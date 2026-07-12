#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
xcodegen generate

if [[ -f Package.resolved ]]; then
  lock_directory="iADB.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
  mkdir -p "$lock_directory"
  cp Package.resolved "$lock_directory/Package.resolved"
fi
