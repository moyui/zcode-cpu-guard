<p align="right">
  <a href="./README.zh-CN.md">中文</a> | <strong>English</strong>
</p>

# zcode-cpu-guard

[![Platform: macOS (Intel)](https://img.shields.io/badge/platform-macOS%20(Intel)-lightgrey.svg)](#)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)
[![Shell](https://img.shields.io/badge/shell-bash-green.svg)](#)

Cap CPU usage for all **ZCode** (macOS Electron app) processes to cut power and heat — **Intel Macs only**. See [README.zh-CN.md](./README.zh-CN.md) for Chinese.

> ⚠️ **Platform: Intel MacBooks only (especially older models)**
> This tool targets the **thermal/power weakness of Intel Macs** — under heavy load the board VRM overheats and the system throttles to 0.7–1.1 GHz, causing severe stutter. **Apple Silicon (M1/M2/M3/M4) Macs do NOT have this problem**: their unified memory and thermal management prevent system-wide throttling from a single app, so **this tool is useless on Apple Silicon and not recommended**.
> Process enumeration depends on `libproc.dylib`, so it **only works on macOS**, not Linux/Windows.

## Why

The older **Intel MacBook** (tested: 2018 15" Intel MacBook Pro) sees its VRM power module exceed 92°C under heavy ZCode load, forcing a throttle to 0.7–1.1 GHz. This tool uses `cpulimit` to cap each ZCode process to a percentage of a single core, directly lowering power and temperature to avoid throttling.

> If your Mac is Apple Silicon, **close this page — you don't need it**.

## Principles & Limitations

- Uses [`cpulimit`](https://github.com/marlonx80/cpulimit) to periodically `SIGSTOP`/`SIGCONT` target processes — a coarse throttle.
- Percentage is **per core**: `40%` = 40% of one core; ZCode has multiple child processes, total is roughly `N × 40%`. Too aggressive may cause frame drops — start from `40%` and tune.
- **macOS (Intel) only**: relies on `libproc.dylib` / `proc_listpids`; no value on Apple Silicon or Linux/Windows.
- Homebrew `cpulimit` 0.2 (marlonx80 fork) removed `-b`; scripts use `nohup` background daemon instead (same effect, `cpulimit` exits when target exits).

## Requirements

- **Intel Mac** (no benefit on Apple Silicon)
- `cpulimit`: `brew install cpulimit`
- `python3` (bundled on macOS, for libproc enumeration)

## Installation

```bash
git clone https://github.com/moyui/zcode-cpu-guard.git
cd zcode-cpu-guard
chmod +x limit-zcode-cpu.sh monitor-zcode-cpu.sh verify-zcode-guard.sh
```

## Usage

### One-shot throttling

```bash
./limit-zcode-cpu.sh                # default 40%
CPU_LIMIT=60 ./limit-zcode-cpu.sh   # temporarily 60%
pkill cpulimit                      # remove all throttling
```

### Persistent watch mode (recommended)

Scans every 5 seconds, auto-throttles newly spawned ZCode processes (including transient ones) and re-applies if the limiter exits unexpectedly.

```bash
CPU_LIMIT=60 ./limit-zcode-cpu.sh --watch
pkill -f "limit-zcode-cpu.sh --watch"   # stop watch (existing throttles remain)
```

Events are written to `zcode-watch.log` in the script directory.

### Monitoring & self-check (optional)

```bash
bash monitor-zcode-cpu.sh 1800     # monitor CPU & coverage for 30 min -> zcode-cpu-monitor.log
bash verify-zcode-guard.sh 1800    # health checks: coverage/dup/orphan/freeze/watcher -> zcode-health.log
```

### LaunchAgent (auto-start on login)

Template `com.zcode.cpu-guard.plist` is provided. Replace all `/PATH/TO/zcode-cpu-guard/` with the absolute repo path, then install:

```bash
# Edit com.zcode.cpu-guard.plist, replace /PATH/TO/... with real path
cp com.zcode.cpu-guard.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.zcode.cpu-guard.plist
```

## Environment Variables

| Variable | Default | Notes |
|------|--------|------|
| `CPU_LIMIT` | `40` | Per-process cap as % of one core (0–100 integer) |
| `WATCH_INTERVAL` | `5` | Watch mode scan interval (seconds) |
| `ZCODE_APP_PATH` | `/Applications/ZCode.app` | ZCode app path for process matching |
| `WATCH_LOG` | `<script dir>/zcode-watch.log` | Watch mode event log path |
| `ZCODE_MONITOR_LOG` | `<script dir>/zcode-cpu-monitor.log` | Monitor log path |
| `ZCODE_HEALTH_LOG` | `<script dir>/zcode-health.log` | Verify log path |

## Files

| File | Purpose |
|------|------|
| `limit-zcode-cpu.sh` | Core: throttle ZCode processes (once / watch mode) |
| `monitor-zcode-cpu.sh` | Monitor per-process CPU & coverage |
| `verify-zcode-guard.sh` | Health checks: coverage/dup/orphan/freeze/watcher |
| `com.zcode.cpu-guard.plist` | LaunchAgent template (replace paths before use) |

## License

MIT © moyui — see [LICENSE](./LICENSE).
