# Radxa Cubie A7S · Armbian 附加组件

为 **Radxa Cubie A7S**（全志 A733，sun60iw2p1）上运行的 **Armbian** 系统准备的附加组件集合：
一些内核驱动、厂商用户态库、以及装完系统之后才需要做的配置，连同安装脚本与说明一起放在这里。

主线适配（板级设备树、分区方案、内核配置等）在上游 Armbian 仓库里；**本仓库只放"装完系统之后再加"的部分**。

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
| [`dsufreq/`](dsufreq/) | DSU / L3 调频 | 集群频率调节的受控启用流程 |
| [`usb-gadget/`](usb-gadget/) | USB gadget | 把 USB-C OTG 口变成串口设备（PC 侧出现 `/dev/ttyACM0`） |
| [`watchdog/`](watchdog/) | 硬件看门狗 | 交给 systemd 喂狗，系统挂死时自动复位 |
| [`tests/`](tests/) | 测试脚本 | 一键硬件验证与压测套件（装完组件后自检用） |

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
├── dsufreq/       DSU/L3 调频受控启用脚本
├── usb-gadget/    USB 串口 gadget 脚本
├── watchdog/      硬件看门狗启用脚本
├── tests/         硬件验证与压测套件（stress.sh + 模块）
└── tools/         组件获取与辅助说明
```

## 六、来源与许可

- 本仓库内的**脚本、源码与文档**：GPL-2.0（见 [`LICENSE`](LICENSE)）；
- 仓库中**厂商提供的二进制与库**（如 `ve/usr-lib/`、`camera/isp/pkgs/`、`tz2hwmon/tz2hwmon.ko` 等）
  来自板卡厂商官方镜像或其官方发布物，版权归各自权利人，随附只为便于安装，详见
  [`THIRD-PARTY.md`](THIRD-PARTY.md)；
- 上游 Armbian 项目与本仓库的关系：本仓库不是 Armbian 官方项目，组件由社区维护。

## 七、说明

- 仓库**只提供安装方法与说明**，不含任何测试报告或运行日志；
- 组件均已在实机长期使用，但**换内核、升级系统后请重新执行对应安装脚本**（尤其是 DKMS 类与内核模块类）；
- 遇到问题请附上：`uname -r`、组件目录下的脚本输出、以及 `dmesg | tail -50`。
