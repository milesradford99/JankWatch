# JankWatch — notes for coding agents

macOS menu-bar app that detects *perceived* lag (symptoms first), attributes it, and offers reversible fixes.
Read docs/ARCHITECTURE.md before changing detection or attribution logic.

## Layout
- `Sources/JankWatchCore` — pure logic, Foundation only. **Must keep compiling on Linux** (`swift build && swift test` runs in CI on Ubuntu). No AppKit/Darwin imports here.
- `Sources/JankWatchMac` — macOS integration. Every file is wrapped in `#if os(macOS)`.
- `Sources/JankWatch` — SwiftUI app; `Sources/jankctl` — admin helper; `Sources/jankprobe` — validation CLI.
- `Tests/JankWatchCoreTests` — XCTest for Core. Add tests for any Core change.

## Build / test
- `swift build && swift test` (any OS). macOS app bundle: `scripts/build-app.sh [arm64|x86_64]`.
- Swift tools 6.0, language mode 5, deployment target macOS 15.
- CI (`.github/workflows/ci.yml`) builds both architectures on macos-15 and smoke-runs jankprobe.

## Conventions
- User-facing strings are Simplified Chinese; code, comments and logs are English.
- All Mach tick values must go through `TimeBase` (Apple Silicon ticks are 125/3 ns).
- Never act on a pid without verifying its start time (`ProcessTable.isSame`). Never touch pid ≤ 1 or our own pid.
- The recover hotkey may only perform reversible actions (`Culprit.hotkeyAction`).
- Tunables live in `JankConfig` (persisted as config.json, partial files allowed) — don't hard-code thresholds elsewhere.

## Real-hardware validation
Not everything can be verified in CI. docs/VALIDATION.md lists the on-device checks (V0–V10) and
docs/REPORT_TEMPLATE.md the report format. When a validation report comes back, map each failed item to the
config keys / code listed in the VALIDATION.md appendix.
