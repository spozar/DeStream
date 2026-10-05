#!/bin/zsh
# Archive DeStream for macOS and export it signed with Developer ID (ready to notarize; does not submit).
# Output: .build/export-mac/DeStream.app
set -e
set -o pipefail
cd "$(dirname "$0")/.."
xcodegen generate -q >/dev/null 2>&1 || xcodegen generate
ARCHIVE=.build/DeStream-mac.xcarchive
OPTIONS=.build/ExportOptions-mac.plist
cat > $OPTIONS <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>developer-id</string>
	<key>signingStyle</key><string>automatic</string>
	<key>teamID</key><string>99476Z45K6</string>
</dict>
</plist>
PLIST
xcodebuild -scheme DeStream -clonedSourcePackagesDirPath .build/spm -skipPackageUpdates \
  -destination 'generic/platform=macOS' -derivedDataPath .build/dd-archive -allowProvisioningUpdates \
  archive -archivePath $ARCHIVE | grep -E "error:|ARCHIVE"
rm -rf .build/export-mac
xcodebuild -exportArchive -archivePath $ARCHIVE -exportPath .build/export-mac -exportOptionsPlist $OPTIONS \
  -allowProvisioningUpdates | grep -E "error|EXPORT"
