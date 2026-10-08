#!/usr/bin/env python3
"""Reproducible serverless CloudFormation; no CDK/SAM production dependency."""
import json
from pathlib import Path

ref = lambda name: {'Ref':name}
sub = lambda value: {'Fn::Sub':value}
att = lambda name, attribute: {'Fn::GetAtt':[name,attribute]}
choose = lambda yes,no: {'Fn::If':['HasSender',yes,no]}
resources = {}


def resource(name,kind,properties,retain=False,depends=None):
    value = {'Type':kind,'Properties':properties}
    if retain:value.update(DeletionPolicy='Retain',UpdateReplacePolicy='Retain')
    if depends:value['DependsOn']=depends
    resources[name]=value


resource('Table','AWS::DynamoDB::Table',{
    'BillingMode':'PAY_PER_REQUEST',
    'AttributeDefinitions':[{'AttributeName':k,'AttributeType':'S'} for k in ['PK','SK']],
    'KeySchema':[{'AttributeName':'PK','KeyType':'HASH'},{'AttributeName':'SK','KeyType':'RANGE'}],
    'SSESpecification':{'SSEEnabled':True},'PointInTimeRecoverySpecification':{'PointInTimeRecoveryEnabled':True},
    'TimeToLiveSpecification':{'AttributeName':'expires_at_epoch','Enabled':True},
    'Tags':[{'Key':'Application','Value':'WorshipCue'},{'Key':'Environment','Value':'Development'}]},True)
for name in ['Assets','Backups']:
    resource(name,'AWS::S3::Bucket',{
        'PublicAccessBlockConfiguration':{k:True for k in ['BlockPublicAcls','IgnorePublicAcls','BlockPublicPolicy','RestrictPublicBuckets']},
        'OwnershipControls':{'Rules':[{'ObjectOwnership':'BucketOwnerEnforced'}]},
        'VersioningConfiguration':{'Status':'Enabled'},
        'BucketEncryption':{'ServerSideEncryptionConfiguration':[{'ServerSideEncryptionByDefault':{'SSEAlgorithm':'AES256'}}]},
        'LifecycleConfiguration':{'Rules':[{'Id':'AbortIncompleteUploads','Status':'Enabled','AbortIncompleteMultipartUpload':{'DaysAfterInitiation':1}}]},
        'Tags':[{'Key':'Application','Value':'WorshipCue'},{'Key':'Environment','Value':'Development'}]},True)
    statements=[{'Sid':'HTTPSOnly','Effect':'Deny','Principal':'*','Action':'s3:*',
        'Resource':[att(name,'Arn'),sub('${'+name+'.Arn}/*')],'Condition':{'Bool':{'aws:SecureTransport':'false'}}}]
    if name=='Assets':statements.append({'Sid':'RequireImmutableCreates','Effect':'Deny','Principal':'*',
        'Action':'s3:PutObject','Resource':sub('${Assets.Arn}/*'),
        'Condition':{'Null':{'s3:if-none-match':'true'},'Bool':{'s3:ObjectCreationOperation':'true'}}})
    resource(name+'Policy','AWS::S3::BucketPolicy',{'Bucket':ref(name),'PolicyDocument':{'Version':'2012-10-17','Statement':statements}})

resource('MailConfigurationSet','AWS::SES::ConfigurationSet',{'Name':sub('${AWS::StackName}-mail')})
resource('MailFeedbackTopic','AWS::SNS::Topic',{'TopicName':sub('${AWS::StackName}-mail-feedback')})
resource('MailFeedbackTopicPolicy','AWS::SNS::TopicPolicy',{
    'Topics':[ref('MailFeedbackTopic')], 'PolicyDocument':{'Version':'2012-10-17','Statement':[
        {'Effect':'Allow','Principal':{'Service':'ses.amazonaws.com'},'Action':'sns:Publish','Resource':ref('MailFeedbackTopic'),
         'Condition':{'StringEquals':{'AWS:SourceAccount':ref('AWS::AccountId'),
            'AWS:SourceArn':sub('arn:${AWS::Partition}:ses:${AWS::Region}:${AWS::AccountId}:configuration-set/${MailConfigurationSet}')}}}]}})
resource('MailFeedbackDeadLetters','AWS::SQS::Queue',{
    'QueueName':sub('${AWS::StackName}-mail-failures'),'SqsManagedSseEnabled':True,'MessageRetentionPeriod':1209600})
resource('MailFeedbackQueuePolicy','AWS::SQS::QueuePolicy',{'Queues':[ref('MailFeedbackDeadLetters')],
    'PolicyDocument':{'Version':'2012-10-17','Statement':[
        {'Effect':'Allow','Principal':{'Service':'sns.amazonaws.com'},'Action':'sqs:SendMessage',
         'Resource':att('MailFeedbackDeadLetters','Arn'),'Condition':{'ArnEquals':{'aws:SourceArn':ref('MailFeedbackTopic')},
             'StringEquals':{'aws:SourceAccount':ref('AWS::AccountId')}}},
        {'Effect':'Deny','Principal':'*','Action':'sqs:*','Resource':att('MailFeedbackDeadLetters','Arn'),
         'Condition':{'Bool':{'aws:SecureTransport':'false'}}}]}})
resource('MailFeedbackLogGroup','AWS::Logs::LogGroup',{
    'LogGroupName':sub('/aws/lambda/${AWS::StackName}-mail-feedback'),'RetentionInDays':14})
resource('MailFeedbackRole','AWS::IAM::Role',{
    'AssumeRolePolicyDocument':{'Version':'2012-10-17','Statement':[{'Effect':'Allow',
        'Principal':{'Service':'lambda.amazonaws.com'},'Action':'sts:AssumeRole'}]},
    'Policies':[{'PolicyName':'ScopedMailFeedback','PolicyDocument':{'Version':'2012-10-17','Statement':[
        {'Effect':'Allow','Action':['logs:CreateLogStream','logs:PutLogEvents'],'Resource':att('MailFeedbackLogGroup','Arn')},
        {'Effect':'Allow','Action':['dynamodb:GetItem','dynamodb:PutItem'],'Resource':att('Table','Arn'),
         'Condition':{'ForAllValues:StringLike':{'dynamodb:LeadingKeys':['MAIL#*']}}},
        {'Effect':'Allow','Action':'sqs:SendMessage','Resource':att('MailFeedbackDeadLetters','Arn')}]}}]})
resource('MailFeedbackFunction','AWS::Lambda::Function',{
    'FunctionName':sub('${AWS::StackName}-mail-feedback'),'Runtime':'python3.13','Handler':'mail_feedback.lambda_handler',
    'Architectures':['arm64'],'Role':att('MailFeedbackRole','Arn'),'Timeout':30,'MemorySize':128,
    'Code':{'S3Bucket':ref('CodeBucket'),'S3Key':ref('CodeKey')},
    'DeadLetterConfig':{'TargetArn':att('MailFeedbackDeadLetters','Arn')},
    'Environment':{'Variables':{'TABLE_NAME':ref('Table'),'FEEDBACK_TOPIC':ref('MailFeedbackTopic'),
        'MAIL_CONFIGURATION_SET':ref('MailConfigurationSet'),'MAIL_SOURCE_ARN':choose(ref('SenderIdentityArn'),'unconfigured'),
        'MAIL_ACCOUNT':ref('AWS::AccountId')}},
    'Tags':[{'Key':'Application','Value':'WorshipCue'},{'Key':'Environment','Value':'Development'}]},depends=['MailFeedbackLogGroup'])
resource('MailFeedbackPermission','AWS::Lambda::Permission',{'Action':'lambda:InvokeFunction',
    'FunctionName':ref('MailFeedbackFunction'),'Principal':'sns.amazonaws.com','SourceArn':ref('MailFeedbackTopic'),
    'SourceAccount':ref('AWS::AccountId')})
resource('MailFeedbackSubscription','AWS::SNS::Subscription',{'TopicArn':ref('MailFeedbackTopic'),'Protocol':'lambda',
    'Endpoint':att('MailFeedbackFunction','Arn'),'RedrivePolicy':{'deadLetterTargetArn':att('MailFeedbackDeadLetters','Arn')}},
    depends=['MailFeedbackPermission','MailFeedbackQueuePolicy'])
resource('MailFeedbackDestination','AWS::SES::ConfigurationSetEventDestination',{
    'ConfigurationSetName':ref('MailConfigurationSet'),'EventDestination':{'Name':'Feedback','Enabled':True,
        'MatchingEventTypes':['BOUNCE','COMPLAINT'],'SnsDestination':{'TopicARN':ref('MailFeedbackTopic')}}},
    depends=['MailFeedbackTopicPolicy','MailFeedbackSubscription'])
resource('MailOperatorAlertsTopic','AWS::SNS::Topic',{
    'TopicName':sub('${AWS::StackName}-mail-operator-alerts'),
    'Tags':[{'Key':'Application','Value':'WorshipCue'},{'Key':'Environment','Value':'Development'}]})
mail_alarms = ['MailFeedbackErrors','MailFeedbackDeadLetterErrors','MailFeedbackDeliveryFailures','MailFeedbackBacklog']
operator_alarms = mail_alarms + ['BackupErrors','BackupStaleCompletion']
resource('MailOperatorAlertsPolicy','AWS::SNS::TopicPolicy',{
    'Topics':[ref('MailOperatorAlertsTopic')], 'PolicyDocument':{'Version':'2012-10-17','Statement':[
        {'Sid':'ScopedCloudWatchAlarms','Effect':'Allow','Principal':{'Service':'cloudwatch.amazonaws.com'},'Action':'sns:Publish',
         'Resource':ref('MailOperatorAlertsTopic'),'Condition':{
             'StringEquals':{'aws:SourceAccount':ref('AWS::AccountId')},
             'ArnEquals':{'aws:SourceArn':[{'Fn::Sub':[
                 'arn:${AWS::Partition}:cloudwatch:${AWS::Region}:${AWS::AccountId}:alarm:${Alarm}',
                 {'Alarm':ref(name)}]} for name in operator_alarms]}}},
        {'Sid':'RequireTLS','Effect':'Deny','Principal':'*','Action':'sns:Publish','Resource':ref('MailOperatorAlertsTopic'),
         'Condition':{'Bool':{'aws:SecureTransport':'false'}}}]}})
for name,namespace,metric,dimension,statistic in [
    ('MailFeedbackErrors','AWS/Lambda','Errors',{'Name':'FunctionName','Value':ref('MailFeedbackFunction')},'Sum'),
    ('MailFeedbackDeadLetterErrors','AWS/Lambda','DeadLetterErrors',{'Name':'FunctionName','Value':ref('MailFeedbackFunction')},'Sum'),
    ('MailFeedbackDeliveryFailures','AWS/SNS','NumberOfNotificationsFailed',{'Name':'TopicName','Value':att('MailFeedbackTopic','TopicName')},'Sum'),
    ('MailFeedbackBacklog','AWS/SQS','ApproximateNumberOfMessagesVisible',{'Name':'QueueName','Value':att('MailFeedbackDeadLetters','QueueName')},'Maximum')]:
    resource(name,'AWS::CloudWatch::Alarm',{'AlarmDescription':'WorshipCue mail feedback needs operator attention; review the restricted recovery queue.',
        'AlarmActions':[ref('MailOperatorAlertsTopic')],
        'Namespace':namespace,'MetricName':metric,'Dimensions':[dimension],'Statistic':statistic,'Period':60,
        'EvaluationPeriods':1,'Threshold':1,'ComparisonOperator':'GreaterThanOrEqualToThreshold','TreatMissingData':'notBreaching'})

resource('UserPool','AWS::Cognito::UserPool',{
    'UserPoolName':sub('${AWS::StackName}'),'UserPoolTier':'ESSENTIALS',
    'UsernameConfiguration':{'CaseSensitive':False},'AdminCreateUserConfig':{'AllowAdminCreateUserOnly':True},
    'MfaConfiguration':'OFF',
    'Policies':{'PasswordPolicy':{'MinimumLength':24,'RequireLowercase':True,'RequireUppercase':True,'RequireNumbers':True,'RequireSymbols':True},
        'SignInPolicy':{'AllowedFirstAuthFactors':choose(['PASSWORD','EMAIL_OTP'],['PASSWORD'])}},
    'EmailConfiguration':choose({'EmailSendingAccount':'DEVELOPER','SourceArn':ref('SenderIdentityArn'),'From':ref('SenderAddress'),
                                'ConfigurationSet':ref('MailConfigurationSet')},
                                {'EmailSendingAccount':'COGNITO_DEFAULT'}),
    'AccountRecoverySetting':{'RecoveryMechanisms':[{'Name':'admin_only','Priority':1}]},
    'Schema':[{'Name':'email','AttributeDataType':'String','Mutable':True,'Required':False},
        {'Name':'is_guest','AttributeDataType':'String','Mutable':False,'Required':False,'StringAttributeConstraints':{'MinLength':'4','MaxLength':'5'}}],
    'UserPoolTags':{'Application':'WorshipCue','Environment':'Development'}},True,depends=['MailFeedbackDestination'])
resource('Client','AWS::Cognito::UserPoolClient',{
    'UserPoolId':ref('UserPool'),'ClientName':sub('${AWS::StackName}-ipad'),'GenerateSecret':False,
    'ExplicitAuthFlows':['ALLOW_USER_AUTH','ALLOW_ADMIN_USER_PASSWORD_AUTH','ALLOW_REFRESH_TOKEN_AUTH'],
    'PreventUserExistenceErrors':'ENABLED','EnableTokenRevocation':True,
    'RefreshTokenRotation':{'Feature':'DISABLED'},'AuthSessionValidity':10,
    'AccessTokenValidity':1,'IdTokenValidity':1,'RefreshTokenValidity':30,
    'TokenValidityUnits':{'AccessToken':'hours','IdToken':'hours','RefreshToken':'days'},
    'ReadAttributes':['email','email_verified','custom:is_guest'],'WriteAttributes':['email']})
resource('HttpApi','AWS::ApiGatewayV2::Api',{'Name':sub('${AWS::StackName}-http'),'ProtocolType':'HTTP'})
resource('SocketApi','AWS::ApiGatewayV2::Api',{'Name':sub('${AWS::StackName}-realtime'),'ProtocolType':'WEBSOCKET','RouteSelectionExpression':'$request.body.action'})
resource('LogGroup','AWS::Logs::LogGroup',{'LogGroupName':sub('/aws/lambda/${AWS::StackName}-backend'),'RetentionInDays':14})
resource('Role','AWS::IAM::Role',{
    'AssumeRolePolicyDocument':{'Version':'2012-10-17','Statement':[{'Effect':'Allow','Principal':{'Service':'lambda.amazonaws.com'},'Action':'sts:AssumeRole'}]},
    'Policies':[{'PolicyName':'Workspace','PolicyDocument':{'Version':'2012-10-17','Statement':[
        {'Effect':'Allow','Action':['logs:CreateLogStream','logs:PutLogEvents'],'Resource':att('LogGroup','Arn')},
        {'Effect':'Allow','Action':['dynamodb:GetItem','dynamodb:PutItem','dynamodb:DeleteItem','dynamodb:Query','dynamodb:ConditionCheckItem'],'Resource':att('Table','Arn')},
        {'Effect':'Allow','Action':['s3:GetObject','s3:GetObjectVersion','s3:PutObject'],'Resource':sub('${Assets.Arn}/*')},
        {'Effect':'Allow','Action':['cognito-idp:AdminCreateUser','cognito-idp:AdminSetUserPassword','cognito-idp:AdminInitiateAuth','cognito-idp:AdminDeleteUser'],'Resource':att('UserPool','Arn')},
        {'Effect':'Allow','Action':'execute-api:ManageConnections','Resource':sub('arn:${AWS::Partition}:execute-api:${AWS::Region}:${AWS::AccountId}:${SocketApi}/development/POST/@connections/*')}
    ]}}]})
resource('Backend','AWS::Lambda::Function',{
    'FunctionName':sub('${AWS::StackName}-backend'),'Runtime':'python3.13','Handler':'handler.lambda_handler',
    'Architectures':['arm64'],'Role':att('Role','Arn'),'Timeout':60,'MemorySize':1024,
    'Code':{'S3Bucket':ref('CodeBucket'),'S3Key':ref('CodeKey')},
    'Environment':{'Variables':{'TABLE_NAME':ref('Table'),'ASSET_BUCKET':ref('Assets'),
        'USER_POOL_ID':ref('UserPool'),'CLIENT_ID':ref('Client'),'EMAIL_READY':choose('true','false'),
        'WEBSOCKET_MANAGEMENT_URL':sub('https://${SocketApi}.execute-api.${AWS::Region}.${AWS::URLSuffix}/development')}},
    'Tags':[{'Key':'Application','Value':'WorshipCue'},{'Key':'Environment','Value':'Development'}]},depends=['LogGroup'])
resource('BackupLogGroup','AWS::Logs::LogGroup',{'LogGroupName':sub('/aws/lambda/${AWS::StackName}-backup'),'RetentionInDays':14})
resource('BackupRole','AWS::IAM::Role',{
    'AssumeRolePolicyDocument':{'Version':'2012-10-17','Statement':[{'Effect':'Allow','Principal':{'Service':'lambda.amazonaws.com'},'Action':'sts:AssumeRole'}]},
    'Policies':[{'PolicyName':'BackupOnly','PolicyDocument':{'Version':'2012-10-17','Statement':[
        {'Effect':'Allow','Action':['logs:CreateLogStream','logs:PutLogEvents'],'Resource':att('BackupLogGroup','Arn')},
        {'Effect':'Allow','Action':'dynamodb:CreateBackup','Resource':att('Table','Arn')},
        {'Effect':'Allow','Action':'dynamodb:DescribeBackup','Resource':sub('${Table.Arn}/backup/*')},
        {'Effect':'Allow','Action':'dynamodb:ListBackups','Resource':'*'},
        {'Effect':'Allow','Action':'cloudwatch:PutMetricData','Resource':'*',
         'Condition':{'StringEquals':{'cloudwatch:namespace':'WorshipCue/Backup'}}},
        {'Effect':'Allow','Action':['s3:ListBucket','s3:GetBucketVersioning'],'Resource':[att('Assets','Arn'),att('Backups','Arn')]},
        {'Effect':'Allow','Action':['s3:GetObject','s3:GetObjectVersion'],'Resource':[sub('${Assets.Arn}/*'),sub('${Backups.Arn}/*')]},
        {'Effect':'Allow','Action':'s3:PutObject','Resource':sub('${Backups.Arn}/*')}
    ]}}]})
resource('BackupFunction','AWS::Lambda::Function',{
    'FunctionName':sub('${AWS::StackName}-backup'),'Runtime':'python3.13','Handler':'backup.lambda_handler',
    'Architectures':['arm64'],'Role':att('BackupRole','Arn'),'Timeout':900,'MemorySize':1024,
    'Code':{'S3Bucket':ref('CodeBucket'),'S3Key':ref('CodeKey')},
    'Environment':{'Variables':{'TABLE_NAME':ref('Table'),'ASSET_BUCKET':ref('Assets'),'BACKUP_BUCKET':ref('Backups')}},
    'Tags':[{'Key':'Application','Value':'WorshipCue'},{'Key':'Environment','Value':'Development'}]},depends=['BackupLogGroup'])
resource('BackupErrors','AWS::CloudWatch::Alarm',{
    'AlarmDescription':'WorshipCue backup failed or timed out; verify the latest complete manifest before retrying. No files are deleted.',
    'AlarmActions':[ref('MailOperatorAlertsTopic')],
    'Namespace':'AWS/Lambda','MetricName':'Errors',
    'Dimensions':[{'Name':'FunctionName','Value':ref('BackupFunction')}],
    'Statistic':'Sum','Period':60,'EvaluationPeriods':1,'DatapointsToAlarm':1,
    'Threshold':1,'ComparisonOperator':'GreaterThanOrEqualToThreshold','TreatMissingData':'notBreaching'})
resource('BackupStaleCompletion','AWS::CloudWatch::Alarm',{
    'AlarmDescription':'WorshipCue has no verified complete backup in the expected 48-hour window; check schedule and saved job without deleting recovery data.',
    'AlarmActions':[ref('MailOperatorAlertsTopic')],
    'Namespace':'WorshipCue/Backup','MetricName':'Completed',
    'Dimensions':[{'Name':'FunctionName','Value':ref('BackupFunction')}],
    'Statistic':'Sum','Period':3600,'EvaluationPeriods':48,'DatapointsToAlarm':48,
    'Threshold':1,'ComparisonOperator':'LessThanThreshold','TreatMissingData':'breaching'})
resource('BackupSchedule','AWS::Events::Rule',{'Description':'Resume a private backup job; start at most one daily job after 04:00 UTC',
    'ScheduleExpression':'rate(5 minutes)','State':'ENABLED','Targets':[{'Arn':att('BackupFunction','Arn'),'Id':'DailyBackup',
        'RetryPolicy':{'MaximumEventAgeInSeconds':3600,'MaximumRetryAttempts':2}}]})
resource('BackupSchedulePermission','AWS::Lambda::Permission',{'Action':'lambda:InvokeFunction','FunctionName':ref('BackupFunction'),
    'Principal':'events.amazonaws.com','SourceArn':att('BackupSchedule','Arn')})
resource('HttpIntegration','AWS::ApiGatewayV2::Integration',{'ApiId':ref('HttpApi'),'IntegrationType':'AWS_PROXY',
    'IntegrationUri':att('Backend','Arn'),'PayloadFormatVersion':'2.0','TimeoutInMillis':30000})
resource('SocketIntegration','AWS::ApiGatewayV2::Integration',{'ApiId':ref('SocketApi'),'IntegrationType':'AWS_PROXY',
    'IntegrationMethod':'POST','IntegrationUri':sub('arn:${AWS::Partition}:apigateway:${AWS::Region}:lambda:path/2015-03-31/functions/${Backend.Arn}/invocations')})
resource('Authorizer','AWS::ApiGatewayV2::Authorizer',{'ApiId':ref('HttpApi'),'AuthorizerType':'JWT','Name':'CognitoAccess',
    'IdentitySource':['$request.header.Authorization'],
    'JwtConfiguration':{'Audience':[ref('Client')],'Issuer':sub('https://cognito-idp.${AWS::Region}.${AWS::URLSuffix}/${UserPool}')}})
for name,key,authorized in [('Health','GET /health',False),('Auth','POST /auth/{proxy+}',False),
                            ('Rest','ANY /rest/{proxy+}',True),('Functions','POST /functions/{proxy+}',True)]:
    props={'ApiId':ref('HttpApi'),'RouteKey':key,'Target':sub('integrations/${HttpIntegration}'),'AuthorizationType':'JWT' if authorized else 'NONE'}
    if authorized:props.update(AuthorizerId=ref('Authorizer'),AuthorizationScopes=['aws.cognito.signin.user.admin'])
    resource(name+'Route','AWS::ApiGatewayV2::Route',props)
for name,key in [('Connect','$connect'),('Disconnect','$disconnect'),('Default','$default')]:
    resource(name+'Route','AWS::ApiGatewayV2::Route',{'ApiId':ref('SocketApi'),'RouteKey':key,
        'Target':sub('integrations/${SocketIntegration}'),'AuthorizationType':'NONE'})
resource('HttpStage','AWS::ApiGatewayV2::Stage',{'ApiId':ref('HttpApi'),'StageName':'$default','AutoDeploy':True,
    'DefaultRouteSettings':{'ThrottlingBurstLimit':30,'ThrottlingRateLimit':10}})
resource('SocketStage','AWS::ApiGatewayV2::Stage',{'ApiId':ref('SocketApi'),'StageName':'development','AutoDeploy':True,
    'DefaultRouteSettings':{'DataTraceEnabled':False,'LoggingLevel':'OFF','ThrottlingBurstLimit':50,'ThrottlingRateLimit':20}})
for name,api in [('Http','HttpApi'),('Socket','SocketApi')]:
    resource(name+'Permission','AWS::Lambda::Permission',{'Action':'lambda:InvokeFunction','FunctionName':ref('Backend'),
        'Principal':'apigateway.amazonaws.com','SourceArn':sub('arn:${AWS::Partition}:execute-api:${AWS::Region}:${AWS::AccountId}:${'+api+'}/*/*')})

template={'AWSTemplateFormatVersion':'2010-09-09',
    'Description':'WorshipCue isolated AWS development workspace. Managed identity, transactional storage, private immutable files, realtime hints.',
    'Parameters':{'CodeBucket':{'Type':'String'},'CodeKey':{'Type':'String'},
        'SenderIdentityArn':{'Type':'String','Default':'','NoEcho':True},'SenderAddress':{'Type':'String','Default':'','NoEcho':True}},
    'Conditions':{'HasSender':{'Fn::Not':[{'Fn::Equals':[ref('SenderIdentityArn'),'']}]}},
    'Resources':resources,
    'Outputs':{'APIURL':{'Value':sub('https://${HttpApi}.execute-api.${AWS::Region}.${AWS::URLSuffix}')},
        'WebSocketURL':{'Value':sub('wss://${SocketApi}.execute-api.${AWS::Region}.${AWS::URLSuffix}/development')},
        'UserPoolId':{'Value':ref('UserPool')},'ClientId':{'Value':ref('Client')},'TableName':{'Value':ref('Table')},
        'AssetBucket':{'Value':ref('Assets')},'BackupBucket':{'Value':ref('Backups')},'BackendFunction':{'Value':ref('Backend')},
        'EmailOTPReady':{'Value':choose('true','false')},'BackupFunction':{'Value':ref('BackupFunction')},
        'MailConfigurationSet':{'Value':ref('MailConfigurationSet')},'MailFeedbackFunction':{'Value':ref('MailFeedbackFunction')},
        'MailFeedbackTopic':{'Value':ref('MailFeedbackTopic')},'MailFeedbackDeadLetters':{'Value':ref('MailFeedbackDeadLetters')},
        'MailOperatorAlertsTopic':{'Value':ref('MailOperatorAlertsTopic')}}}
if __name__=='__main__':
    Path(__file__).with_name('template.json').write_text(json.dumps(template,indent=2)+'\n')
    print('Generated '+str(len(resources))+' isolated serverless resources.')
