#if os(macOS)
import AppKit
import JankWatchCore
import JankWatchMac
import SwiftUI

struct JankWatchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(model: appDelegate.model)
        } label: {
            MenuBarLabel(model: appDelegate.model)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.engine.stop()
    }
}

/// Bridges the engine (background queue) to SwiftUI. All mutations happen on the main thread.
final class AppModel: ObservableObject, EngineDelegate {
    @Published var status = EngineStatus()
    @Published var launchAtLogin = LoginItem.isEnabled
    @Published var hotkeysOK = true

    let engine: Engine
    let panels = PanelController()
    let settings = SettingsWindowController()

    init() {
        engine = Engine(store: EventStore(root: EventStore.defaultRoot()))
        engine.delegate = self
        panels.model = self
        settings.model = self
    }

    func start() {
        engine.start()
        let hk = HotKeyCenter.shared
        let a = hk.register(keyCode: HotKeyCenter.keyL, modifiers: HotKeyCenter.controlOptionCommand, id: 1) { [weak self] in
            self?.engine.mark()
        }
        let b = hk.register(keyCode: HotKeyCenter.keyR, modifiers: HotKeyCenter.controlOptionCommand, id: 2) { [weak self] in
            self?.engine.recoverHotkey()
        }
        hotkeysOK = a && b
        let p = PermissionStatus.current()
        if !UserDefaults.standard.bool(forKey: "onboarded") || !p.inputMonitoring || !p.accessibility {
            UserDefaults.standard.set(true, forKey: "onboarded")
            settings.show()
        }
    }

    // MARK: EngineDelegate (delivered on main)

    func engineDidUpdate(_ status: EngineStatus) {
        if status != self.status { self.status = status }
    }

    func engineShowAlert(_ alert: AlertModel) {
        panels.showAlert(alert)
    }

    func engineUpdateAlert(_ alert: AlertModel) {
        panels.updateAlert(alert)
    }

    func engineMessage(_ message: String) {
        panels.showToast(message)
    }

    // MARK: Actions from UI

    func perform(_ kind: ActionKind, _ c: Culprit, alertID: String?) { engine.perform(kind, culprit: c, alertID: alertID) }
    func ignore(_ c: Culprit, alertID: String?) { engine.ignore(groupKey: c.groupKey, name: c.displayName, alertID: alertID) }
    func notLag(_ alertID: String) { engine.feedbackNotLag(alertID: alertID) }
    func dismissed(_ alertID: String) { engine.dismissed(alertID: alertID) }
    func revert(_ r: ActionRecord) { engine.revert(recordID: r.id) }

    func updateConfig(_ change: (inout JankConfig) -> Void) {
        var c = status.config
        change(&c)
        status.config = c
        engine.updateConfig(c)
    }

    func setLaunchAtLogin(_ on: Bool) {
        if let err = LoginItem.set(on) { panels.showToast("开机启动设置失败：\(err)") }
        launchAtLogin = LoginItem.isEnabled
    }

    func openDataDirectory() { NSWorkspace.shared.open(engine.dataDirectory) }
    func openConfigFile() { NSWorkspace.shared.open(engine.store.configURL) }

    func requestInputMonitoring() {
        InputLatencySensor.requestPermission()
        SystemSettings.openInputMonitoring()
    }

    func requestAccessibility() {
        _ = FrontAppProbe.hasPermission(prompt: true)
        SystemSettings.openAccessibility()
    }
}
#endif
