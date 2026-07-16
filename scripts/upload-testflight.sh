#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

: "${MARKETING_VERSION:?MARKETING_VERSION is required}"
: "${BUILD_NUMBER:?BUILD_NUMBER is required}"
: "${APPLE_TEAM_ID:?APPLE_TEAM_ID is required}"
: "${ASC_KEY_PATH:?ASC_KEY_PATH is required}"
: "${ASC_KEY_ID:?ASC_KEY_ID is required}"
: "${ASC_ISSUER_ID:?ASC_ISSUER_ID is required}"

signing_mode="${SIGNING_MODE:-automatic}"

if [[ ! "$MARKETING_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "MARKETING_VERSION must use MAJOR.MINOR.PATCH" >&2
  exit 1
fi
if [[ ! "$BUILD_NUMBER" =~ ^[0-9]+([.][0-9]+){0,2}$ ]]; then
  echo "BUILD_NUMBER must contain one to three numeric components" >&2
  exit 1
fi
if [[ ! -s "$ASC_KEY_PATH" ]]; then
  echo "App Store Connect API key not found at $ASC_KEY_PATH" >&2
  exit 1
fi
if [[ "$signing_mode" != "automatic" && "$signing_mode" != "manual" ]]; then
  echo "SIGNING_MODE must be automatic or manual" >&2
  exit 1
fi

output_directory="build/testflight"
archive_path="$output_directory/iADB.xcarchive"
export_options="$output_directory/ExportOptions.plist"
rm -rf "$output_directory"
mkdir -p "$output_directory"

authentication_options=(
  -authenticationKeyPath "$ASC_KEY_PATH"
  -authenticationKeyID "$ASC_KEY_ID"
  -authenticationKeyIssuerID "$ASC_ISSUER_ID"
)
archive_authentication_options=("${authentication_options[@]}")
signing_settings=(CODE_SIGN_STYLE=Automatic)
if [[ "$signing_mode" == "automatic" ]]; then
  archive_authentication_options=(-allowProvisioningUpdates "${authentication_options[@]}")
else
  : "${SIGNING_KEYCHAIN_PATH:?SIGNING_KEYCHAIN_PATH is required for manual signing}"
  : "${SIGNING_PROFILE_NAME:?SIGNING_PROFILE_NAME is required for manual signing}"
  : "${SIGNING_CERTIFICATE_IDENTITY:?SIGNING_CERTIFICATE_IDENTITY is required for manual signing}"
  signing_settings=(
    CODE_SIGN_STYLE=Manual
    "CODE_SIGN_IDENTITY=$SIGNING_CERTIFICATE_IDENTITY"
    "PROVISIONING_PROFILE_SPECIFIER=$SIGNING_PROFILE_NAME"
    "OTHER_CODE_SIGN_FLAGS=--keychain $SIGNING_KEYCHAIN_PATH"
  )
fi

set -o pipefail
xcodebuild archive \
  -project iADB.xcodeproj \
  -scheme iADB \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$archive_path" \
  -skipMacroValidation \
  -skipPackagePluginValidation \
  "${archive_authentication_options[@]}" \
  DEVELOPMENT_TEAM="$APPLE_TEAM_ID" \
  MARKETING_VERSION="$MARKETING_VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  "${signing_settings[@]}" \
  2>&1 | tee "$output_directory/archive.log"

if [[ "$signing_mode" == "automatic" ]]; then
  cat > "$export_options" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>app-store-connect</string>
  <key>destination</key>
  <string>upload</string>
  <key>teamID</key>
  <string>$APPLE_TEAM_ID</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>manageAppVersionAndBuildNumber</key>
  <false/>
  <key>uploadSymbols</key>
  <true/>
</dict>
</plist>
PLIST
else
  cat > "$export_options" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>app-store-connect</string>
  <key>destination</key>
  <string>upload</string>
  <key>teamID</key>
  <string>$APPLE_TEAM_ID</string>
  <key>signingStyle</key>
  <string>manual</string>
  <key>signingCertificate</key>
  <string>$SIGNING_CERTIFICATE_IDENTITY</string>
  <key>provisioningProfiles</key>
  <dict>
    <key>com.iadb.app</key>
    <string>$SIGNING_PROFILE_NAME</string>
  </dict>
  <key>manageAppVersionAndBuildNumber</key>
  <false/>
  <key>uploadSymbols</key>
  <true/>
</dict>
</plist>
PLIST
fi

xcodebuild -exportArchive \
  -archivePath "$archive_path" \
  -exportPath "$output_directory/export" \
  -exportOptionsPlist "$export_options" \
  "${authentication_options[@]}" \
  2>&1 | tee "$output_directory/upload.log"

echo "Uploaded iADB $MARKETING_VERSION ($BUILD_NUMBER) to App Store Connect"
