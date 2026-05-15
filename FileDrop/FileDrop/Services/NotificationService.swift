import Foundation
import UserNotifications

@MainActor
final class NotificationService {
    static let shared = NotificationService()

    private var didRequestPermission = false

    private init() {}

    /// Request notification permission once (call from HomeView `.onAppear`).
    func requestPermission() async {
        guard !didRequestPermission else { return }
        didRequestPermission = true
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    func notifySent(filename: String) {
        schedule(
            identifier: "sent-\(UUID().uuidString)",
            title: "✅ FileDrop",
            body: "\(filename) sent"
        )
    }

    func notifyReceived(filename: String) {
        schedule(
            identifier: "recv-\(UUID().uuidString)",
            title: "📥 FileDrop",
            body: "\(filename) received"
        )
    }

    private func schedule(identifier: String, title: String, body: String) {
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized else { return }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: identifier,
                content: content,
                trigger: nil
            )
            try? await center.add(request)
        }
    }
}
