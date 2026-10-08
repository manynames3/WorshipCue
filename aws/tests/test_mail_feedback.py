import copy
import io
import json
import os
import sys
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'src'))
from auth import Authentication
from domain import APIError, Domain
import mail_feedback
from mail_feedback import Feedback, address_hash, suppressed
from store import Conflict, MemoryStore


class MailFeedbackTests(unittest.TestCase):
    def setUp(self):
        self.store = MemoryStore()
        self.feedback = Feedback(self.store, 'synthetic-topic', 'synthetic-mail', 'synthetic-source', 'synthetic-account', lambda: 100)

    def event(self, kind='Bounce', recipients=None):
        recipients = recipients or ['musician@example.test']
        value = {'eventType':kind, 'mail':{'messageId':'synthetic-message',
                 'sourceArn':'synthetic-source','sendingAccountId':'synthetic-account',
                 'destination':recipients, 'tags':{'ses:configuration-set':['synthetic-mail']},
                 'headers':[{'name':'private-header', 'value':'synthetic-code-secret'}]}}
        if kind == 'Bounce':
            value['bounce'] = {'bounceType':'Permanent', 'bouncedRecipients':[{'emailAddress':v} for v in recipients]}
        else:
            value['complaint'] = {'complaintFeedbackType':'abuse', 'complainedRecipients':[{'emailAddress':v} for v in recipients]}
        return {'Records':[{'EventSource':'aws:sns', 'Sns':{'TopicArn':'synthetic-topic', 'Message':json.dumps(value)}}]}

    def changed(self, event, alter):
        value = json.loads(event['Records'][0]['Sns']['Message'])
        alter(value)
        event['Records'][0]['Sns']['Message'] = json.dumps(value)
        return event

    def test_permanent_bounce_blocks_normalized_address_without_retaining_pii(self):
        result = self.feedback.handle(self.event())
        self.assertEqual(1, result['new_suppressions'])
        self.assertTrue(suppressed(self.store, ' Musician@Example.test '))
        self.assertFalse(suppressed(self.store, 'other@example.test'))
        stored = json.dumps(list(self.store.data.items()))
        for private in ('musician', 'example.test', 'synthetic-code-secret', 'private-header', 'synthetic-message'):
            self.assertNotIn(private, stored)
        self.assertEqual('permanent_bounce', next(iter(self.store.data.values()))['reason'])

    def test_complaint_and_duplicate_delivery_are_durable_and_idempotent(self):
        event = self.event('Complaint')
        self.assertEqual(1, self.feedback.handle(event)['new_suppressions'])
        self.assertEqual(0, self.feedback.handle(event)['new_suppressions'])
        self.assertEqual('complaint', next(iter(self.store.data.values()))['reason'])

    def test_complaint_upgrades_bounce_and_older_bounce_cannot_downgrade_it(self):
        self.feedback.handle(self.event())
        self.assertEqual(0,self.feedback.handle(self.event('Complaint'))['new_suppressions'])
        self.feedback.handle(self.event())
        self.assertEqual('complaint',next(iter(self.store.data.values()))['reason'])
        self.assertEqual(100,next(iter(self.store.data.values()))['suppressed_at_epoch'])

    def test_transient_bounce_not_spam_and_later_success_do_not_clear_suppression(self):
        transient = self.changed(self.event(), lambda v:v['bounce'].update(bounceType='Transient'))
        self.assertEqual(0, self.feedback.handle(transient)['new_suppressions'])
        not_spam = self.changed(self.event('Complaint'), lambda v:v['complaint'].update(complaintFeedbackType='not-spam'))
        self.assertEqual(0, self.feedback.handle(not_spam)['new_suppressions'])
        self.feedback.handle(self.event())
        self.feedback.handle(transient)
        self.feedback.handle(not_spam)
        self.assertTrue(suppressed(self.store, 'musician@example.test'))

    def test_multiple_recipients_validated_before_writes(self):
        self.assertEqual(2, self.feedback.handle(self.event(recipients=['one@example.test','two@example.test']))['new_suppressions'])
        other = MemoryStore(); processor = Feedback(other, 'synthetic-topic', 'synthetic-mail', 'synthetic-source', 'synthetic-account')
        bad = self.changed(self.event(), lambda v:v['bounce']['bouncedRecipients'].append({'emailAddress':'outside@example.test'}))
        with self.assertRaises(ValueError): processor.handle(bad)
        self.assertFalse(other.data)

    def test_wrong_topic_configuration_and_public_http_sources_are_denied(self):
        wrong = self.event(); wrong['Records'][0]['Sns']['TopicArn'] = 'outside-topic'
        bad_config = self.changed(self.event(),lambda v:v['mail']['tags'].update({'ses:configuration-set':['outside-mail']}))
        for event in (wrong, bad_config, {'body':'private'}, {'Records':[]}, {'Records':[{'EventSource':'aws:lambda'}]}):
            with self.assertRaises(ValueError): self.feedback.handle(event)
        self.assertFalse(self.store.data)

    def test_exact_ses_destination_probe_is_accepted_only_on_scoped_topic(self):
        event = self.event()
        event['Records'][0]['Sns']['Message'] = mail_feedback.SES_TOPIC_VALIDATION
        self.assertEqual({'processed_records':1, 'new_suppressions':0}, self.feedback.handle(event))
        self.assertFalse(self.store.data)
        for topic, source, raw in (
            ('outside-topic', 'aws:sns', mail_feedback.SES_TOPIC_VALIDATION),
            ('synthetic-topic', 'aws:lambda', mail_feedback.SES_TOPIC_VALIDATION),
            ('synthetic-topic', 'aws:sns', mail_feedback.SES_TOPIC_VALIDATION + '\n'),
            ('synthetic-topic', 'aws:sns', 'Successfully validated another destination.'),
        ):
            event['Records'][0] = {'EventSource':source, 'Sns':{'TopicArn':topic, 'Message':raw}}
            with self.assertRaises(ValueError):
                self.feedback.handle(event)
        self.assertFalse(self.store.data)

    def test_source_identity_and_sending_account_must_match(self):
        for key in ('sourceArn','sendingAccountId'):
            event=self.changed(self.event(),lambda v:v['mail'].update({key:'outside'}))
            with self.assertRaises(ValueError):self.feedback.handle(event)
        self.assertFalse(self.store.data)

    def test_invalid_login_addresses_are_input_errors_before_mail_or_account_writes(self):
        auth=Authentication(None,'us-east-1_SYNTHETIC','synthetic-client',Domain(self.store),True)
        for address in ('@example.test','musician@','bad email@example.test'):
            with self.assertRaises(APIError) as caught:auth.otp({'email':address})
            self.assertEqual('INVALID_INPUT',caught.exception.code)
        self.assertFalse(self.store.data)

    def test_infrastructure_scopes_feedback_and_both_delivery_failure_paths(self):
        import importlib.util
        spec=importlib.util.spec_from_file_location('mail_template',Path(__file__).resolve().parents[1]/'generate_template.py')
        module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
        resources=module.resources
        config=resources['UserPool']['Properties']['EmailConfiguration']['Fn::If'][1]
        self.assertEqual({'Ref':'MailConfigurationSet'},config['ConfigurationSet'])
        self.assertIn('MailFeedbackDestination',resources['UserPool']['DependsOn'])
        function=resources['MailFeedbackFunction']['Properties']
        queue={'Fn::GetAtt':['MailFeedbackDeadLetters','Arn']}
        self.assertEqual(queue,function['DeadLetterConfig']['TargetArn'])
        self.assertEqual(queue,resources['MailFeedbackSubscription']['Properties']['RedrivePolicy']['deadLetterTargetArn'])
        self.assertTrue(resources['MailFeedbackDeadLetters']['Properties']['SqsManagedSseEnabled'])
        self.assertEqual(1209600,resources['MailFeedbackDeadLetters']['Properties']['MessageRetentionPeriod'])
        self.assertEqual({'Ref':'MailFeedbackTopic'},resources['MailFeedbackPermission']['Properties']['SourceArn'])
        self.assertEqual({'Ref':'AWS::AccountId'},resources['MailFeedbackPermission']['Properties']['SourceAccount'])
        statements=resources['MailFeedbackRole']['Properties']['Policies'][0]['PolicyDocument']['Statement']
        self.assertEqual(['dynamodb:GetItem','dynamodb:PutItem'],statements[1]['Action'])
        self.assertEqual(['MAIL#*'],statements[1]['Condition']['ForAllValues:StringLike']['dynamodb:LeadingKeys'])
        self.assertEqual('ApproximateNumberOfMessagesVisible',resources['MailFeedbackBacklog']['Properties']['MetricName'])
        self.assertEqual([{'Ref':'MailOperatorAlertsTopic'}],resources['MailFeedbackBacklog']['Properties']['AlarmActions'])
        statements=resources['MailOperatorAlertsPolicy']['Properties']['PolicyDocument']['Statement']
        self.assertEqual(len(statements),len({statement['Sid'] for statement in statements}))
        self.assertEqual({'Service':'cloudwatch.amazonaws.com'},statements[0]['Principal'])
        self.assertEqual({'Ref':'AWS::AccountId'},statements[0]['Condition']['StringEquals']['aws:SourceAccount'])
        allowed=statements[0]['Condition']['ArnEquals']['aws:SourceArn']
        self.assertEqual(set(module.operator_alarms),{value['Fn::Sub'][1]['Alarm']['Ref'] for value in allowed})

    def test_invalid_json_shapes_bounds_and_addresses_are_denied(self):
        for address in ('broken', '@domain.test','person@','person @example.test', None, 'a'*255+'@x'):
            with self.assertRaises(ValueError): address_hash(address)
        for raw in ('null','[]','{"bad":NaN}', 'x'*262145):
            event=self.event();event['Records'][0]['Sns']['Message']=raw
            with self.assertRaises(ValueError):self.feedback.handle(event)

    def test_conflicts_retry_and_provider_failure_reaches_retry_boundary(self):
        store=self.store; original=store.transact; attempts=[]
        def write(value):
            attempts.append(value)
            if len(attempts)==1:raise Conflict()
            return original(value)
        with patch.object(store,'transact',side_effect=write):
            self.assertEqual(1,self.feedback.handle(self.event())['new_suppressions'])
        self.assertEqual(2,len(attempts))
        with patch.object(store,'get',side_effect=RuntimeError('private-provider-details')):
            with self.assertRaises(RuntimeError):self.feedback.handle(self.event())

    def test_suppressed_address_never_reaches_cognito(self):
        self.feedback.handle(self.event())
        class Cognito:
            def admin_create_user(self,**kwargs):raise AssertionError('Cognito must not be called')
        auth=Authentication(Cognito(),'us-east-1_SYNTHETIC','synthetic-client',Domain(self.store),True)
        with self.assertRaises(APIError) as error:auth.otp({'email':'musician@example.test'})
        self.assertEqual('EMAIL_DELIVERY_UNAVAILABLE',error.exception.code)

    def test_lambda_logs_only_counts_and_sanitizes_errors(self):
        environment={'TABLE_NAME':'synthetic-table','FEEDBACK_TOPIC':'synthetic-topic','MAIL_CONFIGURATION_SET':'synthetic-mail','MAIL_SOURCE_ARN':'synthetic-source','MAIL_ACCOUNT':'synthetic-account'}
        output=io.StringIO()
        with patch.dict(os.environ,environment),patch.object(mail_feedback,'DynamoStore',return_value=self.store),redirect_stdout(output):
            mail_feedback.lambda_handler(self.event(),None)
        self.assertEqual({'event':'mail_feedback_processed','processed_records':1,'new_suppressions':1},json.loads(output.getvalue()))
        output=io.StringIO()
        with patch.dict(os.environ,environment),patch.object(mail_feedback,'DynamoStore',side_effect=RuntimeError('private-address@example.test')),redirect_stdout(output):
            with self.assertRaisesRegex(RuntimeError,'^MAIL_FEEDBACK_FAILED$'):mail_feedback.lambda_handler(self.event(),None)
        self.assertEqual({'event':'mail_feedback_failed'},json.loads(output.getvalue()))


if __name__=='__main__': unittest.main()
