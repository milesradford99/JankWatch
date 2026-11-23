#if os(macOS)
import AppKit
import Foundation
import ServiceManagement

public struct PermissionStatus: Equatable, Sendable {
    public var inputMonitoring: Bool
    public var accessibility: Bool

    public static func current() -> PermissionStatus {
        PermissionStatus(inputMonitoring: InputLatencySensor.hasPermission(), accessibility: FrontAppProbe.hasPermission(prompt: false))
    }
}

public enum SystemSettings {
    public static func openInputMonitoring() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    public static func openAccessibility() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    private static func open(_ s: String) {
        if let url = URL(string: s) { NSWorkspace.shared.open(url) }
    }
}

public enum LoginItem {
    public static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    @discardableResult
    public static func set(_ on: Bool) -> String? {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
#endif
