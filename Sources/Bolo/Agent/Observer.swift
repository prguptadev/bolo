import AppKit
import ApplicationServices
import BoloCore

/// Builds what the agent sees each step: the app in front, its window, the open file or page, and a
/// numbered list of what's in it. Web pages come from the page itself when the browser allows it
/// (BrowserControl); otherwise, and for every other app, from the macOS Accessibility tree.
enum Observer {
    /// The observation, plus what each number points at so the next action can use it.
    final class Snapshot: @unchecked Sendable {
        let observation: Observation
        /// Accessibility elements by number (native apps, or a browser whose page can't be scripted).
        let elements: [Int: AXUIElement]
        /// Set when the numbers belong to a web page (clicks go through the page).
        let browser: BrowserControl.Browser?
        let bundleID: String?
        /// How the walk went (for the --observe dump and bug hunts).
        var stats = ""

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
        "AXButton": "button", "AXLink": "link", "AXTextField": "field", "AXTextArea": "textarea",
        "AXSearchField": "search", "AXComboBox": "combo", "AXCheckBox": "checkbox", "AXRadioButton": "option",
        "AXPopUpButton": "popup", "AXMenuButton": "menubutton", "AXTab": "tab", "AXCell": "cell", "AXRow": "row",
        "AXDisclosureTriangle": "disclosure", "AXSlider": "slider", "AXIncrementor": "stepper", "AXStaticText": "text",
        "AXHeading": "heading", "AXImage": "icon", "AXMenuItem": "menu item", "AXSwitch": "switch", "AXToggle": "toggle",
        "AXSecureTextField": "password field", "AXWebArea": "editor",
    ]
    private static let fieldRoles: Set<String> = ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox", "AXSecureTextField"]
    private static let systemPrompts: Set<String> = [
        "com.apple.UserNotificationCenter", "com.apple.SecurityAgent", "com.apple.coreservices.uiagent", "com.apple.loginwindow",
    ]

    /// Chromium and Electron apps (Chrome, Slack, Teams, VS Code, Discord, Notion…) only build their
    /// web content's accessibility tree when an assistive app asks. Asked once per process.
    private static let askedForTree = LockedSet()

    /// Goals that are about reading what's there get more of the text.
    static func wantsText(_ goal: String) -> Bool {
        goal.range(of: "\\b(read|summari[sz]e|summary|what does|what'?s on|what is on|tell me what|explain|translate|says?|content|padho|kya likha|kya hai)\\b",
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// `target`: an app other than the one in front (the `--observe` debug dump).
    static func snapshot(target: NSRunningApplication? = nil, goal: String = "", maxElements: Int = 40) async -> Snapshot {
        guard MacControl.isTrusted, let app = target ?? MacControl.frontApp() else {
            var o = Observation(app: "unknown")
            o.note = MacControl.isTrusted ? "No app is in front." : "Bolo has no Accessibility access, so it can't see the screen."
            return Snapshot(observation: o, elements: [:], browser: nil, bundleID: nil)
        }
        let bundleID = app.bundleIdentifier
        var o = Observation(app: app.localizedName ?? "the app")
        o.bundleID = bundleID
        // "Bolo would like to control Chrome": macOS's own prompt is in front. Only you may answer it.
        if target == nil, let top = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, Self.systemPrompts.contains(top) {
            o.systemDialog = true
            o.note = "macOS is showing a permission prompt. The user has to answer it."
            return Snapshot(observation: o, elements: [:], browser: nil, bundleID: bundleID)
        }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appEl, 1.5)
        let textLimit = wantsText(goal) ? 3000 : 300

        let pidKey = String(app.processIdentifier)
        if !askedForTree.contains(pidKey) {
            askedForTree.insert(pidKey)
            // Electron listens for the first, Chromium (Chrome, Edge, Brave…) for the second.
            let a = AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            let b = AXUIElementSetAttributeValue(appEl, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            Log.agent.notice("\(o.app, privacy: .public): AXManualAccessibility \(a.rawValue), AXEnhancedUserInterface \(b.rawValue)")
            if a == .success || b == .success { try? await Task.sleep(for: .milliseconds(700)) }
        }

        let browser = BrowserControl.browser(for: bundleID)
        if let browser {
            // A page still loading shows the model half a screen; wait a little for it.
            for _ in 0..<8 where await BrowserControl.isLoading(browser) {
                try? await Task.sleep(for: .milliseconds(400))
            }
            let tabs = await BrowserControl.tabs(browser)
            if tabs.count > 1 { o.note = "Tabs: " + tabs.joined(separator: "; ") + ". Switch with the tab tool." }
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

        // A web page, read from the page (fast, complete, and clickable by number).
        if let browser, !BrowserControl.isScriptingOff(browser) {
            do {
                let page = try await BrowserControl.snapshot(browser, limit: maxElements)
                o.url = page.url
                o.window = page.title
                if let f = page.focused { o.focused = f }
                o.elements = page.elements.map { ScreenElement(id: $0.id, role: $0.role, label: $0.label, value: $0.value) }
                o.hidden = page.more
                o.text = try? await BrowserControl.pageText(browser, limit: textLimit)
                return Snapshot(observation: o, elements: [:], browser: browser, bundleID: bundleID)
            } catch {
                Log.agent.notice("page not readable, using Accessibility: \(error.localizedDescription, privacy: .public)")
            }
        }
        if let browser { o.url = await BrowserControl.currentURL(browser) }

        // Everything else: walk the window's Accessibility tree off the main thread.
        guard let window else {
            o.note = (o.note.map { $0 + " " } ?? "") + "\(o.app) has no window open."
            return Snapshot(observation: o, elements: [:], browser: nil, bundleID: bundleID)
        }
        let box = AXBox(window)
        var found = await Task.detached { walk(box.el, limit: maxElements, textLimit: textLimit) }.value
        // Chrome switches its accessibility on a few seconds after an assistive app starts asking:
        // until then its tree has plenty of nodes but no names or frames. Wait for it, once per
        // process. (A genuinely small window, like Terminal's, has few nodes: no waiting.)
        var tries = 0
        while found.visited > 60, found.items.count < 3, tries < 4, !askedForTree.contains(pidKey + "-warm") {
            tries += 1
            try? await Task.sleep(for: .milliseconds(800))
            found = await Task.detached { walk(box.el, limit: maxElements, textLimit: textLimit) }.value
        }
        if found.items.count >= 3 || tries == 4 { askedForTree.insert(pidKey + "-warm") }
        o.elements = found.items.map(\.element)
        o.hidden = found.hidden
        o.text = found.text.isEmpty ? nil : found.text
        let refs = Dictionary(uniqueKeysWithValues: found.items.map { ($0.element.id, $0.ref) })
        let snap = Snapshot(observation: o, elements: refs, browser: nil, bundleID: bundleID)
        snap.stats = found.stats
        return snap
    }

    private struct Found: @unchecked Sendable {
        var items: [(element: ScreenElement, ref: AXUIElement)] = []
        var hidden = 0
        /// Plain text on screen (headings, messages, paragraphs), for context and reading.
        var text = ""
        var stats = ""
        var visited = 0
    }

    private static let skipInside: Set<String> = [
        "AXButton", "AXLink", "AXMenuItem", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXTab",
        "AXStaticText", "AXTextField", "AXSearchField", "AXComboBox", "AXSecureTextField", "AXSlider", "AXIncrementor",
    ]

    /// Visible, labelled things a person could act on (plus fields, labelled or not), in reading
    /// order, controls before plain text. Budgeted: web views can hold tens of thousands of nodes.
    private static func walk(_ window: AXUIElement, limit: Int, textLimit: Int) -> Found {
        let bounds = ScreenControl.frame(window) ?? .infinite
        let deadline = Date().addingTimeInterval(2.0)
        var controls: [(String, String, String?, AXUIElement)] = []
        var texts: [(String, String, AXUIElement)] = []
        /// Every visible bit of static text with where it is, to name unlabelled fields ("To:" left of a box).
        var textFrames: [(String, CGRect)] = []
        var visited = 0
        var lastLabel = ""
        var roles: [String: Int] = [:]
        var sample: [String] = []
        let started = Date()

        func visit(_ el: AXUIElement, _ depth: Int) {
            guard visited < 8000, depth < 60, Date() < deadline else { return }
            visited += 1
            let r = ScreenControl.role(el)
            roles[r, default: 0] += 1
            if let name = roleNames[r] {
                let isField = fieldRoles.contains(r)
                var label = ScreenControl.label(el, role: r).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                let frame = ScreenControl.frame(el)
                let visible = frame.map { $0.width > 1 && $0.height > 1 && $0.intersects(bounds) } ?? false
                if r == "AXStaticText", visible, let frame, !label.isEmpty { textFrames.append((label, frame)) }
                // A web view that can be typed in (a mail body, an editor) is worth a click; a plain page isn't.
                if r == "AXWebArea" {
                    guard visible, (ScreenControl.attr(el, "AXEditable" as String) as? Bool) == true || ScreenControl.children(el).isEmpty else {
                        for c in ScreenControl.children(el) { visit(c, depth + 1) }
                        return
                    }
                    if label.isEmpty { label = "message body" }
                }
                if sample.count < 10, r != "AXStaticText" {
                    sample.append("\(r.dropFirst(2)) t=\(ScreenControl.string(el, kAXTitleAttribute) ?? "-") d=\(ScreenControl.string(el, kAXDescriptionAttribute) ?? "-") v=\((ScreenControl.attr(el, kAXValueAttribute) as? String) ?? "-") \(frame.map(rect) ?? "no frame") win=\(rect(bounds))")
                }
                if visible, !label.isEmpty || isField {
                    if r == "AXStaticText" || r == "AXHeading" {
                        // Text repeating the control just before it (a button's own title) adds nothing.
                        if label != lastLabel, !label.isEmpty { texts.append((name, label, el)) }
                    } else {
                        var value: String?
                        if isField, r != "AXSecureTextField" { value = (ScreenControl.attr(el, kAXValueAttribute) as? String).map { Conversation.short($0, 80) } }
                        if r == "AXCheckBox" || r == "AXSwitch" || r == "AXRadioButton" || r == "AXToggle" {
                            value = (ScreenControl.attr(el, kAXValueAttribute) as? NSNumber).map { $0.intValue == 1 ? "on" : "off" }
                        }
                        controls.append((name, label, value, el))
                    }
                    lastLabel = label
                }
                // A control's insides are just its own label again.
                if skipInside.contains(r) { return }
            }
            for c in ScreenControl.children(el) { visit(c, depth + 1) }
        }
        visit(window, 0)

        // Unlabelled fields: the nearest text on the same line to their left is their name.
        for i in controls.indices where controls[i].1.isEmpty {
            guard let f = ScreenControl.frame(controls[i].3) else { continue }
            let named = textFrames.filter { abs($0.1.midY - f.midY) < max(10, f.height / 2) && $0.1.maxX <= f.minX + 6 && f.minX - $0.1.maxX < 220 }
                .max { $0.1.maxX < $1.1.maxX }
            if let named { controls[i].1 = named.0.replacingOccurrences(of: ":$", with: "", options: .regularExpression) }
        }

        var found = Found()
        var n = 0
        for (name, label, value, el) in controls {
            if n >= limit { found.hidden += 1; continue }
            n += 1
            found.items.append((ScreenElement(id: n, role: name, label: Conversation.short(label, 80), value: value), el))
        }
        // Headings and short texts are clickable in some apps (rows, dialogs): number a few.
        for (name, label, el) in texts.prefix(12) where n < limit + 12 {
            n += 1
            found.items.append((ScreenElement(id: n, role: name, label: Conversation.short(label, 100)), el))
        }
        // The rest of the text, as reading matter.
        var text = ""
        for (_, label, _) in texts.dropFirst(12) {
            if text.count + label.count > textLimit { found.hidden += 1; continue }
            text += (text.isEmpty ? "" : " · ") + label
        }
        found.text = text
        found.visited = visited
        let top = roles.sorted { $0.value > $1.value }.prefix(10).map { "\($0.key.replacingOccurrences(of: "AX", with: "")) \($0.value)" }
        found.stats = "visited \(visited) nodes in \(Int(Date().timeIntervalSince(started) * 1000)) ms\(Date() >= deadline ? " (budget hit)" : ""), \(controls.count) controls, \(texts.count) texts; roles: " + top.joined(separator: ", ")
        found.stats += "\nsample: " + sample.joined(separator: " | ")
        return found
    }
}

/// "12,34 100x20", safe for the infinite rect used when a window has no frame.
private func rect(_ r: CGRect) -> String {
    // CGRect.infinite is built from ±greatestFiniteMagnitude, which Int() can't hold either.
    guard [r.origin.x, r.origin.y, r.width, r.height].allSatisfy({ $0.isFinite && abs($0) < 1e7 }) else { return "infinite" }
    return "\(Int(r.origin.x)),\(Int(r.origin.y)) \(Int(r.width))x\(Int(r.height))"
}

/// AXUIElement is a thread-safe CF reference; this lets it cross into the background walk.
private struct AXBox: @unchecked Sendable {
    let el: AXUIElement
    init(_ el: AXUIElement) { self.el = el }
}
