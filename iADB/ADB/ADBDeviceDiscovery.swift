import Foundation
import Network

final class ADBDeviceDiscovery: @unchecked Sendable {
    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "com.iadb.discovery")

    func start(pairedKeys: [Data]) -> AsyncStream<[DiscoveredDevice]> {
        AsyncStream { continuation in
            let descriptor = NWBrowser.Descriptor.bonjour(type: "_adb-tls-connect._tcp", domain: nil)
            let browser = NWBrowser(for: descriptor, using: .init())

            browser.browseResultsChangedHandler = { [queue] results, _ in
                let group = DispatchGroup()
                var devices: [DiscoveredDevice] = []
                let lock = NSLock()

                for result in results {
                    guard case .service(let name, _, _, _) = result.endpoint else { continue }

                    group.enter()
                    let conn = NWConnection(to: result.endpoint, using: .init())
                    conn.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            if let path = conn.currentPath,
                               let endpoint = path.remoteEndpoint,
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
                                lock.lock()
                                devices.append(device)
                                lock.unlock()
                            }
                            conn.cancel()
                            group.leave()
                        case .failed, .cancelled:
                            group.leave()
                        default:
                            break
                        }
                    }
                    conn.start(queue: queue)
                }

                group.notify(queue: queue) {
                    continuation.yield(devices)
                }
            }

            browser.stateUpdateHandler = { state in
                if case .failed = state {
                    continuation.yield([])
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
