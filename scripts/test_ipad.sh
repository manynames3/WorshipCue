#!/bin/sh
# Resolve an actual installed iPad simulator; no invented destination UUID.
set -eu
cd "$(dirname "$0")/.."
. scripts/external_xcode_env.sh
xcodebuild -version
xcodebuild -project apps/ipad/WorshipCue.xcodeproj -scheme WorshipCue \
    -derivedDataPath "$worshipcue_build_root/DerivedData" \
    -clonedSourcePackagesDirPath "$worshipcue_build_root/SourcePackages" \
    -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
worshipcue_devices=$(mktemp "${TMPDIR:-/tmp}/worshipcue-devices.XXXXXX")
trap 'rm -f "$worshipcue_devices"' EXIT
xcrun simctl list --json devices available > "$worshipcue_devices"
worshipcue_destination=$(python3 - "$worshipcue_devices" <<'PY'
import json,sys
with open(sys.argv[1]) as source: devices = json.load(source)['devices']
for runtime in sorted(devices):
    for device in devices[runtime]:
        if 'iOS' in runtime and 'iPad' in device['name'] and device.get('isAvailable'):
            print(device['udid']); sys.exit(0)
sys.exit('NOT VERIFIED: no installed available iPad simulator')
PY
)
xcodebuild -project apps/ipad/WorshipCue.xcodeproj -scheme WorshipCue \
    -derivedDataPath "$worshipcue_build_root/DerivedData" \
    -clonedSourcePackagesDirPath "$worshipcue_build_root/SourcePackages" \
    -destination "platform=iOS Simulator,id=$worshipcue_destination" \
    CODE_SIGNING_ALLOWED=NO test
