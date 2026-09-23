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
    /// The most recent snapshot, cached regardless of whether it could
    /// actually be sent. SwiftUI's `.onPreferenceChange` (which reports
    /// this) only fires when the geometry *changes* — for a static layout
    /// that's typically once, on the very first layout pass, which can
    /// easily happen before `connect()`'s handshake finishes. Without this
    /// cache, that one snapshot is dropped and nothing is ever sent again.
    private var lastSnapshot: [RuntimeViewInfo]?

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
        if case .snapshot(let views) = message {
            lastSnapshot = views
        }
        guard let connection else {
            print("[LiveUI] BridgeClient: send() called with no connection — cached for replay on connect: \(message)")
            return
        }
        guard let data = try? JSONEncoder().encode(message) else {
            print("[LiveUI] BridgeClient: failed to encode \(message)")
            return
        }
        if case .snapshot(let views) = message {
            print("[LiveUI] BridgeClient: sending snapshot with \(views.count) view(s): \(views.map(\.id))")
        }
        connection.send(content: Framing.encode(data), completion: .contentProcessed { error in
            if let error {
                print("[LiveUI] BridgeClient: send failed — \(error)")
            }
        })
    }

    private func attemptConnection() {
        receiveBuffer = Data()
        print("[LiveUI] BridgeClient: attempting to connect to \(host):\(port)…")
        let connection = NWConnection(host: host, port: port, using: .tcp)
        self.connection = connection

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            DispatchQueue.main.async { self.isConnected = (state == .ready) }
            switch state {
            case .ready:
                print("[LiveUI] BridgeClient: connected.")
                self.send(.hello(
                    appName: self.appName,
                    bundleIdentifier: self.bundleIdentifier,
                    screenWidth: self.screenSize.width,
                    screenHeight: self.screenSize.height
                ))
                if let lastSnapshot = self.lastSnapshot {
                    print("[LiveUI] BridgeClient: replaying cached snapshot with \(lastSnapshot.count) view(s)")
                    self.send(.snapshot(views: lastSnapshot))
                }
            case .waiting(let error):
                print("[LiveUI] BridgeClient: waiting — \(error)")
            case .failed(let error):
                print("[LiveUI] BridgeClient: failed — \(error)")
                self.scheduleReconnect()
            case .cancelled:
                print("[LiveUI] BridgeClient: cancelled.")
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
