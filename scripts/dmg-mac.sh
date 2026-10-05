#!/bin/zsh
# Build a Developer ID–signed DeStream for sharing, without iCloud (that needs a provisioning profile).
# Output: dist/DeStream-<version>.zip and dist/DeStream-<version>.dmg
#
# Notarizes and staples when either is set:
#   NOTARY_PROFILE                                   a `notarytool store-credentials` profile (local)
#   NOTARY_APPLE_ID + NOTARY_TEAM_ID + NOTARY_PASSWORD  an app-specific password (CI)
# CODESIGN_IDENTITY overrides the Developer ID certificate name.
set -e
set -o pipefail
cd "$(dirname "$0")/.."
xcodegen generate -q >/dev/null 2>&1 || xcodegen generate
IDENTITY="${CODESIGN_IDENTITY:-Developer ID Application: Mediaempire Group AB (99476Z45K6)}"
# The same certificate can be listed more than once (several keychains), which makes the name ambiguous to codesign.
IDENTITY_HASH=$(security find-identity -v -p codesigning | awk -v id="\"$IDENTITY\"" 'index($0, id) { print $2; exit }')
[[ -n $IDENTITY_HASH ]] || { echo "No codesigning identity named \"$IDENTITY\" in the keychain." >&2; exit 1 }
ARCHIVE=.build/DeStream-dmg.xcarchive
EXPORT=.build/export-dmg
OPTIONS=.build/ExportOptions-dmg.plist

xcodebuild -scheme DeStream -clonedSourcePackagesDirPath .build/spm -skipPackageUpdates \
  -destination 'generic/platform=macOS' -derivedDataPath .build/dd-dmg \
  archive -archivePath $ARCHIVE \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" CODE_SIGN_ENTITLEMENTS= PROVISIONING_PROFILE_SPECIFIER= \
  | grep -E "error:|ARCHIVE"

cat > $OPTIONS <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>developer-id</string>
	<key>signingStyle</key><string>manual</string>
	<key>signingCertificate</key><string>Developer ID Application</string>
	<key>teamID</key><string>99476Z45K6</string>
</dict>
</plist>
PLIST
rm -rf $EXPORT
xcodebuild -exportArchive -archivePath $ARCHIVE -exportPath $EXPORT -exportOptionsPlist $OPTIONS | grep -E "error|EXPORT"
APP=$EXPORT/DeStream.app
codesign --verify --deep --strict $APP

if [[ -n $NOTARY_PROFILE ]]; then
  NOTARY_AUTH=(--keychain-profile "$NOTARY_PROFILE")
elif [[ -n $NOTARY_APPLE_ID && -n $NOTARY_TEAM_ID && -n $NOTARY_PASSWORD ]]; then
  NOTARY_AUTH=(--apple-id "$NOTARY_APPLE_ID" --team-id "$NOTARY_TEAM_ID" --password "$NOTARY_PASSWORD")
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" $APP/Contents/Info.plist)
mkdir -p dist
ZIP=dist/DeStream-$VERSION.zip
DMG=dist/DeStream-$VERSION.dmg

# The app is notarized on its own first so the copy inside both the zip and the image is stapled and opens offline.
rm -f $ZIP
ditto -c -k --keepParent $APP $ZIP
if (( ${#NOTARY_AUTH} )); then
  xcrun notarytool submit $ZIP "${NOTARY_AUTH[@]}" --wait
  xcrun stapler staple $APP
  rm -f $ZIP
  ditto -c -k --keepParent $APP $ZIP
fi

STAGE=.build/dmg-stage
rm -rf $STAGE && mkdir -p $STAGE && rm -f $DMG
cp -R $APP $STAGE/
ln -s /Applications $STAGE/Applications
hdiutil create -volname DeStream -srcfolder $STAGE -format UDZO -ov $DMG >/dev/null
codesign --sign $IDENTITY_HASH --timestamp $DMG

if (( ${#NOTARY_AUTH} )); then
  xcrun notarytool submit $DMG "${NOTARY_AUTH[@]}" --wait
  xcrun stapler staple $DMG
  spctl --assess --type execute -v $APP
  spctl --assess --type open --context context:primary-signature -v $DMG
else
  echo "Not notarized (set NOTARY_PROFILE, or NOTARY_APPLE_ID/NOTARY_TEAM_ID/NOTARY_PASSWORD)."
fi
echo "Built $ZIP and $DMG"
