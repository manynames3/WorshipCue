"""Cognito owns authentication; no app-issued JWTs or passwords are persisted."""
import hashlib
import base64
import json
import secrets
import time
import uuid

from domain import APIError
from mail_feedback import address_hash, suppressed


class Authentication:
    def __init__(self, cognito, pool, client, domain, email_ready=False):
        self.cognito, self.pool, self.client, self.domain = cognito, pool, client, domain
        self.email_ready = email_ready
        self.issuer = f'https://cognito-idp.{pool.split("_")[0]}.amazonaws.com/{pool}'

    @staticmethod
    def username(email):
        try:
            return 'member_' + address_hash(email)
        except ValueError:
            raise APIError('INVALID_INPUT') from None

    @staticmethod
    def email(body):
        value = body.get('email')
        if not isinstance(value,str):
            raise APIError('INVALID_INPUT')
        value = value.strip().lower()
        Authentication.username(value)
        return value

    @staticmethod
    def provider_error(error):
        code = getattr(error,'response',{}).get('Error',{}).get('Code','')
        if code in ('NotAuthorizedException','UserNotFoundException','CodeMismatchException','ExpiredCodeException'):
            return APIError('AUTH_REQUIRED',401)
        if code in ('TooManyRequestsException','LimitExceededException'):
            return APIError('RATE_LIMITED',429)
        return APIError('AUTH_UNAVAILABLE',503)

    def actor(self, token):
        if not isinstance(token, str) or not 20 < len(token) < 16000:
            raise APIError('AUTH_REQUIRED', 401)
        try:
            user = self.cognito.get_user(AccessToken=token)
        except Exception as error:
            raise self.provider_error(error) from None
        attributes = {v['Name']: v['Value'] for v in user['UserAttributes']}
        try:
            actor_id = str(uuid.UUID(attributes['sub']))
        except (KeyError, ValueError, TypeError):
            raise APIError('AUTH_REQUIRED', 401) from None
        try:
            raw = token.split('.')[1]
            claims = json.loads(base64.urlsafe_b64decode(raw + '='*((4-len(raw)%4)%4)))
            expiry = int(claims['exp'])
            origin = claims['origin_jti']
            if (not isinstance(origin,str) or not origin or claims.get('token_use') != 'access'
                    or expiry <= int(time.time()) or claims.get('iss') != self.issuer
                    or claims.get('client_id') != self.client or claims.get('sub') != actor_id):
                raise ValueError('Invalid access token')
        except (ValueError, KeyError, IndexError, TypeError):
            raise APIError('AUTH_REQUIRED', 401) from None
        return {'id': actor_id, 'guest': attributes.get('custom:is_guest') == 'true',
                'expires_at_epoch': expiry, 'session_hash': hashlib.sha256((actor_id+origin).encode()).hexdigest()}

    def session(self, result):
        actor = self.actor(result['AccessToken'])
        return {'user': {'id': actor['id'], 'is_anonymous': actor['guest']},
                'access_token': result['AccessToken'], 'refresh_token': result['RefreshToken'],
                'expires_in': result['ExpiresIn']}

    def otp(self, body):
        if not self.email_ready:
            raise APIError('EMAIL_SENDER_NOT_READY', 503)
        email = self.email(body)
        if suppressed(self.domain.store, email):
            raise APIError('EMAIL_DELIVERY_UNAVAILABLE', 503)
        username = self.username(email)
        try:
            self.cognito.admin_create_user(UserPoolId=self.pool, Username=username,
                MessageAction='SUPPRESS', UserAttributes=[{'Name': 'email', 'Value': email}])
        except self.cognito.exceptions.UsernameExistsException:
            pass
        except Exception as error:
            raise self.provider_error(error) from None
        try:
            result = self.cognito.initiate_auth(ClientId=self.client, AuthFlow='USER_AUTH',
                AuthParameters={'USERNAME': username, 'PREFERRED_CHALLENGE': 'EMAIL_OTP'})
        except Exception as error:
            raise self.provider_error(error) from None
        if result.get('ChallengeName') != 'EMAIL_OTP' or not result.get('Session'):
            raise APIError('AUTH_UNAVAILABLE', 503)
        return {'session': result['Session'], 'challenge': 'EMAIL_OTP'}

    def verify(self, body):
        username = self.username(self.email(body))
        code, session = body.get('token'), body.get('session')
        if not isinstance(code, str) or not 6 <= len(code) <= 8 or not code.isascii() or not code.isdigit():
            raise APIError('INVALID_INPUT')
        if not isinstance(session, str) or not 20 <= len(session) <= 12000:
            raise APIError('AUTH_REQUIRED', 401)
        try:
            result = self.cognito.respond_to_auth_challenge(ClientId=self.client,
                ChallengeName='EMAIL_OTP', Session=session,
                ChallengeResponses={'USERNAME': username, 'EMAIL_OTP_CODE': code})
        except Exception as error:
            raise self.provider_error(error) from None
        if 'AuthenticationResult' not in result:
            raise APIError('AUTH_REQUIRED', 401)
        return self.session(result['AuthenticationResult'])

    def refresh(self, body):
        refresh = body.get('refresh_token')
        if not isinstance(refresh, str) or not 20 < len(refresh) < 16000:
            raise APIError('AUTH_REQUIRED', 401)
        try:
            result = self.cognito.initiate_auth(ClientId=self.client, AuthFlow='REFRESH_TOKEN_AUTH',
                AuthParameters={'REFRESH_TOKEN': refresh})['AuthenticationResult']
        except Exception as error:
            raise self.provider_error(error) from None
        result['RefreshToken'] = refresh
        return self.session(result)

    def logout(self, body):
        refresh = body.get('refresh_token')
        if not isinstance(refresh, str) or not 20 < len(refresh) < 16000:
            raise APIError('AUTH_REQUIRED', 401)
        self.cognito.revoke_token(ClientId=self.client, Token=refresh)
        return {'signed_out': True}

    def guest(self, body):
        invitation = body.get('invitation_token')
        self.domain.validate_guest_invitation(invitation)
        username, password = 'guest_' + uuid.uuid4().hex, secrets.token_urlsafe(36) + '!Aa1'
        created = False
        try:
            self.cognito.admin_create_user(UserPoolId=self.pool, Username=username,
                MessageAction='SUPPRESS', TemporaryPassword=password,
                UserAttributes=[{'Name':'custom:is_guest','Value':'true'}])
            created = True
            self.cognito.admin_set_user_password(UserPoolId=self.pool, Username=username,
                Password=password, Permanent=True)
            result = self.cognito.admin_initiate_auth(UserPoolId=self.pool, ClientId=self.client,
                AuthFlow='ADMIN_USER_PASSWORD_AUTH',
                AuthParameters={'USERNAME': username, 'PASSWORD': password})['AuthenticationResult']
            value = self.session(result)
            self.domain.rpc('redeem_invitation', {'token': invitation},
                            {'id': value['user']['id'], 'guest': True})
            return value
        except Exception:
            if created:
                try:
                    self.cognito.admin_delete_user(UserPoolId=self.pool,Username=username)
                except Exception:
                    pass  # Preserve the original failure; no guest grant is accepted without redemption.
            raise
