import Foundation
import UIKit

/// Matches the Rust server wire protocol (`action` from client, `event` from server).
private struct ClientUploadCommand: Encodable {
    let action = "upload"
    let filename: String
    let size: UInt64
}

private struct ClientDownloadCommand: Encodable {
    let action = "download"
    let filename: String
}

private struct ClientListCommand: Encodable {
    let action = "list"
}

private struct ServerPayload: Decodable {
    let event: String
    let filename: String?
    let size: UInt64?
    let percent: Double?
    let message: String?
    let files: [String]?
}

struct ActiveTransfer: Identifiable, Equatable {
    let id: UUID
    let filename: String
    let direction: TransferDirection
    var progress: Double
    var bytesTransferred: Int64
    var totalBytes: Int64
}

@MainActor
final class FileTransferService: ObservableObject {
    @Published var activeTransfer: ActiveTransfer?
    @Published var remoteFiles: [String] = []

    private let webSocket: WebSocketService
    private let history: TransferHistoryStore
    private let chunkSize = 512 * 1024

    private var receiveState: ReceiveState?
    private var uploadCancelled = false
    private var downloadCancelled = false
    private var pendingDownload: CheckedContinuation<Void, Error>?

    private struct ReceiveState {
        let filename: String
        let totalBytes: Int64
        var receivedBytes: Int64
        let fileHandle: FileHandle
        let destinationURL: URL
    }

    @Published var alertMessage: String?

    init(webSocket: WebSocketService, history: TransferHistoryStore) {
        self.webSocket = webSocket
        self.history = history
        webSocket.onMessage = { [weak self] message in
            Task { @MainActor in
                self?.handle(message: message)
            }
        }
        webSocket.isTransferInProgress = { [weak self] in
            self?.activeTransfer != nil
        }
        webSocket.onTransferInterrupted = { [weak self] in
            self?.handleConnectionInterrupted()
        }
    }

    private func handleConnectionInterrupted() {
        cancelActive()
        alertMessage = TransferError.connectionLost.localizedDescription
    }

    func listRemoteFiles() async throws {
        let json = String(data: try JSONEncoder().encode(ClientListCommand()), encoding: .utf8)!
        try await webSocket.send(text: json)
    }

    func upload(urls: [URL]) async throws {
        for url in urls {
            try Task.checkCancellation()
            uploadCancelled = false
            try await uploadSingle(url: url)
        }
    }

    func download(filename: String) async throws {
        downloadCancelled = false
        let command = ClientDownloadCommand(filename: filename)
        let json = String(data: try JSONEncoder().encode(command), encoding: .utf8)!

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pendingDownload = continuation
            Task {
                do {
                    try await webSocket.send(text: json)
                } catch {
                    pendingDownload = nil
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func cancelActive() {
        uploadCancelled = true
        downloadCancelled = true
        if let state = receiveState {
            try? state.fileHandle.close()
            try? FileManager.default.removeItem(at: state.destinationURL)
            receiveState = nil
        }
        pendingDownload?.resume(throwing: TransferError.cancelled)
        pendingDownload = nil
        activeTransfer = nil
    }

    // MARK: - Upload

    private func uploadSingle(url: URL) async throws {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let filename = url.lastPathComponent

        guard FileManager.default.fileExists(atPath: url.path) else {
            let message = TransferError.fileAccess(filename).localizedDescription ?? "Could not read file."
            alertMessage = message
            throw TransferError.fileAccess(filename)
        }

        let attrs: [FileAttributeKey: Any]
        do {
            attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            let message = TransferError.fileAccess(filename).localizedDescription ?? "Could not read file."
            alertMessage = message
            throw TransferError.fileAccess(filename)
        }

        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0

        guard let handle = FileHandle(forReadingAtPath: url.path) else {
            let message = TransferError.fileAccess(filename).localizedDescription ?? "Could not read file."
            alertMessage = message
            throw TransferError.fileAccess(filename)
        }
        defer { try? handle.close() }

        if size > 0, handle.readData(ofLength: 1).isEmpty {
            let message = TransferError.fileAccess(filename).localizedDescription ?? "Could not read file."
            alertMessage = message
            throw TransferError.fileAccess(filename)
        }
        try handle.seek(toOffset: 0)

        let command = ClientUploadCommand(filename: filename, size: size)
        let json = String(data: try JSONEncoder().encode(command), encoding: .utf8)!
        try await webSocket.send(text: json)

        activeTransfer = ActiveTransfer(
            id: UUID(),
            filename: filename,
            direction: .sent,
            progress: 0,
            bytesTransferred: 0,
            totalBytes: Int64(size)
        )

        var sent: UInt64 = 0
        while sent < size {
            try Task.checkCancellation()
            if uploadCancelled { throw TransferError.cancelled }

            let toRead = min(chunkSize, Int(size - sent))
            let data = handle.readData(ofLength: toRead)
            if data.isEmpty { break }

            do {
                try await webSocket.send(data: data)
            } catch {
                if case TransferError.notConnected = error {
                    throw TransferError.connectionLost
                }
                throw error
            }
            sent += UInt64(data.count)

            let percent = size > 0 ? Double(sent) / Double(size) * 100 : 100
            updateActiveProgress(bytes: Int64(sent), total: Int64(size), percent: percent)
        }

        updateActiveProgress(bytes: Int64(size), total: Int64(size), percent: 100)
    }

    private func completeUpload(filename: String, byteCount: Int64) {
        activeTransfer = nil
        let record = TransferRecord(filename: filename, direction: .sent, byteCount: byteCount)
        history.append(record)
        NotificationService.shared.notifySent(filename: filename)
        Haptics.success()
    }

    // MARK: - Incoming messages

    private func handle(message: WebSocketMessage) {
        switch message {
        case .text(let text):
            handleText(text)
        case .data(let data):
            handleBinary(data)
        }
    }

    private func handleText(_ text: String) {
        guard let data = text.data(using: .utf8),
              let payload = try? JSONDecoder().decode(ServerPayload.self, from: data) else { return }

        switch payload.event {
        case "transfer_start":
            guard let filename = payload.filename else { return }
            let size = Int64(payload.size ?? 0)
            if receiveState == nil {
                beginReceive(filename: filename, size: size)
            } else {
                updateActiveTransfer(filename: filename, size: size)
            }

        case "transfer_progress":
            if let percent = payload.percent {
                activeTransfer?.progress = percent
            }

        case "transfer_complete":
            guard let filename = payload.filename ?? receiveState?.filename else { return }
            if receiveState != nil {
                completeReceive(filename: filename)
            } else if activeTransfer?.direction == .sent, activeTransfer?.filename == filename {
                completeUpload(filename: filename, byteCount: activeTransfer?.totalBytes ?? 0)
            } else if activeTransfer?.direction == .sent {
                completeUpload(filename: filename, byteCount: activeTransfer?.totalBytes ?? 0)
            }

        case "file_list":
            remoteFiles = (payload.files ?? []).sorted()

        case "file_added":
            if let name = payload.filename, !remoteFiles.contains(name) {
                remoteFiles.insert(name, at: 0)
            }
            Task { try? await listRemoteFiles() }

        case "error":
            pendingDownload?.resume(throwing: TransferError.invalidResponse)
            pendingDownload = nil
            activeTransfer = nil

        default:
            break
        }
    }

    private func handleBinary(_ data: Data) {
        guard var state = receiveState else { return }
        state.fileHandle.write(data)
        state.receivedBytes += Int64(data.count)
        receiveState = state

        let percent = state.totalBytes > 0
            ? Double(state.receivedBytes) / Double(state.totalBytes) * 100
            : 100
        activeTransfer?.bytesTransferred = state.receivedBytes
        activeTransfer?.progress = min(percent, 100)

        if state.receivedBytes >= state.totalBytes {
            completeReceive(filename: state.filename)
        }
    }

    private func beginReceive(filename: String, size: Int64) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dest = docs.appendingPathComponent(filename)
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: dest.path) else { return }

        receiveState = ReceiveState(
            filename: filename,
            totalBytes: size,
            receivedBytes: 0,
            fileHandle: handle,
            destinationURL: dest
        )
        activeTransfer = ActiveTransfer(
            id: UUID(),
            filename: filename,
            direction: .received,
            progress: 0,
            bytesTransferred: 0,
            totalBytes: size
        )
    }

    private func updateActiveTransfer(filename: String, size: Int64) {
        activeTransfer = ActiveTransfer(
            id: UUID(),
            filename: filename,
            direction: .received,
            progress: 0,
            bytesTransferred: 0,
            totalBytes: size
        )
    }

    private func completeReceive(filename: String) {
        if let state = receiveState {
            try? state.fileHandle.close()
            receiveState = nil
            let record = TransferRecord(
                filename: filename,
                direction: .received,
                byteCount: activeTransfer?.totalBytes ?? 0
            )
            history.append(record)
            NotificationService.shared.notifyReceived(filename: filename)
            Haptics.success()
        }
        activeTransfer = nil
        pendingDownload?.resume()
        pendingDownload = nil
    }

    private func updateActiveProgress(bytes: Int64, total: Int64, percent: Double) {
        guard var transfer = activeTransfer else { return }
        transfer.bytesTransferred = bytes
        transfer.totalBytes = total
        transfer.progress = percent
        activeTransfer = transfer
    }
}

enum Haptics {
    static func success() {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.success)
    }
}
