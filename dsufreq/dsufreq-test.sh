#!/bin/bash
# DSU/L3 调频：受控启用（黑名单 → 手动加载 → 判据 → 提升）
#
# 背景（2026-09-18）：
#   内核把 CONFIG_AW_SUNXI_DSUFREQ 编成模块（=m）。原因：该驱动
#   sunxi-dsufreq.c:487 有一个硬 BUG_ON(1)，而 probe 在 :560 **无条件**调用
#   dsu_init_freq_table()（不受 CONFIG_AW_SUNXI_DSUFREQ_ADJUST 保护——那个符号
#   只管 :584-602 的 freq_qos 块）。触发条件是「DSU 最低 OPP 电压 > CPU 最低
#   OPP 电压」，两个电压都取自 nvmem 选中的 VF 变体，**读 DTB 判不出来**；
#   一旦命中，每次开机都 panic（无串口的 SD 卡机器只能断电 + 重刷）。
#   做成模块 = 把风险挪出启动路径：没人 modprobe，就没人 probe。
#
#   但该模块带 MODULE_DEVICE_TABLE(of, sunxi_dsufreq_of_match)（:637），
#   udev 会按 dsufreq@0 平台设备自动加载 → 必须先用 modprobe.d 黑名单挡住它，
#   才能让"手动 modprobe"成为一次真正受控的实验。
#
# ⚠️ test 步骤可能触发 BUG_ON 直接 panic / 死机：
#   * SD 卡系统不会损坏，断电重启即可；
#   * 黑名单保留时，重启后系统启动路径**完全不受影响**（不会再自动 probe）。
#   本脚本**不会**自动重启、不写 /boot、不碰 eMMC。
#
# 用法:
#   sudo $0 status      # 只读：看 config / 黑名单 / 模块 / sysfs / dmesg
#   sudo $0 blacklist   # 写黑名单（并卸载已加载的模块）→ 重启也不会自动加载
#   sudo $0 test        # 受控实验：确认已黑名单后，手动 modprobe 一次并判定
#   sudo $0 promote     # 实验成功后：删掉黑名单（恢复自动加载）
#   sudo $0 unload      # 卸载模块
set -u

MOD=sunxi-dsufreq                     # modprobe 用的名字（带连字符）
MOD_LS='sunxi[_-]dsufreq'             # lsmod 里显示成下划线，两种都匹配
BL_DIR="${BL_DIR:-/etc/modprobe.d}"
BL="$BL_DIR/blacklist-sunxi-dsufreq.conf"
SYS="${SYS:-/sys/class/dsufreq}"
CONF="${CONF:-/boot/config-$(uname -r)}"

need_root() { [ "$(id -u)" = 0 ] || { echo "需要 root: sudo $0 $*"; exit 1; }; }
loaded() { lsmod | grep -qE "^$MOD_LS[[:space:]]"; }
loaded_line() { lsmod | awk -v m="$MOD_LS" '$1 ~ "^"m"$" {print $1"  "$2" B, refcount "$3}'; }
sym_val() {  # $1 = ADJUST|TEST → y / m / n（is not set）/ ?（符号不在 config 里）
  local l
  l="$(grep -aE "^(# )?CONFIG_AW_SUNXI_DSUFREQ_$1(=| is not set)" "$CONF" 2>/dev/null | tail -1)"
  case "$l" in
    *"is not set") echo n ;;
    *=*)           echo "${l##*=}" ;;
    *)             echo "?" ;;
  esac
}

status() {
  echo "=============================================="
  echo " DSU/L3 调频（$MOD）状态"
  echo "=============================================="
  echo " ── 1. 内核 config ──"
  if [ ! -r "$CONF" ]; then
    printf '   %-22s ⚠️ 读不到文件：%s（不存在或不可读）\n' "CONFIG_AW_SUNXI_DSUFREQ" "$CONF"
  else
    local cv
    cv="$(grep -aE '^CONFIG_AW_SUNXI_DSUFREQ=' "$CONF" 2>/dev/null | tail -1 | cut -d= -f2)"
    if [ -n "$cv" ]; then
      printf '   %-22s =%s\n' "CONFIG_AW_SUNXI_DSUFREQ" "$cv"
      case "$cv" in
        m) printf '   %-22s ✅ =m —— 模块形态，probe 不在启动路径上\n' "" ;;
        y) printf '   %-22s ⚠️ =y —— probe 发生在开机时，请确认本内核已启用该模块配置\n' "" ;;
        *) printf '   %-22s ℹ️ 取值既非 m 也非 y\n' "" ;;
      esac
    elif grep -qaE '^# CONFIG_AW_SUNXI_DSUFREQ is not set' "$CONF"; then
      printf '   %-22s 未设置（is not set）\n' "CONFIG_AW_SUNXI_DSUFREQ"
      printf '   %-22s ⭕ 本内核未启用 dsufreq —— 编译前属正常；需先使用启用了该模块的内核\n' ""
    else
      printf '   %-22s ？该符号不在 config 里（config 可能被裁剪过）\n' "CONFIG_AW_SUNXI_DSUFREQ"
    fi
    printf '   %-22s ADJUST=%s  TEST=%s（两者都应保持关闭，n = 未设置）\n' "" "$(sym_val ADJUST)" "$(sym_val TEST)"
  fi

  echo " ── 2. 模块文件 ──"
  if modinfo "$MOD" >/dev/null 2>&1; then
    printf '   %s ✅ 存在：%s\n' "$MOD" "$(modinfo -F filename "$MOD" 2>/dev/null)"
  else
    printf '   %s ⭕ 内核里没有 —— 需先使用启用了该模块的内核\n' "$MOD"
  fi

  echo " ── 3. 黑名单 ──"
  if [ -f "$BL" ]; then
    printf '   ✅ %s\n      内容：%s\n' "$BL" "$(tr '\n' ' ' < "$BL" 2>/dev/null)"
  else
    printf '   ⭕ 无 %s\n      （没有它时 udev 会在开机自动加载模块）\n' "$BL"
  fi

  echo " ── 4. 当前加载状态 ──"
  if loaded; then
    printf '   ✅ 已加载：%s\n' "$(loaded_line)"
  else
    printf '   ⭕ 未加载\n'
  fi

  echo " ── 5. 调频接口 $SYS ──"
  if [ -d "$SYS" ]; then
    local f
    for f in scaling_cur_freq scaling_available_frequencies scaling_min_freq scaling_max_freq scaling_governor; do
      [ -r "$SYS/$f" ] && printf '   %-30s %s\n' "$f" "$(tr '\n' ' ' < "$SYS/$f" 2>/dev/null | cut -c1-110)"
    done
  else
    printf '   ⭕ 不存在（模块未加载时属正常）\n'
  fi

  echo " ── 6. dmesg（最近与 dsu/BUG 相关的行）──"
  if dmesg >/dev/null 2>&1; then
    local dl; dl="$(dmesg | grep -aiE "dsu|BUG|Call trace" | tail -5)"
    [ -n "$dl" ] && printf '%s\n' "$dl" | sed 's/^/   /' || echo "   （无匹配）"
  else
    echo "   （读不到 dmesg —— 需 root，或 kernel.dmesg_restrict=1）"
  fi

  echo " ── 结论 ──"
  if [ -d "$SYS" ]; then
    echo "   ✅ 模块已加载、接口在：scaling_cur_freq=$(tr -d '\n' < "$SYS/scaling_cur_freq" 2>/dev/null)"
    if dmesg 2>/dev/null | grep -qa "dsu min volt is err"; then
      echo "      ❌ 但 dmesg 里有 dsu min volt is err —— 那正是 BUG_ON 的触发条件，请勿再加载"
    fi
  elif [ -f "$BL" ]; then
    echo "   ⭕ 已黑名单、模块未加载 —— 可以跑 sudo $0 test 做一次受控实验"
  else
    echo "   ⚠️ 未黑名单且未加载 —— 先跑 sudo $0 blacklist 再跑 test（不要直接 modprobe）"
  fi
}

do_blacklist() {
  need_root blacklist
  echo "[1/2] 写黑名单 $BL"
  mkdir -p "$BL_DIR" || { echo "  [FAIL] 建不了目录 $BL_DIR"; exit 1; }
  printf 'blacklist %s\n' "$MOD" > "$BL" || { echo "  [FAIL] 写入失败"; exit 1; }
  echo "  [OK] $(cat "$BL")"
  echo "[2/2] 卸载已加载的模块（若有）"
  if loaded; then
    if modprobe -r "$MOD" 2>/dev/null; then echo "  [OK] 已卸载"; else echo "  [FAIL] 卸载失败（可能被占用）"; fi
  else
    echo "  [..] 未加载，无需卸载"
  fi
  echo
  echo "  下一步：sudo $0 test（受控加载一次）；重启后也不再自动加载。"
  status
}

do_test() {
  need_root test
  echo "=============================================="
  echo " DSU 调频 —— 受控加载实验"
  echo "=============================================="
  echo "[1/3] 前置检查"
  if [ ! -f "$BL" ]; then
    echo "  [FAIL] 黑名单不存在：$BL"
    echo "         先执行: sudo $0 blacklist"
    exit 1
  fi
  echo "  [OK] 黑名单在（重启后也不会自动 probe）"
  if loaded; then
    echo "  [FAIL] 模块已加载 —— 先 sudo $0 unload，保持"手动加载"的可控性"
    exit 1
  fi
  echo "  [OK] 模块当前未加载"
  if ! modinfo "$MOD" >/dev/null 2>&1; then
    echo "  [FAIL] 内核里没有 $MOD 模块（需先使用启用了该模块的内核）"
    exit 1
  fi
  echo "  [OK] 模块文件存在"
  echo
  echo "  ⚠️⚠️  警告  ⚠️⚠️"
  echo "  这一步可能触发内核 BUG_ON（sunxi-dsufreq.c:487）→ 直接 panic / 死机。"
  echo "   * SD 卡系统不会损坏，断电重启即可恢复；"
  echo "   * 黑名单保留时，重启后系统照常启动（不会再自动 probe）；"
  echo "   * 建议接串口，并确认你能物理断电。"
  echo
  read -r -p "  确认继续? [y/N] " ans
  case "$ans" in
    y|Y|yes|YES) ;;
    *) echo "  已取消，未做任何加载。"; exit 0 ;;
  esac
  echo
  echo "[2/3] modprobe $MOD（实验本体）"
  modprobe "$MOD"; local rc=$?
  echo "  modprobe 返回 $rc（机器没挂的话，继续看判据）"
  sleep 2

  echo "[3/3] 判据"
  local ok=1
  if loaded; then echo "  [OK]   模块已加载：$(loaded_line)"; else echo "  [FAIL] 模块未加载"; ok=0; fi
  if [ -d "$SYS" ]; then
    echo "  [OK]   $SYS 出现"
    [ -r "$SYS/scaling_cur_freq" ] && echo "         scaling_cur_freq = $(tr -d '\n' < "$SYS/scaling_cur_freq")"
  else
    echo "  [FAIL] $SYS 未出现"; ok=0
  fi
  echo "  ── dmesg 最近 20 行里的 dsu/BUG/Call trace ──"
  if dmesg >/dev/null 2>&1; then
    local dl; dl="$(dmesg | tail -20 | grep -aiE "dsu|BUG|Call trace")"
    [ -n "$dl" ] && printf '%s\n' "$dl" | sed 's/^/   /' || echo "   （无匹配）"
    if dmesg | grep -qa "dsu min volt is err"; then
      echo "  [FAIL] 命中 dsu min volt is err —— 正是 BUG_ON 的触发条件"; ok=0
    else
      echo "  [OK]   无 dsu min volt is err"
    fi
  else
    echo "   （读不到 dmesg：需 root）"
  fi
  echo
  echo "  ── 结论 ──"
  if [ "$ok" = 1 ]; then
    echo "   ✅ 实验成功（模块加载 + /sys/class/dsufreq 出现 + 无 BUG）"
    echo "      → 可执行 sudo $0 promote 恢复自动加载；"
    echo "      → 或把内核配置 CONFIG_AW_SUNXI_DSUFREQ 改回 =y 内建（下次编译生效）。"
    echo "      当前：scaling_cur_freq=$(tr -d '\n' < "$SYS/scaling_cur_freq" 2>/dev/null)"
  else
    echo "   ❌ 实验未通过（见上面 [FAIL]）"
    echo "      * 若刚才机器 panic/重启：黑名单已保留 → 重启后系统正常，别再手动加载；"
    echo "      * 若只是模块没起来：看 dmesg 里 devm_*/opp 相关报错。"
  fi
}

do_promote() {
  need_root promote
  echo "[1/2] 删除黑名单 $BL"
  if [ -f "$BL" ]; then rm -f "$BL" && echo "  [OK] 已删除"; else echo "  [..] 本来就没有"; fi
  echo "[2/2] 之后如何加载（二选一）"
  echo "   a) 保持 =m：模块带 of: alias，udev 会在开机自动加载（删掉黑名单即恢复）；"
  echo "   b) 把内核配置 CONFIG_AW_SUNXI_DSUFREQ 由 =m 改回 =y，随内核内建（下次编译生效）。"
  echo "   注：CONFIG_AW_SUNXI_DSUFREQ_ADJUST / _TEST 建议继续保持关闭。"
  status
}

do_unload() {
  need_root unload
  if loaded; then
    if modprobe -r "$MOD" 2>/dev/null; then echo "  [OK] 已卸载 $MOD"; else echo "  [FAIL] 卸载失败（被占用？）"; fi
  else
    echo "  [..] 未加载"
  fi
  status
}

case "${1:-}" in
  status)    status ;;
  blacklist) do_blacklist ;;
  test)      do_test ;;
  promote)   do_promote ;;
  unload)    do_unload ;;
  *) sed -n '2,27p' "$0" | sed 's/^# \?//'; exit 1 ;;
esac
