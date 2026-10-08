import copy
import json
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'src'))
from domain import APIError, _Operation
from store import Conflict, DynamoStore, TRANSACTION_ATTEMPTS, token


class KeyClient:
    def query(self, **args):
        # Real DynamoDB rejects empty sort-key values, even in begins_with.
        for name, value in args['ExpressionAttributeValues'].items():
            if name != ':pk' and value.get('S') == '':
                raise ValueError('Empty sort-key value')
        self.args = args
        return {'Items':[]}


class ProviderFailure(Exception):
    def __init__(self, code, reasons=None):
        self.response = {'Error': {'Code': code}}
        if reasons is not None:
            self.response['CancellationReasons'] = reasons


def cancellation(*codes):
    return ProviderFailure('TransactionCanceledException', [{'Code': code} for code in codes])


class TransactionClient:
    """Apply the serialized CAS contract after controlled AWS cancellation responses."""
    def __init__(self, outcomes=()):
        self.outcomes = list(outcomes)
        self.calls = []
        self.rows = {('T#test', 'membership'): {'active': True, 'revision': 1}}

    def transact_write_items(self, **args):
        self.calls.append(copy.deepcopy(args))
        if self.outcomes:
            outcome = self.outcomes.pop(0)
            if isinstance(outcome, Exception):
                raise outcome
        conditions = []
        updates = []
        for operation in args['TransactItems']:
            name, data = next(iter(operation.items()))
            item = data.get('Key') or data['Item']
            key = (item['PK']['S'], item['SK']['S'])
            current = self.rows.get(key)
            expression = data.get('ConditionExpression')
            valid = expression is None or (
                current is None if expression == 'attribute_not_exists(#pk)' else
                current is not None and data['ExpressionAttributeValues'][':etag']['S'] == token(current))
            conditions.append('None' if valid else 'ConditionalCheckFailed')
            if name == 'Put':
                updates.append((key, json.loads(data['Item']['data']['S'])))
            elif name == 'Delete':
                updates.append((key, None))
        if 'ConditionalCheckFailed' in conditions:
            raise cancellation(*conditions)
        for key, value in updates:
            if value is None:
                self.rows.pop(key, None)
            else:
                self.rows[key] = value
        return {}


class StoreContractTests(unittest.TestCase):
    @staticmethod
    def transaction(client):
        operation = _Operation(DynamoStore('table', client), lambda: 0,
                               {'id': '11111111-1111-4111-8111-111111111111', 'guest': False})
        operation.check('T#test', 'membership', {'active': True, 'revision': 1})
        operation.put('U#test', 'cursor', {'scope': 'test', 'revision': 1})
        return operation

    def test_whole_partition_fanout_does_not_send_empty_sort_key(self):
        client = KeyClient()
        self.assertEqual(DynamoStore('table',client).query('WS#team'),[])
        self.assertEqual(client.args['KeyConditionExpression'],'#pk = :pk')
        self.assertTrue(client.args['ConsistentRead'])

    def test_upper_bounded_whole_partition_has_nonempty_lower_key(self):
        client = KeyClient()
        self.assertEqual(DynamoStore('table',client).query('partition',through='row9'),[])
        self.assertEqual(client.args['ExpressionAttributeValues'][':low'],{'S':'\x00'})

    def test_aborted_contention_retries_exact_transaction_and_commits_once(self):
        client = TransactionClient([cancellation('TransactionConflict', 'None'),
                                    cancellation('None', 'TransactionConflict')])
        with patch('store.time.sleep') as sleep, patch('store.random.uniform', return_value=0.025) as jitter:
            self.transaction(client).commit()
        self.assertEqual(len(client.calls), 3)
        self.assertEqual(client.calls, [client.calls[0]] * 3)
        self.assertEqual(len(client.calls[0]['ClientRequestToken']), 36)
        self.assertEqual(client.rows[('U#test', 'cursor')], {'scope': 'test', 'revision': 1})
        self.assertEqual(sleep.call_count, 2)
        self.assertEqual([call.args for call in jitter.call_args_list], [(0, 0.05), (0, 0.1)])

    def test_membership_revocation_during_pause_fails_original_cas_immediately(self):
        client = TransactionClient([cancellation('TransactionConflict', 'None')])
        def revoke(_):
            client.rows[('T#test', 'membership')] = {'active': False, 'revision': 2}
        with patch('store.time.sleep', side_effect=revoke) as sleep:
            with self.assertRaises(APIError) as result:
                self.transaction(client).commit()
        self.assertEqual(result.exception.code, 'REVISION_CONFLICT')
        self.assertEqual(result.exception.status, 409)
        self.assertEqual(client.calls[0], client.calls[1])
        self.assertEqual(sleep.call_count, 1)
        self.assertNotIn(('U#test', 'cursor'), client.rows)

    def test_mixed_conditional_and_contention_never_retries(self):
        client = TransactionClient([cancellation('TransactionConflict', 'ConditionalCheckFailed')])
        with patch('store.time.sleep') as sleep:
            with self.assertRaises(APIError) as result:
                self.transaction(client).commit()
        self.assertEqual(result.exception.code, 'REVISION_CONFLICT')
        self.assertEqual(len(client.calls), 1)
        sleep.assert_not_called()

    def test_incomplete_unknown_or_no_contention_reasons_never_retry(self):
        errors = [
            ProviderFailure('TransactionCanceledException'),
            ProviderFailure('TransactionCanceledException', []),
            cancellation('TransactionConflict'),
            cancellation('TransactionConflict', 'ValidationError'),
            cancellation('TransactionConflict', None),
            cancellation('None', 'None'),
            ProviderFailure('TransactionCanceledException', [{'Code': 'TransactionConflict'}, {}]),
            ProviderFailure('TransactionCanceledException', [{'Code': 'TransactionConflict'}, 'None']),
            ProviderFailure('InternalServerError'),
            TimeoutError('synthetic transport failure'),
        ]
        for error in errors:
            with self.subTest(error=type(error).__name__, response=getattr(error, 'response', {})):
                client = TransactionClient([error])
                with patch('store.time.sleep') as sleep:
                    with self.assertRaises(type(error)) as result:
                        self.transaction(client).commit()
                self.assertIs(result.exception, error)
                self.assertEqual(len(client.calls), 1)
                self.assertNotIn(('U#test', 'cursor'), client.rows)
                sleep.assert_not_called()

    def test_exhausted_contention_is_unavailable_not_a_revision_conflict(self):
        import handler
        error = cancellation('TransactionConflict', 'None')
        client = TransactionClient([error] * TRANSACTION_ATTEMPTS)
        operation = self.transaction(client)
        class Application:
            def handle(self, _):
                operation.commit()
        with patch('store.time.sleep') as sleep, patch('store.random.uniform', side_effect=lambda _, ceiling: ceiling), \
                patch('handler.application', return_value=Application()), patch('builtins.print'):
            result = handler.lambda_handler({}, None)
        self.assertEqual(result['statusCode'], 503)
        self.assertEqual(json.loads(result['body']), {'message': 'UNAVAILABLE'})
        self.assertEqual(len(client.calls), TRANSACTION_ATTEMPTS)
        self.assertEqual(client.calls, [client.calls[0]] * TRANSACTION_ATTEMPTS)
        self.assertEqual(sleep.call_count, TRANSACTION_ATTEMPTS - 1)
        self.assertLessEqual(sum(call.args[0] for call in sleep.call_args_list), 0.75)
        self.assertNotIn(('U#test', 'cursor'), client.rows)

    def test_direct_conditional_failure_preserves_conflict_without_retry(self):
        client = TransactionClient([ProviderFailure('ConditionalCheckFailedException')])
        with patch('store.time.sleep') as sleep:
            with self.assertRaises(Conflict):
                DynamoStore('table', client).transact([
                    {'op': 'check', 'pk': 'T#test', 'sk': 'membership', 'expected': {'active': True}}])
        self.assertEqual(len(client.calls), 1)
        sleep.assert_not_called()


if __name__ == '__main__':
    unittest.main()
