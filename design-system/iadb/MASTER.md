# iADB Design System

## Direction

`Precision Utility` is a native iOS interface for managing one Android device
at a time. It should feel calm, trustworthy, and fast. Technical detail is
available when needed, but status and next actions come first.

Avoid hacker motifs, decorative terminal chrome, heavy glow, and custom fonts.
Use Apple platform conventions and SF Symbols throughout.

## Information architecture

The root tab bar contains five stable destinations:

1. Device
2. Files
3. Apps
4. Console
5. Screens

Device combines discovery, pairing, connection status, and device summary.
Console contains Shell and Logs behind a segmented control. Help, privacy,
licenses, support, and identity reset live in Settings.

The Device screen must not repeat Files, Apps, Console, or Screens navigation;
the persistent tab bar is the only top-level switcher.

## Type

- Use Dynamic Type and the system design for all navigation, labels, and body
  copy.
- Use the monospaced system design only for commands, output, paths, package
  names, ports, identifiers, timestamps, and raw properties.
- Use `monospacedDigit()` for changing metrics.
- Do not use fixed font sizes for user-facing text.

## Color

- Surfaces: dynamic `systemBackground`, `systemGroupedBackground`, and
  `secondarySystemGroupedBackground`.
- Brand/action: system blue with cyan as a restrained supporting accent.
- Connected/success: system green.
- Warning: system orange.
- Destructive/error: system red.
- Every status pairs color with an icon and a text label.
- Body text remains primary or secondary; do not render small body copy in a
  semantic status color.

## Spacing and shape

- Spacing scale: 4, 8, 12, 16, 20, 24, 32 points.
- Control radius: 10 points.
- Card radius: 16 points.
- Hero radius: 22 points.
- Minimum interactive target: 44 by 44 points.
- Cap readable content width on iPad instead of stretching phone layouts.

## Components

- `FeatureHeroCard`: current state, one primary action, optional secondary
  action.
- `AppCard`: grouped information or a tappable destination.
- `StatusBadge`: icon plus short status text.
- `MetricTile`: one label and one value; adaptive grid on regular width.
- `StatusBannerView`: one active operation or recovery message at a time.
- `EmptyState`: explanation plus a reachable primary action.
- Technical rows: human label first, copyable raw value second.

### Button hierarchy

- The visible bezel follows the label's intrinsic width; a 44 by 44 point hit
  region does not imply a full-width visible button.
- Use at most one prominent action in a card or control group. Use bordered,
  plain, toolbar, or menu actions for secondary commands.
- Reserve full-width buttons for a single required form submission or an
  accessibility fallback where the label cannot fit safely beside its peers.
- Keep peer actions the same control size. Communicate priority with style and
  role, not arbitrary width or height.
- Put frequent screen-level actions in the navigation toolbar and row-specific
  actions in a trailing menu.

## Interaction

- Show progress in the control that started the work and prevent duplicate
  submissions.
- Confirm destructive operations. Name the affected device, file, app, or
  screenshot in the confirmation.
- Keep success feedback visible long enough to understand the result.
- Preserve Console state when switching between Shell and Logs.
- Respect Reduce Motion. Use short opacity and position transitions only.

## Adaptive layout and accessibility

- Test compact iPhone portrait and landscape, iPad full screen and Stage
  Manager, light and dark appearances, Increased Contrast, and Accessibility
  XXXL.
- Replace dense horizontal rows with stacked layouts at accessibility sizes.
- Combine related labels and values into one VoiceOver element.
- Add labels to every icon-only action and accessibility actions for gestures.
- Never rely on color, swipe, context menus, pinch, or long press as the only
  way to complete a task.

## App Store assets

- Use fictional device names, addresses, identifiers, packages, logs, and
  screenshots in marketing captures.
- Never publish ADB keys, serial numbers, LAN addresses, or raw personal logs.
- Capture a consistent light-mode iPhone 6.9-inch set and iPad 13-inch set.
- The icon uses an abstract terminal bridge with two large connected forms.
  It must not resemble Apple hardware or include text, tiny nodes, or a
  pre-applied rounded mask.
