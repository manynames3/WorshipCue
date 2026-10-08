# WorshipCueLocal

Production M0 personal-ink storage and canonical geometry; framework-free apart from Foundation and GRDB. The app and executable checks share this implementation. The existing WorshipCueCore package remains the sole source of team-layer identity rules.

`LocalInkStore` is an actor owning one GRDB DatabaseQueue. Its named migration creates personal heads and a personal-only outbox. WAL + synchronous FULL and transactional head/outbox writes define the local acknowledgment boundary. Local generation rejects reordered saves and divergent same-generation bytes. Unsent snapshots coalesce for each exact layer with no server base, while failed transactions retain the previous head/outbox. M2 must add synchronization/in-flight/conflict handling before any network worker consumes this outbox.

`InkChecks` is a real executable check harness for CLT hosts missing XCTest, not a substitute for the supplied XCTest suite or native/device tests. It checks SQLite reopening, captured page/version identity, retries/conflicts, failed writes, independent geometry corner expectations, exact team gating, delayed restoration, and corrupted address rejection. Its byte fixtures are opaque test data; PencilKit archive validity is checked by the separate native tests.

## Dependency review

D20 already selected GRDB. Pin: **7.11.1**, commit `b83108d10f42680d78f23fe4d4d80fc88dab3212`, preserved in `Package.resolved`. Official source: https://github.com/groue/GRDB.swift/tree/v7.11.1. Official requirements: Swift 6.1+, Xcode 16.3+, iOS 13+; the app and local packages now target iPadOS 16.0 under the user's older-iPad requirement (D39 amendment).

License reviewed: MIT, notice copied into the iPad bundle's `ThirdPartyNotices.txt`. This package uses public SQL/DatabaseQueue APIs and the system SQLite library. The resolved package manifest has no active transitive production packages or build plugins. No hosted SDK or credentials were added. This is a scoped manifest/license review, not an independent dependency security audit. Review changes before upgrading the exact pin.
