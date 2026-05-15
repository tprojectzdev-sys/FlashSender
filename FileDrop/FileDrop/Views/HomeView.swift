import SwiftUI

private enum FileDropColors {
    static let background = Color(red: 13 / 255, green: 13 / 255, blue: 13 / 255)
    static let card = Color(red: 22 / 255, green: 22 / 255, blue: 24 / 255)
    static let accent = Color(red: 59 / 255, green: 130 / 255, blue: 246 / 255)
}

struct HomeView: View {
    @EnvironmentObject private var history: TransferHistoryStore
    @EnvironmentObject private var webSocket: WebSocketService
    @EnvironmentObject private var transfers: FileTransferService

    @State private var showSend = false
    @State private var showReceive = false
    @State private var scrollToHistory = false

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                FileDropColors.background.ignoresSafeArea()

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 20) {
                            connectionStatusBar

                            if webSocket.transferConnectionLost {
                                connectionLostBanner
                            }

                            HStack(spacing: 16) {
                                actionCard(
                                    title: "Send Files",
                                    symbol: "square.and.arrow.up.fill",
                                    tint: FileDropColors.accent,
                                    last: history.lastSent
                                ) {
                                    showSend = true
                                }

                                actionCard(
                                    title: "Receive Files",
                                    symbol: "square.and.arrow.down.fill",
                                    tint: Color(red: 34 / 255, green: 197 / 255, blue: 94 / 255),
                                    last: history.lastReceived
                                ) {
                                    showReceive = true
                                }
                            }

                            historySection
                                .id("history")
                        }
                        .padding()
                    }
                    .onChange(of: scrollToHistory) { _, shouldScroll in
                        guard shouldScroll else { return }
                        withAnimation {
                            proxy.scrollTo("history", anchor: .top)
                        }
                        scrollToHistory = false
                    }
                }

                if let active = transfers.activeTransfer {
                    TransferProgressView(transfer: active) {
                        transfers.cancelActive()
                    }
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .navigationTitle("FileDrop")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(FileDropColors.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .sheet(isPresented: $showSend) { SendView() }
            .sheet(isPresented: $showReceive) { ReceiveView() }
            .animation(.spring(duration: 0.35), value: transfers.activeTransfer)
            .onAppear {
                Task { await NotificationService.shared.requestPermission() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .fileDropOpenHistory)) { _ in
                scrollToHistory = true
            }
            .alert(
                "Transfer Error",
                isPresented: Binding(
                    get: { transfers.alertMessage != nil },
                    set: { if !$0 { transfers.alertMessage = nil } }
                )
            ) {
                Button("OK") { transfers.alertMessage = nil }
            } message: {
                Text(transfers.alertMessage ?? "")
            }
        }
        .preferredColorScheme(nil)
    }

    private var connectionLostBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .foregroundStyle(.orange)
            Text("Connection lost — transfer cancelled")
                .font(.subheadline)
                .foregroundStyle(.primary)
            Spacer()
            Button("Retry") {
                webSocket.acknowledgeTransferConnectionLost()
                webSocket.startDiscovery()
            }
            .font(.subheadline.bold())
            .foregroundStyle(FileDropColors.accent)
        }
        .padding(14)
        .background(Color.orange.opacity(0.15))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.orange.opacity(0.35), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var connectionStatusBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
            Text(statusText)
                .font(.subheadline.weight(.semibold))
            Spacer()
            if let url = webSocket.serverURL {
                Text(url.host ?? "")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(FileDropColors.card)
        .clipShape(Capsule())
    }

    private var statusColor: Color {
        switch webSocket.status {
        case .connected: return .green
        case .searching: return .yellow
        case .disconnected: return .red
        }
    }

    private var statusText: String {
        switch webSocket.status {
        case .connected: return "Connected"
        case .searching: return "Searching"
        case .disconnected: return "Disconnected"
        }
    }

    private func actionCard(
        title: String,
        symbol: String,
        tint: Color,
        last: TransferRecord?,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 36))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.title3.bold())
                    .foregroundStyle(.primary)
                if let last {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(last.filename)
                            .font(.caption)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                        Text(last.timestamp, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    Text("No transfers yet")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(FileDropColors.card)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Transfer History", systemImage: "clock.arrow.circlepath")
                .font(.headline)
                .foregroundStyle(FileDropColors.accent)

            if history.records.isEmpty {
                ContentUnavailableView(
                    "No History",
                    systemImage: "tray",
                    description: Text("Sent and received files appear here.")
                )
                .frame(minHeight: 160)
            } else {
                VStack(spacing: 0) {
                    ForEach(history.records) { record in
                        historyRow(record)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    history.delete(id: record.id)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        if record.id != history.records.last?.id {
                            Divider().padding(.leading, 44)
                        }
                    }
                }
                .background(FileDropColors.card)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private func historyRow(_ record: TransferRecord) -> some View {
        HStack(spacing: 12) {
            Image(systemName: record.direction == .sent ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                .foregroundStyle(record.direction == .sent ? FileDropColors.accent : .green)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.filename)
                    .font(.body)
                    .lineLimit(1)
                Text(record.timestamp, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(record.direction == .sent ? "Sent" : "Received")
                .font(.caption.bold())
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(record.direction == .sent ? FileDropColors.accent.opacity(0.2) : Color.green.opacity(0.2))
                .clipShape(Capsule())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
