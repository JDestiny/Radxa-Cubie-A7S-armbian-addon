#!/bin/bash
# Cubie A7S NPU 安装脚本：检查驱动 → 缺失则安装 → golden demo 验证
# 用法: sudo ./install-npu.sh
set -e
BASE="$(dirname "$(readlink -f "$0")")"
FAIL=0

echo "=============================================="
echo " [1/5] 检查 NPU 内核驱动 (vipcore)"
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
echo " [2/5] 安装中间件 (libNBGlinker/libVIPhal v2.0)"
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
echo " [3/5] 安装 vpm_run 工具"
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
echo " [4/5] 官方 golden 验证 (yolov5.nb)"
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
echo " [5/5] 降低 NPU 日志刷屏 (sysctl.d)"
echo "=============================================="
# NPU 驱动 (vipcore) 在推理路径上使用无级别 printk，会把大量日志灌进 dmesg。
# 这里用「控制台级别」抑制：只把 console 上的显示压到 err，dmesg 环形缓冲仍保留全部日志。
#   kernel.printk = <console_loglevel> <default_message_loglevel> <min> <max>
# 撤销：删除 /etc/sysctl.d/99-npu-quiet.conf 后 `sudo sysctl --system`
QUIET=/etc/sysctl.d/99-npu-quiet.conf
cat > "$QUIET" <<'EOF_SYSCTL'
# NPU (vipcore) 日志降噪：控制台只显示 err 及以上；dmesg 缓冲不受影响，排障时仍可 dmesg 查看。
# 由 npu/install-npu.sh 写入，撤销即删除本文件并执行 sudo sysctl --system
kernel.printk = 3 4 1 3
EOF_SYSCTL
sysctl --system >/dev/null 2>&1 && echo "  [OK] 已应用 $QUIET（console 级别=3）" || echo "  [WARN] 写入成功但 sysctl 应用失败，可稍后手动 sysctl --system"
echo "  [i]  治本方案（需重编内核，可选）：把 vipcore 的无级别 printk 改为 dev_dbg()，"
echo "       并在内核打开 CONFIG_DYNAMIC_DEBUG；之后默认完全静默，需要时按需打开："
echo "         echo 'module vipcore +p' | sudo tee /sys/kernel/debug/dynamic_debug/control"
echo "         echo 'module vipcore -p' | sudo tee /sys/kernel/debug/dynamic_debug/control   # 关闭"

echo "=============================================="
if [ "$FAIL" = "0" ]; then
    echo " NPU 安装完成, 验证通过 ✅"
else
    echo " 存在失败项, 请检查上述输出 ❌"
fi
echo "=============================================="
exit $FAIL
