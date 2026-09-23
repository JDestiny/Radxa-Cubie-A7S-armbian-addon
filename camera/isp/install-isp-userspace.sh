#!/bin/bash
# SPDX-License-Identifier: MIT
# 相机 ISP / cedarc 用户态栈安装（B 类，camera/isp/）
#
# 装什么（两个官方 deb，包内路径已核对，不猜）：
#   libAWIspApi-isp-602-arm64 1.0.1  →  /usr/lib/aarch64-linux-gnu/{libisp_ini.so,libisp.so,libAWIspApi.so}
#                                        + /usr/include/{AWIspApi.h,sunxi_camera_v2.h} + /usr/bin/AWISPdemo
#   libcedarc-dev-2.0.0-arm64 1.0.7  →  12 个新库（libvencoder/libvenc_codec/libvenc_base/…）+ 2 个 demo
#                                        + /usr/include/*.h（VE 用户态已装的 15 个同版本文件不重复动）
#
# 为什么必须装 libisp_ini.so：
#   内核驱动 + overlay 只让相机"出图"，**颜色对不对取决于 libisp_ini.so 里有没有该 sensor 的 tuning 档**。
#   官方 issue #19（A7S + IMX415）就是缺 IMX415 档 → 回退 ov13850 档 → 红/品红偏色。
#   1.0.1 版已含该档（判定方式见 --status 的 imx415 计数）。
#
# 安全策略（默认不覆盖任何已有的库）：
#   * 15 个与本机逐字节相同的 cedarc 库 → 跳过（无需动）
#   * 3 个同名但内容不同（libOmxCore/libOmxVdec/libOmxVenc）→ **默认跳过并告警**，
#     因为它们属于已验证可用的 VE 硬解栈；确需覆盖时用 --force（会先备份到 /var/backups/camera-isp/）
#
# 用法:
#   sudo $0 install [--isp-only] [--force]   # 默认=ISP 三件套 + cedarc 新增项（不覆盖已有库）
#   sudo $0 --status                          # 只读：装了什么、生效没、含不含 imx415 档
#   sudo $0 --uninstall                       # 按 manifest 卸载；有备份则还原
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
PKGS="$HERE/pkgs"
LIBDIR=/usr/lib/aarch64-linux-gnu
INCDIR=/usr/include
BINDIR=/usr/bin
STATE=/var/lib/camera-isp
BACKUP_ROOT=/var/backups/camera-isp
MANIFEST="$STATE/manifest.txt"

ISP_DEB=libAWIspApi_602_1.0.0_arm64.deb
CEDARC_DEB=libcedarc-dev_2.0.0_arm64.deb
ISP_SHA=112012255a3f3e7d33faa63241dea8b6e3ab081d1ef63c56c0e656e5b5978fc9
CEDARC_SHA=ccd5da2403837f1c5a566239124eaa66c56b6bbcb485308dd7ad7ec6d8d0d3a4
DL_BASE=https://raw.githubusercontent.com/radxa/allwinner-debian/main/packages/arm64
PROXY_HINT='export https_proxy=http://192.168.123.9:5102 http_proxy=http://192.168.123.9:5102'

ISP_SOS="libisp_ini.so libisp.so libAWIspApi.so"

need_root() { [ "$(id -u)" = 0 ] || { echo "需要 root: sudo $0 $*"; exit 1; }; }

# ── deb 就位（优先用仓库内 pkgs/，缺失则按 URL+sha256 下载） ──────────────
ensure_deb() {  # $1=文件名 $2=sha256 $3=URL 子路径
  local f="$PKGS/$1"
  if [ -s "$f" ]; then
    if [ "$(sha256sum "$f" | cut -d' ' -f1)" = "$2" ]; then echo "  [OK] 用仓库内 $1"; return 0; fi
    echo "  [WARN] $1 校验失败，重新下载"
  fi
  mkdir -p "$PKGS"
  echo "  [..] 下载 $1"
  if ! command -v curl >/dev/null; then echo "  [FAIL] 无 curl"; return 1; fi
  if ! curl -sSL --max-time 240 -o "$f" "$DL_BASE/$3"; then echo "  [FAIL] 下载失败（需要代理：$PROXY_HINT）"; return 1; fi
  local got; got="$(sha256sum "$f" | cut -d' ' -f1)"
  [ "$got" = "$2" ] || { echo "  [FAIL] sha256 不符：期望 $2 实际 $got"; return 1; }
  echo "  [OK] 下载并校验通过 $1"
}

install_one() {  # $1=源文件 $2=目标  [--force 时允许覆盖]
  local src="$1" dst="$2" force="$3"
  if [ -e "$dst" ] && ! cmp -s "$src" "$dst"; then
    if [ "$force" != "force" ]; then
      echo "  [WARN] 已存在且内容不同，跳过（未覆盖）: $dst"; return 2
    fi
    local bdir="$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$bdir$(dirname "$dst")"
    cp -a "$dst" "$bdir$dst" && echo "  [OK] 已备份原文件 → $bdir$dst"
  fi
  install -D -m "$(stat -c%a "$src")" "$src" "$dst" || { echo "  [FAIL] 写入 $dst 失败"; return 1; }
  return 0
}

do_install() {
  need_root install
  local isp_only=0 force=0 a
  for a in "$@"; do case "$a" in
    --isp-only) isp_only=1 ;;
    --force)    force=force ;;
    *) echo "  [FAIL] 未知参数 '$a'"; exit 1 ;;
  esac; done

  echo "[1/4] 准备 deb"
  ensure_deb "$ISP_DEB" "$ISP_SHA" "libAWIspApi/$ISP_DEB" || exit 1
  [ "$isp_only" = 1 ] || ensure_deb "$CEDARC_DEB" "$CEDARC_SHA" "libcedarc/$CEDARC_DEB" || exit 1

  WORK="$(mktemp -d /tmp/isp-install.XXXXXX)"; work="$WORK"; trap 'rm -rf "${work:-}"' EXIT
  echo "[2/4] 解包"
  dpkg-deb -x "$PKGS/$ISP_DEB" "$work/isp" || { echo "  [FAIL] ISP 包解包失败"; exit 1; }
  echo "  [OK] $ISP_DEB"
  if [ "$isp_only" = 0 ]; then
    dpkg-deb -x "$PKGS/$CEDARC_DEB" "$work/cedarc" || { echo "  [FAIL] cedarc 包解包失败"; exit 1; }
    echo "  [OK] $CEDARC_DEB"
  fi

  mkdir -p "$STATE"; : > "$MANIFEST"
  local ok=0 skip=0 fail=0 so
  echo "[3/4] 安装 ISP 三件套"
  for so in $ISP_SOS; do
    local src="$work/isp$LIBDIR/$so"
    [ -f "$src" ] || { echo "  [FAIL] 包内没有 $so（包结构变了？）"; fail=$((fail+1)); continue; }
    install_one "$src" "$LIBDIR/$so" force; case $? in
      0) echo "  [OK] $LIBDIR/$so"; echo "$LIBDIR/$so" >> "$MANIFEST"; ok=$((ok+1)) ;;
      2) skip=$((skip+1)) ;;
      *) fail=$((fail+1)) ;;
    esac
  done
  for h in AWIspApi.h sunxi_camera_v2.h; do
    [ -f "$work/isp$INCDIR/$h" ] && { install -D -m 0644 "$work/isp$INCDIR/$h" "$INCDIR/$h" && echo "  [OK] $INCDIR/$h" && echo "$INCDIR/$h" >> "$MANIFEST" && ok=$((ok+1)); }
  done
  [ -f "$work/isp$BINDIR/AWISPdemo" ] && { install -D -m 0755 "$work/isp$BINDIR/AWISPdemo" "$BINDIR/AWISPdemo" && echo "  [OK] $BINDIR/AWISPdemo" && echo "$BINDIR/AWISPdemo" >> "$MANIFEST" && ok=$((ok+1)); }

  if [ "$isp_only" = 0 ]; then
    echo "[3b/4] 安装 cedarc 新增项（已存在且相同的自动跳过）"
    local f rel
    for f in "$work"/cedarc/usr/lib/aarch64-linux-gnu/*.so "$work"/cedarc/usr/bin/* "$work"/cedarc/usr/include/*.h "$work"/cedarc/etc/cedarc.conf; do
      [ -f "$f" ] || continue
      rel="${f#$work/cedarc}"
      if [ -e "$rel" ] && cmp -s "$f" "$rel"; then skip=$((skip+1)); continue; fi
      install_one "$f" "$rel" "$force"; case $? in
        0) echo "$rel" >> "$MANIFEST"; ok=$((ok+1)) ;;
        2) skip=$((skip+1)) ;;
        *) fail=$((fail+1)) ;;
      esac
    done
  fi

  echo "[4/4] ldconfig"
  ldconfig && echo "  [OK] ldconfig 完成"
  echo
  echo "  结果：安装/更新 $ok 项，跳过 $skip 项（已有或冲突），失败 $fail 项"
  echo "  ⚠️ 3 个 OmxVdec/OmxVenc/OmxCore 若被跳过属**预期**：它们属于已验证的 VE 硬解栈；"
  echo "     确需覆盖请跑 sudo $0 install --force（会先备份到 $BACKUP_ROOT/）"
  echo
  echo "  判成功：sudo $0 --status"
}

do_status() {
  echo "=============================================="
  echo " 相机 ISP / cedarc 用户态栈状态"
  echo "=============================================="
  echo " ── 1. ISP 三件套 ──"
  local so missing=0
  for so in $ISP_SOS; do
    local p="$LIBDIR/$so"
    if [ -f "$p" ]; then printf '   %-18s ✅ %8s 字节  md5 %s\n' "$so" "$(stat -c%s "$p")" "$(md5sum "$p" | cut -c1-8)"
    else printf '   %-18s ⭕ 缺失\n' "$so"; missing=$((missing+1)); fi
  done
  echo " ── 2. libisp_ini.so 是否含 IMX415 tuning 档（#19 的判据） ──"
  if [ -f "$LIBDIR/libisp_ini.so" ]; then
    local n; n="$(strings -a "$LIBDIR/libisp_ini.so" 2>/dev/null | grep -c imx415)"
    printf '   imx415 出现次数: %s  %s\n' "$n" "$([ "$n" -ge 1 ] && echo '✅ 含该档（偏色问题可解）' || echo '❌ 不含 → 会回退 ov13850 档（偏色）')"
    printf '   imx214 出现次数: %s\n' "$(strings -a "$LIBDIR/libisp_ini.so" 2>/dev/null | grep -c imx214)"
  else
    echo "   ⭕ libisp_ini.so 未安装 → 无法判定"
  fi
  echo " ── 3. cedarc / 编码 demo ──"
  local n2=0 b
  for b in libvencoder.so libvenc_codec.so libvenc_base.so libvdecoder.so libVE.so libMemAdapter.so; do
    [ -f "$LIBDIR/$b" ] && n2=$((n2+1))
  done
  printf '   关键 cedarc 库就位: %s/6\n' "$n2"
  for b in AWISPdemo vdecoderdemo vencoderdemo; do
    printf '   %-14s %s\n' "$b" "$([ -x "$BINDIR/$b" ] && echo "✅ $BINDIR/$b" || echo '⭕ 未安装')"
  done
  echo " ── 4. 动态链接器能否解析（ldconfig） ──"
  local lc; lc="$(ldconfig -p 2>/dev/null | grep -E 'libisp\.so|libisp_ini\.so|libAWIspApi\.so' | wc -l)"
  printf '   ldconfig -p 命中 ISP 库: %s/3\n' "$lc"
  if [ -f "$LIBDIR/libAWIspApi.so" ]; then
    if ldd "$LIBDIR/libAWIspApi.so" 2>/dev/null | grep -q 'not found'; then
      echo "   ⚠️ libAWIspApi.so 仍有未解析依赖："; ldd "$LIBDIR/libAWIspApi.so" 2>/dev/null | grep 'not found' | sed 's/^/      /'
    else
      echo "   ✅ libAWIspApi.so 依赖全部解析（libisp.so / libisp_ini.so 已就位）"
    fi
  fi
  echo " ── 5. manifest ──"
  if [ -f "$MANIFEST" ]; then printf '   记录 %s 个已安装路径：%s\n' "$(wc -l < "$MANIFEST")" "$MANIFEST"
  else echo "   无 manifest（说明本脚本没装过）"; fi
  echo " ── 结论 ──"
  if [ "$missing" = 0 ] && [ "$lc" -ge 3 ]; then
    echo "   ✅ 用户态栈已就位 —— 相机出图/偏色的**用户态前提**已满足"
    echo "      （仍需相机实物才能验证出图与色彩；无实物时这里就是终点）"
  else
    echo "   ⭕ 尚未装好：缺 ${missing} 个 ISP 库 / ldconfig 命中 ${lc}/3"
    echo "      → sudo $0 install"
  fi
}

do_uninstall() {
  need_root --uninstall
  [ -f "$MANIFEST" ] || { echo "  没有 manifest，无可卸载（本脚本未装过）"; exit 0; }
  echo "[1/2] 按 manifest 删除"
  local n=0 p
  while read -r p; do
    if [ -e "$p" ]; then rm -f "$p" && { echo "  [OK] 删除 $p"; n=$((n+1)); }; fi
  done < "$MANIFEST"
  local bdir; bdir="$(ls -1d "$BACKUP_ROOT"/* 2>/dev/null | tail -1)"
  if [ -n "$bdir" ]; then
    echo "[2/2] 还原备份（$bdir）"
    (cd "$bdir" && find . -type f | while read -r f; do
      cp -a "$bdir/${f#./}" "/${f#./}" && echo "  [OK] 还原 /${f#./}（权限随备份）"
    done)
  else
    echo "[2/2] 无备份需要还原"
  fi
  rm -rf "$STATE"; ldconfig 2>/dev/null
  echo "  完成（删了 $n 项）。原有的 VE 库未受影响。"
}

case "${1:-}" in
  install)    shift; do_install "$@" ;;
  --status)   do_status ;;
  --uninstall) do_uninstall ;;
  *) sed -n '2,30p' "$0" | sed 's/^# \?//' ;;
esac
