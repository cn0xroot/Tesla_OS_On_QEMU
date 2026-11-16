#!/usr/bin/env bash
# Tesla 2026 QEMU 干净停止(sync 保留 /home cookie 后再停 QEMU)
cd "$(dirname "$0")/.."
exec ./scripts/stop_gui.sh --all "$@"
