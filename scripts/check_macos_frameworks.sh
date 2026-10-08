#!/bin/sh
# PencilKit requires a real bundle identity; a bare CLI traps in macOS preferences.
set -eu
cd "$(dirname "$0")/.."
worshipcue_root=$PWD
swift build --package-path packages/WorshipCueInk --product FrameworkChecks
worshipcue_bin=$(swift build --package-path packages/WorshipCueInk --show-bin-path)
worshipcue_temp=$(mktemp -d "${TMPDIR:-/tmp}/worshipcue-framework.XXXXXX")
trap 'rm -rf "$worshipcue_temp"' EXIT
worshipcue_bundle="$worshipcue_temp/FrameworkChecks.app/Contents"
mkdir -p "$worshipcue_bundle/MacOS"
cp "$worshipcue_bin/FrameworkChecks" "$worshipcue_bundle/MacOS/FrameworkChecks"
cat > "$worshipcue_bundle/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.worshipcue.framework-checks</string>
<key>CFBundleExecutable</key><string>FrameworkChecks</string>
<key>CFBundleName</key><string>FrameworkChecks</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
SWIFT_BACKTRACE=enable=no "$worshipcue_bundle/MacOS/FrameworkChecks" "$worshipcue_root"
