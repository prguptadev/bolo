import AppKit
import BoloCore
import Foundation

/// Mac system operations: the Bin, folders, sleep/restart, dark mode, media and brightness keys,
/// Wi-Fi, battery, disk, IP, clipboard, and quitting or hiding apps.
enum SystemSkills {
    static func run(_ op: SystemOp, app: String?, text: String?, installed: [String: URL]) async throws -> String {
        switch op {
        case .emptyTrash:
            let count = (try? await MacControl.appleScript("tell application \"Finder\" to count items of trash")).flatMap { Int($0) } ?? -1
            if count == 0 { return "The Bin is already empty" }
            // Finder's own "are you sure?" is replaced by Bolo's countdown in the notch.
            try await MacControl.appleScript("""
                tell application "Finder"
                    set warned to warns before emptying of trash
                    set warns before emptying of trash to false
                    empty trash
                    set warns before emptying of trash to warned
                end tell
                """)
            return count > 0 ? "Emptied the Bin (\(count) item\(count == 1 ? "" : "s"))" : "Emptied the Bin"

        case .openTrash:
            try await MacControl.appleScript("tell application \"Finder\"\nopen trash\nactivate\nend tell")
            return "Opened the Bin"

        case .openFolder:
            let name = (text ?? "downloads").lowercased()
            let fm = FileManager.default
            let url: URL? = switch name {
            case "downloads": fm.urls(for: .downloadsDirectory, in: .userDomainMask).first
            case "desktop": fm.urls(for: .desktopDirectory, in: .userDomainMask).first
            case "documents": fm.urls(for: .documentDirectory, in: .userDomainMask).first
            case "applications": URL(fileURLWithPath: "/Applications")
            default: fm.homeDirectoryForCurrentUser
            }
            guard let url else { throw SkillError.failed("Couldn't find \(name).") }
            NSWorkspace.shared.open(url)
            return "Opened \(url.lastPathComponent)"

        case .newFolder:
            let name = text ?? "New Folder"
            try await MacControl.appleScript("""
                tell application "Finder"
                    if (count of Finder windows) > 0 then
                        set where to target of front Finder window
                    else
                        set where to desktop
                    end if
                    make new folder at where with properties {name:\(MacControl.quoted(name))}
                end tell
                """)
            return "Made folder \"\(name)\""

        case .ejectAll:
            try await MacControl.appleScript("tell application \"Finder\" to eject (every disk whose ejectable is true)")
            return "Ejected drives"

        case .sleep:
            try await MacControl.run("/usr/bin/pmset", ["sleepnow"])
            return "Sleeping"
        case .restart:
            try await MacControl.appleScript("tell application \"System Events\" to restart")
            return "Restarting"
        case .shutdown:
            try await MacControl.appleScript("tell application \"System Events\" to shut down")
            return "Shutting down"
        case .logout:
            try await MacControl.appleScript("tell application \"System Events\" to log out")
            return "Logging out"

        case .darkModeOn, .darkModeOff:
            let on = op == .darkModeOn
            try await MacControl.appleScript("tell application \"System Events\" to tell appearance preferences to set dark mode to \(on)")
            return on ? "Dark mode on" : "Dark mode off"

        case .screenshot:
            _ = try ScreenControl.pressKey("cmd+shift+3")
            return "Screenshot saved"

        case .brightnessUp, .brightnessDown:
            for _ in 0..<2 { mediaKey(op == .brightnessUp ? 2 : 3) }
            return op == .brightnessUp ? "Brighter" : "Dimmer"
        case .playPause:
            mediaKey(16)
            return "Play/pause"
        case .nextTrack:
            mediaKey(17)
            return "Next track"
        case .previousTrack:
            mediaKey(18)
            return "Previous track"

        case .wifiOn, .wifiOff:
            let ports = try await MacControl.run("/usr/sbin/networksetup", ["-listallhardwareports"])
            let device = ports.components(separatedBy: "Hardware Port: Wi-Fi").dropFirst().first?
                .range(of: "Device: (\\S+)", options: .regularExpression)
                .map { ports.components(separatedBy: "Hardware Port: Wi-Fi")[1][$0].replacingOccurrences(of: "Device: ", with: "") } ?? "en0"
            do {
                try await MacControl.run("/usr/sbin/networksetup", ["-setairportpower", device, op == .wifiOn ? "on" : "off"])
            } catch {
                throw SkillError.failed("macOS didn't allow switching Wi-Fi. Use Control Center.")
            }
            return op == .wifiOn ? "Wi-Fi on" : "Wi-Fi off"

        case .keepAwake:
            let seconds = keepAwakeSeconds(text)
            stopCaffeinate()
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
            p.arguments = ["-d", "-i", "-t", String(seconds)]
            try p.run()
            caffeinate = p
            return "Staying awake for \(seconds / 60) min"
        case .stopKeepAwake:
            stopCaffeinate()
            return "The Mac can sleep again"

        case .battery:
            let out = try await MacControl.run("/usr/bin/pmset", ["-g", "batt"])
            let line = out.split(separator: "\n").first { $0.contains("%") }.map(String.init) ?? out
            let percent = line.range(of: "\\d+%", options: .regularExpression).map { String(line[$0]) } ?? "?"
            let state = ["charging", "discharging", "charged", "finishing charge"].first { line.contains($0) } ?? ""
            let remaining = line.range(of: "\\d+:\\d+ remaining", options: .regularExpression).map { String(line[$0]) }
            return (["Battery \(percent)", state, remaining].compactMap { $0 }.filter { !$0.isEmpty }).joined(separator: ", ")

        case .diskSpace:
            let values = try URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
            let free = Double(values.volumeAvailableCapacityForImportantUsage ?? 0) / 1e9
            let total = Double(values.volumeTotalCapacity ?? 0) / 1e9
            return String(format: "%.0f GB free of %.0f GB", free, total)

        case .ipAddress:
            let local = (try? await MacControl.run("/usr/sbin/ipconfig", ["getifaddr", "en0"])) ?? ""
            var request = URLRequest(url: URL(string: "https://api.ipify.org")!, timeoutInterval: 4)
            request.setValue("Bolo", forHTTPHeaderField: "User-Agent")
            let publicIP = (try? await URLSession.shared.data(for: request)).map { String(decoding: $0.0, as: UTF8.self) } ?? ""
            return [local.isEmpty ? nil : "Local \(local)", publicIP.isEmpty ? nil : "public \(publicIP)"].compactMap { $0 }.joined(separator: ", ")

        case .time:
            return Date().formatted(date: .omitted, time: .shortened)
        case .date:
            return Date().formatted(date: .complete, time: .omitted)

        case .clipboard:
            guard let s = NSPasteboard.general.string(forType: .string), !s.isEmpty else { return "The clipboard is empty" }
            return s.count > 300 ? String(s.prefix(300)) + "…" : s
        case .clearClipboard:
            NSPasteboard.general.clearContents()
            return "Cleared the clipboard"

        case .quitApp, .hideApp:
            guard let target = runningApp(named: app) else { throw SkillError.failed("\(app ?? "That app") isn't running.") }
            if op == .quitApp {
                // Politely: the app can still ask to save your work.
                target.terminate()
                return "Quit \(target.localizedName ?? app ?? "")"
            }
            target.hide()
            return "Hid \(target.localizedName ?? app ?? "")"

        case .minimize:
            return try ScreenControl.pressKey("cmd+m").replacingOccurrences(of: "Pressed ⌘M", with: "Minimized")
        case .fullScreen:
            _ = try ScreenControl.pressKey("ctrl+cmd+f")
            return "Full screen"
        case .showDesktop:
            try await MacControl.run("/System/Applications/Mission Control.app/Contents/MacOS/Mission Control", ["1"])
            return "Showing the desktop"
        case .missionControl:
            try await MacControl.run("/usr/bin/open", ["-a", "Mission Control"])
            return "Mission Control"
        }
    }

    private static func runningApp(named name: String?) -> NSRunningApplication? {
        guard let name = name?.lowercased() else { return MacControl.frontApp() }
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        return apps.first { $0.localizedName?.lowercased() == name }
            ?? apps.first { ($0.localizedName?.lowercased() ?? "").hasPrefix(name) }
            ?? apps.first { ($0.localizedName?.lowercased() ?? "").contains(name) }
    }

    // MARK: Keep awake

    private static var caffeinate: Process?

    private static func stopCaffeinate() {
        if let p = caffeinate, p.isRunning { p.terminate() }
        caffeinate = nil
    }

    private static func keepAwakeSeconds(_ text: String?) -> Int {
        guard let text, let n = Int(text.filter(\.isNumber)) else { return 3600 }
        return text.contains("hour") ? n * 3600 : n * 60
    }

    // MARK: Media and brightness keys (the Fn-row keys, which aren't ordinary key codes)

    private static func mediaKey(_ key: Int32) {
        func post(_ down: Bool) {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xa00 : 0xb00)
            let data1 = Int((key << 16) | ((down ? 0xa : 0xb) << 8))
            let event = NSEvent.otherEvent(
                with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                context: nil, subtype: 8, data1: data1, data2: -1)
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
        post(true)
        post(false)
    }
}
