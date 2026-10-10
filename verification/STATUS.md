# Verification and publication status

As of **October 10, 2026**. [Overview](../README.md) · [Feature/fix history](../CHANGELOG.md) · [Engineering](../docs/ENGINEERING.md)

This public summary consolidates the local Build 17 qualification, capacity work and Build 19 reader receipts. Tests listed in different rows are separate runs. They must not be summed into a single full-product pass. Private charts, handwriting, email codes, account/device identifiers and raw artifacts are excluded from the repository.

## Publication and builds

| Location | Application source | Documentation |
| --- | --- | --- |
| `main` | Preserved original v1 / Build 3 | Current product overview, changelog and engineering summary |
| `v1` | Original v1 / Build 3 checkpoint | Original checkpoint documentation |
| `v2` | Published concept-direction / AWS Build 8 checkpoint | Current product overview, changelog and engineering summary |
| Local development | Native Build 19 plus backend/browser work after Build 8 | Latest implementation and qualification records |

This documentation update does not publish the pending application/backend source changes. Later features and screenshots describe actual development work, not everything available by cloning the current source checkpoint. No App Store release or fully qualified rehearsal pilot is claimed.

## Recorded results

| Area | Actual result | Scope |
| --- | --- | --- |
| Controlled AWS backend, Python 3.13 | **227 passed**, zero skips | Includes the nine new capacity/deployment regressions; controlled services, not a load test. |
| Swift packages/reference | **36 remote, 55 core, 14 local, 32 reference checks passed** | Separate package/verifier runs during qualification. Core 55 and reference 32 were repeated successfully during Build 19 work. |
| Real hosted AWS scenarios | **27 passed** | Synthetic identities and bounded operations on the deployed development backend. |
| Browser HTTP clients | **22 passed** | Independent cookie jars/guest identities; durable reply, edit, delete/replay, session restoration and revocation. These are HTTP checks, not new rendered browser gestures. |
| Managed Neon + AWS | **12 passed** | Real hosted session/team/chat/WebSocket checks, including logout and rejection of access/refresh afterward. |
| Native live managed sign-in | **One passed** | Production adapter/workspace: fresh user-provided code, Keychain, synthetic team, durable chat and restoration in a new instance. Does not prove UI-entered OTP or a multi-device conversation. |
| Native chat regressions | **12 passed** in the final focused run | Rendered conversation/read-state checks with controlled transport. Synthetic light/dark captures inspected. |
| Code-resend UI | **One passed** in its isolated rerun | Blank field and retained resend step after locally rejected synthetic input; not a delivery test. |
| Private arranger PDF behavior | **One passed** | Import, embedded annotations, manual selected-note transfer, undo, cold restore and fallback export; eight native page renders inspected privately. |
| Page-arrow rendering | **One passed; 80 turns** | Four scenarios across two private PDFs, including 300 strokes. Rendered p95 **123.52–140.72 ms**; excludes gesture-recognition latency. |
| Isolated cloud restore | **1,489 stable rows matched; nine assets verified** | Separate scratch table, published references and 17 immutable rows checked; zero live rows changed/unmatched; owned scratch table removed. Not a maximum-size or multi-invocation restore qualification. |
| Build 19 motion harness | **Seven cases, 44 assertions, zero failures** | Extracted production classifier/regression methods; both directions, uneven fingers, diagonal movement, pinch/writing rejection and bounds. Not actual swipe injection. |
| Build 19 physical native suite | **125 total: 122 passed, three opt-in skips, zero failed** | After classifier correction, before final eligibility handoff correction. Skips: live sign-in and two private-PDF cases. |
| Build 19 visible reader UI | **One passed**, 38.362 seconds | Full screen, finger writing, page controls and restored ink; synthetic normal/full-screen captures inspected. |
| Final Build 19 build/install | **Debug and optimized Release builds passed; install and launch passed** | Nine compiled configuration checks per configuration and signature verification passed. Final gesture-handoff tests compiled but did not execute. |
| Update preservation | **Seven PDFs and five complete personal-ink rows exact; four SQLite checks OK** | Pre/post installation comparison; no normal app uninstall. |

### Failed and unverified runs retained

- **Raw 50-client burst: 27 passed, 23 failed.** HTTP throttling and Lambda limits remain a capacity gate. The last recorded applied Lambda concurrency limit was ten. Higher HTTP admission settings are prepared but have not been deployed; no post-change burst pass is claimed.
- **Build 19 pinch/drawing UI check: one failed.** A pinch left the page and ink unchanged, but the following writing stroke was not recorded. An explicit recognizer-failure handoff correction was implemented afterward.
- **Final handoff reruns: zero cases started.** Xcode's test service stalled before launch. Bounded attempts exited 124; a separate stalled full-native process was terminated. These are unverified attempts, not passing suites.
- Actual latest two-finger swipe feel, post-zoom drawing and the retained two-finger-tap injection case remain unqualified. Earlier Build 12 human confirmation of both swipe directions does not qualify the final Build 19 code.

## What must happen before release

- Confirm the final gesture handoff and native login UI end to end; qualify two real iPads sharing music, marks, cues and chat.
- Qualify the original iPadOS 16 hardware, physical Apple Pencil/palm behavior, large archives, background/resume, reconnect, memory/thermal pressure and a sustained rehearsal.
- Apply sufficient AWS concurrency headroom and rerun representative concurrent-user/chat workloads. Current burst results are insufficient.
- Establish production email delivery and branding. Neon development delivery works; the original Cognito/SES path's last recorded production-access state was denied. No new approval is inferred.
- Finish account deletion, retention, support procedures, larger recovery qualification and release distribution. Background push, TestFlight and public distribution are not enabled.

## Screenshot provenance

The README music stand is a Build 12 physical iPad capture using a synthetic chart and isolated store. The native chat capture is a Build 17 rendered view using synthetic conversation data and controlled transport. The browser capture is a Build 14 actual desktop browser view using synthetic test PDFs/conversations. They are implementation captures, not design concepts, current Build 19 screen proofs or a live multi-iPad session.

Historical published receipts remain available in [Build 8](https://github.com/manynames3/WorshipCue/blob/v2/verification/BUILD8.md), [Build 7](https://github.com/manynames3/WorshipCue/blob/v2/verification/CHAT7.md) and [AWS](https://github.com/manynames3/WorshipCue/blob/v2/verification/AWS.md). Exact later development receipts are retained locally; this summary does not publish their private raw inputs or device bundles.
