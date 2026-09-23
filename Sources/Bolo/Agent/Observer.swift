import AppKit
import ApplicationServices
import BoloCore

/// Builds what the agent sees each step: the app in front, its window, the open file or page, and a
/// numbered list of what's in it. Web pages come from the page itself (BrowserControl); every other
/// app from the macOS Accessibility tree.
enum Observer {
    /// The observation, plus what each number points at so the next action can use it.
    final class Snapshot: @unchecked Sendable {
        let observation: Observation
        /// Accessibility elements by number (native apps, or a browser whose page can't be scripted).
        let elements: [Int: AXUIElement]
        /// Set when the numbers belong to a web page (clicks go through the page).
        let browser: BrowserControl.Browser?
        let bundleID: String?

        init(observation: Observation, elements: [Int: AXUIElement], browser: BrowserControl.Browser?, bundleID: String?) {
            self.observation = observation
            self.elements = elements
            self.browser = browser
            self.bundleID = bundleID
        }

        func role(of id: Int) -> String? { observation.elements.first { $0.id == id }?.role }
        func label(of id: Int) -> String? { observation.elements.first { $0.id == id }?.label }
    }

    private static let roleNames: [String: String] = [
        "AXButton": "button", "AXLink": "link", "AXTextField": "text field", "AXTextArea": "text area",
        "AXSearchField": "search field", "AXComboBox": "combo box", "AXCheckBox": "checkbox", "AXRadioButton": "option",
        "AXPopUpButton": "pop-up menu", "AXMenuButton": "menu button", "AXTab": "tab", "AXCell": "cell", "AXRow": "row",
        "AXDisclosureTriangle": "disclosure", "AXSlider": "slider", "AXIncrementor": "stepper", "AXStaticText": "text",
        "AXHeading": "heading", "AXImage": "image", "AXMenuItem": "menu item", "AXSwitch": "switch", "AXToggle": "toggle",
        "AXSecureTextField": "password field",
    ]
    private static let fieldRoles: Set<String> = ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox", "AXSecureTextField"]
    private static let systemPrompts: Set<String> = [
        "com.apple.UserNotificationCenter", "com.apple.SecurityAgent", "com.apple.coreservices.uiagent", "com.apple.loginwindow",
    ]

    /// Chromium and Electron apps (Chrome, Slack, Teams, VS Code, Discord, Notion…) only build their
    /// web content's accessibility tree when asked. Asked once per process.
    private static let askedForTree = LockedSet()

    static func snapshot(maxElements: Int = 70) async -> Snapshot {
        guard MacControl.isTrusted, let app = MacControl.frontApp() else {
            var o = Observation(app: "unknown")
            o.note = MacControl.isTrusted ? "No app is in front." : "Bolo has no Accessibility access, so it can't see the screen."
            return Snapshot(observation: o, elements: [:], browser: nil, bundleID: nil)
        }
        let bundleID = app.bundleIdentifier
        var o = Observation(app: app.localizedName ?? "the app")
        o.bundleID = bundleID
        // "Bolo would like to control Chrome": macOS's own prompt is in front. Only you may answer it.
        if let top = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, Self.systemPrompts.contains(top) {
            o.systemDialog = true
            o.note = "macOS is showing a permission prompt. The user has to answer it."
            return Snapshot(observation: o, elements: [:], browser: nil, bundleID: bundleID)
        }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appEl, 1.0)

        let pidKey = String(app.processIdentifier)
        if !askedForTree.contains(pidKey) {
            askedForTree.insert(pidKey)
            if AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success {
                try? await Task.sleep(for: .milliseconds(400))
            }
        }

        let window = ScreenControl.element(appEl, kAXFocusedWindowAttribute)
            ?? (ScreenControl.attr(appEl, kAXWindowsAttribute) as? [AXUIElement])?.first
        if let window {
            o.window = ScreenControl.string(window, kAXTitleAttribute)
            if let doc = ScreenControl.string(window, kAXDocumentAttribute) {
                o.document = doc.hasPrefix("file://") ? URL(string: doc)?.path : doc
            }
        }
        if let bar = ScreenControl.element(appEl, kAXMenuBarAttribute) {
            o.menus = ScreenControl.children(bar).compactMap { ScreenControl.string($0, kAXTitleAttribute) }.filter { $0 != "Apple" }
        }
        if let f = ScreenControl.element(appEl, kAXFocusedUIElementAttribute) {
            let r = ScreenControl.role(f)
            var text = (roleNames[r] ?? r.replacingOccurrences(of: "AX", with: "").lowercased())
            let l = ScreenControl.label(f, role: r)
            if !l.isEmpty { text += " \"\(l)\"" }
            if fieldRoles.contains(r), r != "AXSecureTextField", let v = ScreenControl.attr(f, kAXValueAttribute) as? String, !v.isEmpty {
                text += " containing \"\(Conversation.short(v, 80))\""
            }
            o.focused = text
        }

        // A web page: read it from the page (fast, complete, and clickable by number).
        if let browser = BrowserControl.browser(for: bundleID), !BrowserControl.isScriptingOff(browser) {
            do {
                let page = try await BrowserControl.snapshot(browser, limit: maxElements)
                o.url = page.url
                o.window = page.title
                if let f = page.focused { o.focused = f }
                o.elements = page.elements.map { ScreenElement(id: $0.id, role: $0.role, label: $0.label, value: $0.value) }
                o.hidden = page.more
                let tabs = await BrowserControl.tabs(browser)
                if tabs.count > 1 { o.note = "Tabs: " + tabs.joined(separator: "; ") + ". Switch with key cmd+<number>." }
                return Snapshot(observation: o, elements: [:], browser: browser, bundleID: bundleID)
            } catch {
                Log.agent.notice("page not readable, using Accessibility: \(error.localizedDescription, privacy: .public)")
                o.note = error.localizedDescription
            }
        }

        // Everything else: walk the window's Accessibility tree off the main thread.
        guard let window else {
            o.note = (o.note.map { $0 + " " } ?? "") + "\(o.app) has no window open."
            return Snapshot(observation: o, elements: [:], browser: nil, bundleID: bundleID)
        }
        let box = AXBox(window)
        let found = await Task.detached { walk(box.el, limit: maxElements) }.value
        o.elements = found.items.map(\.element)
        o.hidden = found.hidden
        let refs = Dictionary(uniqueKeysWithValues: found.items.map { ($0.element.id, $0.ref) })
        return Snapshot(observation: o, elements: refs, browser: nil, bundleID: bundleID)
    }

    private struct Found: @unchecked Sendable {
        var items: [(element: ScreenElement, ref: AXUIElement)] = []
        var hidden = 0
    }

    /// Visible, labelled things a person could act on (plus fields, labelled or not), in reading
    /// order, controls before plain text. Budgeted: web views can hold tens of thousands of nodes.
    private static func walk(_ window: AXUIElement, limit: Int) -> Found {
        let bounds = ScreenControl.frame(window) ?? .infinite
        let deadline = Date().addingTimeInterval(1.8)
        var controls: [(String, String, String?, AXUIElement)] = []
        var texts: [(String, String, AXUIElement)] = []
        var visited = 0
        var lastLabel = ""

        func visit(_ el: AXUIElement, _ depth: Int) {
            guard visited < 6000, depth < 60, Date() < deadline else { return }
            visited += 1
            let r = ScreenControl.role(el)
            if let name = roleNames[r] {
                let isField = fieldRoles.contains(r)
                var label = ScreenControl.label(el, role: r).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                if r == "AXRadioButton", ScreenControl.string(el, kAXSubroleAttribute) == "AXTabButton" { label = label.isEmpty ? label : label }
                let visible = ScreenControl.frame(el).map { $0.width > 1 && $0.height > 1 && $0.intersects(bounds) } ?? false
                if visible, !label.isEmpty || isField {
                    if r == "AXStaticText" || r == "AXHeading" || r == "AXImage" {
                        // Text repeating the control just before it (a button's own title) adds nothing.
                        if label != lastLabel, !label.isEmpty { texts.append((name, label, el)) }
                    } else {
                        var value: String?
                        if isField, r != "AXSecureTextField" { value = (ScreenControl.attr(el, kAXValueAttribute) as? String).map { Conversation.short($0, 80) } }
                        if r == "AXCheckBox" || r == "AXSwitch" || r == "AXRadioButton" {
                            value = (ScreenControl.attr(el, kAXValueAttribute) as? NSNumber).map { $0.intValue == 1 ? "on" : "off" }
                        }
                        controls.append((name, label, value, el))
                    }
                    lastLabel = label
                }
                // Controls' insides are just their own label again.
                if r != "AXGroup", !["AXStaticText", "AXTextArea", "AXTextField", "AXSearchField"].contains(r), r != "AXRow", r != "AXCell" {
                    if r == "AXButton" || r == "AXLink" || r == "AXMenuItem" || r == "AXCheckBox" || r == "AXRadioButton" || r == "AXPopUpButton" { return }
                }
            }
            for c in ScreenControl.children(el) { visit(c, depth + 1) }
        }
        visit(window, 0)

        var found = Found()
        var n = 0
        for (name, label, value, el) in controls {
            if n >= limit { found.hidden += 1; continue }
            n += 1
            found.items.append((ScreenElement(id: n, role: name, label: label, value: value), el))
        }
        // Some plain text for context (headings, dialog messages, a chat's last lines).
        for (name, label, el) in texts.prefix(max(0, min(25, limit + 20 - n))) {
            n += 1
            found.items.append((ScreenElement(id: n, role: name, label: Conversation.short(label, 120)), el))
        }
        found.hidden += max(0, texts.count - 25)
        return found
    }
}

/// AXUIElement is a thread-safe CF reference; this lets it cross into the background walk.
private struct AXBox: @unchecked Sendable {
    let el: AXUIElement
    init(_ el: AXUIElement) { self.el = el }
}
