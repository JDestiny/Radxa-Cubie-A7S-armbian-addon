# GPU 利用率记账补丁

`gpuacct.patch` 是"原版驱动 → 记账版驱动"的补丁，用于让 `htop` 等工具能按进程看到
GPU 使用率（`drm-engine-*` 记账项）。

## 背景

厂商原版 GPU 内核驱动不向用户态汇报"哪个进程在用 GPU、用了多久"。补丁在驱动的
作业提交路径上加了按进程记账，并把结果通过 DRM 的 `fdinfo` 暴露出来，于是
`htop`（以及任何读 `fdinfo` 的工具）就能显示 GPU 占用。

补丁涉及 5 个文件：

```
services/server/devices/rgxcompute.c
services/server/devices/rgxinit.c
services/server/devices/rgxta3d.c
services/server/devices/rgxtransfer.c
services/server/env/linux/pvr_drm.c
```

## 怎么用

1. 按 [`../../tools/厂商组件获取.md`](../../tools/厂商组件获取.md) 取得原版驱动源码，放在 `gpu/img-bxm-dkms-src/`；
2. 复制一份并打补丁，目录名必须是 `img-bxm-dkms-src-gpuacct`（安装脚本按此名查找）：

```bash
cd gpu
cp -a img-bxm-dkms-src img-bxm-dkms-src-gpuacct
cd img-bxm-dkms-src-gpuacct
patch -p1 --dry-run < ../patches/gpuacct.patch     # 先预演
patch -p1 < ../patches/gpuacct.patch               # 正式应用
```

3. 回到 `gpu/` 运行记账版安装脚本：

```bash
cd .. && sudo ./install-gpu-driver-gpuacct.sh
```

## 说明

- 补丁只改内核驱动（GPL v2），不改用户态；
- **许可**：本补丁按 **GPL-2.0-only** 发布（全文见 [`../../LICENSE-GPL-2.0-only`](../../LICENSE-GPL-2.0-only)）。
  它修改的是 IMG 以 GPL v2 发布的内核驱动源码，属衍生作品，因此必须同为 GPL-2.0；
  本仓库其余部分（脚本、文档、用户态程序）为 MIT，见 [`../../LICENSE`](../../LICENSE)；
- 不想要记账功能就不要打这个补丁，直接 `sudo ./install-gpu-driver-stock.sh` 安装原版驱动；
- 两个变体安装脚本互相排斥（脚本会从 DKMS 树里摘掉另一个），同一时间只装一个。
