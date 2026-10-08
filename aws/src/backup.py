"""Independent, version-pinned file copies plus an on-demand DynamoDB backup.

Manifests are private objects, never log entries. No retention deletions occur.
A complete result requires a usable database backup and verified file copies.
"""
import base64
import hashlib
import json
import time
import uuid
from datetime import datetime, timezone

try:
    from .domain import APIError
except ImportError:
    from domain import APIError


MAX_OBJECTS = 1000  # Pilot bound: raise deliberately after restore/load qualification.
MAX_BYTES = 104857600
PAGE_SIZE = 100


class Backup:
    def __init__(self, ddb, s3, table, assetsbucket, backupsbucket, clock=None):
        self.ddb, self.s3, self.table = ddb, s3, table
        self.assetsbucket, self.backupsbucket = assetsbucket, backupsbucket
        self.clock = clock or time.time

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

    def objects(self):
        token, seen = None, set()
        count = 0
        for _ in range(MAX_OBJECTS // PAGE_SIZE + 2):
            args = dict(Bucket=self.assetsbucket, MaxKeys=PAGE_SIZE)
            if token:
                args['ContinuationToken'] = token
            page = self.s3.list_objects_v2(**args)
            for value in page.get('Contents', []):
                count += 1
                if count > MAX_OBJECTS:
                    raise APIError('BACKUP_PILOT_LIMIT', 503)
                yield value['Key']
            if not page.get('IsTruncated'):
                return
            token = page.get('NextContinuationToken')
            if not token or token in seen:
                raise APIError('BACKUP_LIST_INCOMPLETE', 503)
            seen.add(token)
        raise APIError('BACKUP_LIST_INCOMPLETE', 503)

    def run(self):
        try:
            return self._run()
        except APIError:
            raise
        except Exception:
            raise APIError('BACKUP_UNAVAILABLE', 503) from None

    def _run(self):
        for bucket in (self.assetsbucket, self.backupsbucket):
            if self.s3.get_bucket_versioning(Bucket=bucket).get('Status') != 'Enabled':
                raise APIError('BACKUP_VERSIONING_REQUIRED', 503)
        now = self.clock()
        when = now.astimezone(timezone.utc) if isinstance(now, datetime) else datetime.fromtimestamp(now, timezone.utc)
        stamp = when.strftime('%Y%m%dT%H%M%SZ') + '-' + uuid.uuid4().hex[:12]
        name = 'worshipcue-dev-' + stamp
        receipt = self.ddb.create_backup(TableName=self.table, BackupName=name)
        arn = receipt['BackupDetails']['BackupArn']
        entries, copied = [], 0
        for key in self.objects():
            entry, changed = self.copy(key)
            entries.append(entry)
            copied += int(changed)
        status = None
        for attempt in range(6):
            details = self.ddb.describe_backup(BackupArn=arn)['BackupDescription']['BackupDetails']
            status = details['BackupStatus']
            if status == 'AVAILABLE':
                break
            if status != 'CREATING':
                raise APIError('BACKUP_DATABASE_UNAVAILABLE', 503)
            if attempt < 5:
                time.sleep(2)
        if status != 'AVAILABLE':
            raise APIError('BACKUP_DATABASE_PENDING', 503)
        manifest = dict(schema_version=1, status='complete', created_at=when.isoformat(), source_bucket=self.assetsbucket,
                        backup_bucket=self.backupsbucket, database=dict(table=self.table, backup_arn=arn, backup_name=name,
                        status=status), objects=entries)
        body = json.dumps(manifest, ensure_ascii=False, sort_keys=True, separators=(',', ':'), allow_nan=False).encode()
        checksum = base64.b64encode(hashlib.sha256(body).digest()).decode()
        manifest_key = 'manifests/' + stamp + '.json'
        written = self.s3.put_object(Bucket=self.backupsbucket, Key=manifest_key, Body=body,
                           ContentType='application/json', ChecksumSHA256=checksum, ServerSideEncryption='AES256', IfNoneMatch='*')
        manifest_version = self.version(written)
        head = self.s3.head_object(Bucket=self.backupsbucket, Key=manifest_key, VersionId=manifest_version, ChecksumMode='ENABLED')
        if head['ContentLength'] != len(body) or self.digest(self.backupsbucket, manifest_key, head, manifest_version) != hashlib.sha256(body).hexdigest():
            raise APIError('BACKUP_HASH_MISMATCH', 503)
        return dict(status='complete', objects=len(entries), copied=copied, reused=len(entries) - copied,
                    backup_created=True, backup_available=True, manifest_written=True)


def lambda_handler(event, context):
    import os
    import boto3
    try:
        result = Backup(boto3.client('dynamodb'), boto3.client('s3'), os.environ['TABLE_NAME'],
                        os.environ['ASSET_BUCKET'], os.environ['BACKUP_BUCKET']).run()
        print(json.dumps(dict(event='backup_completed', **result), separators=(',', ':')))
        return result
    except APIError as error:
        print(json.dumps(dict(event='backup_failed', code=error.code), separators=(',', ':')))
        raise RuntimeError(error.code) from None
