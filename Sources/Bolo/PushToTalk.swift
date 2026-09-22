import AppKit

/// Hold the right Option key to talk; release to run. Esc cancels.
/// Typing any other key while holding it (Option-shortcuts, special characters) cancels too,
/// so normal use of the Option key never triggers Bolo.
@MainActor
final class PushToTalk {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var onCancel: (() -> Void)?
    var onEscape: (() -> Void)?

    private static let rightOption: UInt16 = 61
    private static let escape: UInt16 = 53
    private var monitors: [Any] = []
    private var held = false

    func start() {
        let flags: (NSEvent) -> Void = { [weak self] e in self?.flagsChanged(e) }
        let keys: (NSEvent) -> Void = { [weak self] e in self?.keyDown(e) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flags) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { flags($0); return $0 }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: keys) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { keys($0); return $0 }) { monitors.append(m) }
    }

    private func flagsChanged(_ e: NSEvent) {
        guard e.keyCode == Self.rightOption else { return }
        let down = e.modifierFlags.contains(.option)
        if down && !held {
            held = true
            onPress?()
        } else if !down && held {
            held = false
            onRelease?()
        }
    }

    private func keyDown(_ e: NSEvent) {
        if e.keyCode == Self.escape {
            onEscape?()
        } else if held {
            held = false
            onCancel?()
        }
    }
}
