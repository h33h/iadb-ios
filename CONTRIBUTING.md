# Contributing

## Local Setup

1. Install dependencies:

```bash
brew install xcodegen
```

2. Generate the project:

```bash
xcodegen generate
```

3. Open `iADB.xcodeproj` and work in the `iADB` scheme.

## Before Opening A Pull Request

1. Regenerate the project if `project.yml` changed.
2. Run the test suite.
3. Keep changes scoped to one problem.
4. Include screenshots for UI changes when useful.
5. Describe user-facing behavior changes clearly.

## Test Command

```bash
xcodebuild test \
  -project iADB.xcodeproj \
  -scheme iADB \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

## Android Emulator Debug Checks

For production-like manual checks from the iOS Simulator, use the `iADB Android Emulator` scheme after running `xcodegen generate`.

Debug builds expose a hidden connection-screen debug modal on long press. Enable `Use Android Emulator`, set host/port, close the modal, and connect through the live ADB client after the configured ADB endpoint is reachable.

## Pull Request Notes

- Link the issue when applicable.
- Call out risks, edge cases, or follow-up work.
- Mention any manual verification done on device.
