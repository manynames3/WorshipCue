# WorshipCue infrastructure

A stakeholder view of the AWS development system and the path to a church pilot. The diagram separates features implemented now from release gates; it does not claim production or multi-device qualification.

- [One-page PDF for sharing](../../output/pdf/worshipcue-infrastructure.pdf)
- [PNG for presentations](worshipcue-infrastructure.png)
- [Editable vector SVG](worshipcue-infrastructure.svg)

The iPad keeps verified downloaded charts and personal notes usable locally. Team work crosses a permission check for the exact church and team before accessing metadata, messages or files. Live connections notify the app to check durable state; the musician still taps to open an announced song and turns pages independently.

Cognito handles identity and Amazon SES sends sign-in codes. General email onboarding remains gated by SES production access. API Gateway and Lambda serve the app; DynamoDB stores authorized team records and chat, while private S3 stores verified immutable PDFs and drawing assets. WebSocket hints enable foreground live updates; background push is not enabled.

Scheduled backups retain metadata and pinned files, and CloudWatch routes operational alerts. The small development restore has been checked; larger multi-invocation restores still need qualification. The app supports a selected-team personal cloud ZIP export, including verified note files and their authorized source PDFs. That ZIP excludes local unsynced work and is not a complete account backup or automatic restore.

Before release, qualify two real iPads, physical Apple Pencil, the oldest supported hardware, reconnect/offline/resume and a sustained rehearsal. Establish support, deletion and retention policies and finish capacity tests. No paid Apple enrollment or TestFlight distribution is enabled.
