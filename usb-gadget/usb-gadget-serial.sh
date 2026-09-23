#!/bin/bash
# SPDX-License-Identifier: MIT
# USB gadget：把 OTG 口变成 USB 串口设备（PC 侧出现 /dev/ttyACM0）
#
# 背景（2026-09-18）：
#   板级设备树已让 usbc0 进入 OTG 模式、UDC (4100000.udc-controller) 注册成功，
#   但内核只提供"能力"，串口/网卡/存储这些**具体形态必须由用户态写 configfs 决定**，
#   所以此前 OTG 口只能当 host（插 U 盘/键鼠），不能当 device。
#   本脚本用 configfs 配一个 ACM(CDC serial) gadget → 板子插到 PC 上会枚举出串口，
#   可用来登录/传文件，不需要网线。
#
# 为什么是"串口"而不是 U 盘/网卡：
#   mass_storage（把 SD/eMMC 暴露给 PC）有被误格式化/误写引导区的风险，不做；
#   ACM 串口最安全、用途最直接。想换形态见文末"其它形态"。
#
# ⚠️ 注意：启用后 OTG 口进入 device 模式，**不能再插 U 盘/键鼠**；
#   要用回 host 模式执行 `$0 off`（或直接拔掉并 off）。
#   本机 U 盘接在 EHCI(Bus 003) 上，不受影响。
#
# 用法: sudo $0 on | off | status
set -u

G=/sys/kernel/config/usb_gadget/g1
UDC_NAME=4100000.udc-controller

need_root() { [ "$(id -u)" = 0 ] || { echo "需要 root: sudo $0 $*"; exit 1; }; }

status() {
  echo "=============================================="
  echo " USB gadget（ACM 串口）状态"
  echo "=============================================="
  printf '  gadget 目录   : %s\n' "$([ -d "$G" ] && echo "存在 ($G)" || echo 未配置)"
  printf '  绑定 UDC      : %s\n' "$([ -d "$G" ] && cat "$G/UDC" 2>/dev/null || echo -)"
  printf '  UDC 状态      : %s\n' "$(cat /sys/class/udc/$UDC_NAME/state 2>/dev/null || echo 'n/a')"
  printf '  串口设备      : %s\n' "$(ls /dev/ttyGS* 2>/dev/null | tr '\n' ' ' || echo 无)"
  if [ -d "$G" ] && [ -n "$(cat "$G/UDC" 2>/dev/null)" ]; then
    echo "  结论          : ✅ 已启用（把板子插到 PC，PC 侧会出现 /dev/ttyACM*）"
    echo "                   ⚠️ OTG 口当前是 device 模式，不能插 U 盘；用 $0 off 切回"
  else
    echo "  结论          : ⭕ 未启用（OTG 口为 host 模式，可正常插 U 盘/键鼠）"
  fi
}

on() {
  need_root on
  [ -d /sys/kernel/config/usb_gadget ] || { echo "  [FAIL] configfs 未挂载"; exit 1; }
  echo "[1/4] 建 gadget 骨架"
  mkdir -p "$G" && cd "$G" || { echo "  [FAIL] 无法进入 $G"; exit 1; }
  echo 0x1d6b > idVendor      # Linux Foundation
  echo 0x0104 > idProduct     # Multifunction Composite Gadget
  echo 0x0100 > bcdDevice
  echo 0x0200 > bcdUSB
  mkdir -p strings/0x409
  echo "Radxa"      > strings/0x409/manufacturer
  echo "Cubie A7S"  > strings/0x409/product
  echo "A7S0001"    > strings/0x409/serialnumber
  echo "  [OK]"

  echo "[2/4] 建配置与 ACM 功能"
  mkdir -p configs/c.1/strings/0x409
  echo "ACM serial" > configs/c.1/strings/0x409/configuration
  echo 250 > configs/c.1/MaxPower
  mkdir -p functions/acm.usb0
  ln -sf functions/acm.usb0 configs/c.1/ 2>/dev/null || true
  echo "  [OK]"

  echo "[3/4] 绑定 UDC（$UDC_NAME）"
  if ! echo "$UDC_NAME" > UDC 2>/dev/null; then
    echo "  [FAIL] 绑定失败（UDC 忙或不存在）"; exit 1
  fi
  echo "  [OK]"

  echo "[4/4] 校验"
  sleep 1
  status
}

off() {
  need_root off
  echo "[1/2] 解绑 UDC"
  if [ -d "$G" ]; then
    echo "" > "$G/UDC" 2>/dev/null && echo "  [OK] 已解绑"
  else
    echo "  [..] gadget 不存在"
  fi
  echo "[2/2] 清理配置"
  if [ -d "$G" ]; then
    rm -f "$G/configs/c.1/acm.usb0" 2>/dev/null
    rmdir "$G/configs/c.1/strings/0x409" "$G/configs/c.1" 2>/dev/null
    rmdir "$G/functions/acm.usb0" 2>/dev/null
    rmdir "$G/strings/0x409" 2>/dev/null
    rmdir "$G" 2>/dev/null
    echo "  [OK] 已清理（OTG 口回到 host 模式）"
  fi
  status
}

case "${1:-status}" in
  on)     on ;;
  off)    off ;;
  status) status ;;
  *)      sed -n '2,26p' "$0" ;;
esac
