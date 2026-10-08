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
from backup import Backup, STATE_KEY
from domain import APIError


def checksum(data):
    return base64.b64encode(hashlib.sha256(data).digest()).decode()


class MissingObject(Exception):
    response = {'Error': {'Code': 'NoSuchKey'}}


class PreconditionFailed(Exception):
    response = {'Error': {'Code': 'PreconditionFailed'}}


class FakeMetrics:
    def __init__(self):
        self.calls, self.fail = [], False

    def put_metric_data(self, **args):
        self.calls.append(args)
        if self.fail:
            raise TimeoutError('private-metric-receipt-unknown')
        return {}


class FakeDDB:
    def __init__(self):
        self.created = []
        self.states = ['AVAILABLE']
        self.backups, self.list_calls = [], []
        self.fail_after_create = False

    def create_backup(self, **args):
        self.created.append(args)
        arn = 'arn:aws:dynamodb:us-east-1:123456789012:table/' + args['TableName'] + '/backup/' + str(len(self.created))
        self.backups.append(dict(TableName=args['TableName'], BackupName=args['BackupName'], BackupArn=arn))
        if self.fail_after_create:
            self.fail_after_create = False
            raise TimeoutError('private-provider-receipt-unknown')
        return {'BackupDetails': {'BackupArn': arn}}

    def describe_backup(self, **args):
        status = self.states.pop(0) if len(self.states) > 1 else self.states[0]
        row = next(v for v in self.backups if v['BackupArn'] == args['BackupArn'])
        return {'BackupDescription': {'BackupDetails': dict(row, BackupStatus=status), 'SourceTableDetails': {'TableName': row['TableName']}}}

    def list_backups(self, **args):
        self.list_calls.append(args)
        return {'BackupSummaries': [dict(v) for v in self.backups if v['TableName'] == args['TableName']]}


class FakeS3:
    def __init__(self):
        self.current, self.versions = {}, {}
        self.copy_calls, self.put_calls, self.list_calls, self.get_calls = [], [], [], []
        self.enabled = True
        self.corrupt_copy, self.corrupt_manifest = False, False
        self.checkpoint_count, self.fail_checkpoints_from = 0, None
        self.fail_after_checkpoint, self.before_put = False, None

    @property
    def manifests(self):
        return [v for v in self.put_calls if v['Key'].startswith('manifests/')]

    def add(self, bucket, key, data=b'opaque-fixture-bytes', version=None, **headers):
        version = version or 'version-' + str(len(self.versions) + 1)
        row = dict(Body=data, ContentLength=len(data), Metadata={'fixture': 'safe'}, ContentType='application/pdf',
                   ChecksumSHA256=checksum(data), ChecksumType='FULL_OBJECT', VersionId=version,
                   ETag='"' + hashlib.md5(data).hexdigest() + '"')
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
        keys = sorted(k for bucket, k in self.current if bucket == args['Bucket'] and k > args.get('StartAfter', ''))
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
        if self.before_put:
            self.before_put(args)
        current = self.current.get((args['Bucket'], args['Key']))
        if args.get('IfNoneMatch') == '*' and current is not None:
            raise PreconditionFailed()
        if args.get('IfMatch') and (current is None or self.versions[args['Bucket'], args['Key'], current]['ETag'] != args['IfMatch']):
            raise PreconditionFailed()
        failed = False
        if args['Key'] == STATE_KEY:
            self.checkpoint_count += 1
            failed = self.fail_checkpoints_from is not None and self.checkpoint_count >= self.fail_checkpoints_from
            if failed and not self.fail_after_checkpoint:
                raise TimeoutError('private-checkpoint-provider-details')
        data = args['Body'] + b'corrupt' if self.corrupt_manifest and args['Key'].startswith('manifests/') else args['Body']
        version = self.add(args['Bucket'], args['Key'], data, ContentType=args['ContentType'], Metadata={})
        if failed:
            raise TimeoutError('private-checkpoint-receipt-unknown')
        return {'VersionId': version, 'ETag': self.versions[args['Bucket'], args['Key'], version]['ETag']}


class BackupTests(unittest.TestCase):
    def setUp(self):
        self.ddb, self.s3, self.metrics = FakeDDB(), FakeS3(), FakeMetrics()
        self.now = 1791460800
        self.job = self.worker()

    def worker(self, remaining=None):
        return Backup(self.ddb, self.s3, 'fixture-table', 'assets-bucket', 'backup-bucket', lambda: self.now, remaining, self.metrics)

    def state(self):
        version = self.s3.current['backup-bucket', STATE_KEY]
        return json.loads(self.s3.versions['backup-bucket', STATE_KEY, version]['Body'])

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
        manifest = json.loads(self.s3.manifests[0]['Body'])
        self.assertEqual('complete', manifest['status'])
        self.assertEqual(2, len(manifest['objects']))
        self.assertEqual('AVAILABLE', manifest['database']['status'])
        for entry in manifest['objects']:
            row = self.s3.versions['backup-bucket', entry['backup_key'], entry['backup_version_id']]
            self.assertEqual(entry['sha256'], hashlib.sha256(row['Body']).hexdigest())
        put = self.s3.manifests[0]
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
        self.assertEqual([], self.s3.manifests)

    def test_matching_metadata_with_wrong_destination_bytes_fails_closed(self):
        self.s3.add('assets-bucket', 'fixture.pdf')
        self.job.run()
        version = self.s3.current['backup-bucket', 'assets/fixture.pdf']
        row = self.s3.versions['backup-bucket', 'assets/fixture.pdf', version]
        row['Body'] = b'x' * row['ContentLength']
        row['ChecksumSHA256'] = checksum(row['Body'])
        self.error('BACKUP_HASH_MISMATCH')
        self.assertEqual(1, len(self.s3.copy_calls))
        self.assertEqual(1, len(self.s3.manifests))

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
        self.assertEqual([], self.s3.manifests)

    def test_paginated_listing_copies_every_current_object(self):
        for i in range(103):
            self.s3.add('assets-bucket', f'fixture-{i:03d}.pdf')
        self.assertEqual('in_progress', self.job.run()['status'])
        result = self.worker().run()
        self.assertEqual(103, result['objects'])
        self.assertEqual(2, len(self.s3.list_calls))
        self.assertEqual('fixture-099.pdf', self.s3.list_calls[1]['StartAfter'])
        self.assertEqual(1, len(self.ddb.created))

    def test_more_than_1000_objects_complete_across_invocations_with_one_database_backup(self):
        for i in range(1001):
            self.s3.add('assets-bucket', f'fixture-{i:04d}.pdf')
        results = [self.worker().run() for _ in range(11)]
        self.assertTrue(all(v['status'] == 'in_progress' and not v['manifest_written'] for v in results[:-1]))
        self.assertEqual('complete', results[-1]['status'])
        self.assertEqual(1001, results[-1]['objects']); self.assertEqual(1, len(self.ddb.created))
        self.assertEqual(1001, len(self.s3.copy_calls)); self.assertEqual(1, len(self.s3.manifests))
        self.assertEqual(1001, len(json.loads(self.s3.manifests[0]['Body'])['objects']))
        self.assertEqual(1001, len([k for k in self.s3.current if k[0] == 'assets-bucket']))

    def test_repeated_listing_cursor_is_rejected(self):
        self.s3.list_objects_v2 = lambda **_: dict(Contents=[], IsTruncated=True, NextContinuationToken='same')
        self.error('BACKUP_LIST_INCOMPLETE')
        self.assertEqual([], self.s3.manifests)

    def test_database_pending_is_durable_and_deleted_state_never_completes(self):
        self.ddb.states = ['CREATING']
        result = self.job.run()
        self.assertEqual('in_progress', result['status']); self.assertFalse(result['backup_available'])
        self.assertEqual([], self.s3.manifests); self.assertEqual(1, len(self.ddb.created))
        self.ddb.states = ['DELETED']
        self.error('BACKUP_DATABASE_UNAVAILABLE')
        self.assertEqual([], self.s3.manifests); self.assertEqual(1, len(self.ddb.created))

    def test_database_becoming_available_allows_completion(self):
        self.ddb.states = ['CREATING', 'AVAILABLE']
        self.assertEqual('in_progress', self.job.run()['status'])
        result = self.worker().run()
        self.assertEqual(0, result['objects'])
        self.assertTrue(result['backup_available'])
        self.assertEqual(1, len(self.ddb.created))

    def test_sdk_failure_returns_sanitized_error_and_no_success_manifest(self):
        self.s3.add('assets-bucket', 'private-fixture.pdf')
        def unavailable(**args):
            raise RuntimeError('private-fixture.pdf with secret details')
        self.s3.copy_object = unavailable
        self.error('BACKUP_UNAVAILABLE')
        self.assertEqual([], self.s3.manifests)

    def test_active_lease_blocks_competitor_and_expired_owner_cannot_checkpoint(self):
        self.assertIsNone(self.job.acquire(False))
        original = self.state()
        competitor = self.worker(); result = competitor.run()
        self.assertEqual('busy', result['status']); self.assertEqual([], self.ddb.created)
        self.assertEqual(original, self.state())
        self.now += 1000; self.assertIsNone(competitor.acquire(False))
        current = self.state()
        with self.assertRaises(APIError) as caught:
            self.job.save_state(release=True)
        self.assertEqual('BACKUP_LEASE_LOST', caught.exception.code)
        self.assertEqual(current, self.state())

    def test_competing_first_checkpoint_cannot_be_overwritten_or_create_database_backup(self):
        def rival(args):
            if args['Key'] == STATE_KEY:
                self.s3.before_put = None
                row = json.loads(args['Body']); row['lease_owner'] = 'f' * 32
                self.s3.add(args['Bucket'], args['Key'], Backup.body(row), Metadata={}, ContentType='application/json')
        self.s3.before_put = rival
        self.error('BACKUP_CHECKPOINT_CONFLICT')
        self.assertEqual('f' * 32, self.state()['lease_owner']); self.assertEqual([], self.ddb.created)

    def test_unknown_database_creation_is_recovered_by_exact_name_without_second_request(self):
        self.ddb.fail_after_create = True
        self.error('BACKUP_UNAVAILABLE')
        saved = self.state(); self.assertTrue(saved['database_requested']); self.assertIsNone(saved['backup_arn'])
        result = self.worker().run()
        self.assertEqual('complete', result['status']); self.assertEqual(1, len(self.ddb.created))
        self.assertEqual('fixture-table', self.ddb.list_calls[0]['TableName'])
        self.assertEqual(saved['backup_name'], json.loads(self.s3.manifests[0]['Body'])['database']['backup_name'])

    def test_absent_database_receipt_is_not_proof_a_second_create_is_safe(self):
        calls = []
        def unknown(**args):
            calls.append(args); raise TimeoutError('provider-outcome-unknown')
        self.ddb.create_backup = unknown
        self.error('BACKUP_UNAVAILABLE')
        for _ in range(2):
            self.error('BACKUP_DATABASE_REQUEST_UNCERTAIN')
        self.assertEqual(1, len(calls)); self.assertEqual([], self.s3.manifests)

    def test_database_receipt_checkpoint_failure_recovers_same_backup_after_expiry(self):
        self.s3.fail_checkpoints_from = 3
        self.error('BACKUP_UNAVAILABLE')
        self.assertEqual(1, len(self.ddb.created)); self.assertIsNone(self.state()['backup_arn'])
        self.now += 1000; self.s3.fail_checkpoints_from = None
        result = self.worker().run()
        self.assertEqual('complete', result['status']); self.assertEqual(1, len(self.ddb.created))

    def test_unknown_page_checkpoint_keeps_pinned_progress_and_does_not_recopy(self):
        for i in range(103):
            self.s3.add('assets-bucket', f'fixture-{i:03d}.pdf')
        self.s3.fail_checkpoints_from = 4; self.s3.fail_after_checkpoint = True
        self.error('BACKUP_UNAVAILABLE')
        saved = self.state(); self.assertEqual(100, len(saved['objects']))
        self.now += 1000; self.s3.fail_checkpoints_from = None
        result = self.worker().run()
        self.assertEqual('complete', result['status']); self.assertEqual(103, len(self.s3.copy_calls))
        manifest = json.loads(self.s3.manifests[0]['Body'])
        self.assertEqual(saved['objects'], manifest['objects'][:100]); self.assertEqual(1, len(self.ddb.created))

    def test_lost_page_checkpoint_reuses_verified_copies_without_losing_entries(self):
        for i in range(103):
            self.s3.add('assets-bucket', f'fixture-{i:03d}.pdf')
        self.s3.fail_checkpoints_from = 4
        self.error('BACKUP_UNAVAILABLE'); self.assertEqual([], self.state()['objects'])
        self.now += 1000; self.s3.fail_checkpoints_from = None
        self.assertEqual('in_progress', self.worker().run()['status'])
        result = self.worker().run()
        self.assertEqual(103, result['objects']); self.assertEqual(103, len(self.s3.copy_calls))
        self.assertEqual(1, len(self.ddb.created)); self.assertEqual(1, len(self.s3.manifests))

    def test_manifest_written_before_failed_completion_checkpoint_is_reused_exactly(self):
        self.s3.add('assets-bucket', 'fixture.pdf'); self.s3.fail_checkpoints_from = 5
        self.error('BACKUP_UNAVAILABLE'); self.assertEqual(1, len(self.s3.manifests))
        saved = self.s3.manifests[0]['Body']
        self.now += 1000; self.s3.fail_checkpoints_from = None
        result = self.worker().run()
        self.assertEqual('complete', result['status']); self.assertEqual(1, len(self.s3.manifests))
        self.assertEqual(saved, self.s3.manifests[0]['Body']); self.assertEqual(1, len(self.ddb.created))

    def test_low_remaining_time_checkpoints_only_verified_progress_then_resumes(self):
        for i in range(3):
            self.s3.add('assets-bucket', f'fixture-{i}.pdf')
        remaining = iter((900000, 1000))
        partial = self.worker(lambda: next(remaining, 1000)).run()
        self.assertEqual('in_progress', partial['status']); self.assertEqual(1, partial['objects'])
        self.assertFalse(self.state()['scan_complete']); self.assertIsNone(self.state()['lease_owner'])
        result = self.worker().run(); self.assertEqual('complete', result['status']); self.assertEqual(3, result['objects'])
        self.assertEqual(1, len(self.ddb.created)); self.assertEqual(3, len(self.s3.copy_calls))

    def test_scheduled_checks_start_only_once_per_day_after_four_utc(self):
        from datetime import datetime, timezone
        self.now = int(datetime(2026, 10, 8, 3, 59, tzinfo=timezone.utc).timestamp())
        self.assertEqual('idle', self.worker().run(scheduled=True)['status']); self.assertEqual([], self.ddb.created)
        self.now += 60
        self.assertEqual('complete', self.worker().run(scheduled=True)['status'])
        self.assertEqual('idle', self.worker().run(scheduled=True)['status']); self.assertEqual(1, len(self.ddb.created))
        self.now += 86400
        self.assertEqual('complete', self.worker().run(scheduled=True)['status']); self.assertEqual(2, len(self.ddb.created))

    def test_foreign_or_corrupt_checkpoint_cannot_write_or_start_another_database_backup(self):
        self.worker(lambda: 1000).run(); saved = self.state()
        saved['source_bucket'] = 'foreign-bucket'
        self.s3.add('backup-bucket', STATE_KEY, Backup.body(saved), Metadata={}, ContentType='application/json')
        before = len(self.s3.put_calls)
        self.error('BACKUP_CHECKPOINT_INVALID')
        self.assertEqual(before, len(self.s3.put_calls)); self.assertEqual(1, len(self.ddb.created))

    def test_explicit_manifest_byte_limit_does_not_publish_partial_result(self):
        self.s3.add('assets-bucket', 'fixture.pdf', Metadata={'bounded-fixture': 'x' * 2000})
        with patch('backup.MAX_JOB_BYTES', 1500):
            self.error('BACKUP_CHECKPOINT_LIMIT')
        self.assertEqual([], self.s3.manifests); self.assertEqual(1, len(self.ddb.created))

    def test_explicit_provider_rejection_can_retry_after_recovery_without_an_unknown_duplicate(self):
        original = self.ddb.create_backup
        for code in ('AccessDeniedException', 'LimitExceededException', 'TableInUseException'):
            class Rejected(Exception):
                response = {'Error': {'Code': code}, 'ResponseMetadata': {'HTTPStatusCode': 400}}
            with patch.object(self.ddb, 'create_backup', side_effect=Rejected()):
                self.error('BACKUP_DATABASE_REJECTED')
            self.assertFalse(self.state()['database_requested']); self.assertIsNone(self.state()['backup_arn'])
        self.ddb.create_backup = original
        self.assertEqual('complete', self.worker().run()['status']); self.assertEqual(1, len(self.ddb.created))

    def test_internal_provider_error_never_clears_unknown_creation_intent(self):
        class Internal(Exception):
            response = {'Error': {'Code': 'InternalServerError'}, 'ResponseMetadata': {'HTTPStatusCode': 500}}
        with patch.object(self.ddb, 'create_backup', side_effect=Internal()):
            self.error('BACKUP_UNAVAILABLE')
        self.assertTrue(self.state()['database_requested'])
        self.error('BACKUP_DATABASE_REQUEST_UNCERTAIN'); self.assertEqual([], self.ddb.created)

    def test_heartbeat_is_only_published_after_verified_complete_manifest(self):
        self.ddb.states = ['CREATING', 'AVAILABLE']
        self.assertEqual('in_progress', self.job.run()['status']); self.assertEqual([], self.metrics.calls)
        self.assertEqual('complete', self.worker().run()['status'])
        self.assertEqual(1, len(self.metrics.calls)); call = self.metrics.calls[0]
        self.assertEqual('WorshipCue/Backup', call['Namespace'])
        self.assertEqual([{'Name':'FunctionName','Value':'worshipcue-dev-backup'}], call['MetricData'][0]['Dimensions'])
        self.assertEqual(1, call['MetricData'][0]['Value']); self.assertEqual('Completed', call['MetricData'][0]['MetricName'])
        self.assertEqual(1, len(self.s3.manifests))

    def test_unknown_metric_publication_reuses_manifest_and_database_backup_on_retry(self):
        self.metrics.fail = True; self.error('BACKUP_UNAVAILABLE')
        self.assertEqual(1, len(self.s3.manifests)); self.assertEqual('active', self.state()['status'])
        self.metrics.fail = False; self.assertEqual('complete', self.worker().run()['status'])
        self.assertEqual(1, len(self.ddb.created)); self.assertEqual(1, len(self.s3.manifests))
        self.assertEqual(2, len(self.metrics.calls))

    def test_lambda_disables_provider_retries_for_create_and_logs_only_safe_failure_code(self):
        import contextlib
        import os
        from types import SimpleNamespace
        from backup import lambda_handler
        configurations = []
        def client(service, **kwargs):
            if service == 'dynamodb': configurations.append(kwargs['config'])
            return {'dynamodb': self.ddb, 's3': self.s3, 'cloudwatch': self.metrics}[service]
        self.s3.enabled = False; log = io.StringIO()
        modules = {'boto3': SimpleNamespace(client=client), 'botocore.config': SimpleNamespace(Config=lambda **v: v)}
        with patch.dict(sys.modules, modules), patch.dict(os.environ, {'TABLE_NAME':'fixture-table','ASSET_BUCKET':'assets-bucket',
                'BACKUP_BUCKET':'backup-bucket','AWS_LAMBDA_FUNCTION_NAME':'worshipcue-dev-backup'}), contextlib.redirect_stdout(log):
            with self.assertRaisesRegex(RuntimeError, '^BACKUP_VERSIONING_REQUIRED$'):
                lambda_handler({}, None)
        self.assertEqual({'total_max_attempts':1,'mode':'standard'}, configurations[0]['retries'])
        self.assertEqual({'event':'backup_failed','code':'BACKUP_VERSIONING_REQUIRED'}, json.loads(log.getvalue()))


if __name__ == '__main__':
    unittest.main()
