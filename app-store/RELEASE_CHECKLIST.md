# iADB App Store Release Checklist

Use this checklist for each App Store build. Keep the checked copy with the release record.

## Offline gate

- [ ] Run `./scripts/validate-app-store-release.sh` from the repository root.
- [ ] Resolve each `FAIL`. Read each `WARN` and record the decision in the release ticket.
- [ ] Confirm that the commit contains the metadata, icon, screenshots, privacy manifest, privacy policy, support page, and review notes used for submission.
- [ ] Confirm that the release commit and dependency lock file match the archive.

## Identity, version, and signing

- [ ] Confirm that App Store Connect and the archive use bundle ID `com.iadb.app`.
- [ ] Confirm that `MARKETING_VERSION` matches the App Store version and that `CURRENT_PROJECT_VERSION` exceeds every uploaded build for that version.
- [ ] Select the registered Apple Developer team through release configuration or the CI secret.
- [ ] Confirm that the App Store distribution certificate and provisioning profile remain valid through upload.
- [ ] Archive the Release scheme for `generic/platform=iOS`; do not upload an unsigned IPA.
- [ ] Validate the exported archive with Xcode Organizer or `xcrun altool` before selecting it in App Store Connect.

## Binary inspection

- [ ] Confirm that the archive contains `Assets.car`, the AppIcon declarations, and the 1024 × 1024 icon.
- [ ] Confirm that the app bundle root contains `PrivacyInfo.xcprivacy`.
- [ ] Inspect the archived `Info.plist`: bundle ID, `1.0.0` version, build number, Local Network text, Photos add-only text, Bonjour services, and encryption flag.
- [ ] Confirm that the archive has no DEBUG entitlement, debug server, screenshot fixture, simulator architecture, personal path, or public ADB payload logging.
- [ ] Launch the archived configuration on an iPhone and an iPad through TestFlight.

## Privacy and export compliance

- [ ] Compare runtime data handling with `PRIVACY.md`: no account, ads, analytics, tracking, or developer-operated server.
- [ ] Confirm that App Store Connect App Privacy says no data collection only if the Release build and every bundled SDK still match that answer.
- [ ] Confirm that the privacy manifest declares the required reason for direct `UserDefaults` access.
- [ ] Publish the privacy URL and verify it without a GitHub login or repository access.
- [ ] Verify that the support URL gives users a working contact route and any contact details required in the selected sales regions.
- [ ] Complete App Store Connect export-compliance questions for ADB TLS, RSA, SPAKE2, and AES-GCM.
- [ ] Attach approved encryption documentation to the build when App Store Connect requests it. Keep `ITSAppUsesNonExemptEncryption` aligned with that decision.

Apple references:

- [Manage app privacy](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy/)
- [Export compliance](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance)

## Product metadata

- [ ] Confirm the name, subtitle, description, promotional text, keywords, release notes, and URLs against the shipped feature set.
- [ ] Remove claims for any feature disabled in the selected build.
- [ ] Confirm that keywords contain more than two characters, stay within 100 bytes, and do not name competing apps or companies.
- [ ] Check English spelling and read the rendered App Store product page on iPhone and iPad.
- [ ] Complete category, age rating, content rights, availability, pricing, agreements, and regional compliance fields.

Apple publishes the current field rules in [App information](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information/) and [Platform version information](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information/).

## Icon and screenshots

- [ ] Confirm that AppIcon is a 1024 × 1024, 8-bit sRGB PNG without alpha.
- [ ] Provide one to ten iPhone 6.9-inch screenshots at an accepted size. This repository targets 1320 × 2868 portrait PNG.
- [ ] Provide one to ten iPad 13-inch screenshots. This repository targets 2752 × 2064 landscape PNG.
- [ ] Use the six-screen order documented in `app-store/README.md`, unless the release ticket records a shorter product story.
- [ ] Inspect every pixel for a personal address, device serial, pairing code, ADB key, filename, installed-app list, notification, carrier name, or unredacted Logcat line.
- [ ] Confirm that each screenshot shows the submitted UI and uses fictional data from the DEBUG-only fixture.
- [ ] Check status bars, cropping, text contrast, and the absence of transparent pixels.

Apple lists current dimensions and the one-to-ten limit in [Screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/).

## Hardware regression

- [ ] Test pairing, connecting, reconnecting, forgetting, and identity reset with Android 11 and the current Android release.
- [ ] Test one Google device and one manufacturer-modified Android build when hardware permits.
- [ ] Test wrong and expired pairing codes, different pairing and connection ports, Local Network denial, device disappearance, Wi-Fi changes, backgrounding, and app relaunch.
- [ ] Test Files with `/sdcard`, symlinks, spaces, quotes, an empty folder, collisions, a large transfer, cancellation, and Android permission denial.
- [ ] Test Apps with valid and invalid APKs, install failure, uninstall failure, launch, force stop, clear data, filtering, and no results.
- [ ] Test Shell with finite output, large output, a long-running command, stop, nonzero exit status, disconnect, and reconnect.
- [ ] Test Logcat start, stop, pause, clear, filter, export, quiet-device timeout, simultaneous tab activity, and reconnect.
- [ ] Test screenshot capture, repeated capture, Photos denial, Save to Photos, share, delete, and storage failure.
- [ ] Check memory and energy during a large transfer, Shell output, and Logcat streaming.

## UI and accessibility

- [ ] Complete every tab on iPhone and iPad in portrait and landscape.
- [ ] Verify empty, loading, permission-denied, offline, timeout, and server-error states.
- [ ] Confirm that each error offers retry, settings, cancel, reconnect, or another route out.
- [ ] Test VoiceOver labels and order, Dynamic Type, Reduce Motion, Increase Contrast, keyboard navigation, and 44-point touch targets.
- [ ] Confirm that modal sheets expose a dismiss action and that destructive actions ask for confirmation.

## App Review information

- [ ] Paste `app-store/metadata/en-US/review_notes.txt` into App Review Notes.
- [ ] Add the current reviewer contact name, monitored email address, and telephone number.
- [ ] Record the exact Android model, Android version, and Wireless debugging settings used in the review demonstration.
- [ ] Attach a demo video that shows Android Wireless debugging setup, pairing, connection, and one command result. If video cannot reproduce the environment, arrange suitable Android hardware with App Review.
- [ ] Attach the demo video or hardware instructions manually before pressing Submit for Review. Do not leave a placeholder URL in Review Notes.
- [ ] Confirm that Review Notes explain that the pairing port differs from the connection port.
- [ ] Confirm that Review Notes state that the screenshot fixture does not ship in Release.

Apple asks developers to provide special instructions and to prepare a demo video or hardware for an environment that reviewers cannot reproduce. See [App Review](https://developer.apple.com/app-store/review/).

## TestFlight and submission

- [ ] Install the processed TestFlight build on a clean iPhone and iPad.
- [ ] Repeat the hardware regression against that processed build.
- [ ] Check TestFlight crashes, hangs, memory terminations, and console privacy before selecting the build.
- [ ] Confirm that product metadata, screenshots, privacy answers, export status, review contact, notes, and attachment belong to the selected build.
- [ ] Choose manual release for the first version so the team can inspect approval before distribution.
- [ ] Save the App Store Connect validation result, build ID, archive checksum, and final checklist in the release record.
