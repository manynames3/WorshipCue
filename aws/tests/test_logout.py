import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'src'))
from domain import APIError, Domain
from handler import Application
from store import MemoryStore


class ManagedAuth:
    email_ready = True
    def actor(self, token):
        if token != 'managed-fresh-token':
            raise APIError('AUTH_REQUIRED',401)
        return {'id':'member','guest':False,'session_hash':'verified-origin','expires_at_epoch':9999999999}
    def refresh(self, body):
        if body.get('refresh_token') != 'managed-refresh-token':
            raise APIError('AUTH_REQUIRED',401)
        return {'access_token':'managed-fresh-token'}
    def logout(self, body):
        self.logged_out = True
        return {'signed_out':True}


class Live:
    def revoke(self, actor):
        self.denied = actor['session_hash']


class LogoutTests(unittest.TestCase):
    def test_expired_header_fences_the_managed_refreshed_socket_session(self):
        auth, live = ManagedAuth(), Live()
        app = Application(Domain(MemoryStore()),auth,None,live)
        result = app.handle({'rawPath':'/auth/v1/logout','requestContext':{'http':{'method':'POST'}},
            'headers':{'authorization':'Bearer expired-token'},'body':json.dumps({'refresh_token':'managed-refresh-token'})})
        self.assertEqual(result['statusCode'],200)
        self.assertEqual(live.denied,'verified-origin')
        self.assertTrue(auth.logged_out)

    def test_already_revoked_session_logout_is_idempotent_without_a_forged_fence(self):
        auth, live = ManagedAuth(), Live()
        app = Application(Domain(MemoryStore()),auth,None,live)
        app.handle({'rawPath':'/auth/v1/logout','requestContext':{'http':{'method':'POST'}},
            'headers':{'authorization':'Bearer forged-token'},'body':json.dumps({'refresh_token':'invalid-refresh'})})
        self.assertFalse(hasattr(live,'denied'))
        self.assertTrue(auth.logged_out)


if __name__ == '__main__':
    unittest.main()
