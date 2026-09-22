import AppKit
import ApplicationServices
import Foundation

/// Low-level Mac control: keystrokes, Accessibility reads, AppleScript, shell tools.
enum MacControl {
    enum Key: CGKeyCode {
        case returnKey = 36, v = 9, q = 12
    }

    static func press(_ key: Key, flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: key.rawValue, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key.rawValue, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// Pastes text into whatever has keyboard focus, then puts the clipboard back.
    static func paste(_ text: String) async {
        let board = NSPasteboard.general
        let saved = board.string(forType: .string)
        board.clearContents()
        board.setString(text, forType: .string)
        press(.v, flags: .maskCommand)
        try? await Task.sleep(for: .milliseconds(400))
        board.clearContents()
        if let saved { board.setString(saved, forType: .string) }
    }

    /// Types characters as keystrokes (for apps that don't take paste, like Calculator).
    static func typeCharacters(_ text: String) {
        let source = CGEventSource(stateID: .hidSystemState)
        for ch in text {
            var units = Array(String(ch).utf16)
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            down?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            up?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
            usleep(12_000)
        }
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// The text in the focused field of an app. `nil` means the app doesn't expose it.
    static func focusedText(pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
            let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXValueAttribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    static func frontmostBundleID() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    static func running(_ bundleID: String) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    /// Runs AppleScript through osascript so the UI never blocks on a slow app.
    @discardableResult
    static func appleScript(_ source: String) async throws -> String {
        try await run("/usr/bin/osascript", ["-e", source])
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            p.terminationHandler = { proc in
                let o = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if proc.terminationStatus == 0 {
                    cont.resume(returning: o.trimmingCharacters(in: .whitespacesAndNewlines))
                } else {
                    cont.resume(throwing: SkillError.failed(e.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }

    /// Escapes a Swift string for use inside an AppleScript string literal.
    static func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

enum SkillError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self { case .failed(let why): why }
    }
}
