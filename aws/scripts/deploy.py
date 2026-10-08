#!/usr/bin/env python3
"""Create/update only the explicitly named development stack; private inputs stay local."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]


def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w') as file:
        json.dump(value, file, indent=2)
        file.write('\n')
    os.chmod(path, 0o600)


class Deployment:
    def __init__(self, path):
        self.path, self.config = path, json.loads(path.read_text())
        self.region = self.config['region']
        self.stack = self.config['stack']
        if self.stack != 'worshipcue-dev' or self.region != 'us-east-1':
            raise SystemExit('This runner is restricted to the authorized WorshipCue development stack.')

    def call(self, *args, optional=False):
        command = [self.config.get('aws_cli', '/opt/homebrew/bin/aws'), *args,
                   '--region', self.region, '--output', 'json', '--no-cli-pager']
        if self.config.get('profile'):
            command += ['--profile', self.config['profile']]
        result = subprocess.run(command, capture_output=True, text=True)
        if result.returncode:
            if optional and 'does not exist' in result.stderr:
                return None
            save(self.path.parent / 'last-deployment-error.json', {'exit':result.returncode,'error':result.stderr})
            raise SystemExit('AWS rejected a deployment operation; details saved in the private deployment folder.')
        return json.loads(result.stdout) if result.stdout.strip() else {}

    def stack_info(self, name):
        result = self.call('cloudformation', 'describe-stacks', '--stack-name', name, optional=True)
        return result['Stacks'][0] if result else None

    def wait(self, name):
        previous = None
        while True:
            info = self.stack_info(name)
            status = info['StackStatus'] if info else 'MISSING'
            if status != previous:
                print(name + ': ' + status, flush=True)
                previous = status
            if status.endswith('_COMPLETE') and 'ROLLBACK' not in status:
                return info
            if status.endswith('_FAILED') or 'ROLLBACK' in status or status == 'MISSING':
                save(self.path.parent / 'stack-events.json', self.call('cloudformation','describe-stack-events','--stack-name',name))
                raise SystemExit('Stack did not complete; exact events saved in the private deployment folder.')
            time.sleep(15)

    def bootstrap(self):
        name = self.stack + '-artifacts'
        info = self.stack_info(name)
        if not info:
            template = {
                'AWSTemplateFormatVersion':'2010-09-09',
                'Description':'Private code artifacts for the authorized WorshipCue development stack.',
                'Resources':{
                    'Code':{'Type':'AWS::S3::Bucket','DeletionPolicy':'Retain','UpdateReplacePolicy':'Retain','Properties':{
                        'PublicAccessBlockConfiguration':{k:True for k in ['BlockPublicAcls','IgnorePublicAcls','BlockPublicPolicy','RestrictPublicBuckets']},
                        'OwnershipControls':{'Rules':[{'ObjectOwnership':'BucketOwnerEnforced'}]},
                        'BucketEncryption':{'ServerSideEncryptionConfiguration':[{'ServerSideEncryptionByDefault':{'SSEAlgorithm':'AES256'}}]},
                        'VersioningConfiguration':{'Status':'Enabled'},
                        'Tags':[{'Key':'Application','Value':'WorshipCue'},{'Key':'Environment','Value':'Development'}]}},
                    'Policy':{'Type':'AWS::S3::BucketPolicy','Properties':{'Bucket':{'Ref':'Code'},'PolicyDocument':{
                        'Version':'2012-10-17','Statement':[{'Effect':'Deny','Principal':'*','Action':'s3:*',
                            'Resource':[{'Fn::GetAtt':['Code','Arn']},{'Fn::Sub':'${Code.Arn}/*'}],
                            'Condition':{'Bool':{'aws:SecureTransport':'false'}}}]}}}},
                'Outputs':{'Bucket':{'Value':{'Ref':'Code'}}}}
            path = self.path.parent / 'artifact-template.json'
            save(path, template)
            self.call('cloudformation','create-stack','--stack-name',name,'--template-body','file://'+str(path))
        info = self.wait(name)
        return next(o['OutputValue'] for o in info['Outputs'] if o['OutputKey']=='Bucket')

    def recover_empty_failed_create(self):
        info = self.stack_info(self.stack)
        if not info or info['StackStatus'] != 'ROLLBACK_COMPLETE':
            raise SystemExit('Recovery only accepts a completely rolled-back development creation.')
        resources = self.call('cloudformation','list-stack-resources','--stack-name',self.stack)['StackResourceSummaries']
        retained = {r['LogicalResourceId']:r['PhysicalResourceId'] for r in resources if r['ResourceStatus']=='DELETE_SKIPPED'}
        if set(retained) != {'Table','Assets','Backups','UserPool'}:
            raise SystemExit('Unexpected retained resources; automatic empty recovery refused.')
        table = self.call('dynamodb','describe-table','--table-name',retained['Table'])['Table']
        tags = self.call('dynamodb','list-tags-of-resource','--resource-arn',table['TableArn'])['Tags']
        required = {'Application':'WorshipCue','Environment':'Development'}
        if not required.items() <= {t['Key']:t['Value'] for t in tags}.items():
            raise SystemExit('Development table ownership did not match.')
        if self.call('dynamodb','scan','--table-name',retained['Table'],'--limit','1','--consistent-read')['Count']:
            raise SystemExit('Development table contains data; automatic empty recovery refused.')
        for name in ['Assets','Backups']:
            bucket = retained[name]
            tags = self.call('s3api','get-bucket-tagging','--bucket',bucket)['TagSet']
            if not required.items() <= {t['Key']:t['Value'] for t in tags}.items():
                raise SystemExit('Development bucket ownership did not match.')
            contents = self.call('s3api','list-object-versions','--bucket',bucket,'--max-keys','1')
            if contents.get('Versions') or contents.get('DeleteMarkers'):
                raise SystemExit('Development bucket contains data; automatic empty recovery refused.')
        pool = self.call('cognito-idp','describe-user-pool','--user-pool-id',retained['UserPool'])['UserPool']
        if not required.items() <= pool.get('UserPoolTags',{}).items():
            raise SystemExit('Development identity pool ownership did not match.')
        if self.call('cognito-idp','list-users','--user-pool-id',retained['UserPool'],'--limit','1')['Users']:
            raise SystemExit('Development identity pool contains users; automatic empty recovery refused.')
        # No API was successfully deployed and every retained data resource is empty.
        self.call('cloudformation','delete-stack','--stack-name',self.stack)
        self.call('dynamodb','delete-table','--table-name',retained['Table'])
        self.call('cognito-idp','delete-user-pool','--user-pool-id',retained['UserPool'])
        for name in ['Assets','Backups']:
            self.call('s3api','delete-bucket','--bucket',retained[name])
        while self.stack_info(self.stack):
            time.sleep(5)
        print('Recovered only empty, ownership-checked resources from the failed creation.', flush=True)

    def run(self):
        bucket = self.bootstrap()
        package = json.loads((self.path.parent / 'package.json').read_text())
        data = Path(package['path']).read_bytes()
        if hashlib.sha256(data).hexdigest() != package['sha256']:
            raise SystemExit('Deployment package checksum mismatch.')
        key = 'backend/' + package['sha256'] + '.zip'
        self.call('s3api','put-object','--bucket',bucket,'--key',key,'--body',package['path'])
        sender_arn = ''
        if self.config.get('sender'):
            identity = self.call('sesv2','get-email-identity','--email-identity',self.config['sender'])
            if identity.get('VerifiedForSendingStatus'):
                account = self.call('sts','get-caller-identity')['Account']
                sender_arn = f'arn:aws:ses:{self.region}:{account}:identity/{self.config["sender"]}'
        parameters = [{'ParameterKey':k,'ParameterValue':v} for k,v in {
            'CodeBucket':bucket,'CodeKey':key,'SenderIdentityArn':sender_arn,
            'SenderAddress':self.config.get('sender','') if sender_arn else ''}.items()]
        params_path = self.path.parent / 'stack-parameters.json'
        save(params_path,parameters)
        self.call('cloudformation','validate-template','--template-body','file://'+str(ROOT/'template.json'))
        action = 'update-stack' if self.stack_info(self.stack) else 'create-stack'
        flags = ['--disable-rollback'] if action == 'create-stack' else []
        self.call('cloudformation',action,'--stack-name',self.stack,'--template-body','file://'+str(ROOT/'template.json'),
            '--parameters','file://'+str(params_path),'--capabilities','CAPABILITY_IAM',
            '--tags','Key=Application,Value=WorshipCue','Key=Environment,Value=Development',*flags)
        info = self.wait(self.stack)
        self.config['outputs'] = {o['OutputKey']:o['OutputValue'] for o in info['Outputs']}
        self.config['code_sha256'] = package['sha256']
        save(self.path,self.config)
        print('Development deployment completed. Private outputs saved.', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--config',type=Path,required=True)
    parser.add_argument('--recover-empty-failed-create',action='store_true')
    args = parser.parse_args()
    deployment = Deployment(args.config.resolve())
    if args.recover_empty_failed_create:
        deployment.recover_empty_failed_create()
    deployment.run()
