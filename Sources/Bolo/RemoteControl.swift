import Foundation

/// Lets `Bolo --remote "open calculator"` run a sentence inside the running Bolo.app, with the
/// app's own permissions, exactly as if it had been spoken. Used for testing and automation.
///
/// Protected by a random token in a file only you can read, so web pages and other users can't
/// drive it. `--dry-run` shows the plan without acting.
enum RemoteControl {
    static let notification = Notification.Name("dev.prgupta.bolo.remote")
    static let tokenURL = Settings.folder.appendingPathComponent("remote-token")

    static func token() -> String {
        if let t = try? String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), t.count >= 32 {
            return t
        }
        let t = UUID().uuidString + UUID().uuidString
        FileManager.default.createFile(atPath: tokenURL.path, contents: Data(t.utf8), attributes: [.posixPermissions: 0o600])
        return t
    }

    @MainActor
    static func listen(_ run: @escaping @MainActor (String, Bool) -> Void, observe: @escaping @MainActor (String) -> Void) {
        let expected = token()
        DistributedNotificationCenter.default().addObserver(forName: notification, object: nil, queue: .main) { note in
            let info = note.userInfo ?? [:]
            guard info["token"] as? String == expected else {
                Log.agent.error("remote command rejected (bad token)")
                return
            }
            if let app = info["observe"] as? String {
                MainActor.assumeIsolated { observe(app) }
                return
            }
            guard let text = info["text"] as? String, !text.isEmpty else { return }
            let dryRun = (info["dryRun"] as? Bool) ?? false
            MainActor.assumeIsolated { run(text, dryRun) }
        }
    }

    static func send(_ text: String, dryRun: Bool) {
        DistributedNotificationCenter.default().postNotificationName(
            notification, object: nil, userInfo: ["token": token(), "text": text, "dryRun": dryRun], deliverImmediately: true)
    }

    /// Asks the running app to write what the agent sees in `app` ("" = the app in front) to observe.txt.
    static func sendObserve(_ app: String) {
        DistributedNotificationCenter.default().postNotificationName(
            notification, object: nil, userInfo: ["token": token(), "observe": app], deliverImmediately: true)
    }

    static let observeURL = Settings.folder.appendingPathComponent("observe.txt")
}
