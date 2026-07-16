# iADB

The repository currently contains the ADB protocol implementation and a small,
UI-independent business layer. The presentation layer was intentionally removed
and will be rebuilt from scratch.

## Business modules

- Wireless discovery, pairing, connection, and saved devices
- Device information
- Installed-app operations
- Remote file operations
- Shell v2 command streaming and history
- Logcat streaming
- Screenshot capture and local persistence

`iADBApp.swift` contains only an `EmptyView` bootstrap so the application target
continues to compile while the new UI is being designed.

## Build and test

```sh
xcodegen generate
xcodebuild \
  -project iADB.xcodeproj \
  -scheme iADB \
  -destination 'platform=iOS Simulator,name=iADB Audit iPad mini' \
  test CODE_SIGNING_ALLOWED=NO
```
