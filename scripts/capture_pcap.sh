#!/usr/bin/env bash
# 在 QEMU 客户机内跑 tcpdump 抓包，通过 SSH 管道直接把 pcap 数据流回宿主机，
# 不落地客户机磁盘、也不需要额外端口转发。抓完后用宿主机上已有的完整版
# tshark/wireshark 分析——guest 内置的 buildroot 版 wireshark 包编译踩了三个
# 上游脚本本身的兼容性坑（详见 docs/security_analysis.md 附录），不值得为了
# tshark 一个工具在 guest 里死磕，宿主机上的版本更新、协议字典更全。
#
# 用法:
#   ./scripts/capture_pcap.sh [网卡，默认eth0] [抓包时长秒，默认30] [tcpdump过滤表达式，默认空]
#
# 示例:
#   ./scripts/capture_pcap.sh                                   # 抓 eth0 全部流量 30 秒
#   ./scripts/capture_pcap.sh eth0 60 'port 8900 or port 28496'  # 只抓关心的端口
#
# 输出:
#   /tmp/tesla_qemu/capture_<timestamp>.pcap  -- 可直接用 wireshark/tshark 打开
#
# 依赖: 客户机内 tcpdump 已存在（原厂自带，见 docs/security_analysis.md §2）

set -euo pipefail
cd "$(dirname "$0")/.."

IFACE="${1:-eth0}"
DURATION="${2:-30}"
FILTER="${3:-}"

OUTDIR="/tmp/tesla_qemu"
mkdir -p "$OUTDIR"
OUTFILE="$OUTDIR/capture_$(date +%Y%m%d_%H%M%S).pcap"

KEY="scripts/ssh_key/id_ed25519"
[ -f "$KEY" ] || { echo "缺少密钥: $KEY"; exit 1; }

echo "抓包 ${DURATION}s（网卡 $IFACE，过滤条件: ${FILTER:-无}），Ctrl+C 提前结束..."

ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 2222 \
  root@127.0.0.1 \
  "timeout $DURATION tcpdump -i $IFACE -U -w - $FILTER 2>/tmp/tcpdump_stderr.log" \
  > "$OUTFILE"

SIZE=$(stat -c%s "$OUTFILE" 2>/dev/null || echo 0)
echo "抓包完成: $OUTFILE ($SIZE 字节)"

if [ "$SIZE" -lt 100 ]; then
    echo "警告: 文件过小，可能没抓到流量或 tcpdump 报错，检查客户机内 /tmp/tcpdump_stderr.log"
    exit 1
fi

echo
echo "查看方式:"
echo "  tshark -r $OUTFILE                    # 命令行摘要"
echo "  tshark -r $OUTFILE -Y 'http'           # 按协议过滤"
echo "  wireshark $OUTFILE                     # 图形界面（需要本机有 X 显示）"
