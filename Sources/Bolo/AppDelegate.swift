import AVFoundation
import AppKit
import ApplicationServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var agent: Agent!
    private var panel: NotchPanel!
    private var keys = PushToTalk()
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = Settings.load()
        agent = Agent(settings: settings)
        panel = NotchPanel(agent: agent)
        agent.onPhaseChange = { [weak self] phase in
            guard let self else { return }
            if phase == .idle {
                // Let the collapse animation finish before hiding the window.
                Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    if self.agent.phase == .idle { self.panel.hide() }
                }
            } else {
                self.panel.show()
            }
            self.updateIcon(listening: phase == .listening)
        }

        keys.onPress = { [weak self] in self?.agent.keyPressed() }
        keys.onRelease = { [weak self] in self?.agent.keyReleased() }
        keys.onCancel = { [weak self] in self?.agent.keyCancelled() }
        keys.onEscape = { [weak self] in self?.agent.escape() }
        keys.start()

        buildStatusItem()
        requestPermissions()
    }

    // MARK: Permissions

    private func requestPermissions() {
        // Accessibility: needed to hear the key globally and to read and press keys in other apps.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
    }

    // MARK: Menu bar

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon(listening: false)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    private func updateIcon(listening: Bool) {
        let image = NSImage(systemSymbolName: listening ? "mic.fill" : "mic", accessibilityDescription: "Bolo")
        image?.isTemplate = !listening
        statusItem?.button?.image = image
        statusItem?.button?.contentTintColor = listening ? NSColor.systemOrange : nil
    }

    @objc private func openNicknames() { NSWorkspace.shared.open(Settings.nicknamesURL) }
    @objc private func openSettings() { NSWorkspace.shared.open(Settings.settingsURL) }
    @objc private func openHistory() { NSWorkspace.shared.open(Settings.historyURL) }
    @objc private func reload() { Task { await agent.reloadNames() } }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}

extension AppDelegate: NSMenuDelegate {
    /// Rebuilt each time it opens so status lines are current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let hint = NSMenuItem(title: "Hold right ⌥ and speak · Esc stops", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        if !MacControl.isTrusted {
            menu.addItem(NSMenuItem(title: "⚠︎ Turn on Accessibility for Bolo…", action: #selector(openAccessibility), keyEquivalent: ""))
        }
        if let last = agent.lastUtterance {
            let item = NSMenuItem(title: "Last: \(last.prefix(48))", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Nicknames…", action: #selector(openNicknames), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Reload contacts and apps", action: #selector(reload), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Settings file…", action: #selector(openSettings), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "History…", action: #selector(openHistory), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Bolo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for item in menu.items where item.action != nil && item.action != #selector(NSApplication.terminate(_:)) {
            item.target = self
        }
    }
}
