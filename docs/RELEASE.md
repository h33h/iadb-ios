# Release pipelines

GitHub Actions are split by purpose:

- `Pull Request Checks` builds the app and runs unit/UI tests for pull requests.
- `Unsigned IPA` builds an unsigned IPA on every push to `main` and on manual runs.
- `TestFlight` is a manual signed build and upload to App Store Connect.
- `Release` runs for `vMAJOR.MINOR.PATCH` tags, builds the unsigned IPA, uploads the same
  version/build to TestFlight, and publishes the unsigned IPA in a GitHub release.

The GitHub run ID plus retry attempt is used as `CURRENT_PROJECT_VERSION`. It is shared
by all jobs in a release, increases on a retry, and avoids collisions between the
standalone TestFlight and release workflows.

## Repository configuration

Add the public Apple Developer Team ID as a GitHub Actions repository variable:

- `APPLE_TEAM_ID`

Add these GitHub Actions secrets:

- `APP_STORE_CONNECT_API_KEY_ID`
- `APP_STORE_CONNECT_ISSUER_ID`
- `APP_STORE_CONNECT_API_PRIVATE_KEY` — the complete contents of the downloaded `.p8` file
- `SIGNING_REPO_SSH_KEY` — the application-specific read-only deploy key for the private
  `h33h/apple-signing-assets` repository

Certificates, P12 passwords, and provisioning profiles are stored only inside the
per-application age-encrypted bundle in `apple-signing-assets`. The deploy key also acts
as the age identity, so iADB can clone the central repository and decrypt only its own
bundle. No `.p12`, password, or `.mobileprovision` GitHub secret is needed.

Until `teams/Y743CZ57S7/apps/com.iadb.app/app-store/signing-assets.tar.age` exists, the
workflow uses App Store Connect automatic signing. Once the bundle is provisioned, the
same workflow switches to manual signing. A present but invalid bundle fails the build;
it never silently falls back.

Use an App Store Connect team API key with the Admin role and access to Certificates,
Identifiers & Profiles. The same API credentials are required by the central repository's
`Provision signing assets` workflow to issue and rotate encrypted assets.

## Running a release

For a TestFlight-only build, run the `TestFlight` workflow and enter the marketing version.
For a full release, push a semantic version tag:

```bash
git tag v1.0.0
git push origin v1.0.0
```

The GitHub release is created only after both the unsigned build and TestFlight upload
succeed.

Before tagging, complete App Store Connect metadata, privacy labels, export-compliance
documentation, screenshots, support and privacy-policy URLs, and reviewer instructions.
