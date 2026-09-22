# Tesla_OS_On_QEMU

English version: [README.md](README.md)

一套用于解包Tesla车机（信息娱乐ECU，"ICE"）固件/eMMC dump、按需改包（patch）根文件系统用于研究，并在QEMU里离线启动分析的工具集——基于对一台真实Model 3 Intel Elkhart Lake（"ICE-MRB"）平台固件镜像的完整逆向分析工作整理而成。

仓库地址：https://github.com/cn0xroot/Tesla_OS_On_QEMU

> **本仓库只包含工具代码和文档，不包含、也不会自动下载任何固件镜像、解包产物、密钥、抓包数据或日志文件**——详见下文[仓库里不包含什么](#仓库里不包含什么)。你需要自备固件dump。

## 这是什么

Tesla这一代Intel车机的根文件系统是一份受dm-verity保护的squashfs镜像，物理上被拆散存放在多个GPT分区里，用厂商私有的`dm-linear`布局，由原厂`verity-init`在每次启动时动态重新拼接起来。要拿到一份完整、可检查的文件系统副本——并且能在模拟器里而不是真实硬件上把它跑起来——需要走完几个不太直观的步骤（完整过程，包括中间走过的弯路，如果你本地保留了那份分析记录，见`docs/firmware_unpacking_reproduction.md`）。

`scripts/tesla_fw.py`是把整条流水线封装成的一个统一命令行工具：

| 阶段 | 做什么 |
|---|---|
| `unpack` | 分区表 → 从`iasImage`私有容器里提取内核 → 重建`dm-linear`拼接后的完整rootfs → `unsquashfs`解包 |
| `patch` | 编译一个绕过dm-verity签名校验的精简`init` + initrd；把改过的rootfs目录重新打包回squashfs |
| `run` | 在QEMU里启动（可以是改过的）固件——支持纯串口无界面、交互式图形界面、挂载GDB、完整加速图形栈四种模式 |
| `ssh` / `focus` / `capture` | 配合正在运行的QEMU客户机的日常操作：SSH进去、修复宿主机输入焦点、抓包 |

## 依赖环境

- Linux宿主机，Python 3.8+
- `qemu-system-x86_64`、`qemu-img`（建议有KVM，启动速度会合理很多）
- `squashfs-tools`（`unsquashfs`、`mksquashfs`）
- `gcc`（静态编译绕过verity的精简init）、`cpio`、`gzip`
- `fdisk`/`sfdisk`（分区查看/提取）
- `openssh-client`（`ssh`/`capture`子命令要用）

## 快速上手

```bash
git clone https://github.com/cn0xroot/Tesla_OS_On_QEMU
cd Tesla_OS_On_QEMU

# 1. 解包你自己已经拿到的固件 dump（本仓库不提供固件本身）
python3 scripts/tesla_fw.py unpack /path/to/tesla_ROM1_*.bin ./extracted both \
    --ias-image ./extracted/boot/bank_a.iasImage --bzimage-len 0x832fa0 \
    --make-overlay

# 2.（可选）修改 extracted/rootfs_reconstructed/squashfs-root-a/... 下的内容，
#    然后重新打包，并编译一条绕过 verity 签名的启动路径：
python3 scripts/tesla_fw.py patch repack \
    extracted/rootfs_reconstructed/squashfs-root-a rootfs_edited.squashfs
python3 scripts/tesla_fw.py patch build-init ./patched_boot

# 3. 启动
python3 scripts/tesla_fw.py run --mode headless --image /path/to/tesla_ROM1_*.bin --duration 180
python3 scripts/tesla_fw.py run --mode ui --rootfs rootfs_edited.squashfs

# 4. 运行期间
python3 scripts/tesla_fw.py ssh
python3 scripts/tesla_fw.py capture eth0 30
```

每个子命令都有自己的`--help`，列出完整参数。

### `unpack`详解

```
tesla_fw.py unpack <固件镜像.bin> <输出目录> [a|b|both]
    --ias-image PATH        boot 分区里的 bankX.iasImage（提供则同时提取内核）
    --bzimage-len HEX       从设备自身 bootlog.0 读到的精确 bzImage 长度
    --skip-unsquashfs       只重建原始镜像，不跑 unsquashfs
    --make-overlay          额外创建 QEMU qcow2 写时复制覆盖层
    --p2-off/--p3-off/--seg1-len/--p4-off/--p4-end-incl
                             你的镜像分区表和默认值不同时用这几个参数覆盖
```

重建这一步是关键：这一代固件里，单独一个GPT分区**装不下**完整的squashfs + dm-verity元数据。真正的根设备是这个分区加上从LVM数据分区尾部借来的1GiB空间、用`dm-linear`拼接出来的虚拟设备——精确的拼接偏移是从厂商自己的`verity-init`二进制反汇编还原出来的。这个公式里任何一个截断/取整细节算错，得到的rootfs都会"看起来像是坏的"（squashfs表指针指向了文件末尾之外），但其实只是错位了几千字节而已；`tesla_fw.py unpack`用的是已经修正过的公式。

### `patch`详解

```
tesla_fw.py patch build-init <输出目录>         # 编译 scripts/custom_init.c，
                                                # 打包成单文件 initrd
tesla_fw.py patch repack <rootfs目录> <输出.squashfs> [--comp lz4] [--block-size 131072]
tesla_fw.py patch legacy-tables <squashfs>     # 已废弃，仅存档，见 --help
```

原厂rootfs受dm-verity保护：改动哪怕一个字节，原厂`verity-init`都会拒绝挂载。`patch build-init`编译出一个精简的替代PID 1（`scripts/custom_init.c`），完整复刻原厂init的挂载/切根流程，但跳过RSA签名校验——这样任何**结构合法**的squashfs（不管改没改过内容）都能启动。这**不能**、也无意让改过的内容通过Tesla真实的签名校验；仅供离线模拟器研究使用。

### `run`详解

```
tesla_fw.py run --mode headless --image 镜像 --duration 180 [--gui]
tesla_fw.py run --mode ui       --rootfs squashfs [--kernel ...] [--initrd ...]
tesla_fw.py run --mode gdb      --rootfs squashfs
tesla_fw.py run --mode glamor
```

`--mode`在`scripts/`下原本就有的四套QEMU启动方案之间切换（`run_qemu.sh`/`run_qemu_ui.sh`/`run_qemu_gdb.sh`/`run_v62_glamor.sh`）：分别是定长无界面启动、长期运行的交互式图形会话、挂载内核态+用户态GDB的调试会话、完整加速2D图形栈。各自的具体配置见对应脚本头部注释。

## QEMU里各设备功能的实际状态

启动之后哪些真的能用、哪些还不行：

| 子系统 | 状态 | 修复方式 | 本仓库能否复现 |
|---|---|---|---|
| 触摸 | 可用 | 把坐标空间算错的`touch-proxy`换成`x11-input-proxy`——直接用X11 XTest以屏幕坐标注入点击(v63) | 部分——`scripts/x11-input-proxy.c`本身在仓库里，但rootfs里调用它的那部分配置不在 |
| 浏览器——Apple Music网页视图(`chromium-app`) | 可用(能渲染、不崩溃) | 强制走软件渲染(`--disable-gpu --disable-gpu-compositing`)，加上沙箱netns/绑定挂载修复；流媒体后端本身在模拟器环境里连不通，这不是客户机软件的问题 | 否——只烘焙在rootfs里 |
| 浏览器——车机内置Browser应用 | 部分可用 | 绕开一个开机时序竞争后面板能打开，但页面内容是黑屏：没有GPU加速、也没编译进swiftshader软件GL兜底——目前是个尚未解决的硬限制 | 否——未解决问题 |
| 音频/声卡 | 可用(声音输出到宿主机) | 原厂内核压根没编译PCI/USB声卡驱动，加了一个自定义AC97内核模块，配合QEMU的`-audiodev pa,...`把客户机音频流实时转到宿主机PulseAudio/PipeWire；此前还单独修过一个崩溃重启循环(预先建好`/var/lib/alsa`和`/var/lib/audiod`目录) | 部分——QEMU侧的`-audiodev`配置在`run_qemu_ui.sh`/`run_v62_glamor.sh`里，但内核模块和rootfs目录修复不在 |
| 网络(app联网+稳定SSH同时成立) | 可用 | v68双网卡方案：`eth0`留给connman管、配静态IP保证app联网；`eth1`配一个connman完全碰不到的独立静态IP专供SSH，两边互不干扰。另有一个更早的独立修复，防止connman错选一份factory专用配置导致整机断网 | **是**——`tesla_fw.py patch network-fix`(见下文) |
| 图形渲染(2D) | 可用 | 纯2D直出(`-device virtio-vga`，不开`gl=on`)——真实车机UI完整渲染并持续运行(Factory Net标识、地图网格、加载卡片、底部任务栏全部可见且在动) | 否——只是QEMU显示参数，不需要改rootfs |
| 3D硬件加速 | 本宿主不可用 | 试过`virtio-vga-gl`+`gl=on`(virgl)想同时解决下面2D刷新慢和mame黑屏两个问题——guest开始建GL上下文的~35秒那一刻，QEMU在`libGLX_nvidia.so`里段错误；强制走Mesa软件GLX能避开这次崩溃，但QEMU还是在同一个时间点静默死掉。已永久放弃，只在`run_qemu_ui.sh`里留了个实验性的`GL=on`开关 | 不适用——宿主GPU/驱动层限制，不是本仓库工具能解决的 |
| 地图/导航 | 可用 | 需要重编内核(`CONFIG_NETFILTER_XT_TARGET_REDIRECT`、`CONFIG_NF_NAT_REDIRECT`)才能让透明SOCKS代理`REDIRECT`住那些无视`http_proxy`直连的地图/流媒体流量，同时把`CONFIG_NR_CPUS`从4提到8。STABLE rootfs文件名里的"mapfix"指的就是这个。实测拿到真实Google地图瓦片和超充桩列表 | 否——烘焙在自定义的`bzImage_redirect_smp8`内核里，不是rootfs文件 |
| 内置游戏 | 部分可用 | 原生Toybox小游戏(Light Show、Sketchpad等)能玩——由QtCar自己渲染，不需要单独的GL进程。Arcade应用能打开，但里面能下载的游戏(Beach Buggy Racing 2等)装不了——Tesla的CDN后端在模拟器环境里连不上，这是环境限制不是bug。经典mame游戏(Missile Command、Asteroids等)完全渲染不出来：没有GPU、没编译进软件SDL渲染器、这套Mesa构建里的软件EGL-on-X11路径也不工作——和上面3D加速是同一个硬限制 | 部分——音频门控的绕过方案(一个自造的`gameaudio-ready` runit服务)是rootfs改动，还没在本仓库里沉淀成工具；mame/Arcade那部分限制本来就没法用软件解决 |

几点需要说清楚的地方：

- 触摸、浏览器、音频、地图，以及游戏的音频门控绕过方案，这几项"可用"，指的是`run_qemu_ui.sh`/`run_v62_glamor.sh`默认引用的那份预打包`..._STABLE.squashfs`——这份镜像本身不随仓库分发(见[仓库里不包含什么](#仓库里不包含什么))，所以如果你自己从头用`unpack`+`patch repack`打一份rootfs，这几项修复不会自动带上，需要自己重新实现。图形/音频/触摸/地图这几处修复涉及二进制补丁、重编内核和一个自定义内核模块，目前还没有沉淀成本仓库里的独立工具。
- 网络修复是唯一的例外：可以完整从本仓库复现。对着一个已经启动的客户机(用`run --mode ui`或`--mode glamor`起的，这两个模式本来就带第二块网卡)跑：

  ```bash
  python3 scripts/tesla_fw.py patch network-fix
  ```

  这条命令对`eth0`应用的是[Part 2](https://cn0xroot.wordpress.com/2026/09/20/root_tesla_os_on_qemu_part_2_debugging_fixing/)原文逐字记录的`connmanctl`命令序列；给`eth1`配静态IP这部分，原始文件内容没有留存，用的是标准命令做的等效重建。只对当前这次运行生效——改的是运行时网络状态，不是`/etc/runit/1`本身，重启客户机后失效。哪部分是"逐字精确"、哪部分是"等效重建"，`scripts/apply_network_fix.sh`脚本头部写得很清楚。

## 延伸阅读

完整的研究记录——方法论、走过的弯路、以及这套工具沉淀出的结果——发在作者博客上，分两篇：

- [Part 1: Unpacking](https://cn0xroot.wordpress.com/2026/09/19/root-tesla-os-on-qemu-part-1-unpacking/)——完整走一遍GPT分区分析、从设备自己的`bootlog.0`反推出`iasImage`容器格式、反汇编`verity-init`还原出精确的`dm-linear`拼接公式，以及用±2MB全窗口穷举法把一份"看起来数据丢失"的rootfs最终定位到一个被漏掉的`(p4_bytes >> 12) << 3`截断公式。
- [Part 2: Debugging + fixing](https://cn0xroot.wordpress.com/2026/09/20/root_tesla_os_on_qemu_part_2_debugging_fixing/)——覆盖启动链修复（内核模块版本锁定、RCU stall调优、LUKS/quota每次开机重新格式化的坑）、图形栈移植（DRM驱动选型、Mesa ABI不匹配、`virtio-gpu-gl`回退到`virtio-vga`）、触摸输入协议转换，以及两个值得单独提一下的安全发现：`sshd_config`按`is-fused()`切换开发/生产配置，还有`QtCarDvServer.kafel`的seccomp白名单里漏掉的`clock_gettime`——这颗测试内核的glibc跳过了VDSO快速路径才暴露出这个缺口。

## 仓库里不包含什么

`.gitignore`采用严格白名单模式：默认忽略一切，只有工具代码本身（`scripts/*.py`、`*.sh`、`*.c`、`*.patch`）和本README被纳入版本控制。明确地，**以下内容永远不会被提交**：

- 固件dump本身，以及从它衍生出的任何数据（提取出的分区、重建出的rootfs镜像、`.squashfs`/`.qcow2`文件）
- SSH密钥（`scripts/ssh_key/`）
- 抓包数据、串口启动日志、启动后界面截图
- `extracted/`、`build/`、`docs/`等本地工作过程中会积累出来的目录

如果你fork这个项目继续自己的研究，请保持同样的边界：工具代码本身可以公开分享，但它从真实设备产出的分析结果通常不行。

## 使用范围与研究伦理

本项目的目的是让Tesla自家的车机固件可以**离线**、在模拟器里被检查和启动，用于安全研究和防御性分析——不是为了绕开在用真实车辆上的安全机制。`patch build-init`里的dm-verity绕过只帮你在**QEMU内部**启动改过的镜像，对真实车辆自身的verity/TPM信任链没有任何影响、也提供不了任何绕过路径。请只对你有权分析的固件使用本工具（自己拥有的硬件，或在已披露的研究/漏洞赏金授权范围内），发现的问题请遵循负责任的披露流程。

## 致谢

感谢[@vessial](https://x.com/vessial)（[GitHub](https://github.com/vessial)）在固件解包思路上的指导——`unpack`里`dm-linear`重建这部分工作直接受益于这个建议（详见上面[Part 2](https://cn0xroot.wordpress.com/2026/09/20/root_tesla_os_on_qemu_part_2_debugging_fixing/)原文里的致谢）。

`run --mode glamor`（`scripts/run_v62_glamor.sh`）用到的完整加速图形栈，是把[denysvitali/tesla-qemu](https://github.com/denysvitali/tesla-qemu)率先摸索出的Ubuntu Xorg + `modesetting` + glamor（llvmpipe）方案，连同其中的vblank-wait DRM补丁，一起移植到了本项目真实的Tesla 4.14 rootfs上。`scripts/touch-proxy.c`同样基于该项目的`tools/touch-proxy.c`改写。感谢[@denysvitali](https://github.com/denysvitali)在QEMU图形栈这条路线上打下的原始基础。

Tesla官方公开的几个源码仓库，是识别/核对本项目所针对硬件平台的重要参考资料：

- [teslamotors/linux](https://github.com/teslamotors/linux) —— 官方内核源码，用来和提取出的`bzImage`（版本号、`Tesla Model3 hardware core support`字符串、驱动选型）做交叉核对，确认解包结果的真实性。
- [teslamotors/coreboot](https://github.com/teslamotors/coreboot) —— Tesla的coreboot源码，涉及Intel Elkhart Lake平台更早期的引导链，与本项目`unpack`/`patch`工具所针对的`iasImage`/`verity-init`引导序列衔接。
- [teslamotors/buildroot](https://github.com/teslamotors/buildroot) ——确认了固件平台标注为`ice-mrb`（"In-Car Entertainment"）、用户态整体布局（`runit`、`connman`、软件包集合）与该固件一致，也提供了一个版本基线用来比对解包出的rootfs。

## 许可证

本项目采用**GNU General Public License v3.0**开源许可证，完整文本见[`LICENSE`](LICENSE)。

有一个例外：`scripts/touch-proxy.c`是[denysvitali/tesla-qemu](https://github.com/denysvitali/tesla-qemu)中`tools/touch-proxy.c`的衍生作品，而该上游项目本身没有声明任何许可证。因此这一个文件**不受**本仓库GPL-3.0授权的覆盖，具体说明见文件头部注释。本仓库其余内容（包括`scripts/tesla_fw.py`、`scripts/custom_init.c`及全部文档）均为原创，按GPL-3.0授权。
