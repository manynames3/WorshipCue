#!/bin/sh
# Run one command with the external Xcode and temporary/module-cache paths.
set -eu
cd "$(dirname "$0")/.."
. scripts/external_xcode_env.sh
if [ "$#" -eq 0 ]; then
    printf 'Xcode: %s\nBuild storage: %s\nTemporary: %s\n' \
        "$DEVELOPER_DIR" "$worshipcue_build_root" "$TMPDIR"
    xcodebuild -version
else
    exec "$@"
fi
