import base64
import copy
import hashlib
import io
import json
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'src'))
from backup import Backup
from domain import APIError


def checksum(data):
    return base64.b64encode(hashlib.sha256(data).digest()).decode()


class MissingObject(Exception):
    response = {'Error': {'Code': 'NoSuchKey'}}


class FakeDDB:
    def __init__(self):
        self.created = []
        self.states = ['AVAILABLE']

    def create_backup(self, **args):
        self.created.append(args)
        return {'BackupDetails': {'BackupArn': 'arn:aws:dynamodb:us-east-1:123456789012:table/fixture/backup/' + str(len(self.created))}}

    def describe_backup(self, **args):
        status = self.states.pop(0) if len(self.states) > 1 else self.states[0]
        return {'BackupDescription': {'BackupDetails': {'BackupStatus': status}}}


class FakeS3:
    def __init__(self):
        self.current, self.versions = {}, {}
        self.copy_calls, self.put_calls, self.list_calls, self.get_calls = [], [], [], []
        self.enabled = True
        self.corrupt_copy, self.corrupt_manifest = False, False

    def add(self, bucket, key, data=b'opaque-fixture-bytes', version=None, **headers):
        version = version or 'version-' + str(len(self.versions) + 1)
        row = dict(Body=data, ContentLength=len(data), Metadata={'fixture': 'safe'}, ContentType='application/pdf',
                   ChecksumSHA256=checksum(data), ChecksumType='FULL_OBJECT', VersionId=version, ETag='"fixture-etag"')
        row.update(headers)
        self.versions[bucket, key, version] = row
        self.current[bucket, key] = version
        return version

    def get_bucket_versioning(self, **args):
        return {'Status': 'Enabled' if self.enabled else 'Suspended'}

    def head_object(self, **args):
        bucket, key = args['Bucket'], args['Key']
        version = args.get('VersionId', self.current.get((bucket, key)))
        row = self.versions.get((bucket, key, version))
        if row is None:
            raise MissingObject()
        return {k: copy.deepcopy(v) for k, v in row.items() if k != 'Body'}

    def get_object(self, **args):
        self.get_calls.append(args)
        row = self.versions[args['Bucket'], args['Key'], args['VersionId']]
        return {'Body': io.BytesIO(row['Body'])}

    def list_objects_v2(self, **args):
        self.list_calls.append(args)
        keys = sorted(k for bucket, k in self.current if bucket == args['Bucket'])
        start = int(args.get('ContinuationToken', 0))
        count = args['MaxKeys']
        page = dict(Contents=[{'Key': k} for k in keys[start:start + count]], IsTruncated=start + count < len(keys))
        if page['IsTruncated']:
            page['NextContinuationToken'] = str(start + count)
        return page

    def copy_object(self, **args):
        self.copy_calls.append(args)
        source = args['CopySource']
        row = self.versions[source['Bucket'], source['Key'], source['VersionId']]
        data = row['Body'] + b'corrupt' if self.corrupt_copy else row['Body']
        headers = {k: v for k, v in args.items() if k in ('Metadata', 'ContentType', 'CacheControl', 'ContentDisposition', 'ContentEncoding', 'ContentLanguage', 'Expires')}
        version = self.add(args['Bucket'], args['Key'], data, **headers)
        return {'VersionId': version, 'CopyObjectResult': {'ChecksumSHA256': checksum(data)}}

    def put_object(self, **args):
        self.put_calls.append(args)
        data = args['Body'] + b'corrupt' if self.corrupt_manifest else args['Body']
        version = self.add(args['Bucket'], args['Key'], data, ContentType=args['ContentType'], Metadata={})
        return {'VersionId': version}


class BackupTests(unittest.TestCase):
    def setUp(self):
        self.ddb, self.s3 = FakeDDB(), FakeS3()
        self.job = Backup(self.ddb, self.s3, 'fixture-table', 'assets-bucket', 'backup-bucket', lambda: 1791460800)

    def error(self, code):
        with self.assertRaises(APIError) as caught:
            self.job.run()
        self.assertEqual(code, caught.exception.code)
        self.assertEqual(503, caught.exception.status)

    def test_backup_copies_version_pinned_objects_and_verifies_private_manifest(self):
        source_version = self.s3.add('assets-bucket', 'team/user/fixture.pdf', CacheControl='private', ContentDisposition='inline')
        self.s3.add('assets-bucket', 'team/user/fixture.drawing', b'opaque-native-fixture', ContentType='application/octet-stream')
        result = self.job.run()
        self.assertEqual(dict(status='complete', objects=2, copied=2, reused=0, backup_created=True, backup_available=True, manifest_written=True), result)
        self.assertRegex(self.ddb.created[0]['BackupName'], r'^worshipcue-dev-\d{8}T\d{6}Z-[0-9a-f]{12}$')
        pdf = next(c for c in self.s3.copy_calls if c['Key'].endswith('.pdf'))
        self.assertEqual(source_version, pdf['CopySource']['VersionId'])
        self.assertEqual(source_version, pdf['Metadata']['source-version-id'])
        self.assertEqual('safe', pdf['Metadata']['fixture'])
        self.assertEqual('private', pdf['CacheControl'])
        self.assertEqual('inline', pdf['ContentDisposition'])
        self.assertEqual('SHA256', pdf['ChecksumAlgorithm'])
        manifest = json.loads(self.s3.put_calls[0]['Body'])
        self.assertEqual('complete', manifest['status'])
        self.assertEqual(2, len(manifest['objects']))
        self.assertEqual('AVAILABLE', manifest['database']['status'])
        for entry in manifest['objects']:
            row = self.s3.versions['backup-bucket', entry['backup_key'], entry['backup_version_id']]
            self.assertEqual(entry['sha256'], hashlib.sha256(row['Body']).hexdigest())
        put = self.s3.put_calls[0]
        self.assertEqual('*', put['IfNoneMatch'])
        self.assertEqual(checksum(put['Body']), put['ChecksumSHA256'])
        self.assertNotIn('team/user', json.dumps(result))
        self.assertNotIn('fixture.pdf', json.dumps(result))

    def test_second_run_reuses_only_verified_identical_source_versions(self):
        self.s3.add('assets-bucket', 'fixture.pdf')
        self.job.run()
        result = self.job.run()
        self.assertEqual(0, result['copied'])
        self.assertEqual(1, result['reused'])
        self.assertEqual(1, len(self.s3.copy_calls))
        self.assertEqual(2, len(self.ddb.created))
        self.assertNotEqual(self.ddb.created[0]['BackupName'], self.ddb.created[1]['BackupName'])

    def test_new_source_version_keeps_old_backup_version(self):
        old_source = self.s3.add('assets-bucket', 'fixture.pdf', b'old-version')
        self.job.run()
        old_backup = self.s3.current['backup-bucket', 'assets/fixture.pdf']
        new_source = self.s3.add('assets-bucket', 'fixture.pdf', b'new-version')
        result = self.job.run()
        self.assertEqual(1, result['copied'])
        self.assertEqual(b'old-version', self.s3.versions['backup-bucket', 'assets/fixture.pdf', old_backup]['Body'])
        self.assertNotEqual(old_source, new_source)
        self.assertEqual(new_source, self.s3.copy_calls[-1]['CopySource']['VersionId'])

    def test_checksumless_and_composite_sources_use_bounded_full_version_hash(self):
        self.s3.add('assets-bucket', 'legacy.pdf', ChecksumSHA256=None)
        self.s3.add('assets-bucket', 'multipart.pdf', ChecksumType='COMPOSITE', ChecksumSHA256='not-a-full-sha')
        self.job.run()
        self.assertEqual(2, len(self.s3.get_calls))
        self.assertTrue(all(c.get('VersionId') for c in self.s3.get_calls))

    def test_copy_corruption_is_not_reported_complete(self):
        self.s3.add('assets-bucket', 'fixture.pdf')
        self.s3.corrupt_copy = True
        self.error('BACKUP_HASH_MISMATCH')
        self.assertEqual([], self.s3.put_calls)

    def test_matching_metadata_with_wrong_destination_bytes_fails_closed(self):
        self.s3.add('assets-bucket', 'fixture.pdf')
        self.job.run()
        version = self.s3.current['backup-bucket', 'assets/fixture.pdf']
        row = self.s3.versions['backup-bucket', 'assets/fixture.pdf', version]
        row['Body'] = b'x' * row['ContentLength']
        row['ChecksumSHA256'] = checksum(row['Body'])
        self.error('BACKUP_HASH_MISMATCH')
        self.assertEqual(1, len(self.s3.copy_calls))
        self.assertEqual(1, len(self.s3.put_calls))

    def test_manifest_corruption_fails_closed(self):
        self.s3.add('assets-bucket', 'fixture.pdf')
        self.s3.corrupt_manifest = True
        self.error('BACKUP_HASH_MISMATCH')

    def test_versioning_is_required_before_database_backup_is_created(self):
        self.s3.enabled = False
        self.error('BACKUP_VERSIONING_REQUIRED')
        self.assertEqual([], self.ddb.created)

    def test_missing_object_version_is_not_accepted(self):
        self.s3.add('assets-bucket', 'fixture.pdf', version='null')
        self.error('BACKUP_VERSIONING_REQUIRED')
        self.assertEqual([], self.s3.put_calls)

    def test_paginated_listing_copies_every_current_object(self):
        for i in range(103):
            self.s3.add('assets-bucket', f'fixture-{i:03d}.pdf')
        result = self.job.run()
        self.assertEqual(103, result['objects'])
        self.assertEqual(2, len(self.s3.list_calls))
        self.assertEqual('100', self.s3.list_calls[1]['ContinuationToken'])

    def test_pilot_limit_fails_partial_run_without_manifest_or_deletes(self):
        for i in range(4):
            self.s3.add('assets-bucket', f'fixture-{i}.pdf')
        with patch('backup.MAX_OBJECTS', 3):
            self.error('BACKUP_PILOT_LIMIT')
        self.assertEqual(3, len(self.s3.copy_calls))
        self.assertEqual([], self.s3.put_calls)
        self.assertEqual(4, len([k for k in self.s3.current if k[0] == 'assets-bucket']))

    def test_repeated_listing_cursor_is_rejected(self):
        self.s3.list_objects_v2 = lambda **_: dict(Contents=[], IsTruncated=True, NextContinuationToken='same')
        self.error('BACKUP_LIST_INCOMPLETE')
        self.assertEqual([], self.s3.put_calls)

    def test_database_pending_and_deleted_states_never_produce_complete_manifest(self):
        self.ddb.states = ['CREATING']
        with patch('backup.time.sleep') as sleep:
            self.error('BACKUP_DATABASE_PENDING')
        self.assertEqual(5, sleep.call_count)
        self.assertEqual([], self.s3.put_calls)
        self.ddb.states = ['DELETED']
        self.error('BACKUP_DATABASE_UNAVAILABLE')
        self.assertEqual([], self.s3.put_calls)

    def test_database_becoming_available_allows_completion(self):
        self.ddb.states = ['CREATING', 'AVAILABLE']
        with patch('backup.time.sleep') as sleep:
            result = self.job.run()
        self.assertEqual(1, sleep.call_count)
        self.assertEqual(0, result['objects'])
        self.assertTrue(result['backup_available'])

    def test_sdk_failure_returns_sanitized_error_and_no_success_manifest(self):
        self.s3.add('assets-bucket', 'private-fixture.pdf')
        def unavailable(**args):
            raise RuntimeError('private-fixture.pdf with secret details')
        self.s3.copy_object = unavailable
        self.error('BACKUP_UNAVAILABLE')
        self.assertEqual([], self.s3.put_calls)


if __name__ == '__main__':
    unittest.main()
