#!/usr/bin/env bash
# 关闭 launch_gui.sh / run_qemu_test.sh (TTYS1=on) 启动的 Tesla 2026 QEMU 实例。
#
# 只用 `kill <QEMU pid>` 不够干净：swtpm 是独立进程（TPM=on 时才有），QEMU 自己
# trap 了 EXIT 会尝试帮忙关 swtpm，但 TTYS1=on 的后台模式为了不误杀 guest 已经把
# 这个 trap 关掉了（见 run_qemu_test.sh 里 "trap - EXIT" 的注释），所以 swtpm 得
# 这里单独收尾；另外顺手清一下 9p 挂载相关的僵尸提示。
#
# 用法：
#   ./scripts/stop_gui.sh            # 关最近一次 launch_gui.sh/run_qemu_test.sh 启动的实例
#   ./scripts/stop_gui.sh --all      # 关掉所有匹配到的 Tesla 2026 QEMU/swtpm 进程
#   ./scripts/stop_gui.sh --quiet    # 少打印一点（launch_gui.sh 内部重启时用）

set -uo pipefail
cd "$(dirname "$0")/.."

QUIET=0
ALL=0
for a in "$@"; do
    case "$a" in
        --quiet) QUIET=1 ;;
        --all) ALL=1 ;;
    esac
done
log() { [ "$QUIET" = "1" ] || echo "$@"; }

killed_any=0

if [ "$ALL" = "1" ]; then
    PIDS="$(pgrep -f 'qemu-system-x86_64 -name Tesla 2026' 2>/dev/null || true)"
else
    LATEST_PIDS_FILE="$(ls -t logs/qemu_ttys1_*.pids 2>/dev/null | head -1)"
    if [ -n "${LATEST_PIDS_FILE:-}" ]; then
        PIDS="$(cat "$LATEST_PIDS_FILE" | tr ' ' '\n')"
    else
        PIDS="$(pgrep -f 'qemu-system-x86_64 -name Tesla 2026' 2>/dev/null || true)"
    fi
fi

# 干净关机(cookie/home 持久化关键): 停 QEMU 前先让 guest sync + 卸载 /home,
# 否则 SIGTERM 硬停会弄脏 ext4 -> 下次 check-lvm-parts e2fsck 失败 -> mke2fs 重建
# /home -> chromium cookies 全丢(见 docs/51 第10节)。可用 NO_CLEAN_SHUTDOWN=1 跳过。
if [ -n "$PIDS" ] && [ "${NO_CLEAN_SHUTDOWN:-0}" != "1" ]; then
    SSHK="keys/qemu_ssh_key"
    if [ -f "$SSHK" ] && timeout 6 ssh -i "$SSHK" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no \
         -o UserKnownHostsFile=/dev/null -o ConnectTimeout=4 -p 2222 root@127.0.0.1 'echo ok' 2>/dev/null | grep -q ok; then
        log "干净关机: guest sync(让 ext4 journal 一致, 下次 e2fsck 恢复而非重建)..."
        timeout 12 ssh -i "$SSHK" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no \
          -o UserKnownHostsFile=/dev/null -o ConnectTimeout=4 -p 2222 root@127.0.0.1 \
          'sync; sync; sync' 2>/dev/null || true
        log "已 sync; SIGTERM 停 QEMU"
    fi
fi

for pid in $PIDS; do
    [ -z "$pid" ] && continue
    if kill -0 "$pid" 2>/dev/null; then
        log "关闭 PID $pid ($(ps -o comm= -p "$pid" 2>/dev/null))..."
        kill "$pid" 2>/dev/null
        killed_any=1
    fi
done

if [ "$killed_any" = "1" ]; then
    for i in $(seq 1 10); do
        alive=0
        for pid in $PIDS; do kill -0 "$pid" 2>/dev/null && alive=1; done
        [ "$alive" = "0" ] && break
        sleep 1
    done
    for pid in $PIDS; do
        kill -0 "$pid" 2>/dev/null && { log "PID $pid 还没退，SIGKILL"; kill -9 "$pid" 2>/dev/null; }
    done
    log "已关闭。"
else
    log "没找到正在运行的 Tesla 2026 QEMU 实例。"
fi

# 兜底：孤儿 swtpm（正常情况下已经随上面的实例列表一起被杀掉了）
if [ "$ALL" = "1" ]; then
    ORPHAN_SWTPM="$(pgrep -f 'swtpm socket.*extracted/swtpm_state' 2>/dev/null || true)"
    for pid in $ORPHAN_SWTPM; do
        log "关闭孤儿 swtpm PID $pid..."
        kill "$pid" 2>/dev/null
    done
fi
