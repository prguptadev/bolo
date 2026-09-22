import AppKit
import ApplicationServices
import BoloCore

/// Drives the app in front through the Accessibility API: find things by their label, press them,
/// walk menus, type into fields, scroll and press keys. Never guesses between two equal matches.
enum ScreenControl {
    // MARK: - Accessibility helpers

    static func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success ? value : nil
    }

    static func string(_ el: AXUIElement, _ name: String) -> String? {
        (attr(el, name) as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }

    static func element(_ el: AXUIElement, _ name: String) -> AXUIElement? {
        guard let v = attr(el, name), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func children(_ el: AXUIElement) -> [AXUIElement] {
        (attr(el, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    static func role(_ el: AXUIElement) -> String { string(el, kAXRoleAttribute) ?? "" }

    static func isEnabled(_ el: AXUIElement) -> Bool { (attr(el, kAXEnabledAttribute) as? Bool) ?? true }

    static func frame(_ el: AXUIElement) -> CGRect? {
        guard let p = attr(el, kAXPositionAttribute), let s = attr(el, kAXSizeAttribute),
            CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID()
        else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    private static let labelledByValue: Set<String> = [
        "AXStaticText", "AXCell", "AXButton", "AXLink", "AXMenuItem", "AXRadioButton", "AXCheckBox", "AXRow", "AXHeading",
    ]
    private static let labelFromChildren: Set<String> = ["AXRow", "AXCell", "AXButton", "AXLink"]

    /// What a person would call this element: its title, description, visible text or placeholder.
    static func label(_ el: AXUIElement, role: String) -> String {
        if let s = string(el, kAXTitleAttribute) ?? string(el, kAXDescriptionAttribute) { return s }
        if labelledByValue.contains(role), let s = string(el, kAXValueAttribute) { return s }
        if let s = string(el, kAXPlaceholderValueAttribute) ?? string(el, kAXHelpAttribute) { return s }
        if labelFromChildren.contains(role) { return firstText(in: el, depth: 3) ?? "" }
        return ""
    }

    private static func firstText(in el: AXUIElement, depth: Int) -> String? {
        guard depth > 0 else { return nil }
        for c in children(el) {
            if role(c) == "AXStaticText", let s = string(c, kAXValueAttribute) ?? string(c, kAXTitleAttribute) { return s }
            if let s = firstText(in: c, depth: depth - 1) { return s }
        }
        return nil
    }

    struct Node {
        let el: AXUIElement
        let role: String
        let label: String
        let frame: CGRect?
    }

    /// Everything labelled in a window, depth first, within a node and time budget (web views are huge).
    static func collect(from root: AXUIElement, limit: Int = 5000, maxDepth: Int = 50, budget: TimeInterval = 1.5) -> [Node] {
        var out: [Node] = []
        let deadline = Date().addingTimeInterval(budget)
        var visited = 0
        func walk(_ el: AXUIElement, _ depth: Int) {
            guard visited < limit, depth <= maxDepth, Date() < deadline else { return }
            visited += 1
            let r = role(el)
            let l = label(el, role: r)
            if !l.isEmpty { out.append(Node(el: el, role: r, label: l, frame: frame(el))) }
            for c in children(el) { walk(c, depth + 1) }
        }
        walk(root, 0)
        return out
    }

    // MARK: - The app in front

    struct FrontApp {
        let app: NSRunningApplication
        let element: AXUIElement
        var name: String { app.localizedName ?? "the app" }

        var window: AXUIElement? {
            ScreenControl.element(element, kAXFocusedWindowAttribute)
                ?? (ScreenControl.attr(element, kAXWindowsAttribute) as? [AXUIElement])?.first
        }
    }

    static func front() throws -> FrontApp {
        guard MacControl.isTrusted else { throw SkillError.failed("Bolo needs Accessibility access to control apps.") }
        guard let app = NSWorkspace.shared.frontmostApplication else { throw SkillError.failed("No app is in front.") }
        let el = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(el, 1.0)
        return FrontApp(app: app, element: el)
    }

    // MARK: - Pressing

    private static let pressable: Set<String> = [
        "AXButton", "AXMenuItem", "AXCheckBox", "AXRadioButton", "AXLink", "AXCell", "AXRow", "AXPopUpButton",
        "AXMenuButton", "AXDisclosureTriangle", "AXTab", "AXImage", "AXStaticText", "AXGroup", "AXTextField",
    ]

    /// AXPress, walking up to a pressable parent; clicks the element's centre as a last resort.
    @discardableResult
    static func press(_ el: AXUIElement) -> Bool {
        var current: AXUIElement? = el
        for _ in 0..<4 {
            guard let c = current else { break }
            if AXUIElementPerformAction(c, kAXPressAction as CFString) == .success { return true }
            current = element(c, kAXParentAttribute)
        }
        guard let f = frame(el) else { return false }
        click(at: CGPoint(x: f.midX, y: f.midY))
        return true
    }

    static func click(at point: CGPoint) {
        let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
        let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    static func click(_ target: String) throws -> String {
        let front = try front()
        guard let window = front.window else { throw SkillError.failed("\(front.name) has no window open.") }
        let nodes = collect(from: window).filter { pressable.contains($0.role) && isEnabled($0.el) }
        switch ScreenMatch.best(target, in: nodes, label: \.label) {
        case .found(let node):
            press(node.el)
            return "Clicked \(node.label)"
        case .ambiguous(let labels):
            throw SkillError.failed("Several things match \"\(target)\": \(labels.prefix(3).joined(separator: ", ")). Say the full name.")
        case .none:
            throw SkillError.failed("Couldn't find \"\(target)\" in \(front.name).")
        }
    }

    // MARK: - Menus

    struct MenuItem {
        let path: [String]
        let el: AXUIElement
        var title: String { path.last ?? "" }
    }

    static func menuItems(_ app: AXUIElement) -> [MenuItem] {
        guard let bar = element(app, kAXMenuBarAttribute) else { return [] }
        var out: [MenuItem] = []
        func walk(_ el: AXUIElement, _ path: [String], _ depth: Int) {
            guard depth < 6 else { return }
            for c in children(el) {
                switch role(c) {
                case "AXMenu":
                    walk(c, path, depth + 1)
                case "AXMenuItem":
                    guard let title = string(c, kAXTitleAttribute) else { continue }
                    out.append(MenuItem(path: path + [title], el: c))
                    walk(c, path + [title], depth + 1)
                default:
                    continue
                }
            }
        }
        for top in children(bar) {
            walk(top, [string(top, kAXTitleAttribute) ?? "Apple"], 0)
        }
        return out
    }

    /// "File > Export as PDF" or just "Export as PDF".
    static func menu(_ target: String) throws -> String {
        let front = try front()
        var items = menuItems(front.element)
        guard !items.isEmpty else { throw SkillError.failed("Couldn't read \(front.name)'s menus.") }
        let parts = target.components(separatedBy: CharacterSet(charactersIn: ">›")).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let wanted = parts.last ?? target
        if parts.count > 1 {
            let inMenu = items.filter { ScreenMatch.score(said: parts[0], label: $0.path[0]) >= 0.8 }
            if !inMenu.isEmpty { items = inMenu }
        }
        switch ScreenMatch.best(wanted, in: items, label: \.title) {
        case .found(let item):
            guard isEnabled(item.el) else { throw SkillError.failed("\(item.path.joined(separator: " › ")) is greyed out right now.") }
            if AXUIElementPerformAction(item.el, kAXPressAction as CFString) != .success {
                // Some apps only accept a press once the menu is open.
                if let bar = element(front.element, kAXMenuBarAttribute),
                    let top = children(bar).first(where: { string($0, kAXTitleAttribute) == item.path.first })
                {
                    AXUIElementPerformAction(top, kAXPressAction as CFString)
                    usleep(200_000)
                }
                guard AXUIElementPerformAction(item.el, kAXPressAction as CFString) == .success else {
                    throw SkillError.failed("\(front.name) didn't accept \(item.title).")
                }
            }
            return "Chose " + item.path.joined(separator: " › ")
        case .ambiguous(let titles):
            throw SkillError.failed("Several menu items match \"\(wanted)\": \(titles.prefix(3).joined(separator: ", ")). Say the menu too, like \"File menu \(wanted)\".")
        case .none:
            throw SkillError.failed("\(front.name) has no menu item \"\(wanted)\".")
        }
    }

    // MARK: - Typing into a field

    private static let fieldRoles: Set<String> = ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"]

    static func typeInto(_ target: String, text: String) async throws -> String {
        let front = try front()
        guard let window = front.window else { throw SkillError.failed("\(front.name) has no window open.") }
        let fields = collect(from: window).filter { fieldRoles.contains($0.role) }
        var field: Node?
        switch ScreenMatch.best(target, in: fields, label: \.label, minimum: 0.7) {
        case .found(let f): field = f
        case .ambiguous(let labels):
            throw SkillError.failed("Several fields match \"\(target)\": \(labels.prefix(3).joined(separator: ", ")).")
        case .none:
            // "search" means the one search field, whatever its placeholder says.
            let searches = fields.filter { $0.role == "AXSearchField" }
            if ScreenMatch.normalize(target).contains("search"), searches.count == 1 { field = searches[0] }
        }
        guard let field else { throw SkillError.failed("Couldn't find a \"\(target)\" field in \(front.name).") }
        AXUIElementSetAttributeValue(field.el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        if AXUIElementSetAttributeValue(field.el, kAXValueAttribute as CFString, text as CFString) != .success {
            press(field.el)
            try await Task.sleep(for: .milliseconds(150))
            await MacControl.paste(text)
        }
        return "Typed into \(field.label)"
    }

    // MARK: - Scrolling

    static func scroll(_ direction: String, pages: Int) throws -> String {
        let front = try front()
        guard let window = front.window else { throw SkillError.failed("\(front.name) has no window open.") }
        let areas = collect(from: window, limit: 3000).filter { $0.role == "AXScrollArea" }
        let all = areas.isEmpty ? scrollAreas(in: window) : areas.map(\.el)
        let area = all.max { (frame($0)?.width ?? 0) * (frame($0)?.height ?? 0) < (frame($1)?.width ?? 0) * (frame($1)?.height ?? 0) }
        if let area, direction == "top" || direction == "bottom", let bar = element(area, kAXVerticalScrollBarAttribute) {
            AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, NSNumber(value: direction == "top" ? 0.0 : 1.0))
            return "Scrolled to the \(direction)"
        }
        let action = ["up": "AXScrollUpByPage", "down": "AXScrollDownByPage", "left": "AXScrollLeftByPage", "right": "AXScrollRightByPage"][direction]
        if let area, let action, (0..<max(1, pages)).allSatisfy({ _ in AXUIElementPerformAction(area, action as CFString) == .success }) {
            return "Scrolled \(direction)"
        }
        // Fallback: a scroll-wheel event aimed at the app.
        let lines = Int32(10 * max(1, pages))
        let dy: Int32 = direction == "up" ? lines : direction == "down" ? -lines : 0
        let dx: Int32 = direction == "left" ? lines : direction == "right" ? -lines : 0
        let e = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)
        if let f = frame(window) { e?.location = CGPoint(x: f.midX, y: f.midY) }
        e?.postToPid(front.app.processIdentifier)
        return "Scrolled \(direction)"
    }

    /// Scroll areas are usually unlabelled, so `collect` misses them.
    private static func scrollAreas(in el: AXUIElement, depth: Int = 0) -> [AXUIElement] {
        guard depth < 12 else { return [] }
        return children(el).flatMap { c in (role(c) == "AXScrollArea" ? [c] : []) + scrollAreas(in: c, depth: depth + 1) }
    }

    // MARK: - Keys

    private static let keyCodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
        "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
        "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "return": 36,
        "l": 37, "j": 38, "k": 40, "n": 45, "m": 46, "tab": 48, "space": 49, "delete": 51, "escape": 53,
        "left": 123, "right": 124, "down": 125, "up": 126, "home": 115, "pageup": 116, "end": 119, "pagedown": 121,
    ]

    static func pressKey(_ combo: String) throws -> String {
        var flags: CGEventFlags = []
        var key: CGKeyCode?
        var shown = ""
        for part in combo.lowercased().split(separator: "+").map(String.init) {
            switch part {
            case "cmd": flags.insert(.maskCommand); shown += "⌘"
            case "ctrl": flags.insert(.maskControl); shown += "⌃"
            case "opt": flags.insert(.maskAlternate); shown += "⌥"
            case "shift": flags.insert(.maskShift); shown += "⇧"
            default:
                key = keyCodes[part]
                shown += part.count == 1 ? part.uppercased() : part.capitalized
            }
        }
        // "cmd+=" arrives as a trailing empty part after splitting on "+".
        if key == nil, combo.hasSuffix("+") || combo.hasSuffix("=") { key = keyCodes["="]; shown += "=" }
        guard let key else { throw SkillError.failed("Don't know the key \"\(combo)\".") }
        let src = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
        return "Pressed \(shown)"
    }

    static func goBack() throws -> String {
        if let result = try? click("Back") { return result }
        return try pressKey("cmd+[").replacingOccurrences(of: "Pressed", with: "Went back with")
    }

    /// True when the focused element is a search field (by role, or a text field whose placeholder,
    /// description or title mentions search), not a message box.
    static func isSearchFocused(pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.0)
        guard let el = element(app, kAXFocusedUIElementAttribute) else { return false }
        let r = role(el)
        if r == "AXSearchField" { return true }
        guard fieldRoles.contains(r) else { return false }
        let words = [kAXPlaceholderValueAttribute, kAXDescriptionAttribute, kAXTitleAttribute, kAXHelpAttribute, kAXIdentifierAttribute]
            .compactMap { string(el, $0)?.lowercased() }.joined(separator: " ")
        return words.contains("search") || words.contains("find") || words.contains("jump to")
    }

    /// Values of every text field in an app's front window (to confirm a draft before sending).
    static func windowTextFields(pid: pid_t) -> [String] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.0)
        guard let window = element(app, kAXFocusedWindowAttribute) ?? (attr(app, kAXWindowsAttribute) as? [AXUIElement])?.first else { return [] }
        var out: [String] = []
        var visited = 0
        func walk(_ el: AXUIElement, _ depth: Int) {
            guard visited < 4000, depth < 50 else { return }
            visited += 1
            if fieldRoles.contains(role(el)), let v = attr(el, kAXValueAttribute) as? String, !v.isEmpty { out.append(v) }
            for c in children(el) { walk(c, depth + 1) }
        }
        walk(window, 0)
        return out
    }

    // MARK: - Chats by name (groups, or people without a saved number)

    /// Searches an app's chat list for exactly `name` and opens it. `searchKey` focuses the search
    /// box (WhatsApp ⌘F, Teams ⌘E, Slack ⌘K). Opens only on a single exact match.
    static func openChat(named name: String, pid: pid_t, appName: String, searchKey: String) async throws -> String {
        _ = try pressKey(searchKey)
        try await Task.sleep(for: .milliseconds(400))
        // Only type the name if a search box really has focus: otherwise ⌘A + paste would land in the
        // open chat's message box.
        guard isSearchFocused(pid: pid) else {
            throw SkillError.failed("Couldn't open \(appName)'s chat search, so I didn't type anything.")
        }
        _ = try pressKey("cmd+a")
        await MacControl.paste(name)
        try await Task.sleep(for: .milliseconds(1200))

        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.0)
        guard let window = element(app, kAXFocusedWindowAttribute) ?? (attr(app, kAXWindowsAttribute) as? [AXUIElement])?.first else {
            throw SkillError.failed("\(appName) has no window open.")
        }
        // "family group" may be called just "Family" in the app.
        let variants = [name, name.replacingOccurrences(of: "\\s+(group|chat|channel)$", with: "", options: [.regularExpression, .caseInsensitive])]
        let nodes = collect(from: window).filter { !fieldRoles.contains($0.role) }
        for variant in Set(variants) {
            let exact = nodes.filter { ScreenMatch.score(said: variant, label: $0.label) == 1 }
            // The same chat often appears as a row plus its title text; count distinct positions.
            let rows = Dictionary(grouping: exact) { n in n.frame.map { Int($0.midY / 8) } ?? 0 }
            Log.skills.notice("\(appName) search \"\(variant, privacy: .public)\": \(exact.count) exact labels in \(rows.count) rows")
            if rows.count == 1, let node = exact.first {
                press(node.el)
                try await Task.sleep(for: .milliseconds(800))
                return "Opened \(node.label) in \(appName)"
            }
            if rows.count > 1 {
                throw SkillError.failed("\(appName) has more than one chat called \"\(variant)\". Say the full name.")
            }
        }
        _ = try? pressKey("escape")
        throw SkillError.failed("No chat called \"\(name)\" in \(appName).")
    }
}
