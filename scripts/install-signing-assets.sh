#!/bin/bash
set -euo pipefail

: "${SIGNING_CERTIFICATE_PATH:?SIGNING_CERTIFICATE_PATH is required}"
: "${SIGNING_PROFILE_PATH:?SIGNING_PROFILE_PATH is required}"
: "${SIGNING_MANIFEST_PATH:?SIGNING_MANIFEST_PATH is required}"

for file in "$SIGNING_CERTIFICATE_PATH" "$SIGNING_PROFILE_PATH" "$SIGNING_MANIFEST_PATH"; do
  [[ -s "$file" ]] || { echo "Signing input is missing: $file" >&2; exit 1; }
done

p12_password=$(jq -er .p12_password "$SIGNING_MANIFEST_PATH")
profile_uuid=$(jq -er .profile_uuid "$SIGNING_MANIFEST_PATH")
profile_name=$(jq -er .profile_name "$SIGNING_MANIFEST_PATH")
echo "::add-mask::$p12_password"

keychain_path="$RUNNER_TEMP/app-signing.keychain-db"
keychain_password=$(uuidgen)
echo "::add-mask::$keychain_password"

security create-keychain -p "$keychain_password" "$keychain_path"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "keychain_path=$keychain_path" >> "$GITHUB_OUTPUT"
fi
security set-keychain-settings -lut 21600 "$keychain_path"
security unlock-keychain -p "$keychain_password" "$keychain_path"
security import "$SIGNING_CERTIFICATE_PATH" \
  -P "$p12_password" -A -t cert -f pkcs12 -k "$keychain_path"
security set-key-partition-list \
  -S apple-tool:,apple: -k "$keychain_password" "$keychain_path"
security list-keychains -d user -s "$keychain_path"

certificate_identity=$(
  openssl pkcs12 -in "$SIGNING_CERTIFICATE_PATH" -clcerts -nokeys \
    -passin "pass:$p12_password" 2>/dev/null |
    openssl x509 -fingerprint -sha1 -noout |
    cut -d= -f2 |
    tr -d ':'
)
security find-identity -v -p codesigning "$keychain_path" | grep -q "$certificate_identity" || {
  echo "Imported keychain does not contain the expected signing identity" >&2
  exit 1
}

profile_directory="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
mkdir -p "$profile_directory"
cp "$SIGNING_PROFILE_PATH" "$profile_directory/$profile_uuid.mobileprovision"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "profile_uuid=$profile_uuid"
    echo "profile_name=$profile_name"
    echo "certificate_identity=$certificate_identity"
  } >> "$GITHUB_OUTPUT"
fi
