import Foundation
import ComposableArchitecture

/// TCA dependency wrapping ADBClient for testable ADB operations
struct ADBClientDependency: Sendable {
    var connect: @Sendable (_ host: String, _ port: UInt16) async throws -> String
    var disconnect: @Sendable () -> Void
    var isConnected: @Sendable () -> Bool
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
    var pushData: @Sendable (_ data: Data, _ remotePath: String, _ mode: UInt32) async throws -> Void
    var pullFile: @Sendable (_ remotePath: String) async throws -> Data
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

        @Sendable func withClient<T: Sendable>(_ op: @escaping @Sendable (ADBClient) async throws -> T) async throws -> T {
            try await serializer.run {
                guard let c = client.value else { throw ADBError.notConnected }
                return try await op(c)
            }
        }

        return Self(
            connect: { host, port in
                try await serializer.run {
                    let newClient = try ADBClient()
                    try await newClient.connect(host: host, port: port)
                    client.setValue(newClient)
                    return newClient.deviceBanner
                }
            },
            disconnect: {
                client.value?.disconnect()
                client.setValue(nil)
            },
            isConnected: {
                client.value?.isConnected ?? false
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
            pushData: { data, remotePath, mode in
                try await withClient { try await $0.pushData(data, to: remotePath, mode: mode) }
            },
            pullFile: { remotePath in
                try await withClient { try await $0.pullFile(remotePath: remotePath) }
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
            isConnected: { true },
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
            pushData: { _, _, _ in },
            pullFile: { _ in Data() },
            takeScreenshot: { Data() },
            openLogcatStream: { fatalError() },
            reboot: { _ in }
        )
    }

    static var testValue: Self {
        Self(
            connect: unimplemented("ADBClientDependency.connect"),
            disconnect: unimplemented("ADBClientDependency.disconnect"),
            isConnected: unimplemented("ADBClientDependency.isConnected"),
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
            pushData: unimplemented("ADBClientDependency.pushData"),
            pullFile: unimplemented("ADBClientDependency.pullFile"),
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
