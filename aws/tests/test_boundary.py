"""Local boundary qualification, not evidence of deployed AWS SDK behavior.

Cognito/S3/API Gateway calls are controlled fakes. PDFs use the real approved
pypdf parser; all documents, identities, tokens and addresses are synthetic.
"""
import base64
import copy
import hashlib
import io
import json
import logging
import struct
import sys
import time
import unittest
import uuid
import zlib
from contextlib import redirect_stderr, redirect_stdout
from datetime import datetime, timezone
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'src'))
import handler
import test_domain as fixtures
from auth import Authentication
from domain import APIError
from files import Files, validate_pdf, validate_png
from limits import Limits
from realtime import Realtime

try:
    from pypdf import PdfWriter
    from pypdf.generic import RectangleObject
except ImportError:
    PdfWriter = None

POOL, CLIENT = 'us-east-1_SYNTHETIC', 'syntheticclient'
ISSUER = f'https://cognito-idp.us-east-1.amazonaws.com/{POOL}'


def uid():
    return str(uuid.uuid4())


def jwt(claims):
    # Not signed: only the fake GetUser accepts these local test tokens.
    def part(value):
        return base64.urlsafe_b64encode(json.dumps(value).encode()).decode().rstrip('=')
    return part({'alg': 'RS256'}) + '.' + part(claims) + '.synthetic_signature'


class ProviderError(Exception):
    def __init__(self, code):
        super().__init__(code)
        self.response = {'Error': {'Code': code}}


class FakeCognito:
    class UsernameExistsException(Exception):
        pass

    def __init__(self, user_id):
        self.exceptions = SimpleNamespace(UsernameExistsException=self.UsernameExistsException)
        self.users, self.tokens, self.refresh_tokens, self.calls, self.failures = {}, {}, {}, [], {}
        self.default_result = self.issue(user_id)

    def record(self, name, args):
        self.calls.append((name, copy.deepcopy(args)))
        if name in self.failures:
            raise self.failures[name]

    def issue(self, user_id, guest=False, origin=None, **overrides):
        origin = origin or uid()
        claims = dict(sub=user_id, iss=ISSUER, client_id=CLIENT, token_use='access',
                      origin_jti=origin, exp=int(time.time()) + 1800, iat=time.time())
        claims.update(overrides)
        access = jwt(claims)
        self.tokens[access] = {'UserAttributes': [{'Name': 'sub', 'Value': user_id},
            {'Name': 'custom:is_guest', 'Value': 'true' if guest else 'false'}]}
        refresh = 'synthetic_refresh_' + uid() + '_' + origin
        self.refresh_tokens[refresh] = (user_id, guest, origin)
        return {'AccessToken': access, 'RefreshToken': refresh, 'ExpiresIn': 1800}

    def get_user(self, **args):
        self.record('get_user', args)
        if args['AccessToken'] not in self.tokens:
            raise ProviderError('NotAuthorizedException')
        return copy.deepcopy(self.tokens[args['AccessToken']])

    def admin_create_user(self, **args):
        self.record('admin_create_user', args)
        if args['Username'] in self.users:
            raise self.UsernameExistsException()
        self.users[args['Username']] = {'id': uid(), 'attributes': args['UserAttributes']}

    def admin_set_user_password(self, **args):
        self.record('admin_set_user_password', args)

    def admin_delete_user(self, **args):
        self.record('admin_delete_user', args)
        self.users.pop(args['Username'], None)

    def initiate_auth(self, **args):
        self.record('initiate_auth', args)
        if args['AuthFlow'] == 'USER_AUTH':
            return {'ChallengeName': 'EMAIL_OTP', 'Session': 'synthetic_challenge_' + uid()}
        user_id, guest, origin = self.refresh_tokens[args['AuthParameters']['REFRESH_TOKEN']]
        result = self.issue(user_id, guest, origin)
        result.pop('RefreshToken')
        return {'AuthenticationResult': result}

    def respond_to_auth_challenge(self, **args):
        self.record('respond_to_auth_challenge', args)
        return {'AuthenticationResult': self.default_result}

    def admin_initiate_auth(self, **args):
        self.record('admin_initiate_auth', args)
        user = self.users[args['AuthParameters']['USERNAME']]
        return {'AuthenticationResult': self.issue(user['id'], guest=True)}

    def revoke_token(self, **args):
        self.record('revoke_token', args)


class FakeS3:
    def __init__(self):
        self.calls, self.objects, self.streams, self.head_length = [], {}, [], None

    def generate_presigned_url(self, operation, **args):
        self.calls.append((operation, copy.deepcopy(args)))
        return 'https://synthetic-bucket.s3.us-east-1.amazonaws.com/' + args['Params']['Key'] + '?X-Amz-Signature=synthetic'

    def head_object(self, **args):
        self.calls.append(('head_object', copy.deepcopy(args)))
        data = self.objects[args['Key']]
        return {'ContentLength': len(data) if self.head_length is None else self.head_length,
                'ChecksumSHA256': base64.b64encode(hashlib.sha256(data).digest()).decode()}

    def get_object(self, **args):
        self.calls.append(('get_object', copy.deepcopy(args)))
        stream = io.BytesIO(self.objects[args['Key']])
        self.streams.append(stream)
        return {'Body': stream}


class FakeGateway:
    class GoneException(Exception):
        pass

    def __init__(self):
        self.exceptions = SimpleNamespace(GoneException=self.GoneException)
        self.posts, self.deleted, self.gone = [], [], set()

    def post_to_connection(self, **args):
        if args['ConnectionId'] in self.gone:
            raise self.GoneException()
        self.posts.append(copy.deepcopy(args))

    def delete_connection(self, **args):
        self.deleted.append(args['ConnectionId'])


def png(extra=None):
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
    result = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 1, 1, 8, 6, 0, 0, 0))
    if extra:
        result += chunk(extra, b'')
    return result + chunk(b'IDAT', zlib.compress(b'\0\0\0\0\0')) + chunk(b'IEND', b'')


def pdf(count=1, encrypted=False):
    writer = PdfWriter()
    for _ in range(count):
        page = writer.add_blank_page(width=612, height=792)
        page.cropbox = RectangleObject([20, 28, 592, 768])
        page.rotate(90)
    if encrypted:
        writer.encrypt('synthetic_password')
    stream = io.BytesIO()
    writer.write(stream)
    return stream.getvalue()


class BoundaryFixture(unittest.TestCase):
    def setUp(self):
        self.fx = fixtures.DomainTests()
        self.fx.setUp()
        self.fx.time = datetime.now(timezone.utc)
        self.now = int(self.fx.time.timestamp())
        self.domain, self.store, self.team = self.fx.domain, self.fx.store, self.fx.team
        self.cognito = FakeCognito(self.fx.admin['id'])
        self.auth = Authentication(self.cognito, POOL, CLIENT, self.domain, email_ready=True)
        self.s3, self.gateway = FakeS3(), FakeGateway()
        self.files = Files(self.s3, 'synthetic-bucket', self.domain)
        self.realtime = Realtime(self.store, self.domain, self.gateway, clock=lambda: self.now)
        self.admin = self.actor(self.fx.admin)

    def actor(self, value, lifetime=1800):
        return dict(value, expires_at_epoch=self.now + lifetime,
                    session_hash=hashlib.sha256(('synthetic_' + value['id']).encode()).hexdigest())

    def assert_api(self, code, operation, *args, status=None):
        with self.assertRaises(APIError) as caught:
            operation(*args)
        self.assertEqual(code, caught.exception.code)
        if status is not None:
            self.assertEqual(status, caught.exception.status)

    def stage(self, data, kind='native'):
        asset = self.domain.rpc('stage_asset', dict(team_id=self.team, type=kind,
            sha256=hashlib.sha256(data).hexdigest(), expected_bytes=len(data)), self.admin)
        self.s3.objects[asset['storage_key']] = data
        return asset

    @staticmethod
    def finalize_body(asset):
        return dict(asset_id=asset['id'], sha256=asset['sha256'], expected_bytes=asset['bytes'])

    def connect(self, connection, actor=None, team=None, session=None):
        body = {'team_id': team or self.team}
        if session:
            body['session_id'] = session
        ticket = self.realtime.ticket(body, actor or self.admin)['ticket']
        self.realtime.connect(connection, ticket)
        return ticket


class AuthenticationTests(BoundaryFixture):
    def test_managed_identity_and_origin_survive_access_token_refresh(self):
        first = self.auth.actor(self.cognito.default_result['AccessToken'])
        refreshed = self.auth.refresh({'refresh_token': self.cognito.default_result['RefreshToken']})
        second = self.auth.actor(refreshed['access_token'])
        self.assertEqual(first['session_hash'], second['session_hash'])
        self.assertEqual(first['id'], second['id'])
        self.assertNotIn('access_token', first)
        self.assertEqual(self.cognito.default_result['RefreshToken'], refreshed['refresh_token'])
        self.assertIn('get_user', [name for name, _ in self.cognito.calls])

    def test_managed_but_foreign_pool_client_subject_and_id_tokens_are_rejected(self):
        for override in [{'iss': ISSUER + '_foreign'}, {'client_id': 'foreign_client'},
                         {'sub': uid()}, {'token_use': 'id'}, {'exp': int(time.time()) - 1}]:
            with self.subTest(override=override):
                value = self.cognito.issue(self.fx.admin['id'], **override)
                self.assert_api('AUTH_REQUIRED', self.auth.actor, value['AccessToken'], status=401)

    def test_email_otp_creation_never_claims_verified_email_or_sets_password(self):
        result = self.auth.otp({'email': ' Synthetic@Example.invalid '})
        self.assertEqual('EMAIL_OTP', result['challenge'])
        created = next(args for name, args in self.cognito.calls if name == 'admin_create_user')
        self.assertNotIn('TemporaryPassword', created)
        self.assertEqual('SUPPRESS', created['MessageAction'])
        self.assertEqual([{'Name': 'email', 'Value': 'synthetic@example.invalid'}], created['UserAttributes'])
        initiated = next(args for name, args in self.cognito.calls if name == 'initiate_auth')
        self.assertEqual('USER_AUTH', initiated['AuthFlow'])
        self.assertEqual('EMAIL_OTP', initiated['AuthParameters']['PREFERRED_CHALLENGE'])
        self.assertNotIn('@', initiated['AuthParameters']['USERNAME'])
        self.auth.otp({'email': 'synthetic@example.invalid'})

    def test_sender_not_ready_and_invalid_email_make_no_provider_requests(self):
        self.auth.email_ready = False
        self.assert_api('EMAIL_SENDER_NOT_READY', self.auth.otp, {'email': 'synthetic@example.invalid'}, status=503)
        self.auth.email_ready = True
        for email in [None, 123, [], 'missing-at']:
            self.assert_api('INVALID_INPUT', self.auth.otp, {'email': email}, status=400)
        self.assertEqual([], self.cognito.calls)

    def test_email_challenge_accepts_provider_code_with_six_or_eight_digits(self):
        for code in ['123456', '12345678']:
            result = self.auth.verify({'email': 'synthetic@example.invalid', 'token': code, 'session': 's' * 40})
            self.assertEqual(self.fx.admin['id'], result['user']['id'])
            sent = [args for name, args in self.cognito.calls if name == 'respond_to_auth_challenge'][-1]
            self.assertEqual(code, sent['ChallengeResponses']['EMAIL_OTP_CODE'])
            self.assertEqual('s' * 40, sent['Session'])
        self.assert_api('INVALID_INPUT', self.auth.verify, {'email': 'synthetic@example.invalid', 'token': '１２３４５６', 'session': 's' * 40})

    def test_provider_throttling_outage_and_bad_code_are_distinct(self):
        for provider_code, api_code, status in [('TooManyRequestsException', 'RATE_LIMITED', 429),
                ('LimitExceededException', 'RATE_LIMITED', 429), ('InternalErrorException', 'AUTH_UNAVAILABLE', 503),
                ('CodeMismatchException', 'AUTH_REQUIRED', 401), ('ExpiredCodeException', 'AUTH_REQUIRED', 401)]:
            with self.subTest(provider_code=provider_code):
                self.cognito.failures['respond_to_auth_challenge'] = ProviderError(provider_code)
                self.assert_api(api_code, self.auth.verify,
                    {'email': 'synthetic@example.invalid', 'token': '123456', 'session': 's' * 40}, status=status)
        self.cognito.failures['initiate_auth'] = ProviderError('InternalErrorException')
        self.assert_api('AUTH_UNAVAILABLE', self.auth.refresh,
                        {'refresh_token': self.cognito.default_result['RefreshToken']}, status=503)

    def test_guest_creation_requires_invitation_and_uses_managed_credentials(self):
        s, _, _ = self.fx.setlist()
        invite = self.fx.invite(self.team, 'guest', s['id'])
        value = self.auth.guest({'invitation_token': invite['token']})
        self.assertTrue(value['user']['is_anonymous'])
        self.assertEqual([s['id']], [v['id'] for v in self.domain.rows('setlists',
            {'id': value['user']['id'], 'guest': True}, self.team)])
        created = next(args for name, args in self.cognito.calls if name == 'admin_create_user')
        self.assertEqual([{'Name': 'custom:is_guest', 'Value': 'true'}], created['UserAttributes'])
        self.assertTrue(next(args for name, args in self.cognito.calls if name == 'admin_set_user_password')['Permanent'])
        self.assertFalse(any('password' in json.dumps(row).lower() for row in self.store.data.values()))

    def test_invalid_guest_invitation_creates_no_cognito_account(self):
        self.assert_api('ACCESS_REVOKED', self.auth.guest, {'invitation_token': 'synthetic_invalid_invitation'}, status=403)
        self.assertEqual([], self.cognito.calls)

    def test_guest_password_failure_cleans_created_user_without_masking_error(self):
        s, _, _ = self.fx.setlist()
        invite = self.fx.invite(self.team, 'guest', s['id'])
        failure = ProviderError('InternalErrorException')
        self.cognito.failures['admin_set_user_password'] = failure
        self.cognito.failures['admin_delete_user'] = ProviderError('CleanupFailed')
        with self.assertRaises(ProviderError) as caught:
            self.auth.guest({'invitation_token': invite['token']})
        self.assertIs(failure, caught.exception)
        self.assertIn('admin_delete_user', [name for name, _ in self.cognito.calls])
        self.assertEqual(0, sum(1 for pk, sk in self.store.data if sk.startswith('GRANT#')))

    def test_local_logout_revokes_refresh_without_global_signout(self):
        refresh = self.cognito.default_result['RefreshToken']
        self.assertTrue(self.auth.logout({'refresh_token': refresh})['signed_out'])
        self.assertEqual([('revoke_token', {'ClientId': CLIENT, 'Token': refresh})], self.cognito.calls)


class FileBoundaryTests(BoundaryFixture):
    def test_upload_signature_has_exact_checksum_length_and_immutable_condition(self):
        asset = self.stage(b'synthetic_native_archive')
        result = self.files.upload_url(dict(key=asset['storage_key'], bytes=asset['bytes'],
            content_type='application/octet-stream', access_token='never_forward_this'), self.admin)
        operation, signed = self.s3.calls[0]
        self.assertEqual('put_object', operation)
        self.assertEqual('*', signed['Params']['IfNoneMatch'])
        self.assertEqual(asset['bytes'], signed['Params']['ContentLength'])
        checksum = base64.b64encode(bytes.fromhex(asset['sha256'])).decode()
        self.assertEqual(checksum, signed['Params']['ChecksumSHA256'])
        self.assertEqual(checksum, result['headers']['x-amz-checksum-sha256'])
        self.assertEqual({'Content-Type', 'If-None-Match', 'x-amz-checksum-sha256'}, set(result['headers']))
        self.assertNotIn('never_forward_this', json.dumps(result) + json.dumps(signed))
        self.assertLessEqual(signed['ExpiresIn'], 120)

    def test_wrong_upload_owner_size_type_and_unverified_download_are_denied(self):
        asset = self.stage(b'synthetic_native_archive')
        request = dict(key=asset['storage_key'], bytes=asset['bytes'], content_type='application/octet-stream')
        for invalid in [dict(request, bytes=asset['bytes'] + 1), dict(request, content_type='image/png')]:
            self.assert_api('ASSET_NOT_AUTHORIZED', self.files.upload_url, invalid, self.admin, status=403)
        self.assert_api('ASSET_NOT_AUTHORIZED', self.files.upload_url, request, self.actor(self.fx.member), status=403)
        self.assert_api('ASSET_NOT_AUTHORIZED', self.files.download_url, {'key': asset['storage_key']}, self.admin, status=403)
        self.assertEqual([], self.s3.calls)

    def test_finalization_verifies_bytes_closes_stream_and_retries_without_reading_s3(self):
        asset = self.stage(b'synthetic_native_archive')
        first = self.files.finalize(self.finalize_body(asset), self.admin)
        self.assertEqual('verified', first['status'])
        self.assertTrue(self.s3.streams[0].closed)
        calls = len(self.s3.calls)
        self.assertEqual(first, self.files.finalize(self.finalize_body(asset), self.admin))
        self.assertEqual(calls, len(self.s3.calls))
        self.assert_api('ASSET_NOT_AUTHORIZED', self.files.upload_url,
            dict(key=asset['storage_key'], bytes=asset['bytes'], content_type='application/octet-stream'), self.admin)

    def test_changed_bytes_and_short_stream_never_mark_asset_verified(self):
        for corrupted in [b'changed_native_archive___', b'short']:
            asset = self.stage(b'synthetic_native_archive')
            self.s3.objects[asset['storage_key']] = corrupted
            self.s3.head_length = asset['bytes']
            self.assert_api('HASH_MISMATCH', self.files.finalize, self.finalize_body(asset), self.admin, status=409)
            self.assertTrue(self.s3.streams[-1].closed)
            self.assertEqual('staging', self.domain.upload_asset(asset['id'], self.admin)['status'])

    def test_png_validates_real_pixels_crc_chunk_names_and_trailing_bytes(self):
        self.assertEqual({'kind': 'png-rgba', 'width': 1, 'height': 1}, validate_png(png()))
        for invalid in [png(b'1234'), png(b'\x00abc'), png() + b'junk', png()[:-1] + b'\0']:
            self.assert_api('INVALID_PREVIEW', validate_png, invalid)

    @unittest.skipUnless(PdfWriter, 'Approved pypdf vendor is required for real parser qualification')
    def test_pdf_finalization_matches_native_flat_geometry_and_can_publish(self):
        asset = self.stage(pdf(), 'pdf')
        result = self.files.finalize(self.finalize_body(asset), self.admin)
        page = dict(schema_version=1, crop_x=20, crop_y=28, crop_width=572, crop_height=740, rotation=90)
        self.assertEqual([page], result['page_manifest'])
        song = self.domain.rpc('create_song', dict(team_id=self.team, canonical_title='Synthetic chart', command_id=uid()), self.admin)
        chart = self.domain.rpc('publish_chart_version', dict(song_id=song['id'], command_id=uid(),
            verified_pdf_asset_id=asset['id'], page_manifest=[page], written_key='G'), self.admin)
        self.assertEqual([page], chart['pages'])
        download = self.files.download_url({'key': asset['storage_key']}, self.actor(self.fx.member))
        self.assertIn('X-Amz-Signature=', download['url'])
        self.assertLessEqual(self.s3.calls[-1][1]['ExpiresIn'], 60)


@unittest.skipUnless(PdfWriter, 'Approved pypdf vendor is required for real parser qualification')
class RealPDFTests(unittest.TestCase):
    def test_encrypted_excess_pages_and_malformed_documents_are_rejected(self):
        for data in [pdf(encrypted=True), pdf(count=21), b'%PDF-1.7\nsynthetic_private_marker\nnot-a-cross-reference']:
            with self.assertRaises(APIError) as caught:
                validate_pdf(data)
            self.assertEqual('INVALID_PDF', caught.exception.code)

    def test_twenty_pages_are_accepted_with_exact_crop_and_rotation(self):
        result = validate_pdf(pdf(count=20))
        self.assertEqual(20, result['page_count'])
        self.assertEqual(20, len(result['page_manifest']))
        self.assertEqual(90, result['page_manifest'][-1]['rotation'])

    def test_real_parser_warning_path_cannot_log_private_source_excerpt(self):
        import pypdf._reader
        marker = 'synthetic_private_source_marker'
        capture = io.StringIO()
        logger = logging.getLogger('pypdf._reader')
        logger.setLevel(logging.WARNING)
        logger.propagate = True
        logger.handlers = [logging.StreamHandler(capture)]
        def warning(*args, **kwargs):
            logging.getLogger('pypdf._reader').warning(marker)
        # A truncated EOF exercises a real PdfReader recovery-warning call.
        with patch.object(pypdf._reader, 'logger_warning', side_effect=warning) as warned:
            with redirect_stderr(capture):
                validate_pdf(pdf().replace(b'%%EOF', b'%%EO'))
        self.assertTrue(warned.called)
        self.assertNotIn(marker, capture.getvalue())


class RealtimeBoundaryTests(BoundaryFixture):
    def test_ticket_is_hashed_in_storage_single_use_and_expires_explicitly(self):
        raw = self.realtime.ticket({'team_id': self.team, 'access_token': 'never_store_this'}, self.admin)['ticket']
        self.assertNotIn(raw, json.dumps(list(self.store.data.values())))
        self.assertNotIn('never_store_this', json.dumps(list(self.store.data.values())))
        self.realtime.connect('first', raw)
        self.assert_api('AUTH_REQUIRED', self.realtime.connect, 'reused', raw, status=401)
        expired = self.realtime.ticket({'team_id': self.team}, self.admin)['ticket']
        self.now += 60
        self.assert_api('AUTH_REQUIRED', self.realtime.connect, 'expired', expired, status=401)

    def test_access_expiry_and_membership_revocation_stop_fanout_and_remove_connection(self):
        member = self.actor(self.fx.member)
        self.connect('member', member)
        self.domain.rpc('set_membership_active', {'team_id': self.team, 'user_id': member['id'], 'active': False}, self.admin)
        self.realtime.broadcast(self.team)
        self.assertEqual([], self.gateway.posts)
        self.assertIn('member', self.gateway.deleted)
        self.assertIsNone(self.store.get('WSID#member', 'STATE'))
        self.connect('expires', self.actor(self.fx.admin, lifetime=10))
        self.now += 10
        self.realtime.broadcast(self.team)
        self.assertIn('expires', self.gateway.deleted)

    def test_foreign_team_ticket_is_denied_even_for_same_church_member(self):
        self.assert_api('ACCESS_REVOKED', self.realtime.ticket,
            {'team_id': self.fx.second['team_id']}, self.actor(self.fx.member), status=403)

    def test_chat_hints_exclude_guests_and_other_teams_and_contain_no_content(self):
        s, _, _, _, _, session = self.fx.live()
        self.fx.join(self.team, self.fx.guest, 'guest', s['id'])
        self.connect('member')
        self.connect('guest', self.actor(self.fx.guest), session=session['id'])
        self.connect('other-team', team=self.fx.second['team_id'])
        self.realtime.broadcast(self.team, members_only=True)
        self.assertEqual(['member'], [v['ConnectionId'] for v in self.gateway.posts])
        self.assertEqual({'type': 'changed', 'team_id': self.team}, json.loads(self.gateway.posts[0]['Data']))

    def test_logout_denial_covers_old_refreshed_connections_and_never_shortens(self):
        self.connect('existing')
        self.realtime.revoke(dict(self.admin, expires_at_epoch=self.now + 5))
        denial = self.store.get('REVOKED#' + self.admin['session_hash'], 'STATE')
        self.assertGreaterEqual(denial['expires_at_epoch'], self.now + 7200)
        self.realtime.revoke(dict(self.admin, expires_at_epoch=self.now + 9000))
        self.realtime.revoke(dict(self.admin, expires_at_epoch=self.now + 5))
        self.assertEqual(self.now + 9000, self.store.get('REVOKED#' + self.admin['session_hash'], 'STATE')['expires_at_epoch'])
        self.realtime.broadcast(self.team)
        self.assertEqual([], self.gateway.posts)
        self.assertIn('existing', self.gateway.deleted)

    def test_gone_gateway_connection_is_removed(self):
        self.connect('gone')
        self.gateway.gone.add('gone')
        self.realtime.broadcast(self.team)
        self.assertIsNone(self.store.get('WSID#gone', 'STATE'))


class HTTPBoundaryTests(BoundaryFixture):
    def invoke(self, path, body=None, token=None, method='POST', source_ip='192.0.2.1'):
        event = {'rawPath': path, 'requestContext': {'http': {'method': method, 'sourceIp': source_ip}},
                 'headers': {}, 'body': json.dumps(body or {})}
        if token:
            event['headers']['authorization'] = 'Bearer ' + token
        app = handler.Application(self.domain, self.auth, self.files, self.realtime,
                                  Limits(self.store, now=lambda: self.now))
        with patch.object(handler, '_application', app):
            return handler.lambda_handler(event, None)

    def test_health_and_unknown_auth_routes_do_not_call_provider(self):
        value = self.invoke('/health', method='GET')
        self.assertEqual(200, value['statusCode'])
        self.assertTrue(json.loads(value['body'])['emailOtpReady'])
        self.assertEqual(404, self.invoke('/auth/v1/unknown')['statusCode'])
        self.assertEqual([], self.cognito.calls)

    def test_missing_source_ip_and_malformed_email_fail_before_counters_or_provider(self):
        before = copy.deepcopy(self.store.data)
        for source in (None, '', 'not-an-ip'):
            result = self.invoke('/auth/v1/otp', {'email': 'synthetic@example.invalid'}, source_ip=source)
            self.assertEqual(400, result['statusCode'])
        self.assertEqual(400, self.invoke('/auth/v1/otp', {'email': 'malformed'})['statusCode'])
        self.assertEqual(before, self.store.data)
        self.assertEqual([], self.cognito.calls)

    def test_otp_source_and_destination_caps_stop_provider_and_store_only_digests(self):
        address = 'synthetic@example.invalid'
        self.assertEqual(200, self.invoke('/auth/v1/otp', {'email': address})['statusCode'])
        provider_calls = len(self.cognito.calls)
        before = copy.deepcopy(self.store.data)
        result = self.invoke('/auth/v1/otp', {'email': address}, source_ip='192.0.2.2')
        self.assertEqual(429, result['statusCode'])
        self.assertEqual(before, self.store.data)
        self.assertEqual(provider_calls, len(self.cognito.calls))
        for index in range(4):
            self.assertEqual(200, self.invoke('/auth/v1/otp', {'email': f'synthetic{index}@example.invalid'})['statusCode'])
        provider_calls = len(self.cognito.calls)
        result = self.invoke('/auth/v1/otp', {'email': 'synthetic-extra@example.invalid'})
        self.assertEqual(429, result['statusCode'])
        self.assertEqual(provider_calls, len(self.cognito.calls))
        counters = [(key, value) for key, value in self.store.data.items() if key[0].startswith('LIMIT#')]
        self.assertTrue(counters)
        stored = repr(counters)
        self.assertNotIn(address, stored)
        self.assertNotIn('192.0.2.', stored)
        self.assertTrue(all(value['expires_at_epoch'] > self.now for _, value in counters))

    def test_body_actor_cannot_replace_managed_identity(self):
        token = self.cognito.default_result['AccessToken']
        request = {'p': {'team_id': self.team, 'type': 'native', 'sha256': 'a' * 64,
                        'expected_bytes': 100, 'actor_id': self.fx.outside['id']}}
        value = self.invoke('/rest/v1/rpc/stage_asset', request, token)
        self.assertEqual(200, value['statusCode'])
        self.assertEqual(self.fx.admin['id'], json.loads(value['body'])['owner_user_id'])
        denied = self.invoke('/rest/v1/rpc/stage_asset', request, 'forged_token_' + uid())
        self.assertEqual(401, denied['statusCode'])

    def test_bad_json_and_oversized_body_have_bounded_clean_errors(self):
        for data, status in [('[1]', 400), ('{"number":NaN}', 400), ('x' * 1048577, 413)]:
            event = {'rawPath': '/auth/v1/verify', 'requestContext': {'http': {'method': 'POST', 'sourceIp': '192.0.2.1'}}, 'body': data}
            with patch.object(handler, '_application', handler.Application(self.domain, self.auth, self.files, self.realtime)):
                result = handler.lambda_handler(event, None)
            self.assertEqual(status, result['statusCode'])
            self.assertLess(len(result['body']), 100)

    def test_unknown_provider_failure_logs_class_without_token_or_message(self):
        secret = 'synthetic_private_failure_marker'
        self.cognito.failures['admin_create_user'] = RuntimeError(secret)
        output = io.StringIO()
        with redirect_stdout(output):
            value = self.invoke('/auth/v1/otp', {'email': 'synthetic@example.invalid'})
        self.assertEqual(503, value['statusCode'])
        self.assertNotIn(secret, output.getvalue() + value['body'])
        self.assertNotIn('synthetic@example.invalid', output.getvalue())


if __name__ == '__main__':
    unittest.main()
