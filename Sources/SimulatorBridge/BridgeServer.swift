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
    public var onMessage: ((RuntimeMessage) -> Void)?

    public init() {}

    public func start(port: UInt16 = 51820) throws {
        let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port) ?? 51820)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: .main)
        self.listener = listener
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
                        if let message = try? JSONDecoder().decode(RuntimeMessage.self, from: line) {
                            DispatchQueue.main.async { self.onMessage?(message) }
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
