import ComposableArchitecture
import Foundation
import Testing
@testable import iADB

@MainActor
struct DeviceSessionFeatureTests {
    private let identity = DeviceIdentity(
        stableID: "guid:pixel-a",
        displayName: "Pixel A",
        adbFingerprint: "pixel-a"
    )
    private let endpoint = Endpoint(host: "192.0.2.10", port: 37141)

    @Test
    func connectDerivesCapabilitiesAndKeepsStableIdentityAcrossEndpointChange() async {
        let start = Date(timeIntervalSince1970: 100)
        let store = TestStore(initialState: DeviceSessionFeature.State()) {
            DeviceSessionFeature()
        }

        await store.send(.connectionStarted(identity: identity, endpoint: endpoint, date: start)) {
            $0.selectedDevice = self.identity
            $0.transport = .connecting
            $0.lastKnownEndpoint = self.endpoint
            $0.lastSwitchDate = start
        }
        let changedEndpoint = Endpoint(host: "192.0.2.11", port: 40123)
        await store.send(.connectionSucceeded(
            identity: identity,
            endpoint: changedEndpoint,
            date: start.addingTimeInterval(5)
        )) {
            $0.transport = .connected(endpoint: changedEndpoint, since: start.addingTimeInterval(5))
            $0.lastKnownEndpoint = changedEndpoint
            $0.lastSuccessfulContact = start.addingTimeInterval(5)
            $0.capabilities = .connected
        }

        #expect(store.state.selectedDeviceID == identity.stableID)
    }

    @Test
    func disconnectMarksRemoteSnapshotsStaleWithoutRemovingThem() async {
        let fetchedAt = Date(timeIntervalSince1970: 100)
        var state = DeviceSessionFeature.State()
        state.selectedDevice = identity
        state.capabilities = .connected
        state.lastSuccessfulContact = fetchedAt
        state.remoteSnapshots[.files] = RemoteSnapshotRelationship(
            deviceID: identity.stableID,
            fetchedAt: fetchedAt,
            isStale: false
        )
        let store = TestStore(initialState: state) { DeviceSessionFeature() }

        await store.send(.disconnected(
            reason: .transport("Wi-Fi changed"),
            date: fetchedAt.addingTimeInterval(10)
        )) {
            $0.transport = .disconnected(
                reason: .transport("Wi-Fi changed"),
                lastSeen: fetchedAt
            )
            $0.capabilities = .offline
            $0.remoteSnapshots[.files]?.isStale = true
        }
    }

    @Test
    func deviceSwitchInvalidatesOldSnapshotAndConfirmation() async {
        let confirmationDate = Date(timeIntervalSince1970: 100)
        var state = DeviceSessionFeature.State()
        state.selectedDevice = identity
        state.remoteSnapshots[.apps] = RemoteSnapshotRelationship(
            deviceID: identity.stableID,
            fetchedAt: confirmationDate,
            isStale: false
        )
        let store = TestStore(initialState: state) { DeviceSessionFeature() }
        let other = DeviceIdentity(
            stableID: "guid:pixel-b",
            displayName: "Pixel B",
            adbFingerprint: "pixel-b"
        )
        let switchDate = confirmationDate.addingTimeInterval(5)

        await store.send(.connectionStarted(
            identity: other,
            endpoint: Endpoint(host: "192.0.2.20", port: 39000),
            date: switchDate
        )) {
            $0.selectedDevice = other
            $0.transport = .connecting
            $0.lastKnownEndpoint = Endpoint(host: "192.0.2.20", port: 39000)
            $0.lastSwitchDate = switchDate
            $0.remoteSnapshots[.apps]?.isStale = true
        }

        #expect(!store.state.isConfirmationCurrent(
            deviceID: identity.stableID,
            confirmedAt: confirmationDate
        ))
    }

    @Test
    func identityNeverUsesHostOrPort() {
        let device = DiscoveredDevice(
            id: "adb-service-id",
            name: "Pixel",
            host: "192.0.2.42",
            port: 37141,
            isPaired: true
        )
        let resolved = DeviceIdentity.resolved(from: device, pairedDevices: [])
        #expect(resolved.stableID == "service:adb-service-id")
        #expect(!resolved.stableID.contains(device.host))
        #expect(!resolved.stableID.contains(String(device.port)))
    }
}
