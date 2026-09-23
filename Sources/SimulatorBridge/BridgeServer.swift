import Foundation
import Network
import LiveUIModels

/// The desktop-app side of the connection: listens locally for a
/// `BridgeClient` running inside an app in the Simulator (§7, §50).
public final class BridgeServer: ObservableObject {
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var buffers: [ObjectIdentifier: Data] = [:]

    @Published public private(set) var connectedAppCount: Int = 0
    /// A listener failure discovered *after* `start()` returns — e.g. "port
    /// already in use" only shows up asynchronously via Network.framework's
    /// state callback, not as a thrown error from `start()` itself, so
    /// `start()` can return successfully while the listener still ends up
    /// never actually accepting anything. Surfacing this is what makes
    /// that failure visible instead of a silently-stuck-red status dot.
    @Published public private(set) var lastError: String?
    public var onMessage: ((RuntimeMessage) -> Void)?

    public init() {}

    public func start(port: UInt16 = 51820) throws {
        let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port) ?? 51820)
        listener.newConnectionHandler = { [weak self] connection in
            print("[LiveUI] BridgeServer: incoming connection from \(connection.endpoint)")
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            print("[LiveUI] BridgeServer: listener state -> \(state)")
            if case .failed(let error) = state {
                let message = "Could not listen on port \(port): \(error). Another LiveUIApp instance is probably still running — try `killall LiveUIApp` in Terminal, then relaunch."
                DispatchQueue.main.async { self?.lastError = message }
            }
        }
        listener.start(queue: .main)
        self.listener = listener
        print("[LiveUI] BridgeServer: listening on port \(port)")
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
        buffers.removeAll()
        connectedAppCount = 0
    }

    /// Sends a message to every connected app. In practice there's usually
    /// exactly one (the app currently running in the Simulator).
    public func broadcast(_ message: BridgeMessage) {
        guard let data = try? JSONEncoder().encode(message) else { return }
        let framed = Framing.encode(data)
        for connection in connections.values {
            connection.send(content: framed, completion: .contentProcessed { _ in })
        }
    }

    private func accept(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        buffers[key] = Data()
        connectedAppCount = connections.count

        connection.stateUpdateHandler = { [weak self] state in
            print("[LiveUI] BridgeServer: connection \(key) state -> \(state)")
            switch state {
            case .failed, .cancelled:
                self?.remove(key)
            default:
                break
            }
        }
        connection.start(queue: .main)
        receive(on: connection, key: key)
    }

    private func remove(_ key: ObjectIdentifier) {
        connections.removeValue(forKey: key)
        buffers.removeValue(forKey: key)
        connectedAppCount = connections.count
    }

    private func receive(on connection: NWConnection, key: ObjectIdentifier) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffers[key, default: Data()].append(data)
                if var buffer = self.buffers[key] {
                    for line in Framing.extractLines(from: &buffer) {
                        do {
                            let message = try JSONDecoder().decode(RuntimeMessage.self, from: line)
                            if case .snapshot(let views) = message {
                                print("[LiveUI] BridgeServer: received snapshot with \(views.count) view(s): \(views.map(\.id))")
                            } else {
                                print("[LiveUI] BridgeServer: received \(message)")
                            }
                            DispatchQueue.main.async { self.onMessage?(message) }
                        } catch {
                            print("[LiveUI] BridgeServer: FAILED to decode message (\(error)) — raw: \(String(data: line, encoding: .utf8) ?? "<non-utf8, \(line.count) bytes>")")
                        }
                    }
                    self.buffers[key] = buffer
                }
            }
            if isComplete || error != nil {
                self.remove(key)
                return
            }
            self.receive(on: connection, key: key)
        }
    }
}
