# App Store Assets

This directory contains the source material for the iADB product page.

## Screenshot sets

- `screenshots/iphone-6.9`: 1320 × 2868 portrait PNG
- `screenshots/ipad-13`: 2752 × 2064 landscape PNG

Use the `--app-store-screenshots` launch argument. It loads fictional device
data and disables network access so captures never expose a real address,
serial number, package list, ADB key, or log entry.

The six screenshots follow this product story:

1. Android tools on your iPhone — connected device dashboard
2. Browse and manage files — `/sdcard/Download`
3. Run ADB shell anywhere — safe command, output, history, and pins
4. Inspect installed apps — search, filters, app actions
5. Find the signal in Logcat — clean fictional logs and filters
6. Capture and share the screen — gallery and viewer

## Capture rules

- Use only the deterministic demo fixture.
- Keep the status bar free of Focus, recording, and personal carrier state.
- Use one consistent light appearance across the complete screenshot set.
- Do not add an iPhone or iPad bezel.
- Export 8-bit sRGB PNG without alpha.
- Confirm every image dimension and scan visible text before upload.

App Store marketing headers can be composited after the raw in-app captures,
but the product UI must occupy at least 75 percent of the frame and remain an
accurate representation of the shipped app.

## Reproducible capture

Run from the repository root:

```sh
scripts/capture-app-store-screenshots.sh
```

The script regenerates the Xcode project, creates or reuses dedicated App
Store simulators, fixes the status bar at 9:41, and runs only
`AppStoreScreenshotTests`. It exports six stable attachments for Device,
Files, Console Shell, Apps, Console Logs, and Screens. The export is rejected
unless every PNG has the required dimensions, 8-bit components, and no alpha
channel. Existing output is replaced only after the complete set validates.

Useful overrides:

```sh
IADB_SCREENSHOT_TARGETS=iphone scripts/capture-app-store-screenshots.sh
IADB_SCREENSHOT_TARGETS=ipad scripts/capture-app-store-screenshots.sh
IADB_SKIP_PROJECT_GENERATION=1 scripts/capture-app-store-screenshots.sh
```

`IADB_SCREENSHOT_RUNTIME_ID`, `IADB_SCREENSHOT_IPHONE_TYPE`, and
`IADB_SCREENSHOT_IPAD_TYPE` can pin CI to installed simulator components.
`IADB_SCREENSHOT_STATUS_BAR_TIME` overrides the fixed ISO date and time.

## App icon

- `icon/AppIcon-1024.png` is the approved 1024 × 1024 sRGB master.
- `icon/PROMPT.md` records the generation brief and exclusions.
- `../iADB/Assets.xcassets/AppIcon.appiconset/AppIcon.png` must remain an exact
  copy of the approved master.

The source is full-bleed, opaque, and unmasked. Let iOS apply the platform
corner treatment; do not pre-round the artwork.
