# Source from a repository script after changing to the repository root.
# Scoped settings: no global xcode-select change or system-directory symlinks.
worshipcue_tools_root=${WORSHIPCUE_TOOLS_ROOT:-"$(cd .. && pwd)/DeveloperTools"}
worshipcue_xcode_app=${WORSHIPCUE_XCODE_APP:-"$worshipcue_tools_root/Applications/Xcode.app"}
if [ ! -x "$worshipcue_xcode_app/Contents/Developer/usr/bin/xcodebuild" ]; then
    echo "NOT VERIFIED: install stable Xcode at $worshipcue_xcode_app" >&2
    return 2
fi
export DEVELOPER_DIR="$worshipcue_xcode_app/Contents/Developer"
worshipcue_build_root="$worshipcue_tools_root/WorshipCue"
mkdir -p "$worshipcue_tools_root/Temporary" "$worshipcue_build_root/DerivedData" \
    "$worshipcue_build_root/SourcePackages" "$worshipcue_build_root/Archives" \
    "$worshipcue_build_root/Results"
export TMPDIR="$worshipcue_tools_root/Temporary/"
export CLANG_MODULE_CACHE_PATH="$worshipcue_build_root/DerivedData/ModuleCache.noindex"
export SWIFT_MODULE_CACHE_PATH="$worshipcue_build_root/DerivedData/ModuleCache.noindex"
