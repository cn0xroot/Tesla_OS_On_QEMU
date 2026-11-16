#!/usr/bin/env bash
# 2026.26.6.5 固件的无头(headless)首轮启动测试脚本。
#
# 复用上级 2024 项目已经跑通的内核 + custom_init initrd（详见
# ../docs/00_overview.md 第3节），只替换 rootfs 为本目录下的
# 2026.26.6.5.ice（裸 squashfs，直接满足 custom_init 的 /dev/vda 挂载条件，
# 不需要任何分区提取/dm-linear重建）。
#
# 使用独立的 overlay_2026.qcow2（backing 到只读的 tesla_ROM1_*.bin），
# 不触碰 2024 项目已经跑通的 extracted/overlay.qcow2，避免交叉污染。
#
# TPM=on 时会额外起一个 swtpm 软件 TPM 进程，挂给客户机（tpm-crb，TPM2.0），
# 用于验证 Stage 01 里"check-lvm-parts 处理 LUKS 卷时卡死，疑似因为缺 TPM
# 导致固件把自己误判为已熔断量产芯片"这一假设。见 ../docs/00_overview.md。
#
# 用法:
#   ./scripts/run_qemu_test.sh [duration_seconds]
#   TPM=on ./scripts/run_qemu_test.sh 180
#
# 输出:
#   logs/serial_<时间戳>.log   -- 串口(ttyS0)完整日志
#   logs/qemu_stdout_<时间戳>.log
#   TPM=on 时另有 logs/swtpm_<时间戳>.log

set -euo pipefail
cd "$(dirname "$0")/.."   # -> <repo-root>/2026

PARENT="$(cd .. && pwd)"
# 默认用加了 9p 文件系统支持的版本（Stage 12，见 docs/00_overview.md），
# 其它方面和原始 bzImage_redirect_smp8 完全一样（同一份 .config 增量改的）。
# 配合 VIRTFS=on 用，能在 guest 里 mount -t 9p 直接访问宿主机目录，不用再
# 靠 ttyS1 base64 传文件。
BZIMAGE="${KERNEL:-$PARENT/extracted/ias_a/bzImage_redirect_smp8_9p}"
# 注意（见 docs/00_overview.md Stage 06）：这颗内核只编译了 CONFIG_RD_XZ，
# 没有 CONFIG_RD_GZIP —— 外部 -initrd 必须是 .xz，gzip 包传了也会被静默
# 丢弃、无声无息地回退到内核内置的 initramfs（bzImage 自带
# CONFIG_INITRAMFS_SOURCE，和外部这份关系不大，只有当你真的要改
# custom_init.c 本身时才会露馅）。默认指向已经修好 ttyS1 死循环 bug 的
# extracted/initrd_ttys1fix.cpio.xz；如需要 2024 项目原版逻辑可以自己传
# INITRD= 覆盖，但记得那份是 .gz，实测外部加载不会生效。
INITRD="${INITRD:-extracted/initrd_ttys1fix.cpio.xz}"
OVERLAY="extracted/overlay_2026.qcow2"
# 默认用打过全部已知补丁（AppArmor清空/quota修复/宿主机Mesa补全，见
# docs/00_overview.md Stage 05/07/08/10、scripts/patch_rootfs.sh）的版本，
# 不是原始 2026.26.6.5.ice。想测试原始未打补丁固件，显式传 ROOTFS= 覆盖。
ROOTFS="${ROOTFS:-extracted/rootfs_2026_current.squashfs}"
DURATION="${1:-180}"
SMP="${SMP:-8}"
MEM="${MEM:-16384}"  # MiB；默认 16G（2026-10-01 起，此前是硬编码 8192）
TPM="${TPM:-off}"
APPARMOR="${APPARMOR:-1}"   # 设 APPARMOR=0 验证 Stage 03 的"AppArmor内核特性不匹配"假设
TTYS1="${TTYS1:-off}"       # 设 TTYS1=on 额外挂一路 ttyS1 unix socket（配合 scripts/ttys1_probe.py
                             # 现场跑命令诊断），此时脚本会把 qemu 放后台跑、立刻返回，不等 timeout
GPU="${GPU:-vga}"            # vga(默认，纯2D，稳定) | vga-gl(virtio-vga-gl+egl-headless，
                             # 真GPU加速，但实测会和本机 virglrenderer 撞出
                             # "eglMakeCurrent failed: EGL_BAD_ACCESS" 导致 QEMU 自己
                             # core dump，见 docs/00_overview.md Stage 10 末尾，仅在
                             # 需要验证 virgl 硬件加速路径时短时间使用，不建议长跑)
QMP="${QMP:-off}"            # 设 QMP=on 开一个 QMP socket（配合 python3 -c "...screendump..."
                             # 截图，见 docs Stage 10 的截图片段）
VIRTFS="${VIRTFS:-off}"      # 设 VIRTFS=on 挂载 extracted/hostshare/ 到 guest 的 /mnt/host
                             # （9p，mount_tag=hostshare），配合 Stage 12 编的
                             # extracted/hostshare/gdbtool/ 直接在 guest 里跑 gdb。
                             # guest 内挂载命令：
                             #   mount -t 9p -o trans=virtio,version=9p2000.L hostshare /mnt/host
GUI="${GUI:-off}"            # 设 GUI=on 用真实窗口（GTK）显示，而不是 headless
AUDIO="${AUDIO:-on}"         # 设 AUDIO=off 强制静音（-audiodev none），
                             # 默认自动探测宿主机 pulse socket 接真实声音

TS="$(date +%Y%m%d_%H%M%S)"
mkdir -p logs
SERIAL_LOG="logs/serial_${TS}.log"
STDOUT_LOG="logs/qemu_stdout_${TS}.log"

for f in "$BZIMAGE" "$INITRD" "$OVERLAY" "$ROOTFS"; do
    [ -f "$f" ] || { echo "缺少文件: $f"; exit 1; }
done

echo "内核:  $BZIMAGE"
echo "CPU: ${SMP} 核  内存: ${MEM}MiB"
echo "initrd: $INITRD"
echo "overlay: $OVERLAY (独立于2024项目的overlay)"
echo "rootfs: $ROOTFS"
echo "串口日志: $SERIAL_LOG"

TPM_ARGS=()
SWTPM_PID=""
if [ "$TPM" = "on" ]; then
    # 固定状态目录（不按时间戳），让 TPM 密封的 LUKS 密钥跨多次开机持久化，
    # 复现真机"只有第一次开机慢、之后都快"的行为，而不是每次都当全新设备。
    TPM_DIR="${TPM_STATE_DIR:-extracted/swtpm_state}"
    mkdir -p "$TPM_DIR"
    SWTPM_LOG="logs/swtpm_${TS}.log"
    SWTPM_SOCK="$TPM_DIR/swtpm-sock"
    swtpm socket --tpmstate dir="$TPM_DIR" \
        --ctrl type=unixio,path="$SWTPM_SOCK" \
        --tpm2 --log file="$SWTPM_LOG",level=5 &
    SWTPM_PID=$!
    # 等 swtpm 把控制 socket 建出来再往下走
    for i in $(seq 1 50); do [ -S "$SWTPM_SOCK" ] && break; sleep 0.1; done
    [ -S "$SWTPM_SOCK" ] || { echo "swtpm 控制 socket 未建立: $SWTPM_SOCK"; kill "$SWTPM_PID" 2>/dev/null || true; exit 1; }
    TPM_ARGS=(-chardev "socket,id=chrtpm,path=$SWTPM_SOCK" -tpmdev emulator,id=tpm0,chardev=chrtpm -device tpm-crb,tpmdev=tpm0)
    echo "TPM: 已挂软件 TPM (swtpm pid=$SWTPM_PID, 状态目录=$TPM_DIR, 日志=$SWTPM_LOG)"
    trap 'kill "$SWTPM_PID" 2>/dev/null || true' EXIT
else
    echo "TPM: 未挂（TPM=on 开启）"
fi

TTYS1_ARGS=()
if [ "$TTYS1" = "on" ]; then
    TTYS1_SOCK="logs/ttys1_${TS}.sock"
    TTYS1_ARGS=(-chardev "socket,id=ttys1,path=$TTYS1_SOCK,server=on,wait=off" -serial chardev:ttys1)
    echo "ttyS1: $TTYS1_SOCK (用 scripts/ttys1_probe.py 连接)"
fi

# virtio-vga 的 xres/yres 默认是 1280x800（QEMU 自己的默认值，与 Tesla
# 硬件无关），Xorg 没有强制 modeline，靠 EDID 自动选取该默认分辨率。但
# QtCar 的界面布局是按真机原生 1920x1200 设计的（xwininfo 里
# center-splash 窗口固定 --geometry 1920x1200，UI 控件坐标也按此换算），
# 停在 1280x800 会导致右侧内容被裁切（2026-09-12 用户反馈"GUI 分辨率
# 不对"实测复现：Settings 面板、dock 图标在 x=1280 处被硬切）。
# 用 RES=WxH 覆盖，默认已改成 1920x1200。
RES="${RES:-1920x1200}"
RES_X="${RES%x*}"
RES_Y="${RES#*x}"
# 2026-09-30（docs/50 第6节）：egl-headless 默认走 QEMU/virglrenderer 自己选的
# EGL 设备，在本机（NVIDIA + GTK 后端）挂 gtk,gl=on 时会在 eglMakeCurrent 撞
# EGL_BAD_ACCESS/BAD_MATCH 崩溃（docs/50 第4节）。显式传 rendernode 直连
# /dev/dri/renderD128（NVIDIA 渲染节点），绕开宿主机 GTK 的 EGL/X11 协商路径，
# 代价是没有可见窗口（egl-headless 本身不产生宿主机窗口），需要从 guest 内部
# 验证画面而非宿主机截图。设 RENDERNODE= 覆盖（留空则不传，退回默认协商）。
RENDERNODE="${RENDERNODE:-/dev/dri/renderD128}"
EGL_HEADLESS_ARG="egl-headless"
[ -n "$RENDERNODE" ] && EGL_HEADLESS_ARG="egl-headless,rendernode=$RENDERNODE"
if [ "$GPU" = "vga-gl" ]; then
    # virtio-vga-gl 没有 xres/yres 属性（-device virtio-vga-gl,help 确认），
    # 分辨率由 gl 路径的 EDID/协商决定，这里不传。
    GPU_ARGS=(-device virtio-vga-gl -display "$EGL_HEADLESS_ARG")
elif [ "$GPU" = "gpu-gl-pci" ]; then
    # 2026-09-29：用户要求"显卡换成 github 项目的"——denysvitali/tesla-qemu
    # 的 qemu/start.sh 用的是纯 PCI 的 virtio-gpu-gl-pci（配 -vga none），
    # 不是我们之前试过的 virtio-vga-gl（VGA 兼容变体）。14.50.1 节
    # virtio-vga-gl + 自己内核 卡死过；这次换成对方项目里实测能正常协商出
    # virgl（在 Alpine 内核下已验证）的这个具体设备型号，继续用自己编译
    # 的内核，看是不是设备型号本身的差异导致的卡死。
    GPU_ARGS=(-vga none -device "virtio-gpu-gl-pci,edid=on,xres=$RES_X,yres=$RES_Y" -display egl-headless)
else
    GPU_ARGS=(-device "virtio-vga,xres=$RES_X,yres=$RES_Y" -display none)
fi
if [ "$GUI" = "on" ]; then
    # 用真实窗口显示，接管上面 GPU_ARGS 里的 -display，方便直接在宿主机
    # 桌面（本机是 :1，跑着 TigerVNC，用户可以远程直接看/点）里实时看
    # 画面、甚至直接用宿主机鼠标点击（走 QEMU 窗口自己的输入注入，不需要
    # 再经过 QMP input-send-event）。
    # 注意：默认用 SDL，不用 GTK——GTK 下 virtio-vga 以前会协商成
    # 640x480（QtCar 按 1280x800 渲染，只显示左上角一小块），SDL 才会
    # 正确协商到 1280x800。这是 2024 项目 docs/workflow_report.md
    # Stage 17.3 踩过、本项目 2026-09-12 也实测复现过一次的坑（当时
    # 临时用 xrandr 手动纠正，现在直接用 sdl 从根上避免）。
    # 2026-09-13：怀疑 SDL 窗口的鼠标抓取/焦点在宿主机 X11 合成点击下
    # 偶尔失效，用 GUI_BACKEND=gtk 可以临时切 GTK 测试对比（当年测试
    # GTK 640x480 的坑是在没有显式传 xres/yres 的年代，现在已经显式给
    # virtio-vga 传了 xres=1920,yres=1200，实测一次看这个坑是否还在）。
    # 2024 项目 workflow_report.md bug #43 记录的最终根治方案：GTK 窗口
    # 点击对焦可靠（GNOME/mutter 下 SDL 窗口拿不到真正 XSetInputFocus，
    # GTK 原生窗口没有这个问题），关键是要带 `zoom-to-fit=off`（不加这个
    # 会撞回 Stage 17.3 的 640x480 协商坑）。
    # 2026-09-13：默认改成 gtk——2024 项目 workflow_report.md bug #43 的
    # 最终根治方案（GNOME/mutter 下 SDL 窗口拿不到真正 XSetInputFocus，
    # 点击经常"点了没反应"；GTK 原生窗口点击对焦可靠）。配合
    # etc/sv/qtcar/run 里新加的开机自动 xrandr 到 1920x1200，解决了
    # GTK 本身协商不到位的问题。设 GUI_BACKEND=sdl 可以切回旧行为。
    GUI_BACKEND="${GUI_BACKEND:-gtk}"
    if [ "$GUI_BACKEND" = "gtk" ]; then
        DISPLAY_ARG="gtk,zoom-to-fit=off,show-cursor=on"
    else
        DISPLAY_ARG="sdl,show-cursor=on"
    fi
    # GPU=vga-gl 时 egl-headless 天然带 GL 上下文，不需要额外开关；但换成
    # gtk/sdl 真实窗口后 GL 默认是关的，必须显式加 gl=on，否则
    # virtio-vga-gl 设备挂了也是白挂——guest 侧协商不到 GL，退化成纯
    # 2D，等于没测。2026-09-28 验证 3D/virgl 路线时发现这个缺口。
    { [ "$GPU" = "vga-gl" ] || [ "$GPU" = "gpu-gl-pci" ]; } && DISPLAY_ARG="${DISPLAY_ARG},gl=on"
    for i in "${!GPU_ARGS[@]}"; do
        [ "${GPU_ARGS[$i]}" = "-display" ] && GPU_ARGS[$((i+1))]="$DISPLAY_ARG"
    done
    echo "GUI: 真实窗口模式，SDL 后端（DISPLAY=${DISPLAY:-:1}）"
fi

QMP_ARGS=()
if [ "$QMP" = "on" ]; then
    QMP_SOCK="${QMP_SOCK:-/tmp/tesla2026_qmp_${TS}.sock}"
    QMP_ARGS=(-qmp "unix:$QMP_SOCK,server,nowait")
    echo "QMP: $QMP_SOCK"
fi

VIRTFS_ARGS=()
if [ "$VIRTFS" = "on" ]; then
    mkdir -p extracted/hostshare
    VIRTFS_ARGS=(-virtfs "local,path=extracted/hostshare,mount_tag=hostshare,security_model=none,id=hostshare0")
    echo "virtfs(9p): extracted/hostshare -> guest /mnt/host (mount_tag=hostshare)"
fi

# 音频：自动探测宿主机 PipeWire/PulseAudio 的 pulse socket（参考 2024
# 项目 workflow_report.md Stage 22.4），找到就用 -audiodev pa 接到宿主
# 机喇叭，找不到就退回 none（guest 内核已经内置 AC97 驱动，见
# docs/00_overview.md Stage 20，没有真实音频输出也不影响其它功能）。
AUDIO_ARGS=(-audiodev none,id=snd0)
if [ "$AUDIO" != "off" ]; then
    for sock in /run/user/*/pulse/native; do
        if [ -S "$sock" ]; then
            AUDIO_ARGS=(-audiodev "pa,id=snd0,server=unix:$sock")
            echo "audio: 接到宿主机 pulse socket $sock"
            break
        fi
    done
    [ "${AUDIO_ARGS[0]}" = "-audiodev" ] && [ "${AUDIO_ARGS[1]#pa,}" = "${AUDIO_ARGS[1]}" ] && \
        echo "audio: 未找到宿主机 pulse socket，退回 none（guest无真实声音输出）"
fi

# Stage 20.62（2026-09-15）：宿主机 PipeWire 的 module-stream-restore 按应用名记住了
# "Tesla 2026 on QEMU (test)" 这条流的状态，一旦被记成 Mute: yes / 0%，之后每次启动的
# QEMU 音频流都是静音的（guest 里 AC97 已在播、宿主机却无声）。QEMU 起来后在后台
# 找到这条 sink-input，强制取消静音并置 100%，最多等 120 s。
# 2026-09-15 深夜追加：QEMU 在客机音频流开/关时会重建这条 pa 流（sink-input id 变化），
# PipeWire 每次都按记忆重新把它静音，所以不能只在启动时解一次——改成 QEMU 存活期间
# 每 2 s 巡检一次，发现 Mute: yes 就取消静音并置 100%。
unmute_qemu_stream() {
    local sock="$1" id
    while true; do
        PULSE_SERVER="unix:$sock" pactl list sink-inputs 2>/dev/null | awk '
            /^Sink Input #/ {id=substr($3,2)}
            /Mute: yes/ {m[id]=1}
            /application.name = "Tesla 2026 on QEMU/ {if (m[id]) print id}' | while read -r id; do
            PULSE_SERVER="unix:$sock" pactl set-sink-input-mute "$id" 0 2>/dev/null
            PULSE_SERVER="unix:$sock" pactl set-sink-input-volume "$id" 100% 2>/dev/null
            echo "audio: 宿主机 sink-input #$id (QEMU) 已取消静音并置 100%"
        done
        pgrep -f 'qemu-system-x86_64 -name Tesla 2026' >/dev/null || break
        sleep 2
    done
}
if [ "${AUDIO_ARGS[1]#pa,}" != "${AUDIO_ARGS[1]}" ] && command -v pactl >/dev/null 2>&1; then
    unmute_qemu_stream "${AUDIO_ARGS[1]#*server=unix:}" &
fi

echo "启动中（最长 ${DURATION}s，headless）..."

# Stage 20.65（2026-09-25）：-cpu host 在这台 Ryzen 9950X 宿主机上把 AVX-512
# 全家桶（含 avx512-vp2intersect/avx512-bf16 这类 Tesla 目标芯片不可能有的新
# 扩展）透传进 guest。glibc 2.41 的 ifunc resolver 对这批从未在真机上出现过的
# CPUID 组合选错了实现，命中的间接跳转落在 libc.so.6 的 .gnu.hash/.dynsym 只读
# 数据段（file offset 0xf2b，readelf -lW 核实该段 R、不带 X），造成
# "traps: minijail0[PID] general protection ip:...f2b... in libc.so.6" 崩溃循环
# （之前 docs/00_overview.md 20.55.6 误判成 abort() 的 hlt，docs/45 已发现地址落
# 在不可执行段但没找到根因）。chromium/chromium-app/chromium-adapter/
# input-to-virtual 这类大量触发 glibc ifunc 分发的动态 PIE 二进制每次启动稳定
# 命中，车机浏览器因此永远进不了 UI（minijail0 在 execve 完成前就崩，comm 还
# 显示 minijail0）；rgeod 等静态/简单二进制走不到这条 ifunc 路径所以没事。
# 修法（第一版，2026-09-25）：从 -cpu host 里摘掉这批 Tesla 真机 CPU 不可能
# 具备的 AVX-512 扩展与 AMX，逼 ifunc 落回真机也会走的 AVX2/SSE 实现。详见
# docs/47。
#
# 2026-09-28 追加发现（docs/49 14.19）：CPU_STRIP_FLAGS 只覆盖了 chromium
# 系列当时命中的那一条 ifunc 分发路径——qtcar-bluetooth 等另一批 qtcar-family
# 二进制走的是不同的 ifunc 符号（同样落在 libc.so.6 的 .dynsym 数据段，
# file offset 0xf2b，readelf -SW 核实该段只有 A 没有 X），说明问题根源不是
# "AVX-512 指令不支持"本身，而是 -cpu host 透传这台 Ryzen 9950X（Zen5）
# 主机独有、真机/glibc ifunc resolver 从未见过的 CPUID 位组合，resolver
# 算错索引、跳进了符号表数据段——每多发现一个新二进制命中不同的 ifunc
# 符号，就要再摘一批新标志位，属于打地鼠、摘不完。彻底修法：不再用
# `-cpu host` 透传这台主机的具体特性位，改用 QEMU 内置的具名、固定、经过
# glibc/ifunc 广泛测试的 CPU 型号（Skylake-Client-v4，Core Processor 级别，
# 比服务器 Xeon 型号更接近 Tesla 真机的低功耗/客户端定位），从根上避免
# "本机独有的新 CPUID 组合"这个问题类别，而不是逐个二进制排查、逐个标志位
# 裁剪。
CPU_MODEL="${CPU_MODEL:-Skylake-Client-v4}"

QEMU_CMD=(qemu-system-x86_64 \
# Stage 20.55（2026-09-15）：-cpu 加 migratable=off、内核参数加 tsc=reliable。
# 原因：guest 内核 4.14 启动时做跨 CPU 的 TSC 同步自检，在 KVM 上被误判为
# "Marking TSC unstable due to TSCs unsynchronized"，虽然 -append 写了
# clocksource=tsc 也照样退到 hpet（available_clocksource 里没有 kvm-clock，
# 这颗 Tesla 内核没编 KVM guest 支持）。这个内核在 hpet 上 clock_gettime 走不了
# vDSO，每次调用都真的进内核，撞上 Tesla 按真机（TSC 稳定、vDSO 永不进内核）
# 写的 kafel seccomp 策略——QtCarDvServer.kafel 等 78/94 份策略没放行
# clock_gettime，DEFAULT ERRNO_LOG(13) 让 NavServer/CenterDisplay/Power/
# TelemetryService 等线程的 clock_gettime(CLOCK_MONOTONIC) 直接拿到 EACCES
# （dmesg "seccomp: errno: ... syscall=228 arg0=1"，一轮 500s 上千条）。
# 宿主机（Ryzen 9950X）TSC 是 constant/nonstop 且自己就在用 tsc 时钟源，
# tsc=reliable 跳过那个误判的自检是安全的；migratable=off 让 guest 也能看到
# invtsc（constant_tsc/nonstop_tsc）标志，避免内核之后又因 idle 把 TSC 标为不稳。
  # kernel-irqchip=on：q35 默认是 kernel-irqchip=split，2026-09-28 用 GDB
  # attach 客户机（target remote :1234 接自编译内核的 vmlinux 符号）实测抓到
  # sdhci_irq() 在 split 模式下卡死出不来（overlay 走的 sdhci-pci+sd-card，
  # 每次开机都会用到）——电平触发中断清除后 QEMU 没有正确回落，导致 IRQ 立刻
  # 重新触发，guest 侧看起来就是"其中一颗 vCPU 100% 占用、永远卡在
  # Booting from ROM之后没有任何进一步输出"（历史上被误判过好几次：fw_cfg
  # DMA、custom QEMU 编译方式、linuxboot_dma.bin 缺失，见 docs/49 14.9）。
  # 换成 kernel-irqchip=on（全内核态 irqchip）后同一份完整环境（overlay+
  # rootfs+TPM）实测不再卡死，vCPU 正常在不同函数间推进。
  -name "Tesla 2026 on QEMU (test)" -M q35,kernel-irqchip=on -cpu "${CPU_MODEL}" -enable-kvm -m "$MEM" -smp "$SMP" \
  -kernel "$BZIMAGE" \
  -initrd "$INITRD" \
  -append "console=tty0 console=ttyS0,115200n8 loglevel=8 ignore_loglevel clocksource=tsc tsc=reliable panic=1 $([ "$APPARMOR" = "1" ] && echo "security=apparmor apparmor=1" || echo "apparmor=0") intel_xhci_usb_role_switch.default_role=1 modprobe.blacklist=dwc3 rng_core.default_quality=1000" \
  -device sdhci-pci -device sd-card,drive=mmc0 \
  -drive if=none,id=mmc0,format=qcow2,file="$OVERLAY" \
  -drive if=virtio,file="$ROOTFS",format=raw,readonly=on \
  "${GPU_ARGS[@]}" \
  -device qemu-xhci -device usb-kbd -device usb-tablet \
  -netdev user,id=net0,hostfwd=tcp::2222-10.0.2.15:22 \
  -device igb,netdev=net0 \
  "${AUDIO_ARGS[@]}" -device AC97,audiodev=snd0 \
  "${TPM_ARGS[@]}" "${QMP_ARGS[@]}" "${VIRTFS_ARGS[@]}" \
  -serial file:"$SERIAL_LOG" "${TTYS1_ARGS[@]}" -no-reboot)
  # 注意：-serial 出现的先后顺序决定 ttyS0/ttyS1 映射——上面这行必须是
  # "file:$SERIAL_LOG 在前、chardev:ttys1 在后"，踩过一次坑（ttyS0/ttyS1
  # 挂反，串口日志文件里意外收到了 shell 内容，socket 那头全是内核
  # dmesg），见 docs/00_overview.md Stage 07。

# 2026-09-28（docs/49 14.28 后续）：可选 TRACE 环境变量，追加 QEMU 内置
# -trace 事件（逗号分隔多个事件名），配合长时间运行观察 virtio_gpu 命令
# 计数是否随时间推移（用于判断"彻底卡死"还是"极慢但仍在推进"）。
# 2026-09-30（docs/50 第6节续）：egl-headless 本身不产生任何宿主机窗口，
# 没法用 xdotool/import 肉眼验证。配 -vnc 给一个真正的显示协议查看
# egl-headless+rendernode 路径下 virtio-gpu-gl 的实际 scanout 内容——理论上
# VNC 走的是 QEMU 自己读 framebuffer/scanout 再编码，不依赖宿主机 GTK 的
# EGL/X11 协商，应该能避开之前 gtk,gl=on 撞的 eglMakeCurrent 崩溃。
# 设 VNC=:N（QEMU vnc display号，:1 对应 tcp 5901）。
if [ -n "${VNC:-}" ]; then
    QEMU_CMD+=(-vnc "$VNC")
    echo "VNC: $VNC (用任意VNC客户端连 127.0.0.1:$((5900 + ${VNC#:})))"
fi

if [ -n "${TRACE:-}" ]; then
    TRACE_LOG="logs/trace_${TS}.log"
    IFS=',' read -ra _TRACE_EVENTS <<< "$TRACE"
    for _ev in "${_TRACE_EVENTS[@]}"; do
        QEMU_CMD+=(-trace "${_ev},file=${TRACE_LOG}")
    done
    echo "trace: $TRACE -> $TRACE_LOG"
fi

if [ "$TTYS1" = "on" ]; then
    # 后台跑，立刻返回，调用方自己用 ttys1_probe.py 连接、自己决定何时收尾。
    trap - EXIT   # 不要在脚本退出时顺手杀掉 swtpm，guest 还要接着用
    nohup timeout "$DURATION" "${QEMU_CMD[@]}" > "$STDOUT_LOG" 2>&1 &
    echo "QEMU 已在后台启动，PID=$!，swtpm PID=$SWTPM_PID"
    echo "$! $SWTPM_PID" > logs/qemu_ttys1_${TS}.pids
else
    timeout "$DURATION" "${QEMU_CMD[@]}" > "$STDOUT_LOG" 2>&1 || true
    echo "结束（超时被杀属正常）。"
    echo "查看日志: less $SERIAL_LOG"
fi
