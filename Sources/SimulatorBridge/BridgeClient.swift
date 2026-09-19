import Foundation
import Network
import LiveUIModels

/// The runtime side of the connection: lives inside the app under
/// development (running in the Simulator) and talks to `BridgeServer`
/// inside the LiveUI desktop app over a local TCP socket (§7, §56).
public final class BridgeClient: ObservableObject {
    private var connection: NWConnection?
    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private var receiveBuffer = Data()

    @Published public private(set) var isConnected = false
    public var onMessage: ((BridgeMessage) -> Void)?

    public init(host: String = "127.0.0.1", port: UInt16 = 51820) {
        self.host = NWEndpoint.Host(host)
        self.port = NWEndpoint.Port(rawValue: port) ?? 51820
    }

    public func connect(appName: String, bundleIdentifier: String) {
        let connection = NWConnection(host: host, port: port, using: .tcp)
        self.connection = connection

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            DispatchQueue.main.async { self.isConnected = (state == .ready) }
            if state == .ready {
                self.send(.hello(appName: appName, bundleIdentifier: bundleIdentifier))
            }
        }
        connection.start(queue: .main)
        receiveLoop(on: connection)
    }

    public func disconnect() {
        connection?.cancel()
        connection = nil
    }

    public func send(_ message: RuntimeMessage) {
        guard let connection, let data = try? JSONEncoder().encode(message) else { return }
        connection.send(content: Framing.encode(data), completion: .contentProcessed { _ in })
    }

    private func receiveLoop(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.receiveBuffer.append(data)
                for line in Framing.extractLines(from: &self.receiveBuffer) {
                    if let message = try? JSONDecoder().decode(BridgeMessage.self, from: line) {
                        DispatchQueue.main.async { self.onMessage?(message) }
                    }
                }
            }
            if isComplete || error != nil {
                DispatchQueue.main.async { self.isConnected = false }
                return
            }
            self.receiveLoop(on: connection)
        }
    }
}
