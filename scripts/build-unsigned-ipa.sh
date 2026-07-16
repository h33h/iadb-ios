#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

build_number="${BUILD_NUMBER:-}"
requested_version="${MARKETING_VERSION:-}"
output_directory="${OUTPUT_DIRECTORY:-build/unsigned}"

if [[ ! "$build_number" =~ ^[0-9]+([.][0-9]+){0,2}$ ]]; then
  echo "BUILD_NUMBER must contain one to three numeric components" >&2
  exit 1
fi
if [[ -n "$requested_version" && ! "$requested_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "MARKETING_VERSION must use MAJOR.MINOR.PATCH" >&2
  exit 1
fi

rm -rf "$output_directory"
mkdir -p "$output_directory/products" "$output_directory/package/Payload"
output_directory="$(cd "$output_directory" && pwd)"

build_settings=(
  "CURRENT_PROJECT_VERSION=$build_number"
  CODE_SIGNING_ALLOWED=NO
  CODE_SIGNING_REQUIRED=NO
  CODE_SIGN_IDENTITY=
)
if [[ -n "$requested_version" ]]; then
  build_settings+=("MARKETING_VERSION=$requested_version")
fi

set -o pipefail
xcodebuild build \
  -project iADB.xcodeproj \
  -scheme iADB \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$output_directory/DerivedData" \
  -skipMacroValidation \
  -skipPackagePluginValidation \
  CONFIGURATION_BUILD_DIR="$output_directory/products" \
  "${build_settings[@]}" \
  2>&1 | tee "$output_directory/build.log"

app_path="$output_directory/products/iADB.app"
if [[ ! -d "$app_path" ]]; then
  echo "Unsigned application was not produced at $app_path" >&2
  exit 1
fi

packaged_app="$output_directory/package/Payload/iADB.app"
/usr/bin/ditto "$app_path" "$packaged_app"
find "$packaged_app" -type d -name _CodeSignature -prune -exec rm -rf {} +
find "$packaged_app" -type f -name embedded.mobileprovision -delete

if find "$packaged_app" \( -type d -name _CodeSignature -o -type f -name embedded.mobileprovision \) -print -quit | grep -q .; then
  echo "Signing material is still present in the unsigned application" >&2
  exit 1
fi

actual_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$packaged_app/Info.plist")
actual_build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$packaged_app/Info.plist")
ipa_path="$output_directory/iADB-$actual_version-$actual_build-unsigned.ipa"

(
  cd "$output_directory/package"
  /usr/bin/zip -qry "$ipa_path" Payload
)

echo "Created $ipa_path"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "ipa_path=$ipa_path" >> "$GITHUB_OUTPUT"
fi
