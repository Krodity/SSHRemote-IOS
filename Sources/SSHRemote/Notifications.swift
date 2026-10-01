import Foundation
import UserNotifications

/// Per-button "command finished" notifications. The app-wide switch lives in
/// Settings (`commandNotifications`); each button opts in with `Command.notify`.
@MainActor
final class CommandNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = CommandNotifier()
    static let enabledKey = "commandNotifications"

    /// Tapping a notification opens its full output here.
    var onOpen: ((OutputSheet) -> Void)?

    private var enabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    func install() { UNUserNotificationCenter.current().delegate = self }

    /// Asks iOS once; false if the user said no (now or earlier).
    func requestPermission() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        case .denied: return false
        default: return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        }
    }

    /// `result == nil` means the command never ran (no connection); `error` says why.
    func post(for cmd: Command, command: String, host: String, result: CommandResult?,
              error: String? = nil, elapsed: TimeInterval) {
        // A held repeating button would post one per repeat.
        guard enabled, cmd.notify == true, !cmd.repeats else { return }
        let name = cmd.displayText
        let content = UNMutableNotificationContent()
        content.subtitle = host
        content.sound = .default
        if let r = result {
            content.title = r.ok ? "✓ \(name)" : "✗ \(name) — exit \(r.exitStatus ?? -1)"
            let out = r.combined.trimmingCharacters(in: .whitespacesAndNewlines)
            let took = String(format: "%.1fs", elapsed)
            if cmd.notifyOutput == true {
                content.body = out.isEmpty ? "(no output) · \(took)" : String(out.prefix(1000))
            } else {
                content.body = r.ok ? "Finished in \(took)" : "Failed after \(took)"
            }
            content.userInfo = ["title": name, "command": command,
                                "stdout": r.stdout, "stderr": r.stderr, "exit": r.exitStatus ?? -1]
        } else {
            content.title = "✗ \(name)"
            content.body = error ?? "Didn't run"
        }
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    // Show banners while the app is open too — that's where most taps happen.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions { [.banner, .list, .sound] }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let title = info["title"] as? String, let command = info["command"] as? String else { return }
        let r = CommandResult(stdout: info["stdout"] as? String ?? "", stderr: info["stderr"] as? String ?? "",
                              exitStatus: info["exit"] as? Int)
        await MainActor.run { onOpen?(OutputSheet(title: title, command: command, result: r)) }
    }
}
