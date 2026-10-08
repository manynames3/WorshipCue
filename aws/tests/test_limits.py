import json
import sys
import threading
import unittest
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'src'))
from domain import APIError
from limits import Limits
from store import Conflict, MemoryStore


class LimitsTests(unittest.TestCase):
    def setUp(self):
        self.store = MemoryStore()
        self.time = 86400
        self.limits = Limits(self.store, lambda: self.time)

    def rejected(self, action, source='192.0.2.1', destination=None, code='RATE_LIMITED', status=429):
        with self.assertRaises(APIError) as caught:
            self.limits.check(action, source, destination)
        self.assertEqual(code, caught.exception.code)
        self.assertEqual(status, caught.exception.status)

    def test_otp_destination_minute_cap_and_email_normalization(self):
        self.limits.check('otp', '192.0.2.1', ' Musician@Example.test ')
        before = json.dumps(list(self.store.data.items()), sort_keys=True)
        self.rejected('otp', '192.0.2.2', 'musician@example.test')
        self.assertEqual(before, json.dumps(list(self.store.data.items()), sort_keys=True))
        self.time += 60
        self.limits.check('otp', '192.0.2.2', 'MUSICIAN@example.test')

    def test_otp_destination_daily_exact_cap(self):
        for i in range(10):
            self.time = 86400 + i * 60
            self.limits.check('otp', '192.0.2.1', 'musician@example.test')
        self.time += 60
        self.rejected('otp', destination='musician@example.test')
        self.time = 172800
        self.limits.check('otp', '192.0.2.1', 'musician@example.test')

    def test_otp_source_minute_exact_cap(self):
        for i in range(5):
            self.limits.check('otp', '192.0.2.1', f'musician{i}@example.test')
        self.rejected('otp', destination='sixth@example.test')
        self.time += 60
        self.limits.check('otp', '192.0.2.1', 'sixth@example.test')

    def test_otp_source_daily_exact_cap(self):
        for i in range(50):
            self.time = 86400 + (i // 5) * 60
            self.limits.check('otp', '192.0.2.1', f'musician{i}@example.test')
        self.time += 60
        self.rejected('otp', destination='fifty-first@example.test')

    def test_otp_global_daily_exact_cap(self):
        for i in range(200):
            self.limits.check('otp', f'192.0.2.{i + 1}', f'musician{i}@example.test')
        self.rejected('otp', '198.51.100.1', 'new@example.test')
        self.time = 172800
        self.limits.check('otp', '198.51.100.1', 'new@example.test')

    def test_verify_and_refresh_independent_minute_exact_caps(self):
        for _ in range(30):
            self.limits.check('verify', '192.0.2.1')
        self.rejected('verify')
        for _ in range(60):
            self.limits.check('refresh', '192.0.2.1')
        self.rejected('refresh')
        self.time += 60
        self.limits.check('verify', '192.0.2.1')
        self.limits.check('refresh', '192.0.2.1')

    def test_guest_source_minute_and_daily_exact_caps(self):
        for i in range(20):
            self.time = 86400 + (i // 5) * 60
            self.limits.check('guest', '192.0.2.1')
            if i == 4:
                self.rejected('guest')
        self.time += 60
        self.rejected('guest')
        self.time = 172800
        self.limits.check('guest', '192.0.2.1')

    def test_guest_global_daily_exact_cap(self):
        for i in range(100):
            self.limits.check('guest', f'192.0.2.{i + 1}')
        self.rejected('guest', '198.51.100.1')

    def test_counters_contain_no_raw_addresses_and_use_window_end_ttl(self):
        self.time = 86459
        self.limits.check('otp', '2001:db8::1', 'Private.Person@Example.test')
        serialized = json.dumps(list(self.store.data.items()), sort_keys=True)
        self.assertNotIn('2001:db8', serialized)
        self.assertNotIn('private.person', serialized.casefold())
        self.assertNotIn('example.test', serialized)
        self.assertEqual(5, len(self.store.data))
        for (pk, sk), row in self.store.data.items():
            self.assertRegex(pk, r'^LIMIT#[0-9a-f]{64}$')
            self.assertEqual({'count', 'expires_at_epoch'}, set(row))
            self.assertIn(row['expires_at_epoch'], (86460, 172800))
        self.limits.check('otp', '2001:0db8:0:0:0:0:0:1', 'another@example.test')
        # Equivalent IPv6 spellings share the same source counters.
        source = [row for (_, sk), row in self.store.data.items() if '#source#' in sk]
        self.assertEqual([2, 2], sorted(row['count'] for row in source))

    def test_window_rollover_does_not_depend_on_delayed_dynamo_ttl_deletion(self):
        self.time = 86459
        self.limits.check('otp', '192.0.2.1', 'musician@example.test')
        self.rejected('otp', destination='musician@example.test')
        self.time = 86460
        self.limits.check('otp', '192.0.2.1', 'musician@example.test')
        self.assertTrue(any(r['expires_at_epoch'] == 86460 for r in self.store.data.values()))
        self.assertTrue(any(r['expires_at_epoch'] == 86520 for r in self.store.data.values()))

    def test_concurrent_requests_cannot_exceed_source_cap(self):
        barrier = threading.Barrier(12)
        def attempt(i):
            barrier.wait(timeout=5)
            try:
                self.limits.check('otp', '192.0.2.1', f'musician{i}@example.test')
                return 'allowed'
            except APIError as error:
                return error.code
        with ThreadPoolExecutor(max_workers=12) as pool:
            results = list(pool.map(attempt, range(12)))
        self.assertEqual(5, results.count('allowed'))
        self.assertEqual(7, results.count('RATE_LIMITED'))
        source = [row['count'] for (_, sk), row in self.store.data.items() if '#source#60#' in sk]
        self.assertEqual([5], source)

    def test_conflict_retries_and_rechecks_current_limit(self):
        original = self.store.transact
        attempts = 0
        def transient(writes):
            nonlocal attempts
            attempts += 1
            if attempts == 1:
                raise Conflict()
            original(writes)
        self.store.transact = transient
        self.limits.check('verify', '192.0.2.1')
        self.assertEqual(2, attempts)
        self.assertEqual([1], [row['count'] for row in self.store.data.values()])

    def test_conflict_retry_observes_competing_request_at_cap(self):
        original = self.store.transact
        attempts = 0
        def competing(writes):
            nonlocal attempts
            attempts += 1
            if attempts == 1:
                original([dict(writes[0], value=dict(writes[0]['value'], count=30))])
                raise Conflict()
            original(writes)
        self.store.transact = competing
        self.rejected('verify')
        self.assertEqual(1, attempts)
        self.assertEqual([30], [row['count'] for row in self.store.data.values()])

    def test_persistent_conflicts_fail_closed_after_four_attempts(self):
        attempts = []
        def unavailable(writes):
            attempts.append(True)
            raise Conflict()
        self.store.transact = unavailable
        self.rejected('verify', code='UNAVAILABLE', status=503)
        self.assertEqual(4, len(attempts))
        self.assertEqual({}, self.store.data)

    def test_storage_read_and_write_failures_fail_closed(self):
        class BrokenRead:
            def get(self, pk, sk):
                raise RuntimeError('Details must never escape')
        class BrokenWrite(MemoryStore):
            def transact(self, writes):
                raise RuntimeError('Details must never escape')
        for store in (BrokenRead(), BrokenWrite()):
            with self.assertRaises(APIError) as caught:
                Limits(store, lambda: self.time).check('verify', '192.0.2.1')
            self.assertEqual('UNAVAILABLE', str(caught.exception))
            self.assertEqual(503, caught.exception.status)

    def test_datetime_clock_and_invalid_input(self):
        Limits(self.store, lambda: datetime(2026, 10, 8, tzinfo=timezone.utc)).check('verify', '192.0.2.1')
        self.rejected('unsupported', code='INVALID_INPUT', status=400)
        self.rejected('otp', code='INVALID_INPUT', status=400)
        self.rejected('verify', 'untrusted-source', code='INVALID_INPUT', status=400)
        with self.assertRaises(APIError) as caught:
            Limits(self.store, lambda: float('nan')).check('verify', '192.0.2.1')
        self.assertEqual(503, caught.exception.status)


if __name__ == '__main__':
    unittest.main()
