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

        return Self(
            connect: { host, port in
                let newClient = try ADBClient()
                try await newClient.connect(host: host, port: port)
                client.setValue(newClient)
                return newClient.deviceBanner
            },
            disconnect: {
                client.value?.disconnect()
                client.setValue(nil)
            },
            isConnected: {
                client.value?.isConnected ?? false
            },
            shell: { command in
                guard let c = client.value else { throw ADBError.notConnected }
                return try await c.shell(command)
            },
            getDeviceProperty: { property in
                guard let c = client.value else { throw ADBError.notConnected }
                return try await c.getDeviceProperty(property)
            },
            getDeviceModel: {
                guard let c = client.value else { throw ADBError.notConnected }
                return try await c.getDeviceModel()
            },
            getAndroidVersion: {
                guard let c = client.value else { throw ADBError.notConnected }
                return try await c.getAndroidVersion()
            },
            getSDKVersion: {
                guard let c = client.value else { throw ADBError.notConnected }
                return try await c.getSDKVersion()
            },
            getBatteryLevel: {
                guard let c = client.value else { throw ADBError.notConnected }
                return try await c.getBatteryLevel()
            },
            getDeviceSerial: {
                guard let c = client.value else { throw ADBError.notConnected }
                return try await c.getDeviceSerial()
            },
            listPackages: { includeSystem in
                guard let c = client.value else { throw ADBError.notConnected }
                return try await c.listPackages(includeSystem: includeSystem)
            },
            uninstallPackage: { name, keepData in
                guard let c = client.value else { throw ADBError.notConnected }
                return try await c.uninstallPackage(name, keepData: keepData)
            },
            forceStopApp: { name in
                guard let c = client.value else { throw ADBError.notConnected }
                try await c.forceStopApp(name)
            },
            clearAppData: { name in
                guard let c = client.value else { throw ADBError.notConnected }
                return try await c.clearAppData(name)
            },
            getAppInfo: { name in
                guard let c = client.value else { throw ADBError.notConnected }
                return try await c.getAppInfo(name)
            },
            listDirectory: { path in
                guard let c = client.value else { throw ADBError.notConnected }
                return try await c.listDirectory(path)
            },
            pushData: { data, remotePath, mode in
                guard let c = client.value else { throw ADBError.notConnected }
                try await c.pushData(data, to: remotePath, mode: mode)
            },
            pullFile: { remotePath in
                guard let c = client.value else { throw ADBError.notConnected }
                return try await c.pullFile(remotePath: remotePath)
            },
            takeScreenshot: {
                guard let c = client.value else { throw ADBError.notConnected }
                return try await c.takeScreenshot()
            },
            openLogcatStream: {
                guard let c = client.value else { throw ADBError.notConnected }
                return try await c.openLogcatStream()
            },
            reboot: { mode in
                guard let c = client.value else { throw ADBError.notConnected }
                try await c.reboot(mode: mode)
            }
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
