"""Team-isolated WorshipCue transactions. Identity is supplied only by Cognito.

No SQL compatibility layer, global scans, navigation events, or note merging.
All writes condition their authorization and mutable heads in the same transaction.
"""
import copy
import hashlib
import math
import re
import secrets
import unicodedata
import uuid
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

try:
    from .store import Conflict, encode, token
except ImportError:
    from store import Conflict, encode, token


class APIError(Exception):
    def __init__(self, code, status=400):
        super().__init__(code)
        self.code, self.status = code, status


def identifier(value):
    try:
        return str(uuid.UUID(str(value)))
    except (ValueError, TypeError, AttributeError):
        raise APIError('INVALID_INPUT') from None


def text(value, maximum=160):
    if not isinstance(value, str) or not 1 <= len(value.strip()) <= maximum or '\x00' in value:
        raise APIError('INVALID_INPUT')
    return value.strip()


def integer(value, minimum=0, maximum=9007199254740991):
    if isinstance(value, bool) or not isinstance(value, int) or not minimum <= value <= maximum:
        raise APIError('INVALID_INPUT')
    return value


def musical_key(value):
    if not isinstance(value, str) or not re.fullmatch(r'[A-G](#|b)?m?', value):
        raise APIError('INVALID_KEY')
    return value


def timestamp(value):
    try:
        result = datetime.fromisoformat(value.replace('Z', '+00:00'))
        if result.tzinfo is None:
            raise ValueError()
        return result.astimezone(timezone.utc)
    except (ValueError, AttributeError, TypeError):
        raise APIError('INVALID_INPUT') from None


def iso(value):
    return value.astimezone(timezone.utc).isoformat().replace('+00:00', 'Z')


def geometry(value):
    if not isinstance(value, dict):
        raise APIError('INVALID_PAGE')
    result = {}
    for name, alias in [('schema_version', 'schemaVersion'), ('crop_x', 'cropX'), ('crop_y', 'cropY'),
                        ('crop_width', 'cropWidth'), ('crop_height', 'cropHeight'), ('rotation', 'rotation')]:
        n = value.get(name, value.get(alias))
        if isinstance(n, bool) or not isinstance(n, (float, int)) or not math.isfinite(n):
            raise APIError('INVALID_PAGE')
        result[name] = n
    if result['schema_version'] != 1 or result['rotation'] not in (0, 90, 180, 270) or any(
        abs(result[k]) > 100000 for k in ('crop_x', 'crop_y')) or any(
        not 0 < result[k] <= 100000 for k in ('crop_width', 'crop_height')):
        raise APIError('INVALID_PAGE')
    return result


def manifest(value):
    if not isinstance(value, list) or not 1 <= len(value) <= 20:
        raise APIError('INVALID_PAGE')
    return [geometry(page) for page in value]


READS = {'get_session_snapshot', 'get_annotation_head', 'preflight_manifest', 'get_team_roster', 'get_chat_snapshot',
         'get_chat_rooms', 'get_chat_reports', 'get_team_catalog', 'get_team_catalog_page', 'get_team_invitations',
         'get_account_preflight', 'get_account_export_page'}
COMMANDS = {'create_song', 'publish_chart_version', 'create_setlist', 'save_setlist', 'start_session', 'publish_call',
            'end_session', 'save_annotation_revision', 'send_chat_message', 'edit_chat_message', 'delete_chat_message',
            'resolve_chat_report', 'set_member_display_name', 'set_member_role', 'handoff_team_admin'}
CHAT_MESSAGE_COMMANDS = {'send_chat_message', 'edit_chat_message', 'delete_chat_message', 'pin_chat_message'}
CHAT_UNREAD_BUDGET = 200
CHAT_REFERENCE_BUDGET = 5000
TEAM_MEMBER_LIMIT = 200
CATALOG_TABLES = ('songs', 'chart_versions', 'assets', 'setlists', 'performance_items', 'personal_preferences')
CATALOG_PAGE_BYTES = 512 * 1024
EXPORT_TABLES = ('memberships', 'personal_preferences', 'annotation_layers', 'annotation_heads', 'annotation_revisions',
                 'assets', 'chat_messages', 'chat_preferences', 'chat_blocks')
TABLES = {'songs', 'chart_versions', 'assets', 'setlists', 'performance_items', 'personal_preferences',
          'editor_leases', 'live_sessions', 'live_calls', 'annotation_layers', 'annotation_heads',
          'annotation_revisions', 'participants', 'invitations', 'teams', 'memberships', 'guest_grants'}


class _CatalogReads:
    """Readonly cache for a single catalog response, never a mutation or later request."""
    def __init__(self, store):
        self.store, self.reads, self.queries = store, {}, {}

    def get(self, pk, sk):
        if (pk, sk) not in self.reads:
            self.reads[pk, sk] = self.store.get(pk, sk)
        return copy.deepcopy(self.reads[pk, sk])

    def query(self, pk, prefix='', **options):
        key = (pk, prefix, tuple(sorted(options.items())))
        if key not in self.queries:
            self.queries[key] = self.store.query(pk, prefix, **options)
        return copy.deepcopy(self.queries[key])


class Domain:
    def __init__(self, store, now=None):
        self.store = store
        self.now = now or (lambda: datetime.now(timezone.utc))

    def rpc(self, name, payload, actor):
        if not isinstance(payload, dict) or not isinstance(name, str) or name.startswith('_'):
            raise APIError('INVALID_INPUT')
        return _Operation(self.store, self.now, actor).execute(name, payload)

    def rows(self, table, actor, team_id=None):
        return _Operation(self.store, self.now, actor).rows(table, team_id)

    def finalize_asset(self, asset_id, actor, validation):
        """Called only by the server's bounded hash/content validator, never by RPC."""
        op = _Operation(self.store, self.now, actor)
        asset = op.entity('assets', asset_id)
        op.member(asset['team_id'])
        if asset['owner_user_id'] != op.actor['id']:
            raise APIError('ASSET_NOT_AUTHORIZED', 403)
        if not isinstance(validation, dict) or validation.get('sha256') != asset['sha256'] or validation.get('bytes') != asset['bytes']:
            raise APIError('HASH_MISMATCH', 409)
        pages = manifest(validation.get('pages', validation.get('page_manifest'))) if asset['type'] == 'pdf' else None
        if asset['status'] == 'verified':
            if asset.get('page_manifest') != pages:
                raise APIError('IMMUTABLE_RESOURCE', 409)
            return copy.deepcopy(asset)
        if asset['status'] != 'staging':
            raise APIError('FILE_NOT_READY', 409)
        updated = dict(asset, status='verified', verified_at=iso(op.now), page_count=len(pages) if pages else None,
                       page_manifest=pages, validation=dict(pages=pages, page_count=len(pages) if pages else None))
        op.put_entity('assets', updated, asset)
        op.commit()
        return updated

    def upload_asset(self, asset_id, actor, allow_verified=False):
        op = _Operation(self.store, self.now, actor)
        asset = op.entity('assets', asset_id)
        op.member(asset['team_id'])
        if asset['owner_user_id'] != op.actor['id'] or asset['status'] not in (('staging', 'verified') if allow_verified else ('staging',)):
            raise APIError('ASSET_NOT_AUTHORIZED', 403)
        return asset

    def download_asset(self, asset_id, actor):
        op = _Operation(self.store, self.now, actor)
        asset = op.entity('assets', asset_id)
        if not op.asset_readable(asset):
            raise APIError('ASSET_NOT_AUTHORIZED', 403)
        return asset

    def team_access(self, team_id, actor):
        """WebSocket subscriptions use the identical exact-team gate as HTTP."""
        op = _Operation(self.store, self.now, actor)
        return op.member(identifier(team_id))

    def authorize_team(self, actor, team_id, setlist_id=None):
        op = _Operation(self.store, self.now, actor)
        team = identifier(team_id)
        if setlist_id:
            s = op.entity('setlists', setlist_id)
            if s['team_id'] != team:
                raise APIError('ACCESS_REVOKED', 403)
            op.read_setlist(s)
            return dict(team_id=team, setlist_id=s['id'], scope='member' if op.can_member(team) else 'guest')
        op.member(team)
        return dict(team_id=team, scope='member')

    def validate_guest_invitation(self, raw):
        raw = text(raw, 256)
        hashed = hashlib.sha256(raw.encode()).hexdigest()
        ref = self.store.get('INVITE#' + hashed, 'REF')
        entity_ref = self.store.get('ID#' + ref['invitation_id'], 'REF') if ref else None
        row = self.store.get(entity_ref['pk'], entity_ref['sk']) if entity_ref and entity_ref['table'] == 'invitations' else None
        now = self.now()
        if not isinstance(now, datetime):
            now = datetime.fromtimestamp(now, timezone.utc)
        if not row or row['permitted_role'] != 'guest' or row['revoked_at'] or timestamp(row['expires_at']) <= now or row['used_count'] >= row['max_uses']:
            raise APIError('ACCESS_REVOKED', 403)
        return {k: v for k, v in row.items() if k != 'token_hash'}

    def asset_for_key(self, actor, key, upload=False):
        if not isinstance(key, str) or len(key) > 300 or len(key.split('/')) != 3:
            raise APIError('ASSET_NOT_AUTHORIZED', 403)
        parts = key.split('/')
        try:
            identifier(parts[0]); identifier(parts[1])
            asset_id = identifier(parts[2].split('.')[0])
        except APIError:
            raise APIError('ASSET_NOT_AUTHORIZED', 403) from None
        row = self.upload_asset(asset_id, actor) if upload else self.download_asset(asset_id, actor)
        if row['storage_key'] != key:
            raise APIError('ASSET_NOT_AUTHORIZED', 403)
        return dict(row, expected_bytes=row['bytes'])


class _Operation:
    def __init__(self, store, now, actor):
        if not isinstance(actor, dict) or not isinstance(actor.get('guest'), bool):
            raise APIError('AUTH_REQUIRED', 401)
        self.actor = dict(id=identifier(actor.get('id')), guest=actor['guest'])
        self.store, self.now = store, now()
        if not isinstance(self.now, datetime):
            self.now = datetime.fromtimestamp(self.now, timezone.utc)
        self.writes = {}

    def get(self, pk, sk):
        pending = self.writes.get((pk, sk))
        return copy.deepcopy(pending['value']) if pending and pending['op'] == 'put' else self.store.get(pk, sk)

    def check(self, pk, sk, value):
        if (pk, sk) not in self.writes:
            self.writes[pk, sk] = dict(op='check', pk=pk, sk=sk, expected=value)

    def put(self, pk, sk, value, old=None):
        if len(encode(value).encode()) > 350000:
            raise APIError('RESOURCE_LIMIT', 413)
        existing = self.writes.get((pk, sk))
        self.writes[pk, sk] = dict(op='put', pk=pk, sk=sk, value=value,
                                  expected=existing.get('expected') if existing else old)

    def commit(self):
        if self.writes:
            try:
                self.store.transact(list(self.writes.values()))
            except Conflict:
                raise APIError('REVISION_CONFLICT', 409) from None

    def entity(self, table, value):
        entity_id = identifier(value)
        ref = self.get('ID#' + entity_id, 'REF')
        row = self.get(ref['pk'], ref['sk']) if ref and ref['table'] == table else None
        if not row:
            raise APIError('ACCESS_REVOKED', 403)
        return row

    def put_entity(self, table, row, old=None):
        pk, sk = 'T#' + row['team_id'], table + '#' + row['id']
        self.put(pk, sk, row, old)
        if old is None:
            self.put('ID#' + row['id'], 'REF', dict(table=table, pk=pk, sk=sk, team_id=row['team_id']))
        return row

    def member(self, team, role=None):
        team = identifier(team)
        m = self.get('T#' + team, 'memberships#' + self.actor['id'])
        if self.actor['guest'] or not m or not m['active'] or (role and m['role'] not in role):
            raise APIError('ACCESS_REVOKED', 403)
        self.check('T#' + team, 'memberships#' + self.actor['id'], m)
        return m

    def can_member(self, team):
        try:
            return self.member(team)
        except APIError:
            return None

    def read_setlist(self, row):
        m = self.can_member(row['team_id'])
        if m:
            return m
        g = self.get('T#' + row['team_id'], 'guest_grants#' + self.actor['id'] + '#' + row['id'])
        if not g or g.get('revoked_at') or timestamp(g['expires_at']) <= self.now:
            raise APIError('ACCESS_REVOKED', 403)
        self.check('T#' + row['team_id'], 'guest_grants#' + self.actor['id'] + '#' + row['id'], g)
        return None

    def memberships(self):
        result = []
        for pointer in self.store.query('U#' + self.actor['id'], 'MEMBERSHIP#'):
            m = self.can_member(pointer['team_id'])
            if m:
                result.append(m)
        return result

    def grants(self, team=None):
        result = []
        for pointer in self.store.query('U#' + self.actor['id'], 'GRANT#'):
            if team and pointer['team_id'] != team:
                continue
            grant = self.get('T#' + pointer['team_id'], 'guest_grants#' + self.actor['id'] + '#' + pointer['setlist_id'])
            if grant and not grant.get('revoked_at') and timestamp(grant['expires_at']) > self.now:
                result.append(grant)
        return result

    def authorized_setlists(self, team):
        if self.can_member(team):
            return self.store.query('T#' + team, 'setlists#')
        return [self.entity('setlists', g['setlist_id']) for g in self.grants(team)]

    def chart_readable(self, chart):
        if self.can_member(chart['team_id']):
            return True
        for s in self.authorized_setlists(chart['team_id']):
            if any(i['team_chart_version_id'] == chart['id'] for i in s.get('items', []) if i['active']):
                return True
            if any(c['team_chart_version_id'] == chart['id'] for c in self.store.query('T#' + chart['team_id'], 'live_calls#')
                   if c['setlist_id'] == s['id']):
                return True
        return False

    def item(self, item_id, team):
        item_id = identifier(item_id)
        registry = self.get('T#' + team, 'ITEM_REGISTRY') or {'items': {}}
        setlist_id = registry['items'].get(item_id)
        if not setlist_id:
            raise APIError('ACCESS_REVOKED', 403)
        s = self.entity('setlists', setlist_id)
        row = next((i for i in s.get('items', []) if i['id'] == item_id), None)
        if not row:
            raise APIError('ACCESS_REVOKED', 403)
        return row, s

    def layer_readable(self, row):
        if row['scope'] == 'personal':
            return row['owner_user_id'] == self.actor['id'] and bool(self.can_member(row['team_id']))
        try:
            _, s = self.item(row['performance_item_id'], row['team_id'])
            self.read_setlist(s)
            return self.chart_readable(self.entity('chart_versions', row['chart_version_id']))
        except APIError:
            return False

    def asset_readable(self, asset):
        if asset['status'] != 'verified':
            return False
        if asset['type'] == 'pdf':
            return any(c['pdf_asset_id'] == asset['id'] and self.chart_readable(c)
                       for c in self.store.query('T#' + asset['team_id'], 'chart_versions#'))
        for acl in self.store.query('ASSET#' + asset['id'], 'ACL#'):
            layer = self.entity('annotation_layers', acl['layer_id'])
            if self.layer_readable(layer):
                return True
        return False

    def rows(self, table, team=None):
        if table not in TABLES:
            raise APIError('INVALID_INPUT')
        if table == 'memberships':
            return [dict(m, revision=m.get('revision', 1)) for m in self.memberships() if team is None or m['team_id'] == identifier(team)]
        if table == 'guest_grants':
            return self.grants(identifier(team) if team else None)
        teams = [identifier(team)] if team else sorted({m['team_id'] for m in self.memberships()} | {g['team_id'] for g in self.grants()})
        result = []
        for team_id in teams:
            lists = self.authorized_setlists(team_id)
            member = self.can_member(team_id)
            if not member and not lists:
                raise APIError('ACCESS_REVOKED', 403)
            setlist_ids = {s['id'] for s in lists}
            if table == 'setlists':
                result.extend({k: v for k, v in s.items() if k != 'items'} for s in lists)
                continue
            if table == 'performance_items':
                called = {c['performance_item_id'] for c in self.store.query('T#' + team_id, 'live_calls#') if c['setlist_id'] in setlist_ids} if not member else set()
                result.extend(i for s in lists for i in s.get('items', []) if member or i['active'] or i['id'] in called)
                continue
            for row in self.store.query('T#' + team_id, table + '#'):
                allowed = bool(member)
                if table == 'chart_versions':
                    allowed = self.chart_readable(row)
                elif table == 'songs':
                    allowed = bool(member) or any(c['song_id'] == row['id'] and self.chart_readable(c)
                                                  for c in self.store.query('T#' + team_id, 'chart_versions#'))
                elif table == 'assets':
                    allowed = self.asset_readable(row) or (bool(member) and row['owner_user_id'] == self.actor['id'])
                elif table == 'personal_preferences':
                    allowed = bool(member) and row['user_id'] == self.actor['id']
                elif table == 'annotation_layers':
                    allowed = self.layer_readable(row)
                elif table in ('annotation_heads', 'annotation_revisions'):
                    allowed = self.layer_readable(self.entity('annotation_layers', row['layer_id']))
                elif table == 'invitations':
                    allowed = bool(member) and member['role'] == 'admin'
                elif table in ('live_sessions', 'live_calls', 'editor_leases', 'participants'):
                    allowed = row['setlist_id'] in setlist_ids
                    if table == 'participants':
                        allowed = allowed and (row['user_id'] == self.actor['id'] or bool(member and member['role'] in ('leader', 'admin')))
                elif table == 'teams':
                    allowed = bool(member)
                if allowed:
                    result.append({k: v for k, v in row.items() if k not in ('token_hash', 'items')})
        return result

    def authorize(self, name, p):
        def context(row):
            selected = p.get('selected_team_id', p.get('team_id'))
            if selected and identifier(selected) != row['team_id']:
                raise APIError('ACCESS_REVOKED', 403)

        if name in ('create_church_and_default_team', 'get_account_preflight'):
            if self.actor['guest']:
                raise APIError('ACCESS_REVOKED', 403)
        elif name == 'create_team':
            self.church_admin(identifier(p.get('church_id')))
        elif name == 'redeem_invitation':
            pass
        elif name in ('get_team_catalog', 'get_team_catalog_page'):
            team = identifier(p.get('team_id'))
            context({'team_id': team})
            if not self.can_member(team) and not self.authorized_setlists(team):
                raise APIError('ACCESS_REVOKED', 403)
        elif name == 'get_account_export_page':
            context(self.member(p.get('team_id')))
        elif name in ('create_song', 'stage_asset', 'create_setlist', 'create_invitation', 'get_team_roster',
                      'set_membership_active', 'get_chat_snapshot', 'send_chat_message', 'edit_chat_message',
                      'delete_chat_message', 'mark_chat_read', 'mute_chat', 'pin_chat_message', 'report_chat_message',
                      'block_chat_member', 'get_chat_rooms', 'get_chat_reports', 'resolve_chat_report',
                      'get_team_invitations', 'set_member_display_name', 'set_member_role', 'handoff_team_admin'):
            role = ('leader', 'admin') if name in ('create_song', 'create_setlist', 'get_chat_reports', 'resolve_chat_report') else ('admin',) if name in ('create_invitation', 'set_membership_active', 'get_team_invitations') else None
            m = self.member(p.get('team_id'), role)
            context(m)
            if p.get('church_id') and identifier(p['church_id']) != m['church_id']:
                raise APIError('ACCESS_REVOKED', 403)
            if name == 'stage_asset' and p.get('type') == 'pdf':
                self.member(m['team_id'], ('leader', 'admin'))
        elif name in ('publish_chart_version', 'set_personal_preference'):
            resource = self.entity('songs', p.get('song_id'))
            context(resource)
            self.member(resource['team_id'], ('leader', 'admin') if name == 'publish_chart_version' else None)
        elif name in ('save_setlist', 'acquire_editor', 'renew_editor', 'release_editor', 'start_session', 'preflight_manifest', 'revoke_guest_grant'):
            s = self.entity('setlists', p.get('setlist_id'))
            context(s)
            self.read_setlist(s) if name == 'preflight_manifest' else self.member(s['team_id'], ('admin',) if name == 'revoke_guest_grant' else ('leader', 'admin'))
        elif name in ('get_session_snapshot', 'publish_call', 'acknowledge_open', 'end_session'):
            session = self.entity('live_sessions', p.get('session_id'))
            context(session)
            s = self.entity('setlists', session['setlist_id'])
            self.read_setlist(s) if name in ('get_session_snapshot', 'acknowledge_open') else self.member(s['team_id'], ('leader', 'admin'))
        elif name == 'revoke_invitation':
            invite = self.entity('invitations', p.get('invitation_id'))
            context(invite)
            self.member(invite['team_id'], ('admin',))
        elif name in ('get_annotation_head', 'save_annotation_revision'):
            if p.get('layer_id') and name == 'get_annotation_head':
                layer = self.entity('annotation_layers', p['layer_id'])
                context(layer)
                if not self.layer_readable(layer):
                    raise APIError('ACCESS_REVOKED', 403)
            else:
                layer, _ = self.identity(p.get('layer_identity'))
                context(layer)
        else:
            raise APIError('UNSUPPORTED_OPERATION', 404)

    def execute(self, name, p):
        self.authorize(name, p)
        command = identifier(p.get('command_id')) if name in COMMANDS or p.get('command_id') is not None else None
        receipt_key = 'RECEIPT#' + name + '#' + command if command else None
        digest = token(p)
        if receipt_key:
            previous = self.store.get('U#' + self.actor['id'], receipt_key)
            if previous:
                if previous['digest'] != digest:
                    raise APIError('IDEMPOTENCY_CONFLICT', 409)
                return self.receipt_result(name, p, previous['result'])
        handler = getattr(self, 'rpc_' + name, None)
        if handler is None:
            raise APIError('UNSUPPORTED_OPERATION', 404)
        result = handler(p)
        if receipt_key:
            self.put('U#' + self.actor['id'], receipt_key, dict(digest=digest, result=result))
        if name not in READS:
            try:
                self.commit()
            except APIError:
                # A concurrent retry may have committed the exact same command.
                if receipt_key:
                    previous = self.store.get('U#' + self.actor['id'], receipt_key)
                    if previous and previous['digest'] == digest:
                        retry = _Operation(self.store, lambda: self.now, self.actor)
                        retry.authorize(name, p)
                        return retry.receipt_result(name, p, previous['result'])
                raise
        return result

    def receipt_result(self, name, p, result):
        # A receipt proves command completion; it is not an archive of deleted chat text.
        if name in CHAT_MESSAGE_COMMANDS:
            team, _, room = self.chat_scope(p)
            current = self.chat_message(team, room, result['id'])
            member = self.member(team, ('leader', 'admin') if name == 'pin_chat_message' else None)
            if name in ('edit_chat_message', 'delete_chat_message') and current['author_id'] != self.actor['id'] and not (
                    name == 'delete_chat_message' and member['role'] in ('leader', 'admin')):
                raise APIError('ACCESS_REVOKED', 403)
            blocks = self.chat_blocks(team)
            response = self.visible_chat_message(current, blocks['users'])
            self.finish_chat_read(team, blocks.get('revision', 0), moderator=name == 'pin_chat_message' or (
                                  name == 'delete_chat_message' and current['author_id'] != self.actor['id']))
            return response
        if name == 'resolve_chat_report':
            team = identifier(p['team_id'])
            self.member(team, ('leader', 'admin'))
            blocks = self.chat_blocks(team)
            response = self.chat_report(team, result['report_id'], blocks['users'])
            self.finish_chat_read(team, blocks.get('revision', 0), moderator=True)
            return response
        if name == 'block_chat_member':
            team = identifier(p['team_id'])
            blocks = self.chat_blocks(team)
            response = dict(team_id=team, user_id=identifier(p['user_id']), blocked=identifier(p['user_id']) in blocks['users'],
                            block_revision=blocks.get('revision', 0), blocked_author_ids=blocks['users'])
            self.finish_chat_read(team, blocks.get('revision', 0))
            return response
        if name == 'handoff_team_admin':
            team = identifier(p['team_id'])
            # Successful handoff intentionally demotes its sender; only their owned
            # receipt can be read as a member. A fresh mutation still requires admin.
            members = [self.membership_row(team, user) for user in (self.actor['id'], identifier(p['user_id']))]
            _Operation(self.store, lambda: self.now, self.actor).member(team)
            return dict(team_id=team, members=members)
        if name in ('set_member_display_name', 'set_member_role'):
            team = identifier(p['team_id'])
            user = self.actor['id'] if name == 'set_member_display_name' else identifier(p['user_id'])
            row = self.membership_row(team, user)
            _Operation(self.store, lambda: self.now, self.actor).member(team, ('admin',) if user != self.actor['id'] else None)
            return row
        return copy.deepcopy(result)

    def base(self, team, **values):
        t = self.entity('teams', team)
        return dict(schema_version=1, team_id=t['id'], church_id=t['church_id'], **values)

    def church_admin(self, church):
        for m in self.memberships():
            if m['church_id'] == church and m['role'] == 'admin':
                return m
        raise APIError('ACCESS_REVOKED', 403)

    def timezone(self, value):
        value = text(value, 100)
        try:
            ZoneInfo(value)
        except ZoneInfoNotFoundError:
            raise APIError('INVALID_INPUT') from None
        return value

    def add_member(self, team, user, role, display_name=''):
        old = self.get('T#' + team, 'memberships#' + user)
        if not old or not old['active'] or old['role'] != role:
            self.advance_team_authority(team)
        if old is None and len(self.team_members(team)) >= TEAM_MEMBER_LIMIT:
            raise APIError('TEAM_MEMBER_LIMIT', 413)
        row = self.base(team, user_id=user, role=role, active=True, display_name=display_name,
                        created_at=old['created_at'] if old else iso(self.now), revision=old.get('revision', 1) + 1 if old else 1)
        self.put('T#' + team, 'memberships#' + user, row, old)
        pointer = self.get('U#' + user, 'MEMBERSHIP#' + team)
        self.put('U#' + user, 'MEMBERSHIP#' + team, dict(team_id=team), pointer)
        return row

    def rpc_create_church_and_default_team(self, p):
        church, team = str(uuid.uuid4()), str(uuid.uuid4())
        self.put('C#' + church, 'PROFILE', dict(id=church, name=text(p.get('display_name'), 120),
                  timezone=self.timezone(p.get('timezone')), created_by=self.actor['id'], created_at=iso(self.now)))
        self.put_entity('teams', dict(id=team, church_id=church, team_id=team, name='Worship Team'))
        self.put('C#' + church, 'TEAM#' + team, dict(team_id=team))
        self.add_member(team, self.actor['id'], 'admin', text(p['member_display_name'], 120) if p.get('member_display_name') is not None else '')
        return dict(schema_version=1, church_id=church, team_id=team, role='admin')

    def rpc_create_team(self, p):
        church, team = identifier(p.get('church_id')), str(uuid.uuid4())
        founder = self.church_admin(church)
        self.put_entity('teams', dict(id=team, church_id=church, team_id=team, name=text(p.get('display_name'), 120)))
        self.put('C#' + church, 'TEAM#' + team, dict(team_id=team))
        self.add_member(team, self.actor['id'], 'admin', founder.get('display_name', ''))
        return dict(schema_version=1, church_id=church, team_id=team, role='admin')

    def rpc_get_team_roster(self, p):
        team = identifier(p['team_id'])
        self.member(team)
        if not isinstance(p.get('include_inactive', False), bool):
            raise APIError('INVALID_INPUT')
        if p.get('include_inactive'):
            self.member(team, ('admin',))
        members = [dict(m, revision=m.get('revision', 1)) for m in self.team_members(team) if m['active'] or p.get('include_inactive')]
        _Operation(self.store, lambda: self.now, self.actor).member(team, ('admin',) if p.get('include_inactive') else None)
        return dict(team_id=team, members=members)

    def team_members(self, team):
        rows = self.store.query('T#' + team, 'memberships#', limit=TEAM_MEMBER_LIMIT + 1)
        if len(rows) > TEAM_MEMBER_LIMIT:
            raise APIError('TEAM_MEMBER_LIMIT', 413)
        return rows

    def membership_row(self, team, user):
        row = self.get('T#' + team, 'memberships#' + identifier(user))
        if not row:
            raise APIError('ACCESS_REVOKED', 403)
        return dict(row, revision=row.get('revision', 1))

    def advance_team_authority(self, team):
        old = self.get('T#' + team, 'TEAM_AUTHORITY')
        self.put('T#' + team, 'TEAM_AUTHORITY', dict(revision=(old or {}).get('revision', 0) + 1), old)

    def require_remaining_admin(self, team, old, active=True, role=None):
        if old['active'] and old['role'] == 'admin' and (not active or role not in (None, 'admin')):
            if not any(m['active'] and m['role'] == 'admin' and m['user_id'] != old['user_id'] for m in self.team_members(team)):
                raise APIError('TEAM_ADMIN_REQUIRED', 409)

    def rpc_set_member_display_name(self, p):
        team = identifier(p['team_id'])
        old = self.member(team)
        revision = old.get('revision', 1)
        if integer(p.get('expected_revision'), 1) != revision:
            raise APIError('REVISION_CONFLICT', 409)
        name = text(p.get('display_name'), 120)
        row = dict(old, display_name=name, revision=revision + (1 if name != old.get('display_name') else 0))
        self.put('T#' + team, 'memberships#' + self.actor['id'], row, old)
        return row

    def rpc_set_member_role(self, p):
        team, user = identifier(p['team_id']), identifier(p.get('user_id'))
        self.member(team, ('admin',))
        role = p.get('role')
        if role not in ('member', 'leader', 'admin'):
            raise APIError('INVALID_INPUT')
        old = self.get('T#' + team, 'memberships#' + user)
        if not old or not old['active']:
            raise APIError('ACCESS_REVOKED', 403)
        if integer(p.get('expected_revision'), 1) != old.get('revision', 1):
            raise APIError('REVISION_CONFLICT', 409)
        self.advance_team_authority(team)
        self.require_remaining_admin(team, old, role=role)
        row = dict(old, role=role, revision=old.get('revision', 1) + (1 if old['role'] != role else 0))
        self.put('T#' + team, 'memberships#' + user, row, old)
        return row

    def rpc_handoff_team_admin(self, p):
        team, user = identifier(p['team_id']), identifier(p.get('user_id'))
        old = self.member(team, ('admin',))
        target = self.get('T#' + team, 'memberships#' + user)
        if user == self.actor['id'] or not target or not target['active']:
            raise APIError('ACCESS_REVOKED', 403)
        if integer(p.get('expected_self_revision'), 1) != old.get('revision', 1) or integer(p.get('expected_member_revision'), 1) != target.get('revision', 1):
            raise APIError('REVISION_CONFLICT', 409)
        self.advance_team_authority(team)
        sender = dict(old, role='leader', revision=old.get('revision', 1) + 1)
        receiver = dict(target, role='admin', revision=target.get('revision', 1) + (1 if target['role'] != 'admin' else 0))
        self.put('T#' + team, 'memberships#' + self.actor['id'], sender, old)
        self.put('T#' + team, 'memberships#' + user, receiver, target)
        return dict(team_id=team, members=[sender, receiver])

    def rpc_get_team_catalog(self, p):
        team = identifier(p['team_id'])
        member_before = self.can_member(team)
        grants_before = {g['setlist_id'] for g in self.grants(team)} if not member_before else set()
        original_store = self.store
        self.store = _CatalogReads(original_store)
        result = {'team_id': team}
        for table in ('songs', 'chart_versions', 'assets', 'setlists', 'performance_items', 'personal_preferences'):
            result[table] = [] if table == 'personal_preferences' and self.actor['guest'] else self.rows(table, team)
        # A revocation during the catalog reads must not turn into a successful refresh.
        fresh = _Operation(original_store, lambda: self.now, self.actor)
        member_after = fresh.can_member(team)
        if member_before and not member_after:
            raise APIError('ACCESS_REVOKED', 403)
        if not member_after and (not grants_before or not grants_before.issubset(g['setlist_id'] for g in fresh.grants(team))):
            raise APIError('ACCESS_REVOKED', 403)
        return result

    def catalog_scope(self, team):
        member = self.can_member(team)
        grants = [] if member else sorted(self.grants(team), key=lambda g: g['setlist_id'])
        if not member and not grants:
            raise APIError('ACCESS_REVOKED', 403)
        if len(grants) > 40:
            raise APIError('RESOURCE_LIMIT', 413)
        setlist_scopes = []
        for grant in grants:
            self.check('T#' + team, 'guest_grants#' + self.actor['id'] + '#' + grant['setlist_id'], grant)
            row = self.entity('setlists', grant['setlist_id'])
            if row['team_id'] != team:
                raise APIError('ACCESS_REVOKED', 403)
            self.check('T#' + team, 'setlists#' + row['id'], row)
            setlist_scopes.append(dict(id=row['id'], items_token=token(row.get('items', []))))
        digest = token(dict(actor_id=self.actor['id'], team_id=team, member=member, grants=grants, setlist_scopes=setlist_scopes))
        return member, grants, digest

    def catalog_cursor(self, value, team, scope, tables=CATALOG_TABLES, registry='CATALOG_CURSOR'):
        if value is None:
            return dict(table=tables[0], after_key=None)
        if not isinstance(value, dict) or set(value) != {'schema_version', 'team_id', 'table', 'after_key', 'scope_token'}:
            raise APIError('INVALID_CURSOR')
        if not isinstance(value['schema_version'], int) or isinstance(value['schema_version'], bool) or value['schema_version'] != 1 or value['team_id'] != team or value['table'] not in tables or not isinstance(value['scope_token'], str) or not re.fullmatch('[0-9a-f]{64}', value['scope_token']):
            raise APIError('INVALID_CURSOR')
        try:
            cursor_id = identifier(value['after_key'])
        except APIError:
            raise APIError('INVALID_CURSOR') from None
        row = self.store.get('U#' + self.actor['id'], registry + '#' + team + '#' + cursor_id)
        if not row or row['actor_id'] != self.actor['id'] or row['team_id'] != team or row['table'] != value['table'] or row['scope_token'] != value['scope_token'] or row['expires_at_epoch'] <= int(self.now.timestamp()):
            raise APIError('INVALID_CURSOR')
        if row['scope_token'] != scope:
            raise APIError('CATALOG_CHANGED', 409)
        return row

    def guest_catalog_references(self, team, grants):
        lists = {g['setlist_id']: self.entity('setlists', g['setlist_id']) for g in grants}
        calls = self.store.query('T#' + team, 'live_calls#', limit=CHAT_REFERENCE_BUDGET + 1)
        if len(calls) > CHAT_REFERENCE_BUDGET:
            raise APIError('RESOURCE_LIMIT', 413)
        items = [i for s in lists.values() for i in s.get('items', []) if i['active']]
        calls = [c for c in calls if c['setlist_id'] in lists]
        charts = {r['team_chart_version_id'] for r in items + calls}
        if len(charts) > 1000:
            raise APIError('RESOURCE_LIMIT', 413)
        return dict(setlists=lists, charts=charts, songs={r['song_id'] for r in items + calls},
                    called={c['performance_item_id'] for c in calls})

    def guest_catalog_asset(self, row, references):
        if row['status'] != 'verified':
            return False
        if row['type'] == 'pdf':
            for chart_id in references['charts']:
                chart = self.entity('chart_versions', chart_id)
                if chart['team_id'] != row['team_id']:
                    raise APIError('ACCESS_REVOKED', 403)
                if chart['pdf_asset_id'] == row['id']:
                    return True
            return False
        for acl in self.store.query('ASSET#' + row['id'], 'ACL#'):
            layer = self.entity('annotation_layers', acl['layer_id'])
            s = references['setlists'].get(layer['setlist_id'])
            if layer['scope'] == 'team' and layer['team_id'] == row['team_id'] and s and layer['chart_version_id'] in references['charts'] and any(i['id'] == layer['performance_item_id'] for i in s.get('items', [])):
                return True
        return False

    def rpc_get_team_catalog_page(self, p):
        team, limit = identifier(p['team_id']), integer(p.get('limit', 50), 1, 100)
        original = self.store
        member, grants, scope = self.catalog_scope(team)
        position = self.catalog_cursor(p.get('cursor'), team, scope)
        table, after = position['table'], position.get('after_key')
        self.store = _CatalogReads(original)
        references = self.guest_catalog_references(team, grants) if not member else None
        result = dict(schema_version=1, team_id=team, **{name: [] for name in CATALOG_TABLES})
        next_position = None
        budget = CATALOG_PAGE_BYTES - 2048  # Reserve cursor/envelope bytes before adding rows.
        def append(row):
            nonlocal budget
            size = len(encode(row).encode()) + 1
            if size > budget:
                if not result[table]:
                    raise APIError('RESOURCE_LIMIT', 413)
                return False
            result[table].append(row)
            budget -= size
            return True
        def advance():
            index = CATALOG_TABLES.index(table) + 1
            return dict(table=CATALOG_TABLES[index], after_key=None) if index < len(CATALOG_TABLES) else None

        if table == 'performance_items':
            # Embedded items need a revision fence when one setlist spans pages.
            if position.get('item_offset') is not None:
                row = self.store.get('T#' + team, after)
                if not row or row['revision'] != position.get('setlist_revision'):
                    raise APIError('CATALOG_CHANGED', 409)
                offset = position['item_offset']
            else:
                rows = ([s for key, s in sorted(references['setlists'].items()) if after is None or 'setlists#' + key > after][:1]
                        if references else self.store.query('T#' + team, 'setlists#', after=after, limit=1))
                row, offset = (rows[0], 0) if rows else (None, 0)
            if row:
                source_key = 'setlists#' + row['id']
                allowed = bool(member) or any(g['setlist_id'] == row['id'] for g in grants)
                called = set()
                if allowed and not member:
                    called = references['called']
                for index in range(offset, len(row.get('items', []))):
                    item = row['items'][index]
                    if allowed and (member or item['active'] or item['id'] in called):
                        if len(result[table]) >= limit or not append(item):
                            next_position = dict(table=table, after_key=source_key, item_offset=index, setlist_revision=row['revision'])
                            break
                else:
                    more = (any('setlists#' + key > source_key for key in references['setlists'])
                            if references else self.store.query('T#' + team, 'setlists#', after=source_key, limit=1))
                    next_position = dict(table=table, after_key=source_key) if more else advance()
            else:
                next_position = advance()
        elif table == 'personal_preferences' and not member:
            next_position = advance()
        else:
            prefix = table + '#' + self.actor['id'] + '#' if table == 'personal_preferences' else table + '#'
            if references and table in ('songs', 'chart_versions', 'setlists'):
                ids = references['songs'] if table == 'songs' else references['charts'] if table == 'chart_versions' else references['setlists']
                ids = [key for key in sorted(ids) if after is None or prefix + key > after][:limit + 1]
                candidates = [self.entity(table, key) for key in ids]
                if any(row['team_id'] != team for row in candidates):
                    raise APIError('ACCESS_REVOKED', 403)
            else:
                candidates = self.store.query('T#' + team, prefix, after=after, limit=limit + 1)
            consumed = after
            stopped = False
            for row in candidates[:limit]:
                key = prefix + row['song_id'] if table == 'personal_preferences' else table + '#' + row['id']
                allowed = bool(member)
                if table == 'chart_versions':
                    allowed = bool(member) or row['id'] in references['charts']
                elif table == 'songs' and not member:
                    allowed = row['id'] in references['songs']
                elif table == 'assets':
                    allowed = (self.asset_readable(row) or row['owner_user_id'] == self.actor['id']) if member else self.guest_catalog_asset(row, references)
                elif table == 'setlists':
                    allowed = bool(member) or any(g['setlist_id'] == row['id'] for g in grants)
                if allowed and not append({k: v for k, v in row.items() if k not in ('token_hash', 'items')}):
                    stopped = True
                    break
                consumed = key
            next_position = dict(table=table, after_key=consumed) if stopped or len(candidates) > limit else advance()

        fresh = _Operation(original, lambda: self.now, self.actor)
        if fresh.catalog_scope(team)[2] != scope:
            raise APIError('CATALOG_CHANGED', 409)
        if next_position:
            cursor_id = str(uuid.uuid4())
            record = dict(next_position, schema_version=1, actor_id=self.actor['id'], team_id=team, scope_token=scope,
                          expires_at_epoch=int(self.now.timestamp()) + 3600)
            fresh.put('U#' + self.actor['id'], 'CATALOG_CURSOR#' + team + '#' + cursor_id, record)
            result['next_cursor'] = dict(schema_version=1, team_id=team, table=record['table'], after_key=cursor_id, scope_token=scope)
        else:
            result['next_cursor'] = None
        # READS does not normally commit. Cursor registration is deliberately fenced
        # with the same fresh membership/grant rows and expires without content hints.
        fresh.commit()
        if len(encode(result).encode()) > CATALOG_PAGE_BYTES:
            raise APIError('RESOURCE_LIMIT', 413)
        return result

    def rpc_get_account_preflight(self, p):
        pointers = self.store.query('U#' + self.actor['id'], 'MEMBERSHIP#', limit=201)
        if len(pointers) > 200:
            raise APIError('RESOURCE_LIMIT', 413)
        teams, unavailable = [], 0
        for pointer in pointers:
            team = pointer['team_id']
            own = self.can_member(team)
            if not own:
                unavailable += 1
                continue
            if len(teams) >= 50:
                raise APIError('RESOURCE_LIMIT', 413)
            authority = self.store.get('T#' + team, 'TEAM_AUTHORITY')
            self.check('T#' + team, 'TEAM_AUTHORITY', authority)
            admins = [m for m in self.team_members(team) if m['active'] and m['role'] == 'admin']
            profile = self.entity('teams', team)
            fresh = _Operation(self.store, lambda: self.now, self.actor)
            if fresh.member(team) != own or self.store.get('T#' + team, 'TEAM_AUTHORITY') != authority:
                raise APIError('REVISION_CONFLICT', 409)
            sole = own['role'] == 'admin' and len(admins) == 1
            teams.append(dict(team_id=team, church_id=own['church_id'], display_name=profile['name'],
                              member_display_name=own.get('display_name', ''), role=own['role'], revision=own.get('revision', 1),
                              sole_admin=sole, handoff_required=sole))
        # At most 50 active teams permits one atomic final membership/authority
        # fence per team. This read-only preflight never closes an account itself.
        self.commit()
        return dict(schema_version=1, owner_user_id=self.actor['id'], generated_at=iso(self.now), delete_supported=False,
                    teams=teams, unavailable_team_count=unavailable)

    def personal_export_asset(self, row):
        if row['type'] not in ('native', 'preview') or row['status'] != 'verified' or row['owner_user_id'] != self.actor['id']:
            return False
        for acl in self.store.query('ASSET#' + row['id'], 'ACL#'):
            layer = self.entity('annotation_layers', acl['layer_id'])
            if layer['team_id'] == row['team_id'] and layer['scope'] == 'personal' and layer['owner_user_id'] == self.actor['id']:
                return True
        return False

    def rpc_get_account_export_page(self, p):
        team, limit = identifier(p['team_id']), integer(p.get('limit', 50), 1, 100)
        original = self.store
        member, _, scope = self.catalog_scope(team)
        if not member:
            raise APIError('ACCESS_REVOKED', 403)
        position = self.catalog_cursor(p.get('cursor'), team, scope, EXPORT_TABLES, 'ACCOUNT_EXPORT_CURSOR')
        table, after = position['table'], position.get('after_key')
        self.store = _CatalogReads(original)
        result = dict(schema_version=1, owner_user_id=self.actor['id'], team_id=team, export_scope='current_authorized_team',
                      **{name: [] for name in EXPORT_TABLES})
        budget = CATALOG_PAGE_BYTES - 2048
        def append(row):
            nonlocal budget
            size = len(encode(row).encode()) + 1
            if size > budget:
                if not result[table]:
                    raise APIError('RESOURCE_LIMIT', 413)
                return False
            result[table].append(row)
            budget -= size
            return True
        def advance():
            index = EXPORT_TABLES.index(table) + 1
            return dict(table=EXPORT_TABLES[index], after_key=None) if index < len(EXPORT_TABLES) else None
        if table == 'memberships':
            append(dict(member, revision=member.get('revision', 1)))
            next_position = advance()
        elif table == 'chat_blocks':
            row = self.store.get('U#' + self.actor['id'], 'CHAT_BLOCKS#' + team)
            if row:
                append(dict(row, team_id=team, user_id=self.actor['id']))
            next_position = advance()
        elif table == 'chat_preferences':
            if after is None:
                room = 'TEAM'
            else:
                last = 'setlists#' + after.split('#', 1)[1] if after.startswith('SETLIST#') else None
                rows = self.store.query('T#' + team, 'setlists#', after=last, limit=1)
                room = 'SETLIST#' + rows[0]['id'] if rows else None
            if room:
                row = self.store.get('T#' + team, 'CHAT_PREF#' + self.actor['id'] + '#' + room)
                if row:
                    append(dict(row, user_id=self.actor['id'], room=room, setlist_id=room.split('#', 1)[1] if room != 'TEAM' else None))
                last = 'setlists#' + room.split('#', 1)[1] if room != 'TEAM' else None
                more = self.store.query('T#' + team, 'setlists#', after=last, limit=1)
                next_position = dict(table=table, after_key=room) if more else advance()
            else:
                next_position = advance()
        else:
            prefix = table + '#' + self.actor['id'] + '#' if table == 'personal_preferences' else table + '#'
            candidates = self.store.query('T#' + team, prefix, after=after, limit=limit + 1)
            consumed, stopped = after, False
            for row in candidates[:limit]:
                if table == 'personal_preferences':
                    key, allowed = prefix + row['song_id'], row['user_id'] == self.actor['id']
                elif table == 'chat_messages':
                    room = 'SETLIST#' + row['setlist_id'] if row.get('setlist_id') else 'TEAM'
                    key, allowed = prefix + room + '#' + row['id'], row['author_id'] == self.actor['id']
                elif table == 'assets':
                    key, allowed = prefix + row['id'], self.personal_export_asset(row)
                else:
                    key = prefix + (row['layer_id'] if table == 'annotation_heads' else row['id'])
                    allowed = row['scope'] == 'personal' and row['owner_user_id'] == self.actor['id']
                    if allowed and table != 'annotation_layers':
                        layer = self.entity('annotation_layers', row['layer_id'])
                        allowed = layer['scope'] == 'personal' and layer['owner_user_id'] == self.actor['id'] and layer['team_id'] == team
                if allowed:
                    visible = self.visible_chat_message(row) if table == 'chat_messages' else dict(row, verified=True) if table == 'assets' else row
                    if not append(visible):
                        stopped = True
                        break
                consumed = key
            next_position = dict(table=table, after_key=consumed) if stopped or len(candidates) > limit else advance()
        fresh = _Operation(original, lambda: self.now, self.actor)
        if fresh.catalog_scope(team)[2] != scope:
            raise APIError('CATALOG_CHANGED', 409)
        if next_position:
            cursor_id = str(uuid.uuid4())
            record = dict(next_position, schema_version=1, actor_id=self.actor['id'], team_id=team, scope_token=scope,
                          expires_at_epoch=int(self.now.timestamp()) + 3600)
            fresh.put('U#' + self.actor['id'], 'ACCOUNT_EXPORT_CURSOR#' + team + '#' + cursor_id, record)
            result['next_cursor'] = dict(schema_version=1, team_id=team, table=record['table'], after_key=cursor_id, scope_token=scope)
        else:
            result['next_cursor'] = None
        fresh.commit()
        if len(encode(result).encode()) > CATALOG_PAGE_BYTES:
            raise APIError('RESOURCE_LIMIT', 413)
        return result

    def rpc_create_song(self, p):
        title = text(p.get('canonical_title', p.get('title')))
        row = self.base(identifier(p['team_id']), id=str(uuid.uuid4()), canonical_title=title,
                        normalized_title=unicodedata.normalize('NFKC', title).casefold(), initials='',
                        rights_note=p.get('rights_note', ''), archived_at=None, next_version=1)
        if not isinstance(row['rights_note'], str) or len(row['rights_note']) > 1000:
            raise APIError('INVALID_INPUT')
        return self.put_entity('songs', row)

    def rpc_stage_asset(self, p):
        kind, sha = p.get('type'), p.get('sha256')
        suffix = {'pdf': 'pdf', 'native': 'drawing', 'preview': 'png'}.get(kind)
        if not suffix or not isinstance(sha, str) or not re.fullmatch('[0-9a-f]{64}', sha):
            raise APIError('INVALID_INPUT')
        count = integer(p.get('expected_bytes'), 1, 104857600 if kind == 'pdf' else 2097152)
        asset = str(uuid.uuid4())
        row = self.base(identifier(p['team_id']), id=asset, asset_id=asset, owner_user_id=self.actor['id'], type=kind,
                        sha256=sha, bytes=count, status='staging', page_count=None, page_manifest=None, validation=None,
                        storage_key=p['team_id'] + '/' + self.actor['id'] + '/' + asset + '.' + suffix, created_at=iso(self.now))
        return self.put_entity('assets', row)

    def rpc_publish_chart_version(self, p):
        song = self.entity('songs', p['song_id'])
        asset = self.entity('assets', p.get('verified_pdf_asset_id'))
        pages = manifest(p.get('page_manifest'))
        if asset['team_id'] != song['team_id'] or asset['owner_user_id'] != self.actor['id']:
            raise APIError('ASSET_NOT_AUTHORIZED', 403)
        if asset['type'] != 'pdf' or asset['status'] != 'verified':
            raise APIError('FILE_NOT_READY', 409)
        if pages != asset['page_manifest']:
            raise APIError('INVALID_PAGE')
        key = musical_key(p['written_key']) if p.get('written_key') is not None else None
        label = p.get('label', '')
        if not isinstance(label, str) or len(label) > 120:
            raise APIError('INVALID_INPUT')
        self.put_entity('songs', dict(song, next_version=song['next_version'] + 1), song)
        row = self.base(song['team_id'], id=str(uuid.uuid4()), song_id=song['id'], version_number=song['next_version'],
                        label=label, written_key=key, pdf_asset_id=asset['id'], pdf_sha256=asset['sha256'], pdf_bytes=asset['bytes'],
                        page_count=len(pages), page_manifest=pages, pages=pages, published_at=iso(self.now), archived_at=None)
        row['chart_version_id'] = row['id']
        return self.put_entity('chart_versions', row)

    def rpc_create_setlist(self, p):
        row = self.base(identifier(p['team_id']), id=str(uuid.uuid4()), title=text(p.get('title')),
                        timezone=self.timezone(p.get('timezone')), service_time=iso(timestamp(p['service_time'])) if p.get('service_time') else None,
                        revision=0, state='draft', items=[], live_session_id=None)
        self.put_entity('setlists', row)
        self.put('T#' + row['team_id'], 'editor_leases#' + row['id'], self.base(row['team_id'], setlist_id=row['id'],
                   controller_user_id=None, device_id=None, epoch=0, expires_at=iso(self.now), active=False))
        return {k: v for k, v in row.items() if k != 'items'}

    def rpc_save_setlist(self, p):
        s = self.entity('setlists', p['setlist_id'])
        if integer(p.get('base_revision')) != s['revision']:
            raise APIError('REVISION_CONFLICT', 409)
        items = p.get('items')
        if not isinstance(items, list) or len(items) > 200:
            raise APIError('INVALID_INPUT')
        registry = self.get('T#' + s['team_id'], 'ITEM_REGISTRY')
        bindings = copy.deepcopy(registry['items']) if registry else {}
        old_items = {i['id']: i for i in s['items']}
        proposed, positions = {}, set()
        for i in items:
            if not isinstance(i, dict):
                raise APIError('INVALID_INPUT')
            item_id = identifier(i.get('id'))
            if item_id in proposed or (bindings.get(item_id) and bindings[item_id] != s['id']):
                raise APIError('ACCESS_REVOKED', 403)
            chart = self.entity('chart_versions', i.get('team_chart_version_id'))
            if chart['team_id'] != s['team_id'] or chart['song_id'] != identifier(i.get('song_id')):
                raise APIError('FILE_NOT_READY', 409)
            old = old_items.get(item_id)
            if old and (old['song_id'] != chart['song_id'] or old['kind'] == 'ad_hoc'):
                raise APIError('ACCESS_REVOKED', 403)
            kind, position = i.get('kind'), i.get('position')
            if kind == 'planned':
                position = integer(position, 0, 199)
                if position in positions:
                    raise APIError('INVALID_INPUT')
                positions.add(position)
            elif kind != 'standby' or position is not None:
                raise APIError('INVALID_INPUT')
            proposed[item_id] = self.base(s['team_id'], id=item_id, setlist_id=s['id'], song_id=chart['song_id'],
                  team_chart_version_id=chart['id'], performance_key=musical_key(i.get('performance_key')), position=position,
                  kind=kind, active=True, revision=(old['revision'] + 1 if old else 1))
            bindings[item_id] = s['id']
        retained = [dict(i, active=False) if i['kind'] != 'ad_hoc' else i for i in s['items'] if i['id'] not in proposed]
        updated = dict(s, revision=s['revision'] + 1, state='published', title=text(p.get('title', s['title'])),
                       items=retained + list(proposed.values()))
        self.put('T#' + s['team_id'], 'ITEM_REGISTRY', dict(items=bindings), registry)
        self.put_entity('setlists', updated, s)
        return dict(schema_version=1, id=s['id'], setlist_id=s['id'], team_id=s['team_id'], revision=updated['revision'])

    def rpc_set_personal_preference(self, p):
        song, chart = self.entity('songs', p['song_id']), self.entity('chart_versions', p.get('preferred_version_id'))
        if chart['song_id'] != song['id'] or chart['team_id'] != song['team_id']:
            raise APIError('ACCESS_REVOKED', 403)
        key = 'personal_preferences#' + self.actor['id'] + '#' + song['id']
        old = self.get('T#' + song['team_id'], key)
        row = self.base(song['team_id'], user_id=self.actor['id'], song_id=song['id'], preferred_version_id=chart['id'], revision=old['revision'] + 1 if old else 1)
        self.put('T#' + song['team_id'], key, row, old)
        return row

    def rpc_create_invitation(self, p):
        team = identifier(p['team_id'])
        role = p.get('permitted_role')
        expiry = timestamp(p.get('expires_at'))
        if role not in ('member', 'leader', 'guest') or not self.now < expiry <= self.now + timedelta(days=7):
            raise APIError('INVALID_INPUT')
        setlist = identifier(p['setlist_id']) if p.get('setlist_id') else None
        if (role == 'guest') != (setlist is not None) or (setlist and self.entity('setlists', setlist)['team_id'] != team):
            raise APIError('INVALID_INPUT')
        invite, raw = str(uuid.uuid4()), secrets.token_urlsafe(32)
        hashed = hashlib.sha256(raw.encode()).hexdigest()
        row = self.base(team, id=invite, token_hash=hashed, permitted_role=role, setlist_id=setlist,
                        inviter=self.actor['id'], expires_at=iso(expiry), max_uses=integer(p.get('max_uses', 1), 1, 50), used_count=0, revoked_at=None,
                        created_at=iso(self.now), revision=1)
        self.put_entity('invitations', row)
        self.put('INVITE#' + hashed, 'REF', dict(invitation_id=invite))
        return dict(schema_version=1, invitation_id=invite, team_id=team, token=raw, expires_at=iso(expiry), permitted_role=role, installation_required=True)

    def rpc_redeem_invitation(self, p):
        raw = text(p.get('token'), 256)
        digest = hashlib.sha256(raw.encode()).hexdigest()
        rate_key = 'RATE#REDEEM#' + str(int(self.now.timestamp()) // 60)
        old = self.store.get('U#' + self.actor['id'], rate_key)
        if old and old['uses'] >= 10:
            raise APIError('RATE_LIMITED', 429)
        try:
            self.store.transact([dict(op='put', pk='U#' + self.actor['id'], sk=rate_key, expected=old,
                                     value=dict(uses=old['uses'] + 1 if old else 1, expires_at_epoch=int(self.now.timestamp()) + 120))])
        except Conflict:
            raise APIError('RATE_LIMITED', 429) from None
        ref = self.store.get('INVITE#' + digest, 'REF')
        if not ref:
            raise APIError('ACCESS_REVOKED', 403)
        invite = self.entity('invitations', ref['invitation_id'])
        if invite['revoked_at'] or timestamp(invite['expires_at']) <= self.now or (self.actor['guest'] and invite['permitted_role'] != 'guest'):
            raise APIError('ACCESS_REVOKED', 403)
        redemption_key = 'REDEMPTION#' + invite['id']
        receipt = dict(schema_version=1, church_id=invite['church_id'], team_id=invite['team_id'], setlist_id=invite['setlist_id'],
                       role=invite['permitted_role'], expires_at=invite['expires_at'])
        if self.get('U#' + self.actor['id'], redemption_key):
            if invite['permitted_role'] == 'guest':
                self.read_setlist(self.entity('setlists', invite['setlist_id']))
            else:
                self.member(invite['team_id'])
            return receipt
        if invite['used_count'] >= invite['max_uses']:
            raise APIError('ACCESS_REVOKED', 403)
        if invite['permitted_role'] == 'guest':
            key = 'guest_grants#' + self.actor['id'] + '#' + invite['setlist_id']
            grant = self.base(invite['team_id'], user_id=self.actor['id'], setlist_id=invite['setlist_id'], expires_at=invite['expires_at'], revoked_at=None)
            self.put('T#' + invite['team_id'], key, grant, self.get('T#' + invite['team_id'], key))
            self.put('U#' + self.actor['id'], 'GRANT#' + invite['setlist_id'], grant, self.get('U#' + self.actor['id'], 'GRANT#' + invite['setlist_id']))
        else:
            previous = self.get('T#' + invite['team_id'], 'memberships#' + self.actor['id'])
            rank = {'member': 1, 'leader': 2, 'admin': 3}
            role = previous['role'] if previous and previous['active'] and rank[previous['role']] > rank[invite['permitted_role']] else invite['permitted_role']
            self.add_member(invite['team_id'], self.actor['id'], role, text(p.get('display_name', (previous or {}).get('display_name') or 'Musician'), 120))
        self.put_entity('invitations', dict(invite, used_count=invite['used_count'] + 1, revision=invite.get('revision', 1) + 1), invite)
        self.put('U#' + self.actor['id'], redemption_key, receipt)
        return receipt

    def rpc_revoke_invitation(self, p):
        row = self.entity('invitations', p['invitation_id'])
        if p.get('expected_revision') is not None and integer(p['expected_revision'], 1) != row.get('revision', 1):
            raise APIError('REVISION_CONFLICT', 409)
        updated = dict(row, revoked_at=row.get('revoked_at') or iso(self.now), revision=row.get('revision', 1) + (0 if row.get('revoked_at') else 1))
        self.put_entity('invitations', updated, row)
        return dict(invitation_id=row['id'], team_id=row['team_id'], revoked=True, revision=updated['revision'])

    def rpc_get_team_invitations(self, p):
        team = identifier(p['team_id'])
        self.member(team, ('admin',))
        limit = integer(p.get('limit', 50), 1, 100)
        after = 'invitations#' + identifier(p['after_invitation_id']) if p.get('after_invitation_id') else None
        rows = self.store.query('T#' + team, 'invitations#', after=after, limit=limit + 1)
        results = []
        for row in rows[:limit]:
            status = 'revoked' if row.get('revoked_at') else 'expired' if timestamp(row['expires_at']) <= self.now else 'exhausted' if row['used_count'] >= row['max_uses'] else 'active'
            # The creation response is the only place an invitation's raw token is
            # returned. Management lists never contain the token or its hash.
            results.append({k: row.get(k) for k in ('id', 'team_id', 'church_id', 'permitted_role', 'setlist_id', 'expires_at',
                                                   'max_uses', 'used_count', 'revoked_at', 'created_at')})
            results[-1].update(invitation_id=row['id'], revision=row.get('revision', 1), status=status)
        _Operation(self.store, lambda: self.now, self.actor).member(team, ('admin',))
        return dict(team_id=team, invitations=results, has_more=len(rows) > limit,
                    next_invitation_id=results[-1]['id'] if len(rows) > limit and results else None)

    def rpc_revoke_guest_grant(self, p):
        s = self.entity('setlists', p['setlist_id'])
        key = 'guest_grants#' + identifier(p.get('user_id')) + '#' + s['id']
        old = self.get('T#' + s['team_id'], key)
        if old:
            self.put('T#' + s['team_id'], key, dict(old, revoked_at=iso(self.now)), old)
        return dict(revoked=True)

    def rpc_set_membership_active(self, p):
        user, team = identifier(p.get('user_id')), identifier(p['team_id'])
        if user == self.actor['id'] or not isinstance(p.get('active'), bool):
            raise APIError('ACCESS_REVOKED', 403)
        old = self.get('T#' + team, 'memberships#' + user)
        if not old:
            raise APIError('ACCESS_REVOKED', 403)
        if p.get('expected_revision') is not None and integer(p['expected_revision'], 1) != old.get('revision', 1):
            raise APIError('REVISION_CONFLICT', 409)
        self.advance_team_authority(team)
        self.require_remaining_admin(team, old, active=p['active'])
        row = dict(old, active=p['active'], revision=old.get('revision', 1) + (1 if old['active'] != p['active'] else 0))
        self.put('T#' + team, 'memberships#' + user, row, old)
        return row

    def lease(self, s):
        return self.get('T#' + s['team_id'], 'editor_leases#' + s['id'])

    def controller(self, s, device, epoch):
        device, epoch = identifier(device), integer(epoch)
        row = self.lease(s)
        self.member(s['team_id'], ('leader', 'admin'))
        if not row or row['controller_user_id'] != self.actor['id'] or row['device_id'] != device or row['epoch'] != epoch or timestamp(row['expires_at']) <= self.now:
            raise APIError('STALE_CONTROLLER', 409)
        self.check('T#' + s['team_id'], 'editor_leases#' + s['id'], row)
        self.check('T#' + s['team_id'], 'setlists#' + s['id'], s)
        return row

    def rpc_acquire_editor(self, p):
        s = self.entity('setlists', p['setlist_id'])
        old, device = self.lease(s), identifier(p.get('device_id'))
        if integer(p.get('expected_epoch')) != old['epoch']:
            raise APIError('STALE_CONTROLLER', 409)
        active = old['controller_user_id'] is not None and timestamp(old['expires_at']) > self.now
        same = old['controller_user_id'] == self.actor['id'] and old['device_id'] == device
        if active and not same and p.get('explicit_takeover') is not True:
            raise APIError('STALE_CONTROLLER', 409)
        row = dict(old, controller_user_id=self.actor['id'], device_id=device,
                   epoch=old['epoch'] if active and same else old['epoch'] + 1,
                   expires_at=iso(self.now + timedelta(seconds=60)), active=True)
        self.put('T#' + s['team_id'], 'editor_leases#' + s['id'], row, old)
        return row

    def rpc_renew_editor(self, p):
        s = self.entity('setlists', p['setlist_id'])
        old = self.controller(s, p.get('device_id'), p.get('epoch'))
        row = dict(old, expires_at=iso(self.now + timedelta(seconds=60)), active=True)
        self.put('T#' + s['team_id'], 'editor_leases#' + s['id'], row, old)
        return row

    def rpc_release_editor(self, p):
        s = self.entity('setlists', p['setlist_id'])
        old = self.controller(s, p.get('device_id'), p.get('epoch'))
        row = dict(old, controller_user_id=None, device_id=None, expires_at=iso(self.now), active=False)
        self.put('T#' + s['team_id'], 'editor_leases#' + s['id'], row, old)
        return row

    def query_pending(self, team, prefix):
        rows = self.store.query('T#' + team, prefix)
        pending = [w['value'] for (pk, sk), w in self.writes.items() if pk == 'T#' + team and sk.startswith(prefix) and w['op'] == 'put']
        # Immutable IDs or layer keys identify a pending replacement.
        ids = {r.get('id', r.get('layer_id')) for r in pending}
        return [r for r in rows if r.get('id', r.get('layer_id')) not in ids] + pending

    def snapshot(self, session):
        s = self.entity('setlists', session['setlist_id'])
        m = self.read_setlist(s)
        calls = sorted([c for c in self.query_pending(session['team_id'], 'live_calls#') if c['session_id'] == session['id'] and c['sequence'] <= session['latest_sequence']], key=lambda c: c['sequence'], reverse=True)
        heads = []
        for head in self.query_pending(s['team_id'], 'annotation_heads#'):
            if head['scope'] == 'team' and head['setlist_id'] == s['id'] and self.layer_readable(self.entity('annotation_layers', head['layer_id'])):
                heads.append(head)
        return dict(session, schema_version=1, session_id=session['id'], controller_epoch=self.lease(s)['epoch'],
                    latest_call=calls[0] if calls else None, history=calls[:10], annotation_heads=heads,
                    access=dict(scope='member' if m else 'guest', can_control=bool(m and m['role'] in ('leader', 'admin')), can_write_personal=bool(m)))

    def rpc_get_session_snapshot(self, p):
        return self.snapshot(self.entity('live_sessions', p['session_id']))

    def rpc_start_session(self, p):
        s = self.entity('setlists', p['setlist_id'])
        self.controller(s, p.get('device_id'), p.get('epoch'))
        if s['live_session_id']:
            existing = self.entity('live_sessions', s['live_session_id'])
            if existing['status'] == 'LIVE':
                raise APIError('SESSION_ACTIVE', 409)
        row = self.base(s['team_id'], id=str(uuid.uuid4()), setlist_id=s['id'], status='LIVE', latest_sequence=0,
                        latest_call_id=None, state_revision=1, created_at=iso(self.now), ended_at=None)
        self.put_entity('live_sessions', row)
        self.put_entity('setlists', dict(s, live_session_id=row['id']), s)
        return self.snapshot(row)

    def rpc_publish_call(self, p):
        session = self.entity('live_sessions', p['session_id'])
        s = self.entity('setlists', session['setlist_id'])
        lease = self.controller(s, p.get('device_id'), p.get('expected_controller_epoch'))
        if session['status'] != 'LIVE':
            raise APIError('SESSION_ENDED', 409)
        if integer(p.get('expected_latest_sequence')) != session['latest_sequence']:
            raise APIError('STALE_CALL', 409)
        chart = self.entity('chart_versions', p.get('team_chart_version_id'))
        if chart['team_id'] != s['team_id'] or chart['song_id'] != identifier(p.get('song_id')):
            raise APIError('FILE_NOT_READY', 409)
        item_id, key = identifier(p.get('performance_item_id')), musical_key(p.get('performance_key'))
        item = next((i for i in s['items'] if i['id'] == item_id), None)
        if item is None:
            draft = p.get('ad_hoc_draft', p.get('ad_hoc_draft_optional'))
            if not isinstance(draft, dict) or identifier(draft.get('id')) != item_id:
                raise APIError('ACCESS_REVOKED', 403)
            registry = self.get('T#' + s['team_id'], 'ITEM_REGISTRY')
            bindings = dict(registry['items']) if registry else {}
            if item_id in bindings:
                raise APIError('ACCESS_REVOKED', 403)
            item = self.base(s['team_id'], id=item_id, setlist_id=s['id'], song_id=chart['song_id'], team_chart_version_id=chart['id'],
                             performance_key=key, position=None, kind='ad_hoc', revision=1, active=True)
            bindings[item_id] = s['id']
            self.put('T#' + s['team_id'], 'ITEM_REGISTRY', dict(items=bindings), registry)
            self.put_entity('setlists', dict(s, items=s['items'] + [item]), s)
        if not item['active'] or item['song_id'] != chart['song_id']:
            raise APIError('ACCESS_REVOKED', 403)
        call = self.base(s['team_id'], id=str(uuid.uuid4()), call_id=None, session_id=session['id'], setlist_id=s['id'],
                         sequence=session['latest_sequence'] + 1, command_id=identifier(p['command_id']), performance_item_id=item_id,
                         song_id=chart['song_id'], team_chart_version_id=chart['id'], performance_key=key, actor_user_id=self.actor['id'],
                         controller_epoch=lease['epoch'], created_at=iso(self.now))
        call['call_id'] = call['id']
        self.put_entity('live_calls', call)
        updated = dict(session, latest_sequence=call['sequence'], latest_call_id=call['id'], state_revision=session['state_revision'] + 1)
        self.put_entity('live_sessions', updated, session)
        return dict(schema_version=1, team_id=s['team_id'], call=call, latest_call=call, latest_sequence=call['sequence'], snapshot=self.snapshot(updated))

    def rpc_acknowledge_open(self, p):
        session = self.entity('live_sessions', p['session_id'])
        call = self.entity('live_calls', p.get('call_id'))
        chart = self.entity('chart_versions', p.get('selected_chart_version_id'))
        if call['session_id'] != session['id'] or chart['song_id'] != call['song_id'] or chart['team_id'] != session['team_id'] or not self.chart_readable(chart):
            raise APIError('ACCESS_REVOKED', 403)
        device = identifier(p.get('device_id'))
        sk = 'participants#' + session['id'] + '#' + self.actor['id'] + '#' + device
        old = self.get('T#' + session['team_id'], sk)
        row = self.base(session['team_id'], session_id=session['id'], setlist_id=session['setlist_id'], user_id=self.actor['id'], device_id=device,
                        last_seen_at=iso(self.now), latest_received_call_id=session['latest_call_id'], last_opened_call_id=call['id'],
                        selected_chart_version_id=chart['id'], rendered_at=iso(self.now))
        self.put('T#' + session['team_id'], sk, row, old)
        return dict(schema_version=1, call_id=call['id'], selected_chart_version_id=chart['id'], opened=True,
                    is_latest=session['latest_call_id'] == call['id'], meaning='rendered_not_ready')

    def rpc_end_session(self, p):
        session = self.entity('live_sessions', p['session_id'])
        s = self.entity('setlists', session['setlist_id'])
        self.controller(s, p.get('device_id'), p.get('epoch'))
        row = dict(session, status='ENDED', ended_at=iso(self.now), state_revision=session['state_revision'] + 1)
        self.put_entity('live_sessions', row, session)
        self.put_entity('setlists', dict(s, live_session_id=None), s)
        return self.snapshot(row)

    def identity(self, value):
        if not isinstance(value, dict):
            raise APIError('INVALID_INPUT')
        chart = self.entity('chart_versions', value.get('chart_version_id'))
        if chart['church_id'] != identifier(value.get('church_id')) or (value.get('team_id') and chart['team_id'] != identifier(value['team_id'])) or not self.chart_readable(chart):
            raise APIError('ACCESS_REVOKED', 403)
        page = integer(value.get('page_index'), 0, chart['page_count'] - 1)
        scope = value.get('scope')
        if scope == 'personal':
            self.member(chart['team_id'])
            if identifier(value.get('owner_user_id')) != self.actor['id'] or value.get('performance_item_id') is not None:
                raise APIError('ACCESS_REVOKED', 403)
            owner, item_id, setlist_id = self.actor['id'], None, None
        elif scope == 'team':
            item_id = identifier(value.get('performance_item_id'))
            item, s = self.item(item_id, chart['team_id'])
            self.read_setlist(s)
            if value.get('owner_user_id') is not None or item['song_id'] != chart['song_id']:
                raise APIError('ACCESS_REVOKED', 403)
            owner, setlist_id = None, s['id']
        else:
            raise APIError('INVALID_INPUT')
        canonical = self.base(chart['team_id'], chart_version_id=chart['id'], page_index=page, scope=scope,
                              owner_user_id=owner, performance_item_id=item_id, setlist_id=setlist_id)
        canonical['id'] = str(uuid.uuid5(uuid.NAMESPACE_URL, 'worshipcue:layer:' + token(canonical)))
        return canonical, chart

    def rpc_get_annotation_head(self, p):
        if p.get('layer_id'):
            layer = self.entity('annotation_layers', p['layer_id'])
        else:
            layer, _ = self.identity(p.get('layer_identity'))
        return self.get('T#' + layer['team_id'], 'annotation_heads#' + layer['id'])

    def rpc_save_annotation_revision(self, p):
        layer, chart = self.identity(p.get('layer_identity'))
        if layer['scope'] == 'team':
            item, s = self.item(layer['performance_item_id'], layer['team_id'])
            self.controller(s, p.get('device_id'), p.get('controller_epoch_if_team'))
            if item['team_chart_version_id'] != chart['id'] or not item['active']:
                raise APIError('VERSION_MISMATCH', 409)
        canonical = geometry(p.get('geometry'))
        if canonical != chart['page_manifest'][layer['page_index']]:
            raise APIError('INVALID_PAGE')
        native, preview = self.entity('assets', p.get('native_asset_id')), self.entity('assets', p.get('preview_asset_id'))
        for asset, kind in [(native, 'native'), (preview, 'preview')]:
            if asset['type'] != kind or asset['status'] != 'verified' or asset['owner_user_id'] != self.actor['id'] or asset['team_id'] != layer['team_id']:
                raise APIError('FILE_NOT_READY', 409)
        old = self.get('T#' + layer['team_id'], 'annotation_heads#' + layer['id'])
        parent = integer(p.get('parent_revision'))
        if parent != (old['revision_number'] if old else 0):
            raise APIError('REVISION_CONFLICT', 409)
        if old is None:
            self.put_entity('annotation_layers', layer)
        revision_id = str(uuid.uuid4())
        row = dict(layer, id=revision_id, revision_id=revision_id, layer_id=layer['id'], revision_number=parent + 1,
                   parent_revision=parent, command_id=identifier(p['command_id']), native_format='pencilkit',
                   native_asset_id=native['id'], native_sha256=native['sha256'], native_bytes=native['bytes'], native_storage_key=native['storage_key'],
                   preview_asset_id=preview['id'], preview_sha256=preview['sha256'], preview_bytes=preview['bytes'], preview_storage_key=preview['storage_key'],
                   geometry=canonical, device_id=identifier(p.get('device_id')), editor_user_id=self.actor['id'], created_at=iso(self.now))
        self.put_entity('annotation_revisions', row)
        self.put('T#' + layer['team_id'], 'annotation_heads#' + layer['id'], row, old)
        for asset in (native, preview):
            key = 'ACL#' + layer['id']
            previous = self.get('ASSET#' + asset['id'], key)
            if not previous:
                self.put('ASSET#' + asset['id'], key, dict(layer_id=layer['id']))
        return row

    def rpc_preflight_manifest(self, p):
        s = self.entity('setlists', p['setlist_id'])
        self.read_setlist(s)
        chart_ids = {i['team_chart_version_id'] for i in s['items'] if i['active'] and i['kind'] in ('planned', 'standby')}
        if self.can_member(s['team_id']):
            song_ids = {i['song_id'] for i in s['items'] if i['active']}
            chart_ids |= {v['preferred_version_id'] for v in self.store.query('T#' + s['team_id'], 'personal_preferences#' + self.actor['id'] + '#') if v['song_id'] in song_ids}
        chart_ids |= {c['team_chart_version_id'] for c in self.store.query('T#' + s['team_id'], 'live_calls#') if c['setlist_id'] == s['id']}
        heads = [h for h in self.store.query('T#' + s['team_id'], 'annotation_heads#')
                 if h['scope'] == 'team' and h['setlist_id'] == s['id'] and h['chart_version_id'] in chart_ids
                 and self.layer_readable(self.entity('annotation_layers', h['layer_id']))]
        return dict(schema_version=1, team_id=s['team_id'], setlist_id=s['id'], setlist_revision=s['revision'],
                    charts=[self.entity('chart_versions', c) for c in sorted(chart_ids) if self.chart_readable(self.entity('chart_versions', c))], annotation_heads=heads)

    def chat_scope(self, p):
        team = identifier(p.get('team_id'))
        self.member(team)
        setlist = identifier(p['setlist_id']) if p.get('setlist_id') else None
        if setlist and self.entity('setlists', setlist)['team_id'] != team:
            raise APIError('ACCESS_REVOKED', 403)
        return team, setlist, 'SETLIST#' + setlist if setlist else 'TEAM'

    def chat_head(self, team, room):
        return self.get('T#' + team, 'CHAT_HEAD#' + room)

    def advance_chat(self, team, room, message_id):
        old = self.chat_head(team, room)
        revision = old['revision'] + 1 if old else 1
        # Only new sends have creation indexes; older events retain their original ordering.
        self.put('T#' + team, 'CHAT_HEAD#' + room,
                 dict(old or {}, revision=revision, creation_index_from=(old or {}).get('creation_index_from', revision)), old)
        self.put('T#' + team, 'CHAT_DELTA#' + room + '#' + f'{revision:016d}', dict(revision=revision, message_id=message_id))
        return revision

    def chat_message(self, team, room, message):
        value = self.get('T#' + team, 'chat_messages#' + room + '#' + identifier(message))
        if not value:
            raise APIError('ACCESS_REVOKED', 403)
        return value

    def chat_blocks(self, team):
        pk, sk = 'U#' + self.actor['id'], 'CHAT_BLOCKS#' + team
        value = self.get(pk, sk)
        self.check(pk, sk, value)
        return value or dict(users=[], revision=0)

    def visible_chat_message(self, message, blocked=()):
        hidden = message['author_id'] in blocked and message['author_id'] != self.actor['id']
        row = dict(message, chart_version_id=message.get('chart_version_id'), chart_title=message.get('chart_title'))
        if hidden or row['deleted']:
            row.update(body='', chart_version_id=None, chart_title=None)
        if hidden:
            row['hidden'] = True
        return row

    def finish_chat_read(self, team, block_revision=None, moderator=False):
        # Long bounded reads must not return after membership or a local block changed.
        fresh = _Operation(self.store, lambda: self.now, self.actor)
        fresh.member(team, ('leader', 'admin') if moderator else None)
        if block_revision is not None and fresh.chat_blocks(team).get('revision', 0) != block_revision:
            raise APIError('REVISION_CONFLICT', 409)

    def rpc_get_chat_snapshot(self, p):
        team, setlist, room = self.chat_scope(p)
        after = integer(p.get('after_revision', 0))
        blocked = self.chat_blocks(team)
        block_revision = blocked.get('revision', 0)
        reset = integer(p.get('known_block_revision', p.get('block_revision', 0))) != block_revision
        if reset:
            after = 0
        head = self.chat_head(team, room)
        latest = head['revision'] if head else 0
        if after > latest:
            raise APIError('REVISION_CONFLICT', 409)
        pref = self.get('T#' + team, 'CHAT_PREF#' + self.actor['id'] + '#' + room) or {}
        prefix = 'CHAT_DELTA#' + room + '#'
        changes = self.store.query('T#' + team, prefix, after=prefix + f'{after:016d}',
                                   through=prefix + f'{latest:016d}', limit=101) if latest > after else []
        page = changes[:100]
        # Advance over hidden messages as well so a block cannot trap pagination.
        cursor = page[-1]['revision'] if len(changes) > 100 else latest
        messages = {}
        for change in page:
            m = self.chat_message(team, room, change['message_id'])
            # Fetch only the current text: an old delivery event must not resurrect a deleted body.
            if after < m['revision'] <= cursor:
                messages[m['id']] = self.visible_chat_message(m, blocked['users'])
        self.finish_chat_read(team, block_revision)
        return dict(team_id=team, setlist_id=setlist, revision=cursor, latest_revision=latest, has_more=len(changes) > 100,
                    read_revision=pref.get('read_revision', 0), muted=pref.get('muted', False),
                    blocked_author_ids=blocked['users'], block_revision=block_revision, reset=reset, full_reset=reset, fullreset=reset,
                    messages=sorted(messages.values(), key=lambda m: m['revision']))

    def rpc_send_chat_message(self, p):
        team, setlist, room = self.chat_scope(p)
        body = text(p.get('body'), 4000)
        reply = identifier(p['reply_to_id']) if p.get('reply_to_id') else None
        if reply and self.chat_message(team, room, reply)['deleted']:
            raise APIError('MESSAGE_DELETED', 409)
        chart_id = identifier(p['chart_version_id']) if p.get('chart_version_id') else None
        chart_title = None
        if chart_id:
            chart = self.entity('chart_versions', chart_id)
            if chart['team_id'] != team:
                raise APIError('ACCESS_REVOKED', 403)
            if not chart.get('published_at'):
                raise APIError('FILE_NOT_READY', 409)
            asset = self.entity('assets', chart['pdf_asset_id'])
            song = self.entity('songs', chart['song_id'])
            if asset['team_id'] != team or asset['type'] != 'pdf' or asset['status'] != 'verified' or song['team_id'] != team:
                raise APIError('FILE_NOT_READY', 409)
            chart_title = song['canonical_title']
        member = self.member(team)
        message_id = str(uuid.uuid4())
        revision = self.advance_chat(team, room, message_id)
        row = self.base(team, id=message_id, author_id=self.actor['id'], author_name=member.get('display_name', ''),
                        body=body, revision=revision, created_revision=revision, created_at=iso(self.now), edited_at=None,
                        reply_to_id=reply, setlist_id=setlist, deleted=False, pinned=False,
                        chart_version_id=chart_id, chart_title=chart_title)
        self.put('T#' + team, 'chat_messages#' + room + '#' + row['id'], row)
        self.put('T#' + team, 'CHAT_CREATED#' + room + '#' + f'{revision:016d}', dict(revision=revision, message_id=message_id))
        self.put('T#' + team, 'CHAT_REF#' + message_id, dict(room=room, setlist_id=setlist))
        return row

    def edit_message(self, p, delete=False):
        team, _, room = self.chat_scope(p)
        old = self.chat_message(team, room, p.get('message_id'))
        member = self.member(team)
        if old['author_id'] != self.actor['id'] and not (delete and member['role'] in ('leader', 'admin')):
            raise APIError('ACCESS_REVOKED', 403)
        if old['revision'] != integer(p.get('expected_revision')):
            raise APIError('REVISION_CONFLICT', 409)
        if old['deleted']:
            raise APIError('MESSAGE_DELETED', 409)
        row = dict(old, body='' if delete else text(p.get('body'), 4000), deleted=delete,
                   pinned=False if delete else old['pinned'], edited_at=iso(self.now), revision=self.advance_chat(team, room, old['id']))
        if delete:
            row.update(chart_version_id=None, chart_title=None)
        self.put('T#' + team, 'chat_messages#' + room + '#' + old['id'], row, old)
        return self.visible_chat_message(row, self.chat_blocks(team)['users'])

    def rpc_edit_chat_message(self, p):
        return self.edit_message(p)

    def rpc_delete_chat_message(self, p):
        return self.edit_message(p, delete=True)

    def chat_preference(self, p, read=False):
        team, _, room = self.chat_scope(p)
        key = 'CHAT_PREF#' + self.actor['id'] + '#' + room
        old = self.get('T#' + team, key)
        row = old or dict(team_id=team, read_revision=0, muted=False)
        if read:
            value = integer(p.get('revision'))
            if value > (self.chat_head(team, room) or {'revision': 0})['revision']:
                raise APIError('REVISION_CONFLICT', 409)
            row = dict(row, read_revision=max(row['read_revision'], value))
        else:
            if not isinstance(p.get('muted'), bool):
                raise APIError('INVALID_INPUT')
            row = dict(row, muted=p['muted'])
        self.put('T#' + team, key, row, old)
        return row

    def rpc_mark_chat_read(self, p):
        return self.chat_preference(p, read=True)

    def rpc_mute_chat(self, p):
        return self.chat_preference(p)

    def rpc_pin_chat_message(self, p):
        team, _, room = self.chat_scope(p)
        self.member(team, ('leader', 'admin'))
        if not isinstance(p.get('pinned'), bool):
            raise APIError('INVALID_INPUT')
        old = self.chat_message(team, room, p.get('message_id'))
        if old['deleted']:
            raise APIError('MESSAGE_DELETED', 409)
        if p.get('expected_revision') is not None and old['revision'] != integer(p['expected_revision']):
            raise APIError('REVISION_CONFLICT', 409)
        if old['pinned'] == p['pinned']:
            self.check('T#' + team, 'chat_messages#' + room + '#' + old['id'], old)
            return self.visible_chat_message(old, self.chat_blocks(team)['users'])
        row = dict(old, pinned=p['pinned'], revision=self.advance_chat(team, room, old['id']))
        self.put('T#' + team, 'chat_messages#' + room + '#' + old['id'], row, old)
        return self.visible_chat_message(row, self.chat_blocks(team)['users'])

    def rpc_report_chat_message(self, p):
        team, setlist, room = self.chat_scope(p)
        message = self.chat_message(team, room, p.get('message_id'))
        report_id = str(uuid.uuid4())
        row = dict(id=report_id, team_id=team, message_id=message['id'], reporter_id=self.actor['id'],
                   reason=text(p.get('reason'), 1000), created_at=iso(self.now), status='open', revision=1,
                   setlist_id=setlist, room=room, author_id=message['author_id'])
        self.put('T#' + team, 'CHAT_REPORT#' + report_id, row)
        return dict(team_id=team, report_id=report_id, reported=True, revision=1)

    def rpc_block_chat_member(self, p):
        team = identifier(p['team_id'])
        user = identifier(p.get('user_id'))
        if user == self.actor['id'] or not isinstance(p.get('blocked'), bool):
            raise APIError('INVALID_INPUT')
        old = self.get('U#' + self.actor['id'], 'CHAT_BLOCKS#' + team)
        blocked = set(old['users'] if old else [])
        target = self.get('T#' + team, 'memberships#' + user)
        # Removal revokes content, but must not trap an owner's existing local block.
        if (not target or not target['active']) and (p['blocked'] or user not in blocked):
            raise APIError('ACCESS_REVOKED', 403)
        self.check('T#' + team, 'memberships#' + user, target)
        changed = (user in blocked) != p['blocked']
        blocked.add(user) if p['blocked'] else blocked.discard(user)
        revision = (old or {}).get('revision', 0) + (1 if changed else 0)
        self.put('U#' + self.actor['id'], 'CHAT_BLOCKS#' + team, dict(users=sorted(blocked), revision=revision), old)
        return dict(team_id=team, user_id=user, blocked=p['blocked'], block_revision=revision, blocked_author_ids=sorted(blocked))

    def chat_unread(self, team, room, head, read, blocked, budget):
        latest = (head or {}).get('revision', 0)
        if latest <= read:
            return 0
        cutoff = (head or {}).get('creation_index_from', latest + 1) - 1
        creations = {}
        ranges = []
        if read < cutoff:
            # Legacy deltas contain every mutation; only the first event is a creation.
            ranges.append(('CHAT_DELTA#' + room + '#', 0, cutoff, True))
        if latest > max(read, cutoff):
            ranges.append(('CHAT_CREATED#' + room + '#', max(read, cutoff), latest, False))
        for prefix, after, through, legacy in ranges:
            rows = self.store.query('T#' + team, prefix, after=prefix + f'{after:016d}',
                                    through=prefix + f'{through:016d}', limit=budget[0] + 1)
            if len(rows) > budget[0]:
                budget[0] = 0
                return None
            budget[0] -= len(rows)
            for row in rows:
                if legacy:
                    creations.setdefault(row['message_id'], row['revision'])
                else:
                    creations[row['message_id']] = row['revision']
        count = 0
        for message_id, created in creations.items():
            if created > read:
                message = self.chat_message(team, room, message_id)
                if not message['deleted'] and message['author_id'] != self.actor['id'] and message['author_id'] not in blocked:
                    count += 1
        return count

    def rpc_get_chat_rooms(self, p):
        team = identifier(p['team_id'])
        self.member(team)
        limit = integer(p.get('room_limit', 50), 2, 100)
        after = identifier(p['after_setlist_id']) if p.get('after_setlist_id') else None
        if after and self.entity('setlists', after)['team_id'] != team:
            raise APIError('ACCESS_REVOKED', 403)
        count = limit if after else limit - 1
        setlists = self.store.query('T#' + team, 'setlists#', after='setlists#' + after if after else None, limit=count + 1)
        page = setlists[:count]
        rows = [(None, 'Team chat')] if not after else []
        rows += [(s['id'], s['title']) for s in page]
        blocks = self.chat_blocks(team)
        budget, rooms = [CHAT_UNREAD_BUDGET], []
        for setlist, title in rows:
            room = 'SETLIST#' + setlist if setlist else 'TEAM'
            pref = self.get('T#' + team, 'CHAT_PREF#' + self.actor['id'] + '#' + room) or {}
            head = self.chat_head(team, room)
            unread = self.chat_unread(team, room, head, pref.get('read_revision', 0), blocks['users'], budget)
            rooms.append(dict(setlist_id=setlist, title=title, latest_revision=(head or {}).get('revision', 0),
                              read_revision=pref.get('read_revision', 0), unread_count=unread,
                              unread_complete=unread is not None, muted=pref.get('muted', False)))
        self.finish_chat_read(team, blocks.get('revision', 0))
        return dict(team_id=team, rooms=rooms, has_more=len(setlists) > count,
                    next_setlist_id=page[-1]['id'] if len(setlists) > count and page else None,
                    blocked_author_ids=blocks['users'], block_revision=blocks.get('revision', 0))

    def chat_report(self, team, report_id, blocked=None):
        report = self.get('T#' + team, 'CHAT_REPORT#' + identifier(report_id))
        if not report or report['team_id'] != team:
            raise APIError('ACCESS_REVOKED', 403)
        ref = self.get('T#' + team, 'CHAT_REF#' + report['message_id'])
        room = report.get('room') or (ref or {}).get('room')
        if room is None:
            # Old reports had no room locator; bounded exact-team recovery only.
            messages = self.store.query('T#' + team, 'chat_messages#', limit=CHAT_REFERENCE_BUDGET + 1)
            found = next((m for m in messages if m['id'] == report['message_id']), None)
            if not found:
                raise APIError('RESOURCE_LIMIT', 413) if len(messages) > CHAT_REFERENCE_BUDGET else APIError('ACCESS_REVOKED', 403)
            room = 'SETLIST#' + found['setlist_id'] if found.get('setlist_id') else 'TEAM'
        setlist = room.split('#', 1)[1] if room.startswith('SETLIST#') else None
        if setlist and self.entity('setlists', setlist)['team_id'] != team:
            raise APIError('ACCESS_REVOKED', 403)
        message = self.chat_message(team, room, report['message_id'])
        if blocked is None:
            blocked = self.chat_blocks(team)['users']
        return dict(report, report_id=report['id'], revision=report.get('revision', 1), status=report.get('status', 'open'),
                    setlist_id=setlist, message=self.visible_chat_message(message, blocked))

    def rpc_get_chat_reports(self, p):
        team = identifier(p['team_id'])
        self.member(team, ('leader', 'admin'))
        status = p.get('status', 'open')
        if status not in ('open', 'resolved', 'dismissed', 'all'):
            raise APIError('INVALID_INPUT')
        limit = integer(p.get('limit', 50), 1, 100)
        after = identifier(p['after_report_id']) if p.get('after_report_id') else None
        if after:
            self.chat_report(team, after)
        records = self.store.query('T#' + team, 'CHAT_REPORT#', after='CHAT_REPORT#' + after if after else None, limit=limit + 1)
        page = records[:limit]
        blocks = self.chat_blocks(team)
        reports = [self.chat_report(team, r['id'], blocks['users']) for r in page if status == 'all' or r.get('status', 'open') == status]
        self.finish_chat_read(team, blocks.get('revision', 0), moderator=True)
        return dict(team_id=team, reports=reports, has_more=len(records) > limit,
                    next_report_id=page[-1]['id'] if len(records) > limit else None)

    def rpc_resolve_chat_report(self, p):
        team = identifier(p['team_id'])
        self.member(team, ('leader', 'admin'))
        report = self.chat_report(team, p.get('report_id'))
        status = p.get('status')
        if status not in ('resolved', 'dismissed'):
            raise APIError('INVALID_INPUT')
        if integer(p.get('expected_revision'), 1) != report['revision']:
            raise APIError('REVISION_CONFLICT', 409)
        key = 'CHAT_REPORT#' + report['id']
        old = self.get('T#' + team, key)
        if old.get('status', 'open') != 'open':
            raise APIError('REPORT_CLOSED', 409)
        row = dict(old, status=status, revision=report['revision'] + 1, resolved_by=self.actor['id'], resolved_at=iso(self.now))
        self.put('T#' + team, key, row, old)
        return dict(report, **row)
