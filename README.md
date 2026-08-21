# zcode-cpu-guard

限制 **ZCode**（macOS Electron 应用）所有进程的 CPU 使用率，从源头降低功耗与发热。

> ⚠️ **适用机型：仅 Intel CPU 的 MacBook（尤其是老款）**
> 本工具专治 **Intel Mac 的散热/供电短板**——高负载下主板 VRM 过热触发系统强制降频
> （0.7~1.1GHz），导致卡顿。这种情况在 **Apple Silicon（M1/M2/M3/M4）Mac 上不存在**：
> 它们采用统一内存架构与不同的功耗/温度管理，不会因单应用高负载而整体降频，因此
> **本工具对 Apple Silicon Mac 没有用处，也不建议运行**。
> 此外进程枚举依赖 `libproc.dylib`，故**仅支持 macOS**，无法在 Linux / Windows 上使用。

## 为什么需要它

老款 **Intel MacBook**（实测机型：2018 款 15" Intel MacBook Pro）在 ZCode 高负载下，主板 VRM 供电模块
温度会超过 92℃，被系统强制降频到 0.7~1.1GHz，导致严重卡顿。本工具用 `cpulimit` 把每个
ZCode 进程限制在"单核"的指定百分比以内，直接压低功耗与温度，避免触发降频。

> 如果你的 Mac 是 Apple Silicon（M 系列芯片），**请直接关闭本页，无需安装**——它对你没有帮助。

## 原理与限制

- 用 [`cpulimit`](https://github.com/marlonx80/cpulimit) 周期性 `SIGSTOP`/`SIGCONT`（暂停-恢复）目标进程，属"粗暴"限流。
- `cpulimit` 的百分比按**单核**计：`40%` = 1 个核的 40%；ZCode 有多个子进程，叠加后总占用约为 `N × 40%` 单核。限太狠可能让界面掉帧，建议从 `40%` 起按体验微调。
- **仅支持 macOS（Intel 机型）**：进程枚举依赖 `libproc.dylib` / `proc_listpids`，且价值仅存在于会整体降频的老款 Intel Mac；Apple Silicon 与 Linux / Windows 均不适用。
- Homebrew 当前的 cpulimit 0.2（marlonx80 维护版）已移除 `-b` 参数，脚本改用 `nohup` 后台守护（效果相同，目标进程退出后 cpulimit 自动退出）。

## 依赖

- **Intel CPU 的 Mac**（Apple Silicon 不需要、也无收益）
- `cpulimit`：`brew install cpulimit`
- `python3`（macOS 自带，用于 libproc 进程枚举）

## 安装

```bash
git clone https://github.com/moyui/zcode-cpu-guard.git
cd zcode-cpu-guard
chmod +x limit-zcode-cpu.sh monitor-zcode-cpu.sh verify-zcode-guard.sh
```

## 用法

### 一次性限流

```bash
./limit-zcode-cpu.sh                # 默认限制 40%
CPU_LIMIT=60 ./limit-zcode-cpu.sh   # 临时调成 60%
pkill cpulimit                      # 解除所有限流，恢复原状
```

### 常驻 watch 模式（推荐）

每 5 秒扫描一次，自动补限新启动的 ZCode 进程（含瞬态进程），限流器意外退出也会自动补上。

```bash
CPU_LIMIT=60 ./limit-zcode-cpu.sh --watch
pkill -f "limit-zcode-cpu.sh --watch"   # 停止 watch（现有限流继续生效）
```

事件写入脚本所在目录的 `zcode-watch.log`。

### 监控与自检（可选）

```bash
bash monitor-zcode-cpu.sh 1800     # 监控 30 分钟 CPU 占用与限流覆盖 -> zcode-cpu-monitor.log
bash verify-zcode-guard.sh 1800    # 健康检查：覆盖率/重复/残留/冻结/watcher -> zcode-health.log
```

### 登录自启（LaunchAgent）

提供了 `com.zcode.cpu-guard.plist` 模板。把其中所有 `/PATH/TO/zcode-cpu-guard/` 替换为本机
仓库绝对路径，再安装：

```bash
# 先编辑 com.zcode.cpu-guard.plist，替换 /PATH/TO/... 为真实路径
cp com.zcode.cpu-guard.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.zcode.cpu-guard.plist
```

## 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `CPU_LIMIT` | `40` | 每个 ZCode 进程限制为单核 CPU 的百分比（0~100 整数） |
| `WATCH_INTERVAL` | `5` | watch 模式扫描间隔（秒） |
| `ZCODE_APP_PATH` | `/Applications/ZCode.app` | ZCode 应用路径（用于进程匹配） |
| `WATCH_LOG` | `<脚本目录>/zcode-watch.log` | watch 模式事件日志路径 |
| `ZCODE_MONITOR_LOG` | `<脚本目录>/zcode-cpu-monitor.log` | monitor 日志路径 |
| `ZCODE_HEALTH_LOG` | `<脚本目录>/zcode-health.log` | verify 日志路径 |

## 文件

| 文件 | 作用 |
|------|------|
| `limit-zcode-cpu.sh` | 核心：限流 ZCode 进程（once / watch 模式） |
| `monitor-zcode-cpu.sh` | 后台监控各进程 CPU 占用与限流覆盖 |
| `verify-zcode-guard.sh` | 后台健康检查：覆盖率/重复/残留/冻结/watcher |
| `com.zcode.cpu-guard.plist` | LaunchAgent 模板（需替换路径后使用） |

## License

MIT © moyui
