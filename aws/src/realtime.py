"""One-use connection tickets and content-free invalidation hints."""
import hashlib
import json
import secrets
import time

from domain import APIError
from store import Conflict


class Realtime:
    def __init__(self, store, domain, gateway, clock=time.time):
        self.store, self.domain, self.gateway, self.clock = store, domain, gateway, clock

    def ticket(self, body, actor):
        team, session = body.get('team_id'), body.get('session_id')
        setlist = None
        if session:
            snapshot = self.domain.rpc('get_session_snapshot', {'session_id':session, 'selected_team_id':team}, actor)
            setlist = snapshot['setlist_id']
        authorized = self.domain.authorize_team(actor, team, setlist)
        team = authorized['team_id']
        value = secrets.token_urlsafe(32)
        key = hashlib.sha256(value.encode()).hexdigest()
        row = {'team_id':team, 'setlist_id':setlist, 'actor':actor,
               'expires_at_epoch':int(self.clock())+60}
        self.store.transact([{'op':'put', 'pk':'TICKET#'+key, 'sk':'STATE', 'value':row, 'expected':None}])
        return {'ticket':value}

    def connect(self, connection, ticket):
        if not isinstance(ticket, str) or len(ticket)>200:
            raise APIError('AUTH_REQUIRED', 401)
        pk = 'TICKET#'+hashlib.sha256(ticket.encode()).hexdigest()
        row = self.store.get(pk, 'STATE')
        if not row or row['expires_at_epoch'] <= int(self.clock()):
            raise APIError('AUTH_REQUIRED', 401)
        self.domain.authorize_team(row['actor'], row['team_id'], row['setlist_id'])
        value = {**row, 'connection_id':connection,
                 'expires_at_epoch':min(row['actor']['expires_at_epoch'],int(self.clock())+7200)}
        if value['expires_at_epoch'] <= int(self.clock()) or self.revoked(row['actor']):
            raise APIError('AUTH_REQUIRED', 401)
        try:
            self.store.transact([
                {'op':'delete','pk':pk,'sk':'STATE','expected':row},
                {'op':'put','pk':'WS#'+row['team_id'],'sk':connection,'value':value,'expected':None},
                {'op':'put','pk':'WSID#'+connection,'sk':'STATE','value':value,'expected':None}])
        except Conflict:
            raise APIError('AUTH_REQUIRED', 401) from None
        return {}

    def revoked(self, actor):
        return self.store.get('REVOKED#'+actor['session_hash'],'STATE') is not None

    def disconnect(self, connection):
        row = self.store.get('WSID#'+connection,'STATE')
        if row:
            self.store.transact([{'op':'delete','pk':'WSID#'+connection,'sk':'STATE'},
                {'op':'delete','pk':'WS#'+row['team_id'],'sk':connection}])

    def permitted(self, row):
        if row['expires_at_epoch'] <= int(self.clock()) or self.revoked(row['actor']):
            return False
        try:
            self.domain.authorize_team(row['actor'],row['team_id'],row['setlist_id'])
            return True
        except APIError:
            return False

    def heartbeat(self, connection):
        row = self.store.get('WSID#'+connection,'STATE')
        if not row or not self.permitted(row):
            self.disconnect(connection)
            raise APIError('ACCESS_REVOKED',403)
        return {}

    def broadcast(self, team, members_only=False):
        # Files, handwriting, chat text and identifiers other than team never enter the live frame.
        payload = json.dumps({'type':'changed','team_id':team},separators=(',',':')).encode()
        for row in self.store.query('WS#'+team):
            if members_only and row['actor']['guest']:
                continue
            if not self.permitted(row):
                self.disconnect(row['connection_id'])
                try:
                    self.gateway.delete_connection(ConnectionId=row['connection_id'])
                except self.gateway.exceptions.GoneException:
                    pass
                continue
            try:
                self.gateway.post_to_connection(ConnectionId=row['connection_id'],Data=payload)
            except self.gateway.exceptions.GoneException:
                self.disconnect(row['connection_id'])

    def revoke(self, actor):
        pk = 'REVOKED#'+actor['session_hash']
        for _ in range(4):
            previous = self.store.get(pk,'STATE')
            value = {'expires_at_epoch':max(actor['expires_at_epoch'],int(self.clock())+7200,
                (previous or {}).get('expires_at_epoch',0))}
            try:
                self.store.transact([{'op':'put','pk':pk,'sk':'STATE','value':value,'expected':previous}])
                return
            except Conflict:
                continue
        raise APIError('UNAVAILABLE',503)
