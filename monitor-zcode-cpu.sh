#!/bin/bash
# monitor-zcode-cpu.sh [秒数] — 后台监控 ZCode 各进程 CPU 占用与限流覆盖
# 默认监控 3600 秒（60 分钟），每 5 秒采样一次，结果写入 <脚本目录>/zcode-cpu-monitor.log
# 用法: bash monitor-zcode-cpu.sh 1800

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ZCODE_APP_PATH="${ZCODE_APP_PATH:-/Applications/ZCode.app}"
DURATION="${1:-3600}"
LOG="${ZCODE_MONITOR_LOG:-$SCRIPT_DIR/zcode-cpu-monitor.log}"
: > "$LOG"
echo "监控启动 $(date '+%F %T')，采样间隔 5s，预计运行 ${DURATION}s" >> "$LOG"

END=$(( $(date +%s) + DURATION ))
while [ "$(date +%s)" -lt "$END" ]; do
  TS="$(date '+%H:%M:%S')"
  PIDS="$(pgrep -f "ZCode" | grep -v "^$$\$")"
  if [ -z "$PIDS" ]; then
    echo "$TS [ZCode 未运行]" >> "$LOG"
    sleep 5
    continue
  fi
  UNLIMITED=""
  for pid in $PIDS; do
    CPU="$(ps -p "$pid" -o pcpu= 2>/dev/null | tr -d ' ')"
    if pgrep -f "cpulimit -p ${pid} " >/dev/null 2>&1; then
      ST="限"
    else
      ST="未限"
      UNLIMITED="$UNLIMITED $pid"
    fi
    echo "$TS $pid cpu=${CPU:-?} $ST" >> "$LOG"
  done
  LOAD="$(sysctl -n vm.loadavg 2>/dev/null | tr -d '{}')"
  echo "$TS 负载$LOAD 进程数$(echo "$PIDS" | wc -l | tr -d ' ') 未限流:[${UNLIMITED:-}]" >> "$LOG"
  sleep 5
done
echo "监控结束 $(date '+%F %T')" >> "$LOG"
