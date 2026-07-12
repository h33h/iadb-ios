# iADB

[![Build & Test](https://github.com/h33h/iadb-ios/actions/workflows/build.yml/badge.svg)](https://github.com/h33h/iadb-ios/actions/workflows/build.yml)
[![App Store Release](https://github.com/h33h/iadb-ios/actions/workflows/release.yml/badge.svg)](https://github.com/h33h/iadb-ios/actions/workflows/release.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Run Android Wireless Debugging workflows from iPhone or iPad.

`iADB` is a native iOS app for discovering Android devices on the local network, pairing with Wireless Debugging, and using common ADB features without switching to a desktop machine.

## Highlights

- Native iOS app built with SwiftUI
- Wireless Debugging pairing flow with pairing code support
- Local network device discovery
- Quick reconnect to previously used devices
- Device info, files, apps, shell, logcat, and screenshots in one app
- CI for tests, signed App Store archives, validation, and TestFlight upload

## Features

- Discover Android devices on the same Wi-Fi network
- Pair with `Wireless debugging` using a pairing code
- Connect and reconnect to paired devices
- Browse device information
- Explore files on the device
- Inspect installed apps
- Run shell commands
- Read logcat output
- Capture screenshots

## Screenshots

All repository captures use the deterministic, fictional App Store fixture.

| Device | Files | Shell |
| --- | --- | --- |
| <img src="app-store/screenshots/iphone-6.9/01-device.png" alt="Connected Android device dashboard" width="220" /> | <img src="app-store/screenshots/iphone-6.9/02-files.png" alt="Android file manager" width="220" /> | <img src="app-store/screenshots/iphone-6.9/03-shell.png" alt="ADB Shell history and pinned commands" width="220" /> |

| Apps | Logs | Screens |
| --- | --- | --- |
| <img src="app-store/screenshots/iphone-6.9/04-apps.png" alt="Installed app library" width="220" /> | <img src="app-store/screenshots/iphone-6.9/05-logs.png" alt="Live filtered Logcat output" width="220" /> | <img src="app-store/screenshots/iphone-6.9/06-screens.png" alt="Android screenshot gallery" width="220" /> |

## Getting Started

### Requirements

- Xcode 26+
- iOS 17+
- Homebrew
- `xcodegen`

### Local Setup

1. Install `xcodegen`:

```bash
brew install xcodegen
```

2. Generate the Xcode project:

```bash
scripts/generate-project.sh
```

3. Open `iADB.xcodeproj` in Xcode.
4. Build and run the `iADB` scheme.

## Running Tests

```bash
scripts/generate-project.sh
xcodebuild test \
  -project iADB.xcodeproj \
  -scheme iADB \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max'
```

## Debug Android Emulator Mode

Debug builds include an Android Emulator panel under Device › Settings for production-like checks against a local emulator.

Use the `iADB Android Emulator` scheme or enable `Use Android Emulator` in that panel. When the configured ADB endpoint is reachable, iADB injects a synthetic discovered device. `ADBClient` stays live, so connect, shell, files, apps, logcat, and screenshots still use the real ADB protocol.

Defaults:

- Host: `127.0.0.1`
- Port: `5555`
- Launch argument: `--iadb-debug-android-emulator`
- Environment overrides: `IADB_DEBUG_ANDROID_HOST`, `IADB_DEBUG_ANDROID_PORT`

## How To Connect

1. Enable Developer Options on the Android device.
2. Enable `Wireless debugging`.
3. Open `Pair device with pairing code` on Android.
4. In `iADB`, choose the discovered device or use manual pairing.
5. Enter the pairing code and connect.

Both devices must be on the same Wi-Fi network.

## Tech Stack

- SwiftUI
- The Composable Architecture
- XcodeGen
- GitHub Actions

## CI

The repository includes GitHub Actions workflows for:

- build and test on pull requests and pushes to `main`
- signed App Store archive, validation, and optional TestFlight upload from version tags or a manual run

## Roadmap

- Expand connection diagnostics and recovery hints
- Improve file management workflows for larger transfers
- Add more automated coverage around device-specific edge cases
- Expand release automation for App Store metadata and screenshots

## Project Layout

- `iADB/` app source code
- `iADBTests/` unit and feature tests
- `.github/workflows/` CI pipelines

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for local setup and pull request expectations.

## License

Released under the [MIT License](LICENSE).
