#!/bin/bash
# SPDX-License-Identifier: MIT
# ============================================================
# Cubie A7S — tz2hwmon 安装脚本（装完系统后执行）
#   thermal_zone → hwmon 只读桥接: 让 sensors / btop / htop 读到温度
#   v2: 芯片名命中 htop 白名单 (cpu_thermal / soc_thermal), 默认跳过 *_idle_zone 同源别名
#
# 用法:
#   sudo ./install-tz2hwmon.sh              # 编译 → 安装 → 开机自启 → 加载 → 校验
#   sudo ./install-tz2hwmon.sh --prebuilt   # 跳过编译, 直接用仓库内 tz2hwmon.ko
#   sudo ./install-tz2hwmon.sh --no-autoload# 装好但不写 modules-load.d (不随开机加载)
#   sudo ./install-tz2hwmon.sh --status     # 只看状态 (免 root 可读部分)
#   sudo ./install-tz2hwmon.sh --uninstall  # 卸载 (rmmod + 删模块/自启配置)
#
# 说明: 纯只读展示模块; 卸载后内核温控不受任何影响。
# ============================================================
set -uo pipefail

BASE="$(dirname "$(readlink -f "$0")")"
MOD=tz2hwmon
KREL="$(uname -r)"
EXTRA_DIR="/lib/modules/${KREL}/extra"
LOAD_CONF="/etc/modules-load.d/${MOD}.conf"
SRC="$BASE/${MOD}.c"
KO_SRC="$BASE/${MOD}.ko"
KO_DST="${EXTRA_DIR}/${MOD}.ko"
FAIL=0
PREBUILT=0
AUTOLOAD=1
MODE="install"

case "${1:-}" in
    --prebuilt)   PREBUILT=1 ;;
    --no-autoload) AUTOLOAD=0 ;;
    --status)     MODE="status" ;;
    --uninstall)  MODE="uninstall" ;;
    -h|--help)    sed -n '2,15p' "$0"; exit 0 ;;
    "")           ;;
    *)            echo "未知参数: $1 (用 -h 查看用法)"; exit 2 ;;
esac

ok()   { echo "  [OK]   $*"; }
info() { echo "  [..]   $*"; }
bad()  { echo "  [FAIL] $*"; FAIL=1; }
warn() { echo "  [WARN] $*"; }

# htop 3.x 内置的白名单芯片名 (它只认这些名字的温度通道)
HTOP_CHIPS="cpu_thermal soc_thermal acpitz coretemp k10temp zenpower"

need_root() {
    [ "$(id -u)" = "0" ] || { echo "需要 root: sudo $0 ${1:-}"; exit 1; }
}

# ------------------------------------------------------------
# --status: 只读查看
# ------------------------------------------------------------
if [ "$MODE" = "status" ]; then
    echo "=============================================="
    echo " tz2hwmon 状态"
    echo "=============================================="
    if lsmod | grep -q "^${MOD} "; then ok "模块已加载"; else warn "模块未加载"; fi
    [ -f "$KO_DST" ] && ok "已安装: $KO_DST" || info "未安装到 ${EXTRA_DIR}/"
    [ -f "$LOAD_CONF" ] && ok "开机自启: $LOAD_CONF" || info "无开机自启配置"
    echo "--- hwmon 温度通道 ---"
    found=0
    for h in /sys/class/hwmon/hwmon*; do
        [ -r "$h/name" ] || continue
        n="$(cat "$h/name" 2>/dev/null)"
        for f in "$h"/temp*_input; do
            [ -e "$f" ] || continue
            found=$((found + 1))
            lbl=""; [ -r "${f%_input}_label" ] && lbl=" [$(cat "${f%_input}_label")]"
            hit=""; case " $HTOP_CHIPS " in *" $n "*) hit=" ← htop 可见";; esac
            printf "  %-28s %-12s %s%s%s\n" "$n" "$(basename "$f")" \
                   "$(awk '{printf "%.1f°C", $1/1000}' "$f")" "$lbl" "$hit"
        done
    done
    [ "$found" = "0" ] && warn "没有任何 hwmon 温度通道 (模块未加载?)"
    echo "--- thermal_zone 原始读数 (内核真值) ---"
    for z in /sys/class/thermal/thermal_zone*; do
        printf "  %-16s %-20s %.1f°C\n" "$(basename "$z")" \
               "$(cat "$z/type" 2>/dev/null)" "$(awk '{print $1/1000}' "$z/temp" 2>/dev/null)"
    done
    exit 0
fi

# ------------------------------------------------------------
# --uninstall: 卸载
# ------------------------------------------------------------
if [ "$MODE" = "uninstall" ]; then
    need_root --uninstall
    echo "=============================================="
    echo " tz2hwmon 卸载"
    echo "=============================================="
    if lsmod | grep -q "^${MOD} "; then
        rmmod "$MOD" && ok "已卸载模块" || bad "rmmod 失败 (被占用?)"
    else
        info "模块未加载"
    fi
    [ -f "$LOAD_CONF" ] && { rm -f "$LOAD_CONF"; ok "删除 $LOAD_CONF"; } || info "无自启配置"
    [ -f "$KO_DST" ] && { rm -f "$KO_DST"; ok "删除 $KO_DST"; } || info "无已安装模块"
    depmod -a "$KREL" && ok "depmod 完成"
    echo "----------------------------------------------"
    [ "$FAIL" = "0" ] && echo " 卸载完成 ✅ (内核温控无影响)" || echo " 有失败项 ❌"
    exit $FAIL
fi

# ------------------------------------------------------------
# [0/5] 前置检查
# ------------------------------------------------------------
need_root
echo "=============================================="
echo " [0/5] 前置检查"
echo "=============================================="
ok "内核: $KREL"
if [ -d "/lib/modules/${KREL}/build" ]; then
    ok "内核头文件: /lib/modules/${KREL}/build"
else
    bad "缺内核头文件 (${KREL}); 请装 linux-headers-${KREL} 或改用 --prebuilt"
fi
[ -r /sys/class/thermal/thermal_zone0/temp ] && ok "thermal_zone 可用" || bad "无 /sys/class/thermal/thermal_zone*"
zone_n=$(ls -d /sys/class/thermal/thermal_zone* 2>/dev/null | wc -l)
ok "检测到 ${zone_n} 个 thermal_zone"

# ------------------------------------------------------------
# [1/5] 编译
# ------------------------------------------------------------
echo "=============================================="
echo " [1/5] 编译模块"
echo "=============================================="
if [ "$PREBUILT" = "1" ]; then
    info "--prebuilt: 跳过编译"
    [ -f "$KO_SRC" ] && ok "使用仓库内 ${MOD}.ko" || bad "仓库内缺 ${MOD}.ko"
else
    if make -C "$BASE" >/tmp/${MOD}-build.log 2>&1; then
        ok "编译成功 (日志 /tmp/${MOD}-build.log)"
    else
        bad "编译失败:"; tail -5 /tmp/${MOD}-build.log | sed 's/^/         /'
    fi
fi
if [ -f "$KO_SRC" ]; then
    vmag="$(modinfo -F vermagic "$KO_SRC" 2>/dev/null | awk '{print $1}')"
    if [ "$vmag" = "$KREL" ]; then
        ok "vermagic 匹配: $vmag"
    else
        bad "vermagic 不匹配: 模块=$vmag 内核=$KREL (需针对本内核重编, 去掉 --prebuilt)"
    fi
fi
[ "$FAIL" != "0" ] && { echo; echo " 编译/校验失败, 中止 ❌"; exit 1; }

# ------------------------------------------------------------
# [2/5] 安装到 /lib/modules + 开机自启
# ------------------------------------------------------------
echo "=============================================="
echo " [2/5] 安装模块与开机自启"
echo "=============================================="
mkdir -p "$EXTRA_DIR"
install -m644 "$KO_SRC" "$KO_DST" && ok "安装: $KO_DST"
depmod -a "$KREL" && ok "depmod 完成"
if [ "$AUTOLOAD" = "1" ]; then
    echo "$MOD" > "$LOAD_CONF" && ok "开机自启: $LOAD_CONF"
else
    info "--no-autoload: 未写自启配置"
fi

# ------------------------------------------------------------
# [3/5] 加载模块
# ------------------------------------------------------------
echo "=============================================="
echo " [3/5] 加载模块"
echo "=============================================="
if lsmod | grep -q "^${MOD} "; then
    info "已加载, 重新加载以使新版本生效"
    rmmod "$MOD" 2>/dev/null
fi
if modprobe "$MOD" && lsmod | grep -q "^${MOD} "; then
    ok "modprobe $MOD 成功 (运行期不写 dmesg; 通道见下一步校验)"
else
    bad "modprobe 失败 (dmesg | grep tz2hwmon 查看)"
fi

# ------------------------------------------------------------
# [4/5] 校验: hwmon 通道 + htop 可见性
# ------------------------------------------------------------
echo "=============================================="
echo " [4/5] 校验 hwmon 通道"
echo "=============================================="
ch=0; htop_seen=0
for h in /sys/class/hwmon/hwmon*; do
    [ -r "$h/name" ] || continue
    n="$(cat "$h/name" 2>/dev/null)"
    [ -e "$h/temp1_input" ] || continue
    ch=$((ch + 1))
    lbl=""; [ -r "$h/temp1_label" ] && lbl=" [$(cat "$h/temp1_label")]"
    hit=""
    case " $HTOP_CHIPS " in *" $n "*) hit=" ← htop 可见"; htop_seen=$((htop_seen + 1));; esac
    printf "  %-24s %8.1f°C%s%s\n" "$n" \
           "$(awk '{print $1/1000}' "$h/temp1_input")" "$lbl" "$hit"
done
[ "$ch" -gt 0 ] && ok "共 ${ch} 路温度通道" || bad "没有出现 hwmon 温度通道"
if [ "$htop_seen" -gt 0 ]; then
    ok "其中 ${htop_seen} 路命中 htop 白名单芯片名"
else
    warn "没有命中 htop 白名单 (htop 温度表头仍会空白); 请检查 tz2hwmon.c 的 tz_pick_names()"
fi

# ------------------------------------------------------------
# [5/5] 使用提示
# ------------------------------------------------------------
echo "=============================================="
echo " [5/5] 使用"
echo "=============================================="
if [ -r "$HOME/.config/htop/htoprc" ] && grep -q "show_cpu_temperature=1" "$HOME/.config/htop/htoprc" 2>/dev/null; then
    ok "htop 已启用温度显示 (show_cpu_temperature=1)"
else
    info "htop 显示温度需在 ~/.config/htop/htoprc 设 show_cpu_temperature=1 (或在 htop 里 F2→Display options 勾选)"
fi
if command -v sensors >/dev/null; then
    info "sensors 可用: 直接运行 sensors 查看全部通道"
else
    info "可选: sudo apt install lm-sensors 后可用 sensors 查看 (htop/btop 不需要它)"
fi
info "看状态: sudo $0 --status     卸载: sudo $0 --uninstall"
echo "----------------------------------------------"
if [ "$FAIL" = "0" ]; then
    echo " tz2hwmon 安装完成, 校验通过 ✅"
else
    echo " 存在失败项, 请检查上述输出 ❌"
fi
echo "=============================================="
exit $FAIL
