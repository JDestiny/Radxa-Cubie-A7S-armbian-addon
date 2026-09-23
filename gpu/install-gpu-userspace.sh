#!/bin/bash
# SPDX-License-Identifier: MIT
# Cubie A7S GPU 用户态安装脚本：用户态库 / 固件 / ICD / 运行期依赖 + 三项渲染自检
#
# 用法:
#   sudo ./install-gpu-userspace.sh            # 装用户态并自检（不碰内核驱动）
#   sudo ./install-gpu-userspace.sh --help
#
# 职责边界（2026-09-15 拆分后，三个脚本互相独立）:
#   install-gpu-userspace.sh     = 用户态库/固件/ICD/依赖 + vulkaninfo/GLES/OpenCL 三项自检，**不安装也不切换驱动**
#   install-gpu-driver-stock.sh  = 只装**原版**驱动（Radxa r6 原封不动，DKMS 持久化）
#   install-gpu-driver-gpuacct.sh     = 只装 **V6 记账补丁版**驱动（DKMS 持久化，htop 能看到 GPU）
set -e
BASE="$(dirname "$(readlink -f "$0")")"
KVER="$(uname -r)"
FAIL=0

case "${1:-}" in
    -h|--help) awk 'NR>1 && /^#/ {print; next} NR>1 {exit}' "$0"; exit 0 ;;
    "") ;;
    *) echo "未知参数: $1  (本脚本无参数；驱动请用 install-gpu-driver-stock.sh / install-gpu-driver-gpuacct.sh)"; exit 2 ;;
esac

# ---------- 只读提示：当前驱动状态（驱动的安装/切换由另外两个脚本负责） ----------
loaded_variant() { lsmod | grep -q "^pvrsrvkm " || { echo none; return; }; grep -qw PVRGpuAcctKick /proc/kallsyms 2>/dev/null && echo gpuacct || echo stock; }
disk_variant()   { local ko="/lib/modules/$KVER/updates/dkms/pvrsrvkm.ko"; [ -f "$ko" ] || { echo none; return; }; grep -qa PVRGpuAcctKick "$ko" && echo gpuacct || echo stock; }

echo "=============================================="
echo " [0/4] 当前驱动状态（只读；驱动安装/切换请用另外两个脚本）"
echo "=============================================="
echo "  已加载模块 : $(loaded_variant)   磁盘 ko(=重启后加载谁): $(disk_variant)"
case "$(loaded_variant)" in
    gpuacct) echo "  [OK]   V6 记账补丁版在跑 → htop 的 GPU 表头/进程 GPU% 列可用" ;;
    stock)   echo "  [..]   原版驱动在跑 → htop 看不到 GPU 数据；要 htop 可用请跑 ./install-gpu-driver-gpuacct.sh" ;;
    none)    echo "  [WARN] 驱动未加载：用户态装了也用不了 → 先跑 ./install-gpu-driver-stock.sh 或 ./install-gpu-driver-gpuacct.sh" ;;
esac

echo "=============================================="
echo " [1/4] 安装用户态库 + 固件"
echo "=============================================="
# 运行期依赖 (幂等): GLES 需 libxcb-dri2, Vulkan/OpenCL 需 ICD loader 与工具
if ! dpkg -s libxcb-dri2-0 libvulkan1 ocl-icd-libopencl1 >/dev/null 2>&1; then
    echo "  [..] 安装运行期依赖 (libxcb-dri2-0/libvulkan1/ocl-icd-libopencl1)..."
    apt-get install -y libxcb-dri2-0 libvulkan1 ocl-icd-libopencl1 \
        vulkan-tools clinfo 2>/dev/null || true
fi
US="$BASE/userspace"
# 主库 -> /usr/local/lib
cp -a "$US"/libEGL* "$US"/libGLES* "$US"/libgbm* "$US"/libglapi* \
      "$US"/libvulkan* "$US"/libpvr_mesa_wsi.so /usr/local/lib/ 2>/dev/null || true
mkdir -p /usr/local/lib/dri
cp -a "$US"/dri/* /usr/local/lib/dri/ 2>/dev/null || true
# PVR 核心库 -> /usr/lib
cp -a "$US"/usr-lib/* /usr/lib/ 2>/dev/null || true
# 固件
cp -a "$US"/rgx.fw.* "$US"/rgx.sh.* /lib/firmware/ 2>/dev/null || true
# Vulkan ICD
mkdir -p /usr/share/vulkan/icd.d
cp -a "$US"/img_icd.json /usr/share/vulkan/icd.d/
# OpenCL ICD
mkdir -p /etc/OpenCL/vendors
echo "libPVROCL.so.1" > /etc/OpenCL/vendors/img.icd
# ld.so.conf + 开机自动加载
cp -a "$US"/00_xserver-xorg-img-bxm.conf /etc/ld.so.conf.d/ 2>/dev/null || \
  echo "/usr/local/lib" > /etc/ld.so.conf.d/00_xserver-xorg-img-bxm.conf
mkdir -p /etc/modules-load.d
echo "pvrsrvkm" > /etc/modules-load.d/pvr.conf
# DRI 驱动
mkdir -p /usr/lib/aarch64-linux-gnu/dri
for d in pvr_dri.so sunxi-drm_dri.so swrast_dri.so; do
  [ -f "/usr/local/lib/dri/$d" ] && cp -a "/usr/local/lib/dri/$d" /usr/lib/aarch64-linux-gnu/dri/
done
ldconfig
echo "  [OK] 用户态安装完成"

echo "=============================================="
echo " [2/4] 验证 Vulkan"
echo "=============================================="
if command -v vulkaninfo >/dev/null; then
    if vulkaninfo --summary 2>/dev/null | grep -q "BXM-4-64"; then
        echo "  [OK] Vulkan: PowerVR B-Series BXM-4-64 MC1"
    else
        echo "  [FAIL] vulkaninfo 未识别 GPU"; FAIL=1
    fi
else
    echo "  [..] vulkan-tools 未安装, 跳过 (可 apt install vulkan-tools)"
fi

echo "=============================================="
echo " [3/4] 验证 OpenGL ES 渲染 (egl_render)"
echo "=============================================="
if [ -x "$BASE/test/egl_render" ]; then
    OUT="$("$BASE/test/egl_render" 2>&1)"
    if echo "$OUT" | grep -q "255,0,0,255"; then
        echo "  [OK] GLES 渲染: 红色三角形像素正确 ($(echo "$OUT" | grep 'center'))"
    else
        echo "  [FAIL] GLES 渲染异常:"; echo "$OUT" | tail -4; FAIL=1
    fi
else
    echo "  [..] egl_render 缺失, 跳过"
fi

echo "=============================================="
echo " [4/4] 验证 OpenCL (ocl_test)"
echo "=============================================="
if [ -x "$BASE/test/ocl_test" ]; then
    if "$BASE/test/ocl_test" 2>&1 | grep -q "PASS"; then
        echo "  [OK] OpenCL 向量加法 PASS"
    else
        echo "  [FAIL] OpenCL 测试失败"; FAIL=1
    fi
else
    echo "  [..] ocl_test 缺失, 跳过"
fi

echo "=============================================="
if [ "$FAIL" = "0" ]; then
    echo " GPU 用户态安装完成, 三项自检全部通过 ✅"
    case "$(loaded_variant)" in
        gpuacct) echo " 当前驱动: V6 记账补丁版 → htop 的 GPU 表头/进程 GPU% 列可用" ;;
        stock)   echo " 当前驱动: 原版 → htop 看不到 GPU 数据 (要 htop 可用请跑 ./install-gpu-driver-gpuacct.sh)" ;;
        none)    echo " 当前无驱动: 请先跑 ./install-gpu-driver-stock.sh 或 ./install-gpu-driver-gpuacct.sh" ;;
    esac
else
    echo " 存在失败项, 请检查上述输出 ❌"
fi
echo "=============================================="
exit $FAIL
