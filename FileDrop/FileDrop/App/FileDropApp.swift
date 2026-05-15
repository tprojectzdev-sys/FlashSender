import SwiftUI

@MainActor
final class AppEnvironment: ObservableObject {
    let history: TransferHistoryStore
    let webSocket: WebSocketService
    let transfers: FileTransferService

    init() {
        let history = TransferHistoryStore()
        let webSocket = WebSocketService()
        self.history = history
        self.webSocket = webSocket
        self.transfers = FileTransferService(webSocket: webSocket, history: history)
    }
}

@main
struct FileDropApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var env = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(env.history)
                .environmentObject(env.webSocket)
                .environmentObject(env.transfers)
                .task {
                    env.webSocket.startDiscovery()
                }
        }
    }
}
