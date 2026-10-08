"""Durable abuse limits before managed authentication sends mail or creates users.

Only namespaced SHA-256 digests reach storage. All applicable counters advance
atomically, so a rejected request cannot partly consume another allowance.
"""
import hashlib
import ipaddress
import time
from datetime import datetime

try:
    from .domain import APIError
    from .store import Conflict
except ImportError:
    from domain import APIError
    from store import Conflict


# scope, window seconds, maximum accepted attempts in that fixed window
RULES = {
    'otp': [('source', 60, 5), ('source', 86400, 50),
            ('destination', 60, 1), ('destination', 86400, 10), ('global', 86400, 200)],
    'verify': [('source', 60, 30)],
    'guest': [('source', 60, 5), ('source', 86400, 20), ('global', 86400, 100)],
    'refresh': [('source', 60, 60)],
}


class Limits:
    def __init__(self, store, now=None):
        self.store = store
        self.now = now or time.time

    @staticmethod
    def digest(scope, value):
        return hashlib.sha256((scope + '\x00' + value).encode()).hexdigest()

    def check(self, action, source_ip, destination=None):
        if not isinstance(action, str) or action not in RULES or not isinstance(source_ip, str) or not 1 <= len(source_ip.strip()) <= 100:
            raise APIError('INVALID_INPUT')
        source = source_ip.strip().casefold()
        try:
            source = str(ipaddress.ip_address(source))
        except ValueError:
            raise APIError('INVALID_INPUT') from None
        if action == 'otp':
            if not isinstance(destination, str) or not 1 <= len(destination.strip()) <= 320:
                raise APIError('INVALID_INPUT')
            destination = destination.strip().casefold()
        try:
            now = self.now()
            now = int(now.timestamp() if isinstance(now, datetime) else now)
            if now < 0:
                raise ValueError()
        except Exception:
            raise APIError('UNAVAILABLE', 503) from None
        keys = []
        for scope, seconds, maximum in RULES[action]:
            identity = source if scope == 'source' else destination if scope == 'destination' else 'all'
            digest = self.digest(scope, identity)
            start = (now // seconds) * seconds
            keys.append(('LIMIT#' + digest, action + '#' + scope + '#' + str(seconds) + '#' + str(start),
                         maximum, start + seconds))
        for _ in range(4):
            try:
                writes = []
                for pk, sk, maximum, expiry in keys:
                    old = self.store.get(pk, sk)
                    count = old['count'] if old else 0
                    if isinstance(count, bool) or not isinstance(count, int) or count < 0:
                        raise ValueError()
                    if count >= maximum:
                        raise APIError('RATE_LIMITED', 429)
                    writes.append(dict(op='put', pk=pk, sk=sk, expected=old,
                                       value=dict(count=count + 1, expires_at_epoch=expiry)))
                self.store.transact(writes)
                return
            except Conflict:
                continue
            except APIError:
                raise
            except Exception:
                raise APIError('UNAVAILABLE', 503) from None
        raise APIError('UNAVAILABLE', 503)
