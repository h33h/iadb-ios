import Foundation
import Network

final class ADBDeviceDiscovery: @unchecked Sendable {
    private enum BrowserKind: Hashable {
        case connect
        case pairing
    }

    private var connectBrowser: NWBrowser?
    private var pairingBrowser: NWBrowser?
    private let queue = DispatchQueue(label: "com.iadb.discovery")
    private let resolveTimeout: TimeInterval = 5

    /// Резолвленные connect-сервисы: [host: DiscoveredDevice]
    private var connectDevices: [String: DiscoveredDevice] = [:]
    /// Резолвленные pairing-сервисы: [host: port]
    private var pairingPorts: [String: UInt16] = [:]
    private let stateLock = NSLock()
    private var activeContinuation: AsyncStream<DeviceDiscoveryEvent>.Continuation?
    private var activeRunID: UUID?
    private var readyBrowsers: Set<BrowserKind> = []
    private var connectResolutionGeneration = 0
    private var pairingResolutionGeneration = 0

    func start(pairedKeys: [Data]) -> AsyncStream<DeviceDiscoveryEvent> {
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

            // Browse _adb-tls-connect._tcp
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

            // Browse _adb-tls-pairing._tcp
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

    func stop() {
        stop(runID: nil)
    }

    private func stop(runID: UUID?) {
        stateLock.lock()
        if let runID, activeRunID != runID {
            stateLock.unlock()
            return
        }
        activeRunID = nil
        activeContinuation = nil
        readyBrowsers.removeAll()
        let connectBrowser = connectBrowser
        let pairingBrowser = pairingBrowser
        self.connectBrowser = nil
        self.pairingBrowser = nil
        stateLock.unlock()

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
                .failure(String(localized: "Device discovery stopped unexpectedly. Tap Rescan to try again.")),
                runID: runID
            )
        }
    }

    private static func discoveryMessage(for error: NWError) -> String {
        if case .posix(let code) = error, code == .EPERM {
            return String(localized: "Local Network access is disabled. Allow it in Settings, then tap Rescan.")
        }
        return String(
            localized: "Wireless debugging discovery is unavailable: \(error.localizedDescription). Check Wi-Fi and Local Network access, then tap Rescan."
        )
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
        var resolved: [(String, UInt16, String)] = [] // (host, port, name)
        let lock = NSLock()

        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint else { continue }

            group.enter()
            var done = false
            let doneLock = NSLock()

            func finish(connection: NWConnection, host: String?, port: UInt16?) {
                doneLock.lock()
                defer { doneLock.unlock() }
                guard !done else { return }
                done = true
                if let host, let port {
                    lock.lock()
                    resolved.append((host, port, name))
                    lock.unlock()
                }
                connection.cancel()
                group.leave()
            }

            // Принудительно резолвим в IPv4: AOSP adbd на некоторых Android-версиях
            // отвергает TLS-handshake с IPv6 link-local источников. Mac adb по факту
            // использует IPv4, и работает; наш iOS на link-local IPv6 валится с RST.
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
                            // IPv4Address.description иногда добавляет %en0 zone —
                            // для IPv4 это невалидно и ломает NWEndpoint.Host позже.
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
            self?.handleResolved(resolved, kind: kind, runID: runID, generation: generation)
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
                    isPaired: false,
                    pairingPort: pairingPort
                )
            }
        } else {
            pairingPorts.removeAll()
            for (host, port, _) in resolved {
                pairingPorts[host] = port
            }
            // A pairing service only exists while Android's pairing dialog is
            // open. Clear every old port before applying the current snapshot.
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
