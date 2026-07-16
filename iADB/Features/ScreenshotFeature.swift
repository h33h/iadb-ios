import ComposableArchitecture
import Foundation
import ImageIO

struct ScreenshotEntry: Identifiable, Equatable {
    var id: UUID
    var timestamp: Date
    var fileName: String
    var deviceID: String
    var deviceName: String?
    var pixelWidth: Int
    var pixelHeight: Int
    var data: Data
}

@Reducer
struct ScreenshotFeature {
    @ObservableState
    struct State: Equatable {
        var activeDeviceID = DeviceIdentity.unknownID
        var activeDeviceName: String?
        var entries: [ScreenshotEntry] = []
        var isConnected = false
        var isLoading = false
        var isCapturing = false
        var errorMessage: String?
    }

    enum Action {
        case setDevice(id: String, name: String?)
        case setConnected(Bool)
        case load
        case loaded(Result<ScreenshotPersistenceBundle, Error>)
        case capture
        case captured(Result<Data, Error>)
        case delete(UUID)
        case clear
        case persisted(Result<Void, Error>)
        case cancel
    }

    private enum CancelID { case request }
    @Dependency(\.adbClient) var adbClient
    @Dependency(\.screenshotPersistenceClient) var persistence
    @Dependency(\.date.now) var now
    @Dependency(\.uuid) var uuid

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .setDevice(let id, let name):
                state.activeDeviceID = id
                state.activeDeviceName = name
                return .none

            case .setConnected(let value):
                state.isConnected = value
                return value ? .none : .send(.cancel)

            case .load:
                state.isLoading = true
                state.errorMessage = nil
                return .run { send in
                    do { await send(.loaded(.success(try persistence.load()))) }
                    catch { await send(.loaded(.failure(error))) }
                }

            case .loaded(.success(let bundle)):
                state.isLoading = false
                state.entries = bundle.metadata.compactMap { metadata in
                    guard let data = bundle.files[metadata.id] else { return nil }
                    return ScreenshotEntry(
                        id: metadata.id,
                        timestamp: metadata.timestamp,
                        fileName: metadata.fileName,
                        deviceID: metadata.originDeviceID,
                        deviceName: metadata.originDeviceName,
                        pixelWidth: metadata.pixelWidth,
                        pixelHeight: metadata.pixelHeight,
                        data: data
                    )
                }
                .sorted { $0.timestamp > $1.timestamp }
                return .none

            case .loaded(.failure(let error)):
                state.isLoading = false
                state.errorMessage = error.localizedDescription
                return .none

            case .capture:
                guard state.isConnected, !state.isCapturing else { return .none }
                state.isCapturing = true
                state.errorMessage = nil
                return .run { send in
                    do { await send(.captured(.success(try await adbClient.takeScreenshot()))) }
                    catch { await send(.captured(.failure(error))) }
                }
                .cancellable(id: CancelID.request, cancelInFlight: true)

            case .captured(.success(let data)):
                state.isCapturing = false
                let dimensions = Self.dimensions(of: data)
                let id = uuid()
                state.entries.insert(
                    ScreenshotEntry(
                        id: id,
                        timestamp: now,
                        fileName: "\(id.uuidString).png",
                        deviceID: state.activeDeviceID,
                        deviceName: state.activeDeviceName,
                        pixelWidth: dimensions.width,
                        pixelHeight: dimensions.height,
                        data: data
                    ),
                    at: 0
                )
                Self.retain(entries: &state.entries)
                return persist(state.entries)

            case .captured(.failure(let error)):
                state.isCapturing = false
                state.errorMessage = error.localizedDescription
                return .none

            case .delete(let id):
                state.entries.removeAll { $0.id == id }
                return persist(state.entries)

            case .clear:
                state.entries = []
                return .run { send in
                    do {
                        try persistence.clear()
                        await send(.persisted(.success(())))
                    } catch {
                        await send(.persisted(.failure(error)))
                    }
                }

            case .persisted(.success):
                return .none

            case .persisted(.failure(let error)):
                state.errorMessage = error.localizedDescription
                return .none

            case .cancel:
                state.isCapturing = false
                return .cancel(id: CancelID.request)
            }
        }
    }

    private func persist(_ entries: [ScreenshotEntry]) -> Effect<Action> {
        let metadata = entries.map {
            PersistedScreenshotEntry(
                id: $0.id,
                timestamp: $0.timestamp,
                fileName: $0.fileName,
                originDeviceID: $0.deviceID,
                originDeviceName: $0.deviceName,
                pixelWidth: $0.pixelWidth,
                pixelHeight: $0.pixelHeight,
                byteCount: $0.data.count
            )
        }
        let files = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.data) })
        return .run { send in
            do {
                try persistence.save(metadata, files)
                await send(.persisted(.success(())))
            } catch {
                await send(.persisted(.failure(error)))
            }
        }
    }

    private static func retain(entries: inout [ScreenshotEntry]) {
        var bytes = 0
        entries = entries.filter { entry in
            guard entry.data.count <= screenshotStorageByteLimit - bytes else { return false }
            bytes += entry.data.count
            return true
        }
    }

    private static func dimensions(of data: Data) -> (width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return (0, 0)
        }
        return (
            properties[kCGImagePropertyPixelWidth] as? Int ?? 0,
            properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        )
    }
}
