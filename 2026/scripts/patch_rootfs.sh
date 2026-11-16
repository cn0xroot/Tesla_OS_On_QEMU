#!/usr/bin/env bash
# 把 2026.26.6.5.ice 解包后的目录（extracted/squashfs-root-2026/）打上本项目
# 目前为止踩出来的全部修复补丁，再重新 mksquashfs 打包。
#
# 幂等：可以在同一份已解包目录上重复运行（cp -a 覆盖、rm -f 清空都是
# 幂等操作），方便下次重新整理/换一批文件时复用。
#
# 背景 & 每一处补丁对应的具体故障，见 docs/00_overview.md：
#   Stage 05/07 — AppArmor 策略是针对另一内核 ABI 预编译的二进制，
#                 清空 /etc/apparmor.compiled/ 让它变成全局 unconfined。
#   Stage 08    — /home 因 ext4 quota 特性位内核不支持而拒绝挂载，
#                 patch sbin/check-lvm-parts 不再给 home/gamesusr 开 quota。
#   Stage 10    — QtCar（Qt4 QGLWidget，要 EGL ES2/window surface）在原始
#                 rootfs 里找不到任何可用的软件/虚拟 GPU 渲染驱动
#                 （Tesla 自己的 Mesa 25.0.7 是只为真机 Intel 硬件精简过的
#                 构建，没编译 virtio_gpu/llvmpipe 支持）。用宿主机自己
#                 安装的、版本对应的 Mesa 25.2.8 完整用户态库（含
#                 libgallium megadriver + 全部 dri/gbm 插件 + 完整依赖链
#                 + GLVND vendor 配置）整体替换/补全，X11 EGL 平台验证
#                 可以正常初始化、拿到真实 GPU（virgl）或软件（llvmpipe）
#                 渲染上下文。
#   Stage 11    — 排查 QtCar 仍在崩溃的过程中，确认宿主机这份 Mesa 25.2.8
#                 也没有编译 virtio_gpu/virgl gallium 驱动（MESA_LOADER_
#                 DRIVER_OVERRIDE=virtio_gpu 强制指定依然报 "driver
#                 missing"），这是本项目目前唯一没找到解法的已知缺口，
#                 意味着 X11 平台的 EGL 目前只能退化到 llvmpipe 纯软件
#                 渲染。顺带发现并修复一个独立问题：VA-API GStreamer
#                 插件在开 virtio-vga-gl/virgl 时会把宿主机 QEMU 进程
#                 crash 掉，见下面单独的 rm。QtCar 本体为什么连 llvmpipe
#                 路径的 eglInitialize 都失败（而同样环境下 eglinfo 这个
#                 工具明明能成功）目前还没有定论，已经排除了 EGL config
#                 属性、eglGetDisplay/eglGetPlatformDisplay 入口选择、
#                 EGL platform 类型（X11/Surfaceless/GBM 都试过）、
#                 minijail/seccomp 沙箱拦截、RLIMIT_MEMLOCK 这几个方向，
#                 详见 docs/00_overview.md Stage 10~11 的完整排查记录，
#                 这个脚本目前不解决这最后一步。
#   Stage 20.x  — 之后的补丁不再由本脚本"施加"，而是直接改在解包目录
#                 extracted/squashfs-root-2026/ 里、随本脚本一起被打进镜像。
#                 本脚本因此是唯一的重打包入口；解包目录里现存的项目改动
#                 （均带 "2026 QEMU 移植补丁" 注释，可 grep）主要有：
#                 - etc/runit/1：加载项目补的 AppArmor profile；write_board_version
#                   对 gpio 空输出兜底（Stage 20.55，此前脚本在第 62 行静默退出，
#                   firewall/lockdown/pipewire 目录等从未执行）；firewall 失败降级为
#                   WARNING 而不是 runit_die。
#                 - etc/apparmor.d/local/{qtcar-ui-bins,chromium-adapters,connmand}-2026-qemu-fix
#                   ：QtCar/Chromium 二进制的宽松 enforce profile，头上必须带
#                   flags=(attach_disconnected)（Stage 20.55）。
#                 - sbin/firewall："2026 QEMU" 段：跳过 DoIP/TEE/u32（Stage 20.24），
#                   放行宿主机 SSH 端口转发与透明代理的 lo 回程（Stage 20.55）。
#                 - etc/sv/*/down 与 run 脚本守卫：QEMU 里永远起不来的硬件服务
#                   （bwlogger/drmlog/kalertd/ltng/wifi-stats/摄像头…，Stage 20.55.6）；
#                   etc/sv/wpa_supplicant/run 无 /dev/rfkill 时空转。
#                 - usr/bin/gst-register：无 VA-API 插件时跳过 vaapi-dec 校验
#                   （Stage 20.55.10），registry 才能生成并按设计 sv once 自停。
#                 - etc/sv/tsocks-relay、etc/sv/qemu-net-status-fix、usr/bin/tsocks-relay、
#                   x11-input-proxy、去水印、drmWaitVBlank 补丁等早期 Stage 的改动。
#                 - usr/lib/qemu-fix/libqemu_mqtt_guard.so（Stage 20.57，QtCarConnMan 开机
#                   崩溃）、usr/lib/qemu-fix/libqemu_eglpixmap.so（Stage 20.59，
#                   EGL_KHR_image_pixmap 缺失时用 XGetImage 模拟外部窗口合成，Autopilot
#                   可视化面板才不黑）；由 etc/sv/qtcar-connman/run、etc/sv/qtcar/run 在
#                   QEMU 下 LD_PRELOAD；usr/local/bin/pmhelper（Stage 20.58）。
#                 - Stage 20.60（联网/媒体链路）：etc/sv/connman/run 在 QEMU 下不带
#                   --noprivsep 起 connmand（privsep 自己丢能力，自检才能过）并静态配
#                   Wired 服务，connman 的 down 文件已删；etc/sv/qemu-net-status-fix/run
#                   改为只补 LINK_wifiState=online（MediaV2 的联网门只认 wifi/cell）；
#                   etc/chromium.env 的 --proxy-bypass-list 加 127.0.0.0/8 与
#                   *.teslamotors.com（否则 media webapp 经宿主代理 502）；sbin/firewall
#                   INTERNET chain 放行 127.0.0.1:1080（sandbox uid 才能经透明代理出网）。
#                 - Stage 20.61：sbin/firewall INTERNET chain 再放行 10.0.2.2:7897（chromium
#                   浏览器按 --proxy-server 直连宿主代理，否则"未连接到互联网"）；新增
#                   etc/sv/qemu-audio-stack + service/qemu-audio-stack（拉起 qtcar-audiod、
#                   置 GUI_audioReady/MEDIA_simAudioReady，玩具箱不再"音频正在初始化"）。
#                 - Stage 20.62：etc/asound.conf 末尾新增 qemu_dmix/qemu_out（dmix → AC97
#                   hw:0,0）；chromium-app/chromium/chromium-fullscreen/chromium-card/
#                   owners-manual/release-notes 的 run 在 QEMU 守卫下追加
#                   --alsa-output-device=qemu_out（audiod 起不来，tplug 设备无人消费，
#                   chromium 的声音出不去）。宿主侧配套：run_qemu_test.sh 自动取消 QEMU
#                   sink-input 的静音（PipeWire stream-restore 记成了 Mute/0%）。
#                 - Stage 20.63：新增 etc/sv/qemu-display-guard（宿主机缩放 QEMU 窗口会经
#                   virtio-gpu ui_info 把新尺寸当首选模式推给客机，X 掉到 720x400 且不会
#                   自愈）——每 5s 用 xrandr 检查、发现不是 1920x1200 就切回并 restart qtcar
#                   让它重新布局。
#                 - Stage 20.64：usr/lib/qemu-fix/qemu_eglpixmap.c/.so 升级到 v3——刷新节流
#                   80ms→33ms（TheaterView 合成 FPS 18→22）；加了 MIT-SHM 抓帧路径但保持
#                   关闭（X.kafel 的 seccomp 策略不够，硬开会让 Mesa 自己的 X11 SHM winsys
#                   每帧 "Failed to attach to x11 shm" 卡死 QtCar，已现场验证并回滚，代码里
#                   有完整记录，不要重开）。
#                 QEMU 启动参数侧的对应改动在 scripts/run_qemu_test.sh
#                 （tsc=reliable、-cpu host,migratable=off，Stage 20.55）。
#                 完整因果记录见 docs/00_overview.md 对应 Stage。
#
# 用法：
#   ./scripts/patch_rootfs.sh                    # 用默认输入/输出路径
#   ./scripts/patch_rootfs.sh <rootfs目录> <输出squashfs路径>

set -euo pipefail
cd "$(dirname "$0")/.."   # -> <repo-root>/2026

ROOTFS_DIR="${1:-extracted/squashfs-root-2026}"
OUT_SQUASHFS="${2:-extracted/rootfs_2026_current.squashfs}"
SRC=/usr/lib/x86_64-linux-gnu   # 宿主机（Ubuntu 24.04）Mesa 25.2.8 所在目录

[ -d "$ROOTFS_DIR" ] || { echo "找不到解包目录: $ROOTFS_DIR（先用 unsquashfs -d 解包 2026.26.6.5.ice）"; exit 1; }
[ -d "$SRC" ] || { echo "找不到宿主机库目录: $SRC（本脚本假定跑在装了 libegl-mesa0/libgl1-mesa-dri 等包的 Ubuntu 24.04 主机上）"; exit 1; }

cd "$ROOTFS_DIR"

echo "== Stage 05/07: 清空 AppArmor 预编译策略（改为全局 unconfined）=="
rm -f etc/apparmor.compiled/*

echo "== Stage 08: sbin/check-lvm-parts 不再给 home/gamesusr 卷开 ext4 quota =="
if grep -q 'tune2fs -Q usrquota,grpquota,prjquota' sbin/check-lvm-parts 2>/dev/null; then
    python3 - <<'PYEOF'
import re
p = "sbin/check-lvm-parts"
s = open(p).read()
old = '''    if [ "$lv" = "home" ] || [ "$lv" = "$gamesusr_vol" ]; then
        tune2fs -l "$fs_dev" | grep -qE "^Filesystem features:.*quota";
        quota_check_res=$?;
        if [ "$quota_check_res" -eq "1" ]; then
            echo "$fs_dev: Enabling filesystem quota feature";
            tune2fs -Q usrquota,grpquota,prjquota "$fs_dev";
        fi;
    fi;'''
new = '''    # 2026 QEMU 移植补丁：4.14.274-PLK 内核没编译 CONFIG_QUOTA/CONFIG_QFMT_V2，
    # 打了 quota 特性位后内核直接拒绝挂载（"wrong fs type, bad superblock"）。
    :;'''
assert old in s, "check-lvm-parts 原文没匹配上，可能已经改过或者版本不一样，跳过"
open(p, "w").write(s.replace(old, new))
print("已патched sbin/check-lvm-parts")
PYEOF
else
    echo "（已经 patch 过，跳过）"
fi

echo "== Stage 10: 用宿主机 Mesa 25.2.8 补全/替换软件渲染 GL/EGL 支持 =="
mkdir -p usr/share/glvnd/egl_vendor.d
cp -f /usr/share/glvnd/egl_vendor.d/50_mesa.json usr/share/glvnd/egl_vendor.d/

# loader（libEGL/libGLX/libGL 等，走 GLVND 分发）+ 实际实现（libEGL_mesa/libGLX_mesa）
for f in \
    libEGL.so.1.1.0 libEGL.so.1 libEGL.so \
    libEGL_mesa.so.0.0.0 libEGL_mesa.so.0 \
    libgbm.so.1.0.0 libgbm.so.1 libgbm.so \
    libGLX_mesa.so.0.0.0 libGLX_mesa.so.0 libGLX_indirect.so.0 \
    libGLX.so.0.0.0 libGLX.so.0 libGLX.so \
    libGLdispatch.so.0.0.0 libGLdispatch.so.0 libGLdispatch.so \
    libGL.so.1.7.0 libGL.so.1 libGL.so \
    ; do
    [ -f "$SRC/$f" ] && cp -aL "$SRC/$f" usr/lib/
done

# gallium megadriver（libEGL_mesa/libdril_dri.so 运行时 dlopen 的真正驱动实现，
# 必须和上面 libEGL_mesa 同一个 Mesa 构建版本，不能混装）
cp -f "$SRC"/libgallium-*.so usr/lib/

# 经典 DRI 加载模型用的插件目录（给 X 自己的 AIGLX/GLX 用，比如 Xorg 的
# modeset 驱动走 swrast 兜底）——整目录换成宿主机的，保证和上面的
# loader/megadriver 版本一致，避免新旧混装
rm -f usr/lib/dri/*.so
cp -a "$SRC"/dri/*.so usr/lib/dri/

# gbm 平台的 dri 后端插件（Stage 20.54.7/20.54.8 补记：本节最初的注释
# 写的是"全部 dri/gbm 插件"，但实现只换了上面的 usr/lib/dri/ 目录，
# 漏掉了这个 usr/lib/gbm/ 目录——导致 usr/lib/gbm/dri_gbm.so 一直是
# Tesla 原厂链接旧版 libgallium-25.0.7.so 的那份，跟同一进程里其它已经
# 换成新版 25.2.8 的 loader（libEGL_mesa.so.0 等）版本不一致，
# glamor_egl_init() 深处对空函数指针发起调用，X server 段错误崩溃、
# 拖累 qtcar 总控脚本跟着崩溃重启。补齐这一目录，和上面 dri/ 目录一样
# 整体换成宿主机版本，避免同一个"驱动插件"分类下新旧版本混装）
mkdir -p usr/lib/gbm
rm -f usr/lib/gbm/*.so
cp -a "$SRC"/gbm/*.so usr/lib/gbm/

# gbm 平台加载 dri 后端插件时按 /usr/lib/x86_64-linux-gnu/gbm/ 这个多架构
# 路径硬编码查找，Tesla rootfs 没有这层目录结构，建个自引用软链接兜底
[ -e usr/lib/x86_64-linux-gnu ] || ln -s . usr/lib/x86_64-linux-gnu

# 完整传递依赖链（一个个 strace 揪出来的，见 docs Stage 10 逐条记录）
for f in \
    libwayland-client.so.0.22.0 libwayland-client.so.0 \
    libwayland-server.so.0.22.0 libwayland-server.so.0 \
    libwayland-egl.so.1.22.0 libwayland-egl.so.1 \
    libwayland-cursor.so.0.22.0 libwayland-cursor.so.0 \
    libLLVM.so.20.1 \
    libzstd.so.1.5.5 libzstd.so.1 \
    libsensors.so.5.0.0 libsensors.so.5 \
    libxcb-sync.so.1.0.0 libxcb-sync.so.1 \
    libxshmfence.so.1.0.0 libxshmfence.so.1 \
    libdrm_amdgpu.so.1.0.0 libdrm_amdgpu.so.1 \
    libelf.so.1 \
    libdrm_intel.so.1.125.0 libdrm_intel.so.1 \
    libXau.so.6.0.0 libXau.so.6 \
    libXdmcp.so.6.0.0 libXdmcp.so.6 \
    libffi.so.8.1.4 libffi.so.8 \
    libedit.so.2.0.72 libedit.so.2 \
    libxml2.so.2.9.14 libxml2.so.2 \
    libicuuc.so.74 libicudata.so.74 \
    liblzma.so.5.4.5 liblzma.so.5 \
    libpciaccess.so.0.11.1 libpciaccess.so.0 \
    libbsd.so.0.12.1 libbsd.so.0 \
    libtinfo.so.6.4 libtinfo.so.6 \
    libmd.so.0.1.0 libmd.so.0 \
    libz.so.1.3.2 libz.so.1 \
    ; do
    [ -f "$SRC/$f" ] && cp -aL "$SRC/$f" usr/lib/
done

echo "== docs/49 14.31/14.32: libgallium LP_SCENE_MAX_SIZE 补丁已验证无效，撤销 =="
# 背景：GDB 逐层追出 llvmpipe 8 个光栅化 worker 线程反复被同一个"任务计数器
# 恒为1"的信号量唤醒。当时怀疑是 lp_scene.c 里场景专属内存池写满（硬编码
# 36MB 上限 LP_SCENE_MAX_SIZE）逼着提前强制收尾场景，试过二进制打补丁把
# 上限提到 512MB。**实测证伪**：补丁前后用同样的 GDB 断点测信号量唤醒频率，
# 45秒观察窗口分别是 96619 次和 100878 次，几乎没有变化，画面依然冻结在
# 原地——说明瓶颈根本不是场景内存写满，已确认撤销（不再需要这段补丁代码，
# 保留在这里只是记录排查过的方向；下一个怀疑方向见 docs/49 14.32：
# lp_setup_bind_framebuffer() 每次切换渲染目标都无条件强制 flush，和场景
# 内存大小无关，更可能是真正的高频触发源）。

echo "== docs/49 14.34: 持久化 gojue/ecapture (v2.6.0) 到 rootfs =="
# 之前每次都靠 extracted/hostshare/ 9p 共享临时拷贝进去，重开一轮实例就没了。
# 静态链接二进制，直接固化进 rootfs，guest 里长期可用，不依赖 hostshare 挂载。
ECAPTURE_BIN="../../tools/ecapture-v2.6.0-linux-amd64"
if [ -f "$ECAPTURE_BIN" ]; then
    cp -f "$ECAPTURE_BIN" usr/local/bin/ecapture
    chmod +x usr/local/bin/ecapture
else
    echo "!! 找不到 $ECAPTURE_BIN，跳过 ecapture 持久化（不影响其它补丁）"
fi

echo "== Stage 11: 移除会崩溃宿主机 virglrenderer 的 VA-API GStreamer 插件 =="
# 背景（docs/00_overview.md Stage 11）：guest 里的 gst-plugin-scanner 在给
# libgstva.so/libgstvaapi.so 建插件缓存时，会探测硬件视频解码能力，往
# virtio-gpu 发一个宿主机 virglrenderer 不认识的 CREATE_VIDEO_BUFFER 命令，
# 报 "Illegal command buffer"，反复报错最终拖垮 virglrenderer 的 EGL 上下文，
# QEMU 主进程直接 core dump（只在开 virtio-vga-gl/virgl 时才会触发，纯
# virtio-vga 不受影响）。这两个插件文件本身不是刚需，直接摘掉。
rm -f usr/lib/gstreamer-1.0/libgstva.so usr/lib/gstreamer-1.0/libgstvaapi.so

echo "== 校验：确认关键库没有缺失的依赖 =="
missing=0
for f in usr/lib/libEGL.so.1 usr/lib/libEGL_mesa.so.0 usr/lib/libgallium-*.so \
         usr/lib/libLLVM.so.20.1 usr/lib/libgbm.so.1 usr/lib/dri/libdril_dri.so \
         usr/lib/libwayland-client.so.0 usr/lib/libxml2.so.2 usr/lib/libGLX_mesa.so.0; do
    out=$(LD_LIBRARY_PATH="$(pwd)/usr/lib" ldd "$f" 2>&1 | grep "not found" || true)
    if [ -n "$out" ]; then
        echo "!! $f 仍有缺失依赖:"; echo "$out"; missing=1
    fi
done
[ "$missing" -eq 0 ] && echo "OK，没有发现缺失依赖。"

cd - >/dev/null
echo "== 重新打包 squashfs -> $OUT_SQUASHFS =="
mksquashfs "$ROOTFS_DIR" "$OUT_SQUASHFS" -comp lz4 -Xhc -b 131072 -noappend

echo "完成: $OUT_SQUASHFS"
