#!/usr/bin/env python3
"""Qualify deployed SES feedback using AWS simulator mailboxes only.

Private configuration, receipts and failed-event payloads remain external. This
does not request production access, alter identities, subscribe operators, or
send to people. Existing SES feedback forwarding can notify the verified sender.
Only this run's exact deliberately malformed Lambda event may be deleted from
the private failed-event queue. Other failed events are never deleted.
"""
import argparse
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

from smoke import Failure, HTTP

REPO = Path(__file__).resolve().parents[2]
REQUIRED = ('APIURL', 'UserPoolId', 'TableName', 'MailConfigurationSet',
            'MailFeedbackFunction', 'MailFeedbackTopic', 'MailFeedbackDeadLetters')


def require(value, code):
    if not value:
        raise Failure(code)


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False,
                      allow_nan=False).encode()


def load_json(value):
    try:
        return json.loads(value, parse_constant=lambda _: (_ for _ in ()).throw(ValueError()))
    except (TypeError, ValueError, UnicodeError):
        raise Failure('INVALID_PRIVATE_JSON') from None


def save(path, value):
    temporary = path.with_name(path.name + '.' + uuid.uuid4().hex + '.tmp')
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'wb') as file:
        file.write(canonical(value) + b'\n')
        file.flush()
        os.fsync(file.fileno())
    os.replace(temporary, path)
    os.chmod(path, 0o600)


def private_file(path):
    path = path.resolve()
    require(not path.is_relative_to(REPO), 'PRIVATE_INPUT_MUST_BE_EXTERNAL')
    require(path.is_file() and path.stat().st_mode & 0o077 == 0, 'PRIVATE_INPUT_PERMISSIONS_REQUIRED')
    return path


def simulator_address(kind, run):
    require(kind in ('bounce', 'complaint') and re.fullmatch('[0-9a-f]{32}', run or ''), 'INVALID_SIMULATOR_SCOPE')
    return kind + '+' + run + '@simulator.amazonses.com'


def suppression(item, reason):
    try:
        value = load_json(item['data']['S'])
        require(set(value) == {'reason', 'suppressed_at_epoch', 'event_hash'}, 'SUPPRESSION_PRIVATE_SHAPE')
        require(value['reason'] == reason and type(value['suppressed_at_epoch']) is int
                and value['suppressed_at_epoch'] > 0 and re.fullmatch('[0-9a-f]{64}', value['event_hash']),
                'SUPPRESSION_CONTENT_MISMATCH')
        require(item['etag']['S'] == hashlib.sha256(canonical(value)).hexdigest(), 'SUPPRESSION_DIGEST_MISMATCH')
        return True
    except (KeyError, TypeError):
        raise Failure('INVALID_SUPPRESSION_ROW') from None


def owned_marker(body, marker):
    try:
        value = load_json(body)
    except Failure:
        return False
    return value == marker and isinstance(marker, dict) and set(marker) == {'qualification_marker'}


class Runner:
    def __init__(self, config_path, directory, wait_seconds=360, failure_test=True):
        self.config = load_json(private_file(config_path).read_bytes())
        self.outputs = self.config.get('outputs', {})
        if isinstance(self.outputs, list):
            self.outputs = {r['OutputKey']: r['OutputValue'] for r in self.outputs}
        require(all(isinstance(self.outputs.get(k), str) and self.outputs[k] for k in REQUIRED), 'MISSING_STACK_OUTPUTS')
        require(self.config.get('stack') == 'worshipcue-dev' and self.config.get('region') == 'us-east-1', 'DEVELOPMENT_STACK_REQUIRED')
        directory = directory.resolve()
        require(not directory.is_relative_to(REPO), 'PRIVATE_STATE_MUST_BE_EXTERNAL')
        directory.mkdir(parents=True, exist_ok=True)
        os.chmod(directory, 0o700)
        self.directory, self.path = directory, directory / 'mail-state.json'
        self.aws = self.config.get('aws_cli') or shutil.which('aws')
        require(self.aws and Path(self.aws).is_file(), 'AWS_CLI_UNAVAILABLE')
        self.region, self.profile = self.config['region'], self.config.get('profile', 'default')
        self.fingerprint = hashlib.sha256(canonical({k: self.outputs[k] for k in REQUIRED})).hexdigest()
        self.state = load_json(private_file(self.path).read_bytes()) if self.path.exists() else {
            'fingerprint': self.fingerprint, 'run': uuid.uuid4().hex, 'mailboxes': {}, 'failure_test': {}}
        require(self.state.get('fingerprint') == self.fingerprint, 'STATE_STACK_MISMATCH')
        simulator_address('bounce', self.state.get('run'))
        marker = self.state.get('failure_test', {}).get('marker')
        require(marker is None or marker == {'qualification_marker': 'worshipcue-mail-failure-' + self.state['run']},
                'FAILED_EVENT_OWNERSHIP_MISMATCH')
        self.http = HTTP(self.outputs['APIURL'])
        self.wait_seconds, self.failure_test = wait_seconds, failure_test
        self.save()

    def save(self):
        save(self.path, self.state)

    def cli(self, service, operation, args=None, extra=None):
        input_path = self.directory / ('input-' + uuid.uuid4().hex + '.json')
        save(input_path, args or {})
        command = [self.aws, service, operation, '--region', self.region, '--profile', self.profile,
                   '--cli-input-json', 'file://' + str(input_path), '--output', 'json', '--no-cli-pager'] + (extra or [])
        try:
            result = subprocess.run(command, capture_output=True, timeout=45, env={**os.environ, 'AWS_PAGER': ''})
        except (OSError, subprocess.TimeoutExpired):
            raise Failure('AWS_CLI_UNAVAILABLE') from None
        finally:
            input_path.unlink(missing_ok=True)
        if result.returncode:
            match = re.search(rb'An error occurred \(([A-Za-z0-9]+)\)', result.stderr)
            raise Failure(match[1].decode().upper() if match else 'AWS_CLI_FAILED') from None
        return load_json(result.stdout) if result.stdout else {}

    def infrastructure(self):
        account = self.cli('sts', 'get-caller-identity')['Account']
        stack = self.cli('cloudformation', 'describe-stacks', {'StackName': self.config['stack']})['Stacks'][0]
        require(stack.get('StackStatus') in ('CREATE_COMPLETE', 'UPDATE_COMPLETE'), 'STACK_NOT_READY')
        actual = {r['OutputKey']: r['OutputValue'] for r in stack['Outputs']}
        require(all(actual.get(k) == self.outputs[k] for k in REQUIRED), 'DEPLOYED_OUTPUT_MISMATCH')
        pool = self.cli('cognito-idp', 'describe-user-pool', {'UserPoolId': self.outputs['UserPoolId']})['UserPool']
        email = pool['EmailConfiguration']
        require(email.get('EmailSendingAccount') == 'DEVELOPER' and email.get('ConfigurationSet') == self.outputs['MailConfigurationSet'], 'COGNITO_MAIL_CONFIGURATION_MISMATCH')
        expected_source = 'arn:aws:ses:' + self.region + ':' + account + ':identity/' + self.config['sender']
        require(email.get('SourceArn') == expected_source, 'MAIL_IDENTITY_MISMATCH')
        identity = self.cli('sesv2', 'get-email-identity', {'EmailIdentity': self.config['sender']})
        require(identity.get('VerifiedForSendingStatus') is True, 'SENDER_NOT_VERIFIED')
        settings = self.cli('sesv2', 'get-account')
        require(settings.get('SendingEnabled') is True and set(settings.get('SuppressionAttributes', {}).get('SuppressedReasons', [])) == {'BOUNCE', 'COMPLAINT'}, 'SES_SUPPRESSION_NOT_READY')
        destinations = self.cli('sesv2', 'get-configuration-set-event-destinations', {'ConfigurationSetName': self.outputs['MailConfigurationSet']})['EventDestinations']
        require(any(d.get('Enabled') is True and set(d.get('MatchingEventTypes', [])) == {'BOUNCE', 'COMPLAINT'}
                    and d.get('SnsDestination', {}).get('TopicArn') == self.outputs['MailFeedbackTopic'] for d in destinations), 'FEEDBACK_DESTINATION_NOT_READY')
        function = self.cli('lambda', 'get-function-configuration', {'FunctionName': self.outputs['MailFeedbackFunction']})
        require(function.get('State') == 'Active' and function.get('LastUpdateStatus') == 'Successful'
                and function.get('Handler') == 'mail_feedback.lambda_handler', 'FEEDBACK_FUNCTION_NOT_READY')
        env = function.get('Environment', {}).get('Variables', {})
        require(env == {'TABLE_NAME': self.outputs['TableName'], 'FEEDBACK_TOPIC': self.outputs['MailFeedbackTopic'],
                        'MAIL_CONFIGURATION_SET': self.outputs['MailConfigurationSet'], 'MAIL_SOURCE_ARN': expected_source,
                        'MAIL_ACCOUNT': account}, 'FEEDBACK_ENVIRONMENT_MISMATCH')
        attributes = self.cli('sqs', 'get-queue-attributes', {'QueueUrl': self.outputs['MailFeedbackDeadLetters'], 'AttributeNames': ['All']})['Attributes']
        self.queue_arn = attributes['QueueArn']
        require(self.queue_arn == 'arn:aws:sqs:' + self.region + ':' + account + ':worshipcue-dev-mail-failures'
                and attributes.get('SqsManagedSseEnabled') == 'true' and attributes.get('MessageRetentionPeriod') == '1209600'
                and function.get('DeadLetterConfig', {}).get('TargetArn') == self.queue_arn, 'FAILED_EVENT_QUEUE_NOT_READY')
        queue_policy = load_json(attributes.get('Policy', '{}'))
        require(any(s.get('Effect') == 'Allow' and s.get('Principal') == {'Service': 'sns.amazonaws.com'}
                    and s.get('Action') == 'sqs:SendMessage' and s.get('Resource') == self.queue_arn
                    and s.get('Condition', {}).get('ArnEquals', {}).get('aws:SourceArn') == self.outputs['MailFeedbackTopic']
                    and s.get('Condition', {}).get('StringEquals', {}).get('aws:SourceAccount') == account
                    for s in queue_policy.get('Statement', [])), 'FAILED_EVENT_QUEUE_PERMISSION_MISMATCH')
        subscriptions = self.cli('sns', 'list-subscriptions-by-topic', {'TopicArn': self.outputs['MailFeedbackTopic']})['Subscriptions']
        require(len(subscriptions) == 1 and subscriptions[0].get('Protocol') == 'lambda'
                and subscriptions[0].get('Endpoint') == function['FunctionArn'], 'UNEXPECTED_FEEDBACK_SUBSCRIBER')
        subscription = self.cli('sns', 'get-subscription-attributes', {'SubscriptionArn': subscriptions[0]['SubscriptionArn']})['Attributes']
        require(load_json(subscription.get('RedrivePolicy', '{}')).get('deadLetterTargetArn') == self.queue_arn, 'SNS_REDIVE_NOT_READY')
        policy = load_json(self.cli('sns', 'get-topic-attributes', {'TopicArn': self.outputs['MailFeedbackTopic']})['Attributes']['Policy'])
        set_arn = 'arn:aws:ses:' + self.region + ':' + account + ':configuration-set/' + self.outputs['MailConfigurationSet']
        require(any(s.get('Effect') == 'Allow' and s.get('Principal') == {'Service': 'ses.amazonaws.com'}
                    and s.get('Action') == 'sns:Publish' and s.get('Resource') == self.outputs['MailFeedbackTopic']
                    and s.get('Condition', {}).get('StringEquals') == {'AWS:SourceAccount': account, 'AWS:SourceArn': set_arn}
                    for s in policy['Statement']), 'SES_TOPIC_PERMISSION_MISMATCH')
        invocation_policy = load_json(self.cli('lambda', 'get-policy', {'FunctionName': self.outputs['MailFeedbackFunction']})['Policy'])
        require(any(s.get('Principal') == {'Service': 'sns.amazonaws.com'} and s.get('Action') == 'lambda:InvokeFunction'
                    and s.get('Condition', {}).get('ArnLike', {}).get('AWS:SourceArn') == self.outputs['MailFeedbackTopic']
                    and s.get('Condition', {}).get('StringEquals', {}).get('AWS:SourceAccount') == account
                    for s in invocation_policy['Statement']), 'FEEDBACK_INVOKE_PERMISSION_MISMATCH')
        role = function['Role'].rsplit('/', 1)[-1]
        role_policy = self.cli('iam', 'get-role-policy', {'RoleName': role, 'PolicyName': 'ScopedMailFeedback'})['PolicyDocument']
        require(any(set(s.get('Action', [])) == {'dynamodb:GetItem', 'dynamodb:PutItem'}
                    and s.get('Resource') == 'arn:aws:dynamodb:' + self.region + ':' + account + ':table/' + self.outputs['TableName']
                    and s.get('Condition', {}).get('ForAllValues:StringLike', {}).get('dynamodb:LeadingKeys') == ['MAIL#*']
                    for s in role_policy['Statement']), 'FEEDBACK_STORAGE_PERMISSION_MISMATCH')
        require(any(s.get('Action') == 'sqs:SendMessage' and s.get('Resource') == self.queue_arn
                    for s in role_policy['Statement']), 'LAMBDA_FAILED_EVENT_PERMISSION_MISMATCH')
        self.state['infrastructure'] = {'checked': True, 'production_access_enabled': settings.get('ProductionAccessEnabled') is True,
                                        'feedback_forwarding_enabled': identity.get('FeedbackForwardingStatus') is True,
                                        'sns_delivery_failure_tested': False}
        self.save()
        print(json.dumps({'status': 'infrastructure_checked', **self.state['infrastructure']}), flush=True)

    def get_suppression(self, address):
        digest = hashlib.sha256(address.encode()).hexdigest()
        result = self.cli('dynamodb', 'get-item', {'TableName': self.outputs['TableName'],
                          'Key': {'PK': {'S': 'MAIL#' + digest}, 'SK': {'S': 'SUPPRESSION'}}, 'ConsistentRead': True})
        return result.get('Item')

    def mail(self, kind):
        address = simulator_address(kind, self.state['run'])
        record = self.state['mailboxes'].setdefault(kind, {})
        if not record.get('accepted'):
            record['started_at'] = int(time.time())
            record['last_request_at'] = record['started_at']
            self.save()
            result = self.http.api('/auth/v1/otp', body={'email': address})
            require(isinstance(result, dict) and result.get('challenge') == 'EMAIL_OTP'
                    and isinstance(result.get('session'), str), 'OTP_CHALLENGE_NOT_ACCEPTED')
            record['accepted'] = True
            self.save()
        deadline = time.monotonic() + self.wait_seconds
        reason = 'permanent_bounce' if kind == 'bounce' else 'complaint'
        while True:
            item = self.get_suppression(address)
            if item:
                suppression(item, reason)
                record['feedback_verified'] = True
                self.save()
                break
            require(time.monotonic() < deadline, 'MAIL_FEEDBACK_TIMEOUT')
            time.sleep(min(10, max(0.1, deadline - time.monotonic())))
        # The normal one-attempt/minute abuse guard runs before the delivery gate.
        while int(time.time()) // 60 == record.get('last_request_at', record['started_at']) // 60:
            time.sleep(min(10, 61 - int(time.time()) % 60))
        record['last_request_at'] = int(time.time())
        self.save()
        try:
            self.http.api('/auth/v1/otp', body={'email': address})
        except Failure as error:
            require(error.code == 'EMAIL_DELIVERY_UNAVAILABLE' and error.status == 503, 'SUPPRESSED_OTP_RESPONSE_MISMATCH')
        else:
            raise Failure('SUPPRESSED_OTP_WAS_ACCEPTED')
        record['repeated_otp_blocked'] = True
        self.save()
        print(json.dumps({'status': 'simulator_feedback_verified', 'scenario': kind,
                          'suppression_row_hash_checked': True, 'repeated_otp_blocked': True}), flush=True)

    def failed_event(self):
        state = self.state['failure_test']
        if state.get('deleted_own_marker'):
            return
        if not state.get('invoked'):
            attrs = self.cli('sqs', 'get-queue-attributes', {'QueueUrl': self.outputs['MailFeedbackDeadLetters'],
                             'AttributeNames': ['ApproximateNumberOfMessages', 'ApproximateNumberOfMessagesNotVisible']})['Attributes']
            state['existing_failed_events_preserved'] = any(int(attrs.get(k, 0)) for k in
                ('ApproximateNumberOfMessages', 'ApproximateNumberOfMessagesNotVisible'))
            state.pop('skipped_existing_failed_events', None)
            state['marker'] = {'qualification_marker': 'worshipcue-mail-failure-' + self.state['run']}
            self.save()
            output = self.directory / 'async-reply.json'
            payload = self.directory / 'async-marker.json'
            save(payload, state['marker'])
            try:
                # Lambda's streaming CLI command needs explicit invocation flags
                # and a binary file payload, not a JSON-string blob argument.
                command = [self.aws, 'lambda', 'invoke', '--region', self.region, '--profile', self.profile,
                           '--function-name', self.outputs['MailFeedbackFunction'], '--invocation-type', 'Event',
                           '--payload', 'fileb://' + str(payload), '--cli-binary-format', 'raw-in-base64-out',
                           '--output', 'json', '--no-cli-pager', str(output)]
                reply = subprocess.run(command, capture_output=True, timeout=45, env={**os.environ, 'AWS_PAGER': ''})
                if reply.returncode:
                    # Keep the exact diagnostic private; public output stays categorical.
                    save(self.directory / 'async-invoke-diagnostic.json', {'exit': reply.returncode,
                         'stderr': reply.stderr.decode(errors='replace')})
                    raise Failure('ASYNC_INVOKE_FAILED')
                result = load_json(reply.stdout)
            except (OSError, subprocess.TimeoutExpired):
                raise Failure('AWS_CLI_UNAVAILABLE') from None
            finally:
                output.unlink(missing_ok=True)
                payload.unlink(missing_ok=True)
            require(result.get('StatusCode') == 202, 'ASYNC_FAILURE_TEST_NOT_ACCEPTED')
            state['invoked'] = True
            self.save()
        deadline = time.monotonic() + self.wait_seconds
        while time.monotonic() < deadline:
            response = self.cli('sqs', 'receive-message', {'QueueUrl': self.outputs['MailFeedbackDeadLetters'],
                                'MaxNumberOfMessages': 10, 'VisibilityTimeout': 10, 'WaitTimeSeconds': 10})
            for message in response.get('Messages', []):
                if not owned_marker(message.get('Body'), state['marker']):
                    self.cli('sqs', 'change-message-visibility', {'QueueUrl': self.outputs['MailFeedbackDeadLetters'],
                             'ReceiptHandle': message['ReceiptHandle'], 'VisibilityTimeout': 0})
                    continue
                # Persist ownership before deletion; never delete by queue size or position.
                state['received_own_marker'] = True
                state['message_id'] = message['MessageId']
                state['body_sha256'] = hashlib.sha256(message['Body'].encode()).hexdigest()
                self.save()
                receipt = load_json(private_file(self.path).read_bytes())
                require(receipt['fingerprint'] == self.fingerprint and receipt['failure_test']['marker'] == state['marker']
                        and receipt['failure_test']['message_id'] == message['MessageId'], 'FAILED_EVENT_OWNERSHIP_MISMATCH')
                self.cli('sqs', 'delete-message', {'QueueUrl': self.outputs['MailFeedbackDeadLetters'], 'ReceiptHandle': message['ReceiptHandle']})
                state['deleted_own_marker'] = True
                self.save()
                print(json.dumps({'status': 'async_failure_recovered', 'deleted_only_own_marker': True}), flush=True)
                return
            # Existing events are returned immediately; avoid repeatedly reading
            # the same unrelated event while the normal Lambda retries run.
            if response.get('Messages'):
                time.sleep(min(5, max(0.1, deadline - time.monotonic())))
        raise Failure('FAILED_EVENT_RECOVERY_TIMEOUT')

    def run(self):
        self.infrastructure()
        for kind in ('bounce', 'complaint'):
            self.mail(kind)
        if self.failure_test:
            self.failed_event()
        self.state['status'] = 'complete'
        self.save()
        summary = {'status': 'complete', 'simulator_feedback_scenarios': 2,
                   'suppressed_otp_requests': 2, 'async_failure_recovered': bool(self.state['failure_test'].get('deleted_own_marker')),
                   'failed_event_test_skipped': bool(self.state['failure_test'].get('skipped_existing_failed_events')),
                   'sns_delivery_failure_tested': False, 'ses_list_population_tested': False,
                   'feedback_forwarding_enabled': self.state['infrastructure']['feedback_forwarding_enabled']}
        save(self.directory / 'mail-result.json', summary)
        print(json.dumps(summary), flush=True)


class SelfTests(unittest.TestCase):
    def test_only_simulator_addresses_can_be_generated(self):
        run = 'a' * 32
        self.assertEqual('bounce+' + run + '@simulator.amazonses.com', simulator_address('bounce', run))
        for kind, value in (('success', run), ('user@example.test', run), ('bounce', '../private'), ('bounce', None)):
            with self.assertRaises(Failure): simulator_address(kind, value)

    def test_private_receipts_and_unsafe_inputs(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'receipt.json'
            save(path, {'value': 'synthetic'})
            self.assertEqual(0o600, path.stat().st_mode & 0o777)
            self.assertEqual(path.resolve(), private_file(path))
            path.chmod(0o644)
            with self.assertRaises(Failure): private_file(path)
        with self.assertRaises(Failure): private_file(REPO / 'aws' / 'template.json')
        for value in ('null\x00', '{"value":NaN}', b'\xff'):
            with self.assertRaises(Failure): load_json(value)

    def test_only_exact_own_failed_event_is_deletable(self):
        marker = {'qualification_marker': 'synthetic-owned'}
        self.assertTrue(owned_marker(canonical(marker), marker))
        for value in ({'qualification_marker': 'another'}, dict(marker, private='synthetic'), {'Records': []}, []):
            self.assertFalse(owned_marker(canonical(value), marker))
        self.assertFalse(owned_marker('not-json', marker))

    def test_actual_stored_digest_and_private_shape_are_verified(self):
        value = {'reason': 'complaint', 'suppressed_at_epoch': 123, 'event_hash': 'b' * 64}
        item = {'data': {'S': canonical(value).decode()}, 'etag': {'S': hashlib.sha256(canonical(value)).hexdigest()}}
        self.assertTrue(suppression(item, 'complaint'))
        with self.assertRaises(Failure): suppression(item, 'permanent_bounce')
        bad = {'data': item['data'], 'etag': {'S': 'a' * 64}}
        with self.assertRaises(Failure): suppression(bad, 'complaint')
        value['address'] = 'synthetic@example.test'
        with self.assertRaises(Failure): suppression({'data': {'S': canonical(value).decode()}}, 'complaint')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path)
    parser.add_argument('--state-dir', type=Path)
    parser.add_argument('--wait-seconds', type=int, default=360)
    parser.add_argument('--skip-failure-test', action='store_true')
    parser.add_argument('--self-test', action='store_true')
    args = parser.parse_args()
    if args.self_test:
        return 0 if unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(SelfTests)).wasSuccessful() else 1
    if not args.config or not args.state_dir or not 30 <= args.wait_seconds <= 600:
        parser.error('--config and --state-dir are required; wait must be 30–600 seconds')
    try:
        Runner(args.config, args.state_dir, args.wait_seconds, not args.skip_failure_test).run()
        return 0
    except Failure as error:
        print(json.dumps({'status': 'failed', 'code': error.code}), flush=True)
    except Exception:
        print(json.dumps({'status': 'failed', 'code': 'QUALIFICATION_FAILED'}), flush=True)
    return 1


if __name__ == '__main__':
    sys.exit(main())
