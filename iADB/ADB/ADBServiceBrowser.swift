import Foundation
import Network

/// Discovers ADB wireless debugging pairing services via mDNS (Bonjour).
final class ADBServiceBrowser: @unchecked Sendable {
    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "com.iadb.browser")

    /// Browse for ADB pairing services on the local network.
    /// Returns the first matching service's host and port.
    /// - Parameter serviceName: Optional specific service name to match (from QR code).
    /// - Parameter timeout: How long to wait for discovery.
    func discoverPairingService(serviceName: String? = nil, timeout: TimeInterval = 10) async throws -> (host: String, port: UInt16) {
        try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            let lock = NSLock()

            func safeResume(_ result: Result<(String, UInt16), Error>) {
                lock.lock()
                defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                self.browser?.cancel()
                self.browser = nil
                continuation.resume(with: result)
            }

            let descriptor = NWBrowser.Descriptor.bonjour(type: "_adb-tls-pairing._tcp", domain: nil)
            let browser = NWBrowser(for: descriptor, using: .init())

            browser.browseResultsChangedHandler = { results, _ in
                for result in results {
                    if case .service(let name, let type, let domain, _) = result.endpoint {
                        // If we have a specific service name from QR, match it
                        if let target = serviceName {
                            // QR service name may include the type suffix
                            let cleanTarget = target
                                .replacingOccurrences(of: "._adb-tls-pairing._tcp.", with: "")
                                .replacingOccurrences(of: "._adb-tls-pairing._tcp", with: "")
                            if !name.contains(cleanTarget) && !cleanTarget.contains(name) {
                                continue
                            }
                        }

                        // Resolve the service to get host and port
                        let params = NWParameters()
                        let connection = NWConnection(to: result.endpoint, using: params)
                        connection.stateUpdateHandler = { state in
                            switch state {
                            case .ready:
                                if let path = connection.currentPath,
                                   let endpoint = path.remoteEndpoint {
                                    if case .hostPort(let host, let port) = endpoint {
                                        let hostStr: String
                                        switch host {
                                        case .ipv4(let addr):
                                            hostStr = "\(addr)"
                                        case .ipv6(let addr):
                                            hostStr = "\(addr)"
                                        default:
                                            hostStr = "\(host)"
                                        }
                                        connection.cancel()
                                        safeResume(.success((hostStr, port.rawValue)))
                                    }
                                }
                            case .failed(let error):
                                connection.cancel()
                                safeResume(.failure(ADBPairing.PairingError.connectionFailed(error.localizedDescription)))
                            default:
                                break
                            }
                        }
                        connection.start(queue: self.queue)
                        return
                    }
                }
            }

            browser.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    safeResume(.failure(ADBPairing.PairingError.connectionFailed("mDNS browse failed: \(error)")))
                }
            }

            self.browser = browser
            browser.start(queue: queue)

            // Timeout
            queue.asyncAfter(deadline: .now() + timeout) {
                safeResume(.failure(ADBPairing.PairingError.timeout))
            }
        }
    }

    func cancel() {
        browser?.cancel()
        browser = nil
    }
}
