#!/bin/bash
# ============================================================
# Cubie A7S — 原版 GPU 驱动安装器（stock = Radxa r6 原始 pvrsrvkm，未改一行）
#   * 只做一件事：把 img-bxm-dkms-src/ 这份**原版**（Radxa r6 原封不动）编译并**持久化安装**为 pvrsrvkm
#   * 与 install-gpu-driver-gpuacct.sh（V6 = 原版 + GPU 利用率记账补丁，htop 能看到 GPU）**完全独立**：两个脚本各自自包含，
#     装哪个由你选；本脚本会把另一个变体从 DKMS 树里摘掉（避免内核升级时双份竞争）
#   * 持久化：DKMS（0.1.0-3）+ 开机 /etc/modules-load.d/pvr.conf 按名加载 + AUTOINSTALL=yes（换内核自动重建）
#
# 用法:
#   sudo ./install-gpu-driver-stock.sh              # 安装/重装（总是重新编译，约 1~2 分钟）
#   sudo ./install-gpu-driver-stock.sh --status     # 只读：看「已加载 / DKMS / 磁盘 ko(=重启后加载谁)」
#   sudo ./install-gpu-driver-stock.sh --reload     # 只重载模块，不重装
#   sudo ./install-gpu-driver-stock.sh --help
#
# 用户态库/固件/ICD 由 install-gpu-userspace.sh 负责（与本脚本无关）。
# ============================================================
set -uo pipefail

BASE="$(dirname "$(readlink -f "$0")")"
KREL="$(uname -r)"
SRC="$BASE/img-bxm-dkms-src"
DKMS_NAME="img-bxm-dkms"
VER="0.1.0-3"
OTHER_VER="0.1.0-3+gpuacct"
MOD=pvrsrvkm
FAIL=0

ok(){ echo "  [OK]   $*"; }
info(){ echo "  [..]   $*"; }
bad(){ echo "  [FAIL] $*"; FAIL=1; }
warn(){ echo "  [WARN] $*"; }
need_root(){ [ "$(id -u)" = "0" ] || { echo "需要 root: sudo $0"; exit 1; }; }

loaded_variant() {   # 运行中的模块是哪个变体
    lsmod | grep -q "^${MOD} " || { echo none; return; }
    grep -qw PVRGpuAcctKick /proc/kallsyms 2>/dev/null && echo gpuacct || echo stock
}
disk_variant() {     # 磁盘上 DKMS 装的那份 = 重启后会加载的
    local ko="/lib/modules/$KREL/updates/dkms/${MOD}.ko"
    [ -f "$ko" ] || { echo none; return; }
    grep -qa PVRGpuAcctKick "$ko" && echo gpuacct || echo stock
}
dkms_variant() {
    dkms status "$DKMS_NAME" 2>/dev/null | grep -q "0\\.1\\.0-3+gpuacct.*installed" && { echo "0.1.0-3+gpuacct"; return; }
    dkms status "$DKMS_NAME" 2>/dev/null | grep -q "0\\.1\\.0-3.*installed" && { echo "0.1.0-3"; return; }
    echo none
}
ko_info() { local ko="/lib/modules/$KREL/updates/dkms/${MOD}.ko"; [ -f "$ko" ] && stat -c '%s B  %y' "$ko" | cut -d. -f1 || echo 缺失; }

# ---------- 只读模式 ----------
if [ "${1:-}" = "--status" ]; then
    echo "=============================================="
    echo " 原版 GPU 驱动安装器（stock = Radxa r6 原始 pvrsrvkm，未改一行）"
    echo "=============================================="
    echo "  本脚本变体 : stock  (DKMS 0.1.0-3)"
    echo "  已加载模块 : $(loaded_variant)  (${MOD} $(lsmod | awk "/^${MOD}/{print \$2}")B)"
    echo "  DKMS 已装  : $(dkms_variant)"
    echo "  磁盘 ko    : $(disk_variant)  ($(ko_info))   ← 重启后将加载这个"
    echo "  开机加载   : $(grep -h . /etc/modules-load.d/pvr.conf 2>/dev/null | head -1) (/etc/modules-load.d/pvr.conf)"
    echo "  内核       : $KREL"
    echo "  源         : $SRC"
    echo "  说明       : 原版驱动 **不输出** drm-engine-pvr → htop 的 GPU 表头/进程 GPU% 列为空（要用 htop 看 GPU 请装 V6 版）"
    exit 0
fi

# ---------- 只重载 ----------
if [ "${1:-}" = "--reload" ]; then
    need_root
    echo "=== 重载 $MOD ==="
    fuser -s /dev/dri/* 2>/dev/null && warn "有进程占用 /dev/dri (将被中断)"
    modprobe -r "$MOD" && ok "已卸载" || { bad "卸载失败 (仍有进程占用?)"; exit 1; }
    sleep 1
    modprobe "$MOD" && ok "已加载: $(loaded_variant)" || { bad "加载失败"; exit 1; }
    exit $FAIL
fi

case "${1:-}" in
    ""|--install) ;;
    -h|--help) awk 'NR>1 && /^#/ {print; next} NR>1 {exit}' "$0"; exit 0 ;;
    *) echo "未知参数: $1  (可用: --status / --reload / --help)"; exit 2 ;;
esac

need_root

echo "=============================================="
echo " 安装 GPU 驱动：原版 stock（DKMS 0.1.0-3）"
echo "=============================================="

# ---------- [0/5] 前置检查 ----------
echo "[0/5] 前置检查"
[ -d "$SRC/img-bxm" ] || { bad "源目录不完整: $SRC"; exit 1; }
ok "源: $SRC  (源码变体: $(grep -rqs PVRGpuAcctKick "$SRC/img-bxm/linux/rogue_km/services" && echo gpuacct || echo stock))"
command -v dkms >/dev/null || { info "安装 dkms..."; apt-get install -y dkms build-essential >/dev/null 2>&1 || true; }
command -v dkms >/dev/null && ok "dkms: $(dkms --version 2>/dev/null | head -1)" || { bad "无 dkms"; exit 1; }
[ -d "/lib/modules/$KREL/build" ] || [ -d "/usr/src/linux-headers-$KREL" ] && ok "内核头文件就绪" || bad "缺内核头文件"

# ---------- [1/5] 停 GPU 占用 ----------
echo "[1/5] 检查 GPU 占用"
if pgrep -x gpu_stress >/dev/null || pgrep -x ocl_stress >/dev/null || pgrep -x vk_stress >/dev/null; then
    warn "检测到 GPU 负载进程, 驱动切换会中断它们"
fi
fuser -s /dev/dri/* 2>/dev/null && warn "有进程持有 /dev/dri 节点" || ok "无进程占用 /dev/dri"

# ---------- [2/5] 暂存源码 ----------
echo "[2/5] 暂存源码到 DKMS"
DST="/usr/src/${DKMS_NAME}-${VER}"
info "复制 $SRC → $DST (首次要几分钟)"
rm -rf "$DST"; mkdir -p "$DST"
cp -a "$SRC/." "$DST/" || { bad "复制失败"; exit 1; }
# 自愈绝对软链: 生成期目录里若含指向仓库路径的软链, 复制到 /usr/src 后仍指回仓库
# (仓库移动/删除就编不过) → 一律改写为 $DST 内的相对链接
fix_links() {
    local l tgt rel n=0
    while IFS= read -r -d '' l; do
        tgt="$(readlink "$l")"
        case "$tgt" in
            "$SRC"/*) rel="$(realpath --relative-to="$(dirname "$l")" "$DST/${tgt#"$SRC"/}" 2>/dev/null)" || continue
                      ln -sfn "$rel" "$l" && n=$((n+1)) ;;
        esac
    done < <(find "$DST" -type l -print0)
    echo "$n"
}
FIXED="$(fix_links)"
[ "$FIXED" -gt 0 ] && ok "修正 $FIXED 个指向仓库的绝对软链 → 树已自包含" || info "无绝对软链需修正"
sed -i "s/^PACKAGE_VERSION=.*/PACKAGE_VERSION=\"${VER}\"/" "$DST/dkms.conf"
ok "dkms.conf PACKAGE_VERSION=$(grep -m1 '^PACKAGE_VERSION' "$DST/dkms.conf" | cut -d'"' -f2)"

# ---------- [3/5] DKMS 构建安装 ----------
echo "[3/5] DKMS 构建与安装 (约 1~2 分钟)"
# 变体互斥: 把**另一个**变体从 DKMS 树里彻底摘掉 (--all = 所有内核), 否则内核升级时
# dkms autoinstall 会把两个版本都编出来, 谁后编谁覆盖 updates/dkms/pvrsrvkm.ko
if dkms status "$DKMS_NAME/$OTHER_VER" 2>/dev/null | grep -q .; then
    info "移除另一变体 $DKMS_NAME/$OTHER_VER (V6 记账补丁版)"
    dkms remove "$DKMS_NAME/$OTHER_VER" --all >/dev/null 2>&1 || true
    dkms status "$DKMS_NAME/$OTHER_VER" 2>/dev/null | grep -q . && warn "另一变体仍在 DKMS 中" || rm -rf "/usr/src/${DKMS_NAME}-${OTHER_VER}"
fi
# 同变体旧构建先摘掉, 保证干净重建
if dkms status "$DKMS_NAME/$VER" 2>/dev/null | grep -q .; then
    info "移除同变体旧构建 $DKMS_NAME/$VER"
    dkms remove "$DKMS_NAME/$VER" --all >/dev/null 2>&1 || true
fi
dkms add "$DST" >/dev/null 2>&1 || true
if dkms install "$DKMS_NAME/$VER" -k "$KREL" >/tmp/dkms-gpu-install-stock.log 2>&1; then
    ok "DKMS 安装成功 ($DKMS_NAME/$VER)"
else
    bad "DKMS 安装失败 (见 /tmp/dkms-gpu-install-stock.log):"
    tail -5 "/tmp/dkms-gpu-install-stock.log" | sed 's/^/         /'
    echo "  提示: 当前运行的模块未被卸载, 系统仍在用原来的驱动; 可参考上面的编译错误修源后重试"
    exit 1
fi

# ---------- [4/5] 重载模块 ----------
echo "[4/5] 重载 GPU 驱动模块"
modprobe -r "$MOD" 2>/dev/null && ok "旧模块已卸载" || warn "旧模块卸载失败 (可能无占用, 继续)"
sleep 1
if modprobe "$MOD"; then
    ok "新模块已加载"
else
    bad "新模块加载失败 (DKMS 已装好, 重启可恢复); 如需回到另一变体请跑对应脚本"
    exit 1
fi
sleep 2

# ---------- [5/5] 校验 ----------
echo "[5/5] 校验"
now="$(loaded_variant)"; disk="$(disk_variant)"; dk="$(dkms_variant)"
[ "$now" != "none" ] && ok "模块驻留, 变体识别: $now" || bad "模块未驻留"
[ -e /dev/dri/renderD128 ] && ok "/dev/dri/renderD128 存在" || bad "缺 /dev/dri/renderD128"
if [ "$now" = "stock" ] && [ "$disk" = "stock" ] && [ "$dk" = "0.1.0-3" ]; then
    ok "持久化: 运行中 = 磁盘 ko = DKMS(0.1.0-3) = stock"
    ok "重启后仍为 stock (由 /etc/modules-load.d/pvr.conf 在开机时按名加载)"
else
    bad "状态不一致: 运行中=$now 磁盘=$disk DKMS=$dk (期望都是 stock/0.1.0-3)"
fi
if [ "$now" = "stock" ]; then
    ok "确认: 原版驱动生效 (fdinfo 无 drm-engine-*，htop 无 GPU 数据)"
fi
echo "──────────────────────────────────────────────"
if [ "$FAIL" = "0" ]; then
    echo " 完成: 当前 GPU 驱动 = 原版 stock（DKMS 0.1.0-3） ✅"
else
    echo " 存在失败项 ❌"
fi
echo " 状态: sudo $0 --status    仅重载: sudo $0 --reload"
echo "──────────────────────────────────────────────"
exit $FAIL
