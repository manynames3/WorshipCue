#!/usr/bin/env python3
"""Explicit, scoped operator subscription and SES review operations.

All addresses, resource identifiers, request bodies and receipts stay in private
external files. Subscription confirmation is performed by the human recipient.
Publishing a test proves SNS acceptance, not that the operator read the email.
"""
import argparse
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time
import unittest
import uuid

from prepare_ses_request import request
from qualify_mail import REPO, canonical, load_json, private_file, require, save
from smoke import Failure

WEBSITE = 'https://github.com/manynames3/WorshipCue/tree/v2'
MAIL_ALARMS = ('MailFeedbackErrors', 'MailFeedbackDeadLetterErrors',
               'MailFeedbackDeliveryFailures', 'MailFeedbackBacklog')
ALARMS = MAIL_ALARMS + ('BackupErrors', 'BackupStaleCompletion')
READY_PROCESS = ('A confirmed operator email subscription is connected to the four scoped '
    'feedback failure and backlog alarms. The operator investigates the private recovery queue, '
    'repairs the cause and replays only exact resolved events; unresolved events remain in the '
    'encrypted 14-day recovery queue. A separate test notification is used to check the operator '
    'notification path. This pilot sends only sign-in codes explicitly requested by the recipient.')
DRAFT_CAVEAT = ('This is a review draft: human alert delivery and the operator contact/response '
                'process must be confirmed before submission.')


def digest(value):
    return hashlib.sha256(canonical(value)).hexdigest()


def ready_request(config, website=WEBSITE):
    require(website == WEBSITE, 'APPROVED_PRODUCT_PAGE_REQUIRED')
    value = request(config, website)
    require(DRAFT_CAVEAT in value['UseCaseDescription'], 'DRAFT_CONTRACT_CHANGED')
    value['UseCaseDescription'] = value['UseCaseDescription'].replace(DRAFT_CAVEAT, READY_PROCESS)
    return value


def review_status(account):
    value = account.get('Details', {}).get('ReviewDetails', {}).get('Status', 'NONE')
    require(value in ('NONE', 'PENDING', 'FAILED', 'GRANTED', 'DENIED'), 'UNKNOWN_SES_REVIEW_STATUS')
    return value


def request_matches(account, value):
    details = account.get('Details', {})
    return all(details.get(k) == v for k, v in value.items() if k != 'ProductionAccessEnabled')


def history_epoch(value):
    if isinstance(value, str):
        return datetime.fromisoformat(value.replace('Z', '+00:00')).timestamp()
    raise Failure('INVALID_ALARM_HISTORY_TIMESTAMP')


def alarm_history_proof(items, alarm, topic, marker):
    """Bind SNS success to the sole owned ALARM transition, not a prior incident."""
    states = []
    for row in items:
        if row.get('AlarmName') != alarm or row.get('HistoryItemType') != 'StateUpdate':
            continue
        value = load_json(row.get('HistoryData', '{}')).get('newState', {})
        if value.get('stateValue') == 'ALARM':
            states.append((history_epoch(row['Timestamp']), value.get('stateReason')))
    owned = [stamp for stamp, reason in states if reason == marker]
    if len(owned) != 1:
        return False, False
    stamp = owned[0]
    # A real concurrent transition must never be attributed to our test.
    if any(reason != marker and when >= stamp for when, reason in states):
        return True, False
    for row in items:
        if row.get('AlarmName') != alarm or row.get('HistoryItemType') != 'Action':
            continue
        when = history_epoch(row['Timestamp'])
        if not stamp <= when <= stamp + 120:
            continue
        value = load_json(row.get('HistoryData', '{}'))
        structured_success = value.get('actionState') == 'Succeeded' and value.get('notificationResource') == topic
        exact_summary = row.get('HistorySummary', '').rstrip('.') == 'Successfully executed action ' + topic
        if structured_success or exact_summary:
            return True, True
    return True, False


def quiet_alarm_start(alarms, counts):
    require(len(alarms) == len(ALARMS) and all(v.get('StateValue') == 'OK' for v in alarms), 'ACTIVE_OR_UNKNOWN_OPERATOR_ALARM_DO_NOT_TEST')
    require(set(counts) == {'visible', 'in_flight', 'delayed'} and all(v == 0 for v in counts.values()), 'RECOVERY_QUEUE_NOT_EMPTY_DO_NOT_TEST')


def validate_alarm_configuration(alarms, names, topic, backup_function):
    require(set(names) == set(ALARMS) and len(alarms) == len(ALARMS)
            and {v.get('AlarmName') for v in alarms} == set(names.values())
            and all(v.get('AlarmActions') == [topic] and v.get('ActionsEnabled') is True for v in alarms), 'ALARM_ACTIONS_NOT_READY')
    backup = next(v for v in alarms if v.get('AlarmName') == names['BackupErrors'])
    expected = {'Namespace': 'AWS/Lambda', 'MetricName': 'Errors', 'Statistic': 'Sum', 'Period': 60,
        'EvaluationPeriods': 1, 'DatapointsToAlarm': 1, 'Threshold': 1,
        'ComparisonOperator': 'GreaterThanOrEqualToThreshold', 'TreatMissingData': 'notBreaching',
        'Dimensions': [{'Name': 'FunctionName', 'Value': backup_function}]}
    require(all(backup.get(k) == v for k, v in expected.items()), 'BACKUP_ALARM_CONFIGURATION_MISMATCH')
    stale = next(v for v in alarms if v.get('AlarmName') == names['BackupStaleCompletion'])
    expected.update(Namespace='WorshipCue/Backup', MetricName='Completed', Period=3600,
        EvaluationPeriods=48, DatapointsToAlarm=48, ComparisonOperator='LessThanThreshold', TreatMissingData='breaching')
    require(all(stale.get(k) == v for k, v in expected.items()), 'BACKUP_HEARTBEAT_CONFIGURATION_MISMATCH')


def validate_operator_policy(policy, topic, account, names):
    statements = policy.get('Statement', [])
    require(isinstance(statements, list) and len(statements) == 2
            and {s.get('Sid') for s in statements} == {'ScopedCloudWatchAlarms', 'RequireTLS'}, 'OPERATOR_TOPIC_PERMISSION_MISMATCH')
    allow = next(s for s in statements if s['Sid'] == 'ScopedCloudWatchAlarms')
    expected = {'arn:aws:cloudwatch:us-east-1:' + account + ':alarm:' + n for n in names.values()}
    condition = allow.get('Condition', {})
    sources = condition.get('ArnEquals', {}).get('aws:SourceArn', [])
    require(allow.get('Effect') == 'Allow' and allow.get('Principal') == {'Service': 'cloudwatch.amazonaws.com'}
            and allow.get('Action') == 'sns:Publish' and allow.get('Resource') == topic
            and set(condition) == {'StringEquals', 'ArnEquals'}
            and condition['StringEquals'] == {'aws:SourceAccount': account}
            and set(condition['ArnEquals']) == {'aws:SourceArn'}
            and isinstance(sources, list) and len(sources) == len(expected) and set(sources) == expected,
            'OPERATOR_TOPIC_PERMISSION_MISMATCH')
    deny = next(s for s in statements if s['Sid'] == 'RequireTLS')
    require(deny.get('Effect') == 'Deny' and deny.get('Principal') == '*'
            and deny.get('Action') == 'sns:Publish' and deny.get('Resource') == topic
            and deny.get('Condition') == {'Bool': {'aws:SecureTransport': 'false'}}, 'OPERATOR_TOPIC_TLS_REQUIRED')


class Operations:
    def __init__(self, config_path, directory):
        self.config = load_json(private_file(config_path).read_bytes())
        require(self.config.get('stack') == 'worshipcue-dev' and self.config.get('region') == 'us-east-1', 'DEVELOPMENT_SCOPE_REQUIRED')
        self.outputs = self.config.get('outputs', {})
        if isinstance(self.outputs, list):
            self.outputs = {v['OutputKey']: v['OutputValue'] for v in self.outputs}
        require(all(isinstance(self.outputs.get(k), str) and self.outputs[k] for k in
                    ('MailOperatorAlertsTopic', 'MailFeedbackTopic', 'MailFeedbackDeadLetters', 'UserPoolId', 'MailConfigurationSet', 'BackupFunction')), 'OPERATOR_OUTPUTS_REQUIRED')
        self.operator = self.config.get('sender')
        require(isinstance(self.operator, str) and re.fullmatch(r'[A-Za-z0-9.!#$%&\'*+/=?^_`{|}~-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+', self.operator)
                and len(self.operator) <= 254, 'PRIVATE_OPERATOR_ADDRESS_REQUIRED')
        self.directory = directory.resolve()
        require(not self.directory.is_relative_to(REPO), 'PRIVATE_STATE_MUST_BE_EXTERNAL')
        self.directory.mkdir(parents=True, exist_ok=True); os.chmod(self.directory, 0o700)
        self.lock = os.open(self.directory / 'operations.lock', os.O_CREAT | os.O_RDWR, 0o600)
        os.fchmod(self.lock, 0o600)
        try:
            fcntl.flock(self.lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            os.close(self.lock); raise Failure('ANOTHER_OPERATION_IS_RUNNING') from None
        self.path = self.directory / 'operations-state.json'
        self.ready_path = self.directory / 'ses-production-request-READY.json'
        self.fingerprint = digest({'stack': self.config['stack'], 'region': self.config['region'],
            'topic': self.outputs['MailOperatorAlertsTopic'], 'operator': self.operator})
        self.state = load_json(private_file(self.path).read_bytes()) if self.path.exists() else {'fingerprint': self.fingerprint}
        require(self.state.get('fingerprint') == self.fingerprint, 'OPERATOR_STATE_SCOPE_MISMATCH')
        self.aws = self.config.get('aws_cli') or shutil.which('aws')
        require(self.aws and Path(self.aws).is_file(), 'AWS_CLI_UNAVAILABLE')
        self.save()

    def close(self):
        fcntl.flock(self.lock, fcntl.LOCK_UN); os.close(self.lock)

    def save(self):
        save(self.path, self.state)

    def cli(self, service, operation, args=None):
        path = self.directory / ('input-' + uuid.uuid4().hex + '.json'); save(path, args or {})
        try:
            result = subprocess.run([self.aws, service, operation, '--region', self.config['region'],
                '--profile', self.config.get('profile', 'default'), '--cli-input-json', 'file://' + str(path),
                '--output', 'json', '--no-cli-pager', '--no-paginate'], capture_output=True, timeout=45,
                env={**os.environ, 'AWS_PAGER': '', 'AWS_CLI_AUTO_PROMPT': 'off'})
        except (OSError, subprocess.TimeoutExpired) as error:
            save(self.directory / 'last-private-diagnostic.json', {'service': service, 'operation': operation,
                'category': 'local_timeout' if isinstance(error, subprocess.TimeoutExpired) else 'local_execution_failure',
                'at_epoch': int(time.time())})
            raise Failure('AWS_OPERATION_OUTCOME_UNKNOWN') from None
        finally:
            path.unlink(missing_ok=True)
        if result.returncode:
            save(self.directory / 'last-private-diagnostic.json', {'service': service, 'operation': operation,
                'stderr': result.stderr.decode(errors='replace'), 'at_epoch': int(time.time())})
            match = re.search(rb'An error occurred \(([A-Za-z0-9]+)\)', result.stderr)
            raise Failure(match[1].decode().upper() if match else 'AWS_CLI_FAILED') from None
        return load_json(result.stdout) if result.stdout else {}

    def infrastructure(self):
        account = self.cli('sts', 'get-caller-identity')['Account']
        stack = self.cli('cloudformation', 'describe-stacks', {'StackName': self.config['stack']})['Stacks'][0]
        require(stack['StackStatus'] in ('CREATE_COMPLETE', 'UPDATE_COMPLETE'), 'STACK_NOT_READY')
        actual = {v['OutputKey']: v['OutputValue'] for v in stack['Outputs']}
        require(all(actual.get(k) == self.outputs[k] for k in ('MailOperatorAlertsTopic', 'MailFeedbackTopic', 'MailFeedbackDeadLetters', 'UserPoolId', 'MailConfigurationSet', 'BackupFunction')), 'DEPLOYED_OUTPUT_MISMATCH')
        topic = self.outputs['MailOperatorAlertsTopic']
        require(topic == 'arn:aws:sns:us-east-1:' + account + ':worshipcue-dev-mail-operator-alerts'
                and topic != self.outputs['MailFeedbackTopic'], 'DEDICATED_OPERATOR_TOPIC_REQUIRED')
        resources = self.cli('cloudformation', 'describe-stack-resources', {'StackName': self.config['stack']})['StackResources']
        names = {v['LogicalResourceId']: v['PhysicalResourceId'] for v in resources if v['LogicalResourceId'] in ALARMS}
        require(set(names) == set(ALARMS), 'SCOPED_ALARMS_REQUIRED')
        self.alarm_names = names
        alarms = self.cli('cloudwatch', 'describe-alarms', {'AlarmNames': list(names.values())})['MetricAlarms']
        backup = [v['PhysicalResourceId'] for v in resources if v['LogicalResourceId'] == 'BackupFunction']
        require(backup == [self.outputs['BackupFunction']], 'BACKUP_FUNCTION_SCOPE_MISMATCH')
        validate_alarm_configuration(alarms, names, topic, backup[0])
        attributes = self.cli('sns', 'get-topic-attributes', {'TopicArn': topic})['Attributes']
        policy = load_json(attributes['Policy'])
        validate_operator_policy(policy, topic, account, names)
        identity = self.cli('sesv2', 'get-email-identity', {'EmailIdentity': self.operator})
        require(identity.get('VerifiedForSendingStatus') is True, 'SENDER_NOT_VERIFIED')
        pool = self.cli('cognito-idp', 'describe-user-pool', {'UserPoolId': self.outputs['UserPoolId']})['UserPool']
        require(pool.get('EmailConfiguration', {}).get('ConfigurationSet') == self.outputs['MailConfigurationSet'], 'COGNITO_CONFIGURATION_MISMATCH')
        self.state['infrastructure_checked_at_epoch'] = int(time.time()); self.save()

    def queue_counts(self):
        attributes = self.cli('sqs', 'get-queue-attributes', {'QueueUrl': self.outputs['MailFeedbackDeadLetters'],
            'AttributeNames': ['QueueArn', 'ApproximateNumberOfMessages', 'ApproximateNumberOfMessagesNotVisible', 'ApproximateNumberOfMessagesDelayed']})['Attributes']
        account = self.outputs['MailOperatorAlertsTopic'].split(':')[4]
        require(attributes.get('QueueArn') == 'arn:aws:sqs:us-east-1:' + account + ':worshipcue-dev-mail-failures', 'RECOVERY_QUEUE_SCOPE_MISMATCH')
        keys = {'visible': 'ApproximateNumberOfMessages', 'in_flight': 'ApproximateNumberOfMessagesNotVisible', 'delayed': 'ApproximateNumberOfMessagesDelayed'}
        require(all(isinstance(attributes.get(k), str) and re.fullmatch(r'[0-9]+', attributes[k]) for k in keys.values()), 'QUEUE_COUNTS_UNKNOWN')
        return {k: int(attributes[v]) for k, v in keys.items()}

    def qualify_alarm_routing(self, wait_seconds=180):
        require(type(wait_seconds) is int and 1 <= wait_seconds <= 300, 'INVALID_ALARM_TEST_WAIT')
        require(self.subscription(), 'CONFIRMED_OPERATOR_REQUIRED')
        alarm = self.alarm_names['MailFeedbackBacklog']; topic = self.outputs['MailOperatorAlertsTopic']
        record = self.state.get('alarm_qualification')
        if record:
            require(re.fullmatch('[0-9a-f]{32}', record.get('run', '')) and record.get('alarm_name') == alarm
                and record.get('marker') == 'WorshipCue intentional operator routing test ' + record['run'], 'ALARM_TEST_OWNERSHIP_MISMATCH')
            if record.get('complete'):
                return {'status': 'alarm_routing_already_qualified', 'owned_test_transition': True,
                    'sns_action_succeeded': True, 'natural_reevaluation_verified': True, 'inbox_receipt_verified': False}
        else:
            alarms = self.cli('cloudwatch', 'describe-alarms', {'AlarmNames': list(self.alarm_names.values())})['MetricAlarms']
            quiet_alarm_start(alarms, self.queue_counts())
            backlog = next(v for v in alarms if v['AlarmName'] == alarm)
            require(backlog.get('Namespace') == 'AWS/SQS' and backlog.get('MetricName') == 'ApproximateNumberOfMessagesVisible'
                and backlog.get('AlarmActions') == [topic] and backlog.get('ActionsEnabled') is True
                and not backlog.get('OKActions') and not backlog.get('InsufficientDataActions'), 'TEST_ALARM_CONFIGURATION_MISMATCH')
            run = uuid.uuid4().hex
            record = {'run': run, 'alarm_name': alarm, 'marker': 'WorshipCue intentional operator routing test ' + run,
                'started_at_epoch': int(time.time()), 'prior_state': backlog['StateValue'], 'complete': False}
            self.state['alarm_qualification'] = record; self.save()
            # No manual OK restoration: a later genuine incident must stay visible.
            self.cli('cloudwatch', 'set-alarm-state', {'AlarmName': alarm, 'StateValue': 'ALARM', 'StateReason': record['marker'],
                'StateReasonData': json.dumps({'purpose': 'intentional_operator_routing_test', 'run': run})})
            record['state_request_accepted'] = True; self.save()
            print(json.dumps({'status': 'alarm_routing_test_started', 'natural_reevaluation_only': True}), flush=True)
        end = time.monotonic() + wait_seconds
        while time.monotonic() < end:
            history = self.cli('cloudwatch', 'describe-alarm-history', {'AlarmName': alarm, 'MaxRecords': 100,
                'StartDate': datetime.fromtimestamp(record['started_at_epoch'] - 3, timezone.utc).isoformat()})
            require(not history.get('NextToken'), 'ALARM_HISTORY_PAGE_LIMIT_UNVERIFIED')
            save(self.directory / 'alarm-routing-private-history.json', history)
            owned, action = alarm_history_proof(history.get('AlarmHistoryItems', []), alarm, topic, record['marker'])
            alarms = self.cli('cloudwatch', 'describe-alarms', {'AlarmNames': list(self.alarm_names.values())})['MetricAlarms']
            require(len(alarms) == len(ALARMS), 'SCOPED_ALARMS_CHANGED')
            current = next(v for v in alarms if v['AlarmName'] == alarm)
            counts = self.queue_counts()
            require(all(v == 0 for v in counts.values()), 'REAL_QUEUE_ACTIVITY_DO_NOT_RESET')
            require(all(v.get('StateValue') != 'ALARM' or (v['AlarmName'] == alarm and v.get('StateReason') == record['marker']) for v in alarms), 'REAL_ALARM_ACTIVITY_DO_NOT_RESET')
            natural = current.get('StateValue') == 'OK' and current.get('StateReason') != record['marker']
            record.update({'owned_transition_verified': owned, 'sns_action_succeeded': action,
                'natural_reevaluation_verified': natural, 'queue_counts': counts, 'checked_at_epoch': int(time.time())}); self.save()
            if owned and action and natural:
                record['complete'] = True; record['history_sha256'] = digest(history); self.save()
                return {'status': 'alarm_routing_qualified', 'owned_test_transition': True, 'sns_action_succeeded': True,
                    'natural_reevaluation_verified': True, 'manual_ok_reset_performed': False, 'queue_counts_zero': True, 'inbox_receipt_verified': False}
            time.sleep(5)
        raise Failure('ALARM_ROUTING_NOT_YET_QUALIFIED_NO_MANUAL_RESET')

    def subscription(self):
        rows, token = [], None
        for _ in range(20):
            args = {'TopicArn': self.outputs['MailOperatorAlertsTopic']}
            if token: args['NextToken'] = token
            value = self.cli('sns', 'list-subscriptions-by-topic', args)
            rows.extend(value.get('Subscriptions', [])); token = value.get('NextToken')
            if not token: break
        require(not token, 'SUBSCRIPTION_PAGE_LIMIT')
        require(all(v.get('Protocol') == 'email' and v.get('Endpoint', '').lower() == self.operator.lower() for v in rows), 'UNEXPECTED_OPERATOR_SUBSCRIBER')
        require(len(rows) <= 1, 'DUPLICATE_OPERATOR_SUBSCRIPTIONS')
        arn = rows[0].get('SubscriptionArn') if rows else self.state.get('subscription', {}).get('arn')
        confirmed = False
        if arn and arn.startswith(self.outputs['MailOperatorAlertsTopic'] + ':'):
            attributes = self.cli('sns', 'get-subscription-attributes', {'SubscriptionArn': arn})['Attributes']
            require(attributes.get('TopicArn') == self.outputs['MailOperatorAlertsTopic']
                    and attributes.get('Protocol') == 'email' and attributes.get('Endpoint', '').lower() == self.operator.lower()
                    and load_json(attributes.get('FilterPolicy', '{}')) == {}, 'SUBSCRIPTION_SCOPE_MISMATCH')
            confirmed = attributes.get('PendingConfirmation') == 'false'
        self.state['subscription'] = {'arn': arn, 'confirmed': confirmed, 'exists': bool(arn), 'checked_at_epoch': int(time.time())}
        self.save()
        return confirmed

    def subscribe(self):
        if self.subscription(): return {'status': 'operator_already_confirmed', 'sent_confirmation': False}
        if self.state['subscription']['exists']: return {'status': 'operator_confirmation_pending', 'sent_confirmation': False}
        require(not self.state.get('subscription_attempted_at_epoch'), 'SUBSCRIPTION_OUTCOME_UNKNOWN_DO_NOT_RESEND')
        self.state['subscription_attempted_at_epoch'] = int(time.time()); self.save()
        value = self.cli('sns', 'subscribe', {'TopicArn': self.outputs['MailOperatorAlertsTopic'], 'Protocol': 'email',
            'Endpoint': self.operator, 'ReturnSubscriptionArn': True})
        arn = value.get('SubscriptionArn')
        require(isinstance(arn, str) and arn.startswith(self.outputs['MailOperatorAlertsTopic'] + ':'), 'SUBSCRIPTION_RECEIPT_INVALID')
        self.state['subscription'] = {'arn': arn, 'confirmed': False, 'exists': True, 'requested_at_epoch': int(time.time())}; self.save()
        return {'status': 'operator_confirmation_requested', 'sent_confirmation': True, 'human_confirmation_required': True}

    def test_notification(self):
        require(self.subscription(), 'CONFIRMED_OPERATOR_REQUIRED')
        if self.state.get('test_notification', {}).get('accepted'):
            return {'status': 'test_notification_already_published', 'inbox_receipt_verified': False}
        require(not self.state.get('test_notification', {}).get('attempted_at_epoch'), 'TEST_OUTCOME_UNKNOWN_DO_NOT_RESEND')
        self.state['test_notification'] = {'attempted_at_epoch': int(time.time()), 'accepted': False}; self.save()
        value = self.cli('sns', 'publish', {'TopicArn': self.outputs['MailOperatorAlertsTopic'],
            'Subject': 'WorshipCue operator alert test', 'Message': 'WorshipCue operator alert test. This is an intentional test of the dedicated mail feedback failure/backlog notification channel. No production incident or action on a user account is implied.'})
        require(isinstance(value.get('MessageId'), str), 'NOTIFICATION_RECEIPT_INVALID')
        self.state['test_notification'].update({'accepted': True, 'message_id': value['MessageId'], 'accepted_at_epoch': int(time.time())}); self.save()
        return {'status': 'test_notification_published', 'inbox_receipt_verified': False}

    def prepare_production(self):
        require(self.subscription(), 'CONFIRMED_OPERATOR_REQUIRED')
        require(self.state.get('test_notification', {}).get('accepted') is True, 'TEST_NOTIFICATION_REQUIRED')
        value = ready_request(self.config)
        previous = self.state.get('ready_request')
        if previous:
            require(previous['sha256'] == digest(value) and self.ready_path.exists()
                and digest(load_json(private_file(self.ready_path).read_bytes())) == previous['sha256'], 'READY_REQUEST_CHANGED')
        else:
            save(self.ready_path, value)
            self.state['ready_request'] = {'sha256': digest(value), 'prepared_at_epoch': int(time.time())}; self.save()
        return {'status': 'private_production_request_ready', 'submitted': False}

    def submit_production(self, retry_failed=False):
        require(self.subscription(), 'CONFIRMED_OPERATOR_REQUIRED')
        require(self.state.get('test_notification', {}).get('accepted') is True, 'TEST_NOTIFICATION_REQUIRED')
        require(self.state.get('ready_request') and self.ready_path.exists(), 'PREPARE_PRIVATE_REQUEST_FIRST')
        value = load_json(private_file(self.ready_path).read_bytes())
        require(digest(value) == self.state['ready_request']['sha256'] and value == ready_request(self.config), 'READY_REQUEST_CHANGED')
        account = self.cli('sesv2', 'get-account'); status = review_status(account)
        require(account.get('SendingEnabled') is True and set(account.get('SuppressionAttributes', {}).get('SuppressedReasons', [])) == {'BOUNCE', 'COMPLAINT'}, 'SES_SENDING_PROTECTION_REQUIRED')
        if account.get('ProductionAccessEnabled') is True:
            return {'status': 'production_access_already_enabled', 'new_request_submitted': False}
        if status == 'PENDING':
            return {'status': 'production_review_already_pending', 'new_request_submitted': False, 'matches_ready_request': request_matches(account, value)}
        require(status != 'DENIED', 'DENIED_REVIEW_REQUIRES_SEPARATE_REASSESSMENT')
        previous = self.state.get('submission', {})
        require(not previous.get('accepted') or (status == 'FAILED' and retry_failed), 'REQUEST_ALREADY_SUBMITTED')
        require(not previous.get('attempted_at_epoch') or (status == 'FAILED' and retry_failed), 'SUBMISSION_OUTCOME_UNKNOWN_DO_NOT_RESEND')
        require(status != 'FAILED' or retry_failed, 'EXPLICIT_FAILED_REVIEW_RETRY_REQUIRED')
        self.state['submission'] = {'sha256': digest(value), 'attempted_at_epoch': int(time.time()), 'accepted': False}; self.save()
        self.cli('sesv2', 'put-account-details', value)
        self.state['submission'].update({'accepted': True, 'accepted_at_epoch': int(time.time())}); self.save()
        latest = self.cli('sesv2', 'get-account')
        return {'status': 'production_request_submitted', 'request_accepted': True,
            'production_access_enabled': latest.get('ProductionAccessEnabled') is True, 'review_status': review_status(latest)}

    def status(self):
        confirmed = self.subscription(); account = self.cli('sesv2', 'get-account')
        return {'status': 'mail_operations_status', 'operator_confirmed': confirmed, 'scoped_alarm_count': len(ALARMS),
            'feedback_alarm_count': len(MAIL_ALARMS), 'backup_alarm_count': len(ALARMS) - len(MAIL_ALARMS),
            'test_notification_published': self.state.get('test_notification', {}).get('accepted') is True,
            'inbox_receipt_verified': False, 'production_access_enabled': account.get('ProductionAccessEnabled') is True,
            'review_status': review_status(account), 'local_request_accepted': self.state.get('submission', {}).get('accepted') is True}


class SelfTests(unittest.TestCase):
    def test_ready_replaces_only_draft_caveat_with_factual_response_process(self):
        value = ready_request({'stack': 'worshipcue-dev', 'region': 'us-east-1', 'sender': 'synthetic@example.test'})
        self.assertEqual(value['MailType'], 'TRANSACTIONAL'); self.assertNotIn(DRAFT_CAVEAT, value['UseCaseDescription'])
        self.assertIn(READY_PROCESS, value['UseCaseDescription']); self.assertNotIn('automatically replay', value['UseCaseDescription'])
        with self.assertRaises(Failure): ready_request({}, 'https://other.example.test')

    def test_review_status_and_exact_request_matching(self):
        with self.assertRaises(Failure): review_status({'Details': {'ReviewDetails': {'Status': 'unexpected'}}})
        value = {'ProductionAccessEnabled': True, 'WebsiteURL': WEBSITE, 'MailType': 'TRANSACTIONAL'}
        self.assertTrue(request_matches({'Details': {'WebsiteURL': WEBSITE, 'MailType': 'TRANSACTIONAL'}}, value))
        self.assertFalse(request_matches({'Details': {'WebsiteURL': 'https://other.example.test', 'MailType': 'TRANSACTIONAL'}}, value))

    def operation(self, directory, state=None):
        op = Operations.__new__(Operations); op.config = {'stack': 'worshipcue-dev', 'region': 'us-east-1', 'sender': 'synthetic@example.test'}
        op.directory = Path(directory); op.path = op.directory / 'state.json'; op.ready_path = op.directory / 'ready.json'
        op.state = state or {}; op.outputs = {'MailOperatorAlertsTopic': 'arn:aws:sns:us-east-1:000000000000:synthetic'}
        op.operator = 'synthetic@example.test'; return op

    def test_confirmed_subscription_is_required_before_ready_or_send(self):
        with tempfile.TemporaryDirectory() as directory:
            op = self.operation(directory); op.subscription = lambda: False
            for method in (op.prepare_production, op.submit_production, op.test_notification):
                with self.assertRaises(Failure): method()

    def test_ready_receipt_pins_private_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            op = self.operation(directory, {'test_notification': {'accepted': True}}); op.subscription = lambda: True
            op.prepare_production(); self.assertEqual(op.ready_path.stat().st_mode & 0o077, 0)
            value = load_json(op.ready_path.read_bytes()); value['UseCaseDescription'] += ' altered'; save(op.ready_path, value)
            with self.assertRaises(Failure): op.submit_production()

    def test_publish_is_idempotent_and_ack_is_not_inbox_delivery(self):
        with tempfile.TemporaryDirectory() as directory:
            op = self.operation(directory); op.subscription = lambda: True; calls = []
            def cli(service, operation, args): calls.append((service, operation)); return {'MessageId': 'synthetic-message'}
            op.cli = cli
            self.assertFalse(op.test_notification()['inbox_receipt_verified']); op.test_notification()
            self.assertEqual(calls, [('sns', 'publish')])

    def test_existing_pending_review_never_submits_or_claims_ownership(self):
        with tempfile.TemporaryDirectory() as directory:
            op = self.operation(directory, {'test_notification': {'accepted': True}}); op.subscription = lambda: True; op.prepare_production()
            calls = []
            def cli(service, operation, args=None):
                calls.append(operation)
                return {'SendingEnabled': True, 'SuppressionAttributes': {'SuppressedReasons': ['BOUNCE', 'COMPLAINT']},
                    'Details': {'ReviewDetails': {'Status': 'PENDING'}, 'WebsiteURL': 'https://other.example.test'}}
            op.cli = cli; result = op.submit_production()
            self.assertFalse(result['new_request_submitted']); self.assertFalse(result['matches_ready_request']); self.assertEqual(calls, ['get-account'])

    def test_unknown_send_outcome_never_blindly_repeats(self):
        with tempfile.TemporaryDirectory() as directory:
            op = self.operation(directory, {'test_notification': {'attempted_at_epoch': 1}}); op.subscription = lambda: True
            with self.assertRaises(Failure): op.test_notification()

    def test_alarm_qualification_refuses_any_real_or_unknown_incident(self):
        quiet = [{'StateValue': 'OK'}] * len(ALARMS)
        quiet_alarm_start(quiet, {'visible': 0, 'in_flight': 0, 'delayed': 0})
        for state in ('ALARM', 'INSUFFICIENT_DATA', None):
            with self.assertRaises(Failure): quiet_alarm_start([{'StateValue': state}] + quiet[:-1], {'visible': 0, 'in_flight': 0, 'delayed': 0})
        for key in ('visible', 'in_flight', 'delayed'):
            with self.assertRaises(Failure): quiet_alarm_start(quiet, {'visible': 0, 'in_flight': 0, 'delayed': 0, key: 1})

    def test_alarm_proof_requires_owned_transition_and_exact_successful_topic_action(self):
        state = {'AlarmName': 'synthetic-alarm', 'HistoryItemType': 'StateUpdate', 'Timestamp': '2026-10-08T12:00:00Z',
            'HistoryData': json.dumps({'newState': {'stateValue': 'ALARM', 'stateReason': 'owned marker'}})}
        action = {'AlarmName': 'synthetic-alarm', 'HistoryItemType': 'Action', 'Timestamp': '2026-10-08T12:00:01Z',
            'HistoryData': '{}', 'HistorySummary': 'Successfully executed action synthetic-topic'}
        self.assertEqual(alarm_history_proof([state, action], 'synthetic-alarm', 'synthetic-topic', 'owned marker'), (True, True))
        self.assertEqual(alarm_history_proof([action], 'synthetic-alarm', 'synthetic-topic', 'owned marker'), (False, False))
        self.assertEqual(alarm_history_proof([state, action], 'synthetic-alarm', 'other-topic', 'owned marker'), (True, False))
        self.assertEqual(alarm_history_proof([state, {**action, 'HistorySummary': 'Failed to execute action synthetic-topic'}], 'synthetic-alarm', 'synthetic-topic', 'owned marker'), (True, False))
        foreign = {**state, 'Timestamp': '2026-10-08T12:00:00.5Z', 'HistoryData': json.dumps({'newState': {'stateValue': 'ALARM', 'stateReason': 'real incident'}})}
        self.assertEqual(alarm_history_proof([state, action, foreign], 'synthetic-alarm', 'synthetic-topic', 'owned marker'), (True, False))

    def test_alarm_qualification_bounds_wait_and_never_sets_state_on_unconfirmed_operator(self):
        with tempfile.TemporaryDirectory() as directory:
            op = self.operation(directory); op.subscription = lambda: False
            for seconds in (0, 301, True):
                with self.assertRaises(Failure): op.qualify_alarm_routing(seconds)
            with self.assertRaises(Failure): op.qualify_alarm_routing(1)

    def test_alarm_rerun_uses_owned_history_without_repeating_transition(self):
        with tempfile.TemporaryDirectory() as directory:
            run = 'a' * 32; marker = 'WorshipCue intentional operator routing test ' + run
            op = self.operation(directory, {'alarm_qualification': {'run': run, 'marker': marker,
                'alarm_name': 'synthetic-backlog', 'started_at_epoch': 1791460800, 'complete': False}})
            op.subscription = lambda: True; op.alarm_names = {name: 'synthetic-' + name for name in ALARMS}
            op.alarm_names['MailFeedbackBacklog'] = 'synthetic-backlog'
            op.queue_counts = lambda: {'visible': 0, 'in_flight': 0, 'delayed': 0}
            calls = []
            def cli(service, operation, args=None):
                calls.append(operation)
                if operation == 'describe-alarm-history':
                    return {'AlarmHistoryItems': [
                        {'AlarmName': 'synthetic-backlog', 'HistoryItemType': 'StateUpdate', 'Timestamp': '2026-10-08T12:00:00Z',
                            'HistoryData': json.dumps({'newState': {'stateValue': 'ALARM', 'stateReason': marker}})},
                        {'AlarmName': 'synthetic-backlog', 'HistoryItemType': 'Action', 'Timestamp': '2026-10-08T12:00:01Z',
                            'HistoryData': '{}', 'HistorySummary': 'Successfully executed action ' + op.outputs['MailOperatorAlertsTopic']}]}
                self.assertEqual(operation, 'describe-alarms')
                return {'MetricAlarms': [{'AlarmName': name, 'StateValue': 'OK', 'StateReason': 'Natural metric reevaluation'} for name in op.alarm_names.values()]}
            op.cli = cli
            self.assertEqual(op.qualify_alarm_routing(1)['status'], 'alarm_routing_qualified')
            self.assertEqual(op.qualify_alarm_routing(1)['status'], 'alarm_routing_already_qualified')
            self.assertEqual(calls, ['describe-alarm-history', 'describe-alarms'])

    def test_foreign_alarm_receipt_never_qualifies_or_changes_state(self):
        with tempfile.TemporaryDirectory() as directory:
            op = self.operation(directory, {'alarm_qualification': {'run': 'a' * 32, 'marker': 'foreign marker',
                'alarm_name': 'outside', 'complete': True}})
            op.subscription = lambda: True; op.alarm_names = {'MailFeedbackBacklog': 'synthetic-backlog'}
            with self.assertRaises(Failure): op.qualify_alarm_routing(1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path); parser.add_argument('--state-dir', type=Path)
    actions = parser.add_mutually_exclusive_group(required=True)
    for action in ('subscribe', 'status', 'test-notification', 'qualify-alarm-routing', 'prepare-production', 'submit-production', 'self-test'):
        actions.add_argument('--' + action, action='store_true')
    parser.add_argument('--retry-failed-review', action='store_true')
    parser.add_argument('--alarm-wait-seconds', type=int, default=180)
    args = parser.parse_args()
    if args.self_test:
        suite = unittest.defaultTestLoader.loadTestsFromTestCase(SelfTests)
        return 0 if unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful() else 1
    if not args.config or not args.state_dir: parser.error('--config and --state-dir are required')
    op = None
    try:
        op = Operations(args.config, args.state_dir); op.infrastructure()
        if args.subscribe: result = op.subscribe()
        elif args.test_notification: result = op.test_notification()
        elif args.qualify_alarm_routing: result = op.qualify_alarm_routing(args.alarm_wait_seconds)
        elif args.prepare_production: result = op.prepare_production()
        elif args.submit_production: result = op.submit_production(args.retry_failed_review)
        else: result = op.status()
        print(json.dumps(result)); return 0
    except Failure as error:
        code = str(error); print(json.dumps({'status': 'failed', 'code': code if re.fullmatch('[A-Z0-9_]+', code) else 'MAIL_OPERATION_FAILED'})); return 1
    except Exception:
        print(json.dumps({'status': 'failed', 'code': 'MAIL_OPERATION_FAILED'})); return 1
    finally:
        if op: op.close()


if __name__ == '__main__':
    sys_exit = main(); raise SystemExit(sys_exit)
