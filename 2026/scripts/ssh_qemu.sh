#!/bin/bash
# 一键 SSH 进 QEMU 里的 Tesla 2026 固件。
#
# 认证方式：guest 的 /etc/ssh/sshd_config 用的是 sshd_config_dev
# （AuthorizedKeysFile=/etc/ssh/authorized_keys_dev），里面原本只有一条
# Tesla 自己的 CA cert-authority 记录（要私钥签发证书才能用，我们没有），
# 所以之前用户自己的公钥登录会被拒（Permission denied (publickey)）。
# 这里追加了我们自己生成的一把 ed25519 直连公钥到 authorized_keys_dev
# （见 keys/qemu_ssh_key{,.pub}），已随 rootfs 打包进最新的
# extracted/rootfs_2026_current.squashfs。
#
# Stage 20.55（2026-09-15）起 guest 的 /sbin/firewall 在开机时真正加载（INPUT 默认
# DROP、其余 TCP 一律 REJECT --reject-with tcp-reset），本脚本能连上全靠
# extracted/squashfs-root-2026/sbin/firewall 里 "2026 QEMU" 段放行的
#   -A INPUT -i eth0 -s 10.0.2.2/32 -p tcp --dport 22 -j ACCEPT
# 如果某天 ssh 报 "kex_exchange_identification: Connection reset by peer"，先查这条
# 规则还在不在（iptables -S INPUT），备用通道是 scripts/ttys1_probe.py 的 ttyS1 root shell。
# 建议用法：./scripts/ssh_qemu.sh -- 'sh -s' < 本地脚本 > 输出文件（本机 hook 会拦截
# 把 ssh 输出直接接管道的写法）。
#
# 用法：./scripts/ssh_qemu.sh [额外的 ssh 参数...] [-- 远程命令...]
# 例：./scripts/ssh_qemu.sh                     # 直接进 shell
#     ./scripts/ssh_qemu.sh -- uptime           # 跑一条命令
#     SSH_PORT=2223 ./scripts/ssh_qemu.sh       # 走非默认端口

set -euo pipefail
cd "$(dirname "$0")/.."

SSH_PORT="${SSH_PORT:-2222}"
SSH_HOST="${SSH_HOST:-127.0.0.1}"
SSH_USER="${SSH_USER:-root}"
KEY="$(pwd)/keys/qemu_ssh_key"

if [ ! -f "$KEY" ]; then
    echo "找不到 $KEY，先跑一次:" >&2
    echo "  ssh-keygen -t ed25519 -N '' -f $KEY -C tesla2026-qemu-test" >&2
    echo "然后把 ${KEY}.pub 的内容加进" >&2
    echo "  extracted/squashfs-root-2026/etc/ssh/authorized_keys_dev" >&2
    echo "重新 mksquashfs 打包、重启 QEMU 才会生效。" >&2
    exit 1
fi

exec ssh \
    -i "$KEY" \
    -o IdentitiesOnly=yes \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR \
    -p "$SSH_PORT" \
    "${SSH_USER}@${SSH_HOST}" \
    "$@"
