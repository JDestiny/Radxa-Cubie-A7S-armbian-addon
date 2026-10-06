# 相机 ISP / cedarc 用户态栈（B 类，`camera/isp/`）

> 落地日期 **2026-09-19**；目标机 = Cubie A7S（Armbian 26.11 trixie，内核 `6.6.98-vendor-sun60iw2`）。
> 依据 = Radxa 官方 issue **#19**（A7S + IMX415 能出图但偏色）、**#35**（VE 编码）与官方 deb 包。

## 一、为什么必须装

**内核驱动 + overlay 只负责"出图"，颜色对不对取决于用户态 `libisp_ini.so` 里有没有该 sensor 的 tuning 档。**

- 官方 bullseye 镜像缺 **IMX415** 档 → ISP 回退用 `ov13850` 的档做白平衡 → **红/品红偏色**（issue #19）。
- 官方 **1.0.1** 版已含该档；本机此前**三个 `.so` 一个都没有**（内核侧齐全、用户态全空）。

判定是否含档（脚本 `--status` 自动做）：

```bash
strings -a /usr/lib/aarch64-linux-gnu/libisp_ini.so | grep -c imx415    # 期望 ≥1
```

本机实测：`imx415` **14** 次、`imx214` 21 次、`imx219` 14 次、`ov13850` 21 次 → ✅ 含 IMX415 档。

## 二、装了什么（包内路径，已核对，非推测）

两个 deb 已放进 **`isp/pkgs/`**（共 1.3 MB，**< 2 MB 故直接入仓库**，可离线安装；脚本仍支持缺失时按 URL+sha256 自动下载）。

| 包（内部版本） | 文件名 | 大小 | sha256（前 16 位） | 来源 |
|---|---|---|---|---|
| `libAWIspApi-isp-602-arm64` **1.0.1** | `libAWIspApi_602_1.0.0_arm64.deb` | 356,884 B | `112012255a3f3e7d` | `github.com/radxa/allwinner-debian` → `packages/arm64/libAWIspApi/` |
| `libcedarc-dev-2.0.0-arm64` **1.0.7** | `libcedarc-dev_2.0.0_arm64.deb` | 954,640 B | `ccd5da2403837f1c` | 同仓库 → `packages/arm64/libcedarc/` |

> ⚠️ 文件名里的版本（`_602_1.0.0_` / `_2.0.0_`）与包内 `Version:` 字段（**1.0.1** / **1.0.7**）不同 —— 认包内字段。
> 两个包的 `postinst`/`postrm` 都是**空壳**（只 echo），**不会自己跑 `ldconfig`** → 本脚本显式执行。

**落到系统里的文件**（`--status` 会逐项显示）：

| 来源包 | 路径 | 说明 |
|---|---|---|
| libAWIspApi | `/usr/lib/aarch64-linux-gnu/libisp_ini.so`（2,236,632 B） | **调色参数库**（本项核心） |
| libAWIspApi | `/usr/lib/aarch64-linux-gnu/libisp.so`（3,699,408 B） | ISP 主库 |
| libAWIspApi | `/usr/lib/aarch64-linux-gnu/libAWIspApi.so`（67,696 B） | ISP API |
| libAWIspApi | `/usr/include/{AWIspApi.h,sunxi_camera_v2.h}`、`/usr/bin/AWISPdemo` | 头文件与演示程序 |
| libcedarc | 12 个**新增**库（`libvencoder/libvenc_codec/libvenc_base/libawmpeg4*/libvp8/libvp9HwAL/libscaledown` …） | 原 B6 未覆盖的解码/编码库 |
| libcedarc | `/usr/bin/{vdecoderdemo,vencoderdemo}`、`/usr/include/*.h` | 编解码 demo 与头文件 |
| libcedarc | `/etc/cedarc.conf` | 与本机**逐字节相同**（B6 已装）故跳过 |

## 三、怎么用

```bash
cd /home/radxa/armbian
sudo ./B-安装后配置/camera/isp/install-isp-userspace.sh install      # 默认：ISP 三件套 + cedarc 新增项
sudo ./B-安装后配置/camera/isp/install-isp-userspace.sh --status     # 只读检查
sudo ./B-安装后配置/camera/isp/install-isp-userspace.sh --uninstall  # 按 manifest 卸载（并还原备份）
```

可选参数：

| 参数 | 作用 |
|---|---|
| `install --isp-only` | 只装 ISP 三件套（不动任何 cedarc 库；只想修偏色时用这个） |
| `install --force` | 允许覆盖已存在且内容不同的文件（**先备份**到 `/var/backups/camera-isp/<时间戳>/`） |

## 四、与 B6 VE 硬解栈的关系（安全策略）

`libcedarc-dev` 里有 29 个库，与本机现状比对结果是：**12 个新增 / 15 个逐字节相同 / 3 个同名但不同**：

| 文件 | 本机（B6 已验证） | 包内 1.0.7 |
|---|---|---|
| `libOmxCore.so` | 61,560 B | 61,752 B |
| `libOmxVdec.so` | 257,504 B | 255,904 B |
| `libOmxVenc.so` | 200,936 B | 215,296 B |

这 3 个属于**已验证可用**的 B6 VE 硬解栈（H.264 全片解码 / HEVC P010），所以脚本**默认跳过它们**（输出 `[WARN] … 跳过（未覆盖）`），
只装新增项。确需覆盖时用 `--force`（会先备份）。→ **装完 B6 能力不受影响**（已复核 `libvdecoder/libVE/libMemAdapter/libawh264/libawh265` 均为原字节数）。

## 五、快速判成功

```bash
sudo ./B-安装后配置/camera/isp/install-isp-userspace.sh --status
```

期望看到（本机实测）：

```
 ── 1. ISP 三件套 ──
   libisp_ini.so      ✅  2236632 字节  md5 ce1f1e1e
   libisp.so          ✅  3699408 字节  md5 4751ac1d
   libAWIspApi.so     ✅    67696 字节  md5 540489d0
 ── 2. libisp_ini.so 是否含 IMX415 tuning 档 ──
   imx415 出现次数: 14  ✅ 含该档（偏色问题可解）
 ── 4. 动态链接器能否解析（ldconfig） ──
   ldconfig -p 命中 ISP 库: 3/3
   ✅ libAWIspApi.so 依赖全部解析（libisp.so / libisp_ini.so 已就位）
 ── 结论 ──
   ✅ 用户态栈已就位
```

独立复核（不经脚本）：

```bash
ldconfig -p | grep -E "libisp|libAWIspApi"    # 3 条
ldd /usr/lib/aarch64-linux-gnu/libAWIspApi.so # 无 "not found"
strings -a /usr/lib/aarch64-linux-gnu/libisp_ini.so | grep -c imx415   # 14
```

## 六、依赖（`ldd` 实测）

| 对象 | 结果 |
|---|---|
| `libisp_ini.so` / `libisp.so` | 只依赖 `libc` + `ld-linux` → **无外部前置** |
| `libAWIspApi.so` | 依赖 `libisp.so` + `libisp_ini.so`（同包，装完 `ldconfig` 即解析） |
| `AWISPdemo` | 依赖上述三个 ISP 库（现已全部解析 ✅） |
| `vencoderdemo` | 依赖新增的 `libvencoder/libvenc_codec/libvenc_base` + 已有 `libVE/libMemAdapter/libcdc_base` → 现无未解析项 ✅ |

**结论：无需要额外 apt 安装的依赖。**

## 七、卸载

```bash
sudo ./B-安装后配置/camera/isp/install-isp-userspace.sh --uninstall
```

按 `/var/lib/camera-isp/manifest.txt`（记录本次装的 6 条路径）删除，并还原 `/var/backups/camera-isp/` 里的备份，最后跑 `ldconfig`。
**B6 原有的 VE 库不会被删**（它们不在 manifest 里）。

## 八、未验证 / 风险（如实声明）

| # | 项 | 说明 |
|---|---|---|
| 1 | **无相机实物** | 本轮只验证到"库就位 + 依赖解析 + 含 IMX415 档"；**无法验证出图与色彩**。真正验收需插上相机后按 `B-安装后配置/README.md §10.6` 采集 |
| 2 | ISP 通路还需内核侧配合 | 需要 A 类 `0012`（`vind0` 供电）+ B12 overlay；库只是**用户态前提**。⚠️ **2026-09-21 更新**：相机只支持 **IMX219**（驱动编得出来的唯一官方款）——IMX214/IMX415 的 `0017`/`0018` **已退役**（驱动未适配 6.6）。库里的 imx214/imx415 tuning 档保留，供日后移植后使用 |
| 3 | 三个 Omx 库仍是 B6 版本 | 属**有意行为**（默认不覆盖已验证的 VE 栈）。若要试 1.0.7 版：`install --force`，回退用备份目录 |
| 4 | `vencoderdemo` 能否真编码**未验证** | 与 issue #35 同题（编码高度须为 16 的倍数 → 用 **1088** 而非 1080）；属另一课题（B 类候选 B4） |
| 5 | ABI 兼容性来自比对而非实跑 | deb 头 vs 内核 `bsp/include/media/sunxi_camera_v2.h` 的 30 个 `VIDIOC_*` 编号 0 处不符；但**未在真机跑过完整采集** |
