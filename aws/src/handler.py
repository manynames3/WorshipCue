"""API Gateway boundary; identity and team rights are checked on the server."""
import base64
import json
import os
import time

from auth import Authentication
from domain import APIError, Domain
from files import Files
from realtime import Realtime
from limits import Limits
from store import DynamoStore, Conflict

_application = None


def response(status, value):
    return {'statusCode':status,'headers':{'content-type':'application/json; charset=utf-8',
            'cache-control':'no-store','x-content-type-options':'nosniff'},
            'body':json.dumps(value,separators=(',',':'),ensure_ascii=False,allow_nan=False)}


def json_body(event):
    raw = event.get('body') or '{}'
    if event.get('isBase64Encoded'):
        try:
            raw = base64.b64decode(raw,validate=True).decode()
        except (ValueError,UnicodeError):
            raise APIError('INVALID_INPUT') from None
    if len(raw.encode()) > 1048576:
        raise APIError('TOO_LARGE',413)
    try:
        value = json.loads(raw,parse_constant=lambda _: (_ for _ in ()).throw(ValueError()))
    except (ValueError,TypeError):
        raise APIError('INVALID_INPUT') from None
    if not isinstance(value,dict):
        raise APIError('INVALID_INPUT')
    return value


class Application:
    def __init__(self, domain, auth, files, realtime, limits=None):
        self.domain,self.auth,self.files,self.realtime = domain,auth,files,realtime
        self.limits = limits if limits is not None else Limits(domain.store)

    def handle(self,event):
        request = event.get('requestContext',{})
        if 'connectionId' in request:
            route, connection = request.get('routeKey'), request['connectionId']
            if route == '$connect':
                self.realtime.connect(connection,(event.get('queryStringParameters') or {}).get('ticket'))
            elif route == '$disconnect':
                self.realtime.disconnect(connection)
            elif route == '$default':
                if json_body(event).get('action') != 'heartbeat':
                    raise APIError('INVALID_INPUT')
                self.realtime.heartbeat(connection)
            else:
                raise APIError('INVALID_INPUT')
            return response(200,{})
        path, method = event.get('rawPath',''),request.get('http',{}).get('method','')
        if method == 'GET' and path == '/health':
            return response(200,{'service':'worshipcue','version':1,'emailOtpReady':self.auth.email_ready})
        body = {} if method == 'GET' else json_body(event)
        if path.startswith('/auth/v1/') and method == 'POST':
            operation = path.rsplit('/',1)[-1]
            if operation == 'logout':
                token = (event.get('headers',{}).get('authorization') or '').removeprefix('Bearer ')
                try:
                    actor = self.auth.actor(token)
                    self.realtime.revoke(actor)
                except APIError as error:
                    if error.status != 401:
                        raise
                    # An expired header can accompany a still-valid refreshed socket.
                    # Identify that session through Cognito, never unverified JWT claims.
                    try:
                        refreshed = self.auth.refresh(body)
                        self.realtime.revoke(self.auth.actor(refreshed['access_token']))
                    except APIError as refresh_error:
                        if refresh_error.status != 401:
                            raise
                return response(200,self.auth.logout(body))
            routes = {'otp':self.auth.otp,'verify':self.auth.verify,'token':self.auth.refresh,'signup':self.auth.guest}
            if operation not in routes:
                raise APIError('NOT_FOUND',404)
            action = {'otp':'otp','verify':'verify','token':'refresh','signup':'guest'}[operation]
            destination = self.auth.email(body) if operation == 'otp' else None
            self.limits.check(action,request.get('http',{}).get('sourceIp'),destination)
            return response(200,routes[operation](body))
        token = (event.get('headers',{}).get('authorization') or '').removeprefix('Bearer ')
        actor = self.auth.actor(token)
        if self.realtime.revoked(actor):
            raise APIError('AUTH_REQUIRED',401)
        if path.startswith('/rest/v1/rpc/') and method == 'POST':
            name,payload = path.rsplit('/',1)[-1],body.get('p')
            if not isinstance(payload,dict):
                raise APIError('INVALID_INPUT')
            result = self.domain.rpc(name,payload,actor)
            shared = name in {'create_song','publish_chart_version','create_setlist','save_setlist',
                'acquire_editor','renew_editor','release_editor','start_session','publish_call','end_session',
                'send_chat_message','edit_chat_message','delete_chat_message','pin_chat_message'} or (
                    name=='save_annotation_revision' and result.get('scope')=='team') or name in {
                        'set_member_display_name','set_member_role','set_membership_active','handoff_team_admin',
                        'revoke_invitation','revoke_guest_grant'}
            team = result.get('team_id') if isinstance(result,dict) else None
            team = team or payload.get('team_id') or payload.get('selected_team_id')
            if shared and team:
                try:
                    self.realtime.broadcast(team,members_only='chat' in name)
                except Exception:
                    print(json.dumps({'event':'hint_delivery_failed','operation':name}))
            return response(200,result)
        if path.startswith('/rest/v1/') and method == 'GET':
            table = path.rsplit('/',1)[-1]
            team = (event.get('queryStringParameters') or {}).get('team_id')
            return response(200,self.domain.rows(table,actor,team))
        if path.startswith('/functions/v1/') and method == 'POST':
            name = path.rsplit('/',1)[-1]
            if name == 'realtime-ticket':return response(200,self.realtime.ticket(body,actor))
            if name == 'asset-upload-url':return response(200,self.files.upload_url(body,actor))
            if name == 'asset-download-url':return response(200,self.files.download_url(body,actor))
            if name == 'finalize-asset':return response(200,self.files.finalize(body,actor))
            if name == 'redeem-invitation':return response(200,self.domain.rpc('redeem_invitation',body,actor))
        raise APIError('NOT_FOUND',404)


def application():
    global _application
    if _application is None:
        import boto3
        from botocore.config import Config
        store = DynamoStore(os.environ['TABLE_NAME'])
        domain = Domain(store)
        auth = Authentication(boto3.client('cognito-idp'),os.environ['USER_POOL_ID'],os.environ['CLIENT_ID'],domain,
                              os.environ.get('EMAIL_READY')=='true')
        files = Files(boto3.client('s3',config=Config(signature_version='s3v4')),os.environ['ASSET_BUCKET'],domain)
        live = Realtime(store,domain,boto3.client('apigatewaymanagementapi',endpoint_url=os.environ['WEBSOCKET_MANAGEMENT_URL']))
        _application = Application(domain,auth,files,live)
    return _application


def lambda_handler(event,context):
    try:
        return application().handle(event)
    except APIError as error:
        return response(error.status,{'message':error.code})
    except Conflict:
        return response(409,{'message':'REVISION_CONFLICT'})
    except Exception as error:
        # Never print event/body, exception text, tokens, addresses, handwriting or chart content.
        code = getattr(error,'response',{}).get('Error',{}).get('Code')
        known = {'AccessDeniedException','ValidationException','TransactionCanceledException',
                 'ResourceNotFoundException','InternalServerError','ThrottlingException','AccessDenied','NoSuchKey'}
        print(json.dumps({'event':'request_failed','class':type(error).__name__,
                          'provider_code':code if code in known else 'unspecified'}))
        return response(503,{'message':'UNAVAILABLE'})
