#if os(macOS)
import AppKit
import CoreGraphics
import Foundation
import JankWatchCore

/// Decides whether we should be monitoring: screen awake, not locked, our session on console, and the user active.
public final class ActivityGate {
    private let lock = NSLock()
    private var screensAsleep = false
    private var locked = false
    private var sessionInactive = false
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []

    public init() {}

    /// Register for notifications. Call on the main thread.
    public func start() {
        let ws = NSWorkspace.shared.notificationCenter
        func on(_ center: NotificationCenter, _ name: Notification.Name, _ body: @escaping (ActivityGate) -> Void) {
            let t = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                body(self)
                self.lock.unlock()
            }
            tokens.append((center, t))
        }
        on(ws, NSWorkspace.screensDidSleepNotification) { $0.screensAsleep = true }
        on(ws, NSWorkspace.screensDidWakeNotification) { $0.screensAsleep = false }
        on(ws, NSWorkspace.willSleepNotification) { $0.screensAsleep = true }
        on(ws, NSWorkspace.didWakeNotification) { $0.screensAsleep = false }
        on(ws, NSWorkspace.sessionDidResignActiveNotification) { $0.sessionInactive = true }
        on(ws, NSWorkspace.sessionDidBecomeActiveNotification) { $0.sessionInactive = false }
        let dnc = DistributedNotificationCenter.default()
        on(dnc, Notification.Name("com.apple.screenIsLocked")) { $0.locked = true }
        on(dnc, Notification.Name("com.apple.screenIsUnlocked")) { $0.locked = false }
        lock.lock()
        locked = Self.sessionSaysLocked()
        lock.unlock()
    }

    deinit {
        for (c, t) in tokens { c.removeObserver(t) }
    }

    static func sessionSaysLocked() -> Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        if let v = dict["CGSSessionScreenIsLocked"] as? Bool { return v }
        if let v = dict["CGSSessionScreenIsLocked"] as? Int { return v != 0 }
        return false
    }

    /// Seconds since the last keyboard / mouse / trackpad input in this login session. No permission needed.
    public static func idleSeconds() -> Double {
        let types: [CGEventType] = [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .mouseMoved, .leftMouseDragged, .scrollWheel]
        var m = Double.greatestFiniteMagnitude
        for t in types {
            m = min(m, CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: t))
        }
        return m
    }

    public func evaluate(idleAfter: Double) -> (state: GateState, idleSeconds: Double) {
        lock.lock()
        let off = screensAsleep || locked || sessionInactive
        lock.unlock()
        let idle = Self.idleSeconds()
        if off { return (.off, idle) }
        return (idle >= idleAfter ? .idle : .active, idle)
    }
}
#endif
