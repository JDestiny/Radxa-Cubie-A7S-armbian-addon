# Radxa 相机（MIPI-CSI）设备树 overlay

为 Cubie A7S 在 Armbian 下启用 Radxa MIPI-CSI 相机模组：三份设备树 overlay 源文件，以及安装 / 启用 / 停用 / 查看状态的脚本。

## 功能

| 内容 | 说明 |
|---|---|
| `install-camera-overlays.sh` | 编译 overlay、启用或停用指定相机、查看状态、卸载 |
| `sun60i-a733-camera-imx219.dts` | Radxa Camera 8M（IMX219）overlay 源码 |
| `sun60i-a733-camera-imx214.dts` | Radxa Camera 13M（IMX214）overlay 源码，见下方可用性说明 |
| `sun60i-a733-camera-imx415.dts` | Radxa Camera 4K（IMX415）overlay 源码，见下方可用性说明 |
| `isp/` | 相机 ISP 与 cedarc 用户态安装脚本、离线 deb 包 |

overlay 完成的工作：打开 CSI/VIN 通路（`csi1`、`vind0` 供电与 sensor 节点）、把 sensor 的控制 I2C 挂到 `twi3`、配置 sensor 的上电与复位脚，并把 `csi_top` / `csi_isp` 从 600/540 MHz 提升到 704 MHz（相机通路需要更高时钟）。**不插相机时保持与厂商默认设备树一致**，因此相机被做成可插拔的 overlay，而不是改板级设备树。

启用机制：overlay 编译为 `/boot/overlay-user/sun60i-a733-camera-<相机>.dtbo`，并把文件名写入 `/boot/armbianEnv.txt` 的 `user_overlays=`，由启动脚本在开机时叠加。选择 `/boot/overlay-user/` 而不是 `/boot/dtb/`，是因为后者属于 `linux-dtb-*` 软件包，内核或设备树一升级就会被整目录覆盖。

## 支持的相机型号

| 相机 | sensor 驱动 | 当前系统 | 说明 |
|---|---|---|---|
| Radxa Camera 8M（IMX219） | `imx219` | ✅ 可用 | **当前唯一受支持的型号**，内核驱动已具备，无需额外移植 |
| Radxa Camera 13M（IMX214） | `imx214` | ❌ 不可用 | 内核驱动尚未适配 6.6，编译不出模块 |
| Radxa Camera 4K（IMX415） | `imx415_mipi` | ❌ 不可用 | 内核驱动尚未适配 6.6，编译不出模块 |

**在本 Armbian 系统（内核 `6.6.98-vendor-sun60iw2`）上，IMX214 与 IMX415 的内核驱动尚未适配，只有 IMX219 可以正常使用。**

- 三份 overlay 源码都保留，供日后移植驱动后直接使用；`enable imx214` / `enable imx415` 会被脚本中的驱动可用性检查拦下并提示原因。
- 若在自行移植驱动后确需写入配置，可加 `--force` 跳过检查，但驱动缺失时相机仍然不会工作。
- `isp/` 的 `libisp_ini.so` 中同时包含 imx219 / imx214 / imx415 的调色参数，不影响上述结论。

## 前置条件

- **硬件**：Cubie A7S + Radxa 相机模组（当前仅 IMX219 可用），已接到板上的 MIPI-CSI 排线座。
- **系统**：Armbian（aarch64），内核 `6.6.98-vendor-sun60iw2`。
- **内核侧（关键）**：
  - VIN 与 CSI 驱动可用（`sunxi-vin-media` 等）；**`vind0` 的三路供电必须已在内核侧就绪**，否则 VIN 无法 probe，相机不会出图。
  - IMX219 sensor 驱动存在：`/boot/config-$(uname -r)` 中有 `CONFIG_SENSOR_IMX219=m`，且 `imx219` 模块可被 `modinfo` 找到。
- **工具**：`device-tree-compiler`（提供 `dtc`），
  `sudo apt install device-tree-compiler`。
- **权限**：安装 / 启用 / 停用需要 root；**改动后必须重启才生效**。
- **出图取色的用户态依赖**：ISP 用户态库（`libisp_ini.so` 等），见 [`isp/README.md`](isp/README.md)。

## 安装

```bash
cd radxa-cubie-a7s-armbian-addon/camera

# 1) 编译 overlay 到 /boot/overlay-user/（只安装，不启用）
sudo ./install-camera-overlays.sh install

#    如遇 I2C 通信问题，可把控制 I2C 从 400kHz 降到 100kHz 再编译
sudo ./install-camera-overlays.sh install --i2c-100k

# 2) 启用相机（写入 armbianEnv.txt 并配置 sensor 模块开机自加载）
sudo ./install-camera-overlays.sh enable imx219

# 3) 安装 ISP 用户态栈（相机出图取色所需）
sudo ./isp/install-isp-userspace.sh install

# 4) 重启生效
sudo reboot
```

说明：

- `install` 会编译全部三份 overlay，`enable` 只启用指定的相机；**三步都做完并重启后相机才可用**。
- `enable` 会顺带写入 `/etc/modules-load.d/camera-imx219.conf`，让 sensor 模块开机自动加载，否则 VIN 按 `sensor0_mname` 找不到 sensor。
- 脚本修改 `/boot/armbianEnv.txt` 前会自动备份为 `armbianEnv.txt.bak-<时间戳>`。
- **`--i2c-100k` 的使用场景**：若内核能识别 sensor、但采集不到帧，且 `dmesg` 出现 `sunxi:twi_...` 的 ACK / BUS error，说明 400kHz 下 sensor 初始化寄存器写不通，改用本选项重新 `install` 后再试。I2C 只走控制寄存器、图像走 MIPI，降速没有副作用。

## 验证

```bash
sudo ./install-camera-overlays.sh status
```

该命令会输出：三份 dtbo 是否已安装、已装 dtbo 的 I2C 速率、`armbianEnv.txt` 中的 `user_overlays` 与 `overlay_prefix`、sensor 模块自加载配置、三款相机的驱动可用性、**当前内核里叠加是否生效**（`csi1` 状态、`csi_top` 频率、`sensor0_mname`、`/dev/media*`、已加载的 sensor 模块），并给出结论。

独立复核（重启后执行）：

```bash
# sensor 模块是否加载
lsmod | grep imx219

# 是否出现媒体与采集设备节点
ls /dev/media* /dev/video*

# VIN / CSI 驱动日志
dmesg | grep -iE "vin|csi|imx219"

# overlay 是否叠加成功：期望输出 okay
tr -d '\0' < /proc/device-tree/soc@3000000/vind@5800800/csi@5821000/status
```

抓取一帧确认出图（可选，需要 `v4l-utils`）：

```bash
sudo apt install v4l-utils
v4l2-ctl --list-devices                 # 找到相机对应的采集节点
v4l2-ctl -d /dev/video0 --list-formats-ext                       # 确认该节点支持的格式与分辨率
v4l2-ctl -d /dev/video0 --stream-mmap --stream-count=1 --stream-to=frame.raw
```

判断顺序建议：`status` 中 `csi1 = okay` 且 `sensor0_mname` 与所用相机一致 → 再看 `/dev/media*` 与 `v4l2-ctl` 能否枚举到格式 → 最后核对画面颜色（颜色相关的是 `isp/` 的用户态库）。

## 卸载 / 回滚

```bash
# 停用（保留 dtbo 文件）：不带参数 = 清空所有相机条目
sudo ./install-camera-overlays.sh disable imx219
sudo reboot

# 完全卸载：停用 + 删除 /boot/overlay-user/ 下的 dtbo 与目录
sudo ./install-camera-overlays.sh uninstall
sudo reboot
```

- `disable` 会从 `armbianEnv.txt` 的 `user_overlays` 中移除对应相机，并删除 `/etc/modules-load.d/camera-<相机>.conf`；dtbo 文件保留，重启后回到"未启用"状态。
- `uninstall` = `disable`（全部）+ 删除 dtbo 文件与空的 `/boot/overlay-user/` 目录。
- 手工回滚：把 `/boot/armbianEnv.txt.bak-<时间戳>` 覆盖回 `armbianEnv.txt`，删除 `/boot/overlay-user/sun60i-a733-camera-*.dtbo` 与 `/etc/modules-load.d/camera-*.conf`，然后重启。
- 回滚相机不影响系统其余部分：overlay 只在启用时叠加，删除后开机使用厂商默认设备树。

## 组件来源

| 内容 | 来源 |
|---|---|
| 三份 overlay 源码（`.dts`） | 由 **Radxa 官方 Cubie A7S 镜像内的设备树 overlay**（`/boot/dtbo/cubie-a7a-radxa-camera-8m-219.dtbo`、`-13m-214`、`-4k-415`）转写为源码，并按 Armbian 的加载方式（`/boot/overlay-user/` + `armbianEnv.txt` 的 `user_overlays=`）适配 |
| `install-camera-overlays.sh` | 本仓库自行编写 |
| `isp/`（ISP 与 cedarc 用户态） | Radxa `allwinner-debian` 仓库的官方 deb 包，详见 [`isp/README.md`](isp/README.md) |
