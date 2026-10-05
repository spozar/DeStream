#!/bin/zsh
# Build DeStream for the first paired, available iPhone and install + launch it (works over Wi-Fi).
set -e
cd "$(dirname "$0")/.."
xcodegen generate -q >/dev/null 2>&1 || true
COREDEVICE_ID=$(xcrun devicectl list devices 2>/dev/null | awk '/iPhone/ && /available/ {for(i=1;i<=NF;i++) if ($i ~ /^[0-9A-F-]{36}$/) {print $i; exit}}')
[[ -z $COREDEVICE_ID ]] && { echo "No available iPhone found. Unlock it and keep it on the same Wi-Fi (or plug it in)."; exit 1; }
UDID=$(xcodebuild -scheme DeStream -showdestinations 2>/dev/null | sed -n 's/.*platform:iOS, arch:arm64, id:\([^,]*\),.*/\1/p' | head -1)
xcodebuild -scheme DeStream -clonedSourcePackagesDirPath .build/spm -skipPackageUpdates \
  -destination "platform=iOS,id=$UDID" -derivedDataPath .build/dd-device -allowProvisioningUpdates build \
  | grep -E "error:|BUILD"
xcrun devicectl device install app --device "$COREDEVICE_ID" .build/dd-device/Build/Products/Debug-iphoneos/DeStream.app >/dev/null
xcrun devicectl device process launch --device "$COREDEVICE_ID" se.mediaempire.DeStream >/dev/null
echo "Installed and launched DeStream on the iPhone."
