import Foundation
import Network

/// Discovers ADB wireless debugging pairing services via mDNS (Bonjour).
final class ADBServiceBrowser: @unchecked Sendable {
    private typealias Endpoint = (host: String, port: UInt16)

    /// Owns one discovery attempt and guarantees that its continuation, browser,
    /// and resolver are completed or cancelled exactly once.
    private final class DiscoverySession: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Endpoint, Error>?
        private var pendingResult: Result<Endpoint, Error>?
        private var isFinished = false
        private var browser: NWBrowser?
        private var resolver: NWConnection?

        func install(_ continuation: CheckedContinuation<Endpoint, Error>) {
            let result: Result<Endpoint, Error>?
            lock.lock()
            if isFinished {
                result = pendingResult
                pendingResult = nil
            } else {
                self.continuation = continuation
                result = nil
            }
            lock.unlock()

            if let result {
                Self.resume(continuation, with: result)
            }
        }

        func attach(browser: NWBrowser) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !isFinished else { return false }
            self.browser = browser
            return true
        }

        func attach(resolver: NWConnection) -> Bool {
            let previousResolver: NWConnection?
            lock.lock()
            guard !isFinished else {
                lock.unlock()
                return false
            }
            previousResolver = self.resolver
            self.resolver = resolver
            lock.unlock()
            previousResolver?.cancel()
            return true
        }

        @discardableResult
        func finish(_ result: Result<Endpoint, Error>) -> Bool {
            let continuation: CheckedContinuation<Endpoint, Error>?
            let browser: NWBrowser?
            let resolver: NWConnection?

            lock.lock()
            guard !isFinished else {
                lock.unlock()
                return false
            }
            isFinished = true
            continuation = self.continuation
            self.continuation = nil
            if continuation == nil {
                pendingResult = result
            }
            browser = self.browser
            self.browser = nil
            resolver = self.resolver
            self.resolver = nil
            lock.unlock()

            resolver?.cancel()
            browser?.cancel()
            if let continuation {
                Self.resume(continuation, with: result)
            }
            return true
        }

        private static func resume(
            _ continuation: CheckedContinuation<Endpoint, Error>,
            with result: Result<Endpoint, Error>
        ) {
            switch result {
            case .success(let endpoint):
                continuation.resume(returning: endpoint)
            case .failure(let error):
                continuation.resume(throwing: error)
            }
        }
    }

    private let queue = DispatchQueue(label: "com.iadb.browser")
    private let activeSessionLock = NSLock()
    private var activeSession: DiscoverySession?

    /// Browse for ADB pairing services on the local network.
    /// Returns the first matching service's host and port.
    /// - Parameter serviceName: Optional specific service name to match (from QR code).
    /// - Parameter timeout: How long to wait for discovery.
    func discoverPairingService(
        serviceName: String? = nil,
        timeout: TimeInterval = 10
    ) async throws -> (host: String, port: UInt16) {
        let session = DiscoverySession()

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let endpoint = try await withCheckedThrowingContinuation { continuation in
                let previousSession = activate(session)
                previousSession?.finish(.failure(CancellationError()))
                session.install(continuation)

                let descriptor = NWBrowser.Descriptor.bonjour(type: "_adb-tls-pairing._tcp", domain: nil)
                let browser = NWBrowser(for: descriptor, using: .init())
                guard session.attach(browser: browser) else {
                    browser.cancel()
                    clearActive(session)
                    return
                }

                browser.browseResultsChangedHandler = { results, _ in
                    for result in results {
                        guard case .service(let name, _, _, _) = result.endpoint else { continue }

                        // If we have a specific service name from QR, match it.
                        if let target = serviceName {
                            // QR service name may include the type suffix.
                            let cleanTarget = target
                                .replacingOccurrences(of: "._adb-tls-pairing._tcp.", with: "")
                                .replacingOccurrences(of: "._adb-tls-pairing._tcp", with: "")
                            if !name.contains(cleanTarget) && !cleanTarget.contains(name) {
                                continue
                            }
                        }

                        // Resolve the service to get host and port.
                        let connection = NWConnection(to: result.endpoint, using: NWParameters())
                        guard session.attach(resolver: connection) else {
                            connection.cancel()
                            return
                        }
                        connection.stateUpdateHandler = { state in
                            switch state {
                            case .ready:
                                guard let path = connection.currentPath,
                                      let endpoint = path.remoteEndpoint,
                                      case .hostPort(let host, let port) = endpoint else {
                                    return
                                }

                                let hostString: String
                                switch host {
                                case .ipv4(let address):
                                    hostString = "\(address)"
                                case .ipv6(let address):
                                    hostString = "\(address)"
                                default:
                                    hostString = "\(host)"
                                }
                                session.finish(.success((host: hostString, port: port.rawValue)))
                                self.clearActive(session)

                            case .failed(let error):
                                session.finish(.failure(
                                    ADBPairing.PairingError.connectionFailed(error.localizedDescription)
                                ))
                                self.clearActive(session)

                            default:
                                break
                            }
                        }
                        connection.start(queue: self.queue)
                        return
                    }
                }

                browser.stateUpdateHandler = { state in
                    if case .failed(let error) = state {
                        session.finish(.failure(
                            ADBPairing.PairingError.connectionFailed("mDNS browse failed: \(error)")
                        ))
                        self.clearActive(session)
                    }
                }

                browser.start(queue: queue)

                queue.asyncAfter(deadline: .now() + timeout) {
                    session.finish(.failure(ADBPairing.PairingError.timeout))
                    self.clearActive(session)
                }
            }
            try Task.checkCancellation()
            return endpoint
        } onCancel: {
            session.finish(.failure(CancellationError()))
            self.clearActive(session)
        }
    }

    func cancel() {
        let session = takeActiveSession()
        session?.finish(.failure(CancellationError()))
    }

    private func activate(_ session: DiscoverySession) -> DiscoverySession? {
        activeSessionLock.lock()
        defer { activeSessionLock.unlock() }
        let previousSession = activeSession
        activeSession = session
        return previousSession
    }

    private func clearActive(_ session: DiscoverySession) {
        activeSessionLock.lock()
        if activeSession === session {
            activeSession = nil
        }
        activeSessionLock.unlock()
    }

    private func takeActiveSession() -> DiscoverySession? {
        activeSessionLock.lock()
        defer { activeSessionLock.unlock() }
        let session = activeSession
        activeSession = nil
        return session
    }
}
