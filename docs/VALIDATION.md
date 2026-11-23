# JankWatch 实机验证手册

这份文档写给**在真实 Mac 上做验证的人或 agent**。JankWatch 的代码是在没有 Mac 的环境里写的，靠 CI 保证能在 arm64 和 x86_64 上编译、核心逻辑测试能过。但有一批事情只能在真机上确认，这里一项一项列出来：怎么做、预期是什么、要记录哪些数。

做完后按 [REPORT_TEMPLATE.md](REPORT_TEMPLATE.md) 填一份报告，交回给开发者（或开发 agent）。

## 基本原则

- **两台机器都要做**：一台 Intel Mac，一台 Apple Silicon（M1 或更新）Mac，系统都是 macOS 15 或更新。每一项都分别记录两台的结果。
- **只记录，不调参**：发现阈值不合适时，记录数据和现象就够了，不要自己改代码里的阈值。真要改，改 `~/Library/Application Support/JankWatch/config.json`，并在报告里写清楚改了什么。
- **编译失败**：可以修，但修复要单独提交，并在报告里写明改了什么、为什么。
- **主观感受很重要**：每个压力场景都要在 TextEdit 里持续打字、在 Safari 里滚动网页，并记录"实际感觉卡不卡"。工具的判断最终要以人的感受为准。
- **隐私**：`~/Library/Application Support/JankWatch/` 下的数据含有进程名和 App 路径，但不含按键内容。上传或分享前先自己看一遍。
- **有风险的操作**：`scripts/stress/spotlight.sh` 会重建 Spotlight 索引，耗时较长，需要征得机主同意再跑。

## CI 已经确认的内容

GitHub Actions 的 `macos-15` runner 是一台 Apple M1 虚拟机（3 核，macOS 15.8），每次提交 CI 都会做以下这些事，真机上不需要重复确认：

- arm64 和 x86_64 两个包都能编译、打包、签名（ad-hoc）。
- `jankprobe env`、`rusage`、`topology`、`probe`、`evaluate` 都能运行。
- **V2 的部分答案：** 普通用户读不了任何 root 进程或其他用户进程的 rusage（0/139、0/70），`ps` 兜底覆盖了几乎全部（208/209）。Apple Silicon 上 rusage 的单位是 `machTicks`，自动校准结果正确。
- **端到端链路：** 用配置强制保持"活跃"，同时跑 `cpu.sh` 压力。引擎产生了卡顿，归因先是「Spotlight 索引」（虚拟机刚启动时确实在建索引，root 进程，通过 ps 兜底读到，按钮正确标成需要管理员权限）。压力开始后，元凶几秒内切换为「yes」；压力结束后又切回 Spotlight。停止引擎时，卡顿记录写入了 `episodes/`。

CI 确认**不了**的内容：真实输入延迟（CI 上没人打字）、弹窗 UI、权限弹框、管理员密码框、真机上探针的灵敏度，以及开销。CI 虚拟机上的开销约为单核的 1.3%，而且虚拟机的定时器本身就不准，平静时探针 p95 约 75ms。这些都要靠下面的步骤在真机上验证。

## 0. 准备

### 0.1 工具链

```bash
sw_vers                    # 需要 macOS 15+
xcode-select -p            # 需要 Xcode 16+ 或 Command Line Tools，Swift 6
swift --version
```

### 0.2 创建自签名代码签名证书（强烈建议）

不这样做的话，每次重新编译后 macOS 都会忘掉"输入监控"和"辅助功能"的授权。

1. 打开"钥匙串访问"，菜单选"钥匙串访问 > 证书助理 > 创建证书…"
2. 名称填 `JankWatch Local Signing`，身份类型选"自签名根证书"，证书类型选"代码签名"，然后点"创建"。
3. 在终端里执行：

```bash
export JANKWATCH_SIGN_IDENTITY="JankWatch Local Signing"
```

### 0.3 编译与安装

```bash
git clone https://github.com/milesradford99/JankWatch.git && cd JankWatch
scripts/build-app.sh            # 编译本机架构；在 M1 上也可以 scripts/build-app.sh x86_64 交叉编译
cp -R dist/$(uname -m)/JankWatch.app /Applications/
open /Applications/JankWatch.app
```

`jankprobe` 在 `dist/<arch>/jankprobe`，下文直接写成 `jankprobe`。可以设一个别名：`alias jankprobe=$PWD/dist/$(uname -m)/jankprobe`

### 0.4 授权

需要授两份权限，因为它们分属不同的程序：

- **JankWatch.app**：在"系统设置 > 隐私与安全性"里，给"输入监控"和"辅助功能"都打开 JankWatch。授权后退出 JankWatch 再重新打开。
- **终端（运行 jankprobe 用）**：给"输入监控"和"辅助功能"都打开你用的终端 App（Terminal 或 iTerm），然后**重启终端**。从终端运行的 jankprobe 继承的是终端的权限。

### 记录项

- 机型（`sysctl -n hw.model`）、芯片、内存大小、macOS 版本
- `jankprobe env` 的完整输出

---

## V0 构建与启动

| 检查 | 预期 |
|---|---|
| `scripts/build-app.sh` | 成功，最后打印 `done` |
| 打开 App | 菜单栏出现仪表盘图标，Dock 里**没有**图标 |
| 首次启动 | 自动弹出"JankWatch 设置"窗口，显示两项权限的状态 |
| 点开菜单栏图标 | 显示状态（"监测中 · 流畅"）、"近 2 分钟卡顿分"图表、最近卡顿、诊断信息 |
| 数据目录 | `~/Library/Application Support/JankWatch/` 下有 `config.json`、`ticks/` 和 `episodes/` |
| 静置 2 分钟后看菜单 | 诊断信息里"调度基线"从"学习中 x/60"变成一个具体的毫秒数 |

**记录项：** 每一项通过与否；任何报错或崩溃的信息（用 `log show --last 5m --predicate 'process == "JankWatch"'` 查看日志）。

## V1 输入事件时间戳的时钟（风险 1）

**问题：** `CGEvent.timestamp` 到底是纳秒，还是 mach tick？在 Apple Silicon 上两者差 41.67 倍。代码会自动校准，这一步要确认校准结果对不对。

```bash
jankprobe clock --seconds 20      # 运行期间在任意 App 里打字、点击、滚动
```

**预期：**
- 每个事件打印两个候选值：`if-nanos` 和 `if-ticks`。其中有且只有一个落在 0 到几十毫秒之间。
- `RESULT clock` 里 `decided` 是 `nanoseconds` 或 `machTicks`。Intel 上两个候选值相同，`decided` 是 `nanoseconds`。
- 合理的那个候选值，中位数通常在 0.1 到 10ms 之间。

**记录项：** `RESULT clock` 的 JSON；`decided` 的值；合理候选值的中位数和 p95。

**失败时：** 如果两个候选值都不合理，把前 20 行事件输出原样贴进报告。

## V2 能否读取其他用户的进程（风险 2）

**问题：** 以普通用户运行时，`proc_pid_rusage` 能不能读 root 进程（mds_stores、WindowServer、kernel_task）？读不了的话，代码会改用 `ps` 兜底。另外要确认 `ri_user_time` 的单位。

```bash
jankprobe rusage
sudo jankprobe rusage      # 对照：以 root 运行
```

**预期：**
- `ownUserOK == ownUserTotal`，即自己的进程全部能读。
- `rootOK` 和 `rootTotal` 照实记录即可，这一步只是取证。
- `psCoversDenied` 接近 `deniedEPERM`，说明 ps 兜底能覆盖读不了的进程。
- `kernelTaskViaPS`：照实记录。CI 的 Apple Silicon 虚拟机上为 `false`，即普通用户用 `ps` 也拿不到 kernel_task 的 CPU。这不影响降频判断，因为降频看的是温控等级和 CPU_Speed_Limit。
- `unit`：Intel 上为 `nanoseconds`；Apple Silicon 上为 `machTicks` 或 `nanoseconds`，照实记录。

**已知结果（CI 上 macOS 15.8 的 Apple Silicon 虚拟机）：** 普通用户读 root 进程 0/139，读其他用户进程 0/70，自己的进程 221/221，`ps` 兜底覆盖 208/209，`unit` 为 `machTicks`。真机上请确认是否一致。

**记录项：** 两次运行（普通用户、root）的 `RESULT rusage` JSON。

## V3 辅助功能探针的代价（风险 3）

**问题：** 每秒对前台 App 发一次 AX 查询，会不会让 Chrome、Electron 这类 App 打开辅助功能模式，反而变慢、变耗内存？

先让 Chrome 打开 10 个以上标签页，并放到后台保持静止，然后执行：

```bash
jankprobe ax --bundle com.google.Chrome --seconds 30
# 有 Electron App 的话也测一个：
jankprobe ax --bundle com.microsoft.VSCode --seconds 30
jankprobe ax --bundle com.tinyspeck.slackmacgap --seconds 30
jankprobe ax --bundle com.apple.Safari --seconds 30
```

**预期（通过标准）：**
- `p95Ms` < 50，`timeouts` = 0（App 没卡的情况下）。
- `appCPUPercentWithProbe` 与 `appCPUPercentWithoutProbe` 的差值 < 3 个百分点。
- `appMemoryBytesAfter` 与 `appMemoryBytesBefore` 的差值 < 100MB。

**记录项：** 每个 App 的 `RESULT ax`。

**失败时：** 记下是哪些 bundle id 没通过。修复方法是把它们加进默认配置的 `frontProbeSkipBundleIDs`，由开发者来改。

## V4 调度探针的灵敏度（风险 4，最核心的一项）

**问题：** 调度延迟探针和输入延迟，能不能区分出"顺滑"和"卡"？各种卡顿原因下，信号分别有什么表现？

打开两个终端。在**终端 A** 运行：

```bash
jankprobe probe --seconds 600 --input --csv ~/jw-probe-$(uname -m).csv
```

在**终端 B** 按顺序运行下面的场景。每个场景期间都在 TextEdit 里持续打字、在 Safari 里滚动网页；场景之间安静等 30 秒。

| # | 场景 | 命令 | 时长 |
|---|---|---|---|
| S0 | 平静 | （什么都不跑） | 60 秒 |
| S1 | CPU 跑满 | `scripts/stress/cpu.sh` | 60 秒 |
| S2 | CPU 两倍超载 | `scripts/stress/cpu.sh $(( $(sysctl -n hw.logicalcpu) * 2 )) 60` | 60 秒 |
| S3 | 内存压力 | `python3 scripts/stress/memory.py` | 至少 90 秒 |
| S4 | 磁盘 IO | `scripts/stress/disk.sh 10` | 直到跑完 |
| S5 | 前台 App 卡住 | `scripts/stress/hang-app.sh 8` | 约 15 秒 |
| S6 | Intel 过热（可选） | `scripts/stress/cpu.sh` 跑 5 分钟以上 | 观察 `limit` 列 |

**每个场景记录：**
- `lat_p95` 的典型值和最大值
- `samples`：有没有掉到 20 以下
- `ratio`（固定计算耗时相对开头 10 秒的倍数）
- `in_max`（输入延迟最大值）
- `cpu` / `pcpu`、`press`（内存压力）、`swapin`、`therm` / `limit`
- **主观感受**：0 表示顺滑，1 表示偶尔顿一下，2 表示明显卡，3 表示很卡

**预期（初始假设，正是要验证的内容）：**
- S0：`lat_p95` < 3ms，`ratio` 约等于 1，`in_max` < 30ms。
- S1、S2：如果主观感觉卡，`lat_p95` 或 `in_max` 应该明显升高。如果主观不卡、信号也平稳，同样是正确结果，因为 macOS 会优先调度前台。
- S3：`press` ≥ 2、`swapin` > 5MB/s，并且主观感觉卡。
- S5：probe 平稳，但打字没反应（这个场景要靠 AX 探针检测，见 V6）。

**交付：** CSV 文件，加上每个场景的上述记录。

## V5 CPU 拓扑（只在 Apple Silicon 上做）

```bash
jankprobe topology
```

**预期：** `effCoresFirstLooksRight: true`，即后台 QoS 线程集中跑在编号最小的 E 核上。

**记录项：** `RESULT topology` 的 JSON。

## V6 端到端检测与归因

运行已安装的 JankWatch.app，在终端里重跑 V4 的场景（每个场景期间同样保持打字和滚动），记录弹窗内容。也可以不开 App，改用 `jankprobe engine --verbose` 在终端里看事件。

| 场景 | 预期原因（cause） | 预期元凶 |
|---|---|---|
| S1/S2 cpu.sh | `cpuContention`（主观感觉卡的话） | `yes` |
| S3 memory.py | `memoryPressure` | `Python` / `python3`，推荐"退出" |
| S4 disk.sh | `diskIO` | `dd` |
| S5 hang-app.sh | `frontAppHung` | `TextEdit`，不推荐任何操作 |
| （可选）spotlight.sh | `diskIO` 或 `cpuContention` | `Spotlight 索引`，按钮带 🔒 |
| 正常使用 10 分钟 | 不应该弹窗 | — |

**每个场景记录：**
- 是否弹窗
- 从开始有卡顿感到弹窗用了几秒（目标 ≤ 3 秒）
- 弹窗标题（headline）
- 元凶列表是否正确
- 推荐操作
- 误报：在平静或正常使用期间弹出的提示

**数据：** 每次卡顿都会在 `~/Library/Application Support/JankWatch/episodes/` 下生成一个 JSON 文件，请附上。

## V7 弹窗交互

1. 打开 TextEdit 开始打字。从菜单栏选"更多 > 测试弹窗（5 秒后）"，然后**立刻点回 TextEdit 继续打字**。
   - **必须满足：** 弹窗出现后，打字继续输入到 TextEdit，焦点没有被抢走。
2. 第一次点击弹窗里的按钮就能生效，不需要先点一下激活窗口。
3. 在全屏 App 和多桌面下，弹窗都显示在当前屏幕的右上角。
4. 深色和浅色模式下文字都清晰可读。
5. 卡顿结束后约 20 秒，弹窗自动消失；点"×"可以立即关闭。
6. 按 ⌃⌥⌘L：右上角出现提示"已记录…"，并且 `marks.jsonl` 和 `marks/` 下多出记录。
7. 卡顿弹窗出现时按 ⌃⌥⌘R：执行推荐的可撤销操作，并出现提示。

**记录项：** 每一项通过与否；不通过的附截图。

## V8 恢复操作

先把 `config.json` 里的 `"pauseAutoResumeMinutes"` 改成 `1`，然后在菜单里选"设置 > 重新载入配置"。

1. **降级（自己的进程）：** 运行 `scripts/stress/cpu.sh 2 300`，等弹窗出现，点"降级"。
   - 用 `jankprobe act bg-on <pid>` 的对照输出，或用 `ps -o pid,stat,pri,comm -p <pid>` 查看，`pri` 应该下降。
   - 在菜单的"已处理"里点"撤销"，`pri` 应该恢复。
2. **暂停：** 同上点"暂停"。`ps` 的 `stat` 应显示 `T`；约 1 分钟后自动恢复（`stat` 变回 `R`），并出现提示"自动恢复"。
3. **切到前台自动恢复：** 让一个后台 GUI App 成为元凶，再用 JankWatch 暂停它。做法：在 Safari 里打开一个持续耗 CPU 的网页（比如浏览器跑分页面），切到 TextEdit 打字；等弹窗出现后，对 Safari 点"暂停"。也可以开着 Safari 用"测试弹窗"，如果元凶列表里有它，直接点"暂停"。然后切回 Safari，它应该立即恢复运行，并出现提示"你切换到了「…」，已自动恢复"。
4. **管理员路径：** 运行 `sudo sh -c 'yes > /dev/null' &`（这会产生一个 root 进程），等弹窗。元凶"yes"的按钮应该带 🔒。点"降级"后弹出系统密码框，输入密码后操作成功。结束后执行 `sudo pkill yes`。
5. **退出：** 在 S3 的内存场景里点"退出"，Python 进程应该结束。
6. **退出 JankWatch 时恢复：** 暂停一个进程后退出 JankWatch，被暂停的进程应该恢复运行（`stat` 不再是 `T`）。
7. **强制退出：** 按钮需要点两次（第二次显示"确认强制退出？"）。

**记录项：** 每一项通过与否，以及 `ps` 的前后对比。

## V9 自身开销

正常使用 10 分钟（屏幕亮着，一直在操作），每 10 秒采样一次，共 6 次：

```bash
for i in $(seq 6); do ps -o %cpu=,rss= -p $(pgrep -x JankWatch); sleep 10; done
```

同时看菜单里显示的"本工具 CPU"，以及活动监视器"能耗"标签里 JankWatch 的数值。

**通过标准：** 平均 CPU < 单核的 1%（即 `%cpu` 列 < 1.0），RSS < 80MB。

**记录项：** 6 次采样值，以及屏幕关闭或锁屏期间的 CPU（应接近 0）。

## V10 日常使用（至少 3 天，最好 7 天）

1. 照常使用电脑，JankWatch 保持开启（可以在设置里打开"开机启动"）。
2. **每次感觉卡了，就按 ⌃⌥⌘L**，这是评估检出率用的真实标签。
3. 弹窗不对时（其实没卡），点"不是卡顿"。
4. 结束后运行：

```bash
jankprobe evaluate
```

**记录项：**
- `RESULT evaluate` 的 JSON，关注 `recall`、`alertsPerActiveHour`、`notLagPerActiveHour`、`medianAlertDelaySec`、`episodesByCause`
- 漏检的标记时间（`unmatchedMarkTimes`）：对应的 `marks/<时间>.json` 里有当时前 30 秒的数据，请附上
- 任何"弹窗说的原因明显不对"的案例：附上对应的 `episodes/*.json`

**v1 验收目标：**

| 指标 | 目标 |
|---|---|
| `recall` | ≥ 0.8 |
| 误报 | ≤ 1 次/天 |
| `medianAlertDelaySec` | ≤ 3 |
| 自身 CPU（V9） | < 1% |
| 焦点（V7） | 从不抢焦点 |

---

## 附录：失败时常见的原因与对应配置

| 现象 | 可能原因 | 相关配置键 |
|---|---|---|
| 平静时 `lat_p95` 就 > 5ms | App Nap 或定时器合并没关掉 | （代码问题，请报告） |
| 平静时也频繁弹窗 | 阈值太低 | `sensitivity`、`probeLatenessFloorMs`、`inputModerateMs` |
| 明显卡却不弹 | 阈值太高，或信号不灵敏 | 同上，并附 `marks/` 快照 |
| 前台 App 误判为卡住 | AX 查询本身慢 | `frontProbeSlowMs`、`frontProbeTimeoutMs`、`frontProbeSkipBundleIDs` |
| 元凶是系统进程但 CPU 显示为 0 | rusage 被拒、ps 兜底失效 | V2 的结果 |
| 输入延迟一直为空 | 没授权，或时钟校准失败 | V1 的结果，菜单诊断里的"输入时钟" |
