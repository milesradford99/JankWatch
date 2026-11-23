import Foundation

public enum ProcessCategory: String, Codable, Sendable {
    /// Never touch (kernel, window server, launchd...).
    case critical
    /// Security / endpoint software. Never touch (may also violate company policy).
    case security
    /// System services that can be slowed down but should not be paused or killed.
    case systemService
    /// System background work that is safe to defer (indexing, photo analysis, backups, updates).
    case systemDeferrable
    /// Developer tooling (compilers, language servers, VMs).
    case developer
    /// Ordinary user applications.
    case userApp
}

public struct AdminFix: Codable, Equatable, Sendable {
    public var title: String
    public var command: [String]
    public var undoTitle: String?
    public var undoCommand: [String]?
    public var note: String?

    public init(title: String, command: [String], undoTitle: String? = nil, undoCommand: [String]? = nil, note: String? = nil) {
        self.title = title
        self.command = command
        self.undoTitle = undoTitle
        self.undoCommand = undoCommand
        self.note = note
    }
}

public struct KBEntry: Codable, Equatable, Sendable {
    /// Exact process names (or prefixes when `prefix` is true).
    public var names: [String]
    public var prefix: Bool
    /// If set, all matching processes are grouped under this display name.
    public var group: String?
    public var category: ProcessCategory
    public var description: String
    public var advice: String?
    public var adminFix: AdminFix?

    public init(_ names: [String], prefix: Bool = false, group: String? = nil, category: ProcessCategory,
                _ description: String, advice: String? = nil, adminFix: AdminFix? = nil) {
        self.names = names
        self.prefix = prefix
        self.group = group
        self.category = category
        self.description = description
        self.advice = advice
        self.adminFix = adminFix
    }

    func matches(_ name: String) -> Bool {
        if prefix { return names.contains { name.hasPrefix($0) } }
        return names.contains(name)
    }
}

public struct KnowledgeBase: Sendable {
    public var entries: [KBEntry]

    public init(entries: [KBEntry]) {
        self.entries = entries
    }

    public func lookup(_ processName: String) -> KBEntry? {
        entries.first { $0.matches(processName) }
    }

    /// Lookup by group display name (for groups created from a KB `group`).
    public func lookup(group: String) -> KBEntry? {
        entries.first { $0.group == group }
    }

    /// Category for a process / group, falling back to path heuristics.
    public func category(processName: String, path: String?, groupName: String? = nil) -> ProcessCategory {
        if let e = lookup(processName) { return e.category }
        if let g = groupName, let e = lookup(group: g) { return e.category }
        if let p = path {
            if p.hasPrefix("/System/") || p.hasPrefix("/usr/libexec/") || p.hasPrefix("/usr/sbin/") || p.hasPrefix("/sbin/") {
                return .systemService
            }
            if p.hasPrefix("/Library/SystemExtensions/") { return .security }
        }
        return .userApp
    }

    public static let builtin = KnowledgeBase(entries: [
        // Critical
        KBEntry(["kernel_task"], category: .critical,
                "macOS 内核。CPU 占用高通常是在主动限速给芯片降温（过热保护），本身不是元凶。",
                advice: "先找出发热的进程；Intel 机型检查风扇/灰尘，必要时重置 SMC。"),
        KBEntry(["launchd"], category: .critical, "系统第一个进程，负责启动和管理所有服务。"),
        KBEntry(["WindowServer"], category: .critical,
                "负责把所有窗口画到屏幕上。高负载常见于录屏/屏幕共享、外接高分辨率显示器、大量透明/动画窗口。",
                advice: "停止录屏或屏幕共享，减少外接显示器，或关闭“减少透明度”以外的视觉特效。"),
        KBEntry(["loginwindow"], category: .critical, "登录会话管理进程。"),
        KBEntry(["hidd"], category: .critical, "键盘鼠标等输入设备服务。"),
        KBEntry(["coreaudiod"], category: .critical, "系统音频服务。"),
        KBEntry(["opendirectoryd", "configd", "notifyd", "distnoted", "cfprefsd", "securityd"], category: .critical,
                "系统核心服务。"),
        KBEntry(["powerd", "thermald", "thermalmonitord"], category: .critical, "电源与温控服务。"),

        // Security
        KBEntry(["XProtect", "XprotectService", "XProtectPluginService", "XProtectRemediator"], prefix: true, group: "XProtect",
                category: .security, "Apple 内置的恶意软件扫描，系统更新或安装新 App 后会扫描一阵。"),
        KBEntry(["syspolicyd"], category: .security, "Gatekeeper 签名校验，打开新下载的 App 时会忙一会。"),
        KBEntry(["trustd"], category: .security, "证书校验服务。"),
        KBEntry(["falcond", "com.crowdstrike.falcon.Agent"], category: .security, "CrowdStrike 终端安全软件（公司设备常见）。",
                advice: "公司安全软件不能自行停止，如长期占用请联系 IT。"),
        KBEntry(["wdavdaemon", "wdavdaemon_enterprise", "wdavdaemon_unprivileged"], category: .security,
                "Microsoft Defender 终端安全软件。", advice: "公司安全软件不能自行停止，如长期占用请联系 IT。"),
        KBEntry(["SentinelAgent", "sentineld"], category: .security, "SentinelOne 终端安全软件。"),

        // Spotlight
        KBEntry(["mds", "mds_stores", "mdworker", "mdworker_shared", "mdsync", "corespotlightd", "mdbulkimport"], group: "Spotlight 索引",
                category: .systemDeferrable,
                "Spotlight 正在为文件建立搜索索引。系统更新、拷入大量文件或新装 App 后会持续一段时间。",
                advice: "可以暂停索引，等方便时再恢复。",
                adminFix: AdminFix(title: "暂停 Spotlight 索引", command: ["/usr/bin/mdutil", "-a", "-i", "off"],
                                   undoTitle: "恢复 Spotlight 索引", undoCommand: ["/usr/bin/mdutil", "-a", "-i", "on"],
                                   note: "暂停期间 Spotlight 搜不到新文件，记得恢复。")),

        // Photos / ML
        KBEntry(["photoanalysisd", "mediaanalysisd", "photolibraryd", "mediaanalysisd-access", "VisionKitAgent"], group: "照片分析",
                category: .systemDeferrable, "“照片”在后台做人脸、场景识别和视频分析，导入大量照片后会持续很久。"),
        KBEntry(["knowledgeconstructiond", "suggestd", "triald", "duetexpertd", "intelligenceplatformd", "siriknowledged"],
                group: "Siri/智能建议", category: .systemDeferrable, "Siri 与 Apple 智能的后台学习和建议生成。"),

        // Backup / sync
        KBEntry(["backupd", "backupd-helper"], group: "Time Machine 备份", category: .systemDeferrable,
                "Time Machine 正在备份，大量读盘。",
                adminFix: AdminFix(title: "停止本次备份", command: ["/usr/bin/tmutil", "stopbackup"], note: "下一次计划备份仍会照常进行。")),
        KBEntry(["cloudd", "bird", "fileproviderd", "cloudphotod", "CloudDocsDaemon"], group: "iCloud 同步",
                category: .systemService, "iCloud 云盘/照片正在同步，大量上传下载和读写磁盘。"),
        KBEntry(["nsurlsessiond"], category: .systemService, "系统后台下载服务（App 更新、iCloud、系统更新等）。"),

        // Updates
        KBEntry(["softwareupdated", "softwareupdate", "SoftwareUpdateNotificationManager", "MobileSoftwareUpdate"], prefix: true,
                group: "系统更新", category: .systemDeferrable, "正在下载或准备 macOS 更新。"),
        KBEntry(["storedownloadd", "appstoreagent"], group: "App Store 下载", category: .systemDeferrable, "App Store 正在下载或更新 App。"),

        // Diagnostics
        KBEntry(["ReportCrash", "spindump", "tailspind", "sysdiagnose"], group: "系统诊断", category: .systemDeferrable,
                "系统在为崩溃/卡死的程序生成诊断报告，通常很快结束。"),
        KBEntry(["PerfPowerServices", "PerfPowerServicesExtended"], group: "能耗记录", category: .systemService,
                "系统能耗统计服务，偶尔会异常占用 CPU 很久。", advice: "长期占用可尝试重启 Mac。"),

        // Web content
        KBEntry(["com.apple.WebKit.WebContent", "com.apple.WebKit.GPU", "com.apple.WebKit.Networking"], group: "Safari/WebKit 网页",
                category: .userApp, "Safari 或其他使用 WebKit 的 App 的网页进程，某个标签页在跑重脚本或视频。",
                advice: "在 Safari 里找到并关闭耗资源的标签页（Safari 菜单“开发 > 显示页面资源”或用活动监视器看标签名）。"),

        // Developer
        KBEntry(["SourceKitService", "sourcekit-lsp", "swift-frontend", "clang", "ld", "XCBBuildService"], group: "Xcode/Swift 编译",
                category: .developer, "Xcode 或 Swift 工具链在编译/索引代码。"),
        KBEntry(["node", "bun", "deno"], category: .developer, "JavaScript 运行时（开发服务器、构建工具、语言服务器等）。"),
        KBEntry(["java"], category: .developer, "Java 进程（IDE、Gradle、Android 构建等）。"),
        KBEntry(["com.docker.backend", "com.docker.virtualization", "com.docker.hyperkit", "qemu-system-aarch64", "qemu-system-x86_64",
                 "com.apple.Virtualization.VirtualMachine"], group: "虚拟机/Docker", category: .developer,
                "Docker 或虚拟机，内部的工作负载会直接占用宿主机 CPU 和内存。"),
    ])
}
