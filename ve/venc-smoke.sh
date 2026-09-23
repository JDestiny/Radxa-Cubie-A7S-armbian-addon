#!/bin/bash
# VE 硬件 H.264 编码冒烟测试（无需相机）
#
# 背景：
#   Radxa issue radxa-build/radxa-a733#35 报「A733 的 VE 编码器不可用、cedar_dev_ve2 中断永不触发」，
#   社区则反证「编码高度必须是 16 的倍数」（他复现用的是 1920x1080，%16=8）。
#   **在我们的系统上（Armbian 6.6.98 + libcedarc 1.0.7）两者都不成立**：
#   1920x1080 与 1920x1088 **都能编码**，`cedar_dev_ve2` 中断都正常递增，输出是合法 H.264 基本流
#   （SPS+PPS+IDR+P，High Profile / Level 5.1）。见
#
# 前置：已装 VE 用户态库（ve/install-ve.sh），且系统里有 /usr/bin/vencoderdemo
# 用法: sudo $0 [宽x高]    默认 1920x1088
set -u
WH="${1:-1920x1088}"
W="${WH%x*}"; H="${WH#*x}"
TMP=$(mktemp -d /tmp/venc-smoke.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

command -v vencoderdemo >/dev/null || { echo "[FAIL] 缺 vencoderdemo（装 libcedarc-dev 后可用）"; exit 1; }
[ -e /dev/cedar_dev_ve2 ] || { echo "[FAIL] 无 /dev/cedar_dev_ve2（VE 编码器节点）"; exit 1; }

irq() { awk '/cedar_dev_ve2/{print $2}' /proc/interrupts; }
before=$(irq)

# NV12 全黑帧（编码器只关心码流结构，内容无关）
dd if=/dev/zero of="$TMP/in.yuv" bs=1024 count=$((W*H*3/2/1024)) 2>/dev/null
echo "[1/3] 输入 ${W}x${H} NV12 → $((W*H*3/2)) 字节"
echo "[2/3] vencoderdemo 编码 2 帧"
timeout 90 vencoderdemo -i "$TMP/in.yuv" -n 2 -f 0 -o "$TMP/out.h264" -s "${W}x${H}" -d "${W}x${H}" >"$TMP/log" 2>&1
rc=$?
after=$(irq)
echo "[3/3] 判据"
printf '  vencoderdemo 退出码 : %s（期望 0）\n' "$rc"
printf '  cedar_dev_ve2 中断  : %s → %s（增量 %s，期望 ≥1）\n' "$before" "$after" "$((after-before))"
printf '  输出码流            : %s 字节\n' "$(stat -c%s "$TMP/out.h264" 2>/dev/null || echo 0)"
python3 - "$TMP/out.h264" <<'PY'
import sys
d=open(sys.argv[1],'rb').read()
idx=[];i=0
while i<len(d)-3:
    if d[i:i+4]==b'\x00\x00\x00\x01': idx.append((i,4)); i+=4
    elif d[i:i+3]==b'\x00\x00\x01': idx.append((i,3)); i+=3
    else: i+=1
types=[d[o+l]&0x1f for o,l in idx]
name={1:'P',5:'IDR',7:'SPS',8:'PPS',6:'SEI',9:'AUD'}
print("  NAL 单元            : " + ", ".join(name.get(t,str(t)) for t in types))
ok = 7 in types and 8 in types and (5 in types or 1 in types)
print("  结论                : " + ("✅ VE 硬件 H.264 编码可用" if ok else "❌ 码流不含 SPS/PPS/切片，编码未成功"))
sys.exit(0 if ok else 1)
PY
