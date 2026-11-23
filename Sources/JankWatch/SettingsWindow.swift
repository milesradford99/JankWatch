#if os(macOS)
import AppKit
import JankWatchCore
import JankWatchMac
import SwiftUI

/// A plain window (instead of a SwiftUI Settings scene, which is unreliable for menu-bar-only apps).
final class SettingsWindowController {
    weak var model: AppModel?
    private var window: NSWindow?

    func show() {
        guard let model else { return }
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
                             styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "JankWatch 设置"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView(model: model))
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var c: JankConfig { model.status.config }

    var body: some View {
        Form {
            Section("权限") {
                LabeledContent("输入监控") {
                    HStack {
                        Text(model.status.permissions.inputMonitoring ? "已授权" : "未授权")
                            .foregroundStyle(model.status.permissions.inputMonitoring ? .green : .orange)
                        if !model.status.permissions.inputMonitoring { Button("去授权", action: model.requestInputMonitoring) }
                    }
                }
                LabeledContent("辅助功能") {
                    HStack {
                        Text(model.status.permissions.accessibility ? "已授权" : "未授权")
                            .foregroundStyle(model.status.permissions.accessibility ? .green : .orange)
                        if !model.status.permissions.accessibility { Button("去授权", action: model.requestAccessibility) }
                    }
                }
                Text("输入监控只用来读取按键/点击/滚动事件的时间戳，从不读取或记录按键内容。授权后需重启 JankWatch。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("检测") {
                Picker("灵敏度", selection: Binding(get: { c.sensitivity }, set: { v in model.updateConfig { $0.sensitivity = v } })) {
                    ForEach(Sensitivity.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Toggle("测量输入延迟", isOn: Binding(get: { c.inputEnabled }, set: { v in model.updateConfig { $0.inputEnabled = v } }))
                Toggle("探测前台 App 是否卡住", isOn: Binding(get: { c.frontProbeEnabled }, set: { v in model.updateConfig { $0.frontProbeEnabled = v } }))
                Stepper("暂停后自动恢复：\(Int(c.pauseAutoResumeMinutes)) 分钟",
                        value: Binding(get: { c.pauseAutoResumeMinutes }, set: { v in model.updateConfig { $0.pauseAutoResumeMinutes = v } }),
                        in: 1...120, step: 1)
            }

            Section("忽略列表") {
                if c.ignoredGroups.isEmpty {
                    Text("没有忽略的 App").foregroundStyle(.secondary)
                }
                ForEach(c.ignoredGroups, id: \.self) { key in
                    HStack {
                        Text(Self.displayName(key))
                        Spacer()
                        Button("移除") { model.engine.unignore(groupKey: key) }
                    }
                }
            }

            Section("其他") {
                Toggle("开机启动", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                Toggle("记录每秒数据（用于调参，保留 \(c.tickRetentionDays) 天）",
                       isOn: Binding(get: { c.recordTicks }, set: { v in model.updateConfig { $0.recordTicks = v } }))
                HStack {
                    Button("打开数据目录", action: model.openDataDirectory)
                    Button("编辑 config.json", action: model.openConfigFile)
                    Button("重新载入配置") { model.engine.reloadConfig() }
                }
                Text("快捷键：⌃⌥⌘L 标记“刚才卡了”，⌃⌥⌘R 对当前卡顿执行一键恢复。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 560)
    }

    static func displayName(_ key: String) -> String {
        if key.hasPrefix("app:") { return AppGrouping.displayName(forBundle: String(key.dropFirst(4))) }
        if let i = key.firstIndex(of: ":") { return String(key[key.index(after: i)...]) }
        return key
    }
}
#endif
