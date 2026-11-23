# JankWatch 架构

JankWatch 的思路是：**先确认用户此刻真的感到卡（看症状），再找出是谁造成的（做归因），最后给出可以撤销的修复（分级操作）**。其他工具大多只做"某个进程 CPU 超过阈值就提醒"，而卡顿经常并不是 CPU 造成的：内存换页、磁盘 IO、过热降频、WindowServer 负载、前台 App 自己卡住，都会让人觉得卡。

## 模块

```
Sources/
  JankWatchCore/      纯逻辑，只依赖 Foundation，在 Linux 上也能编译和测试
    Models.swift          Tick（每秒一帧的全部数据）、各类采样结构
    Config.swift          所有可调参数（config.json，缺省的键自动用默认值）
    Signals.swift         调度探针基线 + 每秒的症状打分
    LagDetector.swift     带滞回的状态机：正常 / 疑似 / 卡顿，产生 Episode
    ProcessAccounting.swift  累计计数转速率、ps/pmset 输出解析、按 App 分组聚合
    KnowledgeBase.swift   内置进程知识库：说明、类别、允许的操作、管理员修复命令
    Attributor.swift      归因规则，产出 Diagnosis（原因 + 元凶 + 推荐操作）；AlertPolicy 负责弹窗去重
    Ledger.swift          操作记录（可撤销、自动恢复）
    Calibration.swift     时钟 / rusage 单位校准、CPU 拓扑、各核负载
    EventStore.swift      本地持久化 + 评估（检出率、误报率）
  JankWatchMac/       macOS 系统集成（每个文件都包在 #if os(macOS) 里）
    ProbeSensor.swift       调度延迟探针线程
    InputLatencySensor.swift  listen-only CGEventTap，测输入事件的投递延迟
    FrontAppProbe.swift     前台 App 的 AX 往返探测 + 前台 App 跟踪
    ProcessSampler.swift    sysctl 进程表 + proc_pid_rusage，读不到的改用 ps 兜底
    SystemSampler.swift     各核 CPU、vm_statistics64、内存压力、swap、温控、pmset（仅 Intel）
    ActivityGate.swift      息屏 / 锁屏 / 空闲判断
    ProcessController.swift 降级 / 暂停 / 退出，管理员路径（osascript + jankctl）
    HotKeys.swift           Carbon 全局快捷键
    Engine.swift            调度以上全部模块，1Hz 运行
  JankWatch/          菜单栏 App（SwiftUI MenuBarExtra + 不激活的 NSPanel 弹窗）
  jankctl/            以管理员权限执行单个进程操作的小工具（重新校验 pid 和启动时间）
  jankprobe/          实机验证用的命令行工具（docs/VALIDATION.md）
```

## 每秒一次的处理流程

1. **门控**：屏幕睡眠、锁屏或会话不在前台时为 `off`；60 秒没有输入为 `idle`；其他情况为 `active`。只有 `active` 时才运行探针和采样。进入 `active` 时用 `beginActivity(.latencyCritical)` 关掉 App Nap（App Nap 会让探针测出假延迟），但不阻止系统空闲睡眠。
2. **采集症状**：
   - **调度探针**：一个 `userInteractive` QoS 的线程（与前台 App 的 UI 线程同级），每 50ms 用 `mach_wait_until` 唤醒一次，记录比预期晚了多少。每 4 次唤醒跑一次固定的计算量，记录耗时。唤醒变晚说明 CPU 被抢；同样的计算变慢说明降频或严重争抢；唤醒次数不足说明探针线程被饿死。
   - **输入延迟**：listen-only 的事件 tap 监听 keyDown、点击和滚动，计算"现在 − event.timestamp"。只读时间戳，不读按键内容。时钟单位在运行时自动校准。
   - **前台探测**：对前台 App 发一次 AX 查询（focused window），超时 250ms。超时说明这个 App 的主线程卡住了。
3. **采集上下文**：所有进程的 CPU、内存（phys_footprint）、磁盘读写速率，按"最外层 .app"或知识库分组（Chrome 的几十个 Helper 合成一组 "Google Chrome"，mds/mdworker 合成 "Spotlight 索引"）；以及系统 CPU（M1 上单独计算 P 核）、内存压力、swap 读入速率、温控等级、Intel 的 CPU_Speed_Limit。
4. **打分**（`SignalEvaluator`）：每个信号 0 分为正常，0.5 分为中等，0.75 到 1 分为严重。总分 ≥ 1 记为一个"卡顿秒"。也就是说，需要两个信号同时中等，或者一个信号严重，并且用户在最近 5 秒内有输入。

   | 信号 | 0.5 分 | 1 分 |
   |---|---|---|
   | 探针唤醒延迟 p95 | ≥ max(8ms, 基线 × 4)（没有基线时为 12ms） | ≥ max(50ms, 基线 × 6)，或唤醒次数 < 预期的 50% |
   | 固定计算耗时 / 基线 | ≥ 1.8 倍 | ≥ 3 倍 |
   | 输入延迟 | 1 个事件 ≥ 80ms（2 个及以上为 0.75 分） | 任一事件 ≥ 250ms |
   | 前台 AX 往返 | ≥ 100ms | 超时（≥ 250ms） |

   灵敏度"低 / 中 / 高"会把这些阈值分别乘以 1.3、1.0、0.75。基线从"用户活跃、并且输入延迟和前台 App 都正常"的秒里学习（不看探针自己的分数，这样平时就比较嘈杂的机器也能学到自己的基线，而不是一直误报）。卡顿期间不学习，最多保留 600 个样本，取中位数，单个样本超过 40ms 不计入。CI 的 Apple Silicon 虚拟机在 CPU 九成以上忙碌时，探针 p95 约为 75ms，所以阈值不能写死。

5. **状态机**（`LagDetector`）：最近 5 秒里有 ≥ 3 个卡顿秒时进入"卡顿"，降到 ≤ 1 个时退出。门控变为非 `active` 时立即结束当前卡顿。
6. **归因**（`Attributor`）：取最近 10 秒的数据，按优先级判断原因。

   | 优先级 | 原因 | 判据 | 元凶 | 推荐操作 |
   |---|---|---|---|---|
   | 1 | 前台 App 自身无响应 | AX 超时，并且探针基本正常 | 前台 App | 不推荐（只提供退出 / 强制退出） |
   | 2 | 内存不足 | 压力 ≥ 警告，并且 swap 读入 ≥ 5MB/s | 占用内存最多的组（后台优先） | 退出（快捷键执行"暂停"） |
   | 3 | 过热降频 | 温控 ≥ serious，或 CPU_Speed_Limit < 90 | CPU 最高的后台组 | 降级 |
   | 4 | CPU 争抢 | （P 核）忙碌 ≥ 85%，或某个后台组 ≥ 80% | CPU ≥ 30% 的后台组 | 降级 |
   | 5 | 磁盘 IO | 某个后台组读写 ≥ 50MB/s | IO 最高的后台组 | 降级 / 管理员修复 |
   | 6 | 图形合成 | WindowServer ≥ 70% | 后台高 CPU 组（WindowServer 本身不能操作） | — |
   | 7 | 未知 | 以上都不满足 | 列出最可疑的 | — |

   以下几类永远不会被列为元凶：JankWatch 自己、kernel_task、launchd、WindowServer、用户选择忽略的组。

7. **弹窗**：同一"原因 + 元凶"组合 120 秒内只弹一次。卡顿持续期间每 3 秒重新归因、刷新弹窗；用户已经操作过之后就不再刷新，免得内容在鼠标底下跳动。
8. **记录**：每秒一行写入 `ticks/YYYY-MM-DD.jsonl`（保留 7 天）。每次卡顿在结束 10 秒后写入 `episodes/*.json`，包含前 30 秒的完整数据。按 ⌃⌥⌘L 标记的时刻写入 `marks.jsonl`，并保存前 30 秒的快照到 `marks/`。

## 操作与安全

| 类别 | 允许的操作 |
|---|---|
| critical（kernel_task、WindowServer、launchd…） | 无 |
| security（XProtect、EDR…） | 无 |
| systemService（iCloud 同步、nsurlsessiond…） | 降级 |
| systemDeferrable（Spotlight、照片分析、Time Machine、系统更新…） | 降级、暂停，加上知识库里的管理员修复 |
| userApp / developer | 降级、暂停、退出、强制退出 |

- **降级**：`setpriority(PRIO_DARWIN_PROCESS, pid, PRIO_DARWIN_BG)`，降低 CPU 和 IO 优先级；在 Apple Silicon 上会把进程赶到 E 核。可以撤销。
- **暂停**：SIGSTOP。默认 10 分钟后自动 SIGCONT；用户切换到该 App 时立即恢复；JankWatch 退出时，以及下次启动时，都会恢复所有被暂停的进程。
- **退出**：GUI App 调用 `NSRunningApplication.terminate()`，App 会提示保存；其他进程发 SIGTERM。强制退出需要点两次确认。
- **快捷键 ⌃⌥⌘R** 只执行可撤销的操作（降级或暂停）。
- 每次操作前都会核对 pid 和进程启动时间，防止 pid 被复用后误伤其他进程；pid ≤ 1 和 JankWatch 自身一律拒绝。
- 属于其他用户（root）的进程，通过系统管理员密码框以 root 身份运行内置的 `jankctl` 来操作，`jankctl` 会再核对一次 pid 和启动时间。

## Intel 与 Apple Silicon 的差异

| | Intel | Apple Silicon |
|---|---|---|
| mach tick | 1ns | 125/3ns。所有 tick 都经过 `TimeBase` 换算，rusage 的单位在运行时校准 |
| CPU 核心 | 同构 | 区分 P 核和 E 核（`hw.perflevel*`），CPU 争抢按 P 核计算 |
| 降频信号 | `pmset -g therm`（每 10 秒一次）、thermalState | thermalState |
| 降级的效果 | 降低优先级 | 降低优先级，并迁移到 E 核 |

两种架构用同一份代码，分别打包：`scripts/build-app.sh arm64`、`scripts/build-app.sh x86_64`。

## 尚未验证的假设

这些都需要在真机上确认，见 [VALIDATION.md](VALIDATION.md)：

1. `CGEvent.timestamp` 的时钟单位（V1），代码会自动校准。
2. 非 root 时能否用 `proc_pid_rusage` 读 root 进程（V2），读不了时用 ps 兜底。
3. AX 探测会不会拖慢 Chromium / Electron 类 App（V3）。
4. 调度探针在各种卡顿下是否灵敏，尤其是内存换页（V4）。
5. Apple Silicon 上 E 核是否排在编号最前（V5）。
