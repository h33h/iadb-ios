import Foundation
import Network
import Security

/// NWProtocolFramer that implements ADB's STLS (StartTLS) protocol upgrade.
///
/// Protocol flow handled internally by the framer:
/// 1. Send CNXN over plain TCP
/// 2. Receive A_STLS from device (device requests TLS upgrade)
/// 3. Send A_STLS back
/// 4. Dynamically add TLS 1.3 to the protocol stack
/// 5. Mark ready — NWConnection enters .ready after TLS handshake completes
///
/// After the framer marks ready, it enters passthrough mode. All subsequent
/// data flows through TLS transparently — the app reads/writes ADB messages
/// as if talking over a plain connection.
final class ADBSTLSFramer: NWProtocolFramerImplementation {

    // MARK: - Configuration (set before creating NWConnection)

    /// Client TLS identity for mTLS — must be set before connection starts.
    nonisolated(unsafe) static var clientIdentity: SecIdentity?

    // MARK: - Protocol Definition

    static let label = "ADB-STLS"
    static let definition = NWProtocolFramer.Definition(implementation: ADBSTLSFramer.self)

    // MARK: - State

    private enum FramerState {
        case sendingCNXN
        case waitingForSTLS
        case upgrading
        case ready
    }

    private var state: FramerState = .sendingCNXN

    required init(framer: NWProtocolFramer.Instance) {}

    // MARK: - Framer Lifecycle

    func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult {
        // Send CNXN as the first message over plain TCP
        let cnxnMsg = ADBMessage.connectMessage()
        framer.writeOutput(data: cnxnMsg.serialized)
        state = .waitingForSTLS
        return .willMarkReady
    }

    func handleInput(framer: NWProtocolFramer.Instance) -> Int {
        guard state == .waitingForSTLS else { return 0 }

        // Try to parse ADB message header (24 bytes)
        var headerData = Data()
        let headerParsed = framer.parseInput(
            minimumIncompleteLength: ADBMessage.headerSize,
            maximumLength: ADBMessage.headerSize
        ) { buffer, _ in
            guard let buffer = buffer, buffer.count >= ADBMessage.headerSize else { return 0 }
            headerData = Data(buffer)
            return ADBMessage.headerSize
        }

        guard headerParsed, !headerData.isEmpty else {
            return ADBMessage.headerSize  // need more data
        }

        guard let header = ADBMessage.parseHeader(from: headerData) else {
            // Invalid header — let the connection fail
            framer.markFailed(error: NWError.posix(.EPROTO))
            return 0
        }

        // Consume payload if present
        if header.dataLength > 0 {
            let payloadLen = Int(header.dataLength)
            var consumed = false
            framer.parseInput(
                minimumIncompleteLength: payloadLen,
                maximumLength: payloadLen
            ) { buffer, _ in
                guard let buffer = buffer, buffer.count >= payloadLen else { return 0 }
                consumed = true
                return payloadLen
            }
            if !consumed {
                // Need more data for payload — but we already consumed header.
                // This is a problem. For ADB, STLS has no payload, so this shouldn't happen.
                framer.markFailed(error: NWError.posix(.EPROTO))
                return 0
            }
        }

        let command = ADBCommand(rawValue: header.command)

        switch command {
        case .stls:
            // Device requests TLS upgrade — send STLS back
            let stlsMsg = ADBMessage.stlsMessage()
            framer.writeOutput(data: stlsMsg.serialized)

            // Dynamically add TLS 1.3 between framer and TCP
            let tlsOptions = NWProtocolTLS.Options()

            sec_protocol_options_set_min_tls_protocol_version(
                tlsOptions.securityProtocolOptions,
                .TLSv13
            )

            // Accept self-signed server certificates
            sec_protocol_options_set_verify_block(
                tlsOptions.securityProtocolOptions,
                { _, _, completionHandler in completionHandler(true) },
                DispatchQueue.global(qos: .userInitiated)
            )

            // Provide client certificate for mutual TLS
            if let identity = Self.clientIdentity,
               let secIdentity = sec_identity_create(identity) {
                sec_protocol_options_set_local_identity(
                    tlsOptions.securityProtocolOptions,
                    secIdentity
                )
            }

            // Insert TLS into the protocol stack (below framer, above TCP)
            do {
                try framer.prependApplicationProtocol(options: tlsOptions)
            } catch {
                framer.markFailed(error: NWError.posix(.EPROTO))
                return 0
            }

            // Switch to passthrough — all future data flows through TLS transparently
            framer.passThroughInput()
            framer.passThroughOutput()

            state = .ready
            framer.markReady()
            return 0

        default:
            // Device responded with something other than STLS (e.g., CNXN on a non-TLS port).
            // This framer only handles STLS; unexpected responses are protocol errors.
            framer.markFailed(error: NWError.posix(.EPROTO))
            return 0
        }
    }

    func handleOutput(framer: NWProtocolFramer.Instance, message: NWProtocolFramer.Message, messageLength: Int, isComplete: Bool) {
        // In passthrough mode (after markReady), this won't be called.
        // Before markReady, the app shouldn't be sending data.
        do {
            try framer.writeOutputNoCopy(length: messageLength)
        } catch {
            // Ignore write errors during negotiation
        }
    }

    func wakeup(framer: NWProtocolFramer.Instance) {}

    func stop(framer: NWProtocolFramer.Instance) -> Bool {
        return true
    }

    func cleanup(framer: NWProtocolFramer.Instance) {}
}
