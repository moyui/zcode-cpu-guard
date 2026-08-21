#!/bin/bash
# =============================================================================
# limit-zcode-cpu.sh — 限制 ZCode (Electron) 所有进程的 CPU 使用率（macOS）
#
# 背景：部分 MacBook（如 2018 款 15" Intel MacBook Pro）在 ZCode 高负载下，
#       主板 VRM 供电模块温度超过 92℃，被系统强制降频到 0.7~1.1GHz，导致卡顿。
#       本脚本用 cpulimit（Homebrew: brew install cpulimit，0.2 版）把每个
#       ZCode 进程的 CPU 占用限制在"单核"的指定百分比以内，从源头降功耗、降发热。
#
# 用法（一次性）：
#   chmod +x limit-zcode-cpu.sh
#   ./limit-zcode-cpu.sh                # 默认限制 40%
#   CPU_LIMIT=60 ./limit-zcode-cpu.sh   # 临时调成 60%
#   pkill cpulimit                      # 解除所有限流，恢复原状
#
# 用法（常驻 watch 模式，推荐）：
#   CPU_LIMIT=60 ./limit-zcode-cpu.sh --watch
#   # 每 5 秒扫描一次，自动补限新生进程（含瞬态进程，出生后 ≤5s 内命中），
#   # 限流器意外退出也会自动补上；事件写入 <脚本目录>/zcode-watch.log
#   pkill -f "limit-zcode-cpu.sh --watch"   # 停止 watch（现有限流继续生效）
#
# 注意：
#   - Homebrew 当前的 cpulimit 0.2（marlonx80 维护版）已移除 -b 参数，
#     脚本用 nohup 后台守护代替（效果相同，目标进程退出后 cpulimit 自动退出）。
#   - cpulimit 的百分比按"单核"计，40% = 1 个核的 40%；多个子进程叠加后
#     总占用约为 N × 40% 单核，需要更保守时可调低默认值。
#   - 限流原理是周期性 SIGSTOP/SIGCONT（暂停-恢复）进程，属"粗暴"限流，
#     限得太狠可能让界面掉帧，建议从 40% 起按实际体验微调。
#   - 限流后 top/ps 里会多出若干个 "cpulimit" 监控进程，属正常现象。
#   - 仅支持 macOS（依赖 libproc.dylib / proc_listpids）。
# =============================================================================

set -u

# ------------------------- 路径与可调参数（可用环境变量覆盖） -----------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ZCODE_APP_PATH="${ZCODE_APP_PATH:-/Applications/ZCode.app}"
CPU_LIMIT="${CPU_LIMIT:-40}"        # 每个 ZCode 进程限制为单核 CPU 的 40%（0~100）
WATCH_INTERVAL="${WATCH_INTERVAL:-5}"   # watch 模式扫描间隔（秒）
WATCH_LOG="${WATCH_LOG:-$SCRIPT_DIR/zcode-watch.log}"

# 校验 CPU_LIMIT 必须是整数
case "$CPU_LIMIT" in
  ''|*[!0-9]*)
    echo "❌ CPU_LIMIT 必须是 0~100 的整数（当前值：'$CPU_LIMIT'）"
    exit 1
    ;;
esac

# 模式判定
MODE="once"
if [ "${1:-}" = "--watch" ] || [ "${1:-}" = "-w" ]; then
  MODE="watch"
fi

# ------------------------- 0. 检查 cpulimit 是否安装 -------------------------
CPULIMIT_BIN="$(command -v cpulimit 2>/dev/null)"
if [ -z "$CPULIMIT_BIN" ] && [ -x /usr/local/bin/cpulimit ]; then
  CPULIMIT_BIN="/usr/local/bin/cpulimit"
fi
if [ -z "$CPULIMIT_BIN" ]; then
  echo "❌ 未找到 cpulimit，请先安装：brew install cpulimit"
  exit 1
fi
if [ "$MODE" = "watch" ]; then
  echo "[watch] cpulimit: $CPULIMIT_BIN, CPU_LIMIT=${CPU_LIMIT}%"
else
  echo "✅ 使用 cpulimit：$CPULIMIT_BIN"
  echo "📌 限流策略：每个 ZCode 进程 ≤ ${CPU_LIMIT}% 单核 CPU"
fi

# ------------------------- 1. 预先申请 sudo 权限（缓存 5 分钟） -------------------------
sudo -v 2>/dev/null
if [ $? -eq 0 ]; then
  [ "$MODE" = "watch" ] && echo "[watch] sudo ok (cached 5 min)" || echo "✅ sudo 授权成功（缓存 5 分钟）"
else
  if [ "$MODE" = "watch" ]; then
    echo "[watch] sudo unavailable; continuing (not required for own processes)"
  else
    echo "⚠️  sudo 授权未成功；ZCode 是你自己的进程，通常无需 root 也能限流，继续…"
  fi
fi

# ------------------------- 工具函数 -------------------------
# 列出当前所有 ZCode 进程 PID。
# 用 libproc 全量枚举（proc_listpids 列出系统全部 PID → proc_pidpath 读真实
# 可执行路径 → 白名单过滤），完全不依赖命令行匹配。原因：macOS 的 pgrep 对
# 部分进程存在"看不见"的问题（argv 被 Electron 改写或旧实例残留时
# KERN_PROCARGS 读取失败，pgrep -f 直接跳过），实测 zcode-cli、
# zcode-host-local-1、主进程等会从 pgrep 结果中消失，导致漏限流。
zcode_pids() {
  python3 -c '
import ctypes, sys
lib = ctypes.CDLL("libproc.dylib")
app_path = sys.argv[1]
N = 8192
buf = (ctypes.c_int * N)()
n = lib.proc_listpids(1, 0, buf, N)
b = ctypes.create_string_buffer(4096)
out = []
for i in range(min(n, N)):
    pid = buf[i]
    if pid <= 0:
        continue
    r = lib.proc_pidpath(pid, b, 4096)
    if r > 0:
        p = b.value.decode()
        if p.startswith(app_path + "/"):
            out.append(str(pid))
print("\n".join(out))' "$ZCODE_APP_PATH"
}

# 读取单个 PID 的真实可执行路径（读不到则输出空串）
pid_exe() {
  python3 -c 'import ctypes,sys
lib=ctypes.CDLL("libproc.dylib")
b=ctypes.create_string_buffer(4096)
n=lib.proc_pidpath(int(sys.argv[1]), b, 4096)
sys.stdout.write(b.value.decode() if n>0 else "")' "$1" 2>/dev/null
}

# 某 PID 是否已有限流器在监控。用 pgrep -x 按进程名枚举限流器 + ps 提取
# 目标 PID 比对——不依赖 pgrep -f 命令行匹配（它对部分进程不可靠）。
has_limiter() {
  local pid="$1" lp tgt
  for lp in $(pgrep -x cpulimit 2>/dev/null); do
    tgt="$(ps -o command= -p "$lp" 2>/dev/null | sed -n 's/.*-p \([0-9]*\) -l.*/\1/p')"
    [ "$tgt" = "$pid" ] && return 0
  done
  return 1
}

# 限制单个 PID。返回值：0=已限流 1=已被限流 2=进程已退出 3=限流失败
limit_pid() {
  local pid="$1"
  if ! kill -0 "$pid" 2>/dev/null; then
    return 2
  fi
  if has_limiter "$pid"; then
    return 1
  fi
  nohup "$CPULIMIT_BIN" -p "$pid" -l "$CPU_LIMIT" >/dev/null 2>&1 &
  sleep 0.5
  if has_limiter "$pid"; then
    return 0
  fi
  return 3
}

watch_log() {
  echo "[$(date '+%F %T')] $*" >> "$WATCH_LOG"
}

# ------------------------- 一次性模式 -------------------------
if [ "$MODE" = "once" ]; then
  PIDS="$(zcode_pids)"
  if [ -z "$PIDS" ]; then
    echo "❌ 未找到任何 ZCode 进程，请先启动 ZCode 再运行本脚本"
    exit 1
  fi

  echo "📋 共发现 $(echo "$PIDS" | wc -l | tr -d ' ') 个 ZCode 进程："
  for pid in $PIDS; do
    echo "   - PID $pid  $(ps -p "$pid" -o comm= 2>/dev/null)"
  done
  echo ""

  LIMITED=0
  SKIPPED=0
  for pid in $PIDS; do
    echo "🔄 正在限制 PID: $pid → ${CPU_LIMIT}%"
    limit_pid "$pid"
    case $? in
      0) echo "   ✅ 已限制 PID: $pid"; LIMITED=$((LIMITED+1));;
      1) echo "   ⏭️  PID $pid 已被 cpulimit 限流，跳过"; SKIPPED=$((SKIPPED+1));;
      2) echo "   ⏭️  PID $pid 已退出，跳过"; SKIPPED=$((SKIPPED+1));;
      3) echo "   ❌ 限制 PID $pid 失败";;
    esac
  done

  echo ""
  echo "=============================================="
  echo "✅ 已限制 ${LIMITED} 个进程（每个 ≤ ${CPU_LIMIT}% 单核 CPU）"
  if [ "$SKIPPED" -gt 0 ]; then
    echo "⏭️  跳过 ${SKIPPED} 个进程（已退出或已被限流）"
  fi
  if [ "$LIMITED" -eq 0 ] && [ "$SKIPPED" -gt 0 ]; then
    echo "ℹ️  所有 ZCode 进程此前已在限流中，无需重复操作"
  fi
  echo "=============================================="

  PIDS_CSV="$(echo "$PIDS" | paste -sd, -)"
  TOP_ARGS="$(echo "$PIDS" | sed 's/^/-pid /' | tr '\n' ' ')"
  echo ""
  echo "📊 实时监控（可直接复制执行）："
  echo "   快照一次：  top -o cpu -l 1 $TOP_ARGS"
  echo "   持续刷新：  top -o cpu $TOP_ARGS"
  echo "   或用 ps：   ps -o pid,pcpu,comm $PIDS_CSV"
  echo "   每 2 秒刷： while true; do clear; ps -o pid,pcpu,comm -p $PIDS_CSV; sleep 2; done"
  echo ""
  echo "🛑 解除限流（恢复原状）：pkill cpulimit"
  exit 0
fi

# ------------------------- watch 模式 -------------------------
echo "[watch] target=$ZCODE_APP_PATH interval=${WATCH_INTERVAL}s, will auto-limit any new process of ZCode.app"
echo "[watch] stop with: pkill -f 'limit-zcode-cpu.sh --watch' (existing limits stay)"
watch_log "=== watch start, CPU_LIMIT=${CPU_LIMIT}%, interval ${WATCH_INTERVAL}s ==="

# Ctrl-C / TERM 时提示（现有限流继续生效）
trap 'echo "[$(date "+%F %T")] watch stopped (existing limits stay)"; watch_log "watch stopped"; exit 0' INT TERM

LIMITED_TOTAL=0
ZCODE_GONE=0
while true; do
  PIDS="$(zcode_pids)"
  if [ -z "$PIDS" ]; then
    if [ "$ZCODE_GONE" -eq 0 ]; then
      echo "[$(date '+%F %T')] ZCode not running, waiting..."
      watch_log "ZCode not running, waiting"
      ZCODE_GONE=1
    fi
    sleep "$WATCH_INTERVAL"
    continue
  fi
  ZCODE_GONE=0

  # 清理失效限流器。判定"失效"必须谨慎：目标不在当前集合内时，仅当
  # ① 目标已完全不存在，或 ② 目标 PID 被系统复用给非 ZCode 程序（真实
  # 可执行路径不在 ZCode.app 内）才清理。不能只看"不在集合内"——有部分
  # 真实 ZCode 进程（zcode-cli / zcode-host-local-1 等）对 pgrep 不可见，
  # 却可能被 proc_listpids 之外的匹配方式漏掉，误杀会导致它们永久裸奔。
  for lp in $(pgrep -x cpulimit 2>/dev/null); do
    tgt="$(ps -o command= -p "$lp" 2>/dev/null | sed -n 's/.*-p \([0-9]*\) -l.*/\1/p')"
    [ -z "$tgt" ] && continue
    if echo "$PIDS" | grep -qx "$tgt"; then
      continue
    fi
    if ! ps -p "$tgt" >/dev/null 2>&1; then
      REASON="gone"
    else
      case "$(pid_exe "$tgt")" in
        "$ZCODE_APP_PATH"/*) continue ;;   # 真实 ZCode 进程，保留
        *) REASON="reused" ;;
      esac
    fi
    kill "$lp" 2>/dev/null && {
      echo "[$(date '+%F %T')] cleanup limiter $lp (target $tgt $REASON)"
      watch_log "cleanup limiter $lp (target $tgt $REASON)"
    }
  done

  for pid in $PIDS; do
    limit_pid "$pid"
    if [ $? -eq 0 ]; then
      echo "[$(date '+%F %T')] limit PID $pid -> ${CPU_LIMIT}%"
      watch_log "limit PID $pid -> ${CPU_LIMIT}%"
      LIMITED_TOTAL=$((LIMITED_TOTAL+1))
    fi
  done
  sleep "$WATCH_INTERVAL"
done
