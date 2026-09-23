# 相机 ISP / cedarc 用户态栈（`camera/isp/`）

Cubie A7S 相机出图与取色所需的用户态库安装：两个官方 deb 包（已随仓库提供，可离线安装）与其安装 / 检查 / 卸载脚本。

## 功能

| 内容 | 说明 |
|---|---|
| `install-isp-userspace.sh` | 安装 / 检查 / 卸载用户态栈；自带 sha256 校验与备份还原 |
| `pkgs/libAWIspApi_602_1.0.0_arm64.deb` | ISP 用户态：调色参数库 `libisp_ini.so`、ISP 主库 `libisp.so`、API 库 `libAWIspApi.so`，以及头文件与演示程序 `AWISPdemo` |
| `pkgs/libcedarc-dev_2.0.0_arm64.deb` | cedarc 库与工具：编码库 `libvencoder` / `libvenc_codec` / `libvenc_base`、解码与 MJPEG / MPEG-4 / VP8 / VP9 等插件、`libscaledown`，以及 `vdecoderdemo` / `vencoderdemo`、头文件与 `/etc/cedarc.conf` |

**为什么必须装 `libisp_ini.so`：内核驱动与设备树 overlay 只负责让相机"出图"，颜色是否正确取决于 `libisp_ini.so` 里有没有该 sensor 的调色（tuning）参数档。** 缺少对应档位时，ISP 会回退使用其它 sensor 的参数，典型表现是画面偏色、白平衡异常。判定库内是否含某个 sensor 的档位，见下方"验证"。

## 前置条件

- **系统**：Armbian（aarch64），内核 `6.6.98-vendor-sun60iw2`。
- **相机通路已就绪**：设备树 overlay 已按 [`../README.md`](../README.md) 安装并启用，且重启后 `csi1` 为 `okay`（**当前系统仅 IMX219 可用**）。
- **权限**：需要 root（`sudo`）。
- **工具**：`dpkg-deb`（dpkg 自带）；若仓库内 deb 缺失，脚本改用 `curl` 从上游按 URL + sha256 下载。
- **无需额外 apt 依赖**：`libisp_ini.so` / `libisp.so` 只依赖 `libc`；`libAWIspApi.so` 依赖同包内的两个 ISP 库，安装后执行 `ldconfig` 即可解析。

## 安装

```bash
cd radxa-cubie-a7s-armbian-addon/camera/isp

# 默认：ISP 三件套 + cedarc 新增项（不覆盖系统已有的同名文件）
sudo ./install-isp-userspace.sh install

# 只装 ISP 三件套（只解决偏色问题、不想改动任何 cedarc 库时使用）
sudo ./install-isp-userspace.sh install --isp-only

# 允许覆盖已存在且内容不同的文件（覆盖前备份到 /var/backups/camera-isp/<时间戳>/）
sudo ./install-isp-userspace.sh install --force

# 只读检查 / 卸载
sudo ./install-isp-userspace.sh --status
sudo ./install-isp-userspace.sh --uninstall
```

安装位置：

| 来源 | 落地路径 |
|---|---|
| `libAWIspApi` | `/usr/lib/aarch64-linux-gnu/{libisp_ini.so, libisp.so, libAWIspApi.so}`、`/usr/include/{AWIspApi.h, sunxi_camera_v2.h}`、`/usr/bin/AWISPdemo` |
| `libcedarc-dev` | `/usr/lib/aarch64-linux-gnu/` 下的 cedarc 库（编码、解码插件、`libscaledown` 等）、`/usr/bin/{vdecoderdemo, vencoderdemo}`、`/usr/include/*.h`、`/etc/cedarc.conf` |

脚本行为：

- **默认不覆盖已有文件**：安装前逐项比较内容（`cmp`），与包内完全相同的文件直接跳过。
- **同名但内容不同**时会跳过并打印告警，避免覆盖系统上已就绪的 VE 编解码库（典型是 `libOmxCore.so` / `libOmxVdec.so` / `libOmxVenc.so`）。确需替换时加 `--force`，脚本会先把原文件备份到 `/var/backups/camera-isp/<时间戳>/`。
- **两个 deb 的 `postinst` 不会执行 `ldconfig`**，脚本在安装结束后显式执行。
- 安装清单写入 `/var/lib/camera-isp/manifest.txt`，卸载时按清单逐项删除。

## 验证

```bash
sudo ./install-isp-userspace.sh --status
```

`--status` 会逐项输出：ISP 三件套是否存在（含大小与 md5）、`libisp_ini.so` 中是否含对应 sensor 的调色档、关键 cedarc 库就位数量、`ldconfig -p` 命中情况、`libAWIspApi.so` 的依赖是否全部解析、manifest 记录，并给出结论。

独立复核（不经脚本）：

```bash
# 三个 ISP 库是否进入链接器缓存：应有 3 条
ldconfig -p | grep -E "libisp\.so|libisp_ini\.so|libAWIspApi\.so"

# 依赖是否全部解析：不应出现 "not found"
ldd /usr/lib/aarch64-linux-gnu/libAWIspApi.so

# libisp_ini.so 是否含某 sensor 的调色档：输出 ≥1 即包含
strings -a /usr/lib/aarch64-linux-gnu/libisp_ini.so | grep -c imx219
strings -a /usr/lib/aarch64-linux-gnu/libisp_ini.so | grep -c imx415
```

说明：`libisp_ini.so` 内含多款 sensor 的调色参数，档位是否"被实际使用"取决于设备树里配置的 `sensor0_mname`（当前系统为 `imx219`）。库内含有某档 ≠ 该相机可用，相机能否使用取决于内核驱动（见 [`../README.md`](../README.md)）。

## 卸载 / 回滚

```bash
sudo ./install-isp-userspace.sh --uninstall
```

- 按 `/var/lib/camera-isp/manifest.txt`（本次安装的路径列表）逐项删除；
- 若此前用 `--force` 覆盖过文件，则从 `/var/backups/camera-isp/<时间戳>/` 还原备份（保留原权限）；
- 最后执行 `ldconfig` 并清理清单目录。

**不在清单中的文件不会被删除**，因此以其它方式（例如本仓库 `ve/install-ve.sh`）安装的同名库不受影响。手工回滚时删除上表中对应路径并执行 `sudo ldconfig` 即可。

## 组件来源

| 包 | 包内版本 | 文件名 | 大小 | sha256 | 来源 |
|---|---|---|---|---|---|
| `libawispapi-isp-602-arm64` | `1.0.1` | `libAWIspApi_602_1.0.0_arm64.deb` | 356,884 B | `112012255a3f3e7d33faa63241dea8b6e3ab081d1ef63c56c0e656e5b5978fc9` | Radxa [`allwinner-debian`](https://github.com/radxa/allwinner-debian) → `packages/arm64/libAWIspApi/` |
| `libcedarc-dev-2.0.0-arm64` | `1.0.7` | `libcedarc-dev_2.0.0_arm64.deb` | 954,640 B | `ccd5da2403837f1c5a566239124eaa66c56b6bbcb485308dd7ad7ec6d8d0d3a4` | Radxa [`allwinner-debian`](https://github.com/radxa/allwinner-debian) → `packages/arm64/libcedarc/` |

- 两个 deb 已随仓库放在 `pkgs/`，可离线安装；脚本在文件缺失或校验失败时按上表 URL 与 sha256 重新下载。
- **注意版本号以包内字段为准**：文件名中的 `_602_1.0.0_` 与 `_2.0.0_` 与包内 `Version:` 字段（`1.0.1` / `1.0.7`）并不一致。
- 库与工具的著作权归全志科技 / Radxa 原厂所有，随官方软件源分发。
