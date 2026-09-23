# 第三方组件来源与许可

本仓库为便于安装，随附了部分**板卡厂商提供的二进制与库**。这些文件版权归各自权利人，
许可条款以其原始发布物为准；本仓库不对其做任何修改（除必要的目录整理）。

本仓库**自身**的授权分两种，见 [`LICENSE`](LICENSE)（MIT：脚本、文档、用户态程序）与
[`LICENSE-GPL-2.0-only`](LICENSE-GPL-2.0-only)（`tz2hwmon/` 内核模块与 `gpu/patches/` 内核驱动补丁）。
下表中的内容**不适用**上述授权，许可状态以各自仓库或发布物的实际声明为准——其中部分上游仓库
并未声明许可，本仓库对这类内容只给出获取方式、不收录其内容。

| 路径 | 内容 | 来源 | 许可 |
|---|---|---|---|
| `ve/usr-lib/`（18 个 `.so`） | 全志 cedar 系视频编解码用户态库 | Radxa 官方 Cubie A7S 镜像（rsdk-r6）rootfs `/usr/lib` 提取 | 全志闭源，随厂商镜像分发 |
| `ve/include/`（12 个头文件） | 同上，开发头文件 | 同上 | 同上 |
| `ve/cedarc.conf` | 同上，运行时配置 | 同上 | 同上 |
| `camera/isp/pkgs/*.deb` | ISP 与 cedarc 用户态 deb 包（`libAWIspApi-isp-602-arm64`、`libcedarc-dev-2.0.0-arm64`） | Radxa 官方发布物 | 全志闭源，随厂商发布物分发 |
| `tz2hwmon/tz2hwmon.ko` | 预编译内核模块 | 本项目编译（源码在同目录 `tz2hwmon.c`） | GPL-2.0-only |
| `gpu/test/*`（二进制） | GPU 三栈自检程序 | 本项目编译（源码在同目录 `*.c`） | MIT |

**不在本仓库**（需自行从厂商官方发布物取得，见 `tools/厂商组件获取.md`）：

| 组件 | 来源 | 许可 |
|---|---|---|
| GPU 内核驱动源码（`img-bxm-dkms`） | Radxa 官方镜像内 DKMS 包 | IMG GPL v2 |
| GPU 用户态库与固件（`rgx.fw` 等） | Radxa 官方镜像 rootfs | IMG 闭源，随厂商镜像分发 |
| NPU AI SDK（`ai-sdk/`） | Radxa 文档指定的官方 AI SDK 仓库 | 见该仓库自带许可 |
