"""Atomic, strongly consistent key/value storage for the AWS domain.

The payload is JSON so DynamoDB's Decimal conversion cannot change the API contract.
Every conditional write compares a digest of the complete prior payload.
"""
import copy
import hashlib
import json
import threading


class Conflict(Exception):
    pass


def encode(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False)


def token(value):
    return hashlib.sha256(encode(value).encode()).hexdigest()


class MemoryStore:
    """The same transaction contract used by DynamoStore, with atomic test races."""
    def __init__(self):
        self.data = {}
        self.lock = threading.RLock()

    def get(self, pk, sk):
        with self.lock:
            return copy.deepcopy(self.data.get((pk, sk)))

    def query(self, pk, prefix="", after=None, through=None, limit=None):
        with self.lock:
            rows = [copy.deepcopy(v) for (p, s), v in sorted(self.data.items()) if p == pk and s.startswith(prefix)
                    and (after is None or s > after) and (through is None or s <= through)]
            return rows[:limit] if limit else rows

    def transact(self, writes):
        if len(writes) > 100 or len({(w['pk'], w['sk']) for w in writes}) != len(writes):
            raise ValueError("Invalid transaction size or duplicate key")
        with self.lock:
            for w in writes:
                if 'expected' in w and self.data.get((w['pk'], w['sk'])) != w['expected']:
                    raise Conflict()
            for w in writes:
                key = (w['pk'], w['sk'])
                if w['op'] == 'put':
                    self.data[key] = copy.deepcopy(w['value'])
                elif w['op'] == 'delete':
                    self.data.pop(key, None)
                elif w['op'] != 'check':
                    raise ValueError("Invalid operation")


class DynamoStore:
    def __init__(self, table_name, client=None):
        if client is None:
            import boto3  # Supplied by the managed Lambda Python runtime.
            client = boto3.client('dynamodb')
        self.client = client
        self.table_name = table_name

    @staticmethod
    def key(pk, sk):
        return {'PK': {'S': pk}, 'SK': {'S': sk}}

    def get(self, pk, sk):
        item = self.client.get_item(TableName=self.table_name, Key=self.key(pk, sk), ConsistentRead=True).get('Item')
        return json.loads(item['data']['S']) if item else None

    def query(self, pk, prefix="", after=None, through=None, limit=None):
        args = dict(TableName=self.table_name, ConsistentRead=True,
                    KeyConditionExpression='#pk = :pk',
                    ExpressionAttributeNames={'#pk': 'PK'},
                    ExpressionAttributeValues={':pk': {'S': pk}})
        if prefix:
            args.update(KeyConditionExpression='#pk = :pk AND begins_with(#sk, :prefix)',
                        ExpressionAttributeNames={'#pk':'PK','#sk':'SK'},
                        ExpressionAttributeValues={':pk':{'S':pk},':prefix':{'S':prefix}})
        if after is not None or through is not None:
            args['KeyConditionExpression'] = '#pk = :pk AND #sk BETWEEN :low AND :high'
            args['ExpressionAttributeNames'] = {'#pk':'PK','#sk':'SK'}
            args['ExpressionAttributeValues'] = {':pk': {'S': pk}, ':low': {'S': after + '\x00' if after else prefix or '\x00'},
                                               ':high': {'S': through if through else prefix + '\uffff'}}
        rows = []
        while True:
            if limit:
                args['Limit'] = limit - len(rows)
            page = self.client.query(**args)
            rows.extend(json.loads(i['data']['S']) for i in page.get('Items', []))
            if (limit and len(rows) >= limit) or not page.get('LastEvaluatedKey'):
                return rows
            args['ExclusiveStartKey'] = page['LastEvaluatedKey']

    def transact(self, writes):
        if len(writes) > 100 or len({(w['pk'], w['sk']) for w in writes}) != len(writes):
            raise ValueError("Invalid transaction size or duplicate key")
        operations = []
        for w in writes:
            op = {'TableName': self.table_name}
            if 'expected' in w:
                if w['expected'] is None:
                    op.update(ConditionExpression='attribute_not_exists(#pk)', ExpressionAttributeNames={'#pk': 'PK'})
                else:
                    op.update(ConditionExpression='#etag = :etag', ExpressionAttributeNames={'#etag': 'etag'},
                              ExpressionAttributeValues={':etag': {'S': token(w['expected'])}})
            if w['op'] == 'put':
                payload = encode(w['value'])
                if len(payload.encode()) > 350000:
                    raise ValueError("Payload exceeds safe DynamoDB item capacity")
                op['Item'] = dict(self.key(w['pk'], w['sk']), data={'S': payload}, etag={'S': token(w['value'])})
                expiry = w['value'].get('expires_at_epoch')
                if isinstance(expiry, int) and not isinstance(expiry, bool):
                    op['Item']['expires_at_epoch'] = {'N': str(expiry)}
                operations.append({'Put': op})
            elif w['op'] in ('delete', 'check'):
                op['Key'] = self.key(w['pk'], w['sk'])
                operations.append({'Delete' if w['op'] == 'delete' else 'ConditionCheck': op})
            else:
                raise ValueError("Invalid operation")
        try:
            self.client.transact_write_items(TransactItems=operations)
        except Exception as error:
            response = getattr(error, 'response', {})
            code = response.get('Error', {}).get('Code')
            if code == 'ConditionalCheckFailedException' or (
                code == 'TransactionCanceledException' and any(
                    r.get('Code') in ('ConditionalCheckFailed', 'TransactionConflict')
                    for r in response.get('CancellationReasons', []))):
                raise Conflict() from None
            raise
