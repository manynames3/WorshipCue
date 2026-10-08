"""Independent, version-pinned file copies plus an on-demand DynamoDB backup.

Manifests are private objects, never log entries. No retention deletions occur.
A complete result requires a usable database backup and verified file copies.
"""
import base64
import hashlib
import json
import re
import time
import uuid
from datetime import datetime, timezone

try:
    from .domain import APIError
except ImportError:
    from domain import APIError


MAX_BYTES = 104857600
PAGE_SIZE = 100
MAX_JOB_BYTES = 8388608  # Pilot bound: qualify larger manifests before increasing this.
STATE_KEY = 'jobs/current.json'
LEASE_SECONDS = 960  # Longer than the configured 900-second Lambda lifetime.
METRIC_NAMESPACE = 'WorshipCue/Backup'
REJECTED_CREATES = {'AccessDeniedException', 'AccessDenied', 'LimitExceededException',
    'TableInUseException', 'ResourceNotFoundException', 'ValidationException', 'ThrottlingException', 'RequestLimitExceeded'}


class Backup:
    def __init__(self, ddb, s3, table, assetsbucket, backupsbucket, clock=None, remaining=None, metrics=None, function_name='worshipcue-dev-backup'):
        self.ddb, self.s3, self.table = ddb, s3, table
        self.assetsbucket, self.backupsbucket = assetsbucket, backupsbucket
        self.clock = clock or time.time
        self.remaining = remaining or (lambda: 900000)
        self.state, self.etag, self.owner = None, None, None
        self.metrics, self.function_name = metrics, function_name

    def now(self):
        value = self.clock()
        return value.timestamp() if isinstance(value, datetime) else value

    @staticmethod
    def body(value):
        data = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':'), allow_nan=False).encode()
        if len(data) > MAX_JOB_BYTES:
            raise APIError('BACKUP_CHECKPOINT_LIMIT', 503)
        return data

    @staticmethod
    def error_code(error):
        return getattr(error, 'response', {}).get('Error', {}).get('Code')

    @staticmethod
    def valid(value):
        if not value:
            raise ValueError()

    def check_arn(self, arn):
        if not isinstance(arn, str) or not re.fullmatch(r'arn:[a-z-]+:dynamodb:[a-z0-9-]+:[0-9]{12}:table/'
                + re.escape(self.table) + r'/backup/[A-Za-z0-9-]+', arn):
            raise APIError('BACKUP_DATABASE_SCOPE_MISMATCH', 503)
        return arn

    def load_state(self):
        head = self.existing(STATE_KEY)
        if head is None:
            return None, None
        version = self.version(head)
        if not 0 < head.get('ContentLength', 0) <= MAX_JOB_BYTES:
            raise APIError('BACKUP_CHECKPOINT_LIMIT', 503)
        result = self.s3.get_object(Bucket=self.backupsbucket, Key=STATE_KEY, VersionId=version)
        stream = result['Body']
        try:
            raw = stream.read(MAX_JOB_BYTES + 1)
        finally:
            stream.close()
        if len(raw) != head['ContentLength'] or hashlib.sha256(raw).hexdigest() != self.digest(self.backupsbucket, STATE_KEY, head, version):
            raise APIError('BACKUP_HASH_MISMATCH', 503)
        try:
            state = json.loads(raw, parse_constant=lambda _: (_ for _ in ()).throw(ValueError()))
            self.valid(isinstance(state, dict) and state['schema_version'] == 1)
            self.valid((state['table'], state['source_bucket'], state['backup_bucket']) == (self.table, self.assetsbucket, self.backupsbucket))
            self.valid(re.fullmatch(r'\d{8}T\d{6}Z-[0-9a-f]{12}', state['stamp']))
            self.valid(state['backup_name'] == 'worshipcue-dev-' + state['stamp'])
            self.valid(state['status'] in ('active', 'complete') and type(state['database_requested']) is bool)
            self.valid(type(state['scan_complete']) is bool and isinstance(state['objects'], list))
            self.valid(type(state['started_at_epoch']) is int and state['started_at_epoch'] > 0)
            self.valid(datetime.fromisoformat(state['created_at']).timestamp() == state['started_at_epoch'])
            self.valid(type(state['copied']) is int and 0 <= state['copied'] <= len(state['objects']))
            self.valid(type(state['lease_until_epoch']) is int)
            self.valid(state['lease_owner'] is None or re.fullmatch('[0-9a-f]{32}', state['lease_owner']))
            previous = ''
            for row in state['objects']:
                self.valid(isinstance(row['source_key'], str) and previous < row['source_key'] and len(row['source_key'].encode()) <= 1024)
                self.valid(row['backup_key'] == 'assets/' + row['source_key'])
                self.valid(all(isinstance(row[k], str) and row[k] and row[k] != 'null' for k in ('source_version_id', 'backup_version_id')))
                self.valid(re.fullmatch('[0-9a-f]{64}', row['sha256']) and type(row['bytes']) is int and 0 < row['bytes'] <= MAX_BYTES)
                previous = row['source_key']
            self.valid(state['last_key'] == previous)
            if state['backup_arn'] is not None:
                self.check_arn(state['backup_arn'])
            self.valid(isinstance(head['ETag'], str) and head['ETag'])
        except (ValueError, KeyError, TypeError):
            raise APIError('BACKUP_CHECKPOINT_INVALID', 503) from None
        return state, head['ETag']

    def save_state(self, release=False):
        if self.state['lease_owner'] != self.owner or self.state['lease_until_epoch'] <= self.now():
            raise APIError('BACKUP_LEASE_LOST', 503)
        value = dict(self.state)
        if release:
            value.update(lease_owner=None, lease_until_epoch=0)
        body = self.body(value)
        args = dict(Bucket=self.backupsbucket, Key=STATE_KEY, Body=body, ContentType='application/json',
                    ChecksumSHA256=base64.b64encode(hashlib.sha256(body).digest()).decode(), ServerSideEncryption='AES256')
        args['IfMatch' if self.etag else 'IfNoneMatch'] = self.etag or '*'
        try:
            receipt = self.s3.put_object(**args)
        except Exception as error:
            if self.error_code(error) in ('PreconditionFailed', '412', 'ConditionalRequestConflict', '409'):
                raise APIError('BACKUP_CHECKPOINT_CONFLICT', 503) from None
            raise
        self.version(receipt)
        if not isinstance(receipt.get('ETag'), str) or not receipt['ETag']:
            raise APIError('BACKUP_CHECKPOINT_INVALID', 503)
        self.etag, self.state = receipt['ETag'], value

    def acquire(self, scheduled):
        state, self.etag = self.load_state()
        now = int(self.now())
        when = datetime.fromtimestamp(now, timezone.utc)
        if state is not None and state['lease_owner'] is not None and state['lease_until_epoch'] > now:
            return dict(status='busy', objects=len(state['objects']), backup_created=state['backup_arn'] is not None, manifest_written=False)
        if state is None or state['status'] == 'complete':
            if scheduled and (when.hour < 4 or (state and state['created_at'][:10] == when.date().isoformat())):
                return dict(status='idle', backup_created=False, manifest_written=False)
            stamp = when.strftime('%Y%m%dT%H%M%SZ') + '-' + uuid.uuid4().hex[:12]
            state = dict(schema_version=1, stamp=stamp, backup_name='worshipcue-dev-' + stamp,
                table=self.table, source_bucket=self.assetsbucket, backup_bucket=self.backupsbucket,
                created_at=when.isoformat(), started_at_epoch=now, status='active',
                database_requested=False, backup_arn=None, objects=[], copied=0, last_key='', scan_complete=False)
        self.owner = uuid.uuid4().hex
        state.update(lease_owner=self.owner, lease_until_epoch=now + LEASE_SECONDS)
        self.state = state
        self.save_state()
        return None

    def database(self):
        if not self.state['database_requested']:
            # Persist intent before the non-idempotent provider call. Never repeat it on an unknown outcome.
            self.state['database_requested'] = True
            self.save_state()
            try:
                receipt = self.ddb.create_backup(TableName=self.table, BackupName=self.state['backup_name'])
            except Exception as error:
                status = getattr(error, 'response', {}).get('ResponseMetadata', {}).get('HTTPStatusCode')
                if self.error_code(error) in REJECTED_CREATES and status in (400, 403):
                    self.state['database_requested'] = False
                    self.save_state()
                    raise APIError('BACKUP_DATABASE_REJECTED', 503) from None
                raise
            self.state['backup_arn'] = self.check_arn(receipt['BackupDetails']['BackupArn'])
            self.save_state()
        elif self.state['backup_arn'] is None:
            found, token, seen = [], None, set()
            for _ in range(10):
                args = dict(TableName=self.table, BackupType='USER', Limit=100,
                    TimeRangeLowerBound=datetime.fromtimestamp(self.state['started_at_epoch'] - 300, timezone.utc))
                if token:
                    args['ExclusiveStartBackupArn'] = token
                page = self.ddb.list_backups(**args)
                found += [v for v in page.get('BackupSummaries', []) if v.get('BackupName') == self.state['backup_name'] and v.get('TableName') == self.table]
                token = page.get('LastEvaluatedBackupArn')
                if not token:
                    break
                if token in seen:
                    raise APIError('BACKUP_DATABASE_LIST_INCOMPLETE', 503)
                seen.add(token)
            if token:
                raise APIError('BACKUP_DATABASE_LIST_INCOMPLETE', 503)
            if len(found) != 1:
                raise APIError('BACKUP_DATABASE_REQUEST_UNCERTAIN', 503)
            self.state['backup_arn'] = self.check_arn(found[0]['BackupArn'])
            self.save_state()
        value = self.ddb.describe_backup(BackupArn=self.state['backup_arn'])['BackupDescription']
        details = value['BackupDetails']
        if details.get('BackupName') != self.state['backup_name'] or value.get('SourceTableDetails', {}).get('TableName') != self.table:
            raise APIError('BACKUP_DATABASE_SCOPE_MISMATCH', 503)
        if details.get('BackupStatus') not in ('CREATING', 'AVAILABLE'):
            raise APIError('BACKUP_DATABASE_UNAVAILABLE', 503)
        return details['BackupStatus']

    @staticmethod
    def version(value):
        version = value.get('VersionId')
        if not isinstance(version, str) or not version or version == 'null':
            raise APIError('BACKUP_VERSIONING_REQUIRED', 503)
        return version

    def digest(self, bucket, key, head, version):
        count = head.get('ContentLength')
        if isinstance(count, bool) or not isinstance(count, int) or not 0 < count <= MAX_BYTES:
            raise APIError('BACKUP_ASSET_LIMIT', 503)
        checksum = head.get('ChecksumSHA256')
        if checksum and head.get('ChecksumType', 'FULL_OBJECT') == 'FULL_OBJECT':
            try:
                raw = base64.b64decode(checksum, validate=True)
                if len(raw) != 32:
                    raise ValueError()
                return raw.hex()
            except (ValueError, TypeError):
                raise APIError('BACKUP_HASH_MISMATCH', 503) from None
        # Older objects or multipart composite checksums need a full-object hash.
        result = self.s3.get_object(Bucket=bucket, Key=key, VersionId=version)
        body = result['Body']
        digest, received = hashlib.sha256(), 0
        try:
            while True:
                part = body.read(min(1048576, count - received + 1))
                if not part:
                    break
                received += len(part)
                if received > count:
                    raise APIError('BACKUP_HASH_MISMATCH', 503)
                digest.update(part)
        finally:
            body.close()
        if received != count:
            raise APIError('BACKUP_HASH_MISMATCH', 503)
        return digest.hexdigest()

    def existing(self, key):
        try:
            return self.s3.head_object(Bucket=self.backupsbucket, Key=key, ChecksumMode='ENABLED')
        except Exception as error:
            code = getattr(error, 'response', {}).get('Error', {}).get('Code')
            if code in ('404', 'NoSuchKey', 'NotFound'):
                return None
            raise

    def copy(self, key):
        source = self.s3.head_object(Bucket=self.assetsbucket, Key=key, ChecksumMode='ENABLED')
        source_version = self.version(source)
        sha = self.digest(self.assetsbucket, key, source, source_version)
        destination = 'assets/' + key
        prior = self.existing(destination)
        metadata = dict(source.get('Metadata', {}), **{'source-version-id': source_version,
                        'source-sha256': sha, 'source-bytes': str(source['ContentLength'])})
        matching = prior and all(prior.get('Metadata', {}).get(k) == metadata[k]
                                 for k in ('source-version-id', 'source-sha256', 'source-bytes'))
        copied = not matching
        if matching:
            backup_version = self.version(prior)
            if prior['ContentLength'] != source['ContentLength'] or self.digest(self.backupsbucket, destination, prior, backup_version) != sha:
                raise APIError('BACKUP_HASH_MISMATCH', 503)
        else:
            args = dict(Bucket=self.backupsbucket, Key=destination,
                        CopySource=dict(Bucket=self.assetsbucket, Key=key, VersionId=source_version),
                        MetadataDirective='REPLACE', Metadata=metadata, ChecksumAlgorithm='SHA256', ServerSideEncryption='AES256')
            for field in ('ContentType', 'CacheControl', 'ContentDisposition', 'ContentEncoding', 'ContentLanguage', 'Expires'):
                if source.get(field) is not None:
                    args[field] = source[field]
            if source.get('ETag'):
                args['CopySourceIfMatch'] = source['ETag']
            receipt = self.s3.copy_object(**args)
            backup_version = self.version(receipt)
            prior = self.s3.head_object(Bucket=self.backupsbucket, Key=destination, VersionId=backup_version, ChecksumMode='ENABLED')
            if prior['ContentLength'] != source['ContentLength'] or self.digest(self.backupsbucket, destination, prior, backup_version) != sha:
                raise APIError('BACKUP_HASH_MISMATCH', 503)
        entry = dict(source_key=key, source_version_id=source_version, backup_key=destination, backup_version_id=backup_version,
                     sha256=sha, bytes=source['ContentLength'], content_type=source.get('ContentType'), metadata=source.get('Metadata', {}))
        return entry, copied

    def run(self, scheduled=False):
        try:
            return self._run(scheduled)
        except APIError:
            self.release_after_failure()
            raise
        except Exception:
            self.release_after_failure()
            raise APIError('BACKUP_UNAVAILABLE', 503) from None

    def release_after_failure(self):
        try:
            if self.state is not None and self.state.get('lease_owner') == self.owner and self.owner is not None:
                self.save_state(release=True)
        except Exception:
            # A lost/unknown conditional write is left for the next owner after lease expiry.
            pass

    def _run(self, scheduled):
        for bucket in (self.assetsbucket, self.backupsbucket):
            if self.s3.get_bucket_versioning(Bucket=bucket).get('Status') != 'Enabled':
                raise APIError('BACKUP_VERSIONING_REQUIRED', 503)
        idle = self.acquire(scheduled)
        if idle is not None:
            return idle
        status = self.database()
        if not self.state['scan_complete']:
            args = dict(Bucket=self.assetsbucket, MaxKeys=PAGE_SIZE)
            if self.state['last_key']:
                args['StartAfter'] = self.state['last_key']
            page = self.s3.list_objects_v2(**args)
            rows = page.get('Contents', [])
            if not isinstance(rows, list) or len(rows) > PAGE_SIZE or type(page.get('IsTruncated')) is not bool or (page['IsTruncated'] and not rows):
                raise APIError('BACKUP_LIST_INCOMPLETE', 503)
            exhausted = True
            for value in rows:
                if self.remaining() <= 60000 or self.state['lease_until_epoch'] <= self.now() + 60:
                    exhausted = False
                    break
                key = value.get('Key')
                if not isinstance(key, str) or key <= self.state['last_key'] or len(key.encode()) > 1024:
                    raise APIError('BACKUP_LIST_INCOMPLETE', 503)
                entry, changed = self.copy(key)
                self.state['objects'].append(entry)
                self.state['copied'] += int(changed)
                self.state['last_key'] = key
                self.body(self.state)
            self.state['scan_complete'] = exhausted and not page['IsTruncated']
            self.save_state()
        if not self.state['scan_complete'] or status != 'AVAILABLE':
            self.save_state(release=True)
            return dict(status='in_progress', objects=len(self.state['objects']), copied=self.state['copied'],
                backup_created=True, backup_available=status == 'AVAILABLE', manifest_written=False)
        entries, copied = self.state['objects'], self.state['copied']
        manifest = dict(schema_version=1, status='complete', created_at=self.state['created_at'], source_bucket=self.assetsbucket,
                        backup_bucket=self.backupsbucket, database=dict(table=self.table, backup_arn=self.state['backup_arn'], backup_name=self.state['backup_name'],
                        status=status), objects=entries)
        body = self.body(manifest)
        checksum = base64.b64encode(hashlib.sha256(body).digest()).decode()
        manifest_key = 'manifests/' + self.state['stamp'] + '.json'
        prior = self.existing(manifest_key)
        if prior is None:
            written = self.s3.put_object(Bucket=self.backupsbucket, Key=manifest_key, Body=body,
                           ContentType='application/json', ChecksumSHA256=checksum, ServerSideEncryption='AES256', IfNoneMatch='*')
            manifest_version = self.version(written)
        else:
            manifest_version = self.version(prior)
        head = self.s3.head_object(Bucket=self.backupsbucket, Key=manifest_key, VersionId=manifest_version, ChecksumMode='ENABLED')
        if head['ContentLength'] != len(body) or self.digest(self.backupsbucket, manifest_key, head, manifest_version) != hashlib.sha256(body).hexdigest():
            raise APIError('BACKUP_HASH_MISMATCH', 503)
        if self.metrics is None:
            raise APIError('BACKUP_METRICS_REQUIRED', 503)
        self.metrics.put_metric_data(Namespace=METRIC_NAMESPACE, MetricData=[{
            'MetricName':'Completed', 'Dimensions':[{'Name':'FunctionName','Value':self.function_name}],
            'Timestamp':datetime.fromtimestamp(self.now(), timezone.utc), 'Value':1, 'Unit':'Count'}])
        self.state['status'] = 'complete'
        self.save_state(release=True)
        return dict(status='complete', objects=len(entries), copied=copied, reused=len(entries) - copied,
                    backup_created=True, backup_available=True, manifest_written=True)


def lambda_handler(event, context):
    import os
    import boto3
    from botocore.config import Config
    try:
        # CreateBackup has no idempotency token; ambiguous outcomes are resolved from the saved job.
        ddb = boto3.client('dynamodb', config=Config(retries={'total_max_attempts':1,'mode':'standard'}, connect_timeout=5, read_timeout=30))
        result = Backup(ddb, boto3.client('s3'), os.environ['TABLE_NAME'],
                        os.environ['ASSET_BUCKET'], os.environ['BACKUP_BUCKET'],
                        remaining=context.get_remaining_time_in_millis if context else None,
                        metrics=boto3.client('cloudwatch'), function_name=os.environ['AWS_LAMBDA_FUNCTION_NAME']).run(scheduled=event.get('source') == 'aws.events')
        print(json.dumps(dict(event='backup_completed' if result['status'] == 'complete' else 'backup_progress', **result), separators=(',', ':')))
        return result
    except APIError as error:
        print(json.dumps(dict(event='backup_failed', code=error.code), separators=(',', ':')))
        raise RuntimeError(error.code) from None
