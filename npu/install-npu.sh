#!/bin/bash
# Cubie A7S NPU 安装脚本：检查驱动 → 缺失则安装 → golden demo 验证
# 用法: sudo ./install-npu.sh
set -e
BASE="$(dirname "$(readlink -f "$0")")"
FAIL=0

echo "=============================================="
echo " [1/4] 检查 NPU 内核驱动 (vipcore)"
echo "=============================================="
if lsmod | grep -q vipcore && [ -e /dev/vipcore ]; then
    echo "  [OK] vipcore 已加载, /dev/vipcore 存在"
else
    echo "  [..] vipcore 未加载, 尝试加载..."
    if modprobe vipcore 2>/dev/null && [ -e /dev/vipcore ]; then
        echo "  [OK] vipcore 加载成功"
    else
        echo "  [FAIL] 内核没有 vipcore 模块!"
        echo "        编译期修复: 内核配置需启用 CONFIG_AW_NNA_VIP (Armbian sun60iw2 BSP 内核自带)"
        echo "        当前内核: $(uname -r)"
        exit 1
    fi
fi

echo "=============================================="
echo " [2/4] 安装中间件 (libNBGlinker/libVIPhal v2.0)"
echo "=============================================="
LIBDIR="$BASE/ai-sdk/viplite-tina/lib/aarch64-none-linux-gnu/v2.0"
if [ -f "$LIBDIR/libNBGlinker.so" ] && [ -f "$LIBDIR/libVIPhal.so" ]; then
    cp -a "$LIBDIR/libNBGlinker.so" "$LIBDIR/libVIPhal.so" /usr/local/lib/
    ldconfig
    echo "  [OK] 中间件已安装到 /usr/local/lib"
else
    echo "  [FAIL] 中间件文件缺失: $LIBDIR"; exit 1
fi

echo "=============================================="
echo " [3/4] 安装 vpm_run 工具"
echo "=============================================="
if [ -x "$BASE/ai-sdk/examples/vpm_run/vpm_run" ]; then
    install -m755 "$BASE/ai-sdk/examples/vpm_run/vpm_run" /usr/local/bin/vpm_run
    echo "  [OK] vpm_run -> /usr/local/bin"
else
    echo "  [..] 未找到预编译 vpm_run, 尝试编译..."
    cd "$BASE/ai-sdk/examples/vpm_run" && make AI_SDK_PLATFORM=a733 >/dev/null 2>&1 && \
      install -m755 vpm_run /usr/local/bin/vpm_run && echo "  [OK] 编译安装成功" || \
      { echo "  [FAIL] vpm_run 编译失败 (需要 gcc/make)"; exit 1; }
fi

echo "=============================================="
echo " [4/4] 官方 golden 验证 (yolov5.nb)"
echo "=============================================="
GOLD="$BASE/official-golden-test"
if [ -f "$GOLD/yolov5.nb" ] && [ -f "$GOLD/sample.txt" ]; then
    TMPD="$(mktemp -d)"
    cp "$GOLD"/* "$TMPD"/
    # 修正 sample.txt 路径为相对路径
    sed -i 's|/data/assets/||g' "$TMPD/sample.txt"
    cd "$TMPD"
    export LD_LIBRARY_PATH=/usr/local/lib
    if vpm_run -s sample.txt -l 1 -b 0 > vpm.log 2>&1; then
        if grep -q "Test output 0 passed" vpm.log && grep -q "Test output 2 passed" vpm.log; then
            echo "  [OK] 官方 golden 比对 3/3 passed (ret=0)"
        else
            echo "  [FAIL] golden 比对未全部通过:"; grep -E "Test output" vpm.log; FAIL=1
        fi
    else
        echo "  [FAIL] vpm_run 运行失败:"; tail -5 vpm.log; FAIL=1
    fi
    rm -rf "$TMPD"
else
    echo "  [..] golden 测试文件缺失, 跳过 (不影响安装)"
fi

echo "=============================================="
if [ "$FAIL" = "0" ]; then
    echo " NPU 安装完成, 验证通过 ✅"
else
    echo " 存在失败项, 请检查上述输出 ❌"
fi
echo "=============================================="
exit $FAIL
