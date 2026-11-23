#if os(macOS)
import Carbon
import Foundation

/// Global hotkeys via Carbon RegisterEventHotKey (works without Accessibility / Input Monitoring permission).
public final class HotKeyCenter {
    public static let shared = HotKeyCenter()

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var installed = false
    private static let signature: OSType = 0x4A4B_5754  // 'JKWT'

    public static let controlOptionCommand = UInt32(controlKey | optionKey | cmdKey)
    public static let keyL = UInt32(kVK_ANSI_L)
    public static let keyR = UInt32(kVK_ANSI_R)

    /// Register on the main thread. Returns false if the combination is taken by another app.
    @discardableResult
    public func register(keyCode: UInt32, modifiers: UInt32, id: UInt32, handler: @escaping () -> Void) -> Bool {
        installHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hkID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        refs.append(ref)
        handlers[id] = handler
        return true
    }

    public func unregisterAll() {
        for r in refs { UnregisterEventHotKey(r) }
        refs.removeAll()
        handlers.removeAll()
    }

    fileprivate func fire(_ id: UInt32) {
        handlers[id]?()
    }

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotKeyEventHandler, 1, &spec, nil, nil)
    }
}

private func hotKeyEventHandler(_ next: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var hkID = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                   MemoryLayout<EventHotKeyID>.size, nil, &hkID)
    guard status == noErr else { return status }
    let id = hkID.id
    DispatchQueue.main.async { HotKeyCenter.shared.fire(id) }
    return noErr
}
#endif
