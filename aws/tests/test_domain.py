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
from unittest.mock import patch
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
        hidden = self.call('get_chat_snapshot', dict(team_id=self.team, setlist_id=s['id']))['messages']
        self.assertEqual([message['id']], [m['id'] for m in hidden])
        self.assertTrue(hidden[0]['hidden'])
        self.assertEqual('', hidden[0]['body'])
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

    def test_chat_rooms_unread_counts_creations_not_edits_pins_or_self(self):
        s, _, _ = self.setlist()
        first = self.call('send_chat_message', dict(team_id=self.team, command_id=uid(), body='First'), self.member)
        self.call('send_chat_message', dict(team_id=self.team, command_id=uid(), body='My own'))
        rooms = self.call('get_chat_rooms', dict(team_id=self.team))['rooms']
        self.assertEqual([1, 0], [r['unread_count'] for r in rooms])
        self.call('mark_chat_read', dict(team_id=self.team, revision=first['revision']))
        edited = self.call('edit_chat_message', dict(team_id=self.team, message_id=first['id'], expected_revision=first['revision'],
                                                   command_id=uid(), body='Edited'), self.member)
        pinned = self.call('pin_chat_message', dict(team_id=self.team, message_id=first['id'], expected_revision=edited['revision'],
                                                  command_id=uid(), pinned=True))
        self.assertEqual(0, self.call('get_chat_rooms', dict(team_id=self.team))['rooms'][0]['unread_count'])
        self.assertEqual(first['revision'], pinned['created_revision'])
        second = self.call('send_chat_message', dict(team_id=self.team, setlist_id=s['id'], command_id=uid(), body='Sunday'), self.member)
        self.call('mute_chat', dict(team_id=self.team, setlist_id=s['id'], muted=True))
        rooms = self.call('get_chat_rooms', dict(team_id=self.team))['rooms']
        self.assertEqual([0, 1], [r['unread_count'] for r in rooms])
        self.assertTrue(rooms[1]['muted'])
        self.call('delete_chat_message', dict(team_id=self.team, setlist_id=s['id'], command_id=uid(), message_id=second['id'],
                                            expected_revision=second['revision']))
        self.assertEqual(0, self.call('get_chat_rooms', dict(team_id=self.team))['rooms'][1]['unread_count'])

    def test_chat_rooms_legacy_creation_order_and_truthful_bounded_counts(self):
        first = self.call('send_chat_message', dict(team_id=self.team, command_id=uid(), body='Legacy'), self.member)
        prefix = 'T#' + self.team
        # A real pre-upgrade row has deltas but no creation index or creation revision.
        with self.store.lock:
            del self.store.data[prefix, 'CHAT_CREATED#TEAM#0000000000000001']
            self.store.data[prefix, 'CHAT_HEAD#TEAM'] = {'revision': 1}
            del self.store.data[prefix, 'chat_messages#TEAM#' + first['id']]['created_revision']
        self.call('mark_chat_read', dict(team_id=self.team, revision=1))
        self.call('edit_chat_message', dict(team_id=self.team, command_id=uid(), message_id=first['id'], expected_revision=1,
                                           body='Legacy edit'), self.member)
        self.assertEqual(0, self.call('get_chat_rooms', dict(team_id=self.team))['rooms'][0]['unread_count'])
        self.call('send_chat_message', dict(team_id=self.team, command_id=uid(), body='New creation'), self.member)
        self.assertEqual(1, self.call('get_chat_rooms', dict(team_id=self.team))['rooms'][0]['unread_count'])
        with patch('domain.CHAT_UNREAD_BUDGET', 0):
            room = self.call('get_chat_rooms', dict(team_id=self.team))['rooms'][0]
        self.assertIsNone(room['unread_count'])
        self.assertFalse(room['unread_complete'])
        self.assertEqual(1, room['read_revision'])

    def test_chat_rooms_pagination_and_guest_other_team_context_denial(self):
        setlists = [self.setlist()[0] for _ in range(4)]
        foreign = self.setlist(team=self.second['team_id'])[0]
        first = self.call('get_chat_rooms', dict(team_id=self.team, room_limit=2))
        collected = first['rooms']
        page = first
        while page['has_more']:
            page = self.call('get_chat_rooms', dict(team_id=self.team, room_limit=2, after_setlist_id=page['next_setlist_id']))
            self.assertLessEqual(len(page['rooms']), 2)
            collected += page['rooms']
        self.assertEqual({None, *(s['id'] for s in setlists)}, {r['setlist_id'] for r in collected})
        self.expect_error('INVALID_INPUT', 'get_chat_rooms', dict(team_id=self.team, room_limit=101))
        self.expect_error('ACCESS_REVOKED', 'get_chat_rooms', dict(team_id=self.team, after_setlist_id=foreign['id']))
        self.expect_error('ACCESS_REVOKED', 'get_chat_rooms', dict(team_id=self.second['team_id'], selected_team_id=self.team))
        self.expect_error('ACCESS_REVOKED', 'get_chat_rooms', dict(team_id=self.team), self.outside)
        self.join(self.team, self.guest, 'guest', setlists[0]['id'])
        self.expect_error('ACCESS_REVOKED', 'get_chat_rooms', dict(team_id=self.team), self.guest)

    def test_chat_chart_links_exact_published_team_and_same_room_replies(self):
        s, _, chart = self.setlist()
        foreign = self.chart(self.second['team_id'])
        message = self.call('send_chat_message', dict(team_id=self.team, command_id=uid(), body='Use this version',
                                                     chart_version_id=chart['id']), self.member)
        self.assertEqual(chart['id'], message['chart_version_id'])
        self.assertEqual('Test Chart', message['chart_title'])
        self.expect_error('ACCESS_REVOKED', 'send_chat_message', dict(team_id=self.team, command_id=uid(), body='Wrong team',
                                                                    chart_version_id=foreign['id']))
        self.expect_error('ACCESS_REVOKED', 'send_chat_message', dict(team_id=self.team, setlist_id=s['id'], command_id=uid(),
                                                                    body='Wrong room reply', reply_to_id=message['id']))
        self.expect_error('ACCESS_REVOKED', 'send_chat_message', dict(team_id=self.team, command_id=uid(), body='Asset is not chart',
                                                                    chart_version_id=chart['pdf_asset_id']))
        deleted = self.call('delete_chat_message', dict(team_id=self.team, command_id=uid(), message_id=message['id'],
                                                       expected_revision=message['revision']))
        self.assertIsNone(deleted['chart_version_id'])
        self.assertIsNone(deleted['chart_title'])
        self.expect_error('MESSAGE_DELETED', 'send_chat_message', dict(team_id=self.team, command_id=uid(), body='Reply', reply_to_id=message['id']))

    def test_chat_block_generation_hides_links_and_unblock_restores_full_snapshot(self):
        chart = self.chart()
        message = self.call('send_chat_message', dict(team_id=self.team, command_id=uid(), body='Visible text', chart_version_id=chart['id']), self.member)
        before = self.call('get_chat_snapshot', dict(team_id=self.team))
        p = dict(team_id=self.team, user_id=self.member['id'], blocked=True, command_id=uid())
        blocked = self.call('block_chat_member', p)
        self.assertEqual(blocked, self.call('block_chat_member', p))
        hidden = self.call('get_chat_snapshot', dict(team_id=self.team, after_revision=before['revision'], known_block_revision=0))
        self.assertTrue(hidden['reset'])
        self.assertEqual([self.member['id']], hidden['blocked_author_ids'])
        self.assertEqual('', hidden['messages'][0]['body'])
        self.assertIsNone(hidden['messages'][0]['chart_version_id'])
        self.assertTrue(hidden['messages'][0]['hidden'])
        self.assertEqual(0, self.call('get_chat_rooms', dict(team_id=self.team))['rooms'][0]['unread_count'])
        unblocked = self.call('block_chat_member', dict(p, blocked=False, command_id=uid()))
        restored = self.call('get_chat_snapshot', dict(team_id=self.team, after_revision=before['revision'], known_block_revision=blocked['block_revision']))
        self.assertTrue(restored['full_reset'])
        self.assertEqual(message, restored['messages'][0])
        self.assertEqual(2, unblocked['block_revision'])
        # A late retry proves completion but cannot undo a subsequent unblock.
        self.assertFalse(self.call('block_chat_member', p)['blocked'])

    def test_chat_message_receipts_never_resurrect_deleted_or_edited_text(self):
        send = dict(team_id=self.team, command_id=uid(), body='Original')
        message = self.call('send_chat_message', send, self.member)
        edit = dict(team_id=self.team, command_id=uid(), message_id=message['id'], expected_revision=message['revision'], body='Edited')
        edited = self.call('edit_chat_message', edit, self.member)
        self.assertEqual(edited, self.call('send_chat_message', send, self.member))
        pin = dict(team_id=self.team, command_id=uid(), message_id=message['id'], expected_revision=edited['revision'], pinned=True)
        pinned = self.call('pin_chat_message', pin)
        deleted = self.call('delete_chat_message', dict(team_id=self.team, command_id=uid(), message_id=message['id'], expected_revision=pinned['revision']))
        self.assertEqual(deleted, self.call('send_chat_message', send, self.member))
        self.assertEqual(deleted, self.call('edit_chat_message', edit, self.member))
        self.assertEqual(deleted, self.call('pin_chat_message', pin))
        self.call('set_membership_active', dict(team_id=self.team, user_id=self.member['id'], active=False))
        self.expect_error('ACCESS_REVOKED', 'send_chat_message', send, self.member)

    def test_chat_moderation_role_scope_revision_and_idempotent_resolution(self):
        s, _, _ = self.setlist()
        message = self.call('send_chat_message', dict(team_id=self.team, setlist_id=s['id'], command_id=uid(), body='Review'), self.member)
        payload = dict(team_id=self.team, setlist_id=s['id'], command_id=uid(), message_id=message['id'], reason='Please review')
        report = self.call('report_chat_message', payload, self.member)
        self.assertEqual(report, self.call('report_chat_message', payload, self.member))
        records = self.call('get_chat_reports', dict(team_id=self.team))['reports']
        self.assertEqual(1, len(records))
        self.assertEqual(s['id'], records[0]['setlist_id'])
        self.assertEqual(message, records[0]['message'])
        self.expect_error('ACCESS_REVOKED', 'get_chat_reports', dict(team_id=self.team), self.member)
        self.expect_error('ACCESS_REVOKED', 'get_chat_reports', dict(team_id=self.team), self.outside)
        resolve = dict(team_id=self.team, report_id=report['report_id'], expected_revision=1, status='resolved', command_id=uid())
        self.expect_error('ACCESS_REVOKED', 'resolve_chat_report', resolve, self.member)
        self.expect_error('ACCESS_REVOKED', 'resolve_chat_report', dict(resolve, team_id=self.second['team_id']))
        closed = self.call('resolve_chat_report', resolve)
        self.assertEqual(2, closed['revision'])
        self.assertEqual('resolved', closed['status'])
        self.assertEqual([], self.call('get_chat_reports', dict(team_id=self.team))['reports'])
        self.expect_error('REVISION_CONFLICT', 'resolve_chat_report', dict(resolve, command_id=uid()))
        self.expect_error('REPORT_CLOSED', 'resolve_chat_report', dict(resolve, command_id=uid(), expected_revision=2, status='dismissed'))
        self.call('delete_chat_message', dict(team_id=self.team, setlist_id=s['id'], command_id=uid(), message_id=message['id'], expected_revision=message['revision']))
        replay = self.call('resolve_chat_report', resolve)
        self.assertEqual('', replay['message']['body'])
        self.assertTrue(replay['message']['deleted'])

    def test_chat_reports_legacy_room_recovery_and_bounded_filtered_pagination(self):
        s, _, _ = self.setlist()
        message = self.call('send_chat_message', dict(team_id=self.team, setlist_id=s['id'], command_id=uid(), body='Legacy report'), self.member)
        report = self.call('report_chat_message', dict(team_id=self.team, setlist_id=s['id'], command_id=uid(), message_id=message['id'], reason='Legacy'), self.member)
        with self.store.lock:
            del self.store.data['T#' + self.team, 'CHAT_REF#' + message['id']]
            row = self.store.data['T#' + self.team, 'CHAT_REPORT#' + report['report_id']]
            for field in ('room', 'setlist_id', 'revision', 'author_id', 'status'):
                row.pop(field, None)
        legacy = self.call('get_chat_reports', dict(team_id=self.team))['reports'][0]
        self.assertEqual(s['id'], legacy['setlist_id'])
        self.assertEqual(1, legacy['revision'])
        self.call('resolve_chat_report', dict(team_id=self.team, report_id=report['report_id'], expected_revision=1, status='dismissed', command_id=uid()))
        for _ in range(3):
            self.call('report_chat_message', dict(team_id=self.team, setlist_id=s['id'], command_id=uid(), message_id=message['id'], reason='Current'), self.member)
        found, page = [], self.call('get_chat_reports', dict(team_id=self.team, limit=1))
        while True:
            self.assertLessEqual(len(page['reports']), 1)
            found += page['reports']
            if not page['has_more']:
                break
            page = self.call('get_chat_reports', dict(team_id=self.team, limit=1, after_report_id=page['next_report_id']))
        self.assertEqual(3, len(found))
        self.expect_error('INVALID_INPUT', 'get_chat_reports', dict(team_id=self.team, limit=101))

    def test_chat_moderation_concurrent_cas_and_revocation_during_read(self):
        message = self.call('send_chat_message', dict(team_id=self.team, command_id=uid(), body='Review'), self.member)
        report = self.call('report_chat_message', dict(team_id=self.team, command_id=uid(), message_id=message['id'], reason='Review'), self.member)
        original, barrier = self.store.transact, threading.Barrier(2)
        def racing(writes):
            if any(w['sk'].startswith('RECEIPT#resolve_chat_report#') for w in writes):
                barrier.wait(timeout=5)
            return original(writes)
        self.store.transact = racing
        def resolve(status):
            try:
                return self.call('resolve_chat_report', dict(team_id=self.team, report_id=report['report_id'], expected_revision=1,
                                                           status=status, command_id=uid()))['status']
            except APIError as error:
                return error.code
        with ThreadPoolExecutor(max_workers=2) as pool:
            outcomes = list(pool.map(resolve, ['resolved', 'dismissed']))
        self.assertEqual(1, outcomes.count('REVISION_CONFLICT'))
        self.store.transact = original
        original_query = self.store.query
        def revoke(pk, prefix='', **options):
            rows = original_query(pk, prefix, **options)
            if prefix == 'setlists#':
                m = self.store.get('T#' + self.team, 'memberships#' + self.member['id'])
                original([dict(op='put', pk='T#' + self.team, sk='memberships#' + self.member['id'], expected=m, value=dict(m, active=False))])
            return rows
        self.store.query = revoke
        self.expect_error('ACCESS_REVOKED', 'get_chat_rooms', dict(team_id=self.team), self.member)

    def test_chat_body_reads_fence_concurrent_blocks_for_receipts_and_reports(self):
        message = self.call('send_chat_message', dict(team_id=self.team, command_id=uid(), body='Hidden by concurrent block'), self.member)
        pin = dict(team_id=self.team, message_id=message['id'], command_id=uid(), pinned=True)
        self.call('pin_chat_message', pin)
        report = self.call('report_chat_message', dict(team_id=self.team, message_id=message['id'], command_id=uid(), reason='Review'), self.member)
        resolve = dict(team_id=self.team, report_id=report['report_id'], expected_revision=1, status='resolved', command_id=uid())
        self.call('resolve_chat_report', resolve)
        original = self.store.get
        for name, payload in [('pin_chat_message', pin), ('resolve_chat_report', resolve), ('get_chat_reports', dict(team_id=self.team, status='all'))]:
            with self.store.lock:
                self.store.data.pop(('U#' + self.admin['id'], 'CHAT_BLOCKS#' + self.team), None)
            fired = False
            def block_after_read(pk, sk):
                nonlocal fired
                value = original(pk, sk)
                if not fired and pk == 'U#' + self.admin['id'] and sk == 'CHAT_BLOCKS#' + self.team:
                    fired = True
                    self.store.transact([dict(op='put', pk=pk, sk=sk, expected=value, value=dict(users=[self.member['id']], revision=1))])
                return value
            self.store.get = block_after_read
            self.expect_error('REVISION_CONFLICT', name, payload)
            self.store.get = original

    def test_chat_moderation_retries_recheck_current_role_and_pin_noop_does_not_create_delta(self):
        self.join(self.team, self.outside, 'leader')
        message = self.call('send_chat_message', dict(team_id=self.team, command_id=uid(), body='Review'), self.member)
        pin = dict(team_id=self.team, command_id=uid(), message_id=message['id'], expected_revision=message['revision'], pinned=True)
        pinned = self.call('pin_chat_message', pin, self.outside)
        noop = self.call('pin_chat_message', dict(pin, command_id=uid(), expected_revision=pinned['revision']), self.outside)
        self.assertEqual(pinned['revision'], noop['revision'])
        self.expect_error('REVISION_CONFLICT', 'pin_chat_message', dict(pin, command_id=uid(), pinned=False), self.outside)
        delete = dict(team_id=self.team, command_id=uid(), message_id=message['id'], expected_revision=pinned['revision'])
        self.call('delete_chat_message', delete, self.outside)
        old = self.store.get('T#' + self.team, 'memberships#' + self.outside['id'])
        self.store.transact([dict(op='put', pk='T#' + self.team, sk='memberships#' + self.outside['id'], expected=old, value=dict(old, role='member'))])
        self.expect_error('ACCESS_REVOKED', 'pin_chat_message', pin, self.outside)
        self.expect_error('ACCESS_REVOKED', 'delete_chat_message', delete, self.outside)

    def test_chat_report_same_command_concurrency_has_one_durable_report(self):
        message = self.call('send_chat_message', dict(team_id=self.team, command_id=uid(), body='Review'), self.member)
        original, barrier = self.store.transact, threading.Barrier(2)
        def racing(writes):
            if any(w['sk'].startswith('RECEIPT#report_chat_message#') for w in writes):
                barrier.wait(timeout=5)
            return original(writes)
        self.store.transact = racing
        payload = dict(team_id=self.team, command_id=uid(), message_id=message['id'], reason='Review')
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda _: self.call('report_chat_message', payload, self.member), range(2)))
        self.assertEqual(results[0], results[1])
        self.assertEqual(1, len(self.call('get_chat_reports', dict(team_id=self.team))['reports']))

    def test_chat_removed_member_unblock_only_removes_an_existing_owned_block(self):
        payload = dict(team_id=self.team, user_id=self.member['id'], blocked=True, command_id=uid())
        blocked = self.call('block_chat_member', payload)
        self.call('set_membership_active', dict(team_id=self.team, user_id=self.member['id'], active=False))
        self.expect_error('ACCESS_REVOKED', 'block_chat_member', dict(payload, command_id=uid()))
        unblock = dict(payload, blocked=False, command_id=uid())
        cleared = self.call('block_chat_member', unblock)
        self.assertFalse(cleared['blocked'])
        self.assertEqual(blocked['block_revision'] + 1, cleared['block_revision'])
        self.assertEqual([], cleared['blocked_author_ids'])
        self.assertEqual(cleared, self.call('block_chat_member', unblock))
        self.expect_error('ACCESS_REVOKED', 'block_chat_member', dict(unblock, command_id=uid()))
        self.expect_error('ACCESS_REVOKED', 'block_chat_member', dict(unblock, user_id=self.outside['id'], command_id=uid()))
        self.expect_error('ACCESS_REVOKED', 'get_chat_rooms', dict(team_id=self.team), self.member)

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

    def test_onboarding_member_name_is_bounded_and_does_not_rename_church(self):
        actor = dict(id=uid(), guest=False)
        created = self.call('create_church_and_default_team', dict(display_name='Church Name', timezone='UTC', member_display_name='  Musician Name  '), actor)
        profile = self.store.get('C#' + created['church_id'], 'PROFILE')
        self.assertEqual('Church Name', profile['name'])
        roster = self.call('get_team_roster', dict(team_id=created['team_id']), actor)
        self.assertEqual('Musician Name', roster['members'][0]['display_name'])
        self.assertEqual(1, roster['members'][0]['revision'])
        next_team = self.call('create_team', dict(church_id=created['church_id'], display_name='Second Team'), actor)
        self.assertEqual('Musician Name', self.call('get_team_roster', dict(team_id=next_team['team_id']), actor)['members'][0]['display_name'])
        for name in ('', 'x' * 121, 42):
            self.expect_error('INVALID_INPUT', 'create_church_and_default_team', dict(display_name='Church', timezone='UTC', member_display_name=name), actor)
        self.expect_error('ACCESS_REVOKED', 'create_church_and_default_team', dict(display_name='Church', timezone='UTC', member_display_name='Guest'), self.guest)

    def test_own_display_name_cas_retry_and_identity_are_authoritative(self):
        payload = dict(team_id=self.team, user_id=self.admin['id'], display_name=' Pianist ', expected_revision=1, command_id=uid())
        row = self.call('set_member_display_name', payload, self.member)
        self.assertEqual(self.member['id'], row['user_id'])
        self.assertEqual('Pianist', row['display_name'])
        self.assertEqual(2, row['revision'])
        self.assertEqual(row, self.call('set_member_display_name', payload, self.member))
        self.expect_error('REVISION_CONFLICT', 'set_member_display_name', dict(payload, command_id=uid()), self.member)
        self.expect_error('IDEMPOTENCY_CONFLICT', 'set_member_display_name', dict(payload, display_name='Different'), self.member)
        self.expect_error('ACCESS_REVOKED', 'set_member_display_name', dict(payload, team_id=self.second['team_id']), self.member)
        self.expect_error('ACCESS_REVOKED', 'set_member_display_name', payload, self.guest)
        self.call('set_membership_active', dict(team_id=self.team, user_id=self.member['id'], active=False))
        self.expect_error('ACCESS_REVOKED', 'set_member_display_name', payload, self.member)

    def test_inactive_roster_requires_current_exact_team_admin_and_legacy_revision(self):
        old = self.store.get('T#' + self.team, 'memberships#' + self.member['id'])
        legacy = dict(old)
        legacy.pop('revision')
        self.store.transact([dict(op='put', pk='T#' + self.team, sk='memberships#' + self.member['id'], expected=old, value=legacy)])
        self.assertEqual(1, next(m['revision'] for m in self.call('get_team_roster', dict(team_id=self.team))['members'] if m['user_id'] == self.member['id']))
        self.call('set_membership_active', dict(team_id=self.team, user_id=self.member['id'], active=False, expected_revision=1))
        self.assertEqual([self.admin['id']], [m['user_id'] for m in self.call('get_team_roster', dict(team_id=self.team))['members']])
        self.assertEqual(2, len(self.call('get_team_roster', dict(team_id=self.team, include_inactive=True))['members']))
        self.join(self.team, self.outside, 'leader')
        self.expect_error('ACCESS_REVOKED', 'get_team_roster', dict(team_id=self.team, include_inactive=True), self.outside)
        self.expect_error('ACCESS_REVOKED', 'get_team_roster', dict(team_id=self.second['team_id'], include_inactive=True), self.outside)
        self.expect_error('INVALID_INPUT', 'get_team_roster', dict(team_id=self.team, include_inactive='true'))

    def test_roles_require_admin_target_membership_cas_and_retain_last_admin(self):
        payload = dict(team_id=self.team, user_id=self.member['id'], role='leader', expected_revision=1, command_id=uid())
        row = self.call('set_member_role', payload)
        self.assertEqual(('leader', 2), (row['role'], row['revision']))
        self.assertEqual(row, self.call('set_member_role', payload))
        self.expect_error('ACCESS_REVOKED', 'set_member_role', dict(payload, command_id=uid()), self.member)
        self.expect_error('ACCESS_REVOKED', 'set_member_role', dict(payload, command_id=uid()), self.outside)
        self.expect_error('ACCESS_REVOKED', 'set_member_role', dict(payload, team_id=self.second['team_id'], command_id=uid()))
        self.expect_error('REVISION_CONFLICT', 'set_member_role', dict(payload, command_id=uid(), role='member'))
        self.expect_error('TEAM_ADMIN_REQUIRED', 'set_member_role', dict(payload, user_id=self.admin['id'], role='leader', command_id=uid()))
        self.expect_error('INVALID_INPUT', 'set_member_role', dict(payload, role='guest', command_id=uid(), expected_revision=2))

    def test_concurrent_admin_self_demotions_cannot_remove_all_admins(self):
        self.call('set_member_role', dict(team_id=self.team, user_id=self.member['id'], role='admin', expected_revision=1, command_id=uid()))
        original, barrier = self.store.transact, threading.Barrier(2)
        def racing(writes):
            if any(w['sk'].startswith('RECEIPT#set_member_role#') for w in writes):
                barrier.wait(timeout=5)
            return original(writes)
        self.store.transact = racing
        def demote(actor):
            try:
                revision = 1 if actor == self.admin else 2
                return self.call('set_member_role', dict(team_id=self.team, user_id=actor['id'], role='leader', expected_revision=revision, command_id=uid()), actor)
            except APIError as error:
                return error.code
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(demote, [self.admin, self.member]))
        self.assertEqual(1, results.count('REVISION_CONFLICT'))
        self.store.transact = original
        members = self.call('get_team_roster', dict(team_id=self.team))['members']
        remaining = next(m for m in members if m['role'] == 'admin')
        actor = self.admin if remaining['user_id'] == self.admin['id'] else self.member
        self.expect_error('TEAM_ADMIN_REQUIRED', 'set_member_role', dict(team_id=self.team, user_id=actor['id'], role='member', expected_revision=remaining['revision'], command_id=uid()), actor)

    def test_atomic_admin_handoff_allows_owned_retry_after_demotion_only(self):
        payload = dict(team_id=self.team, user_id=self.member['id'], expected_self_revision=1, expected_member_revision=1, command_id=uid())
        result = self.call('handoff_team_admin', payload)
        self.assertEqual(['leader', 'admin'], [m['role'] for m in result['members']])
        self.assertEqual(result, self.call('handoff_team_admin', payload))
        self.expect_error('ACCESS_REVOKED', 'handoff_team_admin', dict(payload, command_id=uid()))
        self.expect_error('IDEMPOTENCY_CONFLICT', 'handoff_team_admin', dict(payload, expected_member_revision=2))
        self.call('set_membership_active', dict(team_id=self.team, user_id=self.admin['id'], active=False, expected_revision=2), self.member)
        self.expect_error('ACCESS_REVOKED', 'handoff_team_admin', payload)

    def test_handoff_rejects_stale_same_user_and_different_team(self):
        payload = dict(team_id=self.team, user_id=self.member['id'], expected_self_revision=1, expected_member_revision=1, command_id=uid())
        self.expect_error('REVISION_CONFLICT', 'handoff_team_admin', dict(payload, expected_member_revision=2))
        self.expect_error('ACCESS_REVOKED', 'handoff_team_admin', dict(payload, user_id=self.admin['id']))
        self.expect_error('ACCESS_REVOKED', 'handoff_team_admin', dict(payload, team_id=self.second['team_id']))
        self.expect_error('ACCESS_REVOKED', 'handoff_team_admin', payload, self.member)
        self.expect_error('ACCESS_REVOKED', 'handoff_team_admin', payload, self.guest)
        self.assertEqual('admin', self.store.get('T#' + self.team, 'memberships#' + self.admin['id'])['role'])

    def test_membership_active_uses_cas_idempotency_and_current_authority(self):
        payload = dict(team_id=self.team, user_id=self.member['id'], active=False, expected_revision=1, command_id=uid())
        removed = self.call('set_membership_active', payload)
        self.assertEqual((False, 2), (removed['active'], removed['revision']))
        self.assertEqual(removed, self.call('set_membership_active', payload))
        self.expect_error('REVISION_CONFLICT', 'set_membership_active', dict(payload, active=True, command_id=uid()))
        restored = self.call('set_membership_active', dict(payload, active=True, expected_revision=2, command_id=uid()))
        self.assertEqual((True, 3), (restored['active'], restored['revision']))
        self.expect_error('ACCESS_REVOKED', 'set_membership_active', dict(payload, user_id=self.admin['id'], command_id=uid()))
        self.expect_error('ACCESS_REVOKED', 'set_membership_active', dict(payload, team_id=self.second['team_id'], command_id=uid()))
        self.expect_error('ACCESS_REVOKED', 'set_membership_active', dict(payload, command_id=uid()), self.member)

    def test_invitation_management_is_bounded_and_never_lists_token_or_hash(self):
        available = self.invite(self.team, uses=2)
        exhausted = self.invite(self.team)
        self.call('redeem_invitation', dict(token=exhausted['token']), dict(id=uid(), guest=False))
        revoked = self.invite(self.team)
        self.call('revoke_invitation', dict(invitation_id=revoked['invitation_id'], expected_revision=1, command_id=uid()))
        other = self.invite(self.second['team_id'])
        p = dict(team_id=self.team, limit=1)
        listed = []
        while True:
            response = self.call('get_team_invitations', p)
            self.assertLessEqual(len(response['invitations']), 1)
            listed += response['invitations']
            if not response['has_more']:
                break
            p['after_invitation_id'] = response['next_invitation_id']
        encoded = json.dumps(listed)
        for token in (available['token'], exhausted['token'], revoked['token'], other['token'], 'token_hash'):
            self.assertNotIn(token, encoded)
        status = {r['id']: r['status'] for r in listed}
        self.assertEqual('active', status[available['invitation_id']])
        self.assertEqual('exhausted', status[exhausted['invitation_id']])
        self.assertEqual('revoked', status[revoked['invitation_id']])
        self.assertNotIn(other['invitation_id'], status)
        self.time += timedelta(days=2)
        status = {r['id']: r['status'] for r in self.call('get_team_invitations', dict(team_id=self.team))['invitations']}
        self.assertEqual('expired', status[available['invitation_id']])
        for actor in (self.member, self.outside, self.guest):
            self.expect_error('ACCESS_REVOKED', 'get_team_invitations', dict(team_id=self.team), actor)
        self.expect_error('ACCESS_REVOKED', 'get_team_invitations', dict(team_id=self.team, selected_team_id=self.second['team_id']))
        self.expect_error('INVALID_INPUT', 'get_team_invitations', dict(team_id=self.team, limit=101))

    def test_invitation_revoke_cas_retry_and_legacy_revision(self):
        invite = self.invite(self.team)
        old = self.store.get('T#' + self.team, 'invitations#' + invite['invitation_id'])
        legacy = dict(old)
        legacy.pop('revision')
        legacy.pop('created_at')
        self.store.transact([dict(op='put', pk='T#' + self.team, sk='invitations#' + invite['invitation_id'], expected=old, value=legacy)])
        found = next(i for i in self.call('get_team_invitations', dict(team_id=self.team))['invitations'] if i['id'] == invite['invitation_id'])
        self.assertEqual(1, found['revision'])
        self.assertIsNone(found['created_at'])
        payload = dict(invitation_id=invite['invitation_id'], team_id=self.team, expected_revision=1, command_id=uid())
        result = self.call('revoke_invitation', payload)
        self.assertEqual(2, result['revision'])
        self.assertEqual(result, self.call('revoke_invitation', payload))
        self.expect_error('REVISION_CONFLICT', 'revoke_invitation', dict(payload, command_id=uid()))
        self.expect_error('ACCESS_REVOKED', 'revoke_invitation', dict(payload, command_id=uid()), self.member)
        self.expect_error('ACCESS_REVOKED', 'redeem_invitation', dict(token=invite['token']), dict(id=uid(), guest=False))

    def test_admin_lists_recheck_role_after_reads_and_invitation_join_preserves_own_name(self):
        invitation = self.invite(self.team)
        self.call('redeem_invitation', dict(token=invitation['token']), self.member)
        self.assertEqual('Test Musician', self.store.get('T#' + self.team, 'memberships#' + self.member['id'])['display_name'])
        original_query = self.store.query
        def demote_during_query(pk, prefix='', **options):
            rows = original_query(pk, prefix, **options)
            if prefix in ('invitations#', 'memberships#'):
                old = self.store.get('T#' + self.team, 'memberships#' + self.admin['id'])
                self.store.transact([dict(op='put', pk='T#' + self.team, sk='memberships#' + self.admin['id'], expected=old, value=dict(old, role='leader'))])
            return rows
        for name, payload in [('get_team_invitations', dict(team_id=self.team)), ('get_team_roster', dict(team_id=self.team, include_inactive=True))]:
            old = self.store.get('T#' + self.team, 'memberships#' + self.admin['id'])
            self.store.transact([dict(op='put', pk='T#' + self.team, sk='memberships#' + self.admin['id'], expected=old, value=dict(old, role='admin'))])
            self.store.query = demote_during_query
            self.expect_error('ACCESS_REVOKED', name, payload)
            self.store.query = original_query

    def paged_catalog(self, actor=None, limit=2):
        value = {name: [] for name in ('songs', 'chart_versions', 'assets', 'setlists', 'performance_items', 'personal_preferences')}
        payload = dict(team_id=self.team, selected_team_id=self.team, limit=limit)
        pages = []
        for _ in range(1000):
            page = self.call('get_team_catalog_page', payload, actor)
            self.assertLessEqual(sum(len(page[name]) for name in value), limit)
            self.assertLessEqual(len(json.dumps(page, separators=(',', ':')).encode()), 512 * 1024)
            pages.append(page)
            for name in value:
                value[name].extend(page[name])
            if page['next_cursor'] is None:
                return value, pages
            payload['cursor'] = page['next_cursor']
        self.fail('Catalog did not terminate within qualification bound')

    def test_paged_catalog_matches_authorized_member_and_guest_rows(self):
        s, _, chart = self.setlist()
        self.setlist()
        private, _, _ = self.ink(chart)
        self.call('save_annotation_revision', private, self.member)
        self.call('set_personal_preference', dict(song_id=chart['song_id'], preferred_version_id=chart['id']), self.member)
        self.join(self.team, self.guest, 'guest', s['id'])
        for actor in (self.admin, self.member, self.guest):
            result, pages = self.paged_catalog(actor, 1)
            for name, rows in result.items():
                expected = [] if name == 'personal_preferences' and actor['guest'] else self.domain.rows(name, actor, self.team)
                self.assertEqual(sorted(expected, key=lambda r: r.get('id', r.get('song_id'))), sorted(rows, key=lambda r: r.get('id', r.get('song_id'))))
            self.assertTrue(all(page['team_id'] == self.team for page in pages))
        self.expect_error('ACCESS_REVOKED', 'get_team_catalog_page', dict(team_id=self.team), self.outside)
        self.expect_error('ACCESS_REVOKED', 'get_team_catalog_page', dict(team_id=self.team, selected_team_id=self.second['team_id']))
        self.expect_error('ACCESS_REVOKED', 'get_team_catalog_page', dict(team_id=self.second['team_id']), self.guest)

    def test_catalog_cursor_is_opaque_owner_bound_reusable_expiring_and_typed(self):
        self.chart()
        payload = dict(team_id=self.team, limit=1)
        page = self.call('get_team_catalog_page', payload, self.member)
        cursor = page['next_cursor']
        record = self.store.get('U#' + self.member['id'], 'CATALOG_CURSOR#' + self.team + '#' + cursor['after_key'])
        self.assertEqual(int(self.time.timestamp()) + 3600, record['expires_at_epoch'])
        one = self.call('get_team_catalog_page', dict(payload, cursor=cursor), self.member)
        two = self.call('get_team_catalog_page', dict(payload, cursor=cursor), self.member)
        self.assertEqual(one['chart_versions'], two['chart_versions'])
        self.expect_error('INVALID_CURSOR', 'get_team_catalog_page', dict(payload, cursor=cursor))
        for changed in (dict(cursor, schema_version=True), dict(cursor, schema_version=1.0), dict(cursor, after_key='assets#' + uid()),
                        dict(cursor, table='memberships'), dict(cursor, team_id=self.second['team_id']), dict(cursor, scope_token='x' * 64), dict(cursor, extra=True)):
            self.expect_error('INVALID_CURSOR', 'get_team_catalog_page', dict(payload, cursor=changed), self.member)
        self.time += timedelta(hours=1)
        self.expect_error('INVALID_CURSOR', 'get_team_catalog_page', dict(payload, cursor=cursor), self.member)

    def test_catalog_scope_change_fences_role_and_guest_grant_paging(self):
        s, _, _ = self.setlist()
        self.join(self.team, self.guest, 'guest', s['id'])
        member_cursor = self.call('get_team_catalog_page', dict(team_id=self.team), self.member)['next_cursor']
        guest_cursor = self.call('get_team_catalog_page', dict(team_id=self.team), self.guest)['next_cursor']
        self.call('set_member_role', dict(team_id=self.team, user_id=self.member['id'], role='leader', expected_revision=1, command_id=uid()))
        self.expect_error('CATALOG_CHANGED', 'get_team_catalog_page', dict(team_id=self.team, cursor=member_cursor), self.member)
        second, _, _ = self.setlist()
        self.join(self.team, self.guest, 'guest', second['id'])
        self.expect_error('CATALOG_CHANGED', 'get_team_catalog_page', dict(team_id=self.team, cursor=guest_cursor), self.guest)
        fresh = self.call('get_team_catalog_page', dict(team_id=self.team), self.guest)['next_cursor']
        self.call('revoke_guest_grant', dict(setlist_id=second['id'], user_id=self.guest['id']))
        self.expect_error('CATALOG_CHANGED', 'get_team_catalog_page', dict(team_id=self.team, cursor=fresh), self.guest)
        self.call('revoke_guest_grant', dict(setlist_id=s['id'], user_id=self.guest['id']))
        self.expect_error('ACCESS_REVOKED', 'get_team_catalog_page', dict(team_id=self.team, cursor=fresh), self.guest)

    def test_filtered_asset_page_progress_never_exposes_private_resource_ids(self):
        private = self.asset('native', actor=self.member)
        value, pages = self.paged_catalog(limit=1)
        self.assertEqual([], value['assets'])
        self.assertNotIn(private['id'], json.dumps(pages))
        self.assertNotIn(private['storage_key'], json.dumps(pages))
        self.assertTrue(any(not any(page[name] for name in value) and page['next_cursor'] for page in pages))
        self.assertEqual(len(pages), 6)

    def test_embedded_setlist_paging_guards_revision_and_bounds_items(self):
        s, first_item, _ = self.setlist()
        second_item = dict(first_item, id=uid(), position=1)
        self.call('save_setlist', dict(setlist_id=s['id'], base_revision=1, items=[first_item, second_item], command_id=uid()))
        _, pages = self.paged_catalog(limit=1)
        first = next(page for page in pages if page['performance_items'])
        self.assertEqual(1, len(first['performance_items']))
        self.assertEqual('performance_items', first['next_cursor']['table'])
        self.call('save_setlist', dict(setlist_id=s['id'], base_revision=2, items=[first_item], command_id=uid()))
        self.expect_error('CATALOG_CHANGED', 'get_team_catalog_page', dict(team_id=self.team, limit=1, cursor=first['next_cursor']))

    def test_catalog_larger_than_four_megabytes_fetches_in_bounded_pages(self):
        sample = self.call('create_song', dict(team_id=self.team, canonical_title='Synthetic archive', command_id=uid()))
        # Real song field bounds, stored in bulk only to keep this domain test fast.
        for _ in range(50):
            writes = []
            for _ in range(100):
                song_id = uid()
                row = dict(sample, id=song_id, rights_note='x' * 1000)
                writes.append(dict(op='put', pk='T#' + self.team, sk='songs#' + song_id, expected=None, value=row))
            self.store.transact(writes)
        aggregate = self.call('get_team_catalog', dict(team_id=self.team))
        self.assertGreater(len(json.dumps(aggregate).encode()), 4 * 1024 * 1024)
        value, pages = self.paged_catalog(limit=100)
        self.assertEqual(5001, len(value['songs']))
        self.assertEqual(5001, len({row['id'] for row in value['songs']}))
        self.assertGreater(len(pages), 50)

    def test_catalog_cursor_write_transaction_fences_concurrent_revocation(self):
        original = self.store.transact
        fired = False
        def revoke_before_cursor(writes):
            nonlocal fired
            if not fired and any(w['sk'].startswith('CATALOG_CURSOR#') and w['op'] == 'put' for w in writes):
                fired = True
                old = self.store.get('T#' + self.team, 'memberships#' + self.member['id'])
                original([dict(op='put', pk='T#' + self.team, sk='memberships#' + self.member['id'], expected=old, value=dict(old, active=False))])
            return original(writes)
        self.store.transact = revoke_before_cursor
        self.expect_error('REVISION_CONFLICT', 'get_team_catalog_page', dict(team_id=self.team), self.member)
        self.assertEqual([], self.store.query('U#' + self.member['id'], 'CATALOG_CURSOR#'))

    def test_guest_catalog_cursor_transaction_fences_each_grant_revocation(self):
        first, _, chart = self.setlist()
        second, _, _ = self.setlist(chart)
        for row in (first, second):
            self.join(self.team, self.guest, 'guest', row['id'])
        original = self.store.transact
        captured = []
        grant_key = 'guest_grants#' + self.guest['id'] + '#' + second['id']
        def revoke_before_cursor(writes):
            if not captured and any(w['sk'].startswith('CATALOG_CURSOR#') and w['op'] == 'put' for w in writes):
                captured.extend(copy.deepcopy(writes))
                old = self.store.get('T#' + self.team, grant_key)
                original([dict(op='put', pk='T#' + self.team, sk=grant_key, expected=old,
                               value=dict(old, revoked_at=self.time.isoformat()))])
            return original(writes)
        self.store.transact = revoke_before_cursor
        self.expect_error('REVISION_CONFLICT', 'get_team_catalog_page', dict(team_id=self.team), self.guest)
        checked = {w['sk'] for w in captured if w['op'] == 'check'}
        self.assertTrue({'guest_grants#' + self.guest['id'] + '#' + row['id'] for row in (first, second)} <= checked)
        self.assertLessEqual(len(captured), 100)
        self.assertEqual([], self.store.query('U#' + self.guest['id'], 'CATALOG_CURSOR#'))

    def test_catalog_byte_budget_splits_large_rows_without_skipping_them(self):
        sample = self.asset()
        pages = [dict(PAGE, crop_x=99999.12345678901, crop_y=99999.12345678901,
                      crop_width=99999.12345678901, crop_height=99999.12345678901)] * 20
        writes = []
        for _ in range(100):
            asset_id = uid()
            row = dict(sample, id=asset_id, storage_key=sample['church_id'] + '/' + self.team + '/' + asset_id + '.pdf',
                       page_manifest=pages, page_count=20, validation=dict(pages=pages, page_count=20))
            writes.append(dict(op='put', pk='T#' + self.team, sk='assets#' + asset_id, expected=None, value=row))
        self.store.transact(writes)
        catalog, results = self.paged_catalog(limit=100)
        self.assertEqual(101, len(catalog['assets']))
        self.assertEqual(101, len({row['id'] for row in catalog['assets']}))
        asset_pages = [page for page in results if page['assets']]
        self.assertGreaterEqual(len(asset_pages), 2)
        self.assertLess(len(asset_pages[0]['assets']), 100)

    def account_export(self, actor=None, limit=1):
        names = ('memberships', 'personal_preferences', 'annotation_layers', 'annotation_heads', 'annotation_revisions',
                 'assets', 'chat_messages', 'chat_preferences', 'chat_blocks')
        result = {name: [] for name in names}
        payload = dict(team_id=self.team, selected_team_id=self.team, limit=limit)
        pages = []
        for _ in range(1000):
            page = self.call('get_account_export_page', payload, actor)
            self.assertEqual((actor or self.admin)['id'], page['owner_user_id'])
            self.assertEqual('current_authorized_team', page['export_scope'])
            self.assertLessEqual(sum(len(page[name]) for name in names), limit)
            self.assertLessEqual(len(json.dumps(page, separators=(',', ':')).encode()), 512 * 1024)
            pages.append(page)
            for name in names:
                result[name].extend(page[name])
            if page['next_cursor'] is None:
                return result, pages
            payload['cursor'] = page['next_cursor']
        self.fail('Export did not terminate')

    def test_account_preflight_sole_admin_handoff_and_unavailable_team_disclosure(self):
        value = self.call('get_account_preflight', {})
        self.assertEqual(self.admin['id'], value['owner_user_id'])
        self.assertFalse(value['delete_supported'])
        self.assertEqual({self.team, self.second['team_id']}, {t['team_id'] for t in value['teams']})
        self.assertTrue(all(t['sole_admin'] and t['handoff_required'] for t in value['teams']))
        self.call('set_member_role', dict(team_id=self.team, user_id=self.member['id'], role='admin', expected_revision=1, command_id=uid()))
        value = self.call('get_account_preflight', {})
        self.assertFalse(next(t for t in value['teams'] if t['team_id'] == self.team)['handoff_required'])
        self.call('set_membership_active', dict(team_id=self.team, user_id=self.admin['id'], active=False), self.member)
        value = self.call('get_account_preflight', {})
        self.assertEqual(1, value['unavailable_team_count'])
        self.assertEqual([self.second['team_id']], [t['team_id'] for t in value['teams']])
        self.expect_error('ACCESS_REVOKED', 'get_account_preflight', {}, self.guest)

    def test_account_export_only_own_personal_files_and_current_chat_without_receipts(self):
        chart = self.chart()
        own, native, preview = self.ink(chart)
        other, other_native, _ = self.ink(chart, self.admin)
        self.call('save_annotation_revision', own, self.member)
        self.call('save_annotation_revision', other)
        orphan = self.asset('native', actor=self.member)
        self.call('set_personal_preference', dict(song_id=chart['song_id'], preferred_version_id=chart['id']), self.member)
        message = self.call('send_chat_message', dict(team_id=self.team, body='Own current text', command_id=uid()), self.member)
        self.call('delete_chat_message', dict(team_id=self.team, message_id=message['id'], expected_revision=message['revision'], command_id=uid()), self.member)
        self.call('send_chat_message', dict(team_id=self.team, body='Other author text', command_id=uid()))
        self.call('mute_chat', dict(team_id=self.team, muted=True), self.member)
        self.call('block_chat_member', dict(team_id=self.team, user_id=self.admin['id'], blocked=True), self.member)
        result, pages = self.account_export(self.member)
        self.assertEqual([self.member['id']], [m['user_id'] for m in result['memberships']])
        self.assertEqual({native['id'], preview['id']}, {a['id'] for a in result['assets']})
        self.assertTrue(all(row['owner_user_id'] == self.member['id'] and row['scope'] == 'personal' for row in result['annotation_layers'] + result['annotation_heads'] + result['annotation_revisions']))
        self.assertEqual([chart['id']], [row['preferred_version_id'] for row in result['personal_preferences']])
        self.assertEqual([''], [m['body'] for m in result['chat_messages']])
        self.assertTrue(result['chat_messages'][0]['deleted'])
        self.assertEqual('TEAM', result['chat_preferences'][0]['room'])
        self.assertEqual([self.admin['id']], result['chat_blocks'][0]['users'])
        wire = json.dumps(pages)
        for forbidden in (other_native['id'], orphan['id'], chart['pdf_asset_id'], 'Other author text', 'Own current text', 'RECEIPT#', 'token_hash'):
            self.assertNotIn(forbidden, wire)

    def test_account_export_excludes_owned_team_ink_and_other_team_without_permission(self):
        s, item, chart, device, lease, _ = self.live()
        shared, shared_native, _ = self.ink(chart, self.admin, item, device, lease['epoch'])
        self.call('save_annotation_revision', shared)
        own, own_native, _ = self.ink(chart, self.admin)
        self.call('save_annotation_revision', own)
        result, pages = self.account_export()
        self.assertIn(own_native['id'], {a['id'] for a in result['assets']})
        self.assertNotIn(shared_native['id'], json.dumps(pages))
        self.expect_error('ACCESS_REVOKED', 'get_account_export_page', dict(team_id=self.team), self.outside)
        self.expect_error('ACCESS_REVOKED', 'get_account_export_page', dict(team_id=self.team), self.guest)
        self.expect_error('ACCESS_REVOKED', 'get_account_export_page', dict(team_id=self.team, selected_team_id=self.second['team_id']))

    def test_account_export_cursor_is_distinct_owner_bound_and_revocation_fenced(self):
        p = dict(team_id=self.team, limit=1)
        export = self.call('get_account_export_page', p, self.member)['next_cursor']
        catalog = self.call('get_team_catalog_page', p, self.member)['next_cursor']
        self.expect_error('INVALID_CURSOR', 'get_account_export_page', dict(p, cursor=catalog), self.member)
        self.expect_error('INVALID_CURSOR', 'get_team_catalog_page', dict(p, cursor=export), self.member)
        self.expect_error('INVALID_CURSOR', 'get_account_export_page', dict(p, cursor=export))
        self.call('set_member_display_name', dict(team_id=self.team, display_name='Changed', expected_revision=1, command_id=uid()), self.member)
        self.expect_error('CATALOG_CHANGED', 'get_account_export_page', dict(p, cursor=export), self.member)
        fresh = self.call('get_account_export_page', p, self.member)['next_cursor']
        self.call('set_membership_active', dict(team_id=self.team, user_id=self.member['id'], active=False))
        self.expect_error('ACCESS_REVOKED', 'get_account_export_page', dict(p, cursor=fresh), self.member)

    def test_account_export_captures_room_preferences_and_all_own_immutable_revisions(self):
        s, _, chart = self.setlist()
        one, _, _ = self.ink(chart)
        self.call('save_annotation_revision', one, self.member)
        two, _, _ = self.ink(chart, parent=1)
        self.call('save_annotation_revision', two, self.member)
        self.call('mute_chat', dict(team_id=self.team, setlist_id=s['id'], muted=True), self.member)
        result, _ = self.account_export(self.member)
        self.assertEqual([1, 2], sorted(r['revision_number'] for r in result['annotation_revisions']))
        self.assertEqual([2], [r['revision_number'] for r in result['annotation_heads']])
        self.assertEqual(4, len(result['assets']))
        self.assertEqual(s['id'], result['chat_preferences'][0]['setlist_id'])

    def test_account_preflight_and_export_finish_fence_concurrent_membership_removal(self):
        original = self.store.transact
        for name, payload in [('get_account_preflight', {}), ('get_account_export_page', dict(team_id=self.team))]:
            old = self.store.get('T#' + self.team, 'memberships#' + self.member['id'])
            original([dict(op='put', pk='T#' + self.team, sk='memberships#' + self.member['id'], expected=old, value=dict(old, active=True))])
            fired = False
            def revoke(writes):
                nonlocal fired
                if not fired:
                    fired = True
                    m = self.store.get('T#' + self.team, 'memberships#' + self.member['id'])
                    original([dict(op='put', pk='T#' + self.team, sk='memberships#' + self.member['id'], expected=m, value=dict(m, active=False))])
                return original(writes)
            self.store.transact = revoke
            self.expect_error('REVISION_CONFLICT', name, payload, self.member)
            self.store.transact = original

    def test_guest_catalog_small_grant_never_queries_unrelated_chart_archive(self):
        s, item, chart = self.setlist()
        self.join(self.team, self.guest, 'guest', s['id'])
        unrelated = self.chart()
        original = self.store.query
        seen = []
        def bounded(pk, prefix='', **options):
            seen.append((pk, prefix, options))
            if prefix == 'chart_versions#':
                self.fail('Guest catalog queried the entire chart archive')
            return original(pk, prefix, **options)
        self.store.query = bounded
        result, pages = self.paged_catalog(self.guest, 1)
        self.assertEqual([chart['id']], [row['id'] for row in result['chart_versions']])
        self.assertEqual([chart['song_id']], [row['id'] for row in result['songs']])
        self.assertNotIn(unrelated['id'], json.dumps(pages))
        self.assertTrue(all(options.get('limit') == 5001 for _, prefix, options in seen if prefix == 'live_calls#'))
        self.store.query = original
        cursor = self.call('get_team_catalog_page', dict(team_id=self.team), self.guest)['next_cursor']
        self.call('save_setlist', dict(setlist_id=s['id'], base_revision=1, items=[], command_id=uid()))
        self.expect_error('CATALOG_CHANGED', 'get_team_catalog_page', dict(team_id=self.team, cursor=cursor), self.guest)

    def test_guest_catalog_historical_call_keeps_exact_inactive_chart_and_item(self):
        s, item, chart, device, lease, session = self.live()
        self.call('publish_call', self.cue(item, chart, device, lease, session))
        self.call('end_session', dict(session_id=session['id'], device_id=device, epoch=lease['epoch'], command_id=uid()))
        self.call('save_setlist', dict(setlist_id=s['id'], base_revision=1, items=[], command_id=uid()))
        self.join(self.team, self.guest, 'guest', s['id'])
        result, _ = self.paged_catalog(self.guest, 1)
        self.assertEqual([chart['id']], [row['id'] for row in result['chart_versions']])
        self.assertEqual([item['id']], [row['id'] for row in result['performance_items']])
        self.assertFalse(result['performance_items'][0]['active'])

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
