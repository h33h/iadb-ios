#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_ROOT="${IADB_SCREENSHOT_WORK_ROOT:-$ROOT/.build/app-store-screenshots}"
TARGETS="${IADB_SCREENSHOT_TARGETS:-all}"
RUNTIME_ID="${IADB_SCREENSHOT_RUNTIME_ID:-}"
PROJECT_PATH="${IADB_SCREENSHOT_PROJECT_PATH:-$ROOT/iADB.xcodeproj}"
STATUS_BAR_TIME="${IADB_SCREENSHOT_STATUS_BAR_TIME:-2026-07-12T09:41:00.000+03:00}"

IPHONE_NAME="${IADB_SCREENSHOT_IPHONE_NAME:-iADB App Store iPhone 6.9}"
IPAD_NAME="${IADB_SCREENSHOT_IPAD_NAME:-iADB App Store iPad 13}"
IPHONE_TYPE="${IADB_SCREENSHOT_IPHONE_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max}"
IPAD_TYPE="${IADB_SCREENSHOT_IPAD_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M4-8GB}"

TEST_IDENTIFIER="iADBUITests/AppStoreScreenshotTests/testCaptureAppStoreScreenshots"

fail() {
  echo "error: $*" >&2
  exit 1
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || fail "Required tool '$1' was not found"
}

device_type_exists() {
  xcrun simctl list devicetypes | grep -Fq "($1)"
}

find_device() {
  local name="$1"
  xcrun simctl list devices available | awk -v name="$name" '
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      prefix = name " ("
      if (index(line, prefix) == 1) {
        rest = substr(line, length(prefix) + 1)
        split(rest, fields, ")")
        print fields[1]
        exit
      }
    }
  '
}

get_or_create_device() {
  local name="$1"
  local type="$2"
  local udid

  udid="$(find_device "$name")"
  if [[ -z "$udid" ]]; then
    udid="$(xcrun simctl create "$name" "$type" "$RUNTIME_ID")"
  fi
  printf '%s\n' "$udid"
}

prepare_status_bar() {
  local udid="$1"
  xcrun simctl boot "$udid" >/dev/null 2>&1 || true
  xcrun simctl bootstatus "$udid" -b
  xcrun simctl status_bar "$udid" clear
  xcrun simctl status_bar "$udid" override \
    --time "$STATUS_BAR_TIME" \
    --dataNetwork wifi \
    --wifiMode active \
    --wifiBars 3 \
    --batteryState charged \
    --batteryLevel 100
}

capture_target() {
  local label="$1"
  local udid="$2"
  local width="$3"
  local height="$4"
  local output_directory="$5"
  local result_bundle="$WORK_ROOT/$label.xcresult"
  local attachments_directory="$WORK_ROOT/$label-attachments"
  local derived_data="$WORK_ROOT/DerivedData-$label"

  rm -rf -- "$result_bundle" "$attachments_directory" "$derived_data"
  prepare_status_bar "$udid"

  echo "Capturing $label screenshots on $udid"
  xcodebuild test \
    -project "$PROJECT_PATH" \
    -scheme iADB \
    -destination "platform=iOS Simulator,id=$udid" \
    -destination-timeout 120 \
    -derivedDataPath "$derived_data" \
    -resultBundlePath "$result_bundle" \
    -only-testing:"$TEST_IDENTIFIER" \
    -parallel-testing-enabled NO \
    -maximum-concurrent-test-simulator-destinations 1 \
    CODE_SIGNING_ALLOWED=NO \
    COMPILER_INDEX_STORE_ENABLE=NO

  mkdir -p "$attachments_directory"
  xcrun xcresulttool export attachments \
    --path "$result_bundle" \
    --output-path "$attachments_directory"

  xcrun swift "$ROOT/scripts/export-app-store-screenshots.swift" \
    "$attachments_directory" \
    "$output_directory" \
    "$width" \
    "$height"
}

cleanup() {
  if [[ -n "${IPHONE_UDID:-}" ]]; then
    xcrun simctl status_bar "$IPHONE_UDID" clear >/dev/null 2>&1 || true
  fi
  if [[ -n "${IPAD_UDID:-}" ]]; then
    xcrun simctl status_bar "$IPAD_UDID" clear >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

require_tool xcodebuild
require_tool xcrun
require_tool awk
require_tool grep

case "$TARGETS" in
  all|iphone|ipad) ;;
  *) fail "IADB_SCREENSHOT_TARGETS must be all, iphone, or ipad" ;;
esac

if [[ -z "$RUNTIME_ID" ]]; then
  RUNTIME_ID="$(xcrun simctl list runtimes available | awk '/^iOS / { runtime = $NF } END { print runtime }')"
fi
[[ -n "$RUNTIME_ID" ]] || fail "No available iOS Simulator runtime was found"

mkdir -p "$WORK_ROOT"

if [[ "${IADB_SKIP_PROJECT_GENERATION:-0}" != "1" ]]; then
  "$ROOT/scripts/generate-project.sh"
fi
[[ -d "$PROJECT_PATH" ]] || fail "Xcode project not found: $PROJECT_PATH"

if [[ "$TARGETS" == "all" || "$TARGETS" == "iphone" ]]; then
  device_type_exists "$IPHONE_TYPE" || fail "Missing iPhone simulator type: $IPHONE_TYPE"
  IPHONE_UDID="$(get_or_create_device "$IPHONE_NAME" "$IPHONE_TYPE")"
  capture_target \
    "iphone-6.9" \
    "$IPHONE_UDID" \
    1320 \
    2868 \
    "$ROOT/app-store/screenshots/iphone-6.9"
fi

if [[ "$TARGETS" == "all" || "$TARGETS" == "ipad" ]]; then
  device_type_exists "$IPAD_TYPE" || fail "Missing iPad simulator type: $IPAD_TYPE"
  IPAD_UDID="$(get_or_create_device "$IPAD_NAME" "$IPAD_TYPE")"
  capture_target \
    "ipad-13" \
    "$IPAD_UDID" \
    2064 \
    2752 \
    "$ROOT/app-store/screenshots/ipad-13"
fi

echo "App Store screenshot capture complete."
