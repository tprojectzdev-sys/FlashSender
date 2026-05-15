import SwiftUI

struct ReceiveView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var transfers: FileTransferService
    @EnvironmentObject private var webSocket: WebSocketService

    @State private var isLoading = false
    @State private var errorMessage: String?

    private let accent = Color(red: 59 / 255, green: 130 / 255, blue: 246 / 255)
    private let card = Color(red: 22 / 255, green: 22 / 255, blue: 24 / 255)

    var body: some View {
        NavigationStack {
            Group {
                if transfers.remoteFiles.isEmpty && !isLoading {
                    ContentUnavailableView(
                        "No Files on PC",
                        systemImage: "tray.and.arrow.down",
                        description: Text("Pull to refresh or wait for new files from your PC folder.")
                    )
                } else {
                    List(transfers.remoteFiles, id: \.self) { name in
                        Button {
                            Task { await download(name: name) }
                        } label: {
                            HStack {
                                Image(systemName: "doc.fill")
                                    .foregroundStyle(accent)
                                Text(name)
                                    .lineLimit(2)
                                Spacer()
                                Image(systemName: "arrow.down.circle")
                            }
                        }
                        .disabled(webSocket.status != .connected || transfers.activeTransfer != nil)
                    }
                    .refreshable {
                        await refresh()
                    }
                }
            }
            .navigationTitle("Receive Files")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(webSocket.status != .connected)
                }
            }
            .overlay {
                if isLoading {
                    ProgressView()
                }
            }
            .alert("Error", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .task {
                await refresh()
            }
        }
    }

    private func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            try await transfers.listRemoteFiles()
            try? await Task.sleep(nanoseconds: 800_000_000)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func download(name: String) async {
        isLoading = true
        defer { isLoading = false }
        do {
            try await transfers.download(filename: name)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
