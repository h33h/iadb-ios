import Foundation
import ComposableArchitecture

enum ADBConnectionEvent: Equatable, Sendable {
    case disconnected(String)
}

/// TCA dependency wrapping ADBClient for testable ADB operations
struct ADBClientDependency: Sendable {
    var connect: @Sendable (_ host: String, _ port: UInt16) async throws -> String
    var disconnect: @Sendable () -> Void
    var resetIdentity: @Sendable () throws -> Void
    var isConnected: @Sendable () -> Bool
    var connectionEvents: @Sendable () -> AsyncStream<ADBConnectionEvent>
    var shell: @Sendable (_ command: String) async throws -> String
    var getDeviceProperty: @Sendable (_ property: String) async throws -> String
    var getDeviceModel: @Sendable () async throws -> String
    var getAndroidVersion: @Sendable () async throws -> String
    var getSDKVersion: @Sendable () async throws -> String
    var getBatteryLevel: @Sendable () async throws -> String
    var getDeviceSerial: @Sendable () async throws -> String
    var listPackages: @Sendable (_ includeSystem: Bool) async throws -> [String]
    var uninstallPackage: @Sendable (_ name: String, _ keepData: Bool) async throws -> String
    var forceStopApp: @Sendable (_ name: String) async throws -> Void
    var clearAppData: @Sendable (_ name: String) async throws -> String
    var getAppInfo: @Sendable (_ name: String) async throws -> String
    var listDirectory: @Sendable (_ path: String) async throws -> String
    var listDirectoryEntries: @Sendable (_ path: String) async throws -> [FileEntry]
    var pushData: @Sendable (_ data: Data, _ remotePath: String, _ mode: UInt32) async throws -> Void
    var pushFile: @Sendable (_ localURL: URL, _ remotePath: String, _ mode: UInt32) async throws -> Void
    var pullFile: @Sendable (_ remotePath: String, _ maximumBytes: Int) async throws -> Data
    var pullFileTo: @Sendable (_ remotePath: String, _ localURL: URL) async throws -> Void
    var takeScreenshot: @Sendable () async throws -> Data
    var openLogcatStream: @Sendable () async throws -> ADBStream
    var reboot: @Sendable (_ mode: String) async throws -> Void
}

extension ADBClientDependency: DependencyKey {
    static var liveValue: Self {
        let client = LockIsolated<ADBClient?>(nil)
        // Сериализатор: ADB-протокол stream-based, один TCP. Параллельные shell/sync
        // команды перемешали бы send/receive и порушили буфер. Все операции
        // выполняются строго по очереди.
        let serializer = RequestSerializer()

        @Sendable func withClient<T: Sendable>(
            _ operation: @escaping @Sendable (ADBClient) async throws -> T
        ) async throws -> T {
            try await serializer.run {
                guard let activeClient = client.value else { throw ADBError.notConnected }
                return try await operation(activeClient)
            }
        }

        return Self(
            connect: { host, port in
                try await serializer.run {
                    let newClient = try ADBClient()
                    // Publish the pending client before awaiting the handshake so
                    // Disconnect/Cancel can abort authentication immediately.
                    client.value?.disconnect()
                    client.setValue(newClient)
                    do {
                        try await newClient.connect(host: host, port: port)
                        guard client.value === newClient else {
                            throw CancellationError()
                        }
                        return newClient.deviceBanner
                    } catch {
                        newClient.disconnect()
                        if client.value === newClient {
                            client.setValue(nil)
                        }
                        throw error
                    }
                }
            },
            disconnect: {
                client.value?.disconnect()
                client.setValue(nil)
            },
            resetIdentity: {
                client.value?.disconnect()
                client.setValue(nil)
                try ADBCrypto.deleteStoredIdentity()
            },
            isConnected: {
                client.value?.isConnected ?? false
            },
            connectionEvents: {
                AsyncStream { continuation in
                    let task = Task.detached {
                        while !Task.isCancelled {
                            do {
                                try await Task.sleep(nanoseconds: 1_000_000_000)
                            } catch {
                                return
                            }
                            guard !Task.isCancelled else { return }
                            guard client.value?.isConnected == true else {
                                continuation.yield(
                                    .disconnected(
                                        "Connection to the Android device was lost. Check Wi-Fi or wait for "
                                            + "the device to finish rebooting, then reconnect."
                                    )
                                )
                                continuation.finish()
                                return
                            }
                        }
                    }
                    continuation.onTermination = { _ in task.cancel() }
                }
            },
            shell: { command in
                try await withClient { try await $0.shell(command) }
            },
            getDeviceProperty: { property in
                try await withClient { try await $0.getDeviceProperty(property) }
            },
            getDeviceModel: {
                try await withClient { try await $0.getDeviceModel() }
            },
            getAndroidVersion: {
                try await withClient { try await $0.getAndroidVersion() }
            },
            getSDKVersion: {
                try await withClient { try await $0.getSDKVersion() }
            },
            getBatteryLevel: {
                try await withClient { try await $0.getBatteryLevel() }
            },
            getDeviceSerial: {
                try await withClient { try await $0.getDeviceSerial() }
            },
            listPackages: { includeSystem in
                try await withClient { try await $0.listPackages(includeSystem: includeSystem) }
            },
            uninstallPackage: { name, keepData in
                try await withClient { try await $0.uninstallPackage(name, keepData: keepData) }
            },
            forceStopApp: { name in
                try await withClient { try await $0.forceStopApp(name) }
            },
            clearAppData: { name in
                try await withClient { try await $0.clearAppData(name) }
            },
            getAppInfo: { name in
                try await withClient { try await $0.getAppInfo(name) }
            },
            listDirectory: { path in
                try await withClient { try await $0.listDirectory(path) }
            },
            listDirectoryEntries: { path in
                try await withClient { try await $0.listDirectoryEntries(path) }
            },
            pushData: { data, remotePath, mode in
                try await withClient { try await $0.pushData(data, to: remotePath, mode: mode) }
            },
            pushFile: { localURL, remotePath, mode in
                try await withClient { try await $0.pushFile(from: localURL, to: remotePath, mode: mode) }
            },
            pullFile: { remotePath, maximumBytes in
                try await withClient { try await $0.pullFile(remotePath: remotePath, maximumBytes: maximumBytes) }
            },
            pullFileTo: { remotePath, localURL in
                try await withClient { try await $0.pullFile(remotePath: remotePath, to: localURL) }
            },
            takeScreenshot: {
                try await withClient { try await $0.takeScreenshot() }
            },
            openLogcatStream: {
                try await withClient { try await $0.openLogcatStream() }
            },
            reboot: { mode in
                try await withClient { try await $0.reboot(mode: mode) }
            }
        )
    }

    static var previewValue: Self {
        Self(
            connect: { _, _ in "device::Preview" },
            disconnect: {},
            resetIdentity: {},
            isConnected: { true },
            connectionEvents: { AsyncStream { $0.finish() } },
            shell: { _ in "" },
            getDeviceProperty: { _ in "Preview" },
            getDeviceModel: { "Preview Phone" },
            getAndroidVersion: { "14" },
            getSDKVersion: { "34" },
            getBatteryLevel: { "  level: 75" },
            getDeviceSerial: { "PREVIEW123" },
            listPackages: { _ in ["com.example.app"] },
            uninstallPackage: { _, _ in "Success" },
            forceStopApp: { _ in },
            clearAppData: { _ in "Success" },
            getAppInfo: { _ in "Preview app info" },
            listDirectory: { _ in "" },
            listDirectoryEntries: { _ in [] },
            pushData: { _, _, _ in },
            pushFile: { _, _, _ in },
            pullFile: { _, _ in Data() },
            pullFileTo: { _, _ in },
            takeScreenshot: { Data() },
            openLogcatStream: { throw ADBError.notConnected },
            reboot: { _ in }
        )
    }

    static var testValue: Self {
        Self(
            connect: unimplemented("ADBClientDependency.connect"),
            disconnect: unimplemented("ADBClientDependency.disconnect"),
            resetIdentity: unimplemented("ADBClientDependency.resetIdentity"),
            isConnected: { false },
            connectionEvents: { AsyncStream { $0.finish() } },
            shell: unimplemented("ADBClientDependency.shell"),
            getDeviceProperty: unimplemented("ADBClientDependency.getDeviceProperty"),
            getDeviceModel: unimplemented("ADBClientDependency.getDeviceModel"),
            getAndroidVersion: unimplemented("ADBClientDependency.getAndroidVersion"),
            getSDKVersion: unimplemented("ADBClientDependency.getSDKVersion"),
            getBatteryLevel: unimplemented("ADBClientDependency.getBatteryLevel"),
            getDeviceSerial: unimplemented("ADBClientDependency.getDeviceSerial"),
            listPackages: unimplemented("ADBClientDependency.listPackages"),
            uninstallPackage: unimplemented("ADBClientDependency.uninstallPackage"),
            forceStopApp: unimplemented("ADBClientDependency.forceStopApp"),
            clearAppData: unimplemented("ADBClientDependency.clearAppData"),
            getAppInfo: unimplemented("ADBClientDependency.getAppInfo"),
            listDirectory: unimplemented("ADBClientDependency.listDirectory"),
            listDirectoryEntries: unimplemented("ADBClientDependency.listDirectoryEntries"),
            pushData: unimplemented("ADBClientDependency.pushData"),
            pushFile: unimplemented("ADBClientDependency.pushFile"),
            pullFile: unimplemented("ADBClientDependency.pullFile"),
            pullFileTo: unimplemented("ADBClientDependency.pullFileTo"),
            takeScreenshot: unimplemented("ADBClientDependency.takeScreenshot"),
            openLogcatStream: unimplemented("ADBClientDependency.openLogcatStream"),
            reboot: unimplemented("ADBClientDependency.reboot")
        )
    }
}

extension DependencyValues {
    var adbClient: ADBClientDependency {
        get { self[ADBClientDependency.self] }
        set { self[ADBClientDependency.self] = newValue }
    }
}
