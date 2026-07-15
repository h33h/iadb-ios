import Foundation
import ComposableArchitecture

@Reducer
struct DeviceSessionFeature {
    @ObservableState
    struct State: Equatable {
        var selectedDevice: DeviceIdentity?
        var transport: DeviceTransportState = .noDevice
        var lastKnownEndpoint: Endpoint?
        var lastSuccessfulContact: Date?
        var capabilities = DeviceCapabilities.offline
        var lastSwitchDate: Date?
        var remoteSnapshots: [RemoteWorkspaceSnapshot: RemoteSnapshotRelationship] = [:]

        var selectedDeviceID: String? { selectedDevice?.stableID }

        mutating func markRemoteSnapshotsStale() {
            for workspace in Array(remoteSnapshots.keys) {
                remoteSnapshots[workspace]?.isStale = true
            }
        }

        func isConfirmationCurrent(deviceID: String, confirmedAt: Date) -> Bool {
            guard selectedDeviceID == deviceID else { return false }
            guard let lastSwitchDate else { return true }
            return confirmedAt >= lastSwitchDate
        }
    }

    enum Action: Equatable {
        case connectionStarted(identity: DeviceIdentity, endpoint: Endpoint, date: Date)
        case connectionSucceeded(identity: DeviceIdentity, endpoint: Endpoint, date: Date)
        case reconnecting(attempt: Int, date: Date)
        case disconnected(reason: SessionDisconnectReason, date: Date)
        case markSnapshotCurrent(RemoteWorkspaceSnapshot, date: Date)
        case invalidateRemoteSnapshots
        case clearSelectedDevice(date: Date)
    }

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .connectionStarted(let identity, let endpoint, let date):
                select(identity, in: &state, at: date)
                state.lastKnownEndpoint = endpoint
                state.transport = .connecting
                state.capabilities = .offline
                return .none

            case .connectionSucceeded(let identity, let endpoint, let date):
                select(identity, in: &state, at: date)
                state.lastKnownEndpoint = endpoint
                state.lastSuccessfulContact = date
                state.transport = .connected(endpoint: endpoint, since: date)
                state.capabilities = .connected
                return .none

            case .reconnecting(let attempt, let date):
                if state.selectedDevice != nil {
                    state.transport = .reconnecting(
                        attempt: attempt,
                        lastEndpoint: state.lastKnownEndpoint
                    )
                }
                state.capabilities = .offline
                state.markRemoteSnapshotsStale()
                if state.lastSwitchDate == nil {
                    state.lastSwitchDate = date
                }
                return .none

            case .disconnected(let reason, let date):
                state.transport = state.selectedDevice == nil
                    ? .noDevice
                    : .disconnected(reason: reason, lastSeen: state.lastSuccessfulContact ?? date)
                state.capabilities = .offline
                state.markRemoteSnapshotsStale()
                return .none

            case .markSnapshotCurrent(let workspace, let date):
                guard let deviceID = state.selectedDeviceID else { return .none }
                state.remoteSnapshots[workspace] = RemoteSnapshotRelationship(
                    deviceID: deviceID,
                    fetchedAt: date,
                    isStale: false
                )
                state.lastSuccessfulContact = date
                return .none

            case .invalidateRemoteSnapshots:
                state.markRemoteSnapshotsStale()
                return .none

            case .clearSelectedDevice(let date):
                state.selectedDevice = nil
                state.transport = .noDevice
                state.lastKnownEndpoint = nil
                state.capabilities = .offline
                state.lastSwitchDate = date
                state.markRemoteSnapshotsStale()
                return .none
            }
        }
    }

    private func select(_ identity: DeviceIdentity, in state: inout State, at date: Date) {
        if state.selectedDeviceID != identity.stableID {
            state.markRemoteSnapshotsStale()
            state.lastSwitchDate = date
        }
        state.selectedDevice = identity
    }
}
