# mDNS Auto-Discovery Connection UI

## Overview

Replace manual IP/port entry with automatic Bonjour-based device discovery. A single list shows all devices found on the network — paired devices connect in one tap, unpaired devices open the pairing flow with pre-filled address.

## Architecture

### New Components

**`ADBDeviceDiscovery`** (`iADB/ADB/ADBDeviceDiscovery.swift`)
- Continuous `NWBrowser` scan for `_adb-tls-connect._tcp` services
- Emits `AsyncStream<[DiscoveredDevice]>` — list updates as devices appear/disappear
- Resolves each service endpoint to host:port via `NWConnection`
- Reuses patterns from existing `ADBServiceBrowser` (pairing discovery)

**`DiscoveredDevice` model** (`iADB/Models/DeviceInfo.swift`)
```swift
struct DiscoveredDevice: Identifiable, Equatable {
    let id: String          // mDNS service name (stable per device)
    var name: String        // device name from mDNS or pairing
    var host: String
    var port: UInt16
    var isPaired: Bool      // matched against PairedDevicesClient
}
```

**`PairedDevicesClient`** (`iADB/Dependencies/PairedDevicesClient.swift`)
- Replaces `SavedDevicesClient` for persistence
- Stores paired device records: `PairedDevice(name, publicKey, lastHost)`
- `publicKey` used to match discovered devices against paired ones
- `lastHost` informational only (not used for connecting — mDNS handles that)
- Backed by UserDefaults (same as current `SavedDevicesClient`)

**`DeviceDiscoveryClient`** (`iADB/Dependencies/DeviceDiscoveryClient.swift`)
- TCA dependency wrapping `ADBDeviceDiscovery`
- `start() -> AsyncStream<[DiscoveredDevice]>`
- `stop()`

### Modified Components

**`ConnectionFeature`** — major rework:
- State: `discoveredDevices: [DiscoveredDevice]` replaces `savedDevices`
- State: `isScanning: Bool`
- State: `connectionState`, `pairing` (kept)
- Remove: `hostInput`, `portInput`, `deviceNameInput`, `showingAddDevice`
- Actions: `startDiscovery`, `devicesUpdated([DiscoveredDevice])`, `connectToDevice(DiscoveredDevice)`, `showPairingForDevice(DiscoveredDevice)`, `showManualPairing`
- On `.onAppear` → start discovery, load paired devices, match
- On `.connectToDevice` → plain TCP → STLS → TLS (existing flow)
- On `.showPairingForDevice` → open pairing sheet with host/port pre-filled
- On pairing success → save to `PairedDevicesClient`, device becomes paired in list

**`PairingFeature`** — minor changes:
- Accept optional pre-filled `hostInput`/`portInput` from parent
- On success → return device name + public key to parent

**`ConnectionView`** — rewrite:
- Single list of discovered devices
- Each row: device icon, name, host:port, paired status indicator
- Paired (green dot) → tap to connect
- Not paired (orange dot) → tap opens pairing sheet
- Bottom: "Pair New Device" button for manual entry
- Footer: scanning indicator with animation
- Remove: Quick Connect section, Add Device sheet, saved devices management

**`PairingView`** — minor:
- IP/port fields pre-filled and optionally read-only when opened from device tap
- "Pair New Device" button opens with empty fields

**`SavedDevicesClient`** — remove (replaced by `PairedDevicesClient`)

**`SavedDevice` model** — remove (replaced by `DiscoveredDevice` + `PairedDevice`)

### Info.plist

Add `NSBonjourServices` array:
```xml
<key>NSBonjourServices</key>
<array>
    <string>_adb-tls-connect._tcp</string>
    <string>_adb-tls-pairing._tcp</string>
</array>
```

## Connection Flow

```
App opens → discovery starts → NWBrowser scans _adb-tls-connect._tcp
                                      │
                              devices appear in list
                                      │
                    ┌─────────────────┼──────────────────┐
                    │                 │                   │
              [Paired device]   [Not paired]    [Pair New Device]
                tap → connect    tap → pairing     manual entry
                    │             sheet (pre-       pairing sheet
                    │             filled IP/port)        │
              TCP → CNXN              │                  │
                    │           enter 6-digit code       │
              STLS? ──yes──→        │                    │
              │          reconnect  pairing success      │
              no         with TLS   save public key      │
              │          CNXN       device turns green    │
              │              │           │               │
              └──────────────┴───────────┴───────────────┘
                                   │
                            Connected ✓
```

## Paired Status Detection

When discovery finds a device:
1. Load all paired device records from `PairedDevicesClient`
2. Match by mDNS service name or host IP against `lastHost`
3. Mark `isPaired = true` for matched devices
4. Full verification happens during TLS handshake (certificate check)

## Data Persistence

**`PairedDevice`** (Codable, stored in UserDefaults):
```swift
struct PairedDevice: Identifiable, Codable {
    let id: UUID
    var name: String
    var publicKey: Data     // device RSA public key from pairing
    var lastHost: String    // last known IP (informational)
}
```

## Error Handling

- mDNS scan finds nothing → show "No devices found. Make sure Wireless Debugging is enabled."
- Local Network permission denied → show explanation + link to Settings
- Connect fails after STLS → show error on the device row, don't remove from list
- Pairing fails → error in pairing sheet (existing behavior)

## Testing

- `DeviceDiscoveryClient` has `.testValue` with unimplemented closures
- `PairedDevicesClient` has `.testValue` with unimplemented closures
- `ConnectionFeatureTests` updated for new state/actions
- `PairingFeatureTests` minimal changes (pre-filled fields)

## Files to Create

1. `iADB/ADB/ADBDeviceDiscovery.swift`
2. `iADB/Dependencies/DeviceDiscoveryClient.swift`
3. `iADB/Dependencies/PairedDevicesClient.swift`

## Files to Modify

1. `iADB/Models/DeviceInfo.swift` — add `DiscoveredDevice`, `PairedDevice`, remove `SavedDevice`
2. `iADB/Features/ConnectionFeature.swift` — rework state/actions/reducer
3. `iADB/Features/PairingFeature.swift` — accept pre-filled fields, return public key
4. `iADB/Views/Connection/ConnectionView.swift` — rewrite with discovery list
5. `iADB/Views/Connection/PairingView.swift` — pre-filled fields support
6. `iADB/Info.plist` — add `NSBonjourServices`

## Files to Remove

1. `iADB/Dependencies/SavedDevicesClient.swift`
