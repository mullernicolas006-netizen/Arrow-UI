import Foundation
import Network
import CoreGraphics
import LiveUIModels

/// The runtime side of the connection: lives inside the app under
/// development (running in the Simulator) and talks to `BridgeServer`
/// inside the LiveUI desktop app over a local TCP socket (§7, §56).
public final class BridgeClient: ObservableObject {
    private var connection: NWConnection?
    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private var receiveBuffer = Data()

    private var shouldReconnect = false
    private var reconnectTask: Task<Void, Never>?
    private var appName = ""
    private var bundleIdentifier = ""
    private var screenSize: CGSize = .zero

    @Published public private(set) var isConnected = false
    public var onMessage: ((BridgeMessage) -> Void)?

    public init(host: String = "127.0.0.1", port: UInt16 = 51820) {
        self.host = NWEndpoint.Host(host)
        self.port = NWEndpoint.Port(rawValue: port) ?? 51820
    }

    /// Connects to the LiveUI desktop app, and keeps retrying (once a
    /// second) if it isn't listening yet or the connection drops. There's
    /// no reliable ordering between "the Simulator app launches" and "the
    /// LiveUI desktop app is up and listening" — whichever starts first,
    /// or gets restarted while the other keeps running, needs this side to
    /// keep trying rather than give up after one failed attempt.
    public func connect(appName: String, bundleIdentifier: String, screenSize: CGSize) {
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.screenSize = screenSize
        shouldReconnect = true
        attemptConnection()
    }

    public func disconnect() {
        shouldReconnect = false
        reconnectTask?.cancel()
        reconnectTask = nil
        connection?.cancel()
        connection = nil
    }

    public func send(_ message: RuntimeMessage) {
        guard let connection, let data = try? JSONEncoder().encode(message) else { return }
        connection.send(content: Framing.encode(data), completion: .contentProcessed { _ in })
    }

    private func attemptConnection() {
        receiveBuffer = Data()
        let connection = NWConnection(host: host, port: port, using: .tcp)
        self.connection = connection

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            DispatchQueue.main.async { self.isConnected = (state == .ready) }
            switch state {
            case .ready:
                self.send(.hello(
                    appName: self.appName,
                    bundleIdentifier: self.bundleIdentifier,
                    screenWidth: self.screenSize.width,
                    screenHeight: self.screenSize.height
                ))
            case .failed, .cancelled:
                self.scheduleReconnect()
            default:
                break
            }
        }
        connection.start(queue: .main)
        receiveLoop(on: connection)
    }

    private func scheduleReconnect() {
        guard shouldReconnect else { return }
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let self, self.shouldReconnect else { return }
            self.attemptConnection()
        }
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
