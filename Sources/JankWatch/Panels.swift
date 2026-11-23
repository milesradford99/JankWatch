#if os(macOS)
import AppKit
import JankWatchCore
import JankWatchMac
import SwiftUI

/// Floating panel that never activates JankWatch, so the app the user is typing in keeps keyboard focus.
final class FloatingPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 380, height: 160),
                   styleMask: [.nonactivatingPanel, .borderless],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isReleasedWhenClosed = false
    }

    // Allow clicking buttons; with .nonactivatingPanel this still does not activate the app.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Buttons react to the first click even though the panel is not key.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class AlertState: ObservableObject {
    @Published var alert: AlertModel?
}

final class PanelController {
    weak var model: AppModel?
    private var alertPanel: FloatingPanel?
    private var alertHost: FirstMouseHostingView<AnyView>?
    private let alertState = AlertState()
    private var dismissWork: DispatchWorkItem?
    private var toastPanel: FloatingPanel?
    private var toastWork: DispatchWorkItem?

    private static var targetScreen: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    private func place(_ panel: NSPanel, size: NSSize, offsetY: CGFloat = 0) {
        guard let screen = Self.targetScreen else { return }
        let vf = screen.visibleFrame
        panel.setFrame(NSRect(x: vf.maxX - size.width - 12, y: vf.maxY - size.height - 12 - offsetY, width: size.width, height: size.height),
                       display: true)
    }

    // MARK: Alert

    func showAlert(_ a: AlertModel) {
        alertState.alert = a
        if alertPanel == nil {
            let panel = FloatingPanel()
            let view = AlertView(state: alertState, model: model, close: { [weak self] in self?.closeAlert(userInitiated: true) })
            let host = FirstMouseHostingView(rootView: AnyView(view))
            panel.contentView = host
            alertPanel = panel
            alertHost = host
        }
        resizeAlert(reposition: true)
        alertPanel?.orderFrontRegardless()  // never makeKey: do not steal focus
        scheduleDismiss(after: 60)
    }

    func updateAlert(_ a: AlertModel) {
        guard alertState.alert?.id == a.id, alertPanel?.isVisible == true else { return }
        alertState.alert = a
        DispatchQueue.main.async { self.resizeAlert(reposition: false) }
        if a.ended && a.lastMessage == nil { scheduleDismiss(after: 20) }
        if a.lastMessage != nil { scheduleDismiss(after: 12) }
    }

    private func resizeAlert(reposition: Bool) {
        guard let panel = alertPanel, let host = alertHost else { return }
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        if reposition || !panel.isVisible {
            place(panel, size: size)
        } else {
            // Keep the top edge fixed while content grows/shrinks.
            var f = panel.frame
            f.origin.y += f.height - size.height
            f.size = size
            panel.setFrame(f, display: true)
        }
    }

    private func scheduleDismiss(after seconds: Double) {
        dismissWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.closeAlert(userInitiated: false) }
        dismissWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }

    func closeAlert(userInitiated: Bool) {
        dismissWork?.cancel()
        if userInitiated, let id = alertState.alert?.id { model?.dismissed(id) }
        alertPanel?.orderOut(nil)
    }

    // MARK: Toast

    func showToast(_ message: String) {
        // If the alert is open, the message is shown inside it instead.
        if alertPanel?.isVisible == true, alertState.alert?.lastMessage == message { return }
        let panel = toastPanel ?? FloatingPanel()
        toastPanel = panel
        let host = FirstMouseHostingView(rootView: ToastView(message: message))
        panel.contentView = host
        host.layoutSubtreeIfNeeded()
        let offset = (alertPanel?.isVisible == true) ? (alertPanel?.frame.height ?? 0) + 8 : 0
        place(panel, size: host.fittingSize, offsetY: offset)
        panel.orderFrontRegardless()
        toastWork?.cancel()
        let w = DispatchWorkItem { [weak panel] in panel?.orderOut(nil) }
        toastWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: w)
    }
}

struct ToastView: View {
    let message: String
    var body: some View {
        Text(message)
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: 360)
            .fixedSize(horizontal: false, vertical: true)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .padding(4)
    }
}

struct AlertView: View {
    @ObservedObject var state: AlertState
    weak var model: AppModel?
    let close: () -> Void

    var body: some View {
        if let a = state.alert {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: a.ended ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(a.ended ? .green : .orange)
                    Text(a.ended ? "卡顿已缓解" : "检测到卡顿 · \(a.diagnosis.cause.label)")
                        .font(.headline)
                    Spacer()
                    Button(action: close) { Image(systemName: "xmark").font(.caption.bold()) }
                        .buttonStyle(.borderless)
                        .help("关闭")
                }
                Text(a.diagnosis.headline)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                if !a.diagnosis.evidence.isEmpty {
                    Text(a.diagnosis.evidence.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(a.diagnosis.culprits.prefix(3))) { c in
                    CulpritRow(culprit: c, alertID: a.id, model: model)
                }
                if let m = a.lastMessage {
                    Text(m).font(.caption).foregroundStyle(.blue).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("不是卡顿") {
                        model?.notLag(a.id)
                        close()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    Spacer()
                    if a.diagnosis.primaryCulprit?.hotkeyAction != nil {
                        Text("⌃⌥⌘R 一键\(a.diagnosis.primaryCulprit!.hotkeyAction!.label)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(14)
            .frame(width: 380, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(4)
        } else {
            EmptyView()
        }
    }
}

struct CulpritRow: View {
    let culprit: Culprit
    let alertID: String
    weak var model: AppModel?
    @State private var confirmForce = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(culprit.displayName).font(.subheadline.bold())
                if culprit.isFrontmost { Text("前台").font(.caption2).padding(.horizontal, 4).background(.quaternary, in: Capsule()) }
                Spacer()
                Text(culprit.metricsSummary).font(.caption).foregroundStyle(.secondary)
            }
            if let d = culprit.description {
                Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
            if let adv = culprit.advice {
                Text("建议：" + adv).font(.caption).foregroundStyle(.secondary).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                ForEach(culprit.allowedActions, id: \.self) { kind in
                    actionButton(kind)
                }
                if let fix = culprit.adminFix {
                    Button("🔒 " + fix.title) { model?.perform(.adminFix, culprit, alertID: alertID) }
                        .controlSize(.small)
                        .help(fix.note ?? "需要管理员密码")
                }
                Spacer()
                Button("忽略") { model?.ignore(culprit, alertID: alertID) }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .help("以后不再把它当作元凶")
            }
            if culprit.allowedActions.isEmpty && culprit.adminFix == nil {
                Text("这是系统关键进程，不建议干预").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    func actionButton(_ kind: ActionKind) -> some View {
        let lock = culprit.needsAdmin && kind != .quit ? "🔒 " : ""
        if kind == .forceQuit {
            Button(confirmForce ? "确认强制退出？" : lock + kind.label) {
                if confirmForce { model?.perform(kind, culprit, alertID: alertID) } else { confirmForce = true }
            }
            .controlSize(.small)
            .tint(.red)
        } else if kind == culprit.recommended {
            Button(lock + kind.label) { model?.perform(kind, culprit, alertID: alertID) }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .help(help(kind))
        } else {
            Button(lock + kind.label) { model?.perform(kind, culprit, alertID: alertID) }
                .controlSize(.small)
                .help(help(kind))
        }
    }

    func help(_ kind: ActionKind) -> String {
        switch kind {
        case .background: return "降到后台优先级：让出 CPU 和磁盘给前台（可撤销）"
        case .pause: return "暂时冻结，切换到它或到时间后自动恢复（可撤销）"
        case .quit: return "正常退出，App 会提示保存"
        case .forceQuit: return "立即结束，未保存的内容会丢失"
        case .adminFix: return ""
        }
    }
}
#endif
