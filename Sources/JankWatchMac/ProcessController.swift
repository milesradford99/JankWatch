#if os(macOS)
import AppKit
import Darwin
import Foundation
import JankWatchCore

// From <sys/resource.h>; defined here so we do not depend on how the macros are imported.
let kPrioDarwinProcess: Int32 = 4
let kPrioDarwinBG: Int32 = 0x1000

public enum ProcessOpResult: Equatable, Sendable {
    case ok
    case gone           // process exited or pid was recycled
    case denied         // EPERM: needs admin
    case refused        // protected pid (kernel, launchd, ourselves)
    case failed(Int32)  // other errno
}

/// Low-level process operations. All operations verify the pid still belongs to the same process first.
public enum ProcessOps {
    public static func isProtected(_ pid: Int32) -> Bool {
        pid <= 1 || pid == getpid()
    }

    public static func setBackground(_ ref: PIDRef, on: Bool) -> ProcessOpResult {
        if isProtected(ref.pid) { return .refused }
        guard ProcessTable.isSame(ref) else { return .gone }
        let rc = setpriority(kPrioDarwinProcess, id_t(ref.pid), on ? kPrioDarwinBG : 0)
        if rc == 0 { return .ok }
        return errno == EPERM || errno == EACCES ? .denied : (errno == ESRCH ? .gone : .failed(errno))
    }

    /// Whether the process currently has Darwin background priority (nil if unknown).
    public static func isBackground(_ pid: Int32) -> Bool? {
        errno = 0
        let v = getpriority(kPrioDarwinProcess, id_t(pid))
        if v == -1 && errno != 0 { return nil }
        return v != 0
    }

    public static func signal(_ ref: PIDRef, _ sig: Int32) -> ProcessOpResult {
        if isProtected(ref.pid) { return .refused }
        guard ProcessTable.isSame(ref) else { return .gone }
        if kill(ref.pid, sig) == 0 { return .ok }
        return errno == EPERM ? .denied : (errno == ESRCH ? .gone : .failed(errno))
    }

    public static func isAlive(_ ref: PIDRef) -> Bool { ProcessTable.isSame(ref) }
}

/// Runs a command as root through the standard macOS administrator password dialog.
public enum AdminRunner {
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func appleScriptString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Blocks until the user answers the dialog. Returns (success, output or error message).
    public static func run(_ argv: [String], prompt: String) -> (ok: Bool, output: String) {
        let command = argv.map(shellQuote).joined(separator: " ")
        let script = "do shell script \(appleScriptString(command)) with prompt \(appleScriptString(prompt)) with administrator privileges"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return (false, error.localizedDescription) }
        p.waitUntilExit()
        let o = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (p.terminationStatus == 0, p.terminationStatus == 0 ? o : e)
    }

    /// Path of the bundled `jankctl` helper (next to the main executable).
    public static var jankctlPath: String? {
        let candidate = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("jankctl").path
        if let c = candidate, FileManager.default.isExecutableFile(atPath: c) { return c }
        return nil
    }

    /// jankctl arguments for a process operation; the helper re-verifies pid + start time as root.
    public static func jankctlArgs(_ op: String, _ refs: [PIDRef]) -> [String]? {
        guard let path = jankctlPath else { return nil }
        return [path, op] + refs.map { "\($0.pid):\(String(format: "%.6f", $0.startTime))" }
    }
}

/// High-level actions on a culprit, used by the engine. Not thread-safe; call from the engine queue
/// (app quitting hops to the main thread internally).
public final class ProcessController {
    public init() {}

    public struct Outcome: Sendable {
        public var ok: Bool
        public var message: String
        public var viaAdmin: Bool
        public var affected: [PIDRef]
    }

    private func summarize(_ results: [(PIDRef, ProcessOpResult)]) -> (ok: [PIDRef], denied: [PIDRef], gone: Int, failed: Int) {
        var ok: [PIDRef] = [], denied: [PIDRef] = []
        var gone = 0, failed = 0
        for (r, res) in results {
            switch res {
            case .ok: ok.append(r)
            case .denied: denied.append(r)
            case .gone: gone += 1
            case .refused, .failed: failed += 1
            }
        }
        return (ok, denied, gone, failed)
    }

    /// Apply `op` to each pid; pids we may not touch are retried through jankctl as admin (one password prompt).
    private func apply(_ refs: [PIDRef], op: String, label: String, name: String, local: (PIDRef) -> ProcessOpResult) -> Outcome {
        let s = summarize(refs.map { ($0, local($0)) })
        var affected = s.ok
        var viaAdmin = false
        var message = ""
        if !s.denied.isEmpty {
            if let args = AdminRunner.jankctlArgs(op, s.denied) {
                let r = AdminRunner.run(args, prompt: "JankWatch 需要管理员权限来\(label)「\(name)」")
                if r.ok {
                    affected += s.denied
                    viaAdmin = true
                } else {
                    message = "管理员操作未完成：\(r.output.trimmingCharacters(in: .whitespacesAndNewlines))"
                }
            } else {
                message = "部分进程属于系统，需要管理员权限（未找到 jankctl）"
            }
        }
        if affected.isEmpty && message.isEmpty { message = s.gone > 0 ? "进程已经退出" : "操作失败" }
        if message.isEmpty { message = "已\(label)「\(name)」（\(affected.count) 个进程）" }
        return Outcome(ok: !affected.isEmpty, message: message, viaAdmin: viaAdmin, affected: affected)
    }

    public func background(_ refs: [PIDRef], name: String, on: Bool) -> Outcome {
        apply(refs, op: on ? "bg-on" : "bg-off", label: on ? "降级" : "恢复优先级", name: name) { ProcessOps.setBackground($0, on: on) }
    }

    public func pause(_ refs: [PIDRef], name: String) -> Outcome {
        apply(refs, op: "stop", label: "暂停", name: name) { ProcessOps.signal($0, SIGSTOP) }
    }

    public func resume(_ refs: [PIDRef], name: String) -> Outcome {
        apply(refs, op: "cont", label: "恢复", name: name) { ProcessOps.signal($0, SIGCONT) }
    }

    /// Graceful quit: NSRunningApplication.terminate for apps, SIGTERM otherwise; escalates after `grace` seconds
    /// only when `escalate` is true.
    public func quit(mainPID: Int32, refs: [PIDRef], name: String, force: Bool, grace: Double, escalate: Bool,
                     completion: @escaping (Outcome) -> Void) {
        let main = refs.first { $0.pid == mainPID } ?? refs.first
        let isApp: Bool = DispatchQueue.main.sync { NSRunningApplication(processIdentifier: mainPID)?.bundleURL != nil }
        if isApp, let main {
            // Make sure we resume first if the app is paused, otherwise it cannot handle the quit request.
            _ = refs.map { ProcessOps.signal($0, SIGCONT) }
            DispatchQueue.main.async {
                guard ProcessTable.isSame(main), let app = NSRunningApplication(processIdentifier: main.pid) else {
                    completion(Outcome(ok: false, message: "进程已经退出", viaAdmin: false, affected: []))
                    return
                }
                let sent = force ? app.forceTerminate() : app.terminate()
                if force || !escalate {
                    completion(Outcome(ok: sent, message: sent ? "已\(force ? "强制退出" : "请求退出")「\(name)」" : "退出请求被拒绝",
                                       viaAdmin: false, affected: [main]))
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + grace) {
                    if !app.isTerminated && ProcessTable.isSame(main) { _ = app.forceTerminate() }
                    completion(Outcome(ok: true, message: "已退出「\(name)」", viaAdmin: false, affected: [main]))
                }
            }
            return
        }
        // Plain processes.
        let sig = force ? SIGKILL : SIGTERM
        let out = apply(refs, op: force ? "kill" : "term", label: force ? "强制结束" : "结束", name: name) {
            _ = ProcessOps.signal($0, SIGCONT)
            return ProcessOps.signal($0, sig)
        }
        if !force && escalate && out.ok {
            DispatchQueue.global().asyncAfter(deadline: .now() + grace) {
                for r in out.affected where ProcessTable.isSame(r) { _ = ProcessOps.signal(r, SIGKILL) }
            }
        }
        completion(out)
    }

    public func runAdminFix(_ argv: [String], title: String) -> Outcome {
        let r = AdminRunner.run(argv, prompt: "JankWatch 需要管理员权限来执行：\(title)")
        return Outcome(ok: r.ok, message: r.ok ? "已执行：\(title)" : "未完成：\(r.output.trimmingCharacters(in: .whitespacesAndNewlines))",
                       viaAdmin: true, affected: [])
    }
}
#endif
