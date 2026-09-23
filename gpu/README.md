# gpu —— PowerVR BXM-4-64 GPU：内核驱动 + 用户态

Cubie A7S 的 GPU 是 Imagination **PowerVR BXM-4-64 MC1**。要在 Armbian 上用起来，需要两半：

- **内核驱动** `pvrsrvkm` —— 提供 `/dev/dri/renderD128` 等设备节点；
- **用户态** —— EGL / OpenGL ES / Vulkan / OpenCL 库、GPU 固件（`rgx.fw` / `rgx.sh`）、以及 Vulkan / OpenCL 的 ICD。

本目录把它们拆成**三个互相独立的脚本**加一组自检程序：`install-gpu-userspace.sh` 只装用户态，
两个 `install-gpu-driver-*.sh` 只装内核驱动（**二选一**），三者互不调用。

## 功能

| 文件 | 作用 |
|---|---|
| `install-gpu-userspace.sh` | 用户态：库 / 固件 / ICD / 运行期依赖，装完做 Vulkan、GLES、OpenCL 三项自检；**不安装也不切换驱动** |
| `install-gpu-driver-stock.sh` | 内核驱动**原版**：官方镜像里 DKMS 包的源码原样编译，DKMS 持久化（`img-bxm-dkms/0.1.0-3`） |
| `install-gpu-driver-gpuacct.sh` | 内核驱动**记账补丁版**：原版 + GPU 利用率记账补丁，`htop` 能看到 GPU 使用率（`img-bxm-dkms/0.1.0-3+gpuacct`） |
| `test/` | 自检程序：`egl_render`、`egl_dev_test`、`egl_info`、`ocl_test`（均含对应的 `.c` 源码） |
| `gpu-driver-stability.sh` | 可选：动态负载下的驱动稳定性压测，与安装流程无关（见 [验证](#验证) 末节） |

### 两个驱动变体怎么选

两个脚本装的是**同一个驱动的两份源码**，区别只在"要不要在 `htop` 里看到 GPU 使用率"：

| | `stock`（原版） | `gpuacct`（记账补丁版） |
|---|---|---|
| 源码 | 官方镜像内 DKMS 包，未做任何改动 | 同一份源码 + 本项目的 GPU 利用率记账补丁 |
| DKMS 版本 | `img-bxm-dkms/0.1.0-3` | `img-bxm-dkms/0.1.0-3+gpuacct` |
| 进程 `fdinfo` | 只有显存类键（`drm-memory-*`） | 另有 `drm-client-id`、`drm-driver: pvr`、`drm-engine-pvr: <ns> ns` |
| `htop` 的 GPU 表头 / 进程 GPU% / GPU TIME | 空白 | 可用 |
| 适合 | 只跑标准 GL / Vulkan / OpenCL 程序，不需要看 GPU 占用 | 想在 `htop` 里看谁在用 GPU、用了多少 |

> **`htop` 显示的 GPU% 会大于 100%，属正常**：`htop` 用"距上次读取该进程的 GPU 时间"作分子、
> 用它自己的一个刷新周期作分母，且不做 100% 钳位；驱动输出的纳秒计数本身是单调真值。
> 默认配置下 GPU 列约每 6 秒跳一次（`htop` 对空闲进程有 5 秒扫描门控）。请把它当作趋势，而不是精确百分比。

**两个变体互斥，装一个就行。** 两个脚本在安装时都会把**另一个变体**从 DKMS 树里摘掉，
避免内核升级时两份驱动互相覆盖；因此"切换变体"＝**跑另一个脚本**，不需要手工清理。
装完都是持久的：DKMS（`AUTOINSTALL=yes`，换内核自动重建）+ `/etc/modules-load.d/pvr.conf` 开机按名加载。

## 前置条件

- **板卡 / 系统**：Radxa Cubie A7S（全志 A733 / sun60iw2p1）+ Armbian（内核分支 `6.6.98-vendor-sun60iw2`）。
- **root 权限**：三个脚本都要 `sudo`。
- **内核头文件**：`linux-headers-$(uname -r)` 已安装（脚本会检查，缺失时直接报错）。
- **组件本体已放到位**（本仓库不含这些大目录，见 [组件来源](#组件来源)）：
  - 装原版驱动 → 需要 `gpu/img-bxm-dkms-src/`；
  - 装记账补丁版 → 需要 `gpu/img-bxm-dkms-src-gpuacct/`；
  - 装用户态 → 需要 `gpu/userspace/`。
- **磁盘空间**：驱动源码树会被复制到 `/usr/src/` 后再编译，约 1~2 分钟，建议预留 1 GB 以上。
- **可中断性**：安装驱动会重新加载 `pvrsrvkm`（`modprobe -r` + `modprobe`），正在使用 GPU 的进程会被中断；
  脚本会先提示 `/dev/dri` 是否被占用。
- 想用 `htop` 看 GPU，需要带 GPU 表头的 **`htop` 3.x**（`htop --version` 确认一下版本；自带的 `GpuMeter` 在 F2 里能看到即满足）。
- 脚本需要可执行权限；若从 ZIP 包解压导致权限丢失，先 `chmod +x gpu/*.sh`。

> 只有**用户态脚本**会写 `/etc/modules-load.d/pvr.conf`。如果只装驱动、不装用户态，请自行创建它
> （内容一行 `pvrsrvkm`），否则重启后驱动不会自动加载。

## 安装

三步：取得组件 → 装内核驱动（二选一）→ 装用户态。

### 1. 取得大体积组件

按 [组件来源](#组件来源) 把驱动源码与（或）`userspace/` 放进 `gpu/`：

```bash
cd gpu
ls -d img-bxm-dkms-src img-bxm-dkms-src-gpuacct userspace 2>/dev/null   # 看哪些已就位
```

### 2. 装内核驱动（二选一）

```bash
# 想用 htop 看 GPU 使用率（推荐）：
sudo ./install-gpu-driver-gpuacct.sh

# 或者：保持原版驱动
sudo ./install-gpu-driver-stock.sh
```

脚本按 `[0/5] 前置检查 → [1/5] 检查 GPU 占用 → [2/5] 暂存源码到 /usr/src → [3/5] DKMS 构建安装 → [4/5] 重载模块 → [5/5] 校验` 执行：

- 源码树复制到 `/usr/src/img-bxm-dkms-<版本>/`，树内指向本仓库的绝对软链接会被改写为相对链接，
  因此之后移动或删除本仓库不影响 DKMS 构建与换内核重建；
- **构建失败不会动正在运行的模块**，系统仍用原来的驱动；错误日志在
  `/tmp/dkms-gpu-install-stock.log` 或 `/tmp/dkms-gpu-install-gpuacct.log`；
- `[5/5]` 校验三处状态一致：**运行中的模块 = `/lib/modules/$(uname -r)/updates/dkms/pvrsrvkm.ko`
  （重启后会加载的那份）= DKMS 里登记的版本**。

### 3. 装用户态

```bash
sudo ./install-gpu-userspace.sh
```

脚本会先装缺失的运行期依赖（`libxcb-dri2-0`、`libvulkan1`、`ocl-icd-libopencl1`，以及 `vulkan-tools`、`clinfo`），
再把 `userspace/` 铺到系统里（都落在 `/usr/local`、`/usr/lib`、`/lib/firmware`；
唯一会写到发行版目录的是 `/usr/lib/aarch64-linux-gnu/dri/` 下的三个 DRI 驱动，见下表）：

| 来源（`gpu/userspace/`） | 安装到 | 说明 |
|---|---|---|
| `libEGL*` `libGLES*` `libgbm*` `libglapi*` `libvulkan*` `libpvr_mesa_wsi.so` | `/usr/local/lib/` | 图形与 Vulkan 入口库 |
| `dri/` | `/usr/local/lib/dri/`，并把 `pvr_dri.so`、`sunxi-drm_dri.so`、`swrast_dri.so` 复制到 `/usr/lib/aarch64-linux-gnu/dri/` | DRI 驱动 |
| `usr-lib/` | `/usr/lib/` | PVR 核心库（含 `libPVROCL.so.1`） |
| `rgx.fw.*`、`rgx.sh.*` | `/lib/firmware/` | GPU 固件 |
| `img_icd.json` | `/usr/share/vulkan/icd.d/` | Vulkan ICD |
| `00_xserver-xorg-img-bxm.conf` | `/etc/ld.so.conf.d/` | 动态库搜索路径 |
| —（脚本生成） | `/etc/OpenCL/vendors/img.icd` | OpenCL ICD，内容为一行 `libPVROCL.so.1` |
| —（脚本生成） | `/etc/modules-load.d/pvr.conf` | 开机按名加载 `pvrsrvkm` |

最后执行 `ldconfig`，并依次做 Vulkan、GLES、OpenCL 三项自检。

> 用户态与内核驱动**互相独立**，先装哪个都行；但只有驱动已加载时用户态才有意义。
> 若 `userspace/` 缺失，脚本不会立刻报错，而是三项自检全部失败 —— 先确认目录已就位再运行。

### 常用参数

| 命令 | 作用 |
|---|---|
| `sudo ./install-gpu-driver-*.sh` | 安装 / 重装（总是重新编译） |
| `sudo ./install-gpu-driver-*.sh --status` | 只读：已加载的变体、DKMS 中已装版本、磁盘上的 `ko`（＝重启后会加载哪个）、开机加载配置 |
| `sudo ./install-gpu-driver-*.sh --reload` | 只重载模块，不重装 |
| `sudo ./install-gpu-driver-*.sh --help` | 用法说明 |
| `sudo ./install-gpu-userspace.sh` | 装用户态并自检（该脚本没有其它参数） |

## 验证

```bash
cd /path/to/radxa-cubie-a7s-armbian-addon/gpu

# 1) 驱动三处状态一致（装的是哪版就用哪个脚本查）
sudo ./install-gpu-driver-gpuacct.sh --status

# 2) 模块与设备节点
lsmod | grep '^pvrsrvkm'
ls -l /dev/dri/                       # 应有 renderD128

# 3) DKMS 与"重启后会加载谁"
dkms status | grep img-bxm
modinfo -n pvrsrvkm                   # 应指向 /lib/modules/$(uname -r)/updates/dkms/pvrsrvkm.ko

# 4) 当前运行的是哪个变体
grep -qw PVRGpuAcctKick /proc/kallsyms && echo "记账补丁版" || echo "原版"
```

用户态三栈（安装脚本已自动跑一遍，也可手工复现）：

```bash
vulkaninfo --summary | grep BXM-4-64   # Vulkan：应出现 PowerVR B-Series BXM-4-64 MC1
./test/egl_render                      # GLES 实渲染：读回的中心像素应为 255,0,0,255
./test/egl_dev_test                    # EGL_EXT_platform_device + /dev/dri/renderD128
./test/egl_info                        # EGL 厂商与扩展信息
./test/ocl_test                        # OpenCL 向量加法，成功时输出 PASS（需重新编译时见 test/*.c）
```

`htop` 看 GPU（仅记账补丁版）：

```bash
htop    # F2 → Meters，把 GPU 加到某一列；进程列表里可再加 GPU% / GPU TIME 字段
# 也可以直接确认驱动在往 fdinfo 里记账（<PID> 换成任一正在用 GPU 的进程）：
grep -H drm-engine-pvr /proc/<PID>/fdinfo/*
```

用原版驱动时，`htop` 的 GPU 表头与 GPU 列**本来就是空白**（原版驱动的 `fdinfo` 不输出引擎时间），不是装坏了。

换内核之后：

```bash
sudo ./install-gpu-driver-gpuacct.sh --status   # 三行看清：已加载 / DKMS / 磁盘 ko
sudo dkms autoinstall -k "$(uname -r)"          # 通常 DKMS 钩子会自动重建，无需手工执行
```

### 可选：驱动稳定性压测

`gpu-driver-stability.sh` 会按"GLES → OpenCL → Vulkan → 混合 → 多客户端 → 跨引擎 → 短命客户端 → 空闲"循环加负载，
每 15 秒采样温度、驱动 debugfs 计数器、`dmesg` 错误数与进程 `fdinfo` 记账，结束时打印汇总：

```bash
# 压测工具在 tests/modules/tools/ 下，默认路径不是本仓库，需要显式指定
sudo TOOLS_DIR=/path/to/radxa-cubie-a7s-armbian-addon/tests/modules/tools \
     ./gpu-driver-stability.sh 7200 /var/log/gpu-stability
```

- 参数：总时长秒数（默认 `7200`）、日志目录（默认 `/var/log/gpu-driver-stability-<时间戳>/`）；
- 前置：驱动已加载（要能读 `/sys/kernel/debug/pvr/status`）、`$TOOLS_DIR/gpu/` 下有三个压测程序；
- 负载默认以 `radxa` 用户身份运行（`LOAD_USER` 可改），这样该用户自己的 `htop` 才读得到 `fdinfo`；
- 这是可选的自检手段，不参与安装。

## 卸载 / 回滚

**换回另一个变体**（最常用，不需要先卸载）：

```bash
sudo ./install-gpu-driver-stock.sh       # 回到原版（htop 不再显示 GPU）
sudo ./install-gpu-driver-gpuacct.sh     # 再切回记账补丁版
```

**彻底移除本目录安装的内核驱动**：

```bash
sudo modprobe -r pvrsrvkm
sudo dkms remove img-bxm-dkms/0.1.0-3 --all            # 记账补丁版为 img-bxm-dkms/0.1.0-3+gpuacct
sudo rm -rf /usr/src/img-bxm-dkms-*
sudo rm -f /lib/modules/*/updates/dkms/pvrsrvkm.ko
sudo rm -f /etc/modules-load.d/pvr.conf                # 之后开机不再自动加载
sudo depmod -a
sudo reboot
```

> 移除后系统就没有 GPU 内核驱动了（`/dev/dri/renderD128` 随之消失），用户态库也无法工作。
> 想再装回来，重跑对应的驱动脚本即可。

**回滚用户态**：

```bash
sudo rm -f /usr/local/lib/libEGL* /usr/local/lib/libGLES* /usr/local/lib/libgbm* \
           /usr/local/lib/libglapi* /usr/local/lib/libvulkan* /usr/local/lib/libpvr_mesa_wsi.so
sudo rm -rf /usr/local/lib/dri
sudo rm -f /lib/firmware/rgx.fw.* /lib/firmware/rgx.sh.*
sudo rm -f /usr/share/vulkan/icd.d/img_icd.json /etc/OpenCL/vendors/img.icd
sudo rm -f /etc/ld.so.conf.d/00_xserver-xorg-img-bxm.conf /etc/modules-load.d/pvr.conf
sudo ldconfig
```

- `/usr/lib/` 下的 PVR 核心库（`libPVROCL.so.1` 等）来自厂商包，删除前请确认没有别的程序在用；
  若 `swrast_dri.so` 覆盖了发行版自带的那份，可用 `sudo apt install --reinstall libgl1-mesa-dri` 还原。
- 删除 `/etc/modules-load.d/pvr.conf` 后，重启时不再自动加载驱动；`sudo modprobe pvrsrvkm` 仍可临时加载。
- 压测脚本只往日志目录写文件，直接删除 `/var/log/gpu-driver-stability-*/` 即可。
- 想完全回到出厂状态，也可以重装官方镜像自带的 DKMS 包（`img-bxm-dkms`）与图形库包。

## 组件来源

本仓库**不含**下面三个大目录，请自行取得后放进 `gpu/`（缺失时安装脚本会报错指出缺哪个）：

| 目录 | 体积 | 内容 |
|---|---|---|
| `img-bxm-dkms-src/` | 约 21 MB | GPU 内核驱动源码（原版，来自官方镜像内的 DKMS 包 `img-bxm-dkms` 0.1.0-3，IMG GPL v2） |
| `img-bxm-dkms-src-gpuacct/` | 约 123 MB | 同一份源码 + GPU 利用率记账补丁（由本项目维护，**非官方发布物**） |
| `userspace/` | 约 106 MB | EGL / GLES / Vulkan / OpenCL 库、DRI 驱动、PVR 核心库、`rgx.fw` / `rgx.sh` 固件、ICD 与图形配置（IMG 闭源，随厂商镜像分发） |

### 1. 从官方镜像提取（驱动源码 + 用户态）

官方 Cubie A7S 镜像（Debian bullseye）里同时含 DKMS 驱动源码与完整用户态：

1. 从 Radxa 下载页取得镜像：<https://docs.radxa.com/en/cubie/a7s/download>
   （文件名形如 `radxa-a733_bullseye_kde_r6.output_512.img.xz`，约 500 MB）。
2. 解压、挂载，再按需拷出：

```bash
cd /path/to/radxa-cubie-a7s-armbian-addon          # 下面的目标路径都相对仓库根目录

xz -d radxa-a733_bullseye_kde_r6.output_512.img.xz
sudo losetup -Pf --show radxa-a733_bullseye_kde_r6.output_512.img   # 记下输出的 /dev/loopX
sudo mkdir -p /mnt/r6 && sudo mount -o ro /dev/loopXp2 /mnt/r6       # p2 通常是 rootfs（ext4）

# 内核驱动源码 → gpu/img-bxm-dkms-src/
sudo find /mnt/r6 -maxdepth 6 -name '*img-bxm*' | head               # 先定位 deb 或已安装的源码目录
sudo mkdir -p gpu/img-bxm-dkms-src
sudo cp -a /mnt/r6/usr/src/img-bxm-dkms-*/. gpu/img-bxm-dkms-src/    # 实际路径以 find 结果为准

# 用户态 → gpu/userspace/（布局见下表）
sudo find /mnt/r6 -name 'libGLESv2.so*' -o -name 'libVK_IMG.so*' -o -name 'rgx.fw*' | head

sudo umount /mnt/r6 && sudo losetup -d /dev/loopX
```

驱动源码目录的根部应当**直接包含** `img-bxm/` 与 `dkms.conf`（脚本用 `img-bxm/` 是否存在做前置检查）。
`gpu/userspace/` 的布局需要与 `install-gpu-userspace.sh` 的预期一致：

| 路径 | 内容 |
|---|---|
| `userspace/`（根） | `libEGL*`、`libGLES*`、`libgbm*`、`libglapi*`、`libvulkan*`、`libpvr_mesa_wsi.so`、`rgx.fw.*`、`rgx.sh.*`、`img_icd.json`、`00_xserver-xorg-img-bxm.conf` |
| `userspace/dri/` | `pvr_dri.so`、`sunxi-drm_dri.so`、`swrast_dri.so` |
| `userspace/usr-lib/` | 镜像 `/usr/lib` 下的 PVR 核心库（含 `libPVROCL.so.1`） |

> 镜像版本不同，具体文件名可能略有差异；脚本按上面的布局查找，缺哪一项自检就会指出哪一项。

### 2. 记账补丁版（`img-bxm-dkms-src-gpuacct/`）

它不是官方发布物，而是"原版源码 + 记账补丁"的结果（补丁随本仓库提供，见 `patches/`）。两种取得方式：

- **用本项目的 Release 附件**（若提供）：把打包好的已打补丁源码树解压到 `gpu/img-bxm-dkms-src-gpuacct/`，
  根部同样应直接含 `img-bxm/` 与 `dkms.conf`；
- **自行打补丁**：复制原版目录后应用仓库内的 `patches/gpuacct.patch`（详见 `patches/README.md`）
  （`-p` 级别按补丁内的路径前缀选择）：

```bash
cp -a img-bxm-dkms-src img-bxm-dkms-src-gpuacct
cd img-bxm-dkms-src-gpuacct && patch -p1 < ../patches/gpuacct.patch
```

只装原版驱动的话，**不需要**这个目录。

> 各组件的出处、许可与提取步骤另见 [`../tools/厂商组件获取.md`](../tools/厂商组件获取.md)、[`../THIRD-PARTY.md`](../THIRD-PARTY.md)。
> 驱动源码为 IMG GPL v2；用户态库与固件为 IMG 闭源、随厂商镜像分发，版权归各自权利人。
