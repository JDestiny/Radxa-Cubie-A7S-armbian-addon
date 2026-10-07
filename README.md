# Radxa Cubie A7S · Armbian 附加组件

为 **Radxa Cubie A7S**（全志 A733，sun60iw2p1）上运行的 **Armbian** 系统准备的附加组件集合：
一些内核驱动、厂商用户态库、以及装完系统之后才需要做的配置，连同安装脚本与说明一起放在这里。

主线适配（板级设备树、分区方案、内核配置等）在上游 Armbian 仓库里；**本仓库只放"装完系统之后再加"的部分**。

<p align="center">
  <img src="assets/pet/whale-girl-refined.png" alt="DEEPSEEK娘" width="200">
</p>

<p align="center"><sub>(｡•̀ᴗ-)✧　DEEPSEEK娘：「脚本能跑，才算写完。」</sub></p>

## 一、适用环境

| 项 | 要求 |
|---|---|
| 板卡 | Radxa Cubie A7S（全志 A733 / sun60iw2p1） |
| 系统 | Armbian（本仓库组件在 **内核 6.6.98-vendor-sun60iw2** 上验证） |
| 权限 | 所有安装脚本都需要 `sudo` |
| 网络 | 部分组件需要联网（见各自目录说明） |

> 这些组件只针对这一块板子与这个内核分支；换内核后部分组件（DKMS 类）需要重新安装。

## 二、组件一览

| 目录 | 组件 | 一句话说明 |
|---|---|---|
| [`gpu/`](gpu/) | GPU（PowerVR BXM-4-64） | 内核驱动（DKMS，两个变体：原版 / 带 GPU 利用率记账）+ 用户态库、固件、Vulkan/OpenCL ICD |
| [`npu/`](npu/) | NPU | 官方 AI SDK 中间件与运行时（golden 测试、resnet50 等） |
| [`ve/`](ve/) | 视频编解码（VE） | 全志 cedar 系用户态库与头文件，硬解 / 硬编码可用 |
| [`camera/`](camera/) | 相机（MIPI-CSI） | 设备树 overlay 安装/启用，以及 ISP 用户态栈（**当前只有 IMX219 可用**） |
| [`tz2hwmon/`](tz2hwmon/) | 温度桥接 | 把 `thermal_zone` 暴露成 `hwmon`，让 `htop` / `btop` / `sensors` 能读到温度 |
| ~~[`dsufreq/`](dsufreq/)~~ | ~~DSU / L3 调频~~ | **⚠️ 已废弃（2026-10-06）：不要安装、不要写黑名单**。DSU 动态调频本来正常工作（实测 312↔1274 MHz），所有处置步骤**都不需要**；目录仅保留 `dsufreq-test.sh status` 作只读排障 |
| [`usb-gadget/`](usb-gadget/) | USB gadget | 把 USB-C OTG 口变成串口设备（PC 侧出现 `/dev/ttyACM0`） |
| [`watchdog/`](watchdog/) | 硬件看门狗 | 交给 systemd 喂狗，系统挂死时自动复位 |

每个目录下都有一份 `README.md`，写明**前置条件、安装步骤、验证方法与卸载/回滚**。

## 三、快速开始

```bash
git clone <本仓库地址> radxa-cubie-a7s-armbian-addon
cd radxa-cubie-a7s-armbian-addon

# 例：装 GPU
cd gpu && sudo ./install-gpu-userspace.sh          # 用户态（库/固件/ICD）
sudo ./install-gpu-driver-gpuacct.sh               # 内核驱动（带利用率记账，htop 可见）

# 例：装温度桥接
cd ../tz2hwmon && sudo ./install-tz2hwmon.sh

# 装完自检
cd ../tests && sudo ./stress.sh --quick
```

组件之间**互不依赖**，可以只装你需要的那几个。

## 四、大体积组件怎么取得

有三个组件体积较大（合计约 1GB），不适合直接放进 git 仓库，因此**仓库里只放脚本与说明**，组件本体需要你自行取得，放进对应目录后再运行安装脚本：

| 组件 | 需要放到哪里 | 取得方式 |
|---|---|---|
| GPU 内核驱动源码（原版约 21 MB） | `gpu/img-bxm-dkms-src/` | 见 [`tools/厂商组件获取.md`](tools/厂商组件获取.md)；记账版 = 原版 + [`gpu/patches/`](gpu/patches/) 里的补丁（补丁随仓库提供） |
| GPU 用户态库与固件（约 106 MB） | `gpu/userspace/` | 同上 |
| NPU AI SDK（约 800 MB） | `npu/ai-sdk/` | 同上 |

若安装脚本提示找不到这些目录，按上表补齐即可。

## 五、目录结构

```
radxa-cubie-a7s-armbian-addon/
├── gpu/           GPU 内核驱动（DKMS）+ 用户态 + 自检程序
├── npu/           NPU 中间件安装脚本
├── ve/            VE 用户态库/头文件/配置 + 安装脚本 + 演示程序
├── camera/        相机设备树 overlay + ISP 用户态
├── tz2hwmon/      温度桥接内核模块（源码 + 预编译）
├── dsufreq/       ⚠️ 已废弃（仅保留只读排障脚本 status）
├── usb-gadget/    USB 串口 gadget 脚本
├── watchdog/      硬件看门狗启用脚本
├── tools/         组件获取与辅助说明
└── AI-DISCLOSURE.md  AI 协助开发声明（工具、分工、贡献者声明方式）
```

## 六、来源与许可

本仓库**按内容类型分两种授权**，每个源码与脚本文件头部都带 `SPDX-License-Identifier` 标识：

| 范围 | 授权 | 为什么这么分 |
|---|---|---|
| 安装脚本、文档，以及**用户态程序**（`ve/` 等） | **MIT**<br>（全文见 [`LICENSE`](LICENSE)） | 这些程序要**动态链接厂商闭源库**（`libvdecoder.so`、`libEGL.so.1`、`libOpenCL.so.1` 等）。GPL-2.0 第 7 节不允许分发"GPL 程序 + 与之不兼容的专有库"这种组合，而本仓库恰恰会发布这些编译好的程序；MIT 没有这个限制。MIT 同时也能被 GPL-2.0 的项目（如 Armbian）直接吸收，两个方向都不会卡住 |
| **内核模块** `tz2hwmon/` 与**内核驱动补丁** `gpu/patches/` | **GPL-2.0-only**<br>（全文见 [`LICENSE-GPL-2.0-only`](LICENSE-GPL-2.0-only)） | Linux 内核是 GPL-2.0-only；该补丁修改的是 IMG 以 GPL v2 发布的内核驱动，属衍生作品，必须同为 GPL-2.0 |

另外两类内容不适用上述授权：

- 仓库中**厂商提供的二进制与库**（`ve/usr-lib/`、`ve/include/`、`camera/isp/pkgs/*.deb`）
  来自板卡厂商官方镜像或其官方发布物，版权归各自权利人，随附只为便于安装，详见
  [`THIRD-PARTY.md`](THIRD-PARTY.md)；
- 本仓库**自行编译**的产物与其源码同授权：`tz2hwmon/tz2hwmon.ko` 为 GPL-2.0-only，
  `ve/` 下的库与用户态程序为 MIT。

上游 Armbian 项目与本仓库的关系：本仓库不是 Armbian 官方项目，组件由社区维护。

**AI 协助**：本仓库内容在 **AI 编码助手（DeepSeek）**协助下开发——工具与分工、责任归属、
贡献者如何声明，见 [`AI-DISCLOSURE.md`](AI-DISCLOSURE.md)。简单说：**脚本由 AI 起草、
人类在真机上验证并负责**，`Signed-off-by` 只由人类签署。

## 七、说明

- 仓库**只提供安装方法与说明**，不含任何测试报告或运行日志；
- 组件均已在实机长期使用，但**换内核、升级系统后请重新执行对应安装脚本**（尤其是 DKMS 类与内核模块类）；
- 遇到问题请附上：`uname -r`、组件目录下的脚本输出、以及 `dmesg | tail -50`。

## 八、致谢

这块板子能从"只有内核驱动"变成各项功能可用，靠的是下面这些项目与厂商发布物。列出出处既为致谢，
也便于核对本仓库随附内容的来源。

### 直接使用的开源项目

| 项目 | 本仓库用到了什么 | 许可 |
|---|---|---|
| [armbian/build](https://github.com/armbian/build) | 组件所运行的 Armbian 系统由它构建；板级主线适配也提交到这里 | GPL-2.0 |
| [orangepi-xunlong/linux-orangepi](https://github.com/orangepi-xunlong/linux-orangepi) | 本板 vendor 内核源码（`6.6.98-vendor-sun60iw2`）：`tz2hwmon` 与 GPU DKMS 驱动都针对它编译 | 内核系 GPL-2.0（仓库未声明） |
| [radxa/allwinner-debian](https://github.com/radxa/allwinner-debian) | `camera/isp/pkgs/` 里两个 deb（ISP 与 cedarc 用户态）的来源 | 未声明许可 |
| [ZIFENG278/ai-sdk](https://github.com/ZIFENG278/ai-sdk) | NPU（VIPLite）中间件、`vpm_run` 与模型样例；Radxa 官方 NPU 文档指定的就是它 | 未声明许可 |
| [radxa-docs/docs](https://github.com/radxa-docs/docs) | Radxa 官方文档的源仓库（docs.radxa.com）；镜像下载页与 NPU 页是本仓库取件的依据 | 内容 CC BY 4.0 |

### 组件所运行的引导链（不属于本仓库）

| 项目 | 用到了什么 | 许可 |
|---|---|---|
| [orangepi-xunlong/u-boot-orangepi](https://github.com/orangepi-xunlong/u-boot-orangepi) | sun60iw2p1 的 U-Boot（`sun60iw2p1_t736_defconfig`） | U-Boot 系（仓库未声明） |
| [orangepi-xunlong/orangepi-build](https://github.com/orangepi-xunlong/orangepi-build) | 提供 ATF/SCP 预编译件与 `pack-uboot` 打包工具 | GPL-2.0 |
| Radxa 官方 Cubie A7S 镜像（rsdk-r6） | GPU 内核驱动源码、GPU 用户态库与固件、VE 库与头文件 | 厂商闭源，见 [`THIRD-PARTY.md`](THIRD-PARTY.md) |

### 测试脚本调用的第三方工具

由发行版包管理器安装，不随本仓库分发：[stress-ng](https://github.com/ColinIanKing/stress-ng)、
[fio](https://github.com/axboe/fio)、[iperf3](https://github.com/esnet/iperf)、
[mbw](https://github.com/raas/mbw)、[OpenSSL](https://github.com/openssl/openssl)、
[FFmpeg](https://github.com/FFmpeg/FFmpeg)、[lm-sensors](https://github.com/lm-sensors/lm-sensors)、
[Vulkan-Tools](https://github.com/KhronosGroup/Vulkan-Tools)，以及系统自带的 `v4l-utils`、`dkms`、
`dtc`、`python3`。

> 上面标注"未声明许可"的仓库，我们没有收录其内容，只在文档中给出获取方式；
> 随附的厂商二进制一律以其原始发布物的条款为准。

---

## 友情链接

同平台（**Allwinner A733 / `sun60iw2`**，Cubie A7A/A7S/A7Z 等）的平行工作与上游来源，
按用途分组；**本仓库组件独立开发，未直接引用其代码**，登记于此便于横向对照。
若将来引用其代码，将按其许可登记到 `THIRD-PARTY.md`。

### 一、GPU / 图形（PowerVR BXM-4-64）

| 项目 | 内容 |
|---|---|
| [ayiejosh/a733-powervr-fex](https://github.com/ayiejosh/a733-powervr-fex) | Cubie A7A/A7S · trixie + kernel 6.6 BSP：DRM-PRIME 补丁 / zink / DXVK / Hangover / FEX；含 **GPU 时钟天花板 1104 MHz**、**供电欠压** 等一手结论 |
| [davidhfrankelcodes/pvr-a733-armbian](https://github.com/davidhfrankelcodes/pvr-a733-armbian) | 上述配方的 Armbian 移植（Orange Pi Zero 3W）+ `gcc15-stringop-overread-fix.patch` + `vk_layer_pvr_strip.c` |
| [Incipiens/OrangePiZero3W-GPU-VPU](https://github.com/Incipiens/OrangePiZero3W-GPU-VPU) | OPi Zero 3W 的 GPU/VPU **镜像构建器**：只放脚本、不含专有二进制（用户态取自 Radxa 镜像 —— 与本仓库同一来源思路）|

### 二、NPU / AI

| 项目 | 内容 |
|---|---|
| [petayyyy/a733_npu_driver](https://github.com/petayyyy/a733_npu_driver) | A733 NPU（Vivante VIP9000）跑 LLM/VLM 实测：视觉/CNN 加速器，小模型 21/8 tok/s，非 Qwen 级；推荐 NPU 视觉 + CPU `llama.cpp` 混合 |
| [MaverickLong/Radxa-A733-NPU-Unified-Driver-Support-Package](https://github.com/MaverickLong/Radxa-A733-NPU-Unified-Driver-Support-Package) | A733 NPU **统一驱动支持包**（社区维护）|
| [MaverickLong/MLIR-TIM-VX](https://github.com/MaverickLong/MLIR-TIM-VX) | 面向 VeriSilicon **TIM-VX / VIP** 的 MLIR 编译路径 |

### 三、板级系统与构建（平行工作）

| 项目 | 内容 |
|---|---|
| [NickAlilovic/build](https://github.com/NickAlilovic/build/tree/Radxa-A7A)（`Radxa-A7A` 分支）| **Cubie A7A/A7Z 的 Armbian BSP 构建**（论坛主推方案，含预编译 release）|
| [DockSeed/a7s-build](https://github.com/DockSeed/a7s-build) | **Cubie A7S** 构建（与本项目同板型）|
| [cuihuir/radxa-a7z-debian12](https://github.com/cuihuir/radxa-a7z-debian12) | Radxa A7Z 的 Debian 12 集成 |
| [parker-int64/sun60i-a733-dtoverlays](https://github.com/parker-int64/sun60i-a733-dtoverlays) | A733 **设备树 overlays** 集合 |
| [vehoelite/edk2-a733](https://github.com/vehoelite/edk2-a733) | A733 的 **EDK2/UEFI** 固件尝试 |
| [skamagedon/a733-zero3](https://github.com/skamagedon/a733-zero3) | A733（Zero 3W）早期 **VE 硬解**探索 —— 本仓库 VE 方案的参考来源之一 |

### 四、官方源码与包（本项目组件的上游来源）

| 项目 | 内容 |
|---|---|
| [radxa/allwinner-bsp](https://github.com/radxa/allwinner-bsp) | **Radxa 官方全志 BSP** —— 本仓库 GPU（`pvrsrvkm` + 用户态）与 VE 组件的**直接来源**（r6 镜像）|
| [radxa/allwinner-device](https://github.com/radxa/allwinner-device) · [radxa-build/radxa-a733](https://github.com/radxa-build/radxa-a733) | 板级设备树与官方构建配置 |
| [radxa-pkg/aw-drivers-dkms](https://github.com/radxa-pkg/aw-drivers-dkms) · [radxa-pkg/u-boot-aw2501](https://github.com/radxa-pkg/u-boot-aw2501) | 官方 DKMS 驱动包与 U-Boot 包 |
| [alexcaoys/allwinner-bsp](https://github.com/alexcaoys/allwinner-bsp) | 全志 BSP 的社区镜像 |
| [armbian/build](https://github.com/armbian/build) | **本板级支持的提交目标（上游）** |

### 五、资料与讨论

| 链接 | 内容 |
|---|---|
| [Armbian 论坛：Radxa Cubie A7A/A7Z - Allwinner a733](https://forum.armbian.com/topic/56130-radxa-cubie-a7aa7z-allwinner-a733/) | 本平台最活跃的讨论帖（7 页）：构建、KVM、外设、散热等 |
| [Radxa 论坛：extreme throttling on A733](https://forum.radxa.com/t/extreme-throttling-introduced-on-a733/30688/4) · [A7A hardware virtualization](https://forum.radxa.com/t/a7a-harware-virtualization/29745) · [hardware decoding not enabled](https://forum.radxa.com/t/hardware-decoding-for-video-not-enabled-on-a7a/29836/9) · [SATA support](https://forum.radxa.com/t/radxa-cubie-a7a-sata-support/29154) | 与本项目测试项直接相关的官方论坛专题（降频/虚拟化/硬解/SATA）|
| [全志 A733 硬件文档（gitlab.com/tina5.0_aiot）](https://gitlab.com/tina5.0_aiot/product/docs/-/blob/product-aiot-stable/A733/Hardware) | 全志官方 A733 硬件文档仓库 |
