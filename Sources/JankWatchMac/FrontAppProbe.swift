#if os(macOS)
import AppKit
import ApplicationServices
import Darwin
import Foundation
import JankWatchCore

/// Info about the frontmost app, kept up to date from NSWorkspace notifications (main thread) and readable anywhere.
public final class FrontmostTracker {
    public struct Info: Equatable, Sendable {
        public var pid: Int32
        public var bundleID: String?
        public var name: String?
        public var bundlePath: String?
    }

    private let lock = NSLock()
    private var info: Info?
    private var observer: NSObjectProtocol?
    public var onActivate: ((Info) -> Void)?

    public init() {}

    /// Call on the main thread.
    public func start() {
        update(NSWorkspace.shared.frontmostApplication)
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.update(app)
        }
    }

    private func update(_ app: NSRunningApplication?) {
        guard let app else { return }
        let i = Info(pid: app.processIdentifier, bundleID: app.bundleIdentifier, name: app.localizedName, bundlePath: app.bundleURL?.path)
        lock.lock()
        info = i
        lock.unlock()
        onActivate?(i)
    }

    public var current: Info? {
        lock.lock(); defer { lock.unlock() }
        return info
    }
}

/// Asks the frontmost app for its focused window via the Accessibility API with a short timeout. If the app's main
/// thread is blocked, the call times out — that means the app itself is hung, not the system.
/// Requires "Accessibility" permission.
public final class FrontAppProbe {
    private let queue = DispatchQueue(label: "JankWatch.frontProbe", qos: .userInitiated)
    private let lock = NSLock()
    private var results: [FrontAppSample] = []
    private var inFlight = false
    public var timeoutMs: Double

    public init(timeoutMs: Double) {
        self.timeoutMs = timeoutMs
    }

    public static func hasPermission(prompt: Bool = false) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    /// Fire one probe asynchronously; skipped if the previous one has not returned yet.
    public func probe(pid: Int32) {
        lock.lock()
        if inFlight {
            lock.unlock()
            return
        }
        inFlight = true
        lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            let r = Self.measure(pid: pid, timeoutMs: self.timeoutMs)
            self.lock.lock()
            self.inFlight = false
            if let r { self.results.append(r) }
            if self.results.count > 100 { self.results.removeFirst(50) }
            self.lock.unlock()
        }
    }

    public func drain() -> [FrontAppSample] {
        lock.lock()
        defer { lock.unlock() }
        let r = results
        results.removeAll()
        return r
    }

    /// Synchronous single measurement (also used by `jankprobe ax`).
    public static func measure(pid: Int32, timeoutMs: Double) -> FrontAppSample? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Float(timeoutMs / 1000))
        var value: CFTypeRef?
        let start = mach_absolute_time()
        let err = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value)
        let ms = MachClock.timebase.ticksToMillis(Double(mach_absolute_time() - start))
        switch err {
        case .apiDisabled, .notImplemented, .invalidUIElement:
            return nil  // no permission, or the app has no AX support: no information
        case .cannotComplete:
            // Returned both on timeout and on other failures; only a call that took ~the whole timeout is a hang.
            return FrontAppSample(pid: pid, roundTripMs: ms, timedOut: ms >= timeoutMs * 0.8)
        default:
            return FrontAppSample(pid: pid, roundTripMs: ms, timedOut: false)
        }
    }
}
#endif
