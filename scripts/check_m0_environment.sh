#!/bin/sh
# Inventory only; never installs Xcode, signs, or claims physical checks passed.
set -u
cd "$(dirname "$0")/.." || exit 1
sw_vers
swift --version
if ! xcodebuild -version; then
    echo 'NOT VERIFIED: full Xcode/iOS SDK/simulator tools unavailable.'
    exit 2
fi
xcodebuild -list -project apps/ipad/WorshipCue.xcodeproj || exit 1
xcrun simctl list devices available || exit 1
xcrun xctrace list devices || exit 1
echo 'Inventory does not verify handwriting, device performance, or note recovery.'
