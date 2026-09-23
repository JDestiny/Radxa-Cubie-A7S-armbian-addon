#!/bin/bash
# Radxa 相机（MIPI-CSI）overlay：安装 / 启用 / 停用 / 状态
#
# 背景（2026-09-18）：
#   官方 r6 镜像支持三款 Radxa 相机 —— 8M(IMX219)、13M(IMX214)、4K(IMX415)，
#   做法是 /boot/dtbo/cubie-a7a-radxa-camera-*.dtbo（默认 .disabled，rsetup 管），
#   由 U-Boot 的 fdt apply 在启动时叠加到主 dtb 上。Armbian 侧机制不同：
#       boot.scr:  load ... ${prefix}overlay-user/${overlay_file}.dtbo ; fdt apply
#                  （对应 armbianEnv.txt 里的 user_overlays=）
#                以及 ${prefix}dtb/allwinner/overlay/${overlay_prefix}-${file}.dtbo
#                  （对应 overlays=，overlay_prefix=sun60i-a733）
#
# 为什么本脚本用 /boot/overlay-user/ + user_overlays= 而不是 overlays=：
#   /boot/dtb/ 属于 linux-dtb-* 包，内核/dtb 一升级就整目录被覆盖，自加的
#   dtbo 会被冲掉；/boot/overlay-user/ 是 Armbian 给用户留的目录，升级不动它。
#
# 为什么是 overlay 而不是直接改板级 dts：
#   相机是可选插拔件，而且插上后管线要提速（csi_top/csi_isp 600/540→704 MHz）。
#   做成 overlay 才能保证"不插相机时启动与厂商默认完全一致"。
#
# 前置条件：
#   0012  vind0 三路 supply   —— 否则 sunxi-vin-media 直接 probe 失败(-1)
#   IMX219                    —— **本仓库当前唯一支持的相机**，无需任何补丁：
#                                CONFIG_SENSOR_IMX219=m 本来就在基线 config 里，驱动/Kconfig/Makefile 接线也在树里
#   ~~0017 / 0018~~           —— **2026-09-21 退役**：它们用于打开 IMX214/IMX415，但那两份 vendor 驱动
#                                未适配 6.6 API、编译不过 → 决定只保留 IMX219。
#                                因此 `enable imx214|imx415` 会被下面的驱动守卫拦下（除非 --force）。
#
# I2C 速率（2026-09-18 新增，依据 radxa-build/radxa-a733 issue #9）：
#   官方三份 overlay 源码都写 clock-frequency = <400000>，我们照抄。但 issue #9 里
#   jacobsonjar（2026-08-25）在 Cubie A7Z + IMX214 上实测：400kHz 下 sensor 的 64 字节
#   初始化寄存器数组写不通，内核报
#       sunxi:twi_sunxi-2513000.twi:[ERR]: drv-mode: Address + Write bit transmitted,ACK not received
#       sunxi:twi_sunxi-2513000.twi:[ERR]: drv mode: TWI BUS error state is 0x20
#   表现是「能识别到 sensor（ID 读经 3 次重试勉强成功）、但每次采集 0 帧」；把 twi3 降到
#   100kHz 后一次成功，并能出全分辨率。I2C 只走控制寄存器、图像走 MIPI，降速无副作用，
#   所以本脚本提供 --i2c-100k 开关（默认仍与官方一致用 400kHz）。
#
# 用法:
#   sudo $0 install [--i2c-100k]        # 编译三个 overlay 到 /boot/overlay-user/（不启用）
#                                       #   --i2c-100k: 把 twi3 从官方 400kHz 降到 100kHz，
#                                       #   见下方「I2C 速率」说明；采集 0 帧且 dmesg 有 TWI 错误时用
#   sudo $0 enable  imx219 [imx214 ...] # 写入 armbianEnv.txt 的 user_overlays（+ sensor 模块自加载）
#   sudo $0 disable [imx219 ...]        # 从 user_overlays 移除（不带参数 = 全清）
#   sudo $0 status                      # 状态 + 重启后的快速判成功判据
#   sudo $0 uninstall                   # 删 dtbo 与 user_overlays 条目
#
# ⚠️ 本脚本**不会重启**，也不会改 eMMC。改完 armbianEnv.txt 需重启才生效。
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
DTS_DIR="$HERE"
DTBO_DIR=/boot/overlay-user
ENV=/boot/armbianEnv.txt
KEY=user_overlays
CAMS="imx219 imx214 imx415"
# camera -> (sensor 驱动模块名, 所需内核补丁编号)
mod_of() { case "$1" in imx219) echo imx219;; imx214) echo imx214;; imx415) echo imx415_mipi;; esac; }
need_of() {
  case "$1" in
    imx219) echo "0012（vind0 供电）；config 里 CONFIG_SENSOR_IMX219=m 本来就有" ;;
    imx214) echo "0012 + **已退役的 0017**（IMX214 驱动未适配 6.6，编译不过）" ;;
    imx415) echo "0012 + **已退役的 0017/0018**（IMX415 驱动未适配 6.6，编译不过）" ;;
  esac
}
# 该相机的 sensor 驱动在当前内核里到底能不能用（config=m 且模块文件在）
driver_ok() {
  local c="$1" m cfg
  m="$(mod_of "$c")"
  cfg="/boot/config-$(uname -r)"
  case "$c" in
    imx219) grep -q "^CONFIG_SENSOR_IMX219=m$" "$cfg" 2>/dev/null || return 1 ;;
    imx214) grep -q "^CONFIG_SENSOR_IMX214=m$" "$cfg" 2>/dev/null || return 1 ;;
    imx415) grep -q "^CONFIG_SENSOR_IMX415=m$" "$cfg" 2>/dev/null || return 1 ;;
  esac
  modinfo "$m" >/dev/null 2>&1 || [ -f "/lib/modules/$(uname -r)/kernel/bsp/drivers/vin/modules/sensor/$m.ko" ]
}
need_root() { [ "$(id -u)" = 0 ] || { echo "需要 root: sudo $0 $*"; exit 1; }; }
dtbo_of() { echo "$DTBO_DIR/sun60i-a733-camera-$1.dtbo"; }

# ── armbianEnv.txt 的 user_overlays 行读写 ──────────────────────────────
env_get() { sed -n "s/^${KEY}=//p" "$ENV" 2>/dev/null | tail -1; }
env_set() {  # $1 = 新的一整串（可为空 -> 删行）
  local new="$1" cur; cur="$(env_get)"
  [ "$cur" = "$new" ] && return 0            # 无变化就不动、也不留备份
  cp -a "$ENV" "$ENV.bak-$(date +%Y%m%d-%H%M%S)"
  if [ -z "$new" ]; then
    sed -i "/^${KEY}=/d" "$ENV"
  elif grep -q "^${KEY}=" "$ENV"; then
    sed -i "s|^${KEY}=.*|${KEY}=$1|" "$ENV"
  else
    printf '%s=%s\n' "$KEY" "$1" >> "$ENV"
  fi
}
env_add() {  # $1 = cam；已存在则不动
  local cur new
  cur="$(env_get)"
  case " $cur " in *" $1 "*) echo "  [SKIP] $KEY 里已有 $1"; return 0;; esac
  new="$(echo "$cur $1" | xargs)"
  env_set "$new"; echo "  [OK] $KEY=$new"
}
env_del() {  # $1 = cam，或 "*" = 全清
  local cur new
  cur="$(env_get)"
  if [ "$1" = "*" ]; then env_set ""; echo "  [OK] 已清空 $KEY"; return 0; fi
  new="$(for t in $cur; do [ "$t" = "$1" ] || echo "$t"; done | xargs)"
  env_set "$new"; echo "  [OK] $KEY=${new:-（空）}"
}

# ── 动作 ────────────────────────────────────────────────────────────────
do_install() {
  need_root install
  local i2c_hz=400000
  for a in "$@"; do
    case "$a" in
      --i2c-100k) i2c_hz=100000 ;;
      *) echo "  [FAIL] 未知参数 '$a'（只支持 --i2c-100k）"; exit 1 ;;
    esac
  done
  command -v dtc >/dev/null || { echo "  [FAIL] 缺 dtc：sudo apt install device-tree-compiler"; exit 1; }
  mkdir -p "$DTBO_DIR"
  echo "[1/2] 编译 overlay 源（$DTS_DIR）  twi3 I2C = ${i2c_hz} Hz$([ "$i2c_hz" = 100000 ] && echo '（已从官方 400kHz 降速）' || echo '（官方默认值）')"
  local fail=0
  for c in $CAMS; do
    local src="$DTS_DIR/sun60i-a733-camera-$c.dts" tmp out
    [ -f "$src" ] || { echo "  [FAIL] 缺源文件 $src"; fail=1; continue; }
    # 需要降速时，编译一份临时源（不改动仓库里的 .dts，保持与官方同值可追溯）
    if [ "$i2c_hz" = 100000 ]; then
      tmp="/tmp/cam-$c-100k.dts"
      sed 's|clock-frequency = <400000>;|clock-frequency = <100000>;|' "$src" > "$tmp"
      grep -q 'clock-frequency = <100000>' "$tmp" || { echo "  [FAIL] $c：源里没找到 400000 的 clock-frequency"; fail=1; continue; }
      src="$tmp"
    fi
    # -@ 让 dtc 生成 __symbols__（与官方 dtbo 一致）；twi3@0/@1 无 reg，屏蔽该告警
    if ! dtc -@ -I dts -O dtb -Wno-unit_address_vs_reg -o "/tmp/cam-$c.dtbo" "$src" 2>"/tmp/cam-$c.err"; then
      echo "  [FAIL] $c 编译失败："; sed 's/^/          /' "/tmp/cam-$c.err"; fail=1; continue
    fi
    rm -f "/tmp/cam-$c-100k.dts"
    install -m 0644 "/tmp/cam-$c.dtbo" "$(dtbo_of "$c")"
    echo "  [OK] $c → $(dtbo_of "$c")  ($(stat -c%s "$(dtbo_of "$c")") 字节)"
    rm -f "/tmp/cam-$c.dtbo" "/tmp/cam-$c.err"
  done
  [ "$fail" = 0 ] || { echo "  有编译失败项，已中止"; exit 1; }
  echo "[2/2] 完成（dtbo 已就位，但**尚未启用**）"
  echo "      启用：sudo $0 enable imx219   （可多选；需重启生效）"
}

do_enable() {
  need_root enable
  local force=0
  [ "${1:-}" = "--force" ] && { force=1; shift; }
  [ $# -gt 0 ] || { echo "用法: sudo $0 enable [--force] imx219        # 当前仅 IMX219 受支持"; exit 1; }
  echo "[1/4] 检查 sensor 驱动是否可用（当前支持的相机：IMX219）"
  local c bad=0
  for c in "$@"; do
    if driver_ok "$c"; then
      echo "  [OK] $c: $(mod_of "$c") 驱动可用（config=m + 模块在）"
    else
      echo "  [FAIL] $c: 内核里没有可用的 $(mod_of "$c") 驱动"
      echo "         → 需要 $(need_of "$c")"
      echo "         → 2026-09-21 决定：IMX214/IMX415 不再支持（驱动未适配 6.6）；请改用 IMX219，"
      echo "           或先移植驱动再用 --force 绕过本检查"
      bad=1
    fi
  done
  [ "$force" = 1 ] && { echo "  [WARN] --force：跳过驱动可用性检查"; bad=0; }
  [ "$bad" = 0 ] || exit 1
  echo "[2/4] 检查 dtbo 是否已安装"
  local missing=0
  for c in "$@"; do
    case " $CAMS " in *" $c "*) ;; *) echo "  [FAIL] 未知相机 '$c'（可选：$CAMS）"; exit 1;; esac
    [ -f "$(dtbo_of "$c")" ] || { echo "  [FAIL] $(dtbo_of "$c") 不存在，先执行 sudo $0 install"; missing=1; }
  done
  [ "$missing" = 0 ] || exit 1
  echo "  [OK]"
  echo "[3/4] 写入 $ENV"
  for c in "$@"; do env_add "$c"; done
  echo "[4/4] 让 sensor 驱动开机自加载（否则 vin 按 sensor0_mname 找不到 sensor）"
  for c in "$@"; do
    local m; m="$(mod_of "$c")"
    printf '# Radxa camera %s\n%s\n' "$c" "$m" > "/etc/modules-load.d/camera-$c.conf"
    if modinfo "$m" >/dev/null 2>&1; then
      echo "  [OK] /etc/modules-load.d/camera-$c.conf → $m"
    else
      echo "  [WARN] 当前内核里找不到模块 $m —— 请确认所需内核补丁（$(need_of "$c")）已编译进内核"
    fi
  done
  echo
  echo "  ⚠️ 需**重启**才生效。重启后按下面判据检查："
  echo "     sudo $0 status"
}

do_disable() {
  need_root disable
  echo "[1/2] 从 $ENV 移除"
  if [ $# -eq 0 ]; then
    env_del "*"
    for c in $CAMS; do rm -f "/etc/modules-load.d/camera-$c.conf"; done
    echo "  [OK] 已移除全部 camera-*.conf"
  else
    for c in "$@"; do env_del "$c"; rm -f "/etc/modules-load.d/camera-$c.conf"; done
  fi
  echo "[2/2] 完成（dtbo 文件保留，重启后回到不插相机的默认状态）"
}

do_status() {
  echo "=============================================="
  echo " Radxa 相机 overlay 状态"
  echo "=============================================="
  echo " ── 1. dtbo 文件 ──"
  for c in $CAMS; do
    local f; f="$(dtbo_of "$c")"
    if [ -f "$f" ]; then
      printf '   %-7s ✅ %s (%s 字节, md5 %s)\n' "$c" "$f" "$(stat -c%s "$f")" "$(md5sum "$f" | cut -c1-8)"
    else
      printf '   %-7s ⭕ 未安装\n' "$c"
    fi
  done
  echo " ── 2. 已装 dtbo 的 twi3 I2C 速率（400kHz=官方 / 100kHz=降速版） ──"
  for c in $CAMS; do
    local f; f="$(dtbo_of "$c")"
    [ -f "$f" ] || continue
    local hz; hz="$(dtc -I dtb -O dts "$f" 2>/dev/null | grep -oE 'clock-frequency = <0x[0-9a-f]+>' | head -1)"
    printf '   %-7s %s\n' "$c" "${hz:-读不到}"
  done
  echo " ── 3. armbianEnv.txt 配置 ──"
  printf '   %s = %s\n' "$KEY" "$(env_get || true)"
  printf '   overlay_prefix = %s\n' "$(sed -n 's/^overlay_prefix=//p' "$ENV")"
  echo " ── 4. sensor 模块自加载 ──"
  for c in $CAMS; do
    local m f; m="$(mod_of "$c")"; f="/etc/modules-load.d/camera-$c.conf"
    [ -f "$f" ] && printf '   %-7s ✅ %s → %s\n' "$c" "$f" "$(cat "$f" | tail -1)" \
                || printf '   %-7s ⭕ 无\n' "$c"
  done
  echo " ── 4b. sensor 驱动可用性（2026-09-21 起本仓库仅支持 IMX219） ──"
  for c in $CAMS; do
    if driver_ok "$c"; then
      printf '   %-7s ✅ %s 驱动可用（config=m + 模块在）\n' "$c" "$(mod_of "$c")"
    elif [ "$c" = imx219 ]; then
      printf '   %-7s ❌ %s 不可用 —— 相机是本仓库唯一支持型号，请检查内核 config/模块\n' "$c" "$(mod_of "$c")"
    else
      printf '   %-7s ❌ %s 不可用（该传感器驱动未适配当前内核）\n' "$c" "$(mod_of "$c")"
    fi
  done
  echo " ── 5. 当前运行内核里是否真的叠加上去了 ──"
  local dtroot=/proc/device-tree/soc@3000000/vind@5800800
  local csi="$dtroot/csi@5821000/status" top="$dtroot/csi_top"
  printf '   csi1 status       : %s\n' "$(tr -d '\0' < "$csi" 2>/dev/null || echo '读不到')"
  # device-tree 的 cell 是大端，od -tx4 会按下标反读（0x23c34600 显示成 0046c323），
  # 故按字节取出再拼：0x23c34600=600MHz(未叠加) / 0x29f63000=704MHz(已叠加)
  local top_hex; top_hex="$(od -An -tx1 "$top" 2>/dev/null | tr -d ' \n')"
  printf '   csi_top           : %s\n' "${top_hex:-读不到}"
  printf '   sensor0_mname     : %s\n' "$(tr -d '\0' < "$dtroot/sensor@5812000/sensor0_mname" 2>/dev/null || echo '读不到')"
  printf '   /dev/media*       : %s\n' "$(ls /dev/media* 2>/dev/null | tr '\n' ' ' || echo 无)"
  printf '   已加载 sensor 模块: %s\n' "$(lsmod | awk '/^imx/{print $1}' | tr '\n' ' ' || true)"
  echo " ── 结论 ──"
  local cur; cur="$(env_get)"
  if [ -z "$cur" ]; then
    echo "   ⭕ 未启用任何相机 overlay（开机走厂商默认 dtb）"
  elif grep -q "okay" "$csi" 2>/dev/null; then
    echo "   ✅ overlay 已生效（csi1=okay），配置的相机: $cur"
    echo "      详见本仓库 camera/README.md"
  else
    echo "   ⚠️ armbianEnv.txt 已配置 [$cur]，但当前内核里 csi1 还不是 okay"
    echo "      → 改了 armbianEnv.txt 后需要重启；若已重启仍如此，看 dmesg | grep -iE 'vin|csi|overlay'"
  fi
}

do_uninstall() {
  need_root uninstall
  do_disable
  for c in $CAMS; do rm -f "$(dtbo_of "$c")" && echo "  [OK] 删除 $(dtbo_of "$c")"; done
  rmdir "$DTBO_DIR" 2>/dev/null && echo "  [OK] 删除空目录 $DTBO_DIR"
  echo "  完成"
}

case "${1:-}" in
  install)   shift; do_install "$@" ;;
  enable)    shift; do_enable "$@" ;;
  disable)   shift; do_disable "$@" ;;
  status)    do_status ;;
  uninstall) do_uninstall ;;
  *) sed -n '3,40p' "$0" | sed 's/^# \?//'; exit 1 ;;
esac
