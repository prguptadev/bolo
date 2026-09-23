import BoloCore
import Foundation

/// Reads and drives the web page in front, whatever the site: lists its links, buttons, tabs and
/// fields with numbers (like browser-use does), clicks them and fills them in. Works through the
/// browser's own AppleScript "run JavaScript in this tab", so it needs one switch per browser:
/// Chrome/Brave/Edge/Arc: View › Developer › Allow JavaScript from Apple Events.
/// Safari: Settings › Advanced › Show features for web developers, then Develop › Allow JavaScript from Apple Events.
/// Without it, Bolo falls back to the Accessibility tree, which is slower and sees less.
enum BrowserControl {
    enum Browser: Equatable {
        case chromium(String)
        case safari

        var appName: String {
            switch self {
            case .chromium(let name): name
            case .safari: "Safari"
            }
        }
    }

    static func browser(for bundleID: String?) -> Browser? {
        switch bundleID {
        case "com.google.Chrome": .chromium("Google Chrome")
        case "com.google.Chrome.beta": .chromium("Google Chrome Beta")
        case "com.brave.Browser": .chromium("Brave Browser")
        case "com.microsoft.edgemac": .chromium("Microsoft Edge")
        case "com.vivaldi.Vivaldi": .chromium("Vivaldi")
        case "company.thebrowser.Browser": .chromium("Arc")
        case "com.apple.Safari": .safari
        default: nil
        }
    }

    enum PageError: LocalizedError {
        case scriptingOff(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .scriptingOff(let app):
                app == "Safari"
                    ? "Safari won't let Bolo read pages. Turn on Develop › Allow JavaScript from Apple Events."
                    : "\(app) won't let Bolo read pages. Turn on View › Developer › Allow JavaScript from Apple Events."
            case .failed(let s): s
            }
        }
    }

    /// Browsers where page scripting is switched off, so we don't keep asking (and waiting) each step.
    private static let off = LockedSet()

    static func isScriptingOff(_ b: Browser) -> Bool { off.contains(b.appName) }

    static func run(_ js: String, in b: Browser) async throws -> String {
        let script = switch b {
        case .chromium(let app): "tell application \(MacControl.quoted(app)) to execute front window's active tab javascript \(MacControl.quoted(js))"
        case .safari: "tell application \"Safari\" to do JavaScript \(MacControl.quoted(js)) in current tab of front window"
        }
        do {
            let out = try await MacControl.appleScript(script)
            off.remove(b.appName)
            return out
        } catch {
            let text = error.localizedDescription
            if text.contains("JavaScript") && (text.contains("turned off") || text.contains("Allow JavaScript") || text.contains("enable")) {
                off.insert(b.appName)
                throw PageError.scriptingOff(b.appName)
            }
            throw PageError.failed(text)
        }
    }

    // MARK: Reading the page

    struct Page: Decodable {
        struct Item: Decodable {
            let id: Int
            let role: String
            let label: String
            let value: String?
        }
        let url: String
        let title: String
        let focused: String?
        let elements: [Item]
        let more: Int
    }

    /// Numbers every visible link, button, tab, field and menu item on the page (and remembers the
    /// numbers in the page itself, so the next click finds the same element).
    static func snapshot(_ b: Browser, limit: Int = 80) async throws -> Page {
        let js = """
            (() => {
              const LIMIT = \(limit);
              const clean = s => (s || '').replace(/\\s+/g, ' ').trim();
              const vis = e => {
                const r = e.getBoundingClientRect();
                if (r.width < 2 || r.height < 2) return false;
                if (r.bottom < 0 || r.top > innerHeight || r.right < 0 || r.left > innerWidth) return false;
                const s = getComputedStyle(e);
                return s.visibility !== 'hidden' && s.display !== 'none' && parseFloat(s.opacity || '1') > 0.05;
              };
              const labelOf = e => {
                let l = e.getAttribute('aria-label') || e.getAttribute('title') || '';
                if (!l && e.labels && e.labels.length) l = e.labels[0].innerText;
                if (!l) l = e.innerText || e.getAttribute('alt') || e.getAttribute('placeholder') || e.getAttribute('name') || '';
                if (!l && (e.type === 'submit' || e.type === 'button')) l = e.value;
                return clean(l).slice(0, 90);
              };
              const sel = 'a[href],button,input:not([type=hidden]),textarea,select,summary,[role=button],[role=link],[role=tab],' +
                '[role=menuitem],[role=checkbox],[role=radio],[role=option],[role=textbox],[role=combobox],[role=switch],' +
                '[role=searchbox],[contenteditable=true],[contenteditable=""],[onclick],[tabindex="0"]';
              document.querySelectorAll('[data-bolo-id]').forEach(e => e.removeAttribute('data-bolo-id'));
              const out = []; let more = 0; const seen = new Set();
              for (const e of document.querySelectorAll(sel)) {
                if (!vis(e)) continue;
                const tag = e.tagName.toLowerCase();
                const field = tag === 'input' || tag === 'textarea' || tag === 'select' || e.isContentEditable;
                const label = labelOf(e);
                if (!label && !field) continue;
                let role = e.getAttribute('role') || (tag === 'a' ? 'link' : tag === 'input' ? (e.type || 'text') + ' field' : tag);
                if (e.isContentEditable && !e.getAttribute('role')) role = 'text box';
                if (e.type === 'password') role = 'password field';
                const key = role + '|' + label;
                if (!field && seen.has(key)) continue;
                seen.add(key);
                if (out.length >= LIMIT) { more++; continue; }
                const id = out.length + 1;
                e.setAttribute('data-bolo-id', String(id));
                const item = { id, role, label };
                if (field && e.type !== 'password') {
                  const v = e.isContentEditable ? e.innerText : (tag === 'select' ? (e.selectedOptions[0] || {}).text : e.value);
                  item.value = clean(v).slice(0, 80);
                }
                if (e.getAttribute('aria-selected') === 'true' || e.getAttribute('aria-checked') === 'true') item.value = 'selected';
                out.push(item);
              }
              const a = document.activeElement;
              const focused = a && a !== document.body ? (a.tagName.toLowerCase() + ' ' + labelOf(a)) : null;
              return JSON.stringify({ url: location.href, title: document.title, focused, elements: out, more });
            })()
            """
        let json = try await run(js, in: b)
        guard let page = try? JSONDecoder().decode(Page.self, from: Data(json.utf8)) else {
            throw PageError.failed("Couldn't read the page.")
        }
        return page
    }

    /// Open tabs of the front window, the active one marked.
    static func tabs(_ b: Browser) async -> [String] {
        let script = switch b {
        case .chromium(let app): """
            tell application \(MacControl.quoted(app))
                set out to (active tab index of front window as text)
                repeat with t in tabs of front window
                    set out to out & linefeed & (title of t)
                end repeat
                return out
            end tell
            """
        case .safari: """
            tell application "Safari"
                set out to (index of current tab of front window as text)
                repeat with t in tabs of front window
                    set out to out & linefeed & (name of t)
                end repeat
                return out
            end tell
            """
        }
        guard let out = try? await MacControl.appleScript(script) else { return [] }
        var lines = out.components(separatedBy: "\n")
        guard let active = Int(lines.removeFirst().trimmingCharacters(in: .whitespaces)) else { return [] }
        let all = lines.enumerated().map { "\($0.offset + 1). \(Conversation.short($0.element, 40))\($0.offset + 1 == active ? " (this tab)" : "")" }
        guard all.count > 15 else { return all }
        // 50 open tabs would drown the prompt: the ones around the current tab, and the count.
        let lo = max(0, min(active - 8, all.count - 15)), hi = min(all.count, lo + 15)
        return Array(all[lo..<hi]) + ["(\(all.count) tabs in all)"]
    }

    // MARK: Acting on the page

    /// Clicks the element numbered `id` in the last snapshot, with the full pointer sequence that
    /// sites listening for mousedown (Gmail, React apps) need.
    static func click(id: Int, in b: Browser) async throws -> String {
        let js = """
            (() => {
              const e = document.querySelector('[data-bolo-id="\(id)"]');
              if (!e) return 'missing';
              e.scrollIntoView({ block: 'center', inline: 'center' });
              const r = e.getBoundingClientRect();
              const o = { bubbles: true, cancelable: true, view: window, clientX: r.left + r.width / 2, clientY: r.top + r.height / 2, button: 0 };
              e.dispatchEvent(new PointerEvent('pointerdown', o)); e.dispatchEvent(new MouseEvent('mousedown', o));
              if (e.focus) e.focus();
              e.dispatchEvent(new PointerEvent('pointerup', o)); e.dispatchEvent(new MouseEvent('mouseup', o));
              e.click();
              return 'ok';
            })()
            """
        let out = try await run(js, in: b)
        guard out == "ok" else { throw PageError.failed("That element is gone from the page (it changed). Look again.") }
        return "Clicked"
    }

    /// Clicks by visible text when the model named a label instead of a number.
    static func click(label: String, in b: Browser) async throws -> String {
        let js = """
            (() => {
              const want = \(jsString(label.lowercased()));
              const clean = s => (s || '').replace(/\\s+/g, ' ').trim().toLowerCase();
              const all = [...document.querySelectorAll('a,button,[role=button],[role=link],[role=tab],[role=menuitem],[role=option],summary,input[type=submit],input[type=button],[onclick]')]
                .filter(e => { const r = e.getBoundingClientRect(); return r.width > 1 && r.height > 1; });
              const text = e => clean(e.getAttribute('aria-label') || e.innerText || e.value || e.title);
              let hits = all.filter(e => text(e) === want);
              if (!hits.length) hits = all.filter(e => text(e).startsWith(want));
              if (!hits.length) hits = all.filter(e => text(e).includes(want));
              const labels = [...new Set(hits.map(text))];
              if (!hits.length) return 'none';
              if (labels.length > 1) return 'many:' + labels.slice(0, 3).join(' | ');
              const e = hits[0];
              e.scrollIntoView({ block: 'center' });
              const r = e.getBoundingClientRect();
              const o = { bubbles: true, cancelable: true, view: window, clientX: r.left + r.width / 2, clientY: r.top + r.height / 2, button: 0 };
              e.dispatchEvent(new PointerEvent('pointerdown', o)); e.dispatchEvent(new MouseEvent('mousedown', o));
              e.dispatchEvent(new PointerEvent('pointerup', o)); e.dispatchEvent(new MouseEvent('mouseup', o));
              e.click();
              return 'ok:' + labels[0];
            })()
            """
        let out = try await run(js, in: b)
        if out.hasPrefix("ok:") { return "Clicked \"\(out.dropFirst(3))\"" }
        if out.hasPrefix("many:") { throw PageError.failed("Several things match \"\(label)\": \(out.dropFirst(5)). Use the id.") }
        throw PageError.failed("Nothing called \"\(label)\" on the page.")
    }

    /// Sets a field's text the way a person typing would (React and other frameworks see the change).
    static func fill(id: Int, text: String, in b: Browser) async throws -> String {
        let js = """
            (() => {
              const e = document.querySelector('[data-bolo-id="\(id)"]');
              if (!e) return 'missing';
              if (e.type === 'password') return 'password';
              const text = \(jsString(text));
              e.scrollIntoView({ block: 'center' });
              e.focus();
              if (e.isContentEditable) {
                document.execCommand('selectAll', false, null);
                document.execCommand('insertText', false, text);
              } else if (e.tagName === 'SELECT') {
                const opt = [...e.options].find(o => o.text.trim().toLowerCase() === text.toLowerCase() || o.value === text)
                  || [...e.options].find(o => o.text.toLowerCase().includes(text.toLowerCase()));
                if (!opt) return 'nooption';
                e.value = opt.value;
              } else {
                const proto = e.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
                Object.getOwnPropertyDescriptor(proto, 'value').set.call(e, text);
              }
              e.dispatchEvent(new Event('input', { bubbles: true }));
              e.dispatchEvent(new Event('change', { bubbles: true }));
              return 'ok';
            })()
            """
        switch try await run(js, in: b) {
        case "ok": return "Filled in. If that was a search box, press return."
        case "password": throw PageError.failed("That's a password field. Bolo never types passwords.")
        case "nooption": throw PageError.failed("That list has no option \"\(text)\".")
        default: throw PageError.failed("That field is gone from the page (it changed). Look again.")
        }
    }

    static func scroll(_ direction: String, in b: Browser) async throws -> String {
        let js = switch direction {
        case "up": "window.scrollBy(0, -innerHeight * 0.8); 'ok'"
        case "top": "window.scrollTo(0, 0); 'ok'"
        case "bottom": "window.scrollTo(0, document.body.scrollHeight); 'ok'"
        default: "window.scrollBy(0, innerHeight * 0.8); 'ok'"
        }
        _ = try await run(js, in: b)
        return "Scrolled \(direction)"
    }

    /// A JavaScript string literal (JSON-escaped).
    static func jsString(_ s: String) -> String {
        let data = (try? JSONEncoder().encode(s)) ?? Data("\"\"".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

extension BrowserControl {
    /// The page the front window is on. AppleScript only: no JavaScript switch needed.
    static func currentURL(_ b: Browser) async -> String? {
        let script = switch b {
        case .chromium(let app): "tell application \(MacControl.quoted(app)) to get URL of active tab of front window"
        case .safari: "tell application \"Safari\" to get URL of current tab of front window"
        }
        return (try? await MacControl.appleScript(script))?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    static func isLoading(_ b: Browser) async -> Bool {
        switch b {
        case .chromium(let app):
            return (try? await MacControl.appleScript("tell application \(MacControl.quoted(app)) to get loading of active tab of front window")) == "true"
        case .safari:
            guard !isScriptingOff(b), let state = try? await run("document.readyState", in: b) else { return false }
            return state != "complete"
        }
    }

    /// Goes to `url` in the tab you're looking at (or a new one). That's what a person would do;
    /// opening through the system always makes a new tab.
    static func navigate(to url: String, in b: Browser, newTab: Bool) async throws {
        let u = MacControl.quoted(url)
        let script = switch (b, newTab) {
        case (.chromium(let app), false): "tell application \(MacControl.quoted(app)) to set URL of active tab of front window to \(u)"
        case (.chromium(let app), true): "tell application \(MacControl.quoted(app)) to tell front window to make new tab with properties {URL:\(u)}"
        case (.safari, false): "tell application \"Safari\" to set URL of current tab of front window to \(u)"
        case (.safari, true): "tell application \"Safari\" to tell front window to make new tab with properties {URL:\(u)}"
        }
        try await MacControl.appleScript(script)
    }

    static func selectTab(_ n: Int, in b: Browser) async throws {
        let script = switch b {
        case .chromium(let app): "tell application \(MacControl.quoted(app)) to set active tab index of front window to \(n)"
        case .safari: "tell application \"Safari\" to tell front window to set current tab to tab \(n)"
        }
        try await MacControl.appleScript(script)
    }

    /// The page's visible text, for reading and summarising.
    static func pageText(_ b: Browser, limit: Int) async throws -> String? {
        let js = """
            (() => { const m = document.querySelector('main, article, [role=main]') || document.body;
              return (m.innerText || '').replace(/\\s+/g, ' ').trim().slice(0, \(limit)); })()
            """
        return try await run(js, in: b).nilIfEmpty
    }
}

/// A tiny thread-safe set (read from background snapshot tasks).
final class LockedSet: @unchecked Sendable {
    private let lock = NSLock()
    private var items: Set<String> = []
    func contains(_ s: String) -> Bool { lock.withLock { items.contains(s) } }
    func insert(_ s: String) { lock.withLock { _ = items.insert(s) } }
    func remove(_ s: String) { lock.withLock { _ = items.remove(s) } }
}
