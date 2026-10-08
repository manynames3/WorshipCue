# SES production access preparation

WorshipCue uses Cognito email codes. SES sender verification is already complete, and one real user code/refresh/sign-out flow passed. The remaining account restriction is the SES sandbox in `us-east-1`: individual recipient verification is temporary, not the intended onboarding design. Production access lets users receive an in-app sign-in code without first registering their address with SES. Team invitations separately control content access. [AWS requirements](https://docs.aws.amazon.com/ses/latest/dg/request-production-access.html)

## Delivery feedback implementation

The dedicated WorshipCue configuration set is attached to Cognito, rather than changing the sender identity's global forwarding/default configuration. Its bounce/complaint destination is a private SNS topic restricted to this account/configuration set. A scoped Lambda verifies topic, configuration set, sender identity/account and affected recipients before writing suppression records. DynamoDB retains only address/message hashes, category and time; it never stores mail headers, sign-in codes or raw addresses in these records or logs.

Permanent failures and complaints stop future code requests to that address. Transient/undetermined failures do not permanently block the account. Duplicate deliveries are idempotent; an older bounce cannot downgrade a complaint. Storage failure raises an error for retry rather than acknowledging success. The consumer can write only `MAIL#` keys in the development table. Existing account SES suppression includes both BOUNCE and COMPLAINT; no account-wide settings were changed.

Both SNS-to-Lambda delivery failure and accepted-Lambda processing failure have a private SSE-SQS encrypted dead-letter queue with 14-day retention. Those failed-event payloads can contain original mail addresses/headers; they are private recovery data, not sanitized logs. Operators must restrict access, avoid copying them into tickets/Git, and delete only resolved events. CloudWatch alarms cover feedback errors, dead-letter delivery errors, SNS notification failures and visible queue backlog. With the user’s explicit authorization, the operator email subscription was requested and confirmed. A direct test notification was accepted by SNS; an owned CloudWatch backlog alarm was then qualified through successful action history and returned naturally to OK. Inbox receipt of either notification was not independently verified. The failure queue was empty at the end of qualification.

AWS mailbox simulator qualification checks feedback routing and the application suppression gate. It does not populate the real SES suppression list or prove a user's inbox delivery. The existing sender has feedback forwarding enabled, so AWS may forward simulator feedback notices to that address. [SES event contents](https://docs.aws.amazon.com/ses/latest/dg/event-publishing-retrieving-sns-contents.html), [SNS event permissions](https://docs.aws.amazon.com/ses/latest/dg/event-publishing-add-event-destination-sns.html), [Lambda async recovery](https://docs.aws.amazon.com/lambda/latest/dg/invocation-async-error-handling.html)

## Submitted request and current review

`aws/scripts/prepare_ses_request.py` creates a mode-0600 draft outside Git. It does not call AWS or submit a support request. The draft uses TRANSACTIONAL mail, the public v2 repository/product description, the existing private sender as a proposed contact, the 10–20-member pilot and the implemented rate/feedback protections. A custom domain with authenticated sending is a stronger release setup, but buying a domain is not required for this preparation.

```sh
python3 aws/scripts/prepare_ses_request.py --self-test
python3 aws/scripts/prepare_ses_request.py \
  --config /absolute/external/AWS/private-config.json \
  --website-url https://github.com/manynames3/WorshipCue/tree/v2
```

On 2026-10-08 the user authorized connecting alerts and submitting the request, then confirmed the alert subscription. The scoped helper reviewed the private ready request and sent it once. AWS initially accepted it with **PENDING** status, then a later status read returned **DENIED** with `ProductionAccessEnabled` false. Ordinary unverified recipients still cannot receive sign-in codes. No repeat submission occurred. The operator subscription, submission receipt and request hash remain private, outside Git. A local lock conflict prevented an earlier attempt before any AWS submission; a later unknown alarm-operation outcome was reconciled from its exact owned receipt rather than blindly repeated. The status response contains a case identifier but no explanation. Reading its body through the Support API returned `SubscriptionRequiredException`; the Support browser requires a direct user sign-in. The actual denial reason is unverified, and no paid Support upgrade or speculative appeal was submitted.

The submitted request describes transactional sign-in codes, the public v2 repository, a 10–20-member pilot, rate limits, bounce/complaint suppression and qualified failure alerts. No paid service enrollment, domain purchase or account-wide feedback change occurred. AWS can request more information; request acceptance is not production approval. [Production access process](https://docs.aws.amazon.com/ses/latest/dg/request-production-access.html)

The final operator policy covers six exact alarm/account sources: the four mail alarms plus backup errors and stale completion. Owned CloudWatch routing exercises qualify both mail-backlog and backup-error paths through successful exact-topic SNS action history and natural return to OK, with no manual reset. All six alarms end OK. Stale completion naturally reaches OK after real verified backup metrics; its own notification delivery remains unexercised. Operator inbox receipt is still unverified.

The operator workflow is to check the alarms and restricted queue, investigate routing/permission/processing errors, retry the repaired event safely, and retain suppression for real permanent failures/complaints. Re-enabling a destination requires verified ownership and an explicit support decision; there is no automatic unsuppression. This process must not expose personal charts, handwriting or team chat.

SES production access is an AWS email-sending approval. It does not require Apple enrollment or publish the iPad app.
