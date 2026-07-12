# App Store release setup

The `App Store Release` workflow creates a signed archive, exports an App Store IPA,
validates it with App Store Connect, and uploads it to TestFlight for version tags.
Tags must use a numeric version such as `v1.0.0`. Manual runs accept the version as an
input. Every workflow run and retry receives a unique build number.

Configure these GitHub Actions secrets before running it:

- `APPLE_TEAM_ID`
- `BUILD_CERTIFICATE_BASE64` — base64-encoded Apple Distribution `.p12`
- `P12_PASSWORD`
- `BUILD_PROVISION_PROFILE_BASE64` — base64-encoded App Store provisioning profile for `com.iadb.app`
- `APP_STORE_CONNECT_API_KEY_ID`
- `APP_STORE_CONNECT_ISSUER_ID`
- `APP_STORE_CONNECT_API_PRIVATE_KEY_BASE64` — base64-encoded App Store Connect `.p8`

Before tagging a release, complete App Store Connect metadata, privacy labels,
export-compliance documentation, iPhone/iPad screenshots, support and privacy-policy
URLs, and reviewer instructions for the Android Wireless Debugging hardware flow.

Suggested repository-hosted URLs after the `main` branch is public:

- Privacy policy: `https://github.com/h33h/iadb-ios/blob/main/PRIVACY.md`
- Support: `https://github.com/h33h/iadb-ios/issues`

Paste the device setup from `docs/APP_REVIEW_NOTES.md` into App Review Information.
