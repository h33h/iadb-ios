# mDNS Auto-Discovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace manual IP/port entry with Bonjour-based device auto-discovery so paired devices appear and connect in one tap.

**Architecture:** `ADBDeviceDiscovery` continuously scans `_adb-tls-connect._tcp` via NWBrowser, emitting discovered devices as an AsyncStream. `PairedDevicesClient` persists paired device public keys. `ConnectionFeature` merges discovery results with paired status and drives the UI list. Tapping a paired device connects via existing STLS flow; tapping unpaired opens pairing with pre-filled address.

**Tech Stack:** Network.framework (NWBrowser), ComposableArchitecture (TCA), SwiftUI, UserDefaults

---

### Task 1: PairedDevice model and PairedDevicesClient

**Files:**
- Modify: `iADB/Models/DeviceInfo.swift` — add `PairedDevice`
- Create: `iADB/Dependencies/PairedDevicesClient.swift`
- Modify: `iADBTests/DeviceInfoTests.swift` — add `PairedDevice` tests

- [ ] **Step 1: Add PairedDevice model**

Add to `iADB/Models/DeviceInfo.swift` (keep existing types for now — they'll be removed in Task 6):

```swift
/// Paired device record persisted after successful pairing
struct PairedDevice: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var publicKey: Data
    var lastHost: String

    init(name: String, publicKey: Data, lastHost: String) {
        self.id = UUID()
        self.name = name
        self.publicKey = publicKey
        self.lastHost = lastHost
    }

    var displayName: String {
        name.isEmpty ? lastHost : name
    }
}
```

- [ ] **Step 2: Write PairedDevice tests**

Add to `iADBTests/DeviceInfoTests.swift`:

```swift
// MARK: - PairedDevice

func testPairedDeviceInit() {
    let key = Data([1, 2, 3])
    let device = PairedDevice(name: "Pixel 7", publicKey: key, lastHost: "192.168.1.42")
    XCTAssertEqual(device.name, "Pixel 7")
    XCTAssertEqual(device.publicKey, key)
    XCTAssertEqual(device.lastHost, "192.168.1.42")
    XCTAssertNotNil(device.id)
}

func testPairedDeviceDisplayName() {
    let d1 = PairedDevice(name: "Pixel", publicKey: Data(), lastHost: "10.0.0.1")
    XCTAssertEqual(d1.displayName, "Pixel")
    let d2 = PairedDevice(name: "", publicKey: Data(), lastHost: "10.0.0.1")
    XCTAssertEqual(d2.displayName, "10.0.0.1")
}

func testPairedDeviceCodable() throws {
    let device = PairedDevice(name: "Test", publicKey: Data([0xAB, 0xCD]), lastHost: "1.2.3.4")
    let encoded = try JSONEncoder().encode(device)
    let decoded = try JSONDecoder().decode(PairedDevice.self, from: encoded)
    XCTAssertEqual(decoded.id, device.id)
    XCTAssertEqual(decoded.name, device.name)
    XCTAssertEqual(decoded.publicKey, device.publicKey)
    XCTAssertEqual(decoded.lastHost, device.lastHost)
}
```

- [ ] **Step 3: Run tests to verify they pass**

Run: `xcodebuild test -scheme iADB -destination 'platform=iOS Simulator,name=iPhone 16 Pro Max,OS=18.6' -skipMacroValidation -only-testing:iADBTests/DeviceInfoTests 2>&1 | grep -E "passed|failed|error:"`
Expected: All tests PASS

- [ ] **Step 4: Create PairedDevicesClient**

Create `iADB/Dependencies/PairedDevicesClient.swift`:

```swift
import Foundation
import ComposableArchitecture

struct PairedDevicesClient: Sendable {
    var load: @Sendable () -> [PairedDevice]
    var save: @Sendable ([PairedDevice]) -> Void
}

extension PairedDevicesClient: DependencyKey {
    private static let key = "pairedDevices"

    static var liveValue: Self {
        Self(
            load: {
                guard let data = UserDefaults.standard.data(forKey: key),
                      let devices = try? JSONDecoder().decode([PairedDevice].self, from: data) else {
                    return []
                }
                return devices
            },
            save: { devices in
                guard let data = try? JSONEncoder().encode(devices) else { return }
                UserDefaults.standard.set(data, forKey: key)
            }
        )
    }

    static var previewValue: Self {
        Self(
            load: { [PairedDevice(name: "Preview", publicKey: Data(), lastHost: "10.0.0.1")] },
            save: { _ in }
        )
    }

    static var testValue: Self {
        Self(
            load: unimplemented("PairedDevicesClient.load"),
            save: unimplemented("PairedDevicesClient.save")
        )
    }
}

extension DependencyValues {
    var pairedDevicesClient: PairedDevicesClient {
        get { self[PairedDevicesClient.self] }
        set { self[PairedDevicesClient.self] = newValue }
    }
}
```

- [ ] **Step 5: Build to verify compilation**

Run: `xcodebuild -scheme iADB -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build -skipMacroValidation 2>&1 | grep -E "error:" | grep -v Macro`
Expected: No errors

- [ ] **Step 6: Commit**

```bash
git add iADB/Models/DeviceInfo.swift iADB/Dependencies/PairedDevicesClient.swift iADBTests/DeviceInfoTests.swift
git commit -m "Add PairedDevice model and PairedDevicesClient dependency"
```

---

### Task 2: DiscoveredDevice model and ADBDeviceDiscovery

**Files:**
- Modify: `iADB/Models/DeviceInfo.swift` — add `DiscoveredDevice`
- Create: `iADB/ADB/ADBDeviceDiscovery.swift`
- Create: `iADB/Dependencies/DeviceDiscoveryClient.swift`

- [ ] **Step 1: Add DiscoveredDevice model**

Add to `iADB/Models/DeviceInfo.swift`:

```swift
struct DiscoveredDevice: Identifiable, Equatable {
    let id: String
    var name: String
    var host: String
    var port: UInt16
    var isPaired: Bool
}
```

- [ ] **Step 2: Create ADBDeviceDiscovery**

Create `iADB/ADB/ADBDeviceDiscovery.swift`:

```swift
import Foundation
import Network

final class ADBDeviceDiscovery: @unchecked Sendable {
    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "com.iadb.discovery")

    func start(pairedKeys: [Data]) -> AsyncStream<[DiscoveredDevice]> {
        AsyncStream { continuation in
            let descriptor = NWBrowser.Descriptor.bonjour(type: "_adb-tls-connect._tcp", domain: nil)
            let browser = NWBrowser(for: descriptor, using: .init())

            browser.browseResultsChangedHandler = { [queue] results, _ in
                let group = DispatchGroup()
                var devices: [DiscoveredDevice] = []
                let lock = NSLock()

                for result in results {
                    guard case .service(let name, _, _, _) = result.endpoint else { continue }

                    group.enter()
                    let conn = NWConnection(to: result.endpoint, using: .init())
                    conn.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            if let path = conn.currentPath,
                               let endpoint = path.remoteEndpoint,
                               case .hostPort(let host, let port) = endpoint {
                                let hostStr: String
                                switch host {
                                case .ipv4(let addr): hostStr = "\(addr)"
                                case .ipv6(let addr): hostStr = "\(addr)"
                                default: hostStr = "\(host)"
                                }
                                let device = DiscoveredDevice(
                                    id: name,
                                    name: name.replacingOccurrences(of: "adb-", with: ""),
                                    host: hostStr,
                                    port: port.rawValue,
                                    isPaired: false
                                )
                                lock.lock()
                                devices.append(device)
                                lock.unlock()
                            }
                            conn.cancel()
                            group.leave()
                        case .failed, .cancelled:
                            group.leave()
                        default:
                            break
                        }
                    }
                    conn.start(queue: queue)
                }

                group.notify(queue: queue) {
                    continuation.yield(devices)
                }
            }

            browser.stateUpdateHandler = { state in
                if case .failed = state {
                    continuation.yield([])
                }
            }

            self.browser = browser
            browser.start(queue: queue)

            continuation.onTermination = { _ in
                browser.cancel()
            }
        }
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }
}
```

- [ ] **Step 3: Create DeviceDiscoveryClient**

Create `iADB/Dependencies/DeviceDiscoveryClient.swift`:

```swift
import Foundation
import ComposableArchitecture

struct DeviceDiscoveryClient: Sendable {
    var start: @Sendable ([Data]) -> AsyncStream<[DiscoveredDevice]>
    var stop: @Sendable () -> Void
}

extension DeviceDiscoveryClient: DependencyKey {
    static var liveValue: Self {
        let discovery = ADBDeviceDiscovery()
        return Self(
            start: { pairedKeys in discovery.start(pairedKeys: pairedKeys) },
            stop: { discovery.stop() }
        )
    }

    static var previewValue: Self {
        Self(
            start: { _ in
                AsyncStream { continuation in
                    continuation.yield([
                        DiscoveredDevice(id: "preview-1", name: "Pixel 7", host: "192.168.1.42", port: 38745, isPaired: true),
                        DiscoveredDevice(id: "preview-2", name: "Galaxy S24", host: "192.168.1.55", port: 42100, isPaired: false)
                    ])
                }
            },
            stop: {}
        )
    }

    static var testValue: Self {
        Self(
            start: unimplemented("DeviceDiscoveryClient.start"),
            stop: unimplemented("DeviceDiscoveryClient.stop")
        )
    }
}

extension DependencyValues {
    var deviceDiscoveryClient: DeviceDiscoveryClient {
        get { self[DeviceDiscoveryClient.self] }
        set { self[DeviceDiscoveryClient.self] = newValue }
    }
}
```

- [ ] **Step 4: Build to verify compilation**

Run: `xcodebuild -scheme iADB -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build -skipMacroValidation 2>&1 | grep -E "error:" | grep -v Macro`
Expected: No errors

- [ ] **Step 5: Commit**

```bash
git add iADB/Models/DeviceInfo.swift iADB/ADB/ADBDeviceDiscovery.swift iADB/Dependencies/DeviceDiscoveryClient.swift
git commit -m "Add mDNS device discovery with NWBrowser for _adb-tls-connect._tcp"
```

---

### Task 3: Add NSBonjourServices to Info.plist

**Files:**
- Modify: `iADB/Info.plist`

- [ ] **Step 1: Add NSBonjourServices**

In `iADB/Info.plist`, add after the `NSLocalNetworkUsageDescription` string closing tag (after line 24):

```xml
	<key>NSBonjourServices</key>
	<array>
		<string>_adb-tls-connect._tcp</string>
		<string>_adb-tls-pairing._tcp</string>
	</array>
```

- [ ] **Step 2: Build to verify**

Run: `xcodebuild -scheme iADB -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build -skipMacroValidation 2>&1 | grep -E "error:" | grep -v Macro`
Expected: No errors

- [ ] **Step 3: Commit**

```bash
git add iADB/Info.plist
git commit -m "Add NSBonjourServices for ADB device discovery and pairing"
```

---

### Task 4: Update PairingFeature to return public key and accept pre-filled fields

**Files:**
- Modify: `iADB/Features/PairingFeature.swift`
- Modify: `iADB/Views/Connection/PairingView.swift`
- Modify: `iADBTests/Features/PairingFeatureTests.swift`

- [ ] **Step 1: Update PairingFeature.State and Action**

Replace `iADB/Features/PairingFeature.swift` entirely:

```swift
import Foundation
import ComposableArchitecture

@Reducer
struct PairingFeature {
    @ObservableState
    struct State: Equatable {
        var hostInput = ""
        var portInput = ""
        var pairingCode = ""
        var pairingState: PairingState = .idle
        var pairedDeviceName: String?
        var pairedDevicePublicKey: Data?
        /// true когда поля заполнены из discovery (IP/порт нередактируемые)
        var isPrefilled = false
    }

    enum PairingState: Equatable {
        case idle
        case pairing
        case success(String)
        case error(String)

        var isPairing: Bool {
            if case .pairing = self { return true }
            return false
        }

        var isSuccess: Bool {
            if case .success = self { return true }
            return false
        }
    }

    enum Action: BindableAction {
        case binding(BindingAction<State>)
        case pairWithCode
        case pairingResult(Result<String, Error>)
        case pairingCompleted(name: String, publicKey: Data)
        case reset
    }

    private enum CancelID { case pairing }

    @Dependency(\.adbPairing) var adbPairing

    var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .binding:
                return .none

            case .pairWithCode:
                let host = state.hostInput.trimmingCharacters(in: .whitespacesAndNewlines)
                let code = state.pairingCode.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !host.isEmpty, !code.isEmpty else { return .none }
                guard let port = UInt16(state.portInput.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                    state.pairingState = .error("Invalid port number")
                    return .none
                }

                state.pairingState = .pairing

                return .run { send in
                    let peerInfo = try await adbPairing.pair(host, port, code)
                    await send(.pairingCompleted(name: peerInfo.name, publicKey: peerInfo.publicKey))
                } catch: { error, send in
                    await send(.pairingResult(.failure(error)))
                }
                .cancellable(id: CancelID.pairing)

            case .pairingCompleted(let name, let publicKey):
                state.pairingState = .success("Paired with \(name)")
                state.pairedDeviceName = name
                state.pairedDevicePublicKey = publicKey
                return .none

            case .pairingResult(.success(let deviceName)):
                state.pairingState = .success("Paired with \(deviceName)")
                state.pairedDeviceName = deviceName
                return .none

            case .pairingResult(.failure(let error)):
                state.pairingState = .error(error.localizedDescription)
                return .none

            case .reset:
                state.pairingCode = ""
                state.pairingState = .idle
                return .none
            }
        }
    }
}
```

- [ ] **Step 2: Update PairingView for pre-filled fields**

In `iADB/Views/Connection/PairingView.swift`, replace the "Pairing Address" section:

```swift
                Section {
                    TextField("IP Address", text: $store.hostInput)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .disabled(store.isPrefilled)
                    TextField("Pairing Port", text: $store.portInput)
                        .keyboardType(.numberPad)
                        .disabled(store.isPrefilled)
                } header: {
                    Text("Pairing Address")
                } footer: {
                    if store.isPrefilled {
                        Text("Address detected automatically. Enter only the pairing code.")
                    } else {
                        Text("Enter the IP address and port shown in the 'Pair device with pairing code' dialog.")
                    }
                }
```

- [ ] **Step 3: Update PairingFeatureTests**

Replace `iADBTests/Features/PairingFeatureTests.swift` content of `pairWithCodeSuccess`:

```swift
    @Test
    func pairWithCodeSuccess() async {
        let store = TestStore(
            initialState: PairingFeature.State(
                hostInput: "192.168.1.100",
                portInput: "37000",
                pairingCode: "123456"
            )
        ) {
            PairingFeature()
        } withDependencies: {
            $0.adbPairing.pair = { _, _, _ in
                ADBPairing.PeerInfo(name: "Pixel 7", guid: "", publicKey: Data([1, 2, 3]))
            }
        }

        await store.send(.pairWithCode) {
            $0.pairingState = .pairing
        }
        await store.receive(\.pairingCompleted) {
            $0.pairingState = .success("Paired with Pixel 7")
            $0.pairedDeviceName = "Pixel 7"
            $0.pairedDevicePublicKey = Data([1, 2, 3])
        }
    }
```

- [ ] **Step 4: Build to verify**

Run: `xcodebuild -scheme iADB -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build -skipMacroValidation 2>&1 | grep -E "error:" | grep -v Macro`
Expected: No errors

- [ ] **Step 5: Commit**

```bash
git add iADB/Features/PairingFeature.swift iADB/Views/Connection/PairingView.swift iADBTests/Features/PairingFeatureTests.swift
git commit -m "Update PairingFeature to return public key and support pre-filled fields"
```

---

### Task 5: Rewrite ConnectionFeature with discovery

**Files:**
- Modify: `iADB/Features/ConnectionFeature.swift`
- Modify: `iADBTests/Features/ConnectionFeatureTests.swift`

- [ ] **Step 1: Rewrite ConnectionFeature**

Replace `iADB/Features/ConnectionFeature.swift` entirely:

```swift
import Foundation
import ComposableArchitecture

@Reducer
struct ConnectionFeature {
    @ObservableState
    struct State: Equatable {
        var discoveredDevices: [DiscoveredDevice] = []
        var pairedDevices: [PairedDevice] = []
        var isScanning = false
        var connectionState: ConnectionState = .disconnected
        @Presents var pairing: PairingFeature.State?
    }

    enum Action: BindableAction {
        case binding(BindingAction<State>)
        case onAppear
        case startDiscovery
        case devicesUpdated([DiscoveredDevice])
        case connectToDevice(DiscoveredDevice)
        case disconnect
        case connectionResult(Result<String, Error>)
        case showPairingForDevice(DiscoveredDevice)
        case showManualPairing
        case pairing(PresentationAction<PairingFeature.Action>)
    }

    private enum CancelID { case connection, discovery }

    @Dependency(\.adbClient) var adbClient
    @Dependency(\.pairedDevicesClient) var pairedDevicesClient
    @Dependency(\.deviceDiscoveryClient) var deviceDiscoveryClient

    var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .binding:
                return .none

            case .onAppear:
                state.pairedDevices = pairedDevicesClient.load()
                return .send(.startDiscovery)

            case .startDiscovery:
                state.isScanning = true
                let pairedKeys = state.pairedDevices.map(\.publicKey)
                return .run { send in
                    let stream = deviceDiscoveryClient.start(pairedKeys)
                    for await devices in stream {
                        await send(.devicesUpdated(devices))
                    }
                }
                .cancellable(id: CancelID.discovery)

            case .devicesUpdated(var devices):
                let paired = state.pairedDevices
                for i in devices.indices {
                    if paired.contains(where: { $0.lastHost == devices[i].host }) {
                        devices[i].isPaired = true
                        if let match = paired.first(where: { $0.lastHost == devices[i].host }) {
                            devices[i].name = match.name
                        }
                    }
                }
                state.discoveredDevices = devices
                return .none

            case .connectToDevice(let device):
                guard state.connectionState != .connecting else { return .none }
                state.connectionState = .connecting

                return .run { [host = device.host, port = device.port] send in
                    let banner = try await adbClient.connect(host, port)
                    await send(.connectionResult(.success(banner)))
                } catch: { error, send in
                    await send(.connectionResult(.failure(error)))
                }
                .cancellable(id: CancelID.connection)

            case .disconnect:
                state.connectionState = .disconnected
                return .merge(
                    .cancel(id: CancelID.connection),
                    .run { _ in adbClient.disconnect() }
                )

            case .connectionResult(.success):
                state.connectionState = .connected
                return .none

            case .connectionResult(.failure(let error)):
                state.connectionState = .error(error.localizedDescription)
                return .none

            case .showPairingForDevice(let device):
                state.pairing = PairingFeature.State(
                    hostInput: device.host,
                    portInput: String(device.port),
                    isPrefilled: true
                )
                return .none

            case .showManualPairing:
                state.pairing = PairingFeature.State()
                return .none

            case .pairing(.presented(.pairingCompleted(let name, let publicKey))):
                guard let pairingState = state.pairing else { return .none }
                let host = pairingState.hostInput.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !host.isEmpty else { return .none }
                guard !state.pairedDevices.contains(where: { $0.publicKey == publicKey }) else {
                    return .none
                }
                let paired = PairedDevice(name: name, publicKey: publicKey, lastHost: host)
                state.pairedDevices.append(paired)
                // Обновляем isPaired в discovered-списке
                if let idx = state.discoveredDevices.firstIndex(where: { $0.host == host }) {
                    state.discoveredDevices[idx].isPaired = true
                    state.discoveredDevices[idx].name = name
                }
                return .run { [devices = state.pairedDevices] _ in
                    pairedDevicesClient.save(devices)
                }

            case .pairing:
                return .none
            }
        }
        .ifLet(\.$pairing, action: \.pairing) {
            PairingFeature()
        }
    }
}
```

- [ ] **Step 2: Rewrite ConnectionFeatureTests**

Replace `iADBTests/Features/ConnectionFeatureTests.swift`:

```swift
import ComposableArchitecture
import Foundation
import Testing
@testable import iADB

@MainActor
struct ConnectionFeatureTests {
    @Test
    func onAppearStartsDiscovery() async {
        let store = TestStore(initialState: ConnectionFeature.State()) {
            ConnectionFeature()
        } withDependencies: {
            $0.pairedDevicesClient.load = { [] }
            $0.deviceDiscoveryClient.start = { _ in
                AsyncStream { $0.yield([]); $0.finish() }
            }
        }

        await store.send(.onAppear)
        await store.receive(\.startDiscovery) {
            $0.isScanning = true
        }
        await store.receive(\.devicesUpdated)
    }

    @Test
    func connectToDeviceSuccess() async {
        let device = DiscoveredDevice(id: "test", name: "Pixel", host: "10.0.0.1", port: 38745, isPaired: true)
        let store = TestStore(initialState: ConnectionFeature.State()) {
            ConnectionFeature()
        } withDependencies: {
            $0.adbClient.connect = { _, _ in "device::Pixel" }
        }

        await store.send(.connectToDevice(device)) {
            $0.connectionState = .connecting
        }
        await store.receive(\.connectionResult.success) {
            $0.connectionState = .connected
        }
    }

    @Test
    func connectToDeviceError() async {
        let device = DiscoveredDevice(id: "test", name: "Pixel", host: "10.0.0.1", port: 38745, isPaired: true)
        let store = TestStore(initialState: ConnectionFeature.State()) {
            ConnectionFeature()
        } withDependencies: {
            $0.adbClient.connect = { _, _ in throw ADBError.connectionFailed("timeout") }
        }

        await store.send(.connectToDevice(device)) {
            $0.connectionState = .connecting
        }
        await store.receive(\.connectionResult.failure) {
            $0.connectionState = .error("Connection failed: timeout")
        }
    }

    @Test
    func disconnect() async {
        var disconnected = false
        let store = TestStore(
            initialState: ConnectionFeature.State(connectionState: .connected)
        ) {
            ConnectionFeature()
        } withDependencies: {
            $0.adbClient.disconnect = { disconnected = true }
        }

        await store.send(.disconnect) {
            $0.connectionState = .disconnected
        }
        #expect(disconnected)
    }

    @Test
    func showManualPairing() async {
        let store = TestStore(initialState: ConnectionFeature.State()) {
            ConnectionFeature()
        }

        await store.send(.showManualPairing) {
            $0.pairing = PairingFeature.State()
        }
    }

    @Test
    func showPairingForDevice() async {
        let device = DiscoveredDevice(id: "test", name: "Galaxy", host: "10.0.0.5", port: 42100, isPaired: false)
        let store = TestStore(initialState: ConnectionFeature.State()) {
            ConnectionFeature()
        }

        await store.send(.showPairingForDevice(device)) {
            $0.pairing = PairingFeature.State(
                hostInput: "10.0.0.5",
                portInput: "42100",
                isPrefilled: true
            )
        }
    }

    @Test
    func duplicateConnectIgnored() async {
        let device = DiscoveredDevice(id: "test", name: "P", host: "1.2.3.4", port: 5555, isPaired: true)
        let store = TestStore(
            initialState: ConnectionFeature.State(connectionState: .connecting)
        ) {
            ConnectionFeature()
        }

        await store.send(.connectToDevice(device))
    }

    @Test
    func devicesUpdatedMatchesPaired() async {
        let paired = PairedDevice(name: "My Pixel", publicKey: Data([1]), lastHost: "10.0.0.1")
        let discovered = [DiscoveredDevice(id: "s1", name: "adb-abc", host: "10.0.0.1", port: 38745, isPaired: false)]

        let store = TestStore(
            initialState: ConnectionFeature.State(pairedDevices: [paired])
        ) {
            ConnectionFeature()
        }

        await store.send(.devicesUpdated(discovered)) {
            $0.discoveredDevices = [
                DiscoveredDevice(id: "s1", name: "My Pixel", host: "10.0.0.1", port: 38745, isPaired: true)
            ]
        }
    }
}
```

- [ ] **Step 3: Build to verify**

Run: `xcodebuild -scheme iADB -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build -skipMacroValidation 2>&1 | grep -E "error:" | grep -v Macro`
Expected: No errors

- [ ] **Step 4: Commit**

```bash
git add iADB/Features/ConnectionFeature.swift iADBTests/Features/ConnectionFeatureTests.swift
git commit -m "Rewrite ConnectionFeature with mDNS discovery and paired device matching"
```

---

### Task 6: Rewrite ConnectionView

**Files:**
- Modify: `iADB/Views/Connection/ConnectionView.swift`

- [ ] **Step 1: Replace ConnectionView entirely**

Replace `iADB/Views/Connection/ConnectionView.swift`:

```swift
import SwiftUI
import ComposableArchitecture

struct ConnectionView: View {
    @Bindable var store: StoreOf<ConnectionFeature>

    var body: some View {
        NavigationStack {
            List {
                // Connection Status
                if store.connectionState != .disconnected {
                    Section {
                        HStack {
                            statusIcon
                            Text(store.connectionState.statusText)
                                .font(.subheadline)
                            Spacer()
                            if store.connectionState.isConnected {
                                Button("Disconnect") {
                                    store.send(.disconnect)
                                }
                                .foregroundColor(.red)
                                .font(.subheadline)
                            }
                        }
                    } header: {
                        Text("Status")
                    }
                }

                // Discovered Devices
                Section {
                    if store.discoveredDevices.isEmpty {
                        VStack(spacing: 8) {
                            if store.isScanning {
                                ProgressView()
                                Text("Looking for devices with Wireless Debugging enabled...")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                            } else {
                                Text("No devices found")
                                    .foregroundColor(.secondary)
                                    .font(.subheadline)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    } else {
                        ForEach(store.discoveredDevices) { device in
                            DiscoveredDeviceRow(device: device) {
                                if device.isPaired {
                                    store.send(.connectToDevice(device))
                                } else {
                                    store.send(.showPairingForDevice(device))
                                }
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("Devices on Network")
                        Spacer()
                        if store.isScanning && !store.discoveredDevices.isEmpty {
                            ProgressView()
                                .scaleEffect(0.7)
                        }
                    }
                }

                // Pair New Device
                Section {
                    Button {
                        store.send(.showManualPairing)
                    } label: {
                        HStack {
                            Image(systemName: "link.badge.plus")
                                .foregroundColor(.accentColor)
                                .frame(width: 30)
                            VStack(alignment: .leading) {
                                Text("Pair New Device")
                                    .font(.body)
                                Text("Enter pairing code manually")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                    }
                    .foregroundColor(.primary)
                } header: {
                    Text("Pair")
                }

                // Help
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("How to connect", systemImage: "questionmark.circle")
                            .font(.subheadline.bold())
                        Text("1. Enable Developer Options on your Android device")
                            .font(.caption)
                        Text("2. Enable 'Wireless debugging' in Developer Options")
                            .font(.caption)
                        Text("3. Devices appear here automatically")
                            .font(.caption)
                        Text("4. First time: tap device → enter pairing code")
                            .font(.caption)
                        Text("5. After pairing: tap device → connected!")
                            .font(.caption)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Help")
                }
            }
            .navigationTitle("iADB")
            .onAppear { store.send(.onAppear) }
            .sheet(item: $store.scope(state: \.pairing, action: \.pairing)) { pairingStore in
                PairingView(store: pairingStore)
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch store.connectionState {
        case .disconnected:
            Image(systemName: "circle")
                .foregroundColor(.gray)
        case .connecting, .authenticating:
            ProgressView()
                .scaleEffect(0.8)
        case .connected:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
        case .error:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundColor(.red)
        }
    }
}

struct DiscoveredDeviceRow: View {
    let device: DiscoveredDevice
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack {
                Image(systemName: "desktopcomputer")
                    .foregroundColor(.accentColor)
                    .frame(width: 30)
                VStack(alignment: .leading) {
                    Text(device.name)
                        .font(.body)
                    Text("\(device.host):\(device.port)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if device.isPaired {
                    Text("Paired")
                        .font(.caption2)
                        .foregroundColor(.green)
                } else {
                    Text("Tap to pair")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
            }
        }
        .foregroundColor(.primary)
    }
}
```

- [ ] **Step 2: Build to verify**

Run: `xcodebuild -scheme iADB -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build -skipMacroValidation 2>&1 | grep -E "error:" | grep -v Macro`
Expected: No errors

- [ ] **Step 3: Commit**

```bash
git add iADB/Views/Connection/ConnectionView.swift
git commit -m "Rewrite ConnectionView with auto-discovery device list"
```

---

### Task 7: Remove SavedDevicesClient and SavedDevice

**Files:**
- Delete: `iADB/Dependencies/SavedDevicesClient.swift`
- Modify: `iADB/Models/DeviceInfo.swift` — remove `SavedDevice`
- Modify: `iADBTests/DeviceInfoTests.swift` — remove `SavedDevice` tests

- [ ] **Step 1: Remove SavedDevice from DeviceInfo.swift**

Delete the `SavedDevice` struct (lines 4–24) from `iADB/Models/DeviceInfo.swift`.

- [ ] **Step 2: Remove SavedDevice tests from DeviceInfoTests.swift**

Delete the `// MARK: - SavedDevice` section and all `testSavedDevice*` methods from `iADBTests/DeviceInfoTests.swift`.

- [ ] **Step 3: Delete SavedDevicesClient.swift**

```bash
git rm iADB/Dependencies/SavedDevicesClient.swift
```

- [ ] **Step 4: Build to verify no remaining references**

Run: `xcodebuild -scheme iADB -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build -skipMacroValidation 2>&1 | grep -E "error:" | grep -v Macro`
Expected: No errors (all references replaced in earlier tasks)

- [ ] **Step 5: Commit**

```bash
git add iADB/Models/DeviceInfo.swift iADBTests/DeviceInfoTests.swift
git commit -m "Remove SavedDevice and SavedDevicesClient (replaced by PairedDevice + discovery)"
```

---

### Task 8: Final integration build and verify

**Files:** None (verification only)

- [ ] **Step 1: Full build**

Run: `xcodebuild -scheme iADB -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build -skipMacroValidation 2>&1 | grep -E "BUILD|error:" | grep -v Macro`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 2: Check for any stale SavedDevice references**

Run: `grep -r "SavedDevice\|SavedDevicesClient\|savedDevicesClient\|savedDevices" --include="*.swift" iADB/ iADBTests/`
Expected: No matches

- [ ] **Step 3: Verify Info.plist has NSBonjourServices**

Run: `grep -A4 "NSBonjourServices" iADB/Info.plist`
Expected: Shows array with both service types

- [ ] **Step 4: Final commit if any fixes needed**

If any issues found, fix and commit with message: `Fix integration issues in mDNS discovery`
