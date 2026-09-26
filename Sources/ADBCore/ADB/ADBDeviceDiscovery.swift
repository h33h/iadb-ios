import Foundation
import Network

/// Обнаруживает службы подключения и сопряжения ADB в локальной сети.
public final class ADBDeviceDiscovery: @unchecked Sendable {
    public init() {}

    private final class CompletionGate: @unchecked Sendable {
        private let lock = NSLock()
        private var completed = false

        func claim() -> Bool {
            lock.withLock {
                guard !completed else { return false }
                completed = true
                return true
            }
        }
    }

    private final class ResolvedServices: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [(String, UInt16, String)] = []

        func append(_ value: (String, UInt16, String)) {
            lock.withLock { values.append(value) }
        }

        func snapshot() -> [(String, UInt16, String)] {
            lock.withLock { values }
        }
    }
    private enum BrowserKind: Hashable {
        case connect
        case pairing
    }

    private var connectBrowser: NWBrowser?
    private var pairingBrowser: NWBrowser?
    private let queue = DispatchQueue(label: "com.iadb.discovery")
    private let resolveTimeout: TimeInterval = 5

    private var connectDevices: [String: DiscoveredDevice] = [:]

    private var pairingPorts: [String: UInt16] = [:]
    private let stateLock = NSLock()
    private let lifecycleLock = NSRecursiveLock()
    private var activeContinuation: AsyncStream<DeviceDiscoveryEvent>.Continuation?
    private var activeRunID: UUID?
    private var readyBrowsers: Set<BrowserKind> = []
    private var connectResolutionGeneration = 0
    private var pairingResolutionGeneration = 0

    /// Запускает поиск и возвращает поток событий текущего запуска.
    public func start() -> AsyncStream<DeviceDiscoveryEvent> {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        stop()

        return AsyncStream { [weak self] continuation in
            guard let self else { return }
            let runID = UUID()
            self.stateLock.lock()
            self.activeRunID = runID
            self.activeContinuation = continuation
            self.connectDevices.removeAll()
            self.pairingPorts.removeAll()
            self.readyBrowsers.removeAll()
            self.connectResolutionGeneration = 0
            self.pairingResolutionGeneration = 0
            self.stateLock.unlock()

            let params = NWParameters()
            params.allowLocalEndpointReuse = true
            params.acceptLocalOnly = true

            let connectDesc = NWBrowser.Descriptor.bonjour(type: "_adb-tls-connect._tcp", domain: "local.")
            let connectBrowser = NWBrowser(for: connectDesc, using: params)
            connectBrowser.browseResultsChangedHandler = { [weak self] results, _ in
                self?.resolveServices(results: results, kind: .connect, runID: runID)
            }
            connectBrowser.stateUpdateHandler = { [weak self] state in
                self?.handleBrowserState(state, kind: .connect, runID: runID)
            }
            self.stateLock.lock()
            guard self.activeRunID == runID else {
                self.stateLock.unlock()
                connectBrowser.cancel()
                continuation.finish()
                return
            }
            self.connectBrowser = connectBrowser
            self.stateLock.unlock()
            connectBrowser.start(queue: queue)

            let pairingDesc = NWBrowser.Descriptor.bonjour(type: "_adb-tls-pairing._tcp", domain: "local.")
            let pairingBrowser = NWBrowser(for: pairingDesc, using: params)
            pairingBrowser.browseResultsChangedHandler = { [weak self] results, _ in
                self?.resolveServices(results: results, kind: .pairing, runID: runID)
            }
            pairingBrowser.stateUpdateHandler = { [weak self] state in
                self?.handleBrowserState(state, kind: .pairing, runID: runID)
            }
            self.stateLock.lock()
            guard self.activeRunID == runID else {
                self.stateLock.unlock()
                pairingBrowser.cancel()
                continuation.finish()
                return
            }
            self.pairingBrowser = pairingBrowser
            self.stateLock.unlock()
            pairingBrowser.start(queue: queue)

            continuation.onTermination = { [weak self] _ in
                self?.stop(runID: runID)
            }
        }
    }

    /// Останавливает поиск и завершает поток событий.
    public func stop() {
        stop(runID: nil)
    }

    private func stop(runID: UUID?) {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        stateLock.lock()
        if let runID, activeRunID != runID {
            stateLock.unlock()
            return
        }
        activeRunID = nil
        let continuation = activeContinuation
        activeContinuation = nil
        readyBrowsers.removeAll()
        let connectBrowser = connectBrowser
        let pairingBrowser = pairingBrowser
        self.connectBrowser = nil
        self.pairingBrowser = nil
        stateLock.unlock()

        continuation?.finish()
        connectBrowser?.cancel()
        pairingBrowser?.cancel()
    }

    private func handleBrowserState(_ state: NWBrowser.State, kind: BrowserKind, runID: UUID) {
        switch state {
        case .ready:
            stateLock.lock()
            guard activeRunID == runID else {
                stateLock.unlock()
                return
            }
            readyBrowsers.insert(kind)
            let allReady = readyBrowsers.count == 2
            let continuation = activeContinuation
            stateLock.unlock()
            if allReady {
                continuation?.yield(.ready)
            }

        case .waiting(let error), .failed(let error):
            yield(
                .failure(Self.discoveryMessage(for: error)),
                runID: runID
            )

        case .setup, .cancelled:
            break

        @unknown default:
            yield(
                .failure("Device discovery stopped unexpectedly."),
                runID: runID
            )
        }
    }

    private static func discoveryMessage(for error: NWError) -> String {
        if case .posix(let code) = error, code == .EPERM {
            return "Local Network access is disabled."
        }
        return "Wireless debugging discovery is unavailable: \(error.localizedDescription)"
    }

    private func yield(_ event: DeviceDiscoveryEvent, runID: UUID) {
        stateLock.lock()
        let continuation = activeRunID == runID ? activeContinuation : nil
        stateLock.unlock()
        continuation?.yield(event)
    }

    private func resolveServices(results: Set<NWBrowser.Result>, kind: BrowserKind, runID: UUID) {
        stateLock.lock()
        guard activeRunID == runID else {
            stateLock.unlock()
            return
        }
        let generation: Int
        switch kind {
        case .connect:
            connectResolutionGeneration += 1
            generation = connectResolutionGeneration
        case .pairing:
            pairingResolutionGeneration += 1
            generation = pairingResolutionGeneration
        }
        stateLock.unlock()

        let group = DispatchGroup()
        let resolved = ResolvedServices()

        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint else { continue }

            group.enter()
            let done = CompletionGate()

            @Sendable func finish(connection: NWConnection, host: String?, port: UInt16?) {
                guard done.claim() else { return }
                if let host, let port {
                    resolved.append((host, port, name))
                }
                connection.cancel()
                group.leave()
            }

            let ipv4Params = NWParameters.tcp
            ipv4Params.allowLocalEndpointReuse = true
            if let ipOptions = ipv4Params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
                ipOptions.version = .v4
            }

            let connection = NWConnection(to: result.endpoint, using: ipv4Params)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready, .waiting:
                    if let remoteEndpoint = connection.currentPath?.remoteEndpoint,
                       case .hostPort(let hostEndpoint, let portEndpoint) = remoteEndpoint {
                        let hostString: String
                        switch hostEndpoint {
                        case .ipv4(let ipv4Address):

                            let bytes = [UInt8](ipv4Address.rawValue)
                            hostString = bytes.count == 4
                                ? "\(bytes[0]).\(bytes[1]).\(bytes[2]).\(bytes[3])"
                                : "\(ipv4Address)"
                        case .ipv6(let ipv6Address):
                            hostString = "\(ipv6Address)"
                        default:
                            hostString = "\(hostEndpoint)"
                        }
                        finish(
                            connection: connection,
                            host: hostString,
                            port: portEndpoint.rawValue
                        )
                    }
                case .failed, .cancelled:
                    finish(connection: connection, host: nil, port: nil)
                default:
                    break
                }
            }
            connection.start(queue: queue)

            queue.asyncAfter(deadline: .now() + resolveTimeout) {
                finish(connection: connection, host: nil, port: nil)
            }
        }

        group.notify(queue: queue) { [weak self] in
            self?.handleResolved(resolved.snapshot(), kind: kind, runID: runID, generation: generation)
        }
    }

    private func handleResolved(
        _ resolved: [(String, UInt16, String)],
        kind: BrowserKind,
        runID: UUID,
        generation: Int
    ) {
        stateLock.lock()
        guard activeRunID == runID else {
            stateLock.unlock()
            return
        }
        let isLatestGeneration: Bool
        switch kind {
        case .connect:
            isLatestGeneration = generation == connectResolutionGeneration
        case .pairing:
            isLatestGeneration = generation == pairingResolutionGeneration
        }
        guard isLatestGeneration else {
            stateLock.unlock()
            return
        }

        if kind == .connect {
            connectDevices.removeAll()
            for (host, port, name) in resolved {
                let pairingPort = pairingPorts[host]
                connectDevices[host] = DiscoveredDevice(
                    id: name,
                    name: name.replacingOccurrences(of: "adb-", with: ""),
                    host: host,
                    port: port,
                    pairingPort: pairingPort
                )
            }
        } else {
            pairingPorts.removeAll()
            for (host, port, _) in resolved {
                pairingPorts[host] = port
            }

            for host in Array(connectDevices.keys) {
                connectDevices[host]?.pairingPort = pairingPorts[host]
            }
        }

        let devices = Array(connectDevices.values)
        let continuation = activeContinuation
        stateLock.unlock()

        continuation?.yield(.devices(devices))
    }
}
