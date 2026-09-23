#!/bin/bash
# 硬件看门狗（systemd 负责喂狗）
#
# 背景（2026-09-18）：
#   本板 `/dev/watchdog0`（sunxi-wdt）本来没有任何服务喂它，而内核配置里
#   `CONFIG_PANIC_ON_OOPS=y` + `panic=0` —— 即"一次 oops 就 panic 且永不重启"。
#   两者叠加的结果是：内核一旦挂死，机器永久卡住，只能人工断电。
#   启用 systemd 的硬件看门狗后，systemd 会周期性喂狗；它自己卡死 → 硬件超时复位。
#
# ⚠️ 关键坑：sunxi-wdt 的**硬件上限只有 16 秒**
#   （SDK `bsp/drivers/watchdog/sunxi_wdt.c`: `#define WDT_MAX_TIMEOUT 16`）。
#   若按常见做法设 60s，systemd 会报：
#       Failed to set watchdog hardware timeout to 1min: Invalid argument
#   并放弃使用看门狗 —— 看起来"配了"，其实没生效。
#   本脚本固定用 16（驱动上限），systemd 每 8 秒喂一次。
#
# 判成功：`dmesg | grep -i "Watchdog running"` 出现
#         `Watchdog running with a hardware timeout of 16s`
#         或 `wdctl /dev/watchdog0` 报 `Device or resource busy`（= 已被 systemd 持有）。
#   注意：`/sys/class/watchdog/watchdog0/{state,timeout}` 读出来是空的 —— 因为
#   `CONFIG_WATCHDOG_SYSFS` 未开（可选特性），**不代表没生效**，请看上面两条判据。
#
# ⚠️ 副作用（预期行为）：systemd 或其喂狗线程若卡死超过 16 s，机器会**自动硬件复位**。
#
# 用法: sudo $0 [on|off|status]
set -u

CONF=/etc/systemd/system.conf
WDT=/dev/watchdog0
TIMEOUT=16

need_root() { [ "$(id -u)" = 0 ] || { echo "需要 root: sudo $0 $*"; exit 1; }; }

cur_setting() { grep -aE "^RuntimeWatchdogSec=" "$CONF" 2>/dev/null | tail -1 | cut -d= -f2; }

status() {
  echo "=============================================="
  echo " 硬件看门狗状态"
  echo "=============================================="
  printf '  配置项         : RuntimeWatchdogSec=%s\n' "$(cur_setting || echo '(未设置=off)')"
  printf '  看门狗设备     : %s\n' "$([ -e $WDT ] && echo "$WDT (sunxi-wdt, 硬件上限 ${TIMEOUT}s)" || echo '不存在')"
  printf '  驱动侧证词     : %s\n' "$(dmesg 2>/dev/null | grep -a "Watchdog running" | tail -1 | sed 's/^.*systemd\[1\]: //' || echo '(无)')"
  if command -v wdctl >/dev/null 2>&1; then
    if wdctl "$WDT" >/dev/null 2>&1; then
      echo "  wdctl          : 可读（说明**没有**进程持有 → 未在喂狗）"
    else
      echo "  wdctl          : Device or resource busy（= 已被 systemd 持有 → 正在喂狗）✅"
    fi
  fi
  if [ "$(cur_setting)" = "$TIMEOUT" ]; then
    echo "  结论           : ✅ 已启用（16 s 硬件超时，systemd 每 8 s 喂一次）"
  else
    echo "  结论           : ⭕ 未启用（内核挂死时不会自动复位）"
  fi
}

on() {
  need_root on
  echo "[1/3] 写 $CONF (RuntimeWatchdogSec=$TIMEOUT)"
  if grep -qaE "^RuntimeWatchdogSec=" "$CONF"; then
    sed -i "s/^RuntimeWatchdogSec=.*/RuntimeWatchdogSec=$TIMEOUT/" "$CONF"
  else
    sed -i "s/^#RuntimeWatchdogSec=.*/RuntimeWatchdogSec=$TIMEOUT/" "$CONF"
  fi
  grep -aE "^RuntimeWatchdogSec=" "$CONF" | sed 's/^/  /'

  echo "[2/3] 让 systemd 重新读取配置"
  systemctl daemon-reexec && echo "  [OK] daemon-reexec"
  sleep 4

  echo "[3/3] 校验"
  status
}

off() {
  need_root off
  echo "[1/2] 关闭（RuntimeWatchdogSec=off）"
  sed -i "s/^RuntimeWatchdogSec=.*/#RuntimeWatchdogSec=off/" "$CONF"
  grep -aE "^#?RuntimeWatchdogSec=" "$CONF" | sed 's/^/  /'
  echo "[2/2] 生效"
  systemctl daemon-reexec && echo "  [OK] daemon-reexec"
  echo "  （systemd 停止喂狗后，看门狗由内核在超时后关闭；可用 status 复查）"
  status
}

case "${1:-status}" in
  on)     on ;;
  off)    off ;;
  status) status ;;
  *)      sed -n '2,30p' "$0" ;;
esac
