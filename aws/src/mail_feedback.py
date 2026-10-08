"""Scoped SES feedback prevents new codes to failed/complaining mailboxes.

Only hashes and categorical reasons are retained. SES owns mail delivery; this
application gate also works while sandbox suppression-management APIs are disabled.
"""
import hashlib
import json
import os
import time

from store import Conflict, DynamoStore

SES_TOPIC_VALIDATION = 'Successfully validated SNS topic for Amazon SES event publishing.'


def address_hash(value):
    if not isinstance(value, str):
        raise ValueError('INVALID_MAIL_ADDRESS')
    value = value.strip().lower()
    if len(value) > 254 or value.count('@') != 1 or any(c.isspace() for c in value) or not all(value.split('@')):
        raise ValueError('INVALID_MAIL_ADDRESS')
    return hashlib.sha256(value.encode()).hexdigest()


def suppressed(store, address):
    return store.get('MAIL#' + address_hash(address), 'SUPPRESSION') is not None


class Feedback:
    def __init__(self, store, topic, configuration_set, source_arn, account, now=time.time):
        self.store, self.topic, self.configuration_set, self.now = store, topic, configuration_set, now
        self.source_arn, self.account = source_arn, account

    def handle(self, event):
        records = event.get('Records') if isinstance(event, dict) else None
        if not isinstance(records, list) or not 1 <= len(records) <= 100:
            raise ValueError('INVALID_MAIL_EVENT')
        changed = 0
        for record in records:
            if not isinstance(record, dict) or record.get('EventSource') != 'aws:sns':
                raise ValueError('INVALID_MAIL_SOURCE')
            sns = record.get('Sns', {})
            if sns.get('TopicArn') != self.topic:
                raise ValueError('INVALID_MAIL_SOURCE')
            raw = sns.get('Message')
            if not isinstance(raw, str) or len(raw.encode()) > 262144:
                raise ValueError('INVALID_MAIL_EVENT')
            # SES validates a destination using this exact, identifier-free probe.
            # The topic policy scopes the publisher to our account/configuration;
            # other non-JSON messages must still fail into retry/recovery.
            if raw == SES_TOPIC_VALIDATION:
                continue
            value = json.loads(raw, parse_constant=lambda _: (_ for _ in ()).throw(ValueError('INVALID_MAIL_EVENT')))
            changed += self.process(value)
        return {'processed_records': len(records), 'new_suppressions': changed}

    def process(self, value):
        if not isinstance(value, dict) or not isinstance(value.get('mail'), dict):
            raise ValueError('INVALID_MAIL_EVENT')
        mail = value['mail']
        if (mail.get('tags', {}).get('ses:configuration-set') != [self.configuration_set]
                or mail.get('sourceArn') != self.source_arn or mail.get('sendingAccountId') != self.account):
            raise ValueError('INVALID_MAIL_SCOPE')
        kind = value.get('eventType')
        if kind == 'Bounce':
            detail = value.get('bounce', {})
            if not isinstance(detail, dict) or detail.get('bounceType') not in ('Permanent','Transient','Undetermined'):
                raise ValueError('INVALID_MAIL_EVENT')
            if detail.get('bounceType') != 'Permanent':
                return 0
            recipients, reason = detail.get('bouncedRecipients'), 'permanent_bounce'
        elif kind == 'Complaint':
            detail = value.get('complaint', {})
            if not isinstance(detail, dict):
                raise ValueError('INVALID_MAIL_EVENT')
            if detail.get('complaintFeedbackType') == 'not-spam':
                return 0
            recipients, reason = detail.get('complainedRecipients'), 'complaint'
        else:
            raise ValueError('INVALID_MAIL_TYPE')
        destination = mail.get('destination')
        message = mail.get('messageId')
        if (not isinstance(destination, list) or not 1 <= len(destination) <= 50
                or not isinstance(recipients, list) or not 1 <= len(recipients) <= 50
                or not isinstance(message, str) or not 1 <= len(message) <= 200):
            raise ValueError('INVALID_MAIL_EVENT')
        addresses = {address_hash(v) for v in destination}
        targets = {address_hash(v.get('emailAddress')) for v in recipients if isinstance(v, dict)}
        if len(targets) != len(recipients) or not targets <= addresses:
            raise ValueError('INVALID_MAIL_RECIPIENT')
        # Validate the complete feedback before any write, then CAS each address.
        changed = 0
        for digest in sorted(targets):
            pk = 'MAIL#' + digest
            for attempt in range(4):
                old = self.store.get(pk, 'SUPPRESSION')
                if old is not None and (reason != 'complaint' or old.get('reason') == 'complaint'):
                    break
                row = {**(old or {}), 'reason': reason, 'suppressed_at_epoch': old['suppressed_at_epoch'] if old else int(self.now()),
                       'event_hash': hashlib.sha256((kind + ':' + message).encode()).hexdigest()}
                try:
                    self.store.transact([{'op':'put', 'pk':pk, 'sk':'SUPPRESSION', 'expected':old, 'value':row}])
                    changed += int(old is None)
                    break
                except Conflict:
                    if attempt == 3:
                        raise RuntimeError('MAIL_FEEDBACK_CONFLICT') from None
        return changed


def lambda_handler(event, context):
    try:
        result = Feedback(DynamoStore(os.environ['TABLE_NAME']), os.environ['FEEDBACK_TOPIC'],
                          os.environ['MAIL_CONFIGURATION_SET'], os.environ['MAIL_SOURCE_ARN'], os.environ['MAIL_ACCOUNT']).handle(event)
        print(json.dumps({'event':'mail_feedback_processed', **result}))
        return result
    except Exception:
        # SNS can retry; never print original mail headers, addresses or exception text.
        print(json.dumps({'event':'mail_feedback_failed'}))
        raise RuntimeError('MAIL_FEEDBACK_FAILED') from None
