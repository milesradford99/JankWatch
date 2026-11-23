#if os(macOS)
import AppKit
import JankWatchCore
import JankWatchMac
import SwiftUI

struct MenuBarLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Image(systemName: symbol)
    }

    var symbol: String {
        switch (model.status.gate, model.status.phase) {
        case (.off, _): return "gauge.with.dots.needle.0percent"
        case (_, .lagging): return "exclamationmark.triangle.fill"
        case (_, .suspect): return "gauge.with.dots.needle.67percent"
        default: return "gauge.with.dots.needle.33percent"
        }
    }
}

struct MenuContentView: View {
    @ObservedObject var model: AppModel

    var s: EngineStatus { model.status }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            ScoreChart(scores: s.recentScores, threshold: s.config.lagScoreThreshold)
                .frame(height: 44)
            if !s.permissions.inputMonitoring || !s.permissions.accessibility || !model.hotkeysOK {
                permissions
            }
            episodes
            actions
            Divider()
            diagnostics
            footer
        }
        .padding(14)
        .frame(width: 360)
    }

    var header: some View {
        HStack {
            Text("JankWatch").font(.headline)
            Spacer()
            Text(stateText).font(.caption).padding(.horizontal, 8).padding(.vertical, 3)
                .background(stateColor.opacity(0.2), in: Capsule())
        }
    }

    var stateText: String {
        switch s.gate {
        case .off: return "暂停监测（息屏/锁屏）"
        case .idle: return "空闲"
        case .active:
            switch s.phase {
            case .normal: return "监测中 · 流畅"
            case .suspect: return "监测中 · 有点慢"
            case .lagging: return "监测中 · 卡顿"
            }
        }
    }

    var stateColor: Color {
        switch (s.gate, s.phase) {
        case (.active, .lagging): return .red
        case (.active, .suspect): return .orange
        case (.active, _): return .green
        default: return .gray
        }
    }

    var permissions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("需要授权").font(.subheadline.bold())
            if !s.permissions.inputMonitoring {
                PermissionRow(title: "输入监控", detail: "测量按键/滚动的延迟（只读时间戳，不记录按键内容）",
                              action: model.requestInputMonitoring)
            }
            if !s.permissions.accessibility {
                PermissionRow(title: "辅助功能", detail: "判断前台 App 自身是否卡住", action: model.requestAccessibility)
            }
            if !model.hotkeysOK {
                Text("全局快捷键 ⌃⌥⌘L / ⌃⌥⌘R 被其他 App 占用").font(.caption).foregroundStyle(.orange)
            }
            if s.permissions.inputMonitoring && !s.inputTapInstalled {
                Text("已授权输入监控，需重启 JankWatch 生效").font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    var episodes: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("最近卡顿").font(.subheadline.bold())
            if s.recentEpisodes.isEmpty {
                Text("暂无").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(s.recentEpisodes.prefix(5))) { e in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(e.startWall, style: .time).font(.caption.monospacedDigit())
                        if let d = e.durationSec { Text("持续 \(Int(d.rounded())) 秒").font(.caption).foregroundStyle(.secondary) }
                    }
                    Text(e.headline).font(.caption).lineLimit(2)
                }
            }
        }
    }

    var actions: some View {
        let records = s.ledger.prefix(6)
        return Group {
            if !records.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("已处理").font(.subheadline.bold())
                    ForEach(Array(records)) { r in
                        HStack {
                            Text("\(r.kind.label)「\(r.displayName)」").font(.caption)
                            Text(r.appliedAt, style: .time).font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            if r.canRevert {
                                Button("撤销") { model.revert(r) }.controlSize(.small)
                            } else if r.revertedAt != nil {
                                Text("已恢复").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    var diagnostics: some View {
        VStack(alignment: .leading, spacing: 2) {
            let base = s.baselineLatencyMs.map { Format.ms($0) } ?? "学习中 \(s.baselineSamples)/\(s.config.baselineMinSamples)"
            Text("调度基线 p95：\(base) · 本工具 CPU \(Format.percent(s.selfCPUPercent))")
            Text("输入时钟：\(s.inputClock?.rawValue ?? (s.inputClockFailed ? "校准失败" : "待校准")) · rusage：\(s.rusageUnit?.rawValue ?? "-")")
            Text("进程 \(s.processesTotal) 个，无权读取 \(s.processesDenied) 个（用 ps 兜底）")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    var footer: some View {
        HStack {
            Button("标记刚才卡了") { model.engine.mark() }.help("⌃⌥⌘L")
            Menu("更多") {
                Button("设置…") { model.settings.show() }
                Button("测试弹窗") { model.engine.showTestAlert() }
                Button("打开数据目录") { model.openDataDirectory() }
                Divider()
                Button("退出 JankWatch") { NSApp.terminate(nil) }
            }
            .fixedSize()
        }
        .controlSize(.small)
    }
}

struct PermissionRow: View {
    let title: String
    let detail: String
    let action: () -> Void
    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption.bold())
                Text(detail).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("去授权", action: action).controlSize(.small)
        }
    }
}

/// Bars of the per-second lag score over the last two minutes.
struct ScoreChart: View {
    let scores: [Double]
    let threshold: Double

    var body: some View {
        Canvas { ctx, size in
            let n = 120
            let w = size.width / CGFloat(n)
            let maxV = max(2.0, scores.max() ?? 0)
            let pad = n - scores.count
            for (i, v) in scores.enumerated() where v > 0 {
                let h = CGFloat(v / maxV) * size.height
                let rect = CGRect(x: CGFloat(i + pad) * w, y: size.height - h, width: max(1, w - 1), height: h)
                let color: Color = v >= threshold ? .red : .orange
                ctx.fill(Path(rect), with: .color(color.opacity(0.8)))
            }
            let y = size.height - CGFloat(threshold / maxV) * size.height
            var line = Path()
            line.move(to: CGPoint(x: 0, y: y))
            line.addLine(to: CGPoint(x: size.width, y: y))
            ctx.stroke(line, with: .color(.secondary.opacity(0.5)), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
        }
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .topLeading) {
            Text("近 2 分钟卡顿分").font(.caption2).foregroundStyle(.secondary).padding(4)
        }
    }
}
#endif
