import Foundation

/// Everyday Mac operations, carried by `Step(.system, target: op.rawValue, …)`.
public enum SystemOp: String, Codable, Sendable, CaseIterable {
    case emptyTrash, openTrash, openFolder, newFolder, ejectAll
    case sleep, restart, shutdown, logout
    case darkModeOn, darkModeOff, screenshot, brightnessUp, brightnessDown, wifiOn, wifiOff, keepAwake, stopKeepAwake
    case battery, diskSpace, ipAddress, time, date, clipboard, clearClipboard
    case quitApp, hideApp, minimize, fullScreen, showDesktop, missionControl
    case playPause, nextTrack, previousTrack

    /// Can't be undone: Bolo shows a short countdown in the notch first (Esc stops it).
    public var irreversible: Bool { [.emptyTrash, .restart, .shutdown, .logout].contains(self) }

    /// Just reports something in the notch.
    public var answersOnly: Bool { [.battery, .diskSpace, .ipAddress, .time, .date, .clipboard].contains(self) }

    /// Words the user must have said before a model may choose this (risky operations only).
    public var mustHear: String? {
        switch self {
        case .emptyTrash: "trash|bin|dustbin|recycle"
        case .restart: "restart|reboot|restarts"
        case .shutdown: "shut|power off|turn off the (?:mac|computer|laptop)|band kar"
        case .logout: "log ?out|sign ?out"
        case .sleep: "sleep|so ja"
        case .quitApp: "quit|close|band"
        case .wifiOff: "wi-?fi"
        default: nil
        }
    }

    public func summary(app: String?, text: String?) -> String {
        switch self {
        case .emptyTrash: "Empty the Bin"
        case .openTrash: "Open the Bin"
        case .openFolder: "Open \(text ?? "folder")"
        case .newFolder: "New folder\(text.map { " \"\($0)\"" } ?? "")"
        case .ejectAll: "Eject drives"
        case .sleep: "Sleep"
        case .restart: "Restart the Mac"
        case .shutdown: "Shut down the Mac"
        case .logout: "Log out"
        case .darkModeOn: "Dark mode on"
        case .darkModeOff: "Dark mode off"
        case .screenshot: "Screenshot"
        case .brightnessUp: "Brighter"
        case .brightnessDown: "Dimmer"
        case .wifiOn: "Wi-Fi on"
        case .wifiOff: "Wi-Fi off"
        case .keepAwake: "Keep awake\(text.map { " for \($0)" } ?? "")"
        case .stopKeepAwake: "Stop keeping awake"
        case .battery: "Battery"
        case .diskSpace: "Disk space"
        case .ipAddress: "IP address"
        case .time: "Time"
        case .date: "Date"
        case .clipboard: "Clipboard"
        case .clearClipboard: "Clear clipboard"
        case .quitApp: "Quit \(app ?? "app")"
        case .hideApp: "Hide \(app ?? "app")"
        case .minimize: "Minimize window"
        case .fullScreen: "Full screen"
        case .showDesktop: "Show desktop"
        case .missionControl: "Mission Control"
        case .playPause: "Play/pause"
        case .nextTrack: "Next track"
        case .previousTrack: "Previous track"
        }
    }
}
