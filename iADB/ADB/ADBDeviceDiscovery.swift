import Foundation
import Network

final class ADBDeviceDiscovery: @unchecked Sendable {
    private var connectBrowser: NWBrowser?
    private var pairingBrowser: NWBrowser?
    private let queue = DispatchQueue(label: "com.iadb.discovery")
    private let resolveTimeout: TimeInterval = 5

    /// Резолвленные connect-сервисы: [host: DiscoveredDevice]
    private var connectDevices: [String: DiscoveredDevice] = [:]
    /// Резолвленные pairing-сервисы: [host: port]
    private var pairingPorts: [String: UInt16] = [:]
    private let stateLock = NSLock()
    private var activeContinuation: AsyncStream<[DiscoveredDevice]>.Continuation?

    func start(pairedKeys: [Data]) -> AsyncStream<[DiscoveredDevice]> {
        AsyncStream { [weak self] continuation in
            guard let self else { return }
            self.activeContinuation = continuation

            let params = NWParameters()
            params.allowLocalEndpointReuse = true
            params.acceptLocalOnly = true

            // Browse _adb-tls-connect._tcp
            let connectDesc = NWBrowser.Descriptor.bonjour(type: "_adb-tls-connect._tcp", domain: "local.")
            let connectBrowser = NWBrowser(for: connectDesc, using: params)
            connectBrowser.browseResultsChangedHandler = { [weak self] results, _ in
                self?.resolveServices(results: results, isConnect: true)
            }
            connectBrowser.stateUpdateHandler = { _ in }
            self.connectBrowser = connectBrowser
            connectBrowser.start(queue: queue)

            // Browse _adb-tls-pairing._tcp
            let pairingDesc = NWBrowser.Descriptor.bonjour(type: "_adb-tls-pairing._tcp", domain: "local.")
            let pairingBrowser = NWBrowser(for: pairingDesc, using: params)
            pairingBrowser.browseResultsChangedHandler = { [weak self] results, _ in
                self?.resolveServices(results: results, isConnect: false)
            }
            pairingBrowser.stateUpdateHandler = { _ in }
            self.pairingBrowser = pairingBrowser
            pairingBrowser.start(queue: queue)

            continuation.onTermination = { [weak self] _ in
                self?.connectBrowser?.cancel()
                self?.pairingBrowser?.cancel()
            }
        }
    }

    func stop() {
        connectBrowser?.cancel()
        connectBrowser = nil
        pairingBrowser?.cancel()
        pairingBrowser = nil
        activeContinuation = nil
    }

    private func resolveServices(results: Set<NWBrowser.Result>, isConnect: Bool) {
        let group = DispatchGroup()
        var resolved: [(String, UInt16, String)] = [] // (host, port, name)
        let lock = NSLock()

        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint else { continue }

            group.enter()
            var done = false
            let doneLock = NSLock()

            func finish(conn: NWConnection, host: String?, port: UInt16?) {
                doneLock.lock()
                defer { doneLock.unlock() }
                guard !done else { return }
                done = true
                if let host, let port {
                    lock.lock()
                    resolved.append((host, port, name))
                    lock.unlock()
                }
                conn.cancel()
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

            let conn = NWConnection(to: result.endpoint, using: ipv4Params)
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready, .waiting:
                    if let ep = conn.currentPath?.remoteEndpoint,
                       case .hostPort(let h, let p) = ep {
                        let hostStr: String
                        switch h {
                        case .ipv4(let a):
                            // IPv4Address.description иногда добавляет %en0 zone —
                            // для IPv4 это невалидно и ломает NWEndpoint.Host позже.
                            let bytes = [UInt8](a.rawValue)
                            hostStr = bytes.count == 4 ? "\(bytes[0]).\(bytes[1]).\(bytes[2]).\(bytes[3])" : "\(a)"
                        case .ipv6(let a): hostStr = "\(a)"
                        default: hostStr = "\(h)"
                        }
                        finish(conn: conn, host: hostStr, port: p.rawValue)
                    }
                case .failed, .cancelled:
                    finish(conn: conn, host: nil, port: nil)
                default:
                    break
                }
            }
            conn.start(queue: queue)

            queue.asyncAfter(deadline: .now() + resolveTimeout) {
                finish(conn: conn, host: nil, port: nil)
            }
        }

        group.notify(queue: queue) { [weak self] in
            self?.handleResolved(resolved, isConnect: isConnect)
        }
    }

    private func handleResolved(_ resolved: [(String, UInt16, String)], isConnect: Bool) {
        stateLock.lock()

        if isConnect {
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
                // Обновляем pairingPort в уже найденных устройствах
                if var device = connectDevices[host] {
                    device.pairingPort = port
                    connectDevices[host] = device
                }
            }
        }

        let devices = Array(connectDevices.values)
        stateLock.unlock()

        activeContinuation?.yield(devices)
    }
}
