# WorshipCueInk

Native PencilKit operations shared by the iPad app and macOS executable verification. The pure domain package remains free of UI/native framework imports. `SelectedInkClipboard` owns immutable selected stroke clones, source identity/geometry/bounds and manual uniform placement. It never uses the system pasteboard, guesses musical alignment, or mutates the source.

Run from the handoff root:

```sh
sh scripts/check_macos_frameworks.sh
```

The macOS harness exercises the same production clipboard API, actual PencilKit archives through the production SQLite store, and actual PDFKit fixture metadata/rejection. It does not test the UIKit canvas/overlay provider, Pencil touch routing, native undo, simulator or physical iPad behavior. Those remain in the unexecuted iPad native test target/device checklist.

The script wraps the compiled executable in a temporary valid macOS app bundle, without launching a UI or configuring signing. Bare CLI PencilKit drawing creation can trap in CoreFoundation preferences because no bundle identifier is available on this host. Initial failed runs and scale-bound diagnostics are preserved in verification; use the wrapper command.
