#!/usr/bin/env bash
# 修复"QEMU窗口点了没反应/键盘输入没反应"的问题。
#
# 根因（已用 evtest 实机验证，见 docs/security_analysis.md 附录/workflow_report.md）：
# 这不是客户机内部的 bug——客户机侧的 evdev/udev/Xorg InputClass 配置本身完全
# 正确（此前已修复过一次，见 99-touch.rules / 10-evdev.conf）。真正的问题出在
# 宿主机这一侧：GNOME Shell 的窗口切换/点击有时不会把 X server 真正的输入焦点
# （XSetInputFocus）转移到 QEMU 的 SDL 窗口上，即使任务栏/Alt-Tab 显示它已经是
# "激活"窗口——这只是 GNOME Shell 自己维护的 _NET_ACTIVE_WINDOW 提示属性，
# 和真正决定按键/点击去哪个窗口的 X 输入焦点是两回事。焦点可能仍然停留在你
# 之前操作的某个其它窗口（比如浏览器）上，QEMU 窗口因此收不到任何输入。
#
# 用法:
#   ./scripts/focus_qemu.sh
#
# 原理: 用 xdotool 直接调用 XSetInputFocus 强制把焦点按到 QEMU 窗口上，
# 绕开 GNOME Shell 那层可能失效的焦点转移逻辑。

set -euo pipefail

if ! command -v xdotool &> /dev/null; then
    echo "缺少 xdotool，请先安装: sudo apt install xdotool"
    exit 1
fi

QEMU_PID="$(pgrep -f 'qemu-system-x86_64.*Tesla on QEMU' | head -1)"
if [ -z "$QEMU_PID" ]; then
    QEMU_PID="$(pgrep -x qemu-system-x86_64 | head -1)"
fi

# 同一个 QEMU 进程有时会残留多个同名的 X 窗口（不同分辨率的旧窗口，见
# docs 里对此的记录）。挑：先看 PID 匹配，再在候选里选面积最大的那个
# （真正在用的窗口分辨率是当前客户机分辨率，通常也是几个候选里最大的）。
WID=""
BEST_AREA=0
for w in $(xdotool search --name 'Tesla on QEMU' 2>/dev/null); do
    wpid="$(xdotool getwindowpid "$w" 2>/dev/null || true)"
    if [ -n "$QEMU_PID" ] && [ "$wpid" != "$QEMU_PID" ]; then
        continue
    fi
    eval "$(xdotool getwindowgeometry --shell "$w" 2>/dev/null)"
    area=$(( WIDTH * HEIGHT ))
    if [ "$area" -gt "$BEST_AREA" ]; then
        BEST_AREA=$area
        WID=$w
    fi
done

if [ -z "$WID" ]; then
    echo "没找到 QEMU 窗口（标题包含 'Tesla on QEMU'），确认 QEMU 是否已用 run_qemu_ui.sh 启动。"
    exit 1
fi

xdotool windowactivate --sync "$WID"
xdotool windowfocus --sync "$WID"

echo "已强制把输入焦点设置到 QEMU 窗口 (id=$WID)。"
echo "现在鼠标点击/键盘输入应该能正常送达客户机了。"
echo "如果之后点到了别的窗口（比如切到浏览器看文档），再回来点QEMU窗口时"
echo "如果又失灵，重新跑一次这个脚本即可。"
