#!/bin/zsh
# Usage: scripts/build.sh <name> [mac|ios|test|all]   — each agent uses its own <name> for DerivedData.
set -o pipefail
cd "$(dirname "$0")/.."
NAME=${1:-default}; WHAT=${2:-all}
xcodegen generate -q >/dev/null 2>&1 || xcodegen generate
COMMON=(-scheme DeStream -clonedSourcePackagesDirPath .build/spm -skipPackageUpdates)
filter() { grep -E "error:|warning: .*/App/.*\.swift|BUILD|TEST|Executed|failed|passed" | grep -v "^Test Case.*passed" | head -80 }
rc=0
if [[ $WHAT == mac || $WHAT == all ]]; then
  xcodebuild "${COMMON[@]}" -destination 'platform=macOS' -derivedDataPath .build/dd-$NAME -allowProvisioningUpdates build 2>&1 | filter || rc=1
  # Finder/Dock cache icons per bundle and only notice changes when the bundle's own mtime moves.
  APP=.build/dd-$NAME/Build/Products/Debug/DeStream.app
  if [[ -d $APP ]]; then
    touch "$APP"
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" >/dev/null 2>&1
  fi
fi
if [[ $WHAT == ios || $WHAT == all ]]; then
  xcodebuild "${COMMON[@]}" -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/dd-$NAME-ios build 2>&1 | filter || rc=1
fi
if [[ $WHAT == test || $WHAT == all ]]; then
  xcodebuild "${COMMON[@]}" -destination 'platform=macOS' -derivedDataPath .build/dd-$NAME test 2>&1 | filter || rc=1
fi
exit $rc
