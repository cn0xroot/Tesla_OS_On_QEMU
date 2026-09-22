#!/bin/sh
# apply_network_fix.sh —— 在已经启动的 QEMU 客户机里，复现 v68"双网卡 +
# connman 静态 IP"网络修复（docs/workflow_report.md Stage 20.3）。
#
# 跑在客户机内部（本脚本设计为通过 SSH 传进去执行，见
# `tesla_fw.py patch network-fix`），不是修改 rootfs 文件。
#
# 诚实说明来源可信度（避免冒充没有的东西）：
#   - connmanctl 那几行是 docs/workflow_report.md §20.3 原文逐字记录的
#     真实命令，可信度高。
#   - eth1 静态 IP 那部分，文档只记录了结果("eth1=10.0.3.15 开机配"，
#     见 §20.7)，没有留下 /etc/runit/1 的逐字原始内容——这里用标准
#     ip 命令做等效重建，效果一致(eth1 拿到 10.0.3.15/24 且不受
#     connman 影响)，但不是"复原原始文件"。
#   - 本脚本只对当前这次运行的客户机生效，重启后失效(因为改的是运行时
#     状态，不是 /etc/runit/1 本身)。想要开机自动生效，需要你自己把
#     等效逻辑写进 rootfs 里的 /etc/runit/1，再用
#     `tesla_fw.py patch repack` 重新打包。
#
# 前提：QEMU 命令行里必须已经有第二块网卡 eth1（run_qemu_ui.sh /
# run_v62_glamor.sh 默认已经带了；纯 run_qemu.sh headless 模式没有，
# 用这个脚本前先确认 `ip link show eth1` 存在）。

set -e

if ! ip link show eth1 >/dev/null 2>&1; then
    echo "!! 没有找到 eth1 设备。这个修复需要 QEMU 命令行带第二块网卡" >&2
    echo "   （run_qemu_ui.sh / run_v62_glamor.sh 默认已经带了，纯" >&2
    echo "   run_qemu.sh headless 模式没有）。中止。" >&2
    exit 1
fi

echo "== 等待 connman 的 Wired 服务出现 =="
SVC=""
for i in $(seq 1 30); do
    SVC=$(connmanctl services 2>/dev/null | awk '/Wired/{print $NF; exit}')
    [ -n "$SVC" ] && break
    sleep 1
done
if [ -z "$SVC" ]; then
    echo "!! 30秒内没等到 connman 的 Wired 服务，connman 是不是没在跑？" >&2
    echo "   （检查: sv status /etc/sv/connman）" >&2
    exit 1
fi
echo "   服务: $SVC"

echo "== 给 eth0 配静态 IP（docs/workflow_report.md §20.3 原文命令）=="
connmanctl config "$SVC" --ipv4 manual 10.0.2.15 255.255.255.0 10.0.2.2
connmanctl config "$SVC" --nameservers 10.0.2.3
connmanctl connect "$SVC"

echo "== 给 eth1 配静态 IP（等效重建，非原始文件内容，见脚本头部说明）=="
ip addr add 10.0.3.15/24 dev eth1 2>/dev/null || true
ip link set eth1 up

if [ -x /etc/sv/connman/down ] || [ -f /etc/sv/connman/down ]; then
    echo "== 发现 /etc/sv/connman/down，按文档描述这个钩子会在服务重启时" \
         "撤销静态配置，先移除掉 =="
    rm -f /etc/sv/connman/down
fi

echo ""
echo "== 完成，核对结果 =="
connmanctl services | grep -i wired || true
ip -4 addr show eth1 | grep inet || true
echo ""
echo "预期: eth0 State=ready / IPv4=manual 10.0.2.15；eth1 带上 10.0.3.15/24。"
echo "SSH 建议走 eth1（tesla_fw.py ssh 默认端口 2223），不受这次 eth0 重新" \
     "配置影响。"
