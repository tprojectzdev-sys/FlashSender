import Foundation

enum ConnectionStatus: Equatable {
    case searching
    case connected
    case disconnected
}

enum WebSocketMessage {
    case text(String)
    case data(Data)
}

@MainActor
final class WebSocketService: ObservableObject {
    @Published private(set) var status: ConnectionStatus = .searching
    @Published private(set) var serverURL: URL?
    /// Set when the socket drops while a file transfer is in progress.
    @Published private(set) var transferConnectionLost = false

    var onMessage: ((WebSocketMessage) -> Void)?
    var isTransferInProgress: (() -> Bool)?
    var onTransferInterrupted: (() -> Void)?

    private var task: URLSessionWebSocketTask?
    private let session: URLSession
    private var receiveLoopTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var shouldReconnect = true
    private var backoffSeconds: Double = 1
    private let maxBackoff: Double = 30
    private let defaultPort = 8765

    private var targetHost: String?
    private var targetPort: Int = 8765

    init() {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        session = URLSession(configuration: config)
    }

    func startDiscovery() {
        shouldReconnect = true
        transferConnectionLost = false
        status = .searching
        reconnectTask?.cancel()
        reconnectTask = Task { await connectWithDiscovery() }
    }

    func acknowledgeTransferConnectionLost() {
        transferConnectionLost = false
    }

    func disconnect() {
        shouldReconnect = false
        reconnectTask?.cancel()
        receiveLoopTask?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        status = .disconnected
        serverURL = nil
    }

    func send(text: String) async throws {
        guard let task else { throw TransferError.notConnected }
        do {
            try await task.send(.string(text))
        } catch {
            handleSendFailure()
            throw error
        }
    }

    func send(data: Data) async throws {
        guard let task else { throw TransferError.notConnected }
        do {
            try await task.send(.data(data))
        } catch {
            handleSendFailure()
            throw error
        }
    }

    // MARK: - Connection

    private func connectWithDiscovery() async {
        status = .searching
        targetHost = nil
        targetPort = defaultPort

        let discovery = MDNSDiscoveryService()
        let discovered = await discovery.discover(timeout: 5)

        if let discovered {
            targetHost = discovered.host
            targetPort = discovered.port
        } else {
            targetHost = "127.0.0.1"
            targetPort = defaultPort
        }

        await openWebSocket()
    }

    private func openWebSocket() async {
        guard shouldReconnect, let host = targetHost else { return }

        let urlString = "ws://\(host):\(targetPort)/"
        guard let url = URL(string: urlString) else {
            scheduleReconnect()
            return
        }

        receiveLoopTask?.cancel()
        task?.cancel(with: .goingAway, reason: nil)

        let wsTask = session.webSocketTask(with: url)
        task = wsTask
        serverURL = url
        wsTask.resume()

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                wsTask.sendPing { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
            status = .connected
            backoffSeconds = 1
            startReceiveLoop()
        } catch {
            status = .disconnected
            publishTransferInterruptedIfNeeded()
            scheduleReconnect()
        }
    }

    private func startReceiveLoop() {
        receiveLoopTask?.cancel()
        receiveLoopTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard let task = self.task else { break }
                do {
                    let message = try await task.receive()
                    switch message {
                    case .string(let text):
                        self.onMessage?(.text(text))
                    case .data(let data):
                        self.onMessage?(.data(data))
                    @unknown default:
                        break
                    }
                } catch {
                    self.publishTransferInterruptedIfNeeded()
                    if self.shouldReconnect {
                        self.status = .disconnected
                        self.scheduleReconnect()
                    }
                    break
                }
            }
        }
    }

    private func handleSendFailure() {
        publishTransferInterruptedIfNeeded()
        status = .disconnected
        scheduleReconnect()
    }

    private func publishTransferInterruptedIfNeeded() {
        guard isTransferInProgress?() == true else { return }
        transferConnectionLost = true
        onTransferInterrupted?()
    }

    private func scheduleReconnect() {
        guard shouldReconnect else { return }
        status = .searching
        let delay = backoffSeconds
        backoffSeconds = min(backoffSeconds * 2, maxBackoff)

        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            await self.connectWithDiscovery()
        }
    }
}

enum TransferError: LocalizedError {
    case notConnected
    case cancelled
    case invalidResponse
    case connectionLost
    case fileAccess(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected to PC"
        case .cancelled:
            return "Transfer cancelled"
        case .invalidResponse:
            return "Unexpected server response"
        case .connectionLost:
            return "Connection lost — transfer cancelled"
        case .fileAccess(let filename):
            return "Could not read \(filename). Check file permissions."
        }
    }
}
