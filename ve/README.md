# VE 视频编解码用户态栈（`ve/`）

Cubie A7S（全志 A733 / sun60iw2p1）在 Armbian 下的 VE（Video Engine，视频编解码引擎）用户态组件、开发头文件与配套演示程序。

## 功能

| 内容 | 说明 |
|---|---|
| `usr-lib/`（18 个库） | 全志闭源视频编解码库：解码框架 `libvdecoder` / `libvideoengine` / `libVE`；内存与缓冲管理 `libMemAdapter` / `libsbm` / `libfbm`；公共基础库 `libcdc_base`；格式解码插件 `libawh264` / `libawh265` / `libawmjpeg` / `libawmjpegplus` / `libawavs` / `libawavs2` / `libawmpeg2`；OpenMAX 组件 `libOmxCore` / `libOmxVdec` / `libOmxVenc`；以及 `libvdecVcs` |
| `include/`（12 个头文件） | 开发头文件：`vdecoder.h`、`vencoder.h`、`vbasetype.h`、`veInterface.h`、`veAdapter.h`、`memoryAdapter.h`、`sc_interface.h`、`sdecoder.h`、`cdc_config.h`、`typedef.h`、`vencoder_platform_v1.h`、`vencoder_platform_v2.h` |
| `cedarc.conf` | 编解码库运行配置（日志级别、调试与落盘开关、4K 缩放等），安装到 `/etc/cedarc.conf` |
| 演示程序 | `cedar_smoke`（单次提交解码）、`cedar_seg`（长码流分段解码）、`cedar_stdin`（管道流式解码）、`vd_dump`（解码并导出 YUV），均带 `.c` 源码；`venc-smoke.sh`（硬件 H.264 编码快速验证） |
| `install-ve.sh` | 安装脚本：装库 / 头文件 / 配置，并在结束时自检 |

支持的硬件解码通路覆盖 H.264、HEVC、MJPEG、AVS / AVS2、MPEG-2 等常见格式；硬件编码由 `libvencoder` 系列提供（见 `../camera/isp/`）。

**内核提供设备节点，本目录只提供用户态。** 解码走 `/dev/cedar_dev`，编码走 `/dev/cedar_dev_ve2`，二者由内核 VE 驱动创建，不属于本目录的安装范围。安装用户态文件后**不需要重启**，刷新动态链接器缓存即可生效。

## 前置条件

- **硬件 / 系统**：Radxa Cubie A7S，Armbian（aarch64），内核 `6.6.98-vendor-sun60iw2`。
- **内核侧**：VE 驱动已就绪，存在 `/dev/cedar_dev`（解码）与 `/dev/cedar_dev_ve2`（编码）设备节点；可执行 `lsmod | grep sunxi_ve` 确认模块已加载。
- **权限**：安装与卸载需要 root（`sudo`）。
- **可选依赖**：
  - 重新编译演示程序需要 `gcc`（头文件安装到 `/usr/include/` 后即可直接编译）。
  - `venc-smoke.sh` 需要 `python3`，并依赖 `/usr/bin/vencoderdemo`（由 `../camera/isp/` 的 `libcedarc-dev` 包提供）。
- **测试素材**：演示程序读取 Annex-B 裸流（`.h264` / `.h265`），可从任意 mp4/mkv 转换，例如
  `ffmpeg -i input.mp4 -c copy -bsf:v h264_mp4toannexb -f h264 input.h264`。

## 安装

```bash
cd radxa-cubie-a7s-armbian-addon/ve
sudo ./install-ve.sh              # 安装 / 更新（默认动作，可重复执行）
sudo ./install-ve.sh --status     # 只读检查当前状态（无需 root）
sudo ./install-ve.sh --force      # 同名不同版本时覆盖（覆盖前先备份）
sudo ./install-ve.sh --uninstall  # 按 manifest 卸载本脚本安装的文件
./install-ve.sh --help            # 帮助
```

安装位置：

| 源 | 目标 | 权限 |
|---|---|---|
| `usr-lib/*.so*` | `/usr/lib/aarch64-linux-gnu/` | `0755` |
| `include/*.h` | `/usr/include/` | `0644` |
| `cedarc.conf` | `/etc/cedarc.conf` | `0644` |

脚本行为：

- **幂等**：目标已存在且与仓库内文件逐字节相同 → 不改动，直接跳过；重复执行不会产生副作用。
- **不覆盖同名不同版本**：目标已存在但内容不同 → 默认跳过并打印双方大小与 md5 摘要；确需替换时用 `--force`，原文件先备份到 `/var/backups/ve/<时间戳>/`。
- 安装清单写入 `/var/lib/ve/manifest.txt`，只记录本脚本实际写入的路径。
- 结束时自动执行 `ldconfig`，并自检：全部库能否被动态链接器解析、演示程序 `cedar_smoke` 的关键依赖能否解析，最后打印安装项统计与结论。

## 验证

### 1. 安装脚本自检

安装结束会输出统计与结论，例如：

```
  ldconfig -p 可解析的库: 18/18
  ldd cedar_smoke: 关键库解析 4/4，未解析依赖 0 项
 ── 结论 ──
   ✅ 安装完成：18/18 个库可被动态链接器解析，演示程序关键依赖 4/4 解析正常。
```

随时可用 `sudo ./install-ve.sh --status` 复查（逐库列出大小与 md5，并显示内核侧设备节点状态）。

### 2. 独立复核

```bash
ldconfig -p | grep -E "libvdecoder|libVE\.so|libMemAdapter"      # 应有对应条目
ldd ./cedar_smoke                                                 # 不应出现 "not found"
ls -l /dev/cedar_dev /dev/cedar_dev_ve2                           # 内核设备节点
```

### 3. 运行演示程序

```bash
cd radxa-cubie-a7s-armbian-addon/ve

# 短码流：一次整流提交
sudo ./cedar_smoke <H.264 裸流文件> [codec=0x115] [pixfmt=6]

# 长码流：按 NAL 边界分段提交
sudo ./cedar_seg <H.264 裸流文件> [codec=0x115] [segMB=4]

# 管道 / 网络流式解码，不落盘
ffmpeg -i input.mkv -map 0:v:0 -c copy -bsf:v hevc_mp4toannexb -f hevc pipe:1 \
  | sudo ./cedar_stdin 0x116 22 4

# 解码并导出 YUV，用于核对画面
sudo ./vd_dump <H.264 裸流文件> out.yuv [codec=0x115] [帧数=10]

# 硬件 H.264 编码（需要 /usr/bin/vencoderdemo）
sudo ./venc-smoke.sh [宽x高]      # 默认 1920x1088
```

参数约定：

| 参数 | 取值 |
|---|---|
| `codec` | `0x115` = H.264，`0x116` = HEVC |
| `pixfmt` | `6` = NV12（8bit），`22` = P010_UV（10bit） |

### 4. 从源码编译演示程序

```bash
cd radxa-cubie-a7s-armbian-addon/ve
gcc -O2 -o cedar_smoke cedar_smoke.c -lvdecoder -lMemAdapter -lVE -lvideoengine -lcdc_base -lfbm -lsbm -ldl
gcc -O2 -o cedar_seg   cedar_seg.c   -lvdecoder -lMemAdapter -lVE -lvideoengine -lcdc_base -lfbm -lsbm -lvdecVcs -ldl
gcc -O2 -o cedar_stdin cedar_stdin.c -lvdecoder -lMemAdapter -lVE -lvideoengine -lcdc_base -lfbm -lsbm -lvdecVcs -ldl
gcc -O2 -o vd_dump     vd_dump.c     -lvdecoder -lvdecVcs -lMemAdapter -lVE -lvideoengine -lcdc_base -lfbm -lsbm -ldl
```

### 5. 使用注意

- 解码器输入缓冲（SBM）约 8MB，**长码流必须分段提交**；`cedar_seg` 与 `cedar_stdin` 已内置按 NAL 边界切段，直接使用即可。
- **解码过程中不要用信号强杀进程**；若 VE 出现异常状态（例如解码速率明显异常），可重新加载驱动恢复：`sudo modprobe -r sunxi_ve && sudo modprobe sunxi_ve`。

## 卸载 / 回滚

```bash
sudo ./install-ve.sh --uninstall
```

脚本按 `/var/lib/ve/manifest.txt` 删除本脚本安装的文件；若此前用 `--force` 覆盖过文件，会把 `/var/backups/ve/<时间戳>/` 中最新的备份还原回原路径，最后执行 `ldconfig` 并清理清单。**清单之外的文件不受影响**（例如由 `../camera/isp/` 安装的同名文件）。

手工回滚（不使用脚本时）：

```bash
sudo rm -f /usr/lib/aarch64-linux-gnu/libawh264.so    # 按需逐个删除本目录装过的库
sudo rm -f /usr/include/vdecoder.h                    # 按需删除头文件
sudo rm -f /etc/cedarc.conf
sudo ldconfig
```

若系统原本就带有相同的库，删除后按发行版方式重新安装即可恢复；`--status` 的逐库列表与 manifest 可用于核对删除范围。

## 组件来源

| 内容 | 来源 |
|---|---|
| `usr-lib/`（18 个库）、`include/`（12 个头文件）、`cedarc.conf` | 提取自 **Radxa 官方 Cubie A7S 镜像的 rootfs**（`radxa-a733` bullseye r6 镜像中的 `/usr/lib/aarch64-linux-gnu/`、`/usr/include/`、`/etc/cedarc.conf`）；与 Radxa `allwinner-debian` 仓库的 `libcedarc` 系列 deb 同源，其中 `libOmxCore.so` / `libOmxVdec.so` / `libOmxVenc.so` 三个库的版本与 deb 包内不同 |
| `cedar_smoke.c`、`cedar_seg.c`、`cedar_stdin.c`、`vd_dump.c`、`venc-smoke.sh`、`install-ve.sh` | 本仓库自行编写，调用上表中的闭源库 |
| 库与头文件的著作权 | 归全志科技 / Radxa 原厂所有，随官方镜像分发 |
