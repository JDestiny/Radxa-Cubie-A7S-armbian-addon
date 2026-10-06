# GPU 组件出处

| 内容 | 出处 |
|---|---|
| userspace/ (EGL/GLES/Vulkan libVK_IMG/OpenCL/ICD + rgx.fw/sh 固件, IMG 闭源) | Radxa Cubie A7S 官方 bullseye r6 镜像 rootfs 提取 — https://docs.radxa.com/en/cubie/a7s/download (`radxa-a733_bullseye_kde_r6.output_512.img.xz`, 本地 images/) |
| img-bxm-dkms-src/ (pvrsrvkm 内核驱动, IMG GPL v2, 47万行) | 同上 r6 镜像内 DKMS 包 (packages/bsp, img-bxm-dkms 0.1.0-3) 源码提取 |
| install-gpu-userspace.sh / install-gpu-driver-stock.sh / install-gpu-driver-gpuacct.sh / test/ | 本工作自研 (2026-09-07 建立; 2026-09-15 按"用户态 / 原版驱动 / V6 驱动"拆成三个独立脚本) |
