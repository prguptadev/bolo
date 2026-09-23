import AVFoundation
import AppKit
import ApplicationServices
import BoloCore
import Contacts
import EventKit
import FoundationModels
import Speech

/// What a fresh Mac needs before Bolo works. Shown from the menu bar ("Check setup…") and by
/// `Bolo --doctor`. Run from Terminal, permission lines describe Terminal, not Bolo.app.
enum SetupCheck {
    struct Line {
        let ok: Bool
        let text: String
        var rendered: String { (ok ? "✓ " : "✗ ") + text }
    }

    static func run(settings: Settings = .load()) async -> [Line] {
        var lines: [Line] = []
        let os = ProcessInfo.processInfo.operatingSystemVersion
        lines.append(Line(ok: os.majorVersion >= 26, text: "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion) (needs 26+)"))

        switch SystemLanguageModel.default.availability {
        case .available:
            lines.append(Line(ok: true, text: "Apple on-device model available (fallback for unusual sentences)"))
        case .unavailable(let reason):
            lines.append(Line(ok: false, text: "Apple on-device model unavailable: \(reason). Turn on Apple Intelligence in System Settings. Everyday commands still work."))
        }

        let locale = Locale(identifier: settings.speechLocale)
        let supported = await SpeechTranscriber.supportedLocales.contains { $0.identifier == locale.identifier }
        let installed = await SpeechTranscriber.installedLocales.contains { $0.identifier == locale.identifier }
        lines.append(Line(
            ok: supported,
            text: supported
                ? "Speech recognition \(settings.speechLocale): \(installed ? "installed" : "supported, downloads on first use (needs internet)")"
                : "Speech recognition doesn't support \(settings.speechLocale). Change speechLocale in Settings."))

        lines.append(Line(ok: AXIsProcessTrusted(), text: "Accessibility (System Settings › Privacy & Security › Accessibility)"))
        lines.append(Line(ok: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized, text: "Microphone"))
        lines.append(Line(ok: CNContactStore.authorizationStatus(for: .contacts) == .authorized, text: "Contacts (to find people by name)"))
        lines.append(Line(ok: EKEventStore.authorizationStatus(for: .reminder) == .fullAccess, text: "Reminders (asked on first \"remind me\")"))
        lines.append(Line(ok: EKEventStore.authorizationStatus(for: .event) == .fullAccess, text: "Calendar (asked on first \"join my next meeting\")"))

        for (name, id) in [("WhatsApp", "net.whatsapp.WhatsApp"), ("Microsoft Teams", "com.microsoft.teams2")] {
            let found = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil
            lines.append(Line(ok: found, text: "\(name) \(found ? "installed" : "not installed")"))
        }

        if settings.brain == "qwen" {
            lines.append(Line(
                ok: QwenPlanner.isDownloaded,
                text: QwenPlanner.isDownloaded
                    ? "Brain downloaded: \(QwenPlanner.modelID) (agent, unusual phrasing, Hinglish)"
                    : "Brain not downloaded. Run: ~/Applications/Bolo.app/Contents/MacOS/Bolo --download-brain"))
        }

        let nicknames = Nicknames.load()
        lines.append(Line(ok: !nicknames.isEmpty, text: "Nicknames: \(nicknames.count) (\(Settings.nicknamesURL.path))"))

        let notch = NSScreen.screens.contains { $0.safeAreaInsets.top > 0 }
        lines.append(Line(ok: true, text: notch ? "Notch found" : "No notch on this screen; the panel shows at the top centre"))
        return lines
    }
}
