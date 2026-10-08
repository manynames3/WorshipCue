import sys
import unittest
from pathlib import Path

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'src'))
from store import DynamoStore


class KeyClient:
    def query(self, **args):
        # Real DynamoDB rejects empty sort-key values, even in begins_with.
        for name, value in args['ExpressionAttributeValues'].items():
            if name != ':pk' and value.get('S') == '':
                raise ValueError('Empty sort-key value')
        self.args = args
        return {'Items':[]}


class StoreContractTests(unittest.TestCase):
    def test_whole_partition_fanout_does_not_send_empty_sort_key(self):
        client = KeyClient()
        self.assertEqual(DynamoStore('table',client).query('WS#team'),[])
        self.assertEqual(client.args['KeyConditionExpression'],'#pk = :pk')
        self.assertTrue(client.args['ConsistentRead'])

    def test_upper_bounded_whole_partition_has_nonempty_lower_key(self):
        client = KeyClient()
        self.assertEqual(DynamoStore('table',client).query('partition',through='row9'),[])
        self.assertEqual(client.args['ExpressionAttributeValues'][':low'],{'S':'\x00'})


if __name__ == '__main__':
    unittest.main()
