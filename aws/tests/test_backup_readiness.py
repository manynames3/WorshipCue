import copy
import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from mail_operations import ALARMS, MAIL_ALARMS, quiet_alarm_start, validate_alarm_configuration, validate_operator_policy
from smoke import Failure


class BackupReadinessTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.resources = json.loads((Path(__file__).resolve().parents[1] / 'template.json').read_text())['Resources']

    def test_backup_errors_and_stale_completion_use_same_exact_operator_topic(self):
        resources = self.resources
        errors = resources['BackupErrors']['Properties']
        heartbeat = resources['BackupStaleCompletion']['Properties']
        for value in (errors, heartbeat):
            self.assertEqual([{'Ref':'MailOperatorAlertsTopic'}], value['AlarmActions'])
            self.assertEqual([{'Name':'FunctionName','Value':{'Ref':'BackupFunction'}}], value['Dimensions'])
        self.assertEqual(('AWS/Lambda', 'Errors', 'Sum', 60, 1, 1), tuple(errors[k] for k in ('Namespace','MetricName','Statistic','Period','EvaluationPeriods','Threshold')))
        self.assertEqual('notBreaching', errors['TreatMissingData'])
        self.assertEqual(('WorshipCue/Backup', 'Completed', 'Sum', 3600, 48, 48), tuple(heartbeat[k] for k in ('Namespace','MetricName','Statistic','Period','EvaluationPeriods','DatapointsToAlarm')))
        self.assertEqual('LessThanThreshold', heartbeat['ComparisonOperator']); self.assertEqual('breaching', heartbeat['TreatMissingData'])
        policy = resources['MailOperatorAlertsPolicy']['Properties']['PolicyDocument']['Statement']
        allowed = policy[0]['Condition']['ArnEquals']['aws:SourceArn']
        self.assertEqual(set(ALARMS), {v['Fn::Sub'][1]['Alarm']['Ref'] for v in allowed})
        self.assertEqual(len(ALARMS), len(allowed)); self.assertEqual(4, len(MAIL_ALARMS)); self.assertEqual(6, len(ALARMS))

    def test_backup_role_has_namespace_scoped_heartbeat_and_no_delete_permissions(self):
        statements = self.resources['BackupRole']['Properties']['Policies'][0]['PolicyDocument']['Statement']
        metric = next(v for v in statements if v['Action'] == 'cloudwatch:PutMetricData')
        self.assertEqual('*', metric['Resource'])
        self.assertEqual({'StringEquals':{'cloudwatch:namespace':'WorshipCue/Backup'}}, metric['Condition'])
        create = next(v for v in statements if v['Action'] == 'dynamodb:CreateBackup')
        self.assertEqual({'Fn::GetAtt':['Table','Arn']}, create['Resource'])
        listing = next(v for v in statements if v['Action'] == 'dynamodb:ListBackups')
        self.assertEqual('*', listing['Resource'])
        actions = [a for v in statements for a in ([v['Action']] if isinstance(v['Action'], str) else v['Action'])]
        self.assertTrue(all('delete' not in a.lower() for a in actions))
        rule = self.resources['BackupSchedule']['Properties']
        self.assertEqual('rate(5 minutes)', rule['ScheduleExpression']); self.assertEqual('ENABLED', rule['State'])
        self.assertEqual({'Fn::GetAtt':['BackupFunction','Arn']}, rule['Targets'][0]['Arn'])

    def live_configuration(self):
        topic = 'synthetic-topic'; names = {v:'synthetic-' + v for v in ALARMS}
        values = []
        for name in ALARMS:
            row = {'AlarmName':names[name], 'AlarmActions':[topic], 'ActionsEnabled':True}
            if name.startswith('Backup'):
                row.update({'Namespace':'AWS/Lambda','MetricName':'Errors','Statistic':'Sum','Period':60,
                    'EvaluationPeriods':1,'DatapointsToAlarm':1,'Threshold':1,'ComparisonOperator':'GreaterThanOrEqualToThreshold',
                    'TreatMissingData':'notBreaching','Dimensions':[{'Name':'FunctionName','Value':'synthetic-backup'}]})
            if name == 'BackupStaleCompletion':
                row.update(Namespace='WorshipCue/Backup', MetricName='Completed', Period=3600,
                    EvaluationPeriods=48, DatapointsToAlarm=48, ComparisonOperator='LessThanThreshold', TreatMissingData='breaching')
            values.append(row)
        return topic, names, values

    def test_operator_validation_rejects_missing_foreign_or_weakened_backup_alarm(self):
        topic, names, rows = self.live_configuration()
        validate_alarm_configuration(rows, names, topic, 'synthetic-backup')
        with self.assertRaises(Failure): validate_alarm_configuration(rows[:-1], names, topic, 'synthetic-backup')
        for name, field, value in [('BackupErrors','Dimensions',[{'Name':'FunctionName','Value':'foreign'}]),
                ('BackupErrors','AlarmActions',['foreign-topic']), ('BackupStaleCompletion','TreatMissingData','notBreaching'),
                ('BackupStaleCompletion','EvaluationPeriods',49), ('BackupErrors','AlarmName','foreign-alarm')]:
            changed = copy.deepcopy(rows); next(v for v in changed if v['AlarmName'] == names[name])[field] = value
            with self.assertRaises(Failure): validate_alarm_configuration(changed, names, topic, 'synthetic-backup')

    def test_operator_policy_allows_only_six_exact_same_account_alarm_sources(self):
        topic, names, _ = self.live_configuration(); account = '000000000000'
        policy = {'Statement':[
            {'Sid':'ScopedCloudWatchAlarms','Effect':'Allow','Principal':{'Service':'cloudwatch.amazonaws.com'},'Action':'sns:Publish','Resource':topic,
             'Condition':{'StringEquals':{'aws:SourceAccount':account},'ArnEquals':{'aws:SourceArn':[
                 'arn:aws:cloudwatch:us-east-1:' + account + ':alarm:' + n for n in names.values()]}}},
            {'Sid':'RequireTLS','Effect':'Deny','Principal':'*','Action':'sns:Publish','Resource':topic,
             'Condition':{'Bool':{'aws:SecureTransport':'false'}}}]}
        validate_operator_policy(policy, topic, account, names)
        changed = copy.deepcopy(policy); changed['Statement'].append({'Effect':'Allow','Principal':'*','Action':'sns:Publish','Resource':topic})
        with self.assertRaises(Failure): validate_operator_policy(changed, topic, account, names)
        for sources in (policy['Statement'][0]['Condition']['ArnEquals']['aws:SourceArn'][:-1], ['*']):
            changed = copy.deepcopy(policy); changed['Statement'][0]['Condition']['ArnEquals']['aws:SourceArn'] = sources
            with self.assertRaises(Failure): validate_operator_policy(changed, topic, account, names)

    def test_mail_routing_test_refuses_existing_backup_incident(self):
        quiet = [{'StateValue':'OK'}] * len(ALARMS)
        for index in (4, 5):
            rows = copy.deepcopy(quiet); rows[index]['StateValue'] = 'ALARM'
            with self.assertRaises(Failure): quiet_alarm_start(rows, {'visible':0,'in_flight':0,'delayed':0})


if __name__ == '__main__':
    unittest.main()
