#!/bin/bash
# verify-zcode-guard.sh [秒数] — 后台健康检查：周期验证 ZCode 限流系统结构
# 默认 900 秒（15 分钟），每 30 秒一轮，结果写入 <脚本目录>/zcode-health.log
# 用法: bash verify-zcode-guard.sh 1800
#
# 检查项：
#   覆盖率  — 每个 ZCode 进程是否都有限流器
#   重复    — 同一进程是否被多个限流器重复限制
#   残留    — 限流器目标已不存在的
#   冻结    — T(停止)状态但无限流器的进程（被限流器杀掉后卡死）
#   watcher — launchd agent 的 watch 守护是否存活
#
# 注意：进程枚举用 proc_listpids + proc_pidpath（不依赖 pgrep -f，它对部分
# 进程不可见）；限流器检测用 pgrep -x cpulimit + ps 提取目标（可靠）。

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ZCODE_APP_PATH="${ZCODE_APP_PATH:-/Applications/ZCode.app}"
DURATION="${1:-900}"
INTERVAL=30
LOG="${ZCODE_HEALTH_LOG:-$SCRIPT_DIR/zcode-health.log}"
: > "$LOG"
echo "健康检查启动 $(date '+%F %T')，每 ${INTERVAL}s 一轮，预计 $((DURATION / INTERVAL)) 轮" >> "$LOG"

enum_zcode() {
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
    if r > 0 and b.value.decode().startswith(app_path + "/"):
        out.append(str(pid))
print("\n".join(out))' "$ZCODE_APP_PATH"
}

limiter_targets() {
  local lp tgt
  for lp in $(pgrep -x cpulimit 2>/dev/null); do
    tgt="$(ps -o command= -p "$lp" 2>/dev/null | sed -n 's/.*-p \([0-9]*\) -l.*/\1/p')"
    [ -n "$tgt" ] && echo "$tgt"
  done
}

END=$(( $(date +%s) + DURATION ))
ROUND=0
while [ "$(date +%s)" -lt "$END" ]; do
  ROUND=$((ROUND + 1))
  TS="$(date '+%F %T')"
  PIDS="$(enum_zcode)"
  TGT="$(limiter_targets)"

  # 覆盖率
  TOT=0; LIM=0; MISS=""
  for p in $PIDS; do
    TOT=$((TOT + 1))
    if echo "$TGT" | grep -qx "$p"; then
      LIM=$((LIM + 1))
    else
      MISS="$MISS $p"
    fi
  done

  # 重复
  DUP="$(echo "$TGT" | sort | uniq -d | tr '\n' ' ')"

  # 残留
  STALE=""
  for t in $TGT; do
    ps -p "$t" >/dev/null 2>&1 || STALE="$STALE $t"
  done

  # 冻结
  FROZEN=""
  for p in $PIDS; do
    ST="$(ps -p "$p" -o stat= 2>/dev/null | tr -d ' ')"
    if [ "$ST" = "T" ] && ! echo "$TGT" | grep -qx "$p"; then
      FROZEN="$FROZEN $p"
    fi
  done

  # watcher 存活（用 [h] 技巧避免匹配到本脚本自身的命令行文本）
  W="$(pgrep -fl "limit-zcode-cpu.sh --watc[h]" | head -1)"
  [ -n "$W" ] && WATCHER="alive" || WATCHER="DEAD"

  STATUS="OK"
  [ -n "$MISS" ] && STATUS="PROBLEM"
  [ -n "$DUP" ] && STATUS="PROBLEM"
  [ -n "$STALE" ] && STATUS="PROBLEM"
  [ -n "$FROZEN" ] && STATUS="PROBLEM"
  [ "$WATCHER" = "DEAD" ] && STATUS="PROBLEM"

  echo "$TS [$STATUS] 进程$TOT/限流$LIM watcher=$WATCHER 缺失:[$MISS] 重复:[$DUP] 残留:[$STALE] 冻结:[$FROZEN]" >> "$LOG"
  sleep "$INTERVAL"
done
echo "健康检查结束 $(date '+%F %T')，共 ${ROUND} 轮" >> "$LOG"
