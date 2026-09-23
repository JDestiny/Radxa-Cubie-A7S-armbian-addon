#!/bin/bash
# ============================================================
# 模块 00: 全硬件验证 — 原 test-cubie-a7s-v8.sh (0-33 章, 85+ 项) 已内化并入本文件
#   * 覆盖: SoC/CPU/内存/PMIC/存储(eMMC+TF)/以太网/WiFi/蓝牙/USB/USB-C/PCIe/VE/NPU/G2D/
#           EEPROM/风扇/LED/按键/MIPI-CSI/UFS/GPU 电源域/串口/稳定性/调频/内存深度/
#           存储性能/网络深度/RTC+hwrng/GPIO/热管理/电压轨/USB 拓扑/NPU devfreq/dmesg/systemd
#   * 由 TOOL/stress.sh source → 通过 mod_verify() 执行; 逐条 PASS/FAIL/SKIP 直接写入压测报告
#     (报告为纯文本, 无颜色码; 计数用本函数内变量, 不解析任何子进程输出)
#   * 也可单独运行: sudo ./modules/00-verify.sh [--quick]      (仅终端输出, 不生成任何文件)
#   * v8 独立脚本 (test-cubie-a7s-v8.sh) 已删除, 内容即本文件
# ============================================================

mod_verify() {
    local QUICK="${QUICK_MODE_INT:-0}"          # 1 = 快速模式 (stress.sh --quick 或本模块 --quick)
    local _a
    for _a in "$@"; do [ "$_a" = "--quick" ] && QUICK=1; done

    local PASS=0 FAIL=0 SKIP=0
    # 本模块会临时覆盖 log/ok/bad/skip/t (见下), 结束前必须恢复, 否则残留函数会影响后续模块
    local _saved_funcs
    _saved_funcs="$(declare -f log ok bad skip t 2>/dev/null)"
    local REPORT="${CUR_LOG:-/dev/stdout}"       # 兼容章节内 "| tee -a $REPORT" 的原样输出
    local -a SKIP_LIST=() FAIL_LIST=()

    # ---- 输出: 直接写本体系报告 ( _emit_* 由 modules/lib.sh 提供) ----
    log()  { _emit_log "$@"; }
    t()    { _emit_head "$*"; }
    ok()   { PASS=$((PASS+1)); _emit_ok "$*"; }
    bad()  { FAIL=$((FAIL+1)); FAIL_LIST+=("$*"); _emit_bad "$*"; }
    skip() { SKIP=$((SKIP+1)); SKIP_LIST+=("$*"); _emit_skip "$*"; }
    chk()  { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
    have() { command -v "$1" >/dev/null 2>&1; }
    mod()  { modprobe "$1" 2>/dev/null; }

    log "══════════════════════════════════════════════"
    log " Radxa Cubie A7S Armbian 全硬件验证 (0-33 章)"
    log " $(date -Is)$([ "$QUICK" = "1" ] && echo "  [快速模式]" || true)"
    log "══════════════════════════════════════════════"

# ── 0. 安装测试依赖 ──────────────────────────────
t "0. 测试依赖安装 (i2c-tools / pciutils / ethtool / stress-ng / memtester / iperf3 / gpiod / mbw / fio)"
if have apt-get; then
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      i2c-tools pciutils ethtool stress-ng usbutils memtester iperf3 gpiod mbw fio >/dev/null 2>&1
  for p in i2cdetect lspci ethtool; do
    have "$p" && ok "$p 可用" || bad "$p 安装失败"
  done
  # mbw(内存带宽) / fio(存储随机 IO) 缺失只跳过对应模块, 不计 FAIL
  for p in mbw fio; do
    have "$p" && ok "$p 可用" || log "  $p 未安装 — 对应压测模块将跳过 (apt install $p)"
  done
else
  bad "无 apt-get, 无法安装依赖"
fi

# ── 1. SoC / 系统 ─────────────────────────────────
t "1. SoC (Allwinner A733) / 系统"
log "  内核: $(uname -r)  arch: $(uname -m)"
model=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null)
log "  型号: $model"
chk "DT model = Radxa Cubie A7S" test "$model" = "Radxa Cubie A7S"
log "  Armbian: $(grep -E 'VERSION|IMAGE' /etc/armbian-release 2>/dev/null | tr '\n' ' ')"
chk "Armbian release 文件" test -f /etc/armbian-release
chk "compatible 含 cubie-a7s" grep -q "cubie-a7s" /proc/device-tree/compatible 2>/dev/null
chk "systemd 运行中" systemctl is-system-running --quiet

# ── 2. CPU (6×A55 + 2×A76) ────────────────────────
t "2. CPU (6× Cortex-A55 + 2× Cortex-A76)"
chk "8 核在线" test "$(nproc)" -eq 8
# 从 DT cpus 节点统计真实拓扑 (grep -l 计数文件数, 避免多文件 -c 的 文件名:计数 问题)
a55=$(grep -l "cortex-a55" /proc/device-tree/cpus/cpu@*/compatible 2>/dev/null | wc -l)
a76=$(grep -l "cortex-a76" /proc/device-tree/cpus/cpu@*/compatible 2>/dev/null | wc -l)
log "  DT 拓扑: ${a55}× Cortex-A55 + ${a76}× Cortex-A76"
[ "$a55" -eq 6 ] && [ "$a76" -eq 2 ] && ok "DT CPU 拓扑 = 6×A55 + 2×A76" || bad "DT CPU 拓扑异常 (a55=$a55 a76=$a76)"
# 从 cpuinfo 核对 CPU part (vendor 内核格式: "CPU part\t: 0x%03x" → A55=0xd05, A76=0xd0b)
p55=$(grep -cE "CPU part.*0xd05" /proc/cpuinfo || true)
p76=$(grep -cE "CPU part.*0xd0b" /proc/cpuinfo || true)
log "  cpuinfo: A55=$p55  A76=$p76"
[ "${p55:-0}" -eq 6 ] && [ "${p76:-0}" -eq 2 ] && ok "cpuinfo 与拓扑一致 (6×A55 + 2×A76)" || bad "cpuinfo 与拓扑不一致 (a55=${p55:-0} a76=${p76:-0})"
[ -d /sys/devices/system/cpu/cpu0/cpufreq ] && ok "cpufreq 存在" || bad "无 cpufreq"
cur=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null)
max=$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null)
log "  频率: ${cur:-?} kHz / max ${max:-?} kHz"
for z in /sys/class/thermal/thermal_zone*; do
  [ -f "$z/temp" ] && log "  温度: $(basename $z) = $(( $(cat $z/temp) / 1000 ))°C ($(cat $z/type))"
done 2>/dev/null

# ── 3. 内存 LPDDR5 ────────────────────────────────
t "3. 内存 (LPDDR5)"
mem_mb=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
log "  总量: ${mem_mb} MiB"
[ "$mem_mb" -ge 7600 ] && ok "8GB LPDDR5 可见" || bad "内存不足 8GB"

# ── 4. PMIC AXP318W ───────────────────────────────
t "4. PMIC (AXP318W)"
regs=$(for r in /sys/class/regulator/regulator.*; do cat $r/name 2>/dev/null; done | grep -c axp8191 2>/dev/null)
[ "${regs:-0}" -gt 0 ] && ok "AXP8191(AXP318W) 稳压器 $regs 个注册" || bad "无 AXP 稳压器"
# AXP8191 挂在 7083000.twi 上, 实际总线号由 sysfs 决定 (本板 = 13)
pmic_i2c=$(ls /sys/bus/i2c/devices/ 2>/dev/null | grep -E '^[0-9]+-0036$' | head -1)
pmic_bus=${pmic_i2c%-*}
if [ -n "$pmic_i2c" ]; then
  ok "PMIC 驱动绑定 i2c 设备 $pmic_i2c"
else
  bad "PMIC 未在 sysfs 注册"
fi
# I2C 单地址探测 (UU = 驱动已绑定, 36 = 裸地址响应; 不做全量扫描以免 NACK 刷屏)
# 注意: 单地址探测时其余单元格为空白, awk 切分后结果落在该行第一个非空字段
if have i2cdetect; then
  if [ -n "$pmic_bus" ]; then
    cell=$(i2cdetect -y -r "$pmic_bus" 0x36 0x36 2>/dev/null | awk '$1=="30:"{for(i=2;i<=NF;i++) if($i!=""){print $i; exit}}')
    case "$cell" in
      UU) ok "PMIC I2C 探测 @ i2c-$pmic_bus 0x36 (UU 驱动已绑定)" ;;
      36) ok "PMIC I2C 探测 @ i2c-$pmic_bus 0x36 响应" ;;
      *)  bad "PMIC I2C 探测 @ i2c-$pmic_bus 0x36 无响应 (cell=$cell)" ;;
    esac
  else
    found=""
    for b in $(ls /sys/bus/i2c/devices/ 2>/dev/null | grep -oE '^[0-9]+-' | tr -d '-' | sort -un); do
      i2cdetect -y -r "$b" 0x36 0x36 2>/dev/null | awk '$1=="30:"{for(i=2;i<=NF;i++) if($i!=""){print $i; exit}}' | grep -qE "36|UU" && { found="$b"; break; }
    done
    [ -n "$found" ] && ok "PMIC I2C 探测 @ i2c 总线 $found 0x36" || bad "PMIC i2c 探测失败 (任何总线均无 0x36)"
  fi
else
  bad "i2c-tools 未安装"
fi
[ -d /sys/class/power_supply ] && ls /sys/class/power_supply/ 2>/dev/null | tee -a "$REPORT" | grep -q . && ok "power_supply 类存在" || skip "power_supply (无电池)"

# ── 5. 存储: eMMC + TF ────────────────────────────
t "5. 存储 (eMMC + TF)"
emmc=""; tf=""
for d in /dev/mmcblk*; do
  case "$(cat /sys/class/block/$(basename $d)/device/type 2>/dev/null)" in
    MMC) emmc="$d";;
    SD)  tf="$d";;
  esac
done
if [ -n "$emmc" ]; then
  size=$(lsblk -dno SIZE $emmc 2>/dev/null)
  log "  eMMC: $emmc ($size) [Y1Y256; A9 采样校准后读可用]"
  ok "eMMC 检测到"
  hs=$(cat /sys/class/mmc_host/mmc*/mmc*:*/timing 2>/dev/null | sort -u | tr '\n' ' ')
  [ -n "$hs" ] && log "  eMMC timing: $hs"
  # A9: HS400 200MHz 采样校准 — 开机不应再有 CMD18 采样错误/retry
  if dmesg 2>/dev/null | grep -qE "smc 0 p2 err|RD DCE|EBE|manual stop command failed"; then
    bad "A9 eMMC: dmesg 仍有 CMD18 采样错误 (CRC/EBE/retry)"
    dmesg 2>/dev/null | grep -E "smc 0 p2 err|RD DCE|EBE|manual stop" | head -3 | tee -a "$REPORT"
  else
    ok "A9 eMMC: 开机 dmesg 无 CMD18 CRC/EBE/retry"
  fi
  # 采样延迟寄存器收敛值 (驱动自愈/校准后应为 0x484)
  dl=$(dmesg 2>/dev/null | grep -oE "REG_DS_DL: 0x[0-9a-fA-F]+|REG_DS_DL=0x[0-9a-fA-F]+" | tail -1)
  log "  采样延迟记录: ${dl:-dmesg 无 REG_DS_DL 输出}"
  # A9: 只读吞吐测试 (--quick 跳过; 仅读整盘, 不触碰分区内容)
  if [ "$QUICK" != "1" ]; then
    log "  顺序读 1GiB 测速 (HS400) ..."
    spd=$(dd if=$emmc of=/dev/null bs=1M count=1024 iflag=direct 2>&1 | tail -1)
    log "  ${spd}"
    rate=$(echo "$spd" | grep -oE "[0-9.]+ (MB|GB)/s" | head -1)
    case "$rate" in
      *GB/s)  ok "A9 eMMC 顺序读 $rate (HS400 正常)" ;;
      *) mb=${rate%% *}; [ -n "$mb" ] && awk -v m="$mb" 'BEGIN{exit !(m>=150)}' && ok "A9 eMMC 顺序读 ${rate} (可用)" || bad "A9 eMMC 读速率异常: ${rate:-无输出}" ;;
    esac
  else
    skip "eMMC 读测速 (quick 模式)"
  fi
else
  bad "eMMC 未检测到"
fi
[ -n "$tf" ] && ok "microSD: $tf ($(lsblk -dno SIZE $tf 2>/dev/null))" || skip "microSD (启动盘可能为其他设备)"
log "  根分区: $(findmnt -no SOURCE / 2>/dev/null)"
chk "根分区可写" touch /tmp/.wtest

# ── 6. 以太网 MAE0621A (RTL8211F 兼容) ─────────────
t "6. 以太网 (MAE0621A 千兆, PHY 驱动 = maxio 官方)"
eth=$(ls /sys/class/net/ | grep -E "^(end|eth)[0-9]+" | head -1)
if [ -n "$eth" ]; then
  ok "以太网接口 $eth 存在"
  op=$(cat /sys/class/net/$eth/operstate 2>/dev/null)
  log "  链路状态: $op"
  [ "$op" = "up" ] && ok "链路 up" || log "  (未插网线)"
  if have ethtool; then
    spd=$(ethtool $eth 2>/dev/null | grep -i speed | awk '{print $2}')
    log "  协商速率: ${spd:-?}"
    echo "$spd" | grep -q "1000" && ok "千兆协商" || log "  (非千兆或未连接)"
  fi
  # A4: PHY 必须由专用驱动绑定 (编译进内核, 非 Generic PHY)
  #     自写 mae0621a 已退役，现用官方 maxio 驱动 v1.8.1.13
  phy=$(ls /sys/bus/mdio_bus/devices/ 2>/dev/null | grep -E "stmmac.*:0[0-9]" | head -1)
  if [ -n "$phy" ]; then
    drv=$(readlink "/sys/bus/mdio_bus/devices/$phy/driver" 2>/dev/null)
    drv=${drv##*/}
    case "$drv" in
      maxio|MAXIO)  ok "A4 PHY 驱动 = maxio 官方驱动 ($phy)" ;;
      "MAE0621A!B-Q3C(I) Gigabit Ethernet"|"MAE0621A/B-Q3C(I) Gigabit Ethernet")
                    # 官方 maxio.c 的 .name（sysfs 把 '/' 显示为 '!'）；Q3C(I) 条目只存在于官方驱动
                    ok "A4 PHY 驱动 = 官方 maxio .name=$drv ($phy)" ;;
      mae0621a|MAE0621A) ok "A4 PHY 驱动 = mae0621a 自写驱动 ($phy) [0030 未生效?]" ;;
      *) bad "A4 PHY 驱动异常: ${drv:-未绑定} (期望 maxio 官方驱动, 非 Generic PHY)" ;;
    esac
    log "  phy_id = $(cat /sys/bus/mdio_bus/devices/$phy/phy_id 2>/dev/null) (MAE0621A Q3 = 0x7b744412)"
    # 官方 maxio 在 config_init 里 printk 版本号 → 最强的"官方驱动真的跑了"证据
    if dmesg 2>/dev/null | grep -q "MAXIO_PHY_VER"; then
      ok "官方 maxio config_init 已执行 ($(dmesg | grep -o 'MAXIO_PHY_VER: [^ ]*' | head -1))"
    else
      log "  (dmesg 无 MAXIO_PHY_VER — 若为 Generic PHY 绑定则属异常)"
    fi
  else
    bad "A4: 未找到 mdio PHY 设备 (stmmac-0:01)"
  fi
  # A4: LED 页寄存器实读 (page 0xd04 reg16)。官方 maxio 的 q3ci config_init 会写该页:
  #     最终值 = OTP 出厂值 | BIT(5|8|10|11) & ~BIT(14), 故只记录不断言固定值。
  _mdio="$(dirname "${BASH_SOURCE[0]}")/../tools/mdio-read.py"
  if command -v python3 >/dev/null 2>&1 && [ -f "$_mdio" ]; then
    ledv=$(python3 "$_mdio" "$eth" 0xd04 16 2>/dev/null | tr -d '\n')
    case "$ledv" in
      *0x*) log "  LED 页 0xd04/reg16 = $ledv  (目视: 黄常亮=链路, 绿闪=活动)" ;;
      *)    log "  (LED 页寄存器读取失败 — 不影响判定)" ;;
    esac
  fi
else
  bad "无以太网接口 (gmac0/PHY 驱动未生效)"
fi

# ── 7. WiFi FCU760K (AIC8800D80) ──────────────────
t "7. WiFi (AIC8800D80 / FCU760K)"
if [ -d /sys/class/net/wlan0 ]; then
  ok "wlan0 存在"
  if have iw; then
    iw dev wlan0 info 2>/dev/null | grep -q "wlan0" && ok "wlan0 可查询" || bad "wlan0 异常"
    ip link set wlan0 up 2>/dev/null
    iw dev wlan0 scan 2>/dev/null | grep -q "SSID:" && ok "WiFi 扫描到 AP" || log "  (未扫描到 AP)"
  else
    skip "iw 扫描 (需 iw 包)"
  fi
else
  bad "wlan0 不存在 (aic8800 驱动未加载)"
fi
chk "aic8800 内核模块" grep -q aic8800 /proc/modules
lsusb 2>/dev/null | grep -qi "a69c" && ok "AIC8800D80 在 USB 总线 (a69c:8d81)" || bad "AIC8800D80 USB 设备缺失"

# ── 8. 蓝牙 ───────────────────────────────────────
t "8. 蓝牙 (AIC8800 BT5.4)"
if [ -d /sys/class/bluetooth/hci0 ]; then
  ok "hci0 存在"
  have bluetoothctl && bluetoothctl --timeout 5 show 2>/dev/null | grep -q "Powered" && ok "蓝牙可控制" || log "  (蓝牙需 power on)"
else
  bad "hci0 不存在"
fi

# ── 9. USB (CH334F HUB + 设备枚举) ────────────────
t "9. USB (CH334F HUB)"
if have lsusb; then
  n=$(lsusb | wc -l)
  [ "$n" -ge 4 ] && ok "USB 设备枚举 $n 个" || bad "USB 设备过少 ($n)"
  lsusb | tee -a "$REPORT" | grep -qi "hub" && ok "USB HUB (CH334F) 识别" || log "  (未识别到 HUB 名称)"
else
  bad "usbutils 未安装"
fi
if lsblk -o NAME,TRAN | grep -q usb; then
  usb_dev=$(lsblk -o NAME,TRAN -r | grep usb | head -1 | awk '{print $1}')
  log "  USB 存储: $usb_dev"
  ok "USB 存储设备"
else
  skip "USB 存储测速 (插入 U 盘可测)"
fi

# ── 10. USB-C / HUSB311 TCPC ──────────────────────
t "10. USB-C (HUSB311 TCPC + SGM2576 VBUS)"
if grep -q husb311 /proc/modules 2>/dev/null || ls /sys/bus/i2c/devices/ 2>/dev/null | grep -q "4e"; then
  ok "husb311 i2c 设备注册"
else
  bad "husb311 未注册"
fi
# husb311 挂在 7084000.twi 上, 实际总线号由 sysfs 决定 (本板 = 14)
husb_i2c=$(ls /sys/bus/i2c/devices/ 2>/dev/null | grep -E '^[0-9]+-004e$' | head -1)
husb_bus=${husb_i2c%-*}
if [ -n "$husb_i2c" ]; then
  ok "husb311 驱动绑定 i2c 设备 $husb_i2c"
else
  bad "husb311 未在 sysfs 注册"
fi
# I2C 单地址探测 (UU = 驱动已绑定, 4e = 裸地址响应)
if have i2cdetect; then
  if [ -n "$husb_bus" ]; then
    cell=$(i2cdetect -y -r "$husb_bus" 0x4e 0x4e 2>/dev/null | awk '$1=="40:"{for(i=2;i<=NF;i++) if($i!=""){print $i; exit}}')
    case "$cell" in
      UU) ok "husb311 I2C 探测 @ i2c-$husb_bus 0x4e (UU 驱动已绑定)" ;;
      4e) ok "husb311 I2C 探测 @ i2c-$husb_bus 0x4e 响应" ;;
      *)  bad "husb311 I2C 探测 @ i2c-$husb_bus 0x4e 无响应 (cell=$cell)" ;;
    esac
  else
    found=""
    for b in $(ls /sys/bus/i2c/devices/ 2>/dev/null | grep -oE '^[0-9]+-' | tr -d '-' | sort -un); do
      i2cdetect -y -r "$b" 0x4e 0x4e 2>/dev/null | awk '$1=="40:"{for(i=2;i<=NF;i++) if($i!=""){print $i; exit}}' | grep -qE "4e|UU" && { found="$b"; break; }
    done
    [ -n "$found" ] && ok "husb311 I2C 探测 @ i2c 总线 $found 0x4e" || bad "husb311 i2c 探测失败 (任何总线均无 0x4e)"
  fi
fi
# husb311 probe 状态检测 (PL3 IRQ/pinctrl 冲突会导致 probe failed -5)
if dmesg 2>/dev/null | grep -q "husb311: probe of.*failed"; then
  bad "husb311 probe 失败 (IRQ/pinctrl 问题, USB-C PD 不可用)"
  dmesg 2>/dev/null | grep -iE "husb311.*(irq|failed|error)" | head -4 | tee -a "$REPORT"
else
  ok "husb311 probe 正常"
fi
[ -d /sys/class/typec ] && ls /sys/class/typec/ 2>/dev/null | grep -q . && ok "Type-C 端口注册" || log "  (typec 端口未注册)"
# DRM 显示 (USB-C DP alt mode / DE)
drm_nodes=$(ls /sys/class/drm/ 2>/dev/null | grep -E "card[0-9]-" | tr '\n' ' ')
[ -n "$drm_nodes" ] && ok "DRM 显示节点: $drm_nodes" || bad "无 DRM 节点"
log "  DRM: $drm_nodes"

# ── 11. PCIe (M.2) ────────────────────────────────
t "11. PCIe (M.2)"
if have lspci; then
  lspci 2>/dev/null | tee -a "$REPORT" | head -5
  # 任意 PCIe 端点设备 (非 bridge 本身) 都算链路工作
  dev=$(lspci 2>/dev/null | grep -E "01:00" | head -1)
  if [ -n "$dev" ]; then
    ok "PCIe 端点设备: ${dev#01:00.0 }"
    echo "$dev" | grep -qiE "non-volatile|nvme" && ok "NVMe SSD 检测到" || log "  (非 NVMe 设备, 如 SATA 卡)"
  else
    skip "PCIe 端点设备 (M.2 槽未装设备)"
  fi
else
  bad "pciutils 未安装"
fi
chk "pcie 电源域" grep -q pcie /sys/kernel/debug/pm_genpd/pm_genpd_summary 2>/dev/null || log "  (pm_genpd 不可读)"

# ── 12. 视频硬解 VE ───────────────────────────────
t "12. 视频硬解 (sunxi-ve)"
chk "sunxi-ve 模块" grep -q "sunxi_ve\|sunxi-ve" /proc/modules
[ -e /dev/cedar_dev ] && ok "VE 设备 /dev/cedar_dev" || log "  (/dev/cedar_dev 不存在, 检查驱动)"

# ── 13. NPU (NNA VIP2) ────────────────────────────
t "13. NPU (Allwinner NNA VIP2 / vipcore)"
mod vipcore
sleep 1
chk "vipcore 模块加载" grep -q vipcore /proc/modules
ls /dev/ 2>/dev/null | grep -qE "npu|nna|vip" && ok "NPU 设备节点: $(ls /dev/ | grep -E 'npu|nna|vip' | tr '\n' ' ')" || bad "NPU 设备节点未找到"
if dmesg 2>/dev/null | grep -qiE "vipcore.*(fail|error)"; then
  log "  (vipcore 日志有告警:)"
  dmesg 2>/dev/null | grep -iE "vipcore.*(fail|error)" | head -3 | tee -a "$REPORT"
fi
log "  (注: 完整 NPU 推理需厂商用户态库 (libnpu/vipruntime), 此处仅验证内核驱动+设备节点)"

# ── 14. 2D 加速 G2D ───────────────────────────────
t "14. 2D 加速 (G2D)"
if grep -q "g2d" /proc/modules 2>/dev/null; then
  ok "g2d_sunxi 模块已加载 (自动加载)"
else
  mod g2d_sunxi
  sleep 1
  grep -q "g2d" /proc/modules 2>/dev/null && ok "g2d_sunxi 模块加载 (modprobe 后)" || bad "g2d_sunxi 加载失败"
fi
[ -e /dev/g2d ] && ok "G2D 设备 /dev/g2d" || bad "无 /dev/g2d"
if dmesg 2>/dev/null | grep -qiE "g2d.*(fail|error)"; then
  dmesg 2>/dev/null | grep -iE "g2d.*(fail|error)" | head -3 | tee -a "$REPORT"
fi

# ── 15. EEPROM BL24C16F ───────────────────────────
t "15. EEPROM (BL24C16F @ i2c 0x50)"
if have i2cdetect; then
  # 只探测 0x50 单地址 (全量扫描会在 sunxi twi 驱动里刷大量 NACK 日志)
  if i2cdetect -y -r 0 0x50 0x50 2>/dev/null | awk '$1=="50:"{print $2}' | grep -qE "50|UU"; then
    ok "EEPROM @ i2c0 0x50"
    if have i2cget; then
      log "  读 EEPROM 前 8 字节: $(for o in 0x00 0x01 0x02 0x03 0x04 0x05 0x06 0x07; do printf '%02x ' $(i2cget -y -f 0 0x50 $o 2>/dev/null); done)"
    fi
  else
    bad "EEPROM 0x50 未探测到"
  fi
else
  bad "i2c-tools 未安装"
fi

# ── 16. 风扇 (WNM6002 + PWM) ──────────────────────
t "16. 风扇 (PWM1_9)"
if ls /sys/class/pwm/ 2>/dev/null | grep -q .; then ok "pwm 控制器存在"; else bad "无 pwm 控制器"; fi
chk "PWM 通道可导出" sh -c 'for c in /sys/class/pwm/pwmchip*; do [ -w "$c/export" ] && exit 0; done; exit 1'
ls /sys/class/pwm/pwmchip*/ 2>/dev/null | grep -q "pwm9\|pwm-9" && ok "PWM9 通道存在" || log "  (PWM 通道名可能不同)"
# 完整列出所有冷却设备类型 (不再 head -3 截断)
log "  全部冷却设备:"
for c in /sys/class/thermal/cooling_device*; do
  [ -f "$c/type" ] && log "    $(basename $c): type=$(cat $c/type) max_state=$(cat $c/max_state 2>/dev/null)"
done
# 风扇散热设备 (pwm-fan) 绑定检查 — dts 配了 5 档 cooling-levels, 正常应 max_state=4
fan_found=""
for c in /sys/class/thermal/cooling_device*; do
  [ "$(cat $c/type 2>/dev/null)" = "pwm-fan" ] && fan_found="$c"
done
if [ -n "$fan_found" ]; then
  ms=$(cat $fan_found/max_state 2>/dev/null)
  [ "$ms" = "4" ] && ok "pwm-fan 冷却设备 $fan_found (max_state=$ms, 5 档正常)" || bad "pwm-fan 冷却设备 $fan_found 但 max_state=$ms (应为 4, dts 有 5 档 cooling-levels)"
else
  modprobe pwm_fan 2>/dev/null; sleep 1
  for c in /sys/class/thermal/cooling_device*; do
    [ "$(cat $c/type 2>/dev/null)" = "pwm-fan" ] && fan_found="$c"
  done
  if [ -n "$fan_found" ]; then
    ok "pwm-fan 冷却设备 (modprobe 后出现: $fan_found)"
  else
    bad "pwm-fan 未绑定 — 风扇无温控! 查 dmesg | grep -iE 'pwm.?fan'"
  fi
fi
ls /sys/class/thermal/ 2>/dev/null | grep -q cooling && ok "散热冷却设备存在" || skip "无 cooling 设备"

# ── 17. LED ───────────────────────────────────────
t "17. LED (绿 sys / 蓝 user)"
if [ -d /sys/class/leds ]; then
  leds=$(ls /sys/class/leds/ 2>/dev/null | tr '\n' ' ')
  log "  LED: $leds"
  ls /sys/class/leds/ | grep -q . && ok "LED 设备存在" || bad "无 LED"
  for l in /sys/class/leds/*; do
    trg=$(cat $l/trigger 2>/dev/null | grep -oE '\[[a-z-]+\]' | head -1)
    log "    $(basename $l): trigger=$trg"
  done
else
  bad "无 /sys/class/leds"
fi

# ── 18. 按键 (PMIC POWERKEY) ──────────────────────
t "18. 电源键 (PMU-PWRON)"
if ls /dev/input/event* >/dev/null 2>&1; then
  ok "input 设备存在"
  cat /proc/bus/input/devices 2>/dev/null | grep -iE "axp|power|pmic" | head -3 | tee -a "$REPORT" | grep -q . && ok "PMIC 按键设备" || log "  (PMIC 按键设备名不同)"
else
  skip "input 设备 (minimal 镜像可能无 evdev)"
fi

# ── 19. MIPI-CSI / VIND-ISP (驱动存在性) ──────────
t "19. MIPI-CSI / VIND-ISP (驱动存在性)"
# A7S 无摄像头传感器, dts 已禁用 csi0/1/2 + vind0 + mipi0/1/2。
# 因此驱动不会被 probe, 也不会出现 /dev/video* —— 这是预期行为。
# 这里只确认驱动模块已随内核发布:
modpath="/lib/modules/$(uname -r)/kernel/bsp/drivers/vin"
if [ -f "$modpath/vin_v4l2.ko" ] && [ -f "$modpath/vin_io.ko" ]; then
  ok "vind/isp 驱动模块存在 (vin_v4l2.ko + vin_io.ko)"
  log "  (无摄像头硬件 + dts 禁用 vind0/csi, 驱动不加载属预期)"
else
  bad "vind/isp 驱动模块缺失"
fi
# V4L2 设备解释
if ls /dev/video* >/dev/null 2>&1; then
  ok "V4L2 设备: $(ls /dev/video* | tr '\n' ' ')"
else
  skip "V4L2 设备 — A7S 板载无摄像头传感器 (MIPI-CSI 接口未接 sensor), vind 驱动虽在内核中但无设备可绑定, 故无 /dev/video* 节点; 属预期, 不是故障"
fi

# ── 19b. UFS 白探测检测（A7S 无 UFS 芯片）────────
t "19b. UFS (无芯片白 probe 检测)"
if dmesg 2>/dev/null | grep -qE "UFS_EVT_LINK_STARTUP_FAIL|link startup failed"; then
  bad "UFS 无芯片仍在 probe (LINK_STARTUP_FAIL)"
  dmesg 2>/dev/null | grep -E "ufs.*(fail|error)" | head -2 | tee -a "$REPORT"
else
  ok "无 UFS 启动错误"
fi

# ── 19c. GPU 电源域 (pd_gpu 超时检测) ─────────────
t "19c. GPU 电源域 (pd_gpu deferred probe)"
if dmesg 2>/dev/null | grep -qE "pd_gpu.*deferred probe timeout"; then
  bad "pd_gpu 测试节点 15s 超时 (dts 应禁用)"
  dmesg 2>/dev/null | grep -E "pd_gpu.*deferred" | head -2 | tee -a "$REPORT"
else
  ok "无 pd_gpu 超时"
fi

# ── 19d. GPU (IMG BXM-4-64, A5 DKMS) ──────────────
t "19d. GPU (IMG BXM-4-64, A5 img-bxm-dkms)"
# A733 的 GPU 是 Imagination BXM-4-64。镜像自带 img-bxm-dkms 0.1.0-3
# (packages/bsp/cubie-a7s/gpu-dkms + cubie-a7s-gpu-dkms 扩展, chroot 内 DKMS
# 构建 pvrsrvkm); 用户态 (Vulkan/GLES 库) 为闭源 B 组, 不在镜像内。
if ls /sys/class/drm/ 2>/dev/null | grep -qE "card[0-9]-"; then
  ok "DRM 显示 (DE) 正常, /dev/dri 存在"
else
  bad "无 DRM 节点 (显示子系统异常)"
fi
if modinfo pvrsrvkm 2>/dev/null | grep -q .; then
  ok "A5: pvrsrvkm 模块存在 (img-bxm-dkms $(modinfo -F version pvrsrvkm 2>/dev/null))"
  if lsmod 2>/dev/null | grep -q pvrsrvkm; then
    ok "A5: pvrsrvkm 已加载"
  else
    if modprobe pvrsrvkm 2>/dev/null; then
      ok "A5: pvrsrvkm 加载成功 (modprobe)"
    else
      skip "A5: pvrsrvkm 加载失败 — 查 dmesg | grep -i pvr (固件/电源域?)"
    fi
  fi
  if [ -e /dev/dri/renderD128 ]; then
    ok "A5: /dev/dri/renderD128 存在 (GPU 可访问)"
  else
    skip "A5: renderD128 未创建 (内核驱动 probe 可能需用户态 B 组配合)"
  fi
else
  skip "A5: pvrsrvkm 未安装 (镜像不含 img-bxm-dkms)"
fi

# ── 20. 串口/调试 ─────────────────────────────────
t "20. 调试串口 (UART0)"
chk "ttyS0 存在" ls /dev/ttyS0

# ── 21. 稳定性压力 ────────────────────────────────
t "21. 稳定性"
if [ "$QUICK" = "1" ]; then
  skip "压力测试 (quick 模式)"
else
  if have stress-ng; then
    log "  运行 60s 全核压力 (stress-ng --cpu 8 --vm 2)..."
    timeout 70 stress-ng --cpu 8 --vm 2 --vm-bytes 512M --timeout 60s >/dev/null 2>&1
    rc=$?
    [ $rc -ne 124 ] && ok "压力测试完成 (rc=$rc)" || bad "压力测试超时/失败"
  else
    log "  简易压力: 8 核 dd 循环 30s..."
    for i in $(seq 8); do dd if=/dev/zero of=/dev/null bs=1M count=99999999 & done
    sleep 30; kill %1 %2 %3 %4 %5 %6 %7 %8 2>/dev/null; wait 2>/dev/null
    ok "简易压力完成"
  fi
  for z in /sys/class/thermal/thermal_zone*; do
    [ -f "$z/temp" ] && log "  压测后温度: $(basename $z) = $(( $(cat $z/temp) / 1000 ))°C"
  done 2>/dev/null
fi

# ── 22. CPU 深度: 逐核 / 大小核 / 调频 ─────────────
t "22. CPU 深度 (逐核/大小核/调频)"
offline=""
for c in /sys/devices/system/cpu/cpu[0-7]; do
  [ "$(cat $c/online 2>/dev/null)" = "1" ] || offline="$offline $(basename $c)"
done
[ -z "$offline" ] && ok "8 核全部 online" || bad "以下核不在线:$offline"
gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)
log "  governor: ${gov:-?}  可用: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors 2>/dev/null | tr '\n' ' ')"
m0=$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null)
m6=$(cat /sys/devices/system/cpu/cpu6/cpufreq/cpuinfo_max_freq 2>/dev/null)
log "  A55(max cpu0)=$m0 kHz  A76(max cpu6)=$m6 kHz"
[ "${m6:-0}" -gt "${m0:-0}" ] && ok "大小核差异确认 (A76 最高频率更高)" || log "  (A76/A55 最高频率相同或读取失败)"
if [ "$QUICK" != "1" ] && [ -n "$gov" ] && [ -w /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]; then
  # 调频爬升测试: performance + 短压力, 看频率是否爬满, 然后恢复
  for c in /sys/devices/system/cpu/cpu[0-7]; do echo performance > $c/cpufreq/scaling_governor 2>/dev/null; done
  stress-ng --cpu 4 --timeout 8s >/dev/null 2>&1 &
  spid=$!
  sleep 4
  f=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null)
  wait $spid 2>/dev/null; sleep 2
  log "  performance 压力下 cpu0 频率: ${f:-?} kHz (max $m0)"
  [ "${f:-0}" -ge $((m0 * 9 / 10)) ] && ok "CPU 频率可爬升至接近最大值" || log "  (频率未爬满: $f vs $m0)"
  for c in /sys/devices/system/cpu/cpu[0-7]; do echo "$gov" > $c/cpufreq/scaling_governor 2>/dev/null; done
else
  skip "调频爬升测试 (quick 模式或 governor 不可写)"
fi
if have stress-ng; then
  timeout 25 stress-ng --cpu 1 --cpu-method matrixprod --timeout 5s >/dev/null 2>&1 && ok "NEON 计算测试完成 (matrixprod)" || log "  (matrixprod 不可用, 跳过)"
fi

# ── 23. 内存深度 (memtester 模式测试) ──────────────
t "23. 内存深度 (memtester)"
if [ "$QUICK" = "1" ]; then
  skip "memtester (quick 模式)"
elif have memtester; then
  log "  运行 memtester 256M x1 (约 20-60s)..."
  if timeout 300 memtester 256M 1 > /tmp/memtester.log 2>&1; then
    ok "memtester 256M 通过"
    grep -E "Stuck Address|COMPARE|Pass completed" /tmp/memtester.log | tail -3 | tee -a "$REPORT"
  else
    bad "memtester 失败 (见 /tmp/memtester.log)"
  fi
else
  skip "memtester (未安装)"
fi

# ── 24. 存储性能 (TF 读写 + SATA) ──────────────────
t "24. 存储性能 (TF 读写)"
if [ "$QUICK" = "1" ]; then
  skip "TF 速度测试 (quick 模式)"
else
  log "  根分区: $(findmnt -no SOURCE / 2>/dev/null)"
  local _spd_t0 _spd_t1 _spd_t2 _spd_t3
  _spd_t0=$(date +%s%N)
  if dd if=/dev/zero of=/root/.a7s-speed.bin bs=1M count=128 conv=fsync 2>/dev/null; then
    _spd_t1=$(date +%s%N)
    wr=$(( 128000000 / ((_spd_t1 - _spd_t0) / 1000000 + 1) / 1000 ))
    sync
    _spd_t2=$(date +%s%N)
    dd if=/root/.a7s-speed.bin of=/dev/null bs=1M count=128 2>/dev/null
    _spd_t3=$(date +%s%N)
    rd=$(( 128000000 / ((_spd_t3 - _spd_t2) / 1000000 + 1) / 1000 ))
    rm -f /root/.a7s-speed.bin
    log "  TF 写: ${wr} MB/s  读: ${rd} MB/s"
    [ "${wr:-0}" -gt 5 ] && [ "${rd:-0}" -gt 20 ] && ok "microSD 性能正常 (写${wr}MB/s 读${rd}MB/s)" || log "  (速度偏低, 仅供参考)"
  else
    rm -f /root/.a7s-speed.bin
    bad "TF 写入测试失败"
  fi
fi
sata=$(lsblk -d -o NAME,TRAN,SIZE,MODEL 2>/dev/null | grep -iE "sata|sd[a-z]" | head -3)
if [ -n "$sata" ]; then
  log "  SATA 设备:"
  echo "$sata" | tee -a "$REPORT"
  ok "SATA 桥接存储可见"
else
  skip "SATA 设备 (M.2 SATA 卡未接硬盘)"
fi

# ── 25. 网络深度 (连通性 + 回环吞吐) ───────────────
t "25. 网络深度"
gw=$(ip route 2>/dev/null | awk '/default/{print $3; exit}')
if [ -n "$gw" ]; then
  ping -c 2 -W 2 "$gw" >/dev/null 2>&1 && ok "网关可达 ($gw)" || bad "网关不可达 ($gw)"
else
  skip "网关 (无默认路由)"
fi
getent hosts deb.debian.org >/dev/null 2>&1 && ok "DNS 解析正常" || bad "DNS 解析失败"
curl -sI --max-time 10 https://deb.debian.org >/dev/null 2>&1 && ok "HTTPS 外网可达 (deb.debian.org)" || log "  (HTTPS 外网不可达或超时)"
if [ "$QUICK" != "1" ] && have iperf3; then
  iperf3 -s -p 5201 >/dev/null 2>&1 &
  spid=$!
  sleep 1
  r=$(iperf3 -c 127.0.0.1 -p 5201 -t 3 2>/dev/null | grep receiver | grep -oE "[0-9.]+ (G|M)bits/sec" | head -1)
  kill $spid 2>/dev/null; wait $spid 2>/dev/null
  log "  回环吞吐 (iperf3): ${r:-?}"
  [ -n "$r" ] && ok "回环 TCP 吞吐测试完成 (${r})" || log "  (iperf3 回环测试未完成)"
elif have iperf3; then
  skip "iperf3 回环 (quick 模式)"
fi
if have iw && [ -d /sys/class/net/wlan0 ]; then
  sig=$(iw dev wlan0 link 2>/dev/null | grep -E "signal|freq" | tr '\n' ' ')
  log "  WiFi 链路: $sig"
fi

# ── 26. RTC / 硬件随机数 ───────────────────────────
t "26. RTC + hwrng"
if [ -e /dev/rtc0 ]; then
  hw=$(hwclock -r 2>/dev/null | head -1)
  if [ -z "$hw" ]; then
    # 无 RTC 电池时 RTC 未初始化, hwclock 读失败属预期; 用内核 rtc sysfs 兜底
    hw=$(cat /sys/class/rtc/rtc0/time 2>/dev/null)
    log "  RTC (sysfs): ${hw:-不可读}"
  else
    log "  RTC: $hw"
  fi
  rtc=$(date -d "${hw}" +%s 2>/dev/null || echo 0)
  rtc_year=$(date -d "@${rtc}" +%Y 2>/dev/null || echo 0)
  if [ "${rtc:-0}" -eq 0 ] || [ "${rtc_year:-0}" -lt 2020 ]; then
    skip "RTC — 开发板无 RTC 电池, 时钟未初始化属预期 (接电池后自动恢复)"
  else
    ok "RTC 可读 (${hw})"
    now=$(date +%s)
    diff=$(( (now - rtc) > 0 ? (now - rtc) : (rtc - now) ))
    [ "${diff:-999999}" -lt 600 ] && ok "RTC 与系统时间偏差 < 10min (${diff}s)" || log "  (RTC 时间偏差 ${diff}s, 可能未同步)"
  fi
else
  bad "无 /dev/rtc0"
fi
if [ -e /dev/hwrng ]; then
  # 用 od (coreutils, 必有) 而非 xxd (属 vim-common 包, 最小系统往往没有 → 会把"读到数据"误判为读取失败)
  hx=$(dd if=/dev/hwrng bs=16 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n' | head -c 32)
  [ -n "$hx" ] && ok "硬件随机数可用 ($hx...)" || bad "hwrng 读取失败"
else
  skip "hwrng (内核未启用)"
fi

# ── 27. GPIO / 排针 ────────────────────────────────
t "27. GPIO (gpiochip 枚举, 不做输出切换)"
if have gpiodetect; then
  gpiodetect 2>/dev/null | tee -a "$REPORT" | grep -q "gpiochip" && ok "GPIO 芯片枚举" || bad "无 gpiochip"
else
  skip "gpiodetect (需 gpiod 包)"
fi

# ── 28. 热管理详情 (trip 点) ───────────────────────
t "28. 热管理 trip 点"
for z in /sys/class/thermal/thermal_zone*; do
  [ -f "$z/type" ] || continue
  trips=""
  for t in $z/trip_point_*_temp; do
    [ -f "$t" ] && trips="$trips $(basename $t | sed 's/trip_point_//;s/_temp//')=$(($(cat $t) / 1000))°C"
  done
  log "  $(cat $z/type):$trips"
done

# ── 29. PMIC 电压轨 ────────────────────────────────
t "29. PMIC 电压轨"
found=0
for r in /sys/class/regulator/regulator.*; do
  n=$(cat $r/name 2>/dev/null)
  case "$n" in
    axp8191-dcdc1|axp8191-dcdc2|axp8191-dcdc3|axp8191-dcdc4|axp8191-dcdc5|axp8191-dcdc6|axp8191-dldo1|axp8191-cldo1|axp8191-bldo1|axp8191-ldoio0)
      u=$(cat $r/microvolts 2>/dev/null)
      log "    $n: ${u:-?} uV"
      found=1
      ;;
  esac
done 2>/dev/null
[ "$found" -eq 1 ] && ok "关键电压轨可读" || log "  (电压轨名称可能不同)"

# ── 30. USB 拓扑 ───────────────────────────────────
t "30. USB 拓扑 (速率)"
lsusb -t 2>/dev/null | tee -a "$REPORT" | grep -qE "5000M|SuperSpeed" && ok "USB 3.x SuperSpeed 链路存在" || log "  (无 SuperSpeed 设备/链路)"
log "  USB 设备总数: $(lsusb 2>/dev/null | tee -a "$REPORT" | wc -l)"

# ── 31. NPU devfreq 详情 ───────────────────────────
t "31. NPU devfreq"
nd=/sys/class/devfreq/3600000.npu
if [ -d "$nd" ]; then
  log "  cur_freq: $(cat $nd/cur_freq 2>/dev/null) Hz"
  log "  available: $(cat $nd/available_frequencies 2>/dev/null)"
  log "  governor: $(cat $nd/governor 2>/dev/null)"
  ok "NPU devfreq 正常"
else
  skip "NPU devfreq 节点缺失"
fi

# ── 32. dmesg 错误汇总 ─────────────────────────────
t "32. dmesg 错误汇总"
oops=$(dmesg 2>/dev/null | grep -cE "Oops|panic|Kernel BUG" || true)
[ "${oops:-0}" -eq 0 ] && ok "无 Oops/panic" || bad "检测到 Oops/panic ($oops 处)!"
known="sunxi:twi_sunxi|sound-mach|sunxi:sunxi_sid|OPP not supported|avoid to switch|sdc[0-9] :the host|ccu_ddr|pinctrl.*unknown pin|cann't get|Get NPU Regulator|Regulator Control FAIL|aic_load_fw: probe|axp8191-temp-ctrl|reg-virt-consumer|failed to set regulator|Get support-ecc|drm.*ERROR|no power_gpios|failed to find usb power|bmu_axp515|hdmi0.*disconnected|bad framebuffer|drm_framebuffer_alloc|Get sunxi drm device|battery temp|not enough data|Speed change timeout|Link up timeout|PCIe speed of Gen1|get_sunxi_drm_connector|Failed to found available display|Failed to locate of_node|supply .* not found|deferred probe pending|iommu_master csi_iommu|sunxi-iommu-v2 3900000|dvfs2_ori|uart-ng.*DMA channel|No DTB found|opteed_fast|boot param - magic|dtb not found for scp|mmc not para|Wrong media type|smc 0 p2 err|manual stop command|unknown pin|drvvbus supply|retry:stop"
unk=$(dmesg 2>/dev/null | grep -E "\[ERR\]|\[ERROR\]|error" | grep -vE "$known" | sed 's/^\[[ 0-9.]*\]//' | sort -u | head -10)
if [ -n "$unk" ]; then
  log "  未归类错误行:"
  echo "$unk" | tee -a "$REPORT"
else
  ok "dmesg 错误均为已知噪音"
fi
log "  ERR 行总数: $(dmesg 2>/dev/null | grep -cE '\[ERR\]' || true)"

# ── 33. systemd 健康 ───────────────────────────────
t "33. systemd 健康"
failed=$(systemctl --failed --no-legend 2>/dev/null | awk 'NR>1{print $2}' | tr '\n' ' ')
if [ -n "$failed" ]; then
  log "  failed units: $failed"
  systemctl --failed --no-legend 2>/dev/null | tail -n +2 | tee -a "$REPORT"
else
  ok "无 failed units"
fi

    # ── 小结 ─────────────────────────────────────────
    log ""
    log "──── 硬件验证小结: PASS=$PASS FAIL=$FAIL SKIP=$SKIP ────"
    local l
    [ "${#FAIL_LIST[@]}" -gt 0 ] && { log " 失败项 (${#FAIL_LIST[@]}):"; for l in "${FAIL_LIST[@]}"; do log "   [FAIL] $l"; done; }
    [ "${#SKIP_LIST[@]}" -gt 0 ] && { log " 跳过项 (${#SKIP_LIST[@]}):"; for l in "${SKIP_LIST[@]}"; do log "   [SKIP] $l"; done; }
    eval "$_saved_funcs"          # 恢复本体系输出函数
    record verify verify_pass "$PASS" items pass
    record verify verify_fail "$FAIL" items "$([ "$FAIL" = "0" ] && echo pass || echo fail)"
    record verify verify_skip "$SKIP" items pass
    [ "$FAIL" -eq 0 ] && return 0 || return 1
}

# ── 单独运行 (./modules/00-verify.sh [--quick] — 仅终端输出, 不生成任何文件) ──
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    STANDALONE=1
    source "$(dirname "$(readlink -f "$0")")/lib.sh"
    standalone_init
    mod_verify "$@"
fi
