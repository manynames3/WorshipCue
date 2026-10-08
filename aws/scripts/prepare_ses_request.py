#!/usr/bin/env python3
"""Prepare private SES request data for review; never submit or send anything."""
import argparse
import json
import os
from pathlib import Path
import tempfile
from urllib.parse import urlsplit

REPO = Path(__file__).resolve().parents[2]
DESCRIPTION = '''WorshipCue is a native iPad music stand for church worship teams. Our initial pilot is one church with 10-20 members. We request transactional email access in us-east-1 to deliver Amazon Cognito sign-in codes triggered by explicit in-app sign-in requests. Users prove control of their mailbox by entering the code; separate invitations and exact-team membership protect libraries, notes, setlists and chat. We do not send marketing email or use purchased contact lists.

The application limits code requests per destination, source and globally. A dedicated SES configuration set routes permanent bounces and complaints through SNS to a scoped Lambda consumer. A hash-only application suppression record prevents further code requests to affected mailboxes; transient bounces are not permanently suppressed. Existing SES account suppression covers BOUNCE and COMPLAINT. Failed feedback has a private encrypted 14-day dead-letter queue and CloudWatch failure/backlog alarms. The associated public repository explains the product and development status. This is a review draft: human alert delivery and the operator contact/response process must be confirmed before submission.'''


def request(config, website):
    parsed = urlsplit(website)
    if (parsed.scheme != 'https' or not parsed.hostname or parsed.username or parsed.password
            or len(website) > 500 or parsed.fragment):
        raise ValueError('A public HTTPS product page is required.')
    if config.get('stack') != 'worshipcue-dev' or config.get('region') != 'us-east-1':
        raise ValueError('Only the authorized development region is supported.')
    sender = config.get('sender')
    if not isinstance(sender,str) or sender.count('@') != 1:
        raise ValueError('An existing private contact address is required.')
    return {'ProductionAccessEnabled':True,'MailType':'TRANSACTIONAL','WebsiteURL':website,
            'ContactLanguage':'EN','AdditionalContactEmailAddresses':[sender],'UseCaseDescription':DESCRIPTION}


def prepare(config_path, website):
    config_path = config_path.resolve()
    if config_path.is_relative_to(REPO) or config_path.stat().st_mode & 0o077:
        raise ValueError('Configuration must be private and outside the repository.')
    value = request(json.loads(config_path.read_text()),website)
    path = config_path.parent/'ses-production-request-DRAFT.json'
    fd, temporary = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd,'w') as file: json.dump(value,file,indent=2); file.write('\n')
        os.chmod(temporary,0o600); os.replace(temporary,path)
    finally:
        if os.path.exists(temporary):os.unlink(temporary)
    return path


def self_test():
    config={'stack':'worshipcue-dev','region':'us-east-1','sender':'synthetic@example.test'}
    assert request(config,'https://example.test/worshipcue')['MailType']=='TRANSACTIONAL'
    for website in ('http://example.test','https://user:secret@example.test','https://example.test/#fragment','file:///private'):
        try:request(config,website)
        except ValueError:pass
        else:raise AssertionError('Unsafe website accepted')
    try:request({**config,'region':'outside'},'https://example.test')
    except ValueError:pass
    else:raise AssertionError('Unapproved scope accepted')
    with tempfile.TemporaryDirectory() as directory:
        source=Path(directory)/'private.json'; source.write_text(json.dumps(config)); source.chmod(0o600)
        result=prepare(source,'https://example.test')
        assert result.stat().st_mode & 0o077 == 0
        assert json.loads(result.read_text())['AdditionalContactEmailAddresses']==[config['sender']]
        source.chmod(0o644)
        try:prepare(source,'https://example.test')
        except ValueError:pass
        else:raise AssertionError('Public private config accepted')
    print('PASS transactional draft, website/scope guards and private output permissions; no AWS calls')


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config',type=Path)
    parser.add_argument('--website-url',default='https://github.com/manynames3/WorshipCue/tree/v2')
    parser.add_argument('--self-test',action='store_true')
    args=parser.parse_args()
    if args.self_test:self_test()
    elif args.config:
        prepare(args.config,args.website_url)
        print('Private review draft saved; no AWS request submitted. Confirm contact, product page and operator alerts before submission.')
    else:parser.error('--config or --self-test is required')
