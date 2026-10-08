import copy
import json
import sys
import threading
import unittest
import uuid
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'src'))
from domain import APIError, Domain, geometry
from store import Conflict, DynamoStore, MemoryStore, token


def uid():
    return str(uuid.uuid4())


PAGE = dict(schema_version=1, crop_x=0, crop_y=0, crop_width=612, crop_height=792, rotation=0)


class DomainTests(unittest.TestCase):
    def setUp(self):
        self.store = MemoryStore()
        self.time = datetime(2026, 10, 8, 12, tzinfo=timezone.utc)
        self.domain = Domain(self.store, lambda: self.time)
        self.admin = dict(id=uid(), guest=False)
        self.member = dict(id=uid(), guest=False)
        self.outside = dict(id=uid(), guest=False)
        self.guest = dict(id=uid(), guest=True)
        self.first = self.call('create_church_and_default_team', dict(display_name='Test Church', timezone='UTC'), self.admin)
        self.team = self.first['team_id']
        self.second = self.call('create_team', dict(church_id=self.first['church_id'], display_name='Separate Team'), self.admin)
        self.other = self.call('create_church_and_default_team', dict(display_name='Other Church', timezone='UTC'), self.outside)
        self.join(self.team, self.member)

    def call(self, name, p, actor=None):
        return self.domain.rpc(name, p, actor or self.admin)

    def expect_error(self, code, name, p, actor=None):
        with self.assertRaises(APIError) as caught:
            self.call(name, p, actor)
        self.assertEqual(code, caught.exception.code)

    def invite(self, team, role='member', setlist=None, actor=None, uses=1):
        return self.call('create_invitation', dict(team_id=team, permitted_role=role, setlist_id=setlist,
             expires_at=(self.time + timedelta(days=1)).isoformat(), max_uses=uses), actor)

    def join(self, team, actor, role='member', setlist=None):
        invite = self.invite(team, role, setlist)
        return self.call('redeem_invitation', dict(token=invite['token'], display_name='Test Musician'), actor)

    def asset(self, kind='pdf', team=None, actor=None):
        team = team or self.team
        row = self.call('stage_asset', dict(team_id=team, type=kind, sha256='a' * 64, expected_bytes=123), actor)
        validation = dict(sha256=row['sha256'], bytes=row['bytes'])
        if kind == 'pdf':
            validation['page_manifest'] = [PAGE]
        return self.domain.finalize_asset(row['id'], actor or self.admin, validation)

    def chart(self, team=None, actor=None):
        team = team or self.team
        song = self.call('create_song', dict(team_id=team, command_id=uid(), canonical_title='Test Chart'), actor)
        asset = self.asset(team=team, actor=actor)
        return self.call('publish_chart_version', dict(song_id=song['id'], command_id=uid(), verified_pdf_asset_id=asset['id'],
             label='Original', written_key='G', page_manifest=[PAGE]), actor)

    def setlist(self, chart=None, team=None):
        chart = chart or self.chart(team)
        row = self.call('create_setlist', dict(team_id=chart['team_id'], title='Sunday', timezone='UTC', command_id=uid()))
        item = dict(id=uid(), song_id=chart['song_id'], team_chart_version_id=chart['id'], performance_key='A', position=0, kind='planned')
        self.call('save_setlist', dict(setlist_id=row['id'], base_revision=0, command_id=uid(), items=[item]))
        return row, item, chart

    def live(self):
        s, item, chart = self.setlist()
        device = uid()
        lease = self.call('acquire_editor', dict(setlist_id=s['id'], device_id=device, expected_epoch=0, explicit_takeover=False))
        session = self.call('start_session', dict(setlist_id=s['id'], device_id=device, epoch=lease['epoch'], command_id=uid()))
        return s, item, chart, device, lease, session

    def cue(self, item, chart, device, lease, session, sequence=0):
        return dict(session_id=session['id'], command_id=uid(), device_id=device, expected_controller_epoch=lease['epoch'],
             expected_latest_sequence=sequence, performance_item_id=item['id'], song_id=chart['song_id'], team_chart_version_id=chart['id'], performance_key='A')

    def ink(self, chart, actor=None, item=None, device=None, epoch=None, parent=0):
        actor = actor or self.member
        native, preview = self.asset('native', chart['team_id'], actor), self.asset('preview', chart['team_id'], actor)
        identity = dict(church_id=chart['church_id'], team_id=chart['team_id'], chart_version_id=chart['id'], page_index=0,
                        scope='team' if item else 'personal', owner_user_id=None if item else actor['id'], performance_item_id=item['id'] if item else None)
        payload = dict(layer_identity=identity, command_id=uid(), parent_revision=parent, native_asset_id=native['id'], preview_asset_id=preview['id'],
                       geometry=PAGE, device_id=device or uid())
        if epoch:
            payload['controller_epoch_if_team'] = epoch
        return payload, native, preview

    def test_workspace_onboarding_and_explicit_same_church_isolation(self):
        a, b, c = self.chart(), self.chart(self.second['team_id']), self.chart(self.other['team_id'], self.outside)
        self.assertEqual([a['id']], [v['id'] for v in self.domain.rows('chart_versions', self.member)])
        self.expect_error('ACCESS_REVOKED', 'create_song', dict(team_id=self.second['team_id'], command_id=uid(), canonical_title='Forbidden'), self.member)
        self.expect_error('ACCESS_REVOKED', 'create_song', dict(team_id=self.other['team_id'], command_id=uid(), canonical_title='Forbidden'))
        # Having an administrative role in another team does not bypass this team.
        self.join(self.team, self.outside, 'leader')
        self.expect_error('ACCESS_REVOKED', 'get_team_roster', dict(team_id=self.second['team_id']), self.outside)
        self.expect_error('ASSET_NOT_AUTHORIZED', 'publish_chart_version', dict(song_id=a['song_id'], command_id=uid(), verified_pdf_asset_id=b['pdf_asset_id'], page_manifest=[PAGE]), self.outside)
        self.assertNotEqual(a['team_id'], c['team_id'])

    def test_create_and_retry_idempotency_and_payload_mismatch(self):
        p = dict(team_id=self.team, command_id=uid(), canonical_title='One')
        first = self.call('create_song', p)
        self.assertEqual(first, self.call('create_song', p))
        self.assertEqual(1, len(self.domain.rows('songs', self.admin, self.team)))
        self.expect_error('IDEMPOTENCY_CONFLICT', 'create_song', dict(p, canonical_title='Changed'))

    def test_selected_team_context_is_enforced_even_for_multi_team_admin(self):
        s, item, chart = self.setlist(team=self.second['team_id'])
        selected = dict(team_id=self.team, selected_team_id=self.team)
        self.expect_error('ACCESS_REVOKED', 'save_setlist', dict(selected, setlist_id=s['id'], base_revision=1, command_id=uid(), items=[item]))
        self.expect_error('ACCESS_REVOKED', 'set_personal_preference', dict(selected, song_id=chart['song_id'], preferred_version_id=chart['id']))
        self.expect_error('ACCESS_REVOKED', 'create_song', dict(team_id=self.second['team_id'], selected_team_id=self.team, command_id=uid(), canonical_title='Wrong selected team'))
        self.expect_error('ACCESS_REVOKED', 'get_annotation_head', dict(selected, layer_identity=dict(church_id=chart['church_id'],
             chart_version_id=chart['id'], scope='personal', owner_user_id=self.admin['id'], performance_item_id=None, page_index=0)))

    def test_uppercase_uuid_client_roster_is_canonical(self):
        roster = self.call('get_team_roster', dict(team_id=self.team.upper()))
        self.assertEqual(self.team, roster['team_id'])
        self.assertEqual({self.admin['id'], self.member['id']}, {m['user_id'] for m in roster['members']})

    def test_team_catalog_matches_authorized_rows_and_excludes_other_team_and_private_metadata(self):
        _, _, chart = self.setlist()
        other = self.chart(self.second['team_id'])
        private, native, preview = self.ink(chart)
        self.call('save_annotation_revision', private, self.member)
        self.call('set_personal_preference', dict(song_id=chart['song_id'], preferred_version_id=chart['id']), self.member)
        p = dict(team_id=self.team.upper(), selected_team_id=self.team)
        catalog = self.call('get_team_catalog', p)
        self.assertEqual(self.team, catalog['team_id'])
        for table in ('songs', 'chart_versions', 'assets', 'setlists', 'performance_items', 'personal_preferences'):
            self.assertEqual(self.domain.rows(table, self.admin, self.team), catalog[table])
        self.assertNotIn(other['id'], [v['id'] for v in catalog['chart_versions']])
        self.assertTrue({native['id'], preview['id']}.isdisjoint(a['id'] for a in catalog['assets']))
        self.assertEqual([], catalog['personal_preferences'])
        self.assertEqual(1, len(self.call('get_team_catalog', dict(team_id=self.team), self.member)['personal_preferences']))
        self.expect_error('ACCESS_REVOKED', 'get_team_catalog', dict(team_id=self.team), self.outside)
        self.expect_error('ACCESS_REVOKED', 'get_team_catalog', dict(team_id=self.team, selected_team_id=self.second['team_id']))

    def test_guest_catalog_is_exact_setlist_scope_and_has_no_personal_preferences(self):
        s, _, chart = self.setlist()
        other_s, _, other_chart = self.setlist()
        self.join(self.team, self.guest, 'guest', s['id'])
        catalog = self.call('get_team_catalog', dict(team_id=self.team), self.guest)
        self.assertEqual([s['id']], [v['id'] for v in catalog['setlists']])
        self.assertEqual([chart['id']], [v['id'] for v in catalog['chart_versions']])
        self.assertEqual([chart['pdf_asset_id']], [v['id'] for v in catalog['assets']])
        self.assertEqual([], catalog['personal_preferences'])
        self.assertNotIn(other_s['id'], [v['setlist_id'] for v in catalog['performance_items']])
        self.assertNotIn(other_chart['song_id'], [v['id'] for v in catalog['songs']])
        for table in ('songs', 'chart_versions', 'assets', 'setlists', 'performance_items'):
            self.assertEqual(self.domain.rows(table, self.guest, self.team), catalog[table])
        self.expect_error('ACCESS_REVOKED', 'get_team_catalog', dict(team_id=self.second['team_id']), self.guest)

    def test_catalog_reuses_reads_only_within_one_request_and_rechecks_revocation(self):
        for _ in range(4):
            self.chart()
        original_query, original_get = self.store.query, self.store.get
        queries, reads = [], []
        def counted_query(pk, prefix='', **options):
            queries.append((pk, prefix))
            return original_query(pk, prefix, **options)
        def counted_get(pk, sk):
            reads.append((pk, sk))
            return original_get(pk, sk)
        self.store.query, self.store.get = counted_query, counted_get
        self.call('get_team_catalog', dict(team_id=self.team), self.member)
        self.assertEqual(1, queries.count(('T#' + self.team, 'chart_versions#')))
        self.assertLessEqual(reads.count(('T#' + self.team, 'memberships#' + self.member['id'])), 4)
        self.call('set_membership_active', dict(team_id=self.team, user_id=self.member['id'], active=False))
        self.expect_error('ACCESS_REVOKED', 'get_team_catalog', dict(team_id=self.team), self.member)

    def test_catalog_revocation_during_read_is_not_hidden_by_request_cache(self):
        self.chart()
        original = self.store.query
        fired = False
        def revoke_during_catalog(pk, prefix='', **options):
            nonlocal fired
            result = original(pk, prefix, **options)
            if not fired and prefix == 'personal_preferences#':
                fired = True
                member = self.store.get('T#' + self.team, 'memberships#' + self.member['id'])
                self.store.transact([dict(op='put', pk='T#' + self.team, sk='memberships#' + self.member['id'],
                                         expected=member, value=dict(member, active=False))])
            return result
        self.store.query = revoke_during_catalog
        self.expect_error('ACCESS_REVOKED', 'get_team_catalog', dict(team_id=self.team), self.member)

    def test_staging_hash_validation_and_published_pdf_immutability(self):
        a = self.call('stage_asset', dict(team_id=self.team, type='pdf', sha256='b' * 64, expected_bytes=200))
        with self.assertRaises(APIError) as error:
            self.domain.finalize_asset(a['id'], self.admin, dict(sha256='c' * 64, bytes=200, pages=[PAGE]))
        self.assertEqual('HASH_MISMATCH', error.exception.code)
        self.assertEqual('staging', self.domain.upload_asset(a['id'], self.admin)['status'])
        v = self.domain.finalize_asset(a['id'], self.admin, dict(sha256='b' * 64, bytes=200, pages=[PAGE]))
        self.assertEqual(v, self.domain.finalize_asset(a['id'], self.admin, dict(sha256='b' * 64, bytes=200, pages=[PAGE])))
        with self.assertRaises(APIError):
            self.domain.upload_asset(a['id'], self.admin)
        with self.assertRaises(APIError) as error:
            self.domain.finalize_asset(a['id'], self.admin, dict(sha256='b' * 64, bytes=200, pages=[dict(PAGE, crop_width=600)]))
        self.assertEqual('IMMUTABLE_RESOURCE', error.exception.code)

    def test_unpublished_assets_not_visible_to_other_members(self):
        native = self.asset('native', actor=self.member)
        self.assertNotIn(native['id'], [r['id'] for r in self.domain.rows('assets', self.admin, self.team)])
        with self.assertRaises(APIError):
            self.domain.download_asset(native['id'], self.admin)
        with self.assertRaises(APIError):
            self.domain.download_asset(native['id'], self.member)

    def test_guest_exact_rehearsal_scope_and_no_chat_or_personal_ink(self):
        s, item, chart = self.setlist()
        other_s, _, other_chart = self.setlist()
        self.join(self.team, self.guest, 'guest', s['id'])
        self.assertEqual([s['id']], [v['id'] for v in self.domain.rows('setlists', self.guest, self.team)])
        self.assertEqual([chart['id']], [v['id'] for v in self.domain.rows('chart_versions', self.guest, self.team)])
        self.assertEqual(chart['pdf_asset_id'], self.domain.download_asset(chart['pdf_asset_id'], self.guest)['id'])
        with self.assertRaises(APIError):
            self.domain.download_asset(other_chart['pdf_asset_id'], self.guest)
        self.expect_error('ACCESS_REVOKED', 'preflight_manifest', dict(setlist_id=other_s['id']), self.guest)
        self.expect_error('ACCESS_REVOKED', 'get_chat_snapshot', dict(team_id=self.team), self.guest)
        self.assertEqual('guest', self.domain.authorize_team(self.guest, self.team, s['id'])['scope'])
        with self.assertRaises(APIError):
            self.domain.authorize_team(self.guest, self.team)

    def test_invitation_reuse_revocation_expiry_and_guest_validation(self):
        s, _, _ = self.setlist()
        invitation = self.invite(self.team, 'guest', s['id'])
        self.assertEqual(s['id'], self.domain.validate_guest_invitation(invitation['token'])['setlist_id'])
        p = dict(token=invitation['token'])
        receipt = self.call('redeem_invitation', p, self.guest)
        self.assertEqual(receipt, self.call('redeem_invitation', p, self.guest))
        with self.assertRaises(APIError):
            self.domain.validate_guest_invitation(invitation['token'])
        self.call('revoke_guest_grant', dict(setlist_id=s['id'], user_id=self.guest['id']))
        self.expect_error('ACCESS_REVOKED', 'redeem_invitation', p, self.guest)
        invite = self.invite(self.team)
        self.call('revoke_invitation', dict(invitation_id=invite['invitation_id']))
        self.expect_error('ACCESS_REVOKED', 'redeem_invitation', dict(token=invite['token']), dict(id=uid(), guest=False))
        self.time += timedelta(days=2)
        self.expect_error('ACCESS_REVOKED', 'redeem_invitation', p, self.guest)

    def test_invitation_brute_force_attempts_are_counted_on_failure(self):
        for _ in range(10):
            self.expect_error('ACCESS_REVOKED', 'redeem_invitation', dict(token='not-a-token'), self.guest)
        self.expect_error('RATE_LIMITED', 'redeem_invitation', dict(token='not-a-token'), self.guest)

    def test_revocation_blocks_new_requests_and_old_idempotency_receipts(self):
        p = dict(team_id=self.team, command_id=uid(), body='Hello')
        self.call('send_chat_message', p, self.member)
        self.call('set_membership_active', dict(team_id=self.team, user_id=self.member['id'], active=False))
        self.expect_error('ACCESS_REVOKED', 'send_chat_message', p, self.member)
        with self.assertRaises(APIError):
            self.domain.authorize_team(self.member, self.team)

    def test_new_member_invitation_does_not_restore_revoked_leader_privileges(self):
        self.join(self.team, self.outside, 'leader')
        self.call('set_membership_active', dict(team_id=self.team, user_id=self.outside['id'], active=False))
        self.join(self.team, self.outside, 'member')
        self.assertEqual('member', self.domain.rows('memberships', self.outside, self.team)[0]['role'])
        self.expect_error('ACCESS_REVOKED', 'create_song', dict(team_id=self.team, command_id=uid(), canonical_title='Old privileges'), self.outside)

    def test_setlist_cas_and_cross_team_versions(self):
        s, item, _ = self.setlist()
        self.expect_error('REVISION_CONFLICT', 'save_setlist', dict(setlist_id=s['id'], base_revision=0, command_id=uid(), items=[]))
        other = self.chart(self.second['team_id'])
        self.expect_error('FILE_NOT_READY', 'save_setlist', dict(setlist_id=s['id'], base_revision=1, command_id=uid(),
             items=[dict(item, song_id=other['song_id'], team_chart_version_id=other['id'])]))

    def test_two_hundred_item_setlist_is_one_atomic_cas(self):
        s, item, _ = self.setlist()
        entries = [dict(item, id=uid(), position=i) for i in range(200)]
        result = self.call('save_setlist', dict(setlist_id=s['id'], base_revision=1, command_id=uid(), items=entries))
        self.assertEqual(2, result['revision'])
        active = [i for i in self.domain.rows('performance_items', self.admin, self.team) if i['active']]
        self.assertEqual(200, len(active))

    def test_editor_takeover_fences_old_device_and_expiry(self):
        s, item, chart, device, lease, session = self.live()
        other_device = uid()
        self.expect_error('STALE_CONTROLLER', 'acquire_editor', dict(setlist_id=s['id'], device_id=other_device, expected_epoch=1, explicit_takeover=False))
        new = self.call('acquire_editor', dict(setlist_id=s['id'], device_id=other_device, expected_epoch=1, explicit_takeover=True))
        self.assertEqual(2, new['epoch'])
        self.expect_error('STALE_CONTROLLER', 'publish_call', self.cue(item, chart, device, lease, session))
        self.time += timedelta(seconds=61)
        self.expect_error('STALE_CONTROLLER', 'renew_editor', dict(setlist_id=s['id'], device_id=other_device, epoch=2))

    def test_live_calls_latest_only_sequence_idempotency_and_historical_ack(self):
        s, item, chart, device, lease, session = self.live()
        p = self.cue(item, chart, device, lease, session)
        first = self.call('publish_call', p)
        self.assertEqual(first, self.call('publish_call', p))
        self.expect_error('STALE_CALL', 'publish_call', self.cue(item, chart, device, lease, session))
        second = self.call('publish_call', self.cue(item, chart, device, lease, session, 1))
        opened = self.call('acknowledge_open', dict(session_id=session['id'], call_id=first['call']['id'], device_id=uid(), selected_chart_version_id=chart['id']), self.member)
        self.assertFalse(opened['is_latest'])
        snap = self.call('get_session_snapshot', dict(session_id=session['id']), self.member)
        self.assertEqual(2, snap['latest_sequence'])
        self.assertEqual(second['call']['id'], snap['latest_call']['id'])
        self.assertFalse(any('page' in k or 'navigate' in k for k in snap['latest_call']))

    def test_ad_hoc_call_registers_item_and_end_blocks_new_calls(self):
        s, item, chart, device, lease, session = self.live()
        p = self.cue(dict(item, id=uid()), chart, device, lease, session)
        p['ad_hoc_draft'] = dict(id=p['performance_item_id'])
        receipt = self.call('publish_call', p)
        self.assertEqual('ad_hoc', next(i for i in self.domain.rows('performance_items', self.admin, self.team) if i['id'] == p['performance_item_id'])['kind'])
        ended = self.call('end_session', dict(session_id=session['id'], command_id=uid(), device_id=device, epoch=lease['epoch']))
        self.assertEqual('ENDED', ended['status'])
        self.expect_error('SESSION_ENDED', 'publish_call', dict(p, command_id=uid(), expected_latest_sequence=1))

    def test_personal_ink_privacy_cas_original_retention_and_idempotency(self):
        chart = self.chart()
        p, native, _ = self.ink(chart)
        head = self.call('save_annotation_revision', p, self.member)
        self.assertEqual(head, self.call('save_annotation_revision', p, self.member))
        self.expect_error('ACCESS_REVOKED', 'get_annotation_head', dict(layer_id=head['layer_id']))
        self.assertEqual([], self.domain.rows('annotation_revisions', self.admin, self.team))
        self.assertEqual([], self.domain.rows('annotation_heads', self.admin, self.team))
        with self.assertRaises(APIError):
            self.domain.download_asset(native['id'], self.admin)
        stale, _, _ = self.ink(chart)
        self.expect_error('REVISION_CONFLICT', 'save_annotation_revision', stale, self.member)
        second, _, _ = self.ink(chart, parent=1)
        new = self.call('save_annotation_revision', second, self.member)
        self.assertEqual(2, new['revision_number'])
        history = self.domain.rows('annotation_revisions', self.member, self.team)
        self.assertEqual({native['id'], second['native_asset_id']}, {r['native_asset_id'] for r in history})

    def test_team_ink_shared_only_for_exact_item_version_page_with_lease(self):
        s, item, chart, device, lease, session = self.live()
        p, native, _ = self.ink(chart, self.admin, item, device, lease['epoch'])
        head = self.call('save_annotation_revision', p)
        self.assertEqual(head, self.call('get_annotation_head', dict(layer_id=head['layer_id']), self.member))
        self.assertEqual(native['id'], self.domain.download_asset(native['id'], self.member)['id'])
        self.join(self.team, self.guest, 'guest', s['id'])
        self.assertEqual(head, self.call('get_annotation_head', dict(layer_id=head['layer_id']), self.guest))
        # A personally preferred version does not implicitly receive the team ink.
        self.expect_error('STALE_CONTROLLER', 'save_annotation_revision', dict(p, command_id=uid(), parent_revision=1, device_id=uid()))
        self.expect_error('ACCESS_REVOKED', 'get_annotation_head', dict(layer_id=head['layer_id']), self.outside)

    def test_invalid_geometry_and_wrong_pdf_manifest_are_rejected(self):
        chart = self.chart()
        p, _, _ = self.ink(chart)
        self.expect_error('INVALID_PAGE', 'save_annotation_revision', dict(p, geometry=dict(PAGE, rotation=45)), self.member)
        self.expect_error('INVALID_PAGE', 'save_annotation_revision', dict(p, geometry=dict(PAGE, crop_width=600)), self.member)
        self.expect_error('INVALID_INPUT', 'get_annotation_head', dict(layer_identity=dict(p['layer_identity'], page_index=1)), self.member)
        for invalid in [dict(PAGE, crop_width=float('nan')), dict(PAGE, schema_version=True)]:
            with self.assertRaises(APIError):
                geometry(invalid)

    def test_chat_send_reply_edit_delete_reconnect_and_team_scope(self):
        p = dict(team_id=self.team, command_id=uid(), body='Bring the new arrangement')
        first = self.call('send_chat_message', p, self.member)
        self.assertEqual(first, self.call('send_chat_message', p, self.member))
        reply = self.call('send_chat_message', dict(team_id=self.team, command_id=uid(), body='Ready', reply_to_id=first['id']))
        self.expect_error('ACCESS_REVOKED', 'send_chat_message', dict(team_id=self.second['team_id'], command_id=uid(), body='Wrong room', reply_to_id=first['id']))
        self.expect_error('ACCESS_REVOKED', 'edit_chat_message', dict(team_id=self.team, command_id=uid(), message_id=first['id'], expected_revision=1, body='Changed'))
        edited = self.call('edit_chat_message', dict(team_id=self.team, command_id=uid(), message_id=first['id'], expected_revision=1, body='Use v2'), self.member)
        self.expect_error('REVISION_CONFLICT', 'delete_chat_message', dict(team_id=self.team, command_id=uid(), message_id=first['id'], expected_revision=1), self.member)
        deleted = self.call('delete_chat_message', dict(team_id=self.team, command_id=uid(), message_id=first['id'], expected_revision=edited['revision']), self.member)
        snapshot = self.call('get_chat_snapshot', dict(team_id=self.team, after_revision=2), self.member)
        self.assertEqual([deleted], snapshot['messages'])
        self.assertEqual('', deleted['body'])
        self.assertTrue(deleted['deleted'])
        self.assertEqual([], self.call('get_chat_snapshot', dict(team_id=self.second['team_id']))['messages'])
        self.assertEqual('Ready', reply['body'])

    def test_chat_setlist_room_read_mute_pin_report_block(self):
        s, _, _ = self.setlist()
        p = dict(team_id=self.team, setlist_id=s['id'], command_id=uid(), body='Service preparation')
        message = self.call('send_chat_message', p, self.member)
        self.assertEqual([], self.call('get_chat_snapshot', dict(team_id=self.team))['messages'])
        self.call('mark_chat_read', dict(team_id=self.team, setlist_id=s['id'], revision=1), self.member)
        self.call('mute_chat', dict(team_id=self.team, setlist_id=s['id'], muted=True), self.member)
        pinned = self.call('pin_chat_message', dict(team_id=self.team, setlist_id=s['id'], message_id=message['id'], pinned=True))
        self.assertTrue(pinned['pinned'])
        self.expect_error('ACCESS_REVOKED', 'pin_chat_message', dict(team_id=self.team, setlist_id=s['id'], message_id=message['id'], pinned=False), self.member)
        report = self.call('report_chat_message', dict(team_id=self.team, setlist_id=s['id'], message_id=message['id'], reason='Please review'))
        self.assertTrue(report['reported'])
        self.call('block_chat_member', dict(team_id=self.team, user_id=self.member['id'], blocked=True))
        self.assertEqual([], self.call('get_chat_snapshot', dict(team_id=self.team, setlist_id=s['id']))['messages'])
        self.assertEqual(2, self.call('get_chat_snapshot', dict(team_id=self.team, setlist_id=s['id']))['revision'])
        pref = self.call('get_chat_snapshot', dict(team_id=self.team, setlist_id=s['id']), self.member)
        self.assertTrue(pref['muted'])
        self.assertEqual(1, pref['read_revision'])

    def test_chat_pagination_preserves_all_changes(self):
        for i in range(105):
            self.call('send_chat_message', dict(team_id=self.team, command_id=uid(), body='Message ' + str(i)), self.member)
        first = self.call('get_chat_snapshot', dict(team_id=self.team), self.member)
        second = self.call('get_chat_snapshot', dict(team_id=self.team, after_revision=first['revision']), self.member)
        self.assertEqual(100, len(first['messages']))
        self.assertTrue(first['has_more'])
        self.assertEqual(5, len(second['messages']))
        self.assertFalse(second['has_more'])
        self.assertEqual(105, second['revision'])

    def test_chat_pagination_never_resurrects_deleted_original_text(self):
        first = self.call('send_chat_message', dict(team_id=self.team, command_id=uid(), body='Remove this text'), self.member)
        for i in range(103):
            self.call('send_chat_message', dict(team_id=self.team, command_id=uid(), body='Message ' + str(i)), self.member)
        deleted = self.call('delete_chat_message', dict(team_id=self.team, command_id=uid(), message_id=first['id'], expected_revision=1), self.member)
        page = self.call('get_chat_snapshot', dict(team_id=self.team), self.member)
        self.assertNotIn(first['id'], [m['id'] for m in page['messages']])
        last = self.call('get_chat_snapshot', dict(team_id=self.team, after_revision=page['revision']), self.member)
        self.assertEqual(deleted, next(m for m in last['messages'] if m['id'] == first['id']))
        self.assertFalse(any(m['body'] == 'Remove this text' for m in page['messages'] + last['messages']))

    def test_asset_key_helper_never_trusts_path_alone(self):
        chart = self.chart()
        asset = self.domain.download_asset(chart['pdf_asset_id'], self.member)
        self.assertEqual(123, self.domain.asset_for_key(self.member, asset['storage_key'])['expected_bytes'])
        with self.assertRaises(APIError):
            self.domain.asset_for_key(self.member, '../' + asset['storage_key'])
        with self.assertRaises(APIError):
            self.domain.asset_for_key(self.member, asset['storage_key'].replace('.pdf', '.png'))

    def test_unknown_account_workflows_fail_explicitly(self):
        self.expect_error('UNSUPPORTED_OPERATION', 'delete_account', {})
        self.expect_error('UNSUPPORTED_OPERATION', 'export_account', {})

    def test_concurrent_same_command_creates_only_one_message(self):
        barrier = threading.Barrier(2)
        original = self.store.transact
        def racing(writes):
            if any(w['sk'].startswith('RECEIPT#send_chat_message#') for w in writes):
                barrier.wait(timeout=5)
            return original(writes)
        self.store.transact = racing
        p = dict(team_id=self.team, command_id=uid(), body='One durable message')
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda _: self.call('send_chat_message', p, self.member), range(2)))
        self.assertEqual(results[0], results[1])
        self.assertEqual(1, len(self.call('get_chat_snapshot', dict(team_id=self.team), self.member)['messages']))

    def test_concurrent_personal_heads_reject_one_writer_and_preserve_both_assets(self):
        chart = self.chart()
        a, _, _ = self.ink(chart)
        b, _, _ = self.ink(chart)
        barrier, original = threading.Barrier(2), self.store.transact
        def racing(writes):
            if any(w['sk'].startswith('annotation_heads#') for w in writes):
                barrier.wait(timeout=5)
            return original(writes)
        self.store.transact = racing
        def save(p):
            try:
                return self.call('save_annotation_revision', p, self.member)
            except APIError as error:
                return error.code
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(save, [a, b]))
        self.assertEqual(1, sum(isinstance(v, dict) for v in results))
        self.assertIn('REVISION_CONFLICT', results)
        self.assertEqual(1, len(self.domain.rows('annotation_revisions', self.member, self.team)))
        self.assertEqual('verified', self.domain.upload_asset(a['native_asset_id'], self.member, allow_verified=True)['status'])
        self.assertEqual('verified', self.domain.upload_asset(b['native_asset_id'], self.member, allow_verified=True)['status'])

    def test_revocation_between_authorization_and_commit_is_atomic(self):
        original = self.store.transact
        fired = False
        def revoke_before_write(writes):
            nonlocal fired
            if not fired and any(w['sk'].startswith('chat_messages#') for w in writes):
                fired = True
                m = self.store.get('T#' + self.team, 'memberships#' + self.member['id'])
                original([dict(op='put', pk='T#' + self.team, sk='memberships#' + self.member['id'], expected=m, value=dict(m, active=False))])
            return original(writes)
        self.store.transact = revoke_before_write
        self.expect_error('REVISION_CONFLICT', 'send_chat_message', dict(team_id=self.team, command_id=uid(), body='Must not commit'), self.member)
        self.assertEqual([], self.call('get_chat_snapshot', dict(team_id=self.team))['messages'])


class StoreTests(unittest.TestCase):
    def test_memory_transaction_failure_has_no_partial_writes(self):
        store = MemoryStore()
        store.transact([dict(op='put', pk='x', sk='a', value={'n': 1}, expected=None)])
        with self.assertRaises(Conflict):
            store.transact([dict(op='put', pk='x', sk='b', value={'n': 2}, expected=None),
                            dict(op='put', pk='x', sk='a', value={'n': 3}, expected={'n': 0})])
        self.assertIsNone(store.get('x', 'b'))
        self.assertEqual({'n': 1}, store.get('x', 'a'))

    def test_dynamo_adapter_strong_reads_pagination_and_conditional_transact(self):
        class Client:
            def __init__(self):
                self.calls = []
            def get_item(self, **args):
                self.calls.append(args)
                return {'Item': {'data': {'S': '{"n":1}'}}}
            def query(self, **args):
                self.calls.append(args)
                return {'Items': [{'data': {'S': '{"n":2}'}}]} if 'ExclusiveStartKey' in args else {
                    'Items': [{'data': {'S': '{"n":1}'}}], 'LastEvaluatedKey': {'PK': {'S': 'p'}, 'SK': {'S': 's'}}}
            def transact_write_items(self, **args):
                self.calls.append(args)
        client = Client()
        store = DynamoStore('table', client)
        self.assertEqual({'n': 1}, store.get('p', 's'))
        self.assertEqual([{'n': 1}, {'n': 2}], store.query('p', 'prefix'))
        self.assertTrue(all(c['ConsistentRead'] for c in client.calls))
        store.transact([dict(op='put', pk='p', sk='s', value={'n': 2}, expected={'n': 1}),
                        dict(op='check', pk='p', sk='membership', expected={'active': True})])
        ops = client.calls[-1]['TransactItems']
        self.assertEqual(token({'n': 1}), ops[0]['Put']['ExpressionAttributeValues'][':etag']['S'])
        self.assertEqual('#etag = :etag', ops[1]['ConditionCheck']['ConditionExpression'])

    def test_dynamo_index_range_is_bounded_and_ttl_is_promoted(self):
        class Client:
            def query(self, **args):
                self.query_args = args
                return {'Items': [{'data': {'S': '{"revision":2}'}}]}
            def transact_write_items(self, **args):
                self.write_args = args
        client = Client()
        store = DynamoStore('table', client)
        store.query('team', 'CHAT#', after='CHAT#0001', through='CHAT#0005', limit=101)
        self.assertEqual(101, client.query_args['Limit'])
        self.assertEqual('CHAT#0005', client.query_args['ExpressionAttributeValues'][':high']['S'])
        self.assertIn('BETWEEN', client.query_args['KeyConditionExpression'])
        store.transact([dict(op='put', pk='ticket', sk='state', value={'expires_at_epoch': 123}, expected=None)])
        self.assertEqual({'N': '123'}, client.write_args['TransactItems'][0]['Put']['Item']['expires_at_epoch'])


if __name__ == '__main__':
    unittest.main()
