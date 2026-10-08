#!/usr/bin/env python3
"""Run real AWS qualification with isolated synthetic data; never print credentials.

Requires an explicitly ready development stack and an external private state directory.
Uses the existing AWS CLI, approved pypdf vendor, and native Swift WebSockets.
No deployment, account setup, dependency installation, or resource deletion occurs here.
"""
import argparse
import base64
import hashlib
import io
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import subprocess
import sys
import time
from datetime import datetime, timedelta, timezone
import urllib.error
import urllib.parse
import urllib.request
import uuid

REPO = Path(__file__).resolve().parents[2]


class Failure(Exception):
    def __init__(self, code, status=0):
        self.code = code if re.fullmatch(r'[A-Z][A-Z0-9_]{0,79}', code or '') else 'UNSAFE_ERROR_REDACTED'
        self.status = status
        super().__init__(self.code)


def require(value, code='ASSERTION_FAILED'):
    if not value:
        raise Failure(code)


def write_private(path, value, binary=False):
    temporary = path.with_name(path.name + '.tmp')
    data = value if binary else json.dumps(value, sort_keys=True, separators=(',', ':')).encode()
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'wb') as output:
        output.write(data)
    os.chmod(temporary, 0o600)
    os.replace(temporary, path)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, newurl):
        return None


class HTTP:
    def __init__(self, endpoint):
        url = urllib.parse.urlsplit(endpoint)
        require(url.scheme == 'https' and url.hostname and not url.username and not url.password
                and not url.query and not url.fragment and url.path in ('', '/'), 'INVALID_API_CONFIGURATION')
        self.endpoint = endpoint.rstrip('/')
        self.opener = urllib.request.build_opener(NoRedirect())

    def request(self, url, method='GET', body=None, headers=None, raw=False):
        payload = body if isinstance(body, bytes) or body is None else json.dumps(body, separators=(',', ':')).encode()
        request = urllib.request.Request(url, data=payload, method=method, headers=headers or {})
        try:
            with self.opener.open(request, timeout=35) as result:
                data = result.read(4 * 1024 * 1024 + 1)
                require(len(data) <= 4 * 1024 * 1024, 'RESPONSE_TOO_LARGE')
                return result.status, data if raw else json.loads(data) if data else None
        except urllib.error.HTTPError as error:
            data = error.read(4096)
            try:
                code = json.loads(data).get('message', '')
            except (ValueError, AttributeError):
                code = ''
            raise Failure(code if re.fullmatch(r'[A-Z][A-Z0-9_]{0,79}', code or '') else 'HTTP_' + str(error.code), error.code) from None
        except (urllib.error.URLError, TimeoutError, OSError):
            raise Failure('NETWORK_UNAVAILABLE') from None
        except (ValueError, TypeError):
            raise Failure('INVALID_JSON_RESPONSE') from None

    def api(self, path, token=None, body=None, method='POST'):
        headers = {'Content-Type': 'application/json', 'Cache-Control': 'no-store'}
        if token:
            headers['Authorization'] = 'Bearer ' + token
        return self.request(self.endpoint + path, method, body, headers)[1]


SWIFT_SOCKET = r'''import Foundation
import Darwin
let options = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: Any]
let ready = URL(fileURLWithPath: options["ready"] as! String)
let result = URL(fileURLWithPath: options["result"] as! String)
func save(_ value: [String: Any], _ path: URL) {
    if let data = try? JSONSerialization.data(withJSONObject: value) {
        try? data.write(to: path, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }
}
final class Delegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    let path: URL
    init(_ path: URL) { self.path = path }
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol value: String?) { save(["connected": true], path) }
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {}
}
let delegate = Delegate(ready)
let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
let socket = session.webSocketTask(with: URL(string: options["url"] as! String)!)
socket.resume()
DispatchQueue.global().asyncAfter(deadline: .now() + 40) {
    save(["status": "timeout"], result); socket.cancel(with: .goingAway, reason: nil); exit(2)
}
Task {
    do {
        while true {
            let message = try await socket.receive(), data: Data
            switch message { case .data(let value): data = value; case .string(let value): data = Data(value.utf8); @unknown default: continue }
            guard data.count < 65536, let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if value["type"] as? String == "changed", value["team_id"] as? String == options["team"] as? String {
                save(["status": "hint", "contentFree": Set(value.keys) == Set(["type", "team_id"])], result)
                socket.cancel(with: .normalClosure, reason: nil); exit(0)
            }
        }
    } catch {
        save(["status": FileManager.default.fileExists(atPath: ready.path) ? "failed" : "rejected"], result); exit(0)
    }
}
RunLoop.main.run()
'''


class Runner:
    def __init__(self, config_path, directory):
        self.config = json.loads(config_path.read_text())
        outputs = self.config.get('outputs', self.config)
        if isinstance(outputs, list):
            outputs = {row['OutputKey']: row['OutputValue'] for row in outputs}
        self.outputs = outputs
        require(all(outputs.get(k) for k in ('APIURL', 'WebSocketURL', 'UserPoolId', 'ClientId', 'TableName', 'AssetBucket')), 'MISSING_STACK_OUTPUTS')
        require(not directory.resolve().is_relative_to(REPO), 'STATE_MUST_BE_EXTERNAL')
        directory.mkdir(parents=True, exist_ok=True)
        os.chmod(directory, 0o700)
        self.directory, self.state_path = directory, directory / 'qualification-state.json'
        fingerprint = hashlib.sha256(json.dumps({k: outputs[k] for k in ('APIURL', 'WebSocketURL', 'UserPoolId', 'ClientId', 'TableName', 'AssetBucket')}, sort_keys=True).encode()).hexdigest()
        self.state = json.loads(self.state_path.read_text()) if self.state_path.exists() else {'run': uuid.uuid4().hex, 'fingerprint': fingerprint, 'users': {}, 'commands': {}, 'receipts': {}}
        legacy = hashlib.sha256(json.dumps(outputs, sort_keys=True).encode()).hexdigest()
        require(self.state['fingerprint'] in (fingerprint, legacy), 'STATE_STACK_MISMATCH')
        self.state['fingerprint'] = fingerprint
        self.save()
        self.http = HTTP(outputs['APIURL'])
        self.aws = self.config.get('aws_cli') or shutil.which('aws') or '/opt/homebrew/bin/aws'
        require(Path(self.aws).is_file(), 'AWS_CLI_UNAVAILABLE')
        self.region = self.config.get('region', 'us-east-1')
        self.profile = self.config.get('profile', 'default')
        self.passed = 0

    def save(self):
        write_private(self.state_path, self.state)

    def cli(self, operation, arguments):
        path = self.directory / 'cli-input.json'
        write_private(path, arguments)
        command = [self.aws, 'cognito-idp', operation, '--region', self.region, '--profile', self.profile,
                   '--cli-input-json', 'file://' + str(path), '--output', 'json', '--no-cli-pager']
        try:
            result = subprocess.run(command, capture_output=True, timeout=60, env={**os.environ, 'AWS_PAGER': ''})
        except (OSError, subprocess.TimeoutExpired):
            raise Failure('AWS_CLI_UNAVAILABLE') from None
        finally:
            path.unlink(missing_ok=True)
        if result.returncode:
            match = re.search(rb'An error occurred \(([A-Za-z0-9]+)\)', result.stderr)
            code = match[1].decode().upper() if match else 'AWS_CLI_FAILED'
            raise Failure(code) from None
        try:
            return json.loads(result.stdout) if result.stdout else {}
        except ValueError:
            raise Failure('AWS_CLI_INVALID_RESPONSE') from None

    def identity(self, role):
        value = self.state['users'].get(role)
        if value is None:
            value = {'username': 'wc_smoke_' + role + '_' + self.state['run'], 'password': secrets.token_urlsafe(32) + '!Aa1',
                     'email': 'smoke-' + role + '-' + self.state['run'] + '@example.invalid'}
            self.state['users'][role] = value
            self.save()
        try:
            created = self.cli('admin-create-user', {'UserPoolId': self.outputs['UserPoolId'], 'Username': value['username'],
                'MessageAction': 'SUPPRESS', 'TemporaryPassword': value['password'],
                'UserAttributes': [{'Name': 'email', 'Value': value['email']}, {'Name': 'custom:is_guest', 'Value': 'false'}]})
            attributes = {v['Name']: v['Value'] for v in created['User']['Attributes']}
        except Failure as error:
            if error.code != 'USERNAMEEXISTSEXCEPTION':
                raise
            found = self.cli('admin-get-user', {'UserPoolId': self.outputs['UserPoolId'], 'Username': value['username']})
            attributes = {v['Name']: v['Value'] for v in found['UserAttributes']}
            require(attributes.get('email') == value['email'] and attributes.get('custom:is_guest') == 'false', 'TEST_IDENTITY_OWNERSHIP_MISMATCH')
        self.cli('admin-set-user-password', {'UserPoolId': self.outputs['UserPoolId'], 'Username': value['username'], 'Password': value['password'], 'Permanent': True})
        authenticated = self.cli('admin-initiate-auth', {'UserPoolId': self.outputs['UserPoolId'], 'ClientId': self.outputs['ClientId'],
            'AuthFlow': 'ADMIN_USER_PASSWORD_AUTH', 'AuthParameters': {'USERNAME': value['username'], 'PASSWORD': value['password']}})
        value['id'] = attributes['sub']
        value['id_token'] = authenticated['AuthenticationResult']['IdToken']
        value['session'] = {'user': {'id': value['id'], 'is_anonymous': False},
            'access_token': authenticated['AuthenticationResult']['AccessToken'],
            'refresh_token': authenticated['AuthenticationResult']['RefreshToken'],
            'expires_in': authenticated['AuthenticationResult']['ExpiresIn']}
        self.save()
        return value

    def token(self, role):
        return self.state['users'][role]['session']['access_token']

    def api(self, path, role='admin', body=None, method='POST'):
        return self.http.api(path, self.token(role), body, method)

    def rpc(self, name, payload, role='admin'):
        return self.api('/rest/v1/rpc/' + name, role, {'p': payload})

    def command(self, key, payload):
        if key not in self.state['commands']:
            self.state['commands'][key] = {**payload, 'command_id': str(uuid.uuid4())}
            self.save()
        return self.state['commands'][key]

    def ensure(self, key, name, payload, role='admin'):
        prepared = self.command(key, payload)
        if key not in self.state['receipts']:
            try:
                self.state['receipts'][key] = self.rpc(name, prepared, role)
            except Failure as error:
                print('FAIL rpc_' + name + ' [' + error.code + ']', flush=True)
                raise
            self.save()
        return self.state['receipts'][key]

    def rows(self, name, role='admin', team=None):
        query = '?team_id=' + urllib.parse.quote(team) if team else ''
        return self.api('/rest/v1/' + name + query, role, method='GET')

    def denial(self, name, payload, role='member', code='ACCESS_REVOKED'):
        try:
            self.rpc(name, payload, role)
        except Failure as error:
            require(error.code == code, 'WRONG_DENIAL_CODE')
            return
        raise Failure('UNAUTHORIZED_OPERATION_SUCCEEDED')

    def test(self, name, work):
        try:
            work()
        except Failure as error:
            print('FAIL ' + name + ' [' + error.code + ']', flush=True)
            raise
        except Exception:
            print('FAIL ' + name + ' [UNEXPECTED_TEST_ERROR]', flush=True)
            raise Failure('UNEXPECTED_TEST_ERROR') from None
        self.passed += 1
        print('PASS ' + name, flush=True)

    def fixture_pdf(self):
        file = self.directory / 'synthetic-blank.pdf'
        if not file.exists():
            vendor = self.config.get('pypdf_path') or str(REPO.parent / 'DeveloperTools/WorshipCue/AWS/vendor')
            sys.path.insert(0, vendor)
            try:
                from pypdf import PdfWriter
                writer = PdfWriter(); writer.add_blank_page(width=612, height=792)
                buffer = io.BytesIO(); writer.write(buffer)
            except Exception:
                raise Failure('APPROVED_PDF_VENDOR_UNAVAILABLE') from None
            write_private(file, buffer.getvalue(), binary=True)
        return file.read_bytes()

    @staticmethod
    def signed_url(value):
        url = urllib.parse.urlsplit(value)
        require(url.scheme == 'https' and url.hostname and url.hostname.endswith('.amazonaws.com')
                and ('.s3.' in url.hostname or url.hostname.startswith('s3.')) and not url.username and not url.password,
                'UNSAFE_SIGNED_STORAGE_URL')
        return value

    def chart(self, key, team, role='admin'):
        data = self.fixture_pdf(); digest = hashlib.sha256(data).hexdigest()
        song = self.ensure(key + '-song', 'create_song', {'team_id': team, 'canonical_title': 'Synthetic Qualification Chart ' + key}, role)
        asset = self.ensure(key + '-asset', 'stage_asset', {'team_id': team, 'type': 'pdf', 'sha256': digest, 'expected_bytes': len(data)}, role)
        signed = self.api('/functions/v1/asset-upload-url', role,
            {'key': asset['storage_key'], 'content_type': 'application/pdf', 'bytes': len(data)}) if key + '-uploaded' not in self.state['receipts'] else None
        if signed:
            require(signed['headers'].get('If-None-Match') == '*' and signed['headers'].get('x-amz-checksum-sha256') == base64.b64encode(bytes.fromhex(digest)).decode(), 'SIGNED_CHECKSUM_HEADER_MISMATCH')
            try:
                invalid = data[:-1] + bytes([data[-1] ^ 1])
                try:
                    self.http.request(self.signed_url(signed['url']), 'PUT', invalid, signed['headers'], raw=True)
                except Failure as error:
                    require(error.status == 400 or (error.status == 412 and self.state.get('checks', {}).get(key + '-checksum')), 'CHECKSUM_REJECTION_FAILED')
                    if error.status == 400:
                        self.state.setdefault('checks', {})[key + '-checksum'] = True; self.save()
                else:
                    raise Failure('INCORRECT_CHECKSUM_UPLOAD_ACCEPTED')
                self.http.request(self.signed_url(signed['url']), 'PUT', data, signed['headers'], raw=True)
            except Failure as error:
                # A prior run may have completed the PUT before its private state was saved.
                require(error.status == 412, 'SIGNED_UPLOAD_FAILED')
            try:
                self.http.request(self.signed_url(signed['url']), 'PUT', data, signed['headers'], raw=True)
            except Failure as error:
                require(error.status == 412, 'IMMUTABLE_OVERWRITE_WRONG_STATUS')
            else:
                raise Failure('IMMUTABLE_OVERWRITE_SUCCEEDED')
            self.state['receipts'][key + '-uploaded'] = True; self.save()
        finalized = self.api('/functions/v1/finalize-asset', role,
            {'asset_id': asset['id'], 'sha256': digest, 'expected_bytes': len(data)})
        require(finalized['status'] == 'verified' and len(finalized['page_manifest']) == 1, 'PDF_FINALIZATION_FAILED')
        chart = self.ensure(key + '-chart', 'publish_chart_version', {'song_id': song['id'], 'verified_pdf_asset_id': asset['id'],
            'label': 'Synthetic blank page', 'written_key': 'G', 'page_manifest': finalized['page_manifest']}, role)
        return song, asset, chart

    def download(self, asset, role):
        signed = self.api('/functions/v1/asset-download-url', role, {'key': asset['storage_key']})
        status, data = self.http.request(self.signed_url(signed['url']), raw=True)
        require(status == 200 and hashlib.sha256(data).hexdigest() == asset['sha256'] and len(data) == asset['bytes'], 'DOWNLOAD_HASH_MISMATCH')
        return data

    def setlist(self, key, team, chart):
        row = self.ensure(key + '-setlist', 'create_setlist', {'team_id': team, 'title': 'Synthetic Rehearsal ' + key, 'timezone': 'UTC'})
        item = self.state.setdefault('items', {}).get(key)
        if item is None:
            item = {'id': str(uuid.uuid4()), 'song_id': chart['song_id'], 'team_chart_version_id': chart['id'],
                    'performance_key': 'A', 'position': 0, 'kind': 'planned'}
            self.state['items'][key] = item; self.save()
        receipt = self.ensure(key + '-save', 'save_setlist', {'setlist_id': row['id'], 'base_revision': 0, 'items': [item]})
        require(receipt['revision'] == 1, 'SETLIST_REVISION_MISMATCH')
        return row, item

    def private_artifact(self, key, team, data, kind, role='member'):
        digest = hashlib.sha256(data).hexdigest()
        asset = self.ensure(key + '-asset', 'stage_asset', {'team_id': team, 'type': kind, 'sha256': digest, 'expected_bytes': len(data)}, role)
        if key + '-uploaded' not in self.state['receipts']:
            mime = 'image/png' if kind == 'preview' else 'application/octet-stream'
            signed = self.api('/functions/v1/asset-upload-url', role, {'key': asset['storage_key'], 'content_type': mime, 'bytes': len(data)})
            try:
                self.http.request(self.signed_url(signed['url']), 'PUT', data, signed['headers'], raw=True)
            except Failure as error:
                require(error.status == 412, 'PRIVATE_ARTIFACT_UPLOAD_FAILED')
            self.state['receipts'][key + '-uploaded'] = True; self.save()
        return self.api('/functions/v1/finalize-asset', role, {'asset_id': asset['id'], 'sha256': digest, 'expected_bytes': len(data)})

    @staticmethod
    def preview_png():
        import struct
        import zlib
        def chunk(kind, payload):
            return struct.pack('>I', len(payload)) + kind + payload + struct.pack('>I', zlib.crc32(kind + payload) & 0xffffffff)
        return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 1, 1, 8, 6, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(b'\x00\x00\x00\x00\xff')) + chunk(b'IEND', b'')

    def start_socket(self, key, ticket, team):
        script = self.directory / 'socket-qualification.swift'
        write_private(script, SWIFT_SOCKET.encode(), binary=True)
        prefix = self.directory / key
        ready, result, options = prefix.with_suffix('.ready.json'), prefix.with_suffix('.result.json'), prefix.with_suffix('.input.json')
        ready.unlink(missing_ok=True); result.unlink(missing_ok=True)
        endpoint = urllib.parse.urlsplit(self.outputs['WebSocketURL'])
        require(endpoint.scheme == 'wss' and not endpoint.query and not endpoint.username and not endpoint.password, 'UNSAFE_SOCKET_ENDPOINT')
        value = self.outputs['WebSocketURL'] + '?ticket=' + urllib.parse.quote(ticket, safe='')
        write_private(options, {'url': value, 'team': team, 'ready': str(ready), 'result': str(result)})
        process = subprocess.Popen(['/bin/sh', str(REPO / 'scripts/with_external_xcode.sh'), 'swift', str(script), str(options)],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        return process, ready, result

    def socket_result(self, process, result, require_open=False, ready=None):
        try:
            process.communicate(timeout=45)
        except subprocess.TimeoutExpired:
            process.kill(); process.communicate(); raise Failure('SOCKET_TEST_TIMEOUT') from None
        require(result.exists(), 'SWIFT_SOCKET_HARNESS_FAILED')
        if require_open:
            require(ready.exists(), 'SOCKET_HANDSHAKE_FAILED')
        return json.loads(result.read_text())

    def qualify(self):
        self.state['attempt'] = self.state.get('attempt', 0) + 1; self.save()
        attempt = str(self.state['attempt'])
        self.test('hosted_api_health', lambda: require(self.http.api('/health', method='GET')['service'] == 'worshipcue'))
        self.test('managed_identity_setup', lambda: [self.identity(role) for role in ('admin', 'member', 'outside')])
        workspace = self.ensure('workspace', 'create_church_and_default_team', {'display_name': 'Synthetic Qualification ' + self.state['run'][:8], 'timezone': 'UTC'})
        second = self.ensure('second-team', 'create_team', {'church_id': workspace['church_id'], 'display_name': 'Synthetic Private Second Team'})
        outside = self.ensure('outside-workspace', 'create_church_and_default_team', {'display_name': 'Synthetic Outside Church', 'timezone': 'UTC'}, 'outside')
        team, other = workspace['team_id'], second['team_id']
        invitation = self.ensure('member-invitation', 'create_invitation', {'team_id': team, 'permitted_role': 'member',
            'expires_at': (datetime.now(timezone.utc) + timedelta(days=6)).isoformat(), 'max_uses': 1})
        self.ensure('member-redemption', 'redeem_invitation', {'token': invitation['token'], 'display_name': 'Synthetic Musician'}, 'member')
        self.rpc('set_membership_active', {'team_id': team, 'user_id': self.state['users']['member']['id'], 'active': True})
        def managed_auth():
            current = self.state['users']['member']['session']
            refreshed = self.http.api('/auth/v1/token', body={'refresh_token': current['refresh_token']})
            require(refreshed['user']['id'] == current['user']['id'] and not refreshed['user']['is_anonymous'], 'REFRESH_IDENTITY_CHANGED')
            self.state['users']['member']['session'] = refreshed; self.save()
            try:
                self.http.api('/rest/v1/memberships', token=self.state['users']['member']['id_token'], method='GET')
            except Failure as error:
                require((error.code == 'AUTH_REQUIRED' and error.status == 401) or
                        (error.code in ('HTTP_401', 'HTTP_403') and error.status in (401, 403)),
                        'ID_TOKEN_WRONG_REJECTION')
            else:
                raise Failure('ID_TOKEN_ACCEPTED_AS_ACCESS_TOKEN')
        self.test('managed_refresh_and_access_token_only_authentication', managed_auth)
        def creation_replay():
            require(workspace == self.rpc('create_church_and_default_team', self.state['commands']['workspace']),
                    'WORKSPACE_DUPLICATE_CHANGED')
            require(second == self.rpc('create_team', self.state['commands']['second-team']), 'TEAM_DUPLICATE_CHANGED')
            require(second['church_id'] == workspace['church_id'] and team != other, 'TEAM_PARTITION_NOT_DISTINCT')
        self.test('workspace_and_team_idempotency', creation_replay)
        a_song, a_asset, a_chart = self.chart('A', team)
        _, b_asset, b_chart = self.chart('B', other)
        _, c_asset, c_chart = self.chart('C', outside['team_id'], 'outside')
        _, other_a_asset, other_a_chart = self.chart('A-other', team)
        self.test('signed_pdf_checksum_finalize_and_immutable_upload', lambda: require(a_chart['page_count'] == 1 and a_chart['pdf_sha256'] == hashlib.sha256(self.fixture_pdf()).hexdigest()))
        self.test('published_pdf_download_integrity', lambda: require(self.download(a_asset, 'member') == self.fixture_pdf()))

        def isolation():
            require({v['id'] for v in self.rows('chart_versions', 'member')} == {a_chart['id'], other_a_chart['id']}, 'CROSS_TEAM_CATALOG_EXPOSED')
            for target in (other, outside['team_id']):
                self.denial('get_team_roster', {'team_id': target})
                self.denial('create_song', {'team_id': target, 'command_id': str(uuid.uuid4()), 'canonical_title': 'Forbidden synthetic request'})
            for asset in (b_asset, c_asset):
                try:
                    self.api('/functions/v1/asset-download-url', 'member', {'key': asset['storage_key']})
                except Failure as error:
                    require(error.code == 'ASSET_NOT_AUTHORIZED', 'WRONG_FILE_DENIAL')
                else:
                    raise Failure('CROSS_TEAM_FILE_EXPOSED')
            self.denial('set_personal_preference', {'selected_team_id': team, 'song_id': b_chart['song_id'], 'preferred_version_id': b_chart['id']}, 'admin')
        self.test('same_church_and_outside_church_access_isolation', isolation)
        first_set, item = self.setlist('A', team, a_chart)
        other_set, _ = self.setlist('B', team, other_a_chart)
        self.test('setlist_compare_and_swap', lambda: self.denial('save_setlist', self.command('stale-setlist', {'setlist_id': first_set['id'], 'base_revision': 0, 'items': []}), 'admin', 'REVISION_CONFLICT'))
        self.test('cross_team_chart_rejected_from_setlist', lambda: self.denial('save_setlist', self.command('cross-team-setlist', {'setlist_id': first_set['id'], 'base_revision': 1,
            'items': [{**item, 'song_id': b_chart['song_id'], 'team_chart_version_id': b_chart['id']}]}), 'admin', 'FILE_NOT_READY'))
        def personal_privacy():
            # Opaque synthetic bytes test authorization/CAS only, not PencilKit serialization.
            native = self.private_artifact('personal-native', team, b'SYNTHETIC-BOUNDED-ARCHIVE', 'native')
            preview = self.private_artifact('personal-preview', team, self.preview_png(), 'preview')
            identity = {'church_id': workspace['church_id'], 'team_id': team, 'chart_version_id': a_chart['id'], 'page_index': 0,
                        'scope': 'personal', 'owner_user_id': self.state['users']['member']['id'], 'performance_item_id': None}
            payload = {'layer_identity': identity, 'parent_revision': 0, 'native_asset_id': native['id'], 'preview_asset_id': preview['id'],
                       'geometry': a_chart['page_manifest'][0], 'device_id': str(uuid.uuid4())}
            head = self.ensure('personal-head', 'save_annotation_revision', payload, 'member')
            require(self.rpc('get_annotation_head', {'layer_id': head['layer_id']}, 'member')['revision_number'] == 1, 'PERSONAL_HEAD_UNREADABLE')
            self.denial('get_annotation_head', {'layer_id': head['layer_id']}, 'admin')
            try:
                self.api('/functions/v1/asset-download-url', 'admin', {'key': native['storage_key']})
            except Failure as error:
                require(error.code == 'ASSET_NOT_AUTHORIZED', 'ADMIN_PERSONAL_FILE_WRONG_DENIAL')
            else:
                raise Failure('ADMIN_PERSONAL_FILE_EXPOSED')
            require(self.download(native, 'member') == b'SYNTHETIC-BOUNDED-ARCHIVE', 'PERSONAL_ARCHIVE_HASH_MISMATCH')
            self.denial('save_annotation_revision', self.command('personal-stale', payload), 'member', 'REVISION_CONFLICT')
        self.test('personal_archive_privacy_and_revision_compare_and_swap', personal_privacy)
        first_chat = self.ensure('chat-first', 'send_chat_message', {'team_id': team, 'body': 'Synthetic rehearsal preparation'}, 'member')

        def chat():
            duplicate = self.rpc('send_chat_message', self.state['commands']['chat-first'], 'member')
            require(duplicate == first_chat, 'CHAT_DUPLICATE_ID_CHANGED')
            snapshot = self.rpc('get_chat_snapshot', {'team_id': team, 'after_revision': 0}, 'member')
            require(sum(m['id'] == first_chat['id'] for m in snapshot['messages']) == 1, 'CHAT_DUPLICATE_STORED')
            catchup = self.rpc('get_chat_snapshot', {'team_id': team, 'after_revision': snapshot['revision']}, 'member')
            require(catchup['messages'] == [], 'CHAT_CATCHUP_REPEATED')
            self.rpc('mark_chat_read', {'team_id': team, 'revision': snapshot['revision']}, 'member')
            self.denial('get_chat_snapshot', {'team_id': other})
            self.denial('send_chat_message', {'team_id': other, 'command_id': str(uuid.uuid4()), 'body': 'Forbidden synthetic message'})
        self.test('durable_chat_deduplication_catchup_and_team_scope', chat)

        def guest():
            invitation = self.ensure('guest-invitation-' + attempt, 'create_invitation', {'team_id': team, 'permitted_role': 'guest', 'setlist_id': first_set['id'],
                'expires_at': (datetime.now(timezone.utc) + timedelta(days=6)).isoformat(), 'max_uses': 1})
            if 'guest' not in self.state['users']:
                session = self.http.api('/auth/v1/signup', body={'invitation_token': invitation['token']})
                require(session['user']['is_anonymous'] is True, 'GUEST_IDENTITY_NOT_SCOPED')
                self.state['users']['guest'] = {'id': session['user']['id'], 'session': session}; self.save()
            else:
                current = self.state['users']['guest']['session']
                current = self.http.api('/auth/v1/token', body={'refresh_token': current['refresh_token']})
                self.state['users']['guest']['session'] = current; self.save()
                self.api('/functions/v1/redeem-invitation', 'guest', {'token': invitation['token']})
            require({v['id'] for v in self.rows('setlists', 'guest', team)} == {first_set['id']}, 'GUEST_OTHER_SETLIST_EXPOSED')
            require(self.download(a_asset, 'guest') == self.fixture_pdf(), 'GUEST_GRANTED_FILE_UNREADABLE')
            require({v['id'] for v in self.rows('chart_versions', 'guest', team)} == {a_chart['id']}, 'GUEST_OTHER_CHART_EXPOSED')
            try:
                self.api('/functions/v1/asset-download-url', 'guest', {'key': other_a_asset['storage_key']})
            except Failure as error:
                require(error.code == 'ASSET_NOT_AUTHORIZED', 'GUEST_WRONG_FILE_DENIAL')
            else:
                raise Failure('GUEST_OTHER_FILE_EXPOSED')
            self.denial('preflight_manifest', {'setlist_id': other_set['id']}, 'guest')
            self.denial('get_chat_snapshot', {'team_id': team}, 'guest')
            self.denial('send_chat_message', {'team_id': team, 'command_id': str(uuid.uuid4()), 'body': 'Forbidden guest message'}, 'guest')
        self.test('managed_guest_exact_setlist_and_chat_denial', guest)

        def aggregate_catalog():
            keys = ('songs', 'chart_versions', 'assets', 'setlists', 'performance_items', 'personal_preferences')
            for role in ('member', 'guest'):
                value = self.rpc('get_team_catalog', {'team_id': team, 'selected_team_id': team}, role)
                require(isinstance(value, dict) and all(isinstance(value.get(key), list) for key in keys),
                        'INCOMPLETE_TEAM_CATALOG')
                for key in keys:
                    require(value[key] == self.rows(key, role, team), 'AGGREGATED_CATALOG_SCOPE_MISMATCH')
                if role == 'guest':
                    require(value['personal_preferences'] == [], 'GUEST_PREFERENCES_EXPOSED')
            self.denial('get_team_catalog', {'team_id': other, 'selected_team_id': other})
            self.denial('get_team_catalog', {'team_id': outside['team_id'], 'selected_team_id': outside['team_id']})
        self.test('aggregated_catalog_preserves_member_guest_and_team_isolation', aggregate_catalog)

        def live_calls():
            device = self.state.setdefault('live_device', str(uuid.uuid4())); self.save()
            leases = self.rows('editor_leases', 'admin', team)
            lease = next(value for value in leases if value['setlist_id'] == first_set['id'])
            lease = self.rpc('acquire_editor', {'setlist_id': first_set['id'], 'device_id': device,
                'expected_epoch': lease['epoch'], 'explicit_takeover': False})
            # Complete only an earlier interrupted session belonging to this runner's known setlist.
            prior = self.state.get('active_test_session')
            if prior:
                snapshot = self.rpc('get_session_snapshot', {'session_id': prior['id']})
                if snapshot['status'] == 'LIVE':
                    self.rpc('end_session', {'session_id': prior['id'], 'device_id': device, 'epoch': lease['epoch'], 'command_id': str(uuid.uuid4())})
            session = self.ensure('live-start-' + attempt, 'start_session', {'setlist_id': first_set['id'], 'device_id': device, 'epoch': lease['epoch']})
            self.state['active_test_session'] = session; self.save()
            try:
                payload = {'session_id': session['id'], 'device_id': device, 'expected_controller_epoch': lease['epoch'], 'expected_latest_sequence': 0,
                    'performance_item_id': item['id'], 'song_id': a_chart['song_id'], 'team_chart_version_id': a_chart['id'], 'performance_key': 'A'}
                first = self.ensure('live-first-' + attempt, 'publish_call', payload)
                require(first == self.rpc('publish_call', self.state['commands']['live-first-' + attempt]), 'LIVE_DUPLICATE_CHANGED')
                self.denial('publish_call', self.command('live-stale-' + attempt, payload), 'admin', 'STALE_CALL')
                second = self.ensure('live-second-' + attempt, 'publish_call', {**payload, 'expected_latest_sequence': 1})
                snapshot = self.rpc('get_session_snapshot', {'session_id': session['id']}, 'member')
                require(snapshot['latest_sequence'] == 2 and snapshot['latest_call']['id'] == second['call']['id'], 'LIVE_LATEST_CALL_INCORRECT')
                require(not any('page' in key or 'navigate' in key for key in snapshot['latest_call']), 'LIVE_PROTOCOL_NAVIGATION_FIELD')
                ack = self.rpc('acknowledge_open', {'session_id': session['id'], 'call_id': first['call']['id'],
                    'device_id': str(uuid.uuid4()), 'selected_chart_version_id': a_chart['id']}, 'member')
                require(ack['opened'] and not ack['is_latest'] and ack['meaning'] == 'rendered_not_ready', 'LIVE_ACK_READINESS_CONFLATED')
            finally:
                self.rpc('renew_editor', {'setlist_id': first_set['id'], 'device_id': device, 'epoch': lease['epoch']})
                self.rpc('end_session', self.command('live-end-' + attempt, {'session_id': session['id'], 'device_id': device, 'epoch': lease['epoch']}))
            self.denial('publish_call', self.command('live-after-end-' + attempt, {**payload, 'expected_latest_sequence': 2}), 'admin', 'SESSION_ENDED')
        self.test('live_sequence_deduplication_historical_ack_and_terminal_end', live_calls)

        def realtime():
            ticket = self.api('/functions/v1/realtime-ticket', 'member', {'team_id': team})['ticket']
            first, ready, result = self.start_socket('socket-first', ticket, team)
            try:
                deadline = time.monotonic() + 15
                while not ready.exists() and first.poll() is None and time.monotonic() < deadline:
                    time.sleep(0.1)
                require(ready.exists(), 'SOCKET_HANDSHAKE_FAILED')
                reused, reused_ready, reused_result = self.start_socket('socket-reuse', ticket, team)
                second = self.socket_result(reused, reused_result)
                require(second['status'] == 'rejected' and not reused_ready.exists(), 'SOCKET_TICKET_REUSE_ACCEPTED')
                self.rpc('send_chat_message', self.command('chat-live-hint-' + attempt, {'team_id': team, 'body': 'Synthetic live hint verification'}), 'admin')
                delivered = self.socket_result(first, result, True, ready)
                require(delivered['status'] == 'hint' and delivered['contentFree'], 'SOCKET_CONTENT_FREE_HINT_FAILED')
                durable = self.rpc('get_chat_snapshot', {'team_id': team, 'after_revision': first_chat['revision']}, 'member')
                require(any(m['body'] == 'Synthetic live hint verification' for m in durable['messages']), 'SOCKET_DURABLE_CATCHUP_FAILED')
            finally:
                if first.poll() is None:
                    first.kill(); first.communicate()
        self.test('realtime_one_use_ticket_content_free_hint_and_durable_catchup', realtime)

        def revoke():
            user = self.state['users']['member']['id']
            try:
                self.rpc('set_membership_active', {'team_id': team, 'user_id': user, 'active': False})
                self.denial('get_chat_snapshot', {'team_id': team})
                self.denial('send_chat_message', self.state['commands']['chat-first'])
            finally:
                self.rpc('set_membership_active', {'team_id': team, 'user_id': user, 'active': True})
        self.test('revocation_blocks_requests_and_old_idempotency_receipts', revoke)
        def logout_scope():
            user = self.state['users']['member']
            result = self.cli('admin-initiate-auth', {'UserPoolId': self.outputs['UserPoolId'], 'ClientId': self.outputs['ClientId'],
                'AuthFlow': 'ADMIN_USER_PASSWORD_AUTH', 'AuthParameters': {'USERNAME': user['username'], 'PASSWORD': user['password']}})['AuthenticationResult']
            old = user['session']
            self.http.api('/auth/v1/logout', old['access_token'], {'refresh_token': old['refresh_token']})
            for path, body, token, method in [('/rest/v1/memberships', None, old['access_token'], 'GET'),
                    ('/auth/v1/token', {'refresh_token': old['refresh_token']}, None, 'POST')]:
                try:
                    self.http.api(path, token, body, method)
                except Failure as error:
                    require(error.code == 'AUTH_REQUIRED', 'LOGOUT_WRONG_REJECTION')
                else:
                    raise Failure('LOGGED_OUT_SESSION_REMAINED_ACTIVE')
            memberships = self.http.api('/rest/v1/memberships', result['AccessToken'], method='GET')
            require(any(value['team_id'] == team for value in memberships), 'LOGOUT_REVOKED_OTHER_SESSION')
            user['session'] = {'user': old['user'], 'access_token': result['AccessToken'], 'refresh_token': result['RefreshToken'], 'expires_in': result['ExpiresIn']}; self.save()
            # Qualify malformed-header recovery; this is not a claim of one-hour expiry testing.
            surviving = self.cli('admin-initiate-auth', {'UserPoolId': self.outputs['UserPoolId'], 'ClientId': self.outputs['ClientId'],
                'AuthFlow': 'ADMIN_USER_PASSWORD_AUTH', 'AuthParameters': {'USERNAME': user['username'], 'PASSWORD': user['password']}})['AuthenticationResult']
            self.http.api('/auth/v1/logout', 'synthetic-malformed-access-header', {'refresh_token': result['RefreshToken']})
            try:
                self.http.api('/rest/v1/memberships', result['AccessToken'], method='GET')
            except Failure as error:
                require(error.code == 'AUTH_REQUIRED', 'MALFORMED_HEADER_LOGOUT_WRONG_REJECTION')
            else:
                raise Failure('MALFORMED_HEADER_LOGOUT_LEFT_SESSION_ACTIVE')
            memberships = self.http.api('/rest/v1/memberships', surviving['AccessToken'], method='GET')
            require(any(value['team_id'] == team for value in memberships), 'MALFORMED_HEADER_LOGOUT_REVOKED_OTHER_SESSION')
            user['session'] = {'user': old['user'], 'access_token': surviving['AccessToken'], 'refresh_token': surviving['RefreshToken'], 'expires_in': surviving['ExpiresIn']}; self.save()
        self.test('logout_session_scope_and_malformed_header_fallback', logout_scope)
        print(str(self.passed) + ' passed / 0 failed', flush=True)
        self.state['last_qualification'] = {'passed': self.passed, 'at': datetime.now(timezone.utc).isoformat()}; self.save()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, required=True)
    parser.add_argument('--state-directory', type=Path, required=True)
    args = parser.parse_args()
    try:
        Runner(args.config, args.state_directory).qualify()
        return 0
    except Failure as error:
        print('QUALIFICATION FAILED [' + error.code + ']', flush=True)
        return 1
    except Exception:
        # Never emit exception strings or tracebacks: provider responses can contain credentials.
        print('QUALIFICATION FAILED [UNEXPECTED_ERROR_REDACTED]', flush=True)
        return 1


if __name__ == '__main__':
    sys.exit(main())
