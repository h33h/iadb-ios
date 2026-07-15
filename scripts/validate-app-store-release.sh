#!/bin/bash

set -o pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

passed=0
warned=0
failed=0

pass() { passed=$((passed + 1)); printf 'PASS  %s\n' "$1"; }
warn() { warned=$((warned + 1)); printf 'WARN  %s\n' "$1"; }
fail() { failed=$((failed + 1)); printf 'FAIL  %s\n' "$1"; }

need() {
  test -f "$1" && return 0
  fail "Missing file: $1"
  return 1
}

value() {
  local result
  result=$(<"$1")
  printf '%s' "$result"
}

characters() { LC_ALL=en_US.UTF-8 wc -m | tr -d '[:space:]'; }
bytes() { LC_ALL=C wc -c | tr -d '[:space:]'; }
raw() { plutil -extract "$2" raw -o - "$1" 2>/dev/null; }
json() { plutil -extract "$2" json -o - "$1" 2>/dev/null; }

yaml() {
  awk -v key="$1" '$1 == key ":" { gsub(/"/, "", $2); print $2; exit }' project.yml
}

property() {
  sips -g "$2" "$1" 2>/dev/null |
    awk -v key="$2" '$1 == key ":" { print $2; exit }'
}

check_text() {
  local file="$1" label="$2" minimum="$3" maximum="$4" unit="$5"
  local content count
  need "$file" || return
  iconv -f UTF-8 -t UTF-8 "$file" >/dev/null 2>&1 || {
    fail "$label is not valid UTF-8"
    return
  }
  content=$(value "$file")
  if test "$unit" = bytes; then
    count=$(printf '%s' "$content" | bytes)
  else
    count=$(printf '%s' "$content" | characters)
  fi
  if test "$count" -ge "$minimum" && test "$count" -le "$maximum"; then
    pass "$label length is $count $unit"
  else
    fail "$label length is $count $unit; expected $minimum to $maximum"
  fi
  grep -Eq '<[^>]+>' "$file" && fail "$label contains HTML-like markup"
}

check_url() {
  local file="$1" label="$2" url
  need "$file" || return
  url=$(value "$file")
  if [[ "$url" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?(/[^[:space:]]*)?$ ]] &&
    [[ ! "$url" =~ (example\.com|localhost|127\.0\.0\.1|0\.0\.0\.0) ]] &&
    [[ "$url" != *"@"* ]]; then
    pass "$label has a public HTTPS shape"
  else
    fail "$label must be one public HTTPS URL without placeholders"
  fi
}

check_metadata() {
  local file found=0 duplicate keyword
  printf '\nMetadata\n'
  check_text app-store/metadata/en-US/name.txt "App name" 2 30 characters
  check_text app-store/metadata/en-US/subtitle.txt "Subtitle" 1 30 characters
  check_text app-store/metadata/en-US/promotional_text.txt "Promotional text" 0 170 characters
  check_text app-store/metadata/en-US/description.txt "Description" 1 4000 characters
  check_text app-store/metadata/en-US/keywords.txt "Keywords" 1 100 bytes
  check_text app-store/metadata/en-US/release_notes.txt "Release notes" 1 4000 characters
  check_text app-store/metadata/en-US/review_notes.txt "Review notes" 1 4000 bytes
  check_url app-store/metadata/en-US/support_url.txt "Support URL"
  check_url app-store/metadata/en-US/marketing_url.txt "Marketing URL"
  check_url app-store/metadata/en-US/privacy_url.txt "Privacy URL"

  duplicate=$(tr ',' '\n' < app-store/metadata/en-US/keywords.txt | sort | uniq -d)
  test -z "$duplicate" && pass "Keywords are unique" || fail "Keywords contain duplicates"
  while IFS= read -r keyword; do
    test "$(printf '%s' "$keyword" | characters)" -gt 2 ||
      fail "Keyword '$keyword' must contain more than two characters"
  done < <(tr ',' '\n' < app-store/metadata/en-US/keywords.txt)
  grep -Eq '(^,|,$|,[[:space:]]|[[:space:]],)' app-store/metadata/en-US/keywords.txt &&
    fail "Keywords contain an empty term or comma-adjacent whitespace"

  for file in app-store/metadata/en-US/*.txt PRIVACY.md SUPPORT.md; do
    test -f "$file" || continue
    if grep -Eiq '(^|[^[:alnum:]_])(TODO|TBD|FIXME|CHANGEME)([^[:alnum:]_]|$)|YOUR[_ -](APP|COMPANY|NAME|URL|EMAIL)|example\.com|lorem ipsum|test@example' "$file"; then
      fail "$file contains placeholder text"
      found=1
    fi
    if grep -Eq 'BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{20,}|Authorization:[[:space:]]*Bearer' "$file"; then
      fail "$file may contain a credential"
      found=1
    fi
    if grep -Eq '(^|[^0-9])([0-9]{1,3}\.){3}[0-9]{1,3}([^0-9]|$)' "$file"; then
      fail "$file contains an IPv4 address"
      found=1
    fi
  done
  test "$found" -eq 0 &&
    pass "Release text has no known placeholders, IP addresses, or credentials"
  warn "Open each public URL before submission; this script makes no network requests"
}

check_identity() {
  local bundle version build display store origin marketing
  printf '\nRelease identity\n'
  need project.yml || return
  need iADB/Info.plist || return
  bundle=$(yaml PRODUCT_BUNDLE_IDENTIFIER)
  version=$(yaml MARKETING_VERSION)
  build=$(yaml CURRENT_PROJECT_VERSION)
  if [[ "$bundle" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]] &&
    [[ ! "$bundle" =~ (example|yourcompany|placeholder|tests|uitests) ]]; then
    pass "Bundle identifier is $bundle"
  else
    fail "Bundle identifier '$bundle' is not release-safe"
  fi
  [[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] &&
    pass "Marketing version is $version" ||
    fail "MARKETING_VERSION '$version' needs three numeric components"
  [[ "$build" =~ ^[1-9][0-9]*$ ]] &&
    pass "Build number is $build" ||
    fail "CURRENT_PROJECT_VERSION '$build' is not a positive integer"
  if test "$(raw iADB/Info.plist CFBundleIdentifier)" = '$(PRODUCT_BUNDLE_IDENTIFIER)' &&
    test "$(raw iADB/Info.plist CFBundleShortVersionString)" = '$(MARKETING_VERSION)' &&
    test "$(raw iADB/Info.plist CFBundleVersion)" = '$(CURRENT_PROJECT_VERSION)'; then
    pass "Info.plist inherits release identity from build settings"
  else
    fail "Info.plist release substitutions are inconsistent"
  fi
  display=$(raw iADB/Info.plist CFBundleDisplayName)
  store=$(value app-store/metadata/en-US/name.txt)
  test "$display" = "$store" &&
    pass "Bundle display name matches App Store name" ||
    fail "Bundle display name differs from App Store name"
  grep -Fq 'TARGETED_DEVICE_FAMILY: "1,2"' project.yml &&
    pass "Target supports iPhone and iPad" ||
    fail "Target must support iPhone and iPad"
  if grep -Eq '^[[:space:]]+DEVELOPMENT_TEAM:' project.yml ||
    [[ "$DEVELOPMENT_TEAM" =~ ^[A-Z0-9]{10}$ ]]; then
    pass "A release signing team is configured"
  else
    warn "Supply a registered 10-character DEVELOPMENT_TEAM before archiving"
  fi
  origin=$(git config --get remote.origin.url 2>/dev/null | sed 's/\.git$//')
  marketing=$(value app-store/metadata/en-US/marketing_url.txt)
  test "$origin" = "$marketing" &&
    pass "Marketing URL matches the Git remote" ||
    warn "Confirm that Marketing URL points to the public release repository"
}

check_privacy() {
  local manifest=iADB/PrivacyInfo.xcprivacy info=iADB/Info.plist api bonjour encryption
  printf '\nPrivacy and permissions\n'
  need "$manifest" || return
  need "$info" || return
  need PRIVACY.md || return
  need SUPPORT.md || return
  plutil -lint "$manifest" "$info" >/dev/null 2>&1 &&
    pass "Privacy manifest and Info.plist are valid" ||
    fail "Privacy manifest or Info.plist is invalid"
  test "$(raw "$manifest" NSPrivacyTracking)" = false &&
    pass "Privacy manifest declares no tracking" ||
    fail "NSPrivacyTracking conflicts with the privacy policy"
  json "$manifest" NSPrivacyCollectedDataTypes >/dev/null &&
    pass "Collected-data declaration is present" ||
    fail "NSPrivacyCollectedDataTypes is missing"
  api=$(json "$manifest" NSPrivacyAccessedAPITypes)
  if rg -q 'UserDefaults' iADB -g '*.swift' &&
    [[ "$api" == *NSPrivacyAccessedAPICategoryUserDefaults* ]] &&
    [[ "$api" == *CA92.1* ]]; then
    pass "UserDefaults required-reason declaration is present"
  else
    fail "UserDefaults use and manifest reason do not match"
  fi
  grep -A1 -F 'path: iADB/PrivacyInfo.xcprivacy' project.yml |
    grep -Fq 'buildPhase: resources' &&
    pass "project.yml copies the privacy manifest" ||
    fail "project.yml does not copy the privacy manifest"
  if test -n "$(raw "$info" NSLocalNetworkUsageDescription)" &&
    test -n "$(raw "$info" NSPhotoLibraryAddUsageDescription)"; then
    pass "Local Network and Photos descriptions are present"
  else
    fail "A required permission description is missing"
  fi
  bonjour=$(json "$info" NSBonjourServices)
  [[ "$bonjour" == *_adb-tls-connect._tcp* ]] &&
    [[ "$bonjour" == *_adb-tls-pairing._tcp* ]] &&
    pass "ADB Bonjour services are declared" ||
    fail "ADB Bonjour declarations are incomplete"
  encryption=$(raw "$info" ITSAppUsesNonExemptEncryption)
  if test "$encryption" = true || test "$encryption" = false; then
    pass "ITSAppUsesNonExemptEncryption is a Boolean"
    warn "Record export compliance and attach any requested documents"
  else
    fail "ITSAppUsesNonExemptEncryption is missing or invalid"
  fi
}

validate_png() {
  local file="$1" label="$2" wanted_width="$3" wanted_height="$4"
  local format width height alpha bits profile
  format=$(property "$file" format)
  width=$(property "$file" pixelWidth)
  height=$(property "$file" pixelHeight)
  alpha=$(property "$file" hasAlpha)
  bits=$(property "$file" bitsPerSample)
  profile=$(property "$file" profile)
  if test "$format" = png &&
    test "$width" = "$wanted_width" &&
    test "$height" = "$wanted_height" &&
    test "$alpha" = no &&
    test "$bits" = 8 &&
    [[ "$profile" == sRGB* ]]; then
    pass "$label has valid size, color profile, and alpha: $(basename "$file")"
  else
    fail "$label has format=$format size=$width x $height alpha=$alpha bits=$bits profile=$profile: $file"
  fi
  strings "$file" 2>/dev/null |
    grep -Eiq '(/Users/|localhost|127\.0\.0\.1|0\.0\.0\.0|PRIVATE KEY|IADB_DEBUG_)' &&
    fail "$label embeds a local path, address, key, or debug marker: $file"
}

check_icon() {
  local contents=iADB/Assets.xcassets/AppIcon.appiconset/Contents.json filename icon
  printf '\nApp icon\n'
  need "$contents" || return
  filename=$(raw "$contents" images.0.filename)
  icon=iADB/Assets.xcassets/AppIcon.appiconset/$filename
  if test "$(raw "$contents" images.0.size)" = 1024x1024 &&
    test "$(raw "$contents" images.0.idiom)" = universal &&
    need "$icon"; then
    pass "Catalog references a universal 1024x1024 AppIcon"
    validate_png "$icon" "App icon" 1024 1024
  else
    fail "AppIcon catalog source is incomplete"
  fi
  grep -Fq 'ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon' project.yml &&
    grep -Fq 'path: iADB/Assets.xcassets' project.yml &&
    pass "project.yml compiles the AppIcon catalog" ||
    fail "project.yml does not compile the AppIcon catalog"
}

check_set() {
  local directory="$1" label="$2" width="$3" height="$4" count file
  if ! test -d "$directory"; then
    fail "Missing screenshot directory: $directory"
    return
  fi
  count=$(find "$directory" -maxdepth 1 -type f -iname '*.png' | wc -l | tr -d '[:space:]')
  if test "$count" -lt 1 || test "$count" -gt 10; then
    fail "$label set contains $count screenshots; expected 1 to 10"
    return
  fi
  pass "$label set contains $count screenshots"
  test "$count" -eq 6 || warn "$label set has $count images; app-store/README.md defines six"
  while IFS= read -r file; do
    validate_png "$file" "$label screenshot" "$width" "$height"
  done < <(find "$directory" -maxdepth 1 -type f -iname '*.png' -print | sort)
}

check_screenshots() {
  printf '\nScreenshots\n'
  check_set app-store/screenshots/iphone-6.9 "iPhone 6.9-inch" 1320 2868
  check_set app-store/screenshots/ipad-13 "iPad 13-inch" 2064 2752
  warn "Inspect screenshot pixels by eye; this offline validator does not run OCR"
}

for tool in awk find git grep iconv plutil rg sed sips sort strings tr uniq wc; do
  command -v "$tool" >/dev/null 2>&1 || fail "Required local tool is unavailable: $tool"
done
test "$failed" -eq 0 || exit 2

printf 'iADB App Store offline validation\nRepository: %s\n' "$ROOT"
check_metadata
check_identity
check_privacy
check_icon
check_screenshots
printf '\nSummary: %d passed, %d warnings, %d failures\n' "$passed" "$warned" "$failed"
test "$failed" -eq 0 || exit 1
printf 'Offline App Store release checks passed.\n'
