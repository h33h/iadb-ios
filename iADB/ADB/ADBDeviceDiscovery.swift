import Foundation
import Network

final class ADBDeviceDiscovery: @unchecked Sendable {
    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "com.iadb.discovery")
    private let resolveTimeout: TimeInterval = 5

    func start(pairedKeys: [Data]) -> AsyncStream<[DiscoveredDevice]> {
        AsyncStream { continuation in
            let params = NWParameters()
            params.allowLocalEndpointReuse = true
            params.acceptLocalOnly = true

            let descriptor = NWBrowser.Descriptor.bonjour(type: "_adb-tls-connect._tcp", domain: "local.")
            let browser = NWBrowser(for: descriptor, using: params)

            browser.browseResultsChangedHandler = { [queue, resolveTimeout] results, _ in
                let group = DispatchGroup()
                var devices: [DiscoveredDevice] = []
                let lock = NSLock()

                for result in results {
                    guard case .service(let name, _, _, _) = result.endpoint else { continue }

                    group.enter()
                    var resolved = false
                    let resolveLock = NSLock()

                    func finishResolve(conn: NWConnection, device: DiscoveredDevice?) {
                        resolveLock.lock()
                        defer { resolveLock.unlock() }
                        guard !resolved else { return }
                        resolved = true
                        if let device = device {
                            lock.lock()
                            devices.append(device)
                            lock.unlock()
                        }
                        conn.cancel()
                        group.leave()
                    }

                    // Резолв Bonjour endpoint → IP:port через TCP connection
                    let conn = NWConnection(to: result.endpoint, using: .tcp)
                    conn.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            if let endpoint = conn.currentPath?.remoteEndpoint,
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
                                finishResolve(conn: conn, device: device)
                            } else {
                                finishResolve(conn: conn, device: nil)
                            }
                        case .waiting:
                            // TLS-порт не даёт plain TCP .ready — берём endpoint из path
                            if let endpoint = conn.currentPath?.remoteEndpoint,
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
                                finishResolve(conn: conn, device: device)
                            }
                        case .failed, .cancelled:
                            finishResolve(conn: conn, device: nil)
                        default:
                            break
                        }
                    }
                    conn.start(queue: queue)

                    queue.asyncAfter(deadline: .now() + resolveTimeout) {
                        finishResolve(conn: conn, device: nil)
                    }
                }

                group.notify(queue: queue) {
                    continuation.yield(devices)
                }
            }

            browser.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    break
                case .waiting:
                    // Local Network permission ещё не дана или отклонена
                    break
                case .failed:
                    continuation.yield([])
                default:
                    break
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
