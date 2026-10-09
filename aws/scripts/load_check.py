#!/usr/bin/env python3
"""Bounded real API concurrency check using already-qualified synthetic identities.

Never creates identities, sends mail, publishes music/chat, changes membership or
turns pages. Output is counts/timing only; credentials stay in private inputs.
"""
import argparse
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import math
from pathlib import Path
import random
import re
import sys
import time
import unittest
import uuid
from urllib.parse import urlsplit

from smoke import Failure, HTTP, REPO, require

TABLES = ('songs', 'chart_versions', 'assets', 'setlists', 'performance_items', 'personal_preferences')
RETRYABLE = {'HTTP_429', 'HTTP_500', 'HTTP_502', 'HTTP_503', 'HTTP_504', 'UNAVAILABLE', 'NETWORK_UNAVAILABLE', 'RATE_LIMITED'}


def inputs(config_path, state_path):
    for path in (config_path, state_path):
        require(path.resolve().is_file() and not path.resolve().is_relative_to(REPO)
                and path.stat().st_mode & 0o077 == 0, 'PRIVATE_INPUT_REQUIRED')
    config, state = json.loads(config_path.read_text()), json.loads(state_path.read_text())
    require(config.get('stack') == 'worshipcue-dev' and config.get('region') == 'us-east-1', 'DEVELOPMENT_SCOPE_REQUIRED')
    outputs = config['outputs']
    if isinstance(outputs, list):
        outputs = {v['OutputKey']: v['OutputValue'] for v in outputs}
    fingerprint = hashlib.sha256(json.dumps({k: outputs[k] for k in ('APIURL', 'WebSocketURL', 'UserPoolId', 'ClientId', 'TableName', 'AssetBucket')}, sort_keys=True).encode()).hexdigest()
    require(state.get('fingerprint') == fingerprint and state.get('last_qualification', {}).get('passed', 0) >= 21, 'QUALIFIED_STATE_REQUIRED')
    team = state['receipts']['workspace']['team_id']
    require(str(uuid.UUID(team)) == team, 'INVALID_TEAM')
    tokens = []
    for role in ('admin', 'member'):
        row = state['users'][role]
        require(row['username'] == 'wc_smoke_' + role + '_' + state['run'], 'SYNTHETIC_IDENTITY_REQUIRED')
        session = row['session']
        require(row['id'] == session['user']['id'] and session['user']['is_anonymous'] is False, 'IDENTITY_STATE_MISMATCH')
        tokens.append(session['access_token'])
    endpoint = urlsplit(outputs['APIURL'])
    require(endpoint.scheme == 'https' and re.fullmatch(r'[a-z0-9]+\.execute-api\.us-east-1\.amazonaws\.com', endpoint.hostname or ''), 'DEVELOPMENT_ENDPOINT_REQUIRED')
    return HTTP(outputs['APIURL']), team, tokens


def validate(value, team):
    require(isinstance(value, dict) and value.get('schema_version') == 1 and value.get('team_id') == team,
            'CATALOG_SCOPE_MISMATCH')
    require(all(isinstance(value.get(k), list) for k in TABLES) and sum(len(value[k]) for k in TABLES) <= 1,
            'CATALOG_PAGE_INVALID')
    require('next_cursor' in value, 'CATALOG_PAGE_INVALID')
    require(len(json.dumps(value).encode()) <= 512 * 1024, 'CATALOG_PAGE_TOO_LARGE')


def client(http, token, team, clock=time.monotonic, pause=time.sleep):
    start, failures = clock(), Counter()
    for attempt in range(5):
        try:
            value = http.api('/rest/v1/rpc/get_team_catalog_page', token,
                             {'p': {'team_id': team, 'selected_team_id': team, 'limit': 1}})
            validate(value, team)
            return dict(success=True, elapsed=clock() - start, attempts=attempt + 1, failures=dict(failures))
        except Failure as error:
            failures[error.code] += 1
            retryable = error.code in RETRYABLE or error.status in (429, 500, 502, 503, 504)
            if not retryable or attempt == 4 or clock() - start >= 30:
                return dict(success=False, elapsed=clock() - start, attempts=attempt + 1, failures=dict(failures))
            pause(min(3, .3 * 2 ** attempt) + random.uniform(0, .2))
        except Exception:
            return dict(success=False, elapsed=clock() - start, attempts=attempt + 1, failures={'UNEXPECTED_ERROR_REDACTED': 1})


def arrival_delay(index, clients, window):
    require(1 <= clients <= 50 and 0 <= index < clients and isinstance(window, (int, float))
            and not isinstance(window, bool) and math.isfinite(window) and 0 <= window <= 30, 'ARRIVAL_WINDOW_INVALID')
    return window * index / max(1, clients - 1)


def qualify(http, team, tokens, clients, arrival_window=0):
    require(1 <= clients <= 50, 'CLIENT_LIMIT')
    arrival_delay(0, clients, arrival_window)
    started = time.monotonic()
    def execute(index):
        scheduled = started + arrival_delay(index, clients, arrival_window)
        delay = scheduled - time.monotonic()
        if delay > 0:
            time.sleep(delay)
        return client(http, tokens[index % len(tokens)], team)
    with ThreadPoolExecutor(max_workers=clients) as pool:
        results = list(pool.map(execute, range(clients)))
    elapsed = sorted(r['elapsed'] for r in results)
    failures = Counter()
    for result in results:
        failures.update(result['failures'])
    return dict(check='bounded_catalog_api_concurrency', clients=clients, synthetic_identities=len(tokens),
        arrival_mode='raw_burst' if arrival_window == 0 else 'paced_start', arrival_window_seconds=arrival_window,
        passed=sum(r['success'] for r in results), failed=sum(not r['success'] for r in results),
        attempts=sum(r['attempts'] for r in results), retry_codes=dict(failures),
        elapsed_seconds=round(time.monotonic() - started, 3),
        median_seconds=round(elapsed[len(elapsed) // 2], 3),
        p95_seconds=round(elapsed[max(0, (95 * len(elapsed) + 99) // 100 - 1)], 3),
        maximum_seconds=round(elapsed[-1], 3),
        scope='one first-page read per simulated client; two existing synthetic managed identities; no WebSocket fanout or device soak')


def self_test():
    class Tests(unittest.TestCase):
        def test_bad_scope_is_refused(self):
            with self.assertRaises(Failure): validate({'schema_version': 1, 'team_id': 'other'}, 'team')
        def test_missing_and_oversized_pages_are_refused(self):
            page = dict(schema_version=1, team_id='team', next_cursor=None, **{k: [] for k in TABLES})
            validate(page, 'team')
            page['songs'] = [{}, {}]
            with self.assertRaises(Failure): validate(page, 'team')
            page['songs'] = [dict(padding='x' * (512 * 1024))]
            with self.assertRaises(Failure): validate(page, 'team')
        def test_forbidden_never_retries(self):
            class API:
                def api(self, *args): raise Failure('ACCESS_REVOKED', 403)
            result = client(API(), 'opaque', 'team', pause=lambda _: self.fail('Unexpected retry'))
            self.assertFalse(result['success']); self.assertEqual(1, result['attempts'])
        def test_throttle_retries_bounded_and_preserves_failure_count(self):
            class API:
                attempts = 0
                def api(self, *args):
                    self.attempts += 1
                    if self.attempts < 3: raise Failure('HTTP_429', 429)
                    return dict(schema_version=1, team_id='team', next_cursor=None, **{k: [] for k in TABLES})
            result = client(API(), 'opaque', 'team', pause=lambda _: None)
            self.assertTrue(result['success']); self.assertEqual(3, result['attempts']); self.assertEqual(2, result['failures']['HTTP_429'])
        def test_malformed_page_does_not_become_success(self):
            class API:
                def api(self, *args): return {}
            result = client(API(), 'opaque', 'team', pause=lambda _: self.fail('Unexpected retry'))
            self.assertFalse(result['success']); self.assertEqual(1, result['attempts'])
        def test_paced_arrivals_are_explicit_bounded_and_do_not_change_raw_burst(self):
            self.assertEqual([0] * 50, [arrival_delay(i, 50, 0) for i in range(50)])
            offsets = [arrival_delay(i, 50, 5) for i in range(50)]
            self.assertEqual((0, 5), (offsets[0], offsets[-1]))
            self.assertTrue(all(b > a for a, b in zip(offsets, offsets[1:])))
            self.assertEqual(0, arrival_delay(0, 1, 5))
            for invalid in (-1, 31, float('nan'), float('inf'), True):
                with self.assertRaises(Failure): arrival_delay(0, 50, invalid)
        def test_exhausted_retries_remain_failure_in_either_arrival_mode(self):
            class API:
                def api(self, *args): raise Failure('HTTP_503', 503)
            result = client(API(), 'opaque', 'team', pause=lambda _: None)
            self.assertFalse(result['success']); self.assertEqual(5, result['attempts'])
            self.assertEqual(5, result['failures']['HTTP_503'])
    return 0 if unittest.TextTestRunner().run(unittest.defaultTestLoader.loadTestsFromTestCase(Tests)).wasSuccessful() else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path); parser.add_argument('--state-file', type=Path)
    parser.add_argument('--clients', type=int, default=20); parser.add_argument('--self-test', action='store_true')
    parser.add_argument('--arrival-window-seconds', type=float, default=0,
                        help='Optional 0-30 second evenly paced starts; default 0 preserves the original raw burst')
    args = parser.parse_args()
    if args.self_test: return self_test()
    if args.config is None or args.state_file is None: parser.error('Private config/state required')
    try:
        result = qualify(*inputs(args.config, args.state_file), args.clients, args.arrival_window_seconds)
        print(json.dumps(result, sort_keys=True), flush=True)
        return 0 if result['failed'] == 0 else 1
    except Exception as error:
        print(json.dumps(dict(check='bounded_catalog_api_concurrency', status='failed',
                             code=error.code if isinstance(error, Failure) else 'UNEXPECTED_ERROR_REDACTED')), flush=True)
        return 1


if __name__ == '__main__':
    sys.exit(main())
