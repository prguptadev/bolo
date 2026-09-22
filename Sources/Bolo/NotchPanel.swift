import AppKit
import SwiftUI

/// A borderless panel hanging from the notch. It never takes focus and ignores the mouse:
/// it only shows what you said and what Bolo is doing.
final class NotchPanel: NSPanel {
    private static let size = NSSize(width: 520, height: 220)

    init(agent: Agent) {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = NSHostingView(rootView: NotchView(agent: agent, notch: Self.notchSize()))
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show() {
        guard let screen = Self.notchScreen() else { return }
        let f = screen.frame
        setFrame(NSRect(x: f.midX - Self.size.width / 2, y: f.maxY - Self.size.height, width: Self.size.width, height: Self.size.height), display: true)
        orderFrontRegardless()
    }

    func hide() { orderOut(nil) }

    private static func notchScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }

    /// Width and height of the camera notch, or a menu-bar-sized stand-in on screens without one.
    static func notchSize() -> CGSize {
        guard let s = notchScreen() else { return CGSize(width: 200, height: 24) }
        let top = s.safeAreaInsets.top
        guard top > 0, let left = s.auxiliaryTopLeftArea, let right = s.auxiliaryTopRightArea else {
            return CGSize(width: 200, height: NSStatusBar.system.thickness)
        }
        return CGSize(width: s.frame.width - left.width - right.width, height: top)
    }
}

private let micOrange = Color(red: 0.95, green: 0.60, blue: 0.18)
private let okGreen = Color(red: 0.25, green: 0.73, blue: 0.31)
private let failRed = Color(red: 0.96, green: 0.42, blue: 0.38)

struct NotchView: View {
    @ObservedObject var agent: Agent
    let notch: CGSize

    var body: some View {
        VStack(spacing: 0) {
            if agent.phase != .idle {
                VStack(alignment: .leading, spacing: 8) {
                    Color.clear.frame(height: notch.height - 4)
                    content
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 14)
                .frame(minWidth: notch.width + 40, maxWidth: 480, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .background(
                    UnevenRoundedRectangle(bottomLeadingRadius: 22, bottomTrailingRadius: 22, style: .continuous)
                        .fill(Color.black))
                .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .top)))
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(duration: 0.25), value: agent.phase)
        .animation(.easeOut(duration: 0.15), value: agent.rows.count)
        .foregroundStyle(.white)
    }

    @ViewBuilder private var content: some View {
        switch agent.phase {
        case .idle:
            EmptyView()
        case .listening:
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Circle().fill(micOrange).frame(width: 8, height: 8)
                Text(agent.transcript.isEmpty ? "Listening…" : agent.transcript)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(agent.transcript.isEmpty ? .gray : .white)
                    .lineLimit(3)
                Spacer(minLength: 8)
                LevelBars(level: agent.level)
            }
        case .working, .done, .failed:
            Text(agent.transcript)
                .font(.system(size: 13))
                .foregroundStyle(.gray)
                .lineLimit(2)
            ForEach(agent.rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    icon(row.status).frame(width: 14)
                    Text(row.text).font(.system(size: row.isAnswer ? 15 : 14)).lineLimit(row.isAnswer ? 10 : 2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let message = agent.message {
                Text(message).font(.system(size: 13)).foregroundStyle(agent.phase == .failed ? failRed : .gray).lineLimit(3)
            }
        }
    }

    @ViewBuilder private func icon(_ status: Agent.Row.Status) -> some View {
        switch status {
        case .pending: Image(systemName: "circle").foregroundStyle(.gray).font(.system(size: 10))
        case .running: ProgressView().controlSize(.mini).tint(micOrange)
        case .ok: Image(systemName: "checkmark").foregroundStyle(okGreen).font(.system(size: 12, weight: .bold))
        case .failed: Image(systemName: "xmark").foregroundStyle(failRed).font(.system(size: 12, weight: .bold))
        }
    }
}

private struct LevelBars: View {
    let level: Float
    private let shape: [CGFloat] = [0.5, 0.8, 1.0, 0.7, 0.9, 0.6]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(shape.indices, id: \.self) { i in
                Capsule().fill(micOrange)
                    .frame(width: 3, height: max(4, 18 * shape[i] * CGFloat(max(0.15, level))))
            }
        }
        .frame(height: 18)
        .animation(.linear(duration: 0.08), value: level)
    }
}
