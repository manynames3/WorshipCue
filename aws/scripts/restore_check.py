#!/usr/bin/env python3
"""Qualify a private backup by restoring only an isolated development scratch table.

Uses the installed AWS CLI and Python standard library. Private manifests, scans,
and receipts stay outside the repository. Output contains only counts and status.
The scratch table is retained by default; --cleanup needs its creation receipt.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
import uuid
from datetime import datetime, timezone

REPO = Path(__file__).resolve().parents[2]
EPHEMERAL = ('LIMIT#', 'TICKET#', 'WS#', 'WSID#', 'REVOKED#')
MAX_OBJECT_BYTES = 104857600
MAX_MANIFEST_BYTES = 8388608
MAX_ROWS = 50000


class Failure(Exception):
    def __init__(self, code):
        self.code = code if re.fullmatch(r'[A-Z][A-Z0-9_]{0,79}', code or '') else 'UNSAFE_ERROR_REDACTED'
        super().__init__(self.code)


def require(value, code):
    if not value:
        raise Failure(code)


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False, allow_nan=False).encode()


def load_json(data):
    try:
        return json.loads(data, parse_constant=lambda _: (_ for _ in ()).throw(ValueError()))
    except (ValueError, TypeError, UnicodeError):
        raise Failure('INVALID_PRIVATE_JSON') from None


def private_path(path):
    path = path.resolve()
    require(not path.is_relative_to(REPO), 'PRIVATE_INPUT_MUST_BE_EXTERNAL')
    require(path.is_file() and path.stat().st_mode & 0o077 == 0, 'PRIVATE_INPUT_PERMISSIONS_REQUIRED')
    return path


def save(path, value):
    temporary = path.with_name(path.name + '.' + uuid.uuid4().hex + '.tmp')
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'wb') as file:
        file.write(canonical(value))
        file.write(b'\n')
        file.flush()
        os.fsync(file.fileno())
    os.replace(temporary, path)
    os.chmod(path, 0o600)


def checksum(value):
    try:
        raw = base64.b64decode(value, validate=True)
        require(len(raw) == 32, 'INVALID_S3_CHECKSUM')
        return raw.hex()
    except (ValueError, TypeError):
        raise Failure('INVALID_S3_CHECKSUM') from None


def version(value):
    require(isinstance(value, str) and value and value != 'null', 'VERSION_PIN_REQUIRED')
    return value


def rows(items):
    """Check the actual stored CAS digest, not a digest supplied by the test caller."""
    require(isinstance(items, list) and len(items) <= MAX_ROWS, 'SCAN_LIMIT_OR_SHAPE')
    result = {}
    for item in items:
        try:
            pk, sk, payload, etag = (item[name]['S'] for name in ('PK', 'SK', 'data', 'etag'))
            require(all(isinstance(v, str) for v in (pk, sk, payload, etag)), 'INVALID_ROW')
            require((pk, sk) not in result, 'DUPLICATE_ROW')
            value = load_json(payload)
            require(isinstance(value, dict), 'INVALID_ROW')
            require(hashlib.sha256(canonical(value)).hexdigest() == etag, 'ROW_DIGEST_MISMATCH')
            if 'expires_at_epoch' in item:
                expiry = value.get('expires_at_epoch')
                require(isinstance(expiry, int) and not isinstance(expiry, bool)
                        and item['expires_at_epoch'] == {'N': str(expiry)}, 'ROW_EXPIRY_MISMATCH')
            result[pk, sk] = {'value': value, 'etag': etag, 'item': item}
        except (KeyError, TypeError, ValueError):
            raise Failure('INVALID_ROW') from None
    return result


def stable(value):
    return {key: row['item'] for key, row in value.items()
            if not key[0].startswith(EPHEMERAL)
            and not (key[0].startswith('U#') and key[1].startswith('RATE#REDEEM#')
                     and 'expires_at_epoch' in row['value'])}


def match_stable(expected, actual):
    require(stable(expected) == stable(actual), 'STABLE_SOURCE_OR_RESTORE_MISMATCH')
    return len(stable(expected))


def manifest_entries(manifest, table, assets, backups):
    require(isinstance(manifest, dict) and manifest.get('schema_version') == 1
            and manifest.get('status') == 'complete', 'COMPLETE_MANIFEST_REQUIRED')
    require(manifest.get('source_bucket') == assets and manifest.get('backup_bucket') == backups,
            'MANIFEST_BUCKET_MISMATCH')
    database = manifest.get('database', {})
    require(database.get('table') == table and database.get('status') == 'AVAILABLE'
            and isinstance(database.get('backup_arn'), str), 'MANIFEST_DATABASE_MISMATCH')
    objects = manifest.get('objects')
    require(isinstance(objects, list) and len(objects) <= 1000, 'MANIFEST_OBJECT_LIMIT')
    result = {}
    for entry in objects:
        require(isinstance(entry, dict), 'INVALID_MANIFEST_ENTRY')
        key = entry.get('source_key')
        require(isinstance(key, str) and key and key not in result
                and entry.get('backup_key') == 'assets/' + key, 'INVALID_MANIFEST_KEY')
        version(entry.get('source_version_id'))
        version(entry.get('backup_version_id'))
        count = entry.get('bytes')
        require(isinstance(count, int) and not isinstance(count, bool) and 0 < count <= MAX_OBJECT_BYTES,
                'INVALID_MANIFEST_SIZE')
        require(isinstance(entry.get('sha256'), str) and re.fullmatch('[0-9a-f]{64}', entry['sha256']),
                'INVALID_MANIFEST_DIGEST')
        result[key] = entry
    return result


def material(row, sk):
    """Compare only immutable material when a live row has later archive state."""
    if sk.startswith('assets#') and row.get('status') == 'verified':
        fields = ('id', 'asset_id', 'team_id', 'church_id', 'owner_user_id', 'type',
                  'sha256', 'bytes', 'storage_key', 'page_count', 'page_manifest')
    elif sk.startswith('chart_versions#'):
        fields = ('id', 'chart_version_id', 'team_id', 'church_id', 'song_id', 'version_number',
                  'label', 'written_key', 'pdf_asset_id', 'pdf_sha256', 'pdf_bytes', 'page_count',
                  'page_manifest', 'pages', 'published_at')
    elif sk.startswith('annotation_revisions#'):
        return row
    else:
        return None
    return {field: row.get(field) for field in fields}


def qualify(restored, entries, before, after, expected=None):
    assets, verified, references = {}, 0, 0
    for (_, sk), record in restored.items():
        value = record['value']
        if sk.startswith('assets#'):
            require(value.get('id') not in assets, 'DUPLICATE_ASSET_ID')
            assets[value.get('id')] = value
            if value.get('status') == 'verified':
                entry = entries.get(value.get('storage_key'))
                require(entry and entry['sha256'] == value.get('sha256') and entry['bytes'] == value.get('bytes'),
                        'VERIFIED_ASSET_NOT_RECOVERABLE')
                verified += 1
    for (_, sk), record in restored.items():
        value = record['value']
        prefixes = ('pdf',) if sk.startswith('chart_versions#') else ('native', 'preview') if sk.startswith('annotation_revisions#') else ()
        for prefix in prefixes:
            asset = assets.get(value.get(prefix + '_asset_id'))
            kind = 'pdf' if prefix == 'pdf' else 'native' if prefix == 'native' else 'preview'
            require(asset and asset.get('status') == 'verified' and asset.get('type') == kind
                    and asset.get('team_id') == value.get('team_id')
                    and asset.get('sha256') == value.get(prefix + '_sha256')
                    and asset.get('bytes') == value.get(prefix + '_bytes'), 'PUBLISHED_REFERENCE_MISMATCH')
            if prefix != 'pdf':
                require(asset.get('storage_key') == value.get(prefix + '_storage_key'), 'PUBLISHED_REFERENCE_MISMATCH')
            references += 1
    immutable, unchanged, changed = 0, 0, 0
    for key, record in restored.items():
        prior, current = before.get(key), after.get(key)
        if prior and current and prior['item'] == current['item']:
            if record['item'] == prior['item']:
                unchanged += 1
            else:
                changed += 1  # A live change after backup is not a restore failure.
        else:
            changed += 1
        frozen = material(record['value'], key[1])
        if frozen is not None and prior and current:
            require(frozen == material(prior['value'], key[1]) == material(current['value'], key[1]),
                    'IMMUTABLE_MATERIAL_MISMATCH')
            immutable += 1
    matched = match_stable(expected, restored) if expected is not None else None
    return dict(restored_rows=len(restored), stable_rows=len(stable(restored)), verified_assets=verified,
                published_file_references=references, immutable_live_rows_checked=immutable,
                unchanged_live_rows_matching=unchanged, changed_or_unmatched_live_rows=changed,
                expected_stable_rows_matching=matched, source_snapshot_transactional=False)


class RestoreCheck:
    def __init__(self, config_path, directory=None, source_snapshot=None):
        config_path = private_path(config_path)
        self.config = load_json(config_path.read_bytes())
        require(self.config.get('stack') == 'worshipcue-dev' and self.config.get('region') == 'us-east-1',
                'AUTHORIZED_DEVELOPMENT_STACK_REQUIRED')
        self.outputs = self.config.get('outputs', {})
        if isinstance(self.outputs, list):
            self.outputs = {r['OutputKey']: r['OutputValue'] for r in self.outputs}
        require(all(isinstance(self.outputs.get(k), str) and self.outputs[k]
                    for k in ('TableName', 'AssetBucket', 'BackupBucket')), 'MISSING_STACK_OUTPUTS')
        self.directory = (directory or config_path.parent / 'restore-check').resolve()
        require(not self.directory.is_relative_to(REPO), 'STATE_MUST_BE_EXTERNAL')
        self.directory.mkdir(parents=True, exist_ok=True)
        os.chmod(self.directory, 0o700)
        self.path = self.directory / 'receipt.json'
        self.aws = self.config.get('aws_cli') or shutil.which('aws') or '/opt/homebrew/bin/aws'
        require(Path(self.aws).is_file(), 'AWS_CLI_UNAVAILABLE')
        self.table, self.assets, self.backups = (self.outputs[k] for k in ('TableName', 'AssetBucket', 'BackupBucket'))
        self.fingerprint = hashlib.sha256(canonical({k: self.outputs[k] for k in ('TableName', 'AssetBucket', 'BackupBucket')})).hexdigest()
        self.state = load_json(private_path(self.path).read_bytes()) if self.path.exists() else None
        if self.state:
            require(self.state.get('fingerprint') == self.fingerprint and self.state.get('owner') == 'WorshipCueRestoreCheck',
                    'RECEIPT_STACK_MISMATCH')
        self.expected = None
        expected_path = self.directory / 'expected-source.json'
        if source_snapshot:
            source_snapshot = private_path(source_snapshot)
            snapshot = load_json(source_snapshot.read_bytes())
            self.expected = rows(snapshot.get('Items'))
            digest = hashlib.sha256(canonical(snapshot)).hexdigest()
            require(not self.state or self.state.get('source_snapshot_sha256') == digest, 'SOURCE_SNAPSHOT_CHANGED')
            save(expected_path, snapshot)
        elif self.state and self.state.get('source_snapshot_sha256'):
            snapshot = load_json(private_path(expected_path).read_bytes())
            require(hashlib.sha256(canonical(snapshot)).hexdigest() == self.state['source_snapshot_sha256'], 'SOURCE_SNAPSHOT_CHANGED')
            self.expected = rows(snapshot.get('Items'))

    def cli(self, service, operation, arguments=None, outfile=None, optional=False):
        path = self.directory / ('input-' + uuid.uuid4().hex + '.json')
        save(path, arguments or {})
        command = [self.aws, service, operation, '--region', 'us-east-1',
                   '--output', 'json', '--no-cli-pager', '--no-paginate']
        if self.config.get('profile'):
            command += ['--profile', self.config['profile']]
        if outfile:
            # GetObject is a customized CLI command and does not support JSON input.
            require(service == 's3api' and operation == 'get-object', 'UNSUPPORTED_CLI_OUTFILE')
            require(set(arguments) == {'Bucket', 'Key', 'VersionId', 'ChecksumMode'}, 'INVALID_DOWNLOAD_ARGUMENTS')
            command += ['--bucket', arguments['Bucket'], '--key', arguments['Key'],
                        '--version-id', arguments['VersionId'], '--checksum-mode', arguments['ChecksumMode']]
            command.append(str(outfile))
        else:
            command += ['--cli-input-json', 'file://' + str(path)]
        try:
            result = subprocess.run(command, capture_output=True, timeout=60,
                                    env={**os.environ, 'AWS_PAGER': '', 'AWS_CLI_AUTO_PROMPT': 'off'})
        except (OSError, subprocess.TimeoutExpired):
            raise Failure('AWS_CLI_UNAVAILABLE_OR_TIMEOUT') from None
        finally:
            path.unlink(missing_ok=True)
        if result.returncode:
            match = re.search(rb'An error occurred \(([A-Za-z0-9]+)\)', result.stderr)
            code = match[1].decode().upper() if match else 'AWS_CLI_FAILED'
            if optional and code == 'RESOURCENOTFOUNDEXCEPTION':
                return None
            save(self.directory / 'provider-error.json', {'service': service, 'operation': operation,
                 'argument_names': sorted((arguments or {}).keys()), 'exit': result.returncode,
                 'code': code, 'stderr': result.stderr.decode(errors='replace')})
            raise Failure(code) from None
        try:
            return load_json(result.stdout) if result.stdout.strip() else {}
        except Failure:
            save(self.directory / 'provider-error.json', {'service': service, 'operation': operation,
                 'argument_names': sorted((arguments or {}).keys()), 'exit': result.returncode,
                 'code': 'AWS_CLI_INVALID_JSON', 'stdout': result.stdout[:4096].decode(errors='replace')})
            raise Failure('AWS_CLI_INVALID_JSON') from None

    def save(self):
        save(self.path, self.state)

    def scope(self):
        account = self.cli('sts', 'get-caller-identity')['Account']
        stacks = self.cli('cloudformation', 'describe-stacks', {'StackName': 'worshipcue-dev'})['Stacks']
        require(len(stacks) == 1, 'DEVELOPMENT_STACK_REQUIRED')
        outputs = {r['OutputKey']: r['OutputValue'] for r in stacks[0].get('Outputs', [])}
        require(all(outputs.get(k) == self.outputs[k] for k in ('TableName', 'AssetBucket', 'BackupBucket')),
                'LIVE_STACK_OUTPUT_MISMATCH')
        if self.state:
            require(self.state.get('account') == account, 'RECEIPT_ACCOUNT_MISMATCH')
        return account

    def download(self, key, pinned, maximum, expected_sha=None, read_body=False):
        head = self.cli('s3api', 'head-object', {'Bucket': self.backups, 'Key': key,
                          'VersionId': pinned, 'ChecksumMode': 'ENABLED'})
        require(version(head.get('VersionId')) == pinned, 'OBJECT_VERSION_MISMATCH')
        count = head.get('ContentLength')
        require(isinstance(count, int) and not isinstance(count, bool) and 0 < count <= maximum, 'OBJECT_SIZE_LIMIT')
        path = self.directory / ('object-' + uuid.uuid4().hex + '.bin')
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        os.close(fd)
        try:
            received = self.cli('s3api', 'get-object', {'Bucket': self.backups, 'Key': key,
                                'VersionId': pinned, 'ChecksumMode': 'ENABLED'}, outfile=path)
            os.chmod(path, 0o600)
            require(received.get('VersionId') == pinned and received.get('ContentLength') == count, 'OBJECT_VERSION_OR_SIZE_MISMATCH')
            digest, size = hashlib.sha256(), 0
            with path.open('rb') as body:
                while True:
                    part = body.read(1048576)
                    if not part:
                        break
                    size += len(part)
                    require(size <= count, 'OBJECT_HASH_MISMATCH')
                    digest.update(part)
            sha = digest.hexdigest()
            require(size == count and (expected_sha is None or sha == expected_sha), 'OBJECT_HASH_MISMATCH')
            for metadata in (head, received):
                if metadata.get('ChecksumType', 'FULL_OBJECT') == 'FULL_OBJECT' and metadata.get('ChecksumSHA256'):
                    require(checksum(metadata['ChecksumSHA256']) == sha, 'STORED_S3_CHECKSUM_MISMATCH')
            if expected_sha is None or read_body:
                require(head.get('ChecksumType', 'FULL_OBJECT') == 'FULL_OBJECT' and head.get('ChecksumSHA256'),
                        'MANIFEST_STORED_CHECKSUM_REQUIRED')
                return path.read_bytes(), sha, head
            return None, sha, head
        finally:
            path.unlink(missing_ok=True)

    def latest_manifest(self):
        candidates, cursor, seen = [], None, set()
        while True:
            args = {'Bucket': self.backups, 'Prefix': 'manifests/', 'MaxKeys': 1000}
            if cursor:
                args['ContinuationToken'] = cursor
            page = self.cli('s3api', 'list-objects-v2', args)
            candidates.extend(v for v in page.get('Contents', []) if v.get('Key', '').endswith('.json'))
            require(len(candidates) <= 10000, 'MANIFEST_LIST_LIMIT')
            if not page.get('IsTruncated'):
                break
            cursor = page.get('NextContinuationToken')
            require(cursor and cursor not in seen, 'MANIFEST_LIST_INCOMPLETE')
            seen.add(cursor)
        for candidate in sorted(candidates, key=lambda v: (v['LastModified'], v['Key']), reverse=True):
            key = candidate['Key']
            head = self.cli('s3api', 'head-object', {'Bucket': self.backups, 'Key': key, 'ChecksumMode': 'ENABLED'})
            pinned = version(head.get('VersionId'))
            data, sha, _ = self.download(key, pinned, MAX_MANIFEST_BYTES)
            manifest = load_json(data)
            if isinstance(manifest, dict) and manifest.get('status') == 'complete':
                manifest_entries(manifest, self.table, self.assets, self.backups)
                save(self.directory / 'manifest.json', manifest)
                return manifest, key, pinned, sha
        raise Failure('NO_COMPLETE_BACKUP_MANIFEST')

    def scan(self, table):
        items, cursor, seen = [], None, set()
        while True:
            args = {'TableName': table, 'ConsistentRead': True, 'Limit': 250}
            if cursor:
                args['ExclusiveStartKey'] = cursor
            page = self.cli('dynamodb', 'scan', args)
            items.extend(page.get('Items', []))
            require(len(items) <= MAX_ROWS, 'SCAN_LIMIT_OR_SHAPE')
            cursor = page.get('LastEvaluatedKey')
            if not cursor:
                return {'Items': items}
            digest = hashlib.sha256(canonical(cursor)).hexdigest()
            require(digest not in seen, 'SCAN_INCOMPLETE')
            seen.add(digest)

    def verify_objects(self, entries):
        for entry in entries.values():
            _, _, head = self.download(entry['backup_key'], entry['backup_version_id'], MAX_OBJECT_BYTES, entry['sha256'])
            require(head['ContentLength'] == entry['bytes'], 'BACKUP_ASSET_SIZE_MISMATCH')
            metadata = head.get('Metadata', {})
            require(metadata.get('source-version-id') == entry['source_version_id']
                    and metadata.get('source-sha256') == entry['sha256']
                    and metadata.get('source-bytes') == str(entry['bytes']), 'BACKUP_PROVENANCE_MISMATCH')

    def owned_table(self):
        state = self.state
        require(state and state.get('created') is True and state.get('owner') == 'WorshipCueRestoreCheck', 'CREATION_RECEIPT_REQUIRED')
        run = state.get('run')
        require(isinstance(run, str) and str(uuid.UUID(run)) == run, 'INVALID_RECEIPT_RUN')
        target = 'WorshipCue-dev-restorecheck-' + run
        require(state.get('target_table') == target and target != self.table, 'EXACT_SCRATCH_TABLE_REQUIRED')
        table = self.cli('dynamodb', 'describe-table', {'TableName': target}, optional=True)
        if table is None:
            return None
        table = table['Table']
        require(table.get('TableArn') == state.get('target_arn') and table.get('TableName') == target,
                'SCRATCH_OWNERSHIP_MISMATCH')
        source = table.get('RestoreSummary', {}).get('SourceBackupArn')
        require(source is None or source == state.get('backup_arn'), 'SCRATCH_RESTORE_SOURCE_MISMATCH')
        # AWS omits RestoreSummary after ACTIVE; the successful creation receipt and
        # immutable table identity continue to bind this run, including during cleanup.
        identity, creation = table.get('TableId'), table.get('CreationDateTime')
        require(isinstance(identity, str) and identity and isinstance(creation, str), 'SCRATCH_IDENTITY_REQUIRED')
        require(0 <= (datetime.fromisoformat(creation) - datetime.fromisoformat(state['requested_at'])).total_seconds() <= 300,
                'SCRATCH_CREATION_TIME_MISMATCH')
        require(not state.get('target_table_id') or state['target_table_id'] == identity,
                'SCRATCH_TABLE_ID_MISMATCH')
        require(not state.get('target_creation_time') or state['target_creation_time'] == creation,
                'SCRATCH_CREATION_TIME_MISMATCH')
        if not state.get('target_table_id') or not state.get('target_creation_time'):
            state.update(target_table_id=identity, target_creation_time=creation)
            self.save()
        return table

    def start(self, account):
        manifest, key, pinned, sha = self.latest_manifest()
        entries = manifest_entries(manifest, self.table, self.assets, self.backups)
        arn = manifest['database']['backup_arn']
        backup = self.cli('dynamodb', 'describe-backup', {'BackupArn': arn})['BackupDescription']
        require(backup['BackupDetails'].get('BackupArn') == arn and backup['BackupDetails'].get('BackupStatus') == 'AVAILABLE'
                and backup.get('SourceTableDetails', {}).get('TableName') == self.table, 'BACKUP_SOURCE_MISMATCH')
        require(arn.startswith('arn:aws:dynamodb:us-east-1:' + account + ':table/' + self.table + '/backup/'), 'BACKUP_ACCOUNT_MISMATCH')
        self.verify_objects(entries)
        before = self.scan(self.table)
        if self.expected is not None:
            match_stable(self.expected, rows(before['Items']))
        save(self.directory / 'source-before.json', before)
        run = str(uuid.uuid4())
        target = 'WorshipCue-dev-restorecheck-' + run
        require(self.cli('dynamodb', 'describe-table', {'TableName': target}, optional=True) is None, 'SCRATCH_NAME_ALREADY_EXISTS')
        self.state = dict(schema_version=1, owner='WorshipCueRestoreCheck', run=run, account=account,
                          fingerprint=self.fingerprint, target_table=target, backup_arn=arn, created=False,
                          phase='restore_requested', manifest_key=key, manifest_version=pinned, manifest_sha256=sha,
                          backup_objects_verified=len(entries), requested_at=datetime.now(timezone.utc).isoformat(),
                          source_snapshot_sha256=hashlib.sha256(canonical(load_json((self.directory / 'expected-source.json').read_bytes()))).hexdigest()
                          if self.expected is not None else None)
        self.save()
        restored = self.cli('dynamodb', 'restore-table-from-backup', {'TargetTableName': target, 'BackupArn': arn,
                             'BillingModeOverride': 'PAY_PER_REQUEST'})['TableDescription']
        require(restored.get('TableName') == target and restored.get('RestoreSummary', {}).get('SourceBackupArn') == arn,
                'RESTORE_RECEIPT_MISMATCH')
        self.state.update(created=True, target_arn=restored['TableArn'], phase='restoring',
                          target_table_id=restored.get('TableId'), target_creation_time=restored.get('CreationDateTime'))
        self.save()
        print(json.dumps({'status': 'restoring', 'backup_objects_verified': len(entries)}), flush=True)

    def verify(self):
        state = self.state
        require(state.get('created') is True, 'CREATION_RECEIPT_REQUIRED')
        data, sha, _ = self.download(state['manifest_key'], state['manifest_version'], MAX_MANIFEST_BYTES,
                                     state['manifest_sha256'], read_body=True)
        require(sha == state['manifest_sha256'], 'MANIFEST_CHANGED')
        entries = manifest_entries(load_json(data), self.table, self.assets, self.backups)
        table = self.owned_table()
        require(table and table.get('TableStatus') == 'ACTIVE' and not table.get('RestoreSummary', {}).get('RestoreInProgress'),
                'RESTORE_NOT_ACTIVE')
        self.cli('dynamodb', 'tag-resource', {'ResourceArn': state['target_arn'], 'Tags': [
            {'Key': 'Application', 'Value': 'WorshipCue'}, {'Key': 'Environment', 'Value': 'Development'},
            {'Key': 'RestoreCheckOwner', 'Value': state['run']}]})
        self.state['phase'] = 'verifying'
        self.save()
        self.verify_objects(entries)
        restored = self.scan(state['target_table'])
        save(self.directory / 'restored-scan.json', restored)
        before = load_json(private_path(self.directory / 'source-before.json').read_bytes())
        after = self.scan(self.table)
        save(self.directory / 'source-after.json', after)
        result = qualify(rows(restored['Items']), entries, rows(before['Items']), rows(after['Items']), self.expected)
        result.update(status='complete', backup_objects_verified=state['backup_objects_verified'],
                      retained_scratch_table=True, manifest_version_verified=True)
        self.state.update(phase='complete', result=result, completed_at=datetime.now(timezone.utc).isoformat())
        self.state.pop('last_error', None)
        self.save()
        print(json.dumps(result, sort_keys=True), flush=True)

    def run(self):
        account = self.scope()
        if self.state and self.state.get('phase') == 'complete':
            require(self.owned_table() is not None, 'RETAINED_SCRATCH_TABLE_MISSING')
            print(json.dumps(self.state['result'], sort_keys=True), flush=True)
            return
        if self.state is None:
            self.start(account)
        started, previous = time.monotonic(), None
        while True:
            table = self.owned_table()
            require(table is not None, 'SCRATCH_TABLE_MISSING')
            status = table['TableStatus']
            if status != previous:
                print(json.dumps({'status': 'restoring', 'table_status': status}), flush=True)
                previous = status
            if status == 'ACTIVE' and not table.get('RestoreSummary', {}).get('RestoreInProgress'):
                break
            require(status in ('CREATING', 'ACTIVE') and time.monotonic() - started < 7200, 'RESTORE_PENDING_OR_FAILED')
            time.sleep(15)
        self.verify()

    def cleanup(self):
        self.scope()
        table = self.owned_table()
        if table is None:
            require(self.state.get('phase') in ('delete_requested', 'deleted'), 'SCRATCH_TABLE_MISSING')
            self.state['phase'] = 'deleted'
            self.save()
            print(json.dumps({'status': 'deleted', 'scratch_tables_deleted': 1}), flush=True)
            return
        if table.get('TableStatus') == 'DELETING':
            require(self.state.get('phase') == 'delete_requested', 'SCRATCH_DELETE_RECEIPT_REQUIRED')
        else:
            require(table.get('TableStatus') == 'ACTIVE' and not table.get('RestoreSummary', {}).get('RestoreInProgress'), 'CLEANUP_WAIT_FOR_RESTORE')
            tags = self.cli('dynamodb', 'list-tags-of-resource', {'ResourceArn': self.state['target_arn']}).get('Tags', [])
            require({'Application': 'WorshipCue', 'Environment': 'Development', 'RestoreCheckOwner': self.state['run']}.items()
                    <= {tag['Key']: tag['Value'] for tag in tags}.items(), 'SCRATCH_TAG_OWNERSHIP_MISMATCH')
            self.state['phase'] = 'delete_requested'
            self.save()
            self.cli('dynamodb', 'delete-table', {'TableName': self.state['target_table']})
        for _ in range(40):
            if self.owned_table() is None:
                self.state['phase'] = 'deleted'
                self.save()
                print(json.dumps({'status': 'deleted', 'scratch_tables_deleted': 1}), flush=True)
                return
            time.sleep(3)
        raise Failure('SCRATCH_DELETE_PENDING')


def self_test():
    class Contracts(unittest.TestCase):
        def item(self, pk, sk, value):
            return {'PK': {'S': pk}, 'SK': {'S': sk}, 'data': {'S': canonical(value).decode()},
                    'etag': {'S': hashlib.sha256(canonical(value)).hexdigest()}}

        def test_real_stored_digest_and_corruption(self):
            item = self.item('T#synthetic', 'songs#synthetic', {'id': 'synthetic'})
            self.assertEqual(1, len(rows([item])))
            item['data']['S'] = '{"id":"changed"}'
            with self.assertRaises(Failure):
                rows([item])

        def test_ephemeral_changes_are_excluded_but_stable_changes_fail(self):
            expected = rows([self.item('T#synthetic', 'songs#synthetic', {'id': 'synthetic'}),
                             self.item('WS#synthetic', 'STATE', {'id': 'expired'}),
                             self.item('U#synthetic', 'RATE#REDEEM#synthetic', {'uses': 1, 'expires_at_epoch': 123})])
            actual = rows([self.item('T#synthetic', 'songs#synthetic', {'id': 'synthetic'})])
            self.assertEqual(1, match_stable(expected, actual))
            with self.assertRaises(Failure):
                match_stable(expected, rows([self.item('T#synthetic', 'songs#synthetic', {'id': 'changed'})]))

        def test_verified_files_must_be_manifested(self):
            asset = dict(id='synthetic', status='verified', type='pdf', team_id='synthetic', storage_key='synthetic.pdf', sha256='a' * 64, bytes=123)
            restored = rows([self.item('T#synthetic', 'assets#synthetic', asset)])
            with self.assertRaises(Failure):
                qualify(restored, {}, restored, restored)
            result = qualify(restored, {'synthetic.pdf': {'sha256': 'a' * 64, 'bytes': 123}}, restored, restored)
            self.assertEqual(1, result['verified_assets'])
            self.assertFalse(result['source_snapshot_transactional'])

        def test_published_reference_hash_must_match_asset(self):
            asset = dict(id='asset', status='verified', type='pdf', team_id='team', storage_key='synthetic.pdf', sha256='a' * 64, bytes=123)
            chart = dict(id='chart', team_id='team', pdf_asset_id='asset', pdf_sha256='b' * 64, pdf_bytes=123)
            restored = rows([self.item('T#team', 'assets#asset', asset), self.item('T#team', 'chart_versions#chart', chart)])
            with self.assertRaises(Failure):
                qualify(restored, {'synthetic.pdf': {'sha256': 'a' * 64, 'bytes': 123}}, restored, restored)

        def test_live_mutable_change_does_not_fake_full_snapshot_match(self):
            old = rows([self.item('T#team', 'setlists#synthetic', {'revision': 1})])
            new = rows([self.item('T#team', 'setlists#synthetic', {'revision': 2})])
            result = qualify(old, {}, new, new)
            self.assertEqual(1, result['changed_or_unmatched_live_rows'])
            self.assertIsNone(result['expected_stable_rows_matching'])
            with self.assertRaises(Failure):
                qualify(old, {}, new, new, expected=new)

        def test_cleanup_refuses_source_or_unowned_table_without_cloud_call(self):
            runner = RestoreCheck.__new__(RestoreCheck)
            runner.table = 'source-table'
            runner.state = {'created': False, 'owner': 'WorshipCueRestoreCheck'}
            with self.assertRaises(Failure):
                runner.owned_table()
            run = str(uuid.uuid4())
            runner.state.update(created=True, run=run, target_table='source-table')
            with self.assertRaises(Failure):
                runner.owned_table()

        def test_completed_restore_uses_creation_identity_when_aws_omits_summary(self):
            run = str(uuid.uuid4())
            runner = RestoreCheck.__new__(RestoreCheck)
            runner.table = 'source-table'
            when = '2026-10-08T12:00:01+00:00'
            target = 'WorshipCue-dev-restorecheck-' + run
            runner.state = {'created': True, 'owner': 'WorshipCueRestoreCheck', 'run': run,
                'target_table': target, 'target_arn': 'synthetic-arn', 'backup_arn': 'synthetic-backup',
                'requested_at': '2026-10-08T12:00:00+00:00', 'target_table_id': 'synthetic-id', 'target_creation_time': when}
            description = dict(TableName=target, TableArn='synthetic-arn', TableStatus='ACTIVE',
                               TableId='synthetic-id', CreationDateTime=when)
            runner.cli = lambda *args, **kwargs: {'Table': description}
            self.assertEqual('ACTIVE', runner.owned_table()['TableStatus'])
            description['TableId'] = 'replacement-id'
            with self.assertRaises(Failure) as caught:
                runner.owned_table()
            self.assertEqual('SCRATCH_TABLE_ID_MISMATCH', caught.exception.code)

        def test_pinned_download_hashes_actual_bytes_and_removes_local_file(self):
            payload = b'synthetic backup bytes'
            sha = hashlib.sha256(payload).hexdigest()
            checksum_value = base64.b64encode(hashlib.sha256(payload).digest()).decode()
            with tempfile.TemporaryDirectory() as directory:
                runner = RestoreCheck.__new__(RestoreCheck)
                runner.directory, runner.backups = Path(directory), 'synthetic-backups'
                calls = []
                def cli(service, operation, arguments, outfile=None):
                    calls.append((service, operation, arguments))
                    self.assertEqual('pinned-synthetic-version', arguments['VersionId'])
                    if outfile:
                        outfile.write_bytes(payload)
                    return dict(VersionId='pinned-synthetic-version', ContentLength=len(payload),
                                ChecksumSHA256=checksum_value, ChecksumType='FULL_OBJECT')
                runner.cli = cli
                _, actual, _ = runner.download('synthetic-key', 'pinned-synthetic-version', 100, sha)
                self.assertEqual(sha, actual)
                self.assertEqual(['head-object', 'get-object'], [call[1] for call in calls])
                self.assertEqual([], list(Path(directory).iterdir()))

        def test_pinned_manifest_with_expected_hash_returns_parseable_body(self):
            payload = canonical({'status': 'complete'})
            sha = hashlib.sha256(payload).hexdigest()
            with tempfile.TemporaryDirectory() as directory:
                runner = RestoreCheck.__new__(RestoreCheck)
                runner.directory, runner.backups = Path(directory), 'synthetic-backups'
                def cli(service, operation, arguments, outfile=None):
                    if outfile:
                        outfile.write_bytes(payload)
                    return dict(VersionId='pinned-version', ContentLength=len(payload),
                                ChecksumSHA256=base64.b64encode(hashlib.sha256(payload).digest()).decode())
                runner.cli = cli
                body, actual, _ = runner.download('synthetic-manifest', 'pinned-version', 100, sha, read_body=True)
                self.assertEqual('complete', load_json(body)['status'])
                self.assertEqual(sha, actual)

        def test_pinned_download_rejects_wrong_bytes_even_with_claimed_checksum(self):
            with tempfile.TemporaryDirectory() as directory:
                runner = RestoreCheck.__new__(RestoreCheck)
                runner.directory, runner.backups = Path(directory), 'synthetic-backups'
                def cli(service, operation, arguments, outfile=None):
                    if outfile:
                        outfile.write_bytes(b'corrupt')
                    return dict(VersionId='pinned-version', ContentLength=7,
                                ChecksumSHA256=base64.b64encode(b'a' * 32).decode())
                runner.cli = cli
                with self.assertRaises(Failure) as caught:
                    runner.download('synthetic-key', 'pinned-version', 100, 'a' * 64)
                self.assertEqual('OBJECT_HASH_MISMATCH', caught.exception.code)
                self.assertEqual([], list(Path(directory).iterdir()))

        def test_get_object_cli_uses_explicit_required_arguments_without_json_flag(self):
            from unittest.mock import patch
            from types import SimpleNamespace
            with tempfile.TemporaryDirectory() as directory:
                runner = RestoreCheck.__new__(RestoreCheck)
                runner.directory, runner.aws, runner.config = Path(directory), '/synthetic/aws', {}
                outfile = Path(directory) / 'synthetic-object.bin'
                with patch('subprocess.run', return_value=SimpleNamespace(returncode=0, stdout=b'{}', stderr=b'')) as call:
                    runner.cli('s3api', 'get-object', {'Bucket': 'synthetic-bucket', 'Key': 'synthetic-key',
                               'VersionId': 'synthetic-version', 'ChecksumMode': 'ENABLED'}, outfile=outfile)
                command = call.call_args.args[0]
                self.assertNotIn('--cli-input-json', command)
                self.assertEqual('synthetic-bucket', command[command.index('--bucket') + 1])
                self.assertEqual('synthetic-key', command[command.index('--key') + 1])
                self.assertEqual('synthetic-version', command[command.index('--version-id') + 1])
                self.assertEqual(str(outfile), command[-1])
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(Contracts))
    return 0 if result.wasSuccessful() else 1


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path)
    parser.add_argument('--state-dir', type=Path)
    parser.add_argument('--source-snapshot', type=Path)
    disposition = parser.add_mutually_exclusive_group()
    disposition.add_argument('--keep', action='store_true', default=True, help='Retain the scratch table (default).')
    disposition.add_argument('--cleanup', action='store_true', help='Delete only the scratch table bound to the external creation receipt.')
    parser.add_argument('--self-test', action='store_true', help='Run local contract checks without AWS.')
    args = parser.parse_args()
    if args.self_test:
        sys.exit(self_test())
    if args.config is None:
        parser.error('--config is required unless --self-test is used')
    runner = None
    try:
        runner = RestoreCheck(args.config, args.state_dir, args.source_snapshot)
        runner.cleanup() if args.cleanup else runner.run()
    except Exception as error:
        code = error.code if isinstance(error, Failure) else 'UNEXPECTED_RESTORE_CHECK_FAILURE'
        if runner and runner.state:
            runner.state['last_error'] = code
            try:
                runner.save()
            except OSError:
                code = 'PRIVATE_RECEIPT_WRITE_FAILED'
        print(json.dumps({'status': 'failed', 'code': code}), flush=True)
        sys.exit(1)
