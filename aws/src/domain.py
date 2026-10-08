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


READS = {'get_session_snapshot', 'get_annotation_head', 'preflight_manifest', 'get_team_roster', 'get_chat_snapshot', 'get_team_catalog'}
COMMANDS = {'create_song', 'publish_chart_version', 'create_setlist', 'save_setlist', 'start_session', 'publish_call',
            'end_session', 'save_annotation_revision', 'send_chat_message', 'edit_chat_message', 'delete_chat_message'}
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
            return [m for m in self.memberships() if team is None or m['team_id'] == identifier(team)]
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

        if name == 'create_church_and_default_team':
            if self.actor['guest']:
                raise APIError('ACCESS_REVOKED', 403)
        elif name == 'create_team':
            self.church_admin(identifier(p.get('church_id')))
        elif name == 'redeem_invitation':
            pass
        elif name == 'get_team_catalog':
            team = identifier(p.get('team_id'))
            context({'team_id': team})
            if not self.can_member(team) and not self.authorized_setlists(team):
                raise APIError('ACCESS_REVOKED', 403)
        elif name in ('create_song', 'stage_asset', 'create_setlist', 'create_invitation', 'get_team_roster',
                      'set_membership_active', 'get_chat_snapshot', 'send_chat_message', 'edit_chat_message',
                      'delete_chat_message', 'mark_chat_read', 'mute_chat', 'pin_chat_message', 'report_chat_message', 'block_chat_member'):
            role = ('leader', 'admin') if name in ('create_song', 'create_setlist') else ('admin',) if name in ('create_invitation', 'set_membership_active') else None
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
                return previous['result']
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
                        _Operation(self.store, lambda: self.now, self.actor).authorize(name, p)
                        return previous['result']
                raise
        return result

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
        row = self.base(team, user_id=user, role=role, active=True, display_name=display_name,
                        created_at=old['created_at'] if old else iso(self.now))
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
        self.add_member(team, self.actor['id'], 'admin')
        return dict(schema_version=1, church_id=church, team_id=team, role='admin')

    def rpc_create_team(self, p):
        church, team = identifier(p.get('church_id')), str(uuid.uuid4())
        self.put_entity('teams', dict(id=team, church_id=church, team_id=team, name=text(p.get('display_name'), 120)))
        self.put('C#' + church, 'TEAM#' + team, dict(team_id=team))
        self.add_member(team, self.actor['id'], 'admin')
        return dict(schema_version=1, church_id=church, team_id=team, role='admin')

    def rpc_get_team_roster(self, p):
        team = identifier(p['team_id'])
        self.member(team)
        return {'team_id': team, 'members': [m for m in self.store.query('T#' + team, 'memberships#') if m['active']]}

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
                        inviter=self.actor['id'], expires_at=iso(expiry), max_uses=integer(p.get('max_uses', 1), 1, 50), used_count=0, revoked_at=None)
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
            self.add_member(invite['team_id'], self.actor['id'], role, text(p.get('display_name', 'Musician'), 120))
        self.put_entity('invitations', dict(invite, used_count=invite['used_count'] + 1), invite)
        self.put('U#' + self.actor['id'], redemption_key, receipt)
        return receipt

    def rpc_revoke_invitation(self, p):
        row = self.entity('invitations', p['invitation_id'])
        self.put_entity('invitations', dict(row, revoked_at=iso(self.now)), row)
        return dict(invitation_id=row['id'], revoked=True)

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
        self.put('T#' + team, 'memberships#' + user, dict(old, active=p['active']), old)
        return dict(user_id=user, active=p['active'], team_id=team)

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
        self.put('T#' + team, 'CHAT_HEAD#' + room, dict(revision=revision), old)
        self.put('T#' + team, 'CHAT_DELTA#' + room + '#' + f'{revision:016d}', dict(revision=revision, message_id=message_id))
        return revision

    def chat_message(self, team, room, message):
        value = self.get('T#' + team, 'chat_messages#' + room + '#' + identifier(message))
        if not value:
            raise APIError('ACCESS_REVOKED', 403)
        return value

    def rpc_get_chat_snapshot(self, p):
        team, setlist, room = self.chat_scope(p)
        after = integer(p.get('after_revision', 0))
        head = self.chat_head(team, room)
        latest = head['revision'] if head else 0
        if after > latest:
            raise APIError('REVISION_CONFLICT', 409)
        pref = self.get('T#' + team, 'CHAT_PREF#' + self.actor['id'] + '#' + room) or {}
        blocked = self.get('U#' + self.actor['id'], 'CHAT_BLOCKS#' + team) or {'users': []}
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
            if after < m['revision'] <= cursor and (m['author_id'] not in blocked['users'] or m['author_id'] == self.actor['id']):
                messages[m['id']] = m
        return dict(team_id=team, setlist_id=setlist, revision=cursor, latest_revision=latest, has_more=len(changes) > 100,
                    read_revision=pref.get('read_revision', 0), muted=pref.get('muted', False),
                    messages=sorted(messages.values(), key=lambda m: m['revision']))

    def rpc_send_chat_message(self, p):
        team, setlist, room = self.chat_scope(p)
        body = text(p.get('body'), 4000)
        reply = identifier(p['reply_to_id']) if p.get('reply_to_id') else None
        if reply and self.chat_message(team, room, reply)['deleted']:
            raise APIError('MESSAGE_DELETED', 409)
        member = self.member(team)
        message_id = str(uuid.uuid4())
        row = self.base(team, id=message_id, author_id=self.actor['id'], author_name=member.get('display_name', ''),
                        body=body, revision=self.advance_chat(team, room, message_id), created_at=iso(self.now), edited_at=None,
                        reply_to_id=reply, setlist_id=setlist, deleted=False, pinned=False)
        self.put('T#' + team, 'chat_messages#' + room + '#' + row['id'], row)
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
        self.put('T#' + team, 'chat_messages#' + room + '#' + old['id'], row, old)
        return row

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
        row = dict(old, pinned=p['pinned'], revision=self.advance_chat(team, room, old['id']))
        self.put('T#' + team, 'chat_messages#' + room + '#' + old['id'], row, old)
        return row

    def rpc_report_chat_message(self, p):
        team, _, room = self.chat_scope(p)
        message = self.chat_message(team, room, p.get('message_id'))
        report_id = str(uuid.uuid4())
        row = dict(id=report_id, team_id=team, message_id=message['id'], reporter_id=self.actor['id'],
                   reason=text(p.get('reason'), 1000), created_at=iso(self.now), status='open')
        self.put('T#' + team, 'CHAT_REPORT#' + report_id, row)
        return dict(team_id=team, report_id=report_id, reported=True)

    def rpc_block_chat_member(self, p):
        team = identifier(p['team_id'])
        user = identifier(p.get('user_id'))
        if user == self.actor['id'] or not isinstance(p.get('blocked'), bool):
            raise APIError('INVALID_INPUT')
        target = self.get('T#' + team, 'memberships#' + user)
        if not target or not target['active']:
            raise APIError('ACCESS_REVOKED', 403)
        old = self.get('U#' + self.actor['id'], 'CHAT_BLOCKS#' + team)
        blocked = set(old['users'] if old else [])
        blocked.add(user) if p['blocked'] else blocked.discard(user)
        self.put('U#' + self.actor['id'], 'CHAT_BLOCKS#' + team, dict(users=sorted(blocked)), old)
        return dict(team_id=team, user_id=user, blocked=p['blocked'])
