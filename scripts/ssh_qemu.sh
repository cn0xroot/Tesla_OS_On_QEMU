#!/usr/bin/env bash
# 一键 SSH 进正在运行的 QEMU 客户机（配合 run_qemu_ui.sh / run_qemu_gdb.sh 使用）。
#
# 用法:
#   ./scripts/ssh_qemu.sh                 # 直接进交互 shell
#   ./scripts/ssh_qemu.sh "cmd ..."       # 远程执行一条命令后退出
#
# 说明:
#   密钥/端口对应 docs/workflow_report.md 第6.3节记录的 sshd 方案：
#   authorized_keys_dev 里加了这把本地生成的 ed25519 密钥，QEMU 用
#   hostfwd 把客户机 192.168.90.100:22 转发到宿主机 2222 端口。

set -euo pipefail
cd "$(dirname "$0")/.."

KEY="scripts/ssh_key/id_ed25519"
# v68 起 SSH 走独立管理网卡 eth1(hostfwd 2223)。因为 connman 会按车网拓扑重配
# eth0 → 打断 eth0 上的入站 SSH(见 workflow §20),所以把 SSH 隔离到 eth1。
# 2222 仍保留(eth0,connman 接管前可用,联网后会失效),默认用 2223 更稳。
PORT="${SSH_PORT:-2223}"

[ -f "$KEY" ] || { echo "缺少密钥: $KEY"; exit 1; }

exec ssh -i "$KEY" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o LogLevel=ERROR \
  -p "$PORT" \
  root@127.0.0.1 "$@"
