#!/bin/sh
# A discovered, trusted device and an existing authorized free signing team are
# required. Keep UI cases in separate sessions for iPadOS 17's testmanagerd.
set -eu
cd "$(dirname "$0")/.."
: "${WORSHIPCUE_TEST_DEVICE_ID:?Supply the exact device identifier discovered by Xcode}"
: "${WORSHIPCUE_TEST_TEAM_ID:?Supply the existing authorized Personal Team identifier}"
. scripts/external_xcode_env.sh
worshipcue_result_root="$worshipcue_build_root/Results/M0-device-$(date +%Y%m%d-%H%M%S)"
mkdir "$worshipcue_result_root"
printf 'M0_DEVICE_RESULT_ROOT=%s\n' "$worshipcue_result_root"

worshipcue_run_tests() {
    xcodebuild -project apps/ipad/WorshipCue.xcodeproj -scheme "$2" -configuration Debug \
        -derivedDataPath "$worshipcue_build_root/DerivedData-Xcode27-iPad17" \
        -clonedSourcePackagesDirPath "$worshipcue_build_root/SourcePackages" \
        -destination "platform=iOS,id=$WORSHIPCUE_TEST_DEVICE_ID" -destination-timeout 30 \
        -resultBundlePath "$worshipcue_result_root/$1.xcresult" \
        SDK_STAT_CACHE_DIR="$worshipcue_build_root/DerivedData-Xcode27-iPad17" \
        DEVELOPMENT_TEAM="$WORSHIPCUE_TEST_TEAM_ID" CODE_SIGN_STYLE=Automatic \
        -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
        -parallel-testing-enabled NO "-only-testing:$3" test
}

worshipcue_run_tests native WorshipCue WorshipCueTests
worshipcue_run_tests drawing WorshipCueUI WorshipCueUITests/MusicStandUITests/testDrawingToolsSaveAndColdRelaunch
worshipcue_run_tests colors WorshipCueUI WorshipCueUITests/MusicStandUITests/testCompactColorPickerDismissalRenderedColorsAndRememberedChoices
worshipcue_run_tests transfer WorshipCueUI WorshipCueUITests/MusicStandUITests/testSelectedTransferCancelCommitUndoAndVersionPageIsolation
worshipcue_run_tests team WorshipCueUI WorshipCueUITests/MusicStandUITests/testReadOnlyTeamLayerUsesExactVersionAndPage
printf 'M0_DEVICE_TESTS_PASSED\n'
