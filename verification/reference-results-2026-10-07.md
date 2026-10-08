# Fresh reference verification, 2026-10-07

These results were executed on this workspace during M0 implementation. Original handoff evidence (`REPORT.md`, `swift-test.log`, and `package-test.log`) is preserved unchanged. Reference checks do not certify native PDFKit/PencilKit behavior or a physical iPad.

## Environment

- Working directory: `/Volumes/CRUCIAL 525GB - Data/Projects/general dump/WorshipCue_Codex_Handoff_v1`.
- macOS 27.0.1 (26A434), arm64.
- `/usr/bin/swift`: Apple Swift 6.4 (`swiftlang-6.4.0.34.1`, clang 2100.3.34.1), swift-driver 1.168.6.
- Active developer directory: `/Library/Developer/CommandLineTools`.
- Default `python3`: `/opt/homebrew/bin/python3`, Python 3.14.6, pip 26.1.2; `jsonschema` initially missing.
- Bundled Python: `/Users/aiden/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3`, Python 3.12.14; `jsonschema` also missing.
- No alternate toolchain found at `/Library/Developer/Toolchains` or `/Users/aiden/Library/Developer/Toolchains`; `/Applications/Xcode.app/Contents/Developer/Toolchains` is absent.
- Fresh raw environment output: `reference-toolchain.log`.

## Exact checks and results

| Command | Exit | Result / raw log |
| --- | --- | --- |
| `shasum -a 256 -c MANIFEST.sha256` | 0 | All **56 original handoff entries matched**, checked before implementation edits. `reference-manifest-check.log`. |
| `swift test --package-path reference/WorshipCueCore` | 1 | Build cannot resolve module dependency `XCTest` from installed Command Line Tools. **No reference tests executed.** `reference-swift-test.log`. |
| `swift build --package-path reference/WorshipCueCore` | 0 | Portable library compiled, `Build complete! (14.06 sec)`. Linker warning: search path `/Library/Developer/CommandLineTools/Developer/Library/Frameworks` not found. `reference-swift-build.log`. |
| `swift test --package-path reference/WorshipCueCore --build-system native` | 1 | Alternate local SwiftPM engine also fails with `no such module 'XCTest'`; engine itself is deprecated. **No reference tests executed.** `reference-swift-test-native-engine.log`. |
| `printf 'import Testing\n' \| swiftc -typecheck -` | 1 | Available compiler also lacks the `Testing` module. `reference-swift-testing-import.log`. |
| `python3 scripts/verify_package.py` | 1 | Default interpreter reports missing verification dependency. `reference-package-default-python.log`. |
| `/tmp/worshipcue-reference-verification-venv/bin/python3 scripts/verify_package.py` | 0 | **32 tests passed**, 0 failures, 0.050 seconds. `reference-package-test.log`. |

The Python success uses an isolated temporary environment, created after checking existing default and bundled runtimes. Existing pinned verification dependency was installed with these commands; no production dependency or reference contract changed:

```sh
python3 -m venv /tmp/worshipcue-reference-verification-venv
/tmp/worshipcue-reference-verification-venv/bin/python3 -m pip install -r scripts/requirements.txt
/tmp/worshipcue-reference-verification-venv/bin/python3 scripts/verify_package.py
/tmp/worshipcue-reference-verification-venv/bin/python3 -m pip freeze
```

Environment creation/installation succeeded (exit 0). See `reference-python-dependency-install.log`. Actual resolved packages are recorded in `reference-python-environment.log`: `jsonschema==4.26.0`, `attrs==26.1.0`, `jsonschema-specifications==2025.9.1`, `referencing==0.37.0`, and `rpds-py==2026.9.1`. The temporary environment can be recreated from the commands above; it is not part of the delivered repository.

The 32 checks cover contract examples and JSON Schema validation, rejected page/auto-follow live commands, fixture hashes/lengths, Korean error keys, and reference SQLite constraints/transaction shapes. They do not run the native implementation. The handoff's earlier 55 passing Swift tests were reported on Linux and are historical evidence, not fresh passing results on this host.

## Unverified requirements

- Fresh reference XCTest execution requires a toolchain that supplies XCTest; installed Command Line Tools do not.
- Native app build, simulator execution, PDFKit/PencilKit integration tests, and native selected-stroke copy/paste require the native SDK/tools; they are separate from this portable library build.
- Physical device model, iPadOS version, Pencil model, handwriting/palm interaction, force-kill recovery, rotated/CropBox alignment, zoom/rotation/canvas reuse, memory/thermal/resume behavior, and multi-iPad tests remain **NOT VERIFIED** by these checks.

The immutable original manifest remains provenance for the handoff. Do not rewrite it to hide deliberate implementation/documentation changes made after the successful integrity check.
