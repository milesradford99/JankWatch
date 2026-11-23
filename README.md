# JankWatch

**你打字跟不上手、滚动一顿一顿的时候，告诉你是谁干的，并且一键恢复。**

JankWatch 是一个 macOS 菜单栏小工具。它只在屏幕亮着、你正在用电脑的时候工作：持续测量"你此刻有没有感到卡"，一旦确认卡了，就弹出一个不抢焦点的小窗口，告诉你原因和元凶，并给出可以撤销的修复按钮。

> **状态：v0.1，尚未经过实机验证。** 代码在没有 Mac 的环境里写成，CI 能在 arm64 和 x86_64 上编译并通过核心逻辑测试。有一批假设还要在真机上确认，验证步骤见 [docs/VALIDATION.md](docs/VALIDATION.md)。

## 和"CPU 高了就提醒"的工具有什么不同

| | 常见的资源监控 / 告警工具 | JankWatch |
|---|---|---|
| 判断依据 | 某个进程 CPU 超过 X% | **症状**：调度延迟、按键投递延迟、前台 App 是否无响应 |
| 能识别的原因 | CPU | CPU 争抢、内存换页、磁盘 IO、过热降频、WindowServer 负载、前台 App 自身卡住 |
| 元凶 | 单个进程 | 按 App 聚合（Chrome 的几十个 Helper 算一个），附进程说明 |
| 修复 | 结束进程 | **降级**（让出 CPU 和磁盘，可撤销）→ **暂停**（自动恢复）→ 退出 |
| 打扰 | 阈值一过就提醒 | 只在你正在操作、并且确实卡了的时候提醒；同一问题 2 分钟内只提醒一次 |

## 工作原理（简版）

- **调度探针**：一个和前台 UI 线程同等优先级的线程，每 50ms 醒来一次，测量自己晚醒了多少，以及一段固定计算变慢了多少。
- **输入延迟**：读取每个按键、点击、滚动事件从产生到被投递的耗时。**只读时间戳，从不读取按键内容。**
- **前台探测**：用辅助功能接口问一下前台 App"你的焦点窗口是哪个"。250ms 内没有回答，说明它自己卡住了。
- **归因**：在卡顿发生前后的 10 秒里，比对内存压力、swap、温控、各进程的 CPU、内存和磁盘占用，判断原因并找出元凶。

详细设计见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。

## 安装

需要 macOS 15 及以上，以及 Xcode 16 或 Command Line Tools（Swift 6）。Intel 和 Apple Silicon 分别打包。

```bash
git clone https://github.com/milesradford99/JankWatch.git
cd JankWatch
scripts/build-app.sh                  # 本机架构；也可以指定 arm64 或 x86_64
cp -R dist/$(uname -m)/JankWatch.app /Applications/
open /Applications/JankWatch.app
```

CI 也会为每次提交打出 `JankWatch-<版本>-arm64.zip` 和 `-x86_64.zip`（在 Actions 的 artifacts 里）。这些包没有经过公证，第一次打开时需要右键选"打开"，或者执行 `xattr -dr com.apple.quarantine /Applications/JankWatch.app`。

### 签名（建议）

macOS 按代码签名来记住授权。用默认的 ad-hoc 签名时，每次重新编译后都要重新授权。建议先建一个自签名证书：

1. 打开"钥匙串访问"，选择"证书助理 > 创建证书…"。名称填 `JankWatch Local Signing`，身份类型选"自签名根证书"，证书类型选"代码签名"。
2. 用这个证书来编译：

```bash
JANKWATCH_SIGN_IDENTITY="JankWatch Local Signing" scripts/build-app.sh
```

### 权限

| 权限 | 用途 | 不授予会怎样 |
|---|---|---|
| 输入监控 | 测量输入事件的投递延迟（只读时间戳） | 少了最贴近"打字跟不上"的那个信号 |
| 辅助功能 | 判断前台 App 是否卡住 | 无法区分"系统卡"还是"这个 App 自己卡" |
| 管理员密码（按需） | 操作属于系统（root）的进程，比如暂停 Spotlight 索引 | 只能操作你自己的进程 |

首次启动时会弹出设置窗口引导授权。授权后需要重启 JankWatch。

## 使用

- 菜单栏图标显示当前状态：流畅 / 有点慢 / 卡顿 / 暂停监测（息屏或锁屏）。
- 卡顿弹窗出现在屏幕右上角，**不会抢走你正在打字的窗口的焦点**。
  - **降级**：降到后台优先级，让出 CPU 和磁盘，可在菜单"已处理"里撤销。
  - **暂停**：冻结进程，10 分钟后或你切换到它时自动恢复。
  - **退出 / 强制退出**：强制退出需要点两次确认。
  - **🔒**：需要管理员密码。
  - **忽略**：以后不再把它当作元凶，比如正在编译的 Xcode。
  - **不是卡顿**：标记为误报，帮助改进检测。
- 快捷键：
  - **⌃⌥⌘R**：对当前卡顿执行推荐的可撤销操作，手不用离开键盘。
  - **⌃⌥⌘L**：标记"刚才卡了"。这会保存当时的数据，用于改进检测（尤其是没有检测到的情况）。

## 数据与隐私

所有数据都保存在本机的 `~/Library/Application Support/JankWatch/`，不联网，没有统计上报。

| 文件 | 内容 |
|---|---|
| `config.json` | 所有可调参数，只写想覆盖的键也可以 |
| `ticks/*.jsonl` | 每秒一行的指标（默认保留 7 天，可在设置里关闭） |
| `episodes/*.json` | 每次卡顿的完整记录 |
| `marks.jsonl`、`marks/` | 你按 ⌃⌥⌘L 标记的时刻和当时的快照 |
| `feedback.jsonl` | "不是卡顿"、"忽略"等反馈 |
| `actions.json` | JankWatch 做过的操作（用于撤销） |

这些文件里有进程名和 App 路径，但**不会**有任何按键内容、窗口标题或文件内容。

## 开发

```bash
swift build && swift test        # 核心逻辑在 Linux 上也能编译和测试
```

- 项目结构和设计见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。
- 实机验证见 [docs/VALIDATION.md](docs/VALIDATION.md)，报告模板见 [docs/REPORT_TEMPLATE.md](docs/REPORT_TEMPLATE.md)。
- `jankprobe` 是诊断用的命令行工具（编译后在 `dist/<arch>/jankprobe`），比如 `jankprobe probe --input` 可以实时查看探针数据。

## 许可证

MIT
