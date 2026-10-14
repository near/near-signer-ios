import Foundation
import NearSignerCore
import Network

enum BridgeStatus: Equatable {
    case off
    case listening(connections: Int)
    case failed(String)
}

#if targetEnvironment(simulator)
/// Test transport for the iOS Simulator, which has no Bluetooth. It is compiled into Simulator
/// builds only: device builds talk Bluetooth and nothing else.
///
/// It speaks Speculos framing (`u32 BE length ‖ APDU`) on 127.0.0.1:9999. The Simulator shares
/// the Mac's loopback interface, so `near-signer-host --tcp 127.0.0.1:9999` on the Mac reaches it.
final class SimulatorBridge: @unchecked Sendable {
    static let port: UInt16 = 9999

    private final class Handler {
        let connection: NWConnection
        let session: NearAppSession
        var decoder = TCPFrameDecoder()
        var task: Task<Void, Never>?

        init(connection: NWConnection, session: NearAppSession) {
            self.connection = connection
            self.session = session
        }
    }

    private let queue = DispatchQueue(label: "near-signer.simulator-bridge")
    private let makeSession: @Sendable (String) -> NearAppSession
    private let onStatus: @Sendable (BridgeStatus) -> Void

    // Confined to `queue`.
    private var listener: NWListener?
    private var handlers: [ObjectIdentifier: Handler] = [:]

    init(makeSession: @escaping @Sendable (String) -> NearAppSession,
         onStatus: @escaping @Sendable (BridgeStatus) -> Void) {
        self.makeSession = makeSession
        self.onStatus = onStatus
    }

    func start() {
        queue.async {
            guard self.listener == nil, let port = NWEndpoint.Port(rawValue: SimulatorBridge.port) else { return }
            do {
                let parameters = NWParameters.tcp
                parameters.acceptLocalOnly = true
                parameters.allowLocalEndpointReuse = true
                parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: port)
                let listener = try NWListener(using: parameters)
                listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.publishStatus()
                    case let .failed(error):
                        self.onStatus(.failed(error.localizedDescription))
                    default:
                        break
                    }
                }
                listener.start(queue: self.queue)
                self.listener = listener
            } catch {
                self.onStatus(.failed(error.localizedDescription))
            }
        }
    }

    func stop() {
        queue.async {
            self.listener?.stateUpdateHandler = nil
            self.listener?.cancel()
            self.listener = nil
            for handler in self.handlers.values { self.close(handler) }
            self.handlers.removeAll()
            self.onStatus(.off)
        }
    }

    private func publishStatus() {
        guard listener != nil else { return }
        onStatus(.listening(connections: handlers.count))
    }

    private func accept(_ connection: NWConnection) {
        let handler = Handler(connection: connection, session: makeSession("Simulator"))
        handlers[ObjectIdentifier(handler)] = handler
        connection.stateUpdateHandler = { [weak self, weak handler] state in
            guard let self, let handler else { return }
            switch state {
            case .ready:
                self.receive(on: handler)
            case .failed, .cancelled:
                self.close(handler)
            default:
                break
            }
        }
        connection.start(queue: queue)
        publishStatus()
    }

    private func close(_ handler: Handler) {
        handler.task?.cancel()
        handler.connection.stateUpdateHandler = nil
        handler.connection.cancel()
        if handlers.removeValue(forKey: ObjectIdentifier(handler)) != nil {
            publishStatus()
        }
    }

    /// Reads, then processes complete APDUs in order before reading again.
    private func receive(on handler: Handler) {
        handler.connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { handler.decoder.append(data) }
            var messages: [Data] = []
            do {
                while let message = try handler.decoder.nextMessage() { messages.append(message) }
            } catch {
                self.close(handler)
                return
            }
            if error != nil || isComplete {
                self.close(handler)
                return
            }
            guard !messages.isEmpty else {
                self.receive(on: handler)
                return
            }
            handler.task = Task { [weak self] in
                for message in messages {
                    let response = await handler.session.handle(message)
                    if Task.isCancelled { return }
                    await SimulatorBridge.send(TCPFrameDecoder.encodeResponse(response), on: handler.connection)
                }
                guard let self else { return }
                self.queue.async { self.receive(on: handler) }
            }
        }
    }

    private static func send(_ data: Data, on connection: NWConnection) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: data, completion: .contentProcessed { _ in continuation.resume() })
        }
    }
}
#endif
