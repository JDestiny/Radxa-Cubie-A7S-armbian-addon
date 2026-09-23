#!/bin/bash
# SPDX-License-Identifier: MIT
# ve/install-ve.sh — Cubie A7S（全志 A733 / sun60iw2p1）VE 视频编解码用户态栈安装
#
# 安装内容：
#   ve/usr-lib/*.so*   →  /usr/lib/aarch64-linux-gnu/   全志闭源编解码库
#   ve/include/*.h     →  /usr/include/                 开发头文件
#   ve/cedarc.conf     →  /etc/cedarc.conf              编解码库运行配置
#
# 用法：
#   sudo ./install-ve.sh              安装 / 更新（默认动作，可重复执行）
#   sudo ./install-ve.sh --force      同名但内容不同的文件也覆盖（覆盖前先备份）
#   sudo ./install-ve.sh --status     只读检查当前状态（无需 root）
#   sudo ./install-ve.sh --uninstall  按 manifest 卸载本脚本安装的文件
#   ./install-ve.sh --help            显示本帮助
#
# 行为约定：
#   * 幂等：目标已存在且与仓库内文件逐字节相同 → 不改动，直接跳过。
#   * 不覆盖同名不同版本：目标已存在且内容不同 → 默认跳过并打印差异提示；
#     确需替换时用 --force，脚本会先把原文件备份到 /var/backups/ve/<时间戳>/。
#   * manifest 只记录本脚本真正写入（新建或覆盖）的路径，--uninstall 也只删这些路径，
#     因此不会误删系统原有的同名文件。
#   * 安装结束自动执行 ldconfig，并做基本自检：库能否被动态链接器解析、
#     演示程序 cedar_smoke 的依赖能否全部解析，最后打印结论。
#   * 本脚本只装用户态文件，不改内核模块、不改设备树；VE 设备节点由内核驱动提供。
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")" && pwd)"
LIB_SRC="$HERE/usr-lib"
INC_SRC="$HERE/include"
CONF_SRC="$HERE/cedarc.conf"
DEMO_BIN="$HERE/cedar_smoke"

LIB_DST=/usr/lib/aarch64-linux-gnu
INC_DST=/usr/include
CONF_DST=/etc/cedarc.conf

STATE_DIR=/var/lib/ve
MANIFEST="$STATE_DIR/manifest.txt"
BACKUP_ROOT=/var/backups/ve

LDCONFIG="$(command -v ldconfig 2>/dev/null || true)"
[ -n "$LDCONFIG" ] || LDCONFIG=/sbin/ldconfig

ARGS="${*:-}"
# 本次安装的临时清单（全局，便于 EXIT trap 清理）
NEW_MANIFEST=""

# 自检结果（由 self_check 填写）
CHK_TOTAL=0
CHK_RESOLVED=0
CHK_NF=0
CHK_CORE=0
CHK_CORE_TOTAL=4

# 统计目录下匹配某个通配模式的文件数（用 glob，兼容源目录是符号链接的情况）
count_files() {
    local n=0 f
    for f in "$1"/$2; do
        [ -f "$f" ] && n=$((n + 1))
    done
    echo "$n"
}

usage() {
    cat <<'EOF'
ve/install-ve.sh — Cubie A7S（全志 A733）VE 视频编解码用户态栈安装

用法：
  sudo ./install-ve.sh              安装 / 更新（默认动作，可重复执行）
  sudo ./install-ve.sh --force      同名但内容不同的文件也覆盖（覆盖前先备份）
  sudo ./install-ve.sh --status     只读检查当前状态（无需 root）
  sudo ./install-ve.sh --uninstall  按 manifest 卸载本脚本安装的文件
  ./install-ve.sh --help            显示本帮助

安装位置：
  ve/usr-lib/*.so*   →  /usr/lib/aarch64-linux-gnu/
  ve/include/*.h     →  /usr/include/
  ve/cedarc.conf     →  /etc/cedarc.conf

说明：
  * 可重复执行：已存在且内容相同的文件不会被改动。
  * 已存在但内容不同（同名不同版本）的文件默认不覆盖，只打印提示；
    确需替换用 --force，原文件会先备份到 /var/backups/ve/<时间戳>/。
  * 安装后自动执行 ldconfig 并自检，打印安装结果与结论。
EOF
}

need_root() {
    [ "$(id -u)" = 0 ] || { echo "[FAIL] 需要 root 权限，请用: sudo $0 $ARGS" >&2; exit 1; }
}

# 计数器的输出由调用方负责；返回值约定：
#   0  安装 / 更新成功
#   10 目标已存在且内容相同，且此前由本脚本安装 → 跳过（保留 manifest 记录）
#   11 目标已存在且内容相同，但非本脚本安装 → 保持原文件不动
#   20 目标已存在且内容不同 → 按策略未覆盖
#   1  失败
install_one() {
    local src="$1" dst="$2" force="$3" mode="$4"

    if [ -e "$dst" ]; then
        if cmp -s "$src" "$dst"; then
            if [ -f "$MANIFEST" ] && grep -qxF -- "$dst" "$MANIFEST"; then
                echo "  [SKIP] 已安装且内容相同，无需改动: $dst"
                return 10
            fi
            echo "  [KEEP] 系统已有同名同内容文件，保持不动: $dst"
            return 11
        fi

        if [ "$force" != force ]; then
            echo "  [WARN] 已存在同名但内容不同的文件，未覆盖: $dst"
            printf '         系统现有: %8s 字节  md5 %s\n' "$(stat -c%s "$dst")" "$(md5sum "$dst" | cut -c1-8)"
            printf '         仓库文件: %8s 字节  md5 %s\n' "$(stat -c%s "$src")" "$(md5sum "$src" | cut -c1-8)"
            echo "         确认要替换请执行: sudo $0 --force  （替换前会备份原文件）"
            return 20
        fi

        local bdir="$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)"
        mkdir -p "$bdir$(dirname "$dst")"
        if cp -a "$dst" "$bdir$dst"; then
            echo "  [OK] 原文件已备份 → $bdir$dst"
        else
            echo "  [FAIL] 备份失败，放弃覆盖: $dst"
            return 1
        fi
    fi

    if install -D -m "$mode" "$src" "$dst"; then
        echo "  [OK] $dst"
        return 0
    fi
    echo "  [FAIL] 写入失败: $dst"
    return 1
}

# ldconfig 后自检：库能否被解析、演示程序依赖是否齐全
self_check() {
    local f base missing="" ldout lddout line
    local nf=0 core_ok=0

    ldout="$("$LDCONFIG" -p 2>/dev/null || true)"
    CHK_TOTAL=0
    CHK_RESOLVED=0
    for f in "$LIB_SRC"/*.so*; do
        [ -f "$f" ] || continue
        base="$(basename "$f")"
        CHK_TOTAL=$((CHK_TOTAL + 1))
        # 注意：这里用 here-string 而不是管道。管道的读端若提前退出（grep -q），
        # 写端会收到 SIGPIPE，在 pipefail 下会让整条管道判为非 0。
        if grep -qF "/$base" <<< "$ldout"; then
            CHK_RESOLVED=$((CHK_RESOLVED + 1))
        else
            missing="$missing $base"
        fi
    done
    printf '  ldconfig -p 可解析的库: %s/%s\n' "$CHK_RESOLVED" "$CHK_TOTAL"
    [ -z "$missing" ] || echo "  未解析:$missing"

    CHK_CORE=0
    if [ -x "$DEMO_BIN" ]; then
        lddout="$(ldd "$DEMO_BIN" 2>/dev/null || true)"
        # 只把 "<库名> => not found" 计为“依赖未解析”；glibc 符号版本提示（version `GLIBC_x' not found）
        # 属于演示程序编译时所用工具链的问题，与库是否安装无关，单独提示。
        nf="$(grep -c '=> not found' <<< "$lddout" || true)"
        CHK_NF="${nf:-0}"
        local nver
        nver="$(grep -c 'not found' <<< "$lddout" || true)"
        for base in libvdecoder.so libVE.so libMemAdapter.so libvideoengine.so; do
            if grep -qE "^[[:space:]]*${base} => /" <<< "$lddout"; then
                CHK_CORE=$((CHK_CORE + 1))
            fi
        done
        printf '  ldd %s: 关键库解析 %s/%s，未解析依赖 %s 项\n' \
            "$(basename "$DEMO_BIN")" "$CHK_CORE" "$CHK_CORE_TOTAL" "$CHK_NF"
        if [ "$CHK_NF" != 0 ]; then
            grep '=> not found' <<< "$lddout" | sed 's/^/         /'
        fi
        if [ "${nver:-0}" -gt "$CHK_NF" ]; then
            echo "  [NOTE] 另有 $((nver - CHK_NF)) 条 glibc 符号版本提示（属演示程序工具链差异，不影响库安装）。"
        fi
    else
        echo "  [WARN] 找不到演示程序 $DEMO_BIN，跳过 ldd 自检"
    fi
}

do_install() {
    local force="-" a
    for a in "$@"; do
        case "$a" in
            --force) force=force ;;
            *) echo "[FAIL] 未知参数: $a" >&2; exit 1 ;;
        esac
    done
    need_root

    echo "=============================================="
    echo " VE 视频编解码用户态栈安装（Cubie A7S / A733）"
    echo "=============================================="

    echo "[1/5] 检查源文件"
    local n_lib n_inc
    n_lib="$(count_files "$LIB_SRC" '*.so*')"
    n_inc="$(count_files "$INC_SRC" '*.h')"
    [ "${n_lib:-0}" -gt 0 ] || { echo "  [FAIL] $LIB_SRC 下没有库文件（请在 ve/ 目录内运行本脚本）"; exit 1; }
    [ "${n_inc:-0}" -gt 0 ] || { echo "  [FAIL] $INC_SRC 下没有头文件"; exit 1; }
    [ -f "$CONF_SRC" ] || { echo "  [FAIL] 缺少 $CONF_SRC"; exit 1; }
    echo "  [OK] 源目录 $LIB_SRC（$n_lib 个库）"
    echo "  [OK] 源目录 $INC_SRC（$n_inc 个头文件）"
    echo "  [OK] 配置文件 $CONF_SRC"

    mkdir -p "$STATE_DIR"
    NEW_MANIFEST="$STATE_DIR/.manifest.$$"
    : > "$NEW_MANIFEST"
    trap 'rm -f "${NEW_MANIFEST:-}"' EXIT

    local rc f base dst
    local ok=0 skip=0 keep=0 conflict=0 fail=0

    echo "[2/5] 安装库 → $LIB_DST"
    for f in "$LIB_SRC"/*.so*; do
        [ -f "$f" ] || continue
        base="$(basename "$f")"
        dst="$LIB_DST/$base"
        install_one "$f" "$dst" "$force" 0755; rc=$?
        case "$rc" in
            0)  ok=$((ok + 1));       echo "$dst" >> "$NEW_MANIFEST" ;;
            10) skip=$((skip + 1));   echo "$dst" >> "$NEW_MANIFEST" ;;
            11) keep=$((keep + 1)) ;;
            20) conflict=$((conflict + 1)) ;;
            *)  fail=$((fail + 1)) ;;
        esac
    done

    echo "[3/5] 安装头文件 → $INC_DST"
    for f in "$INC_SRC"/*.h; do
        [ -f "$f" ] || continue
        base="$(basename "$f")"
        dst="$INC_DST/$base"
        install_one "$f" "$dst" "$force" 0644; rc=$?
        case "$rc" in
            0)  ok=$((ok + 1));       echo "$dst" >> "$NEW_MANIFEST" ;;
            10) skip=$((skip + 1));   echo "$dst" >> "$NEW_MANIFEST" ;;
            11) keep=$((keep + 1)) ;;
            20) conflict=$((conflict + 1)) ;;
            *)  fail=$((fail + 1)) ;;
        esac
    done

    echo "[4/5] 安装配置 → $CONF_DST"
    install_one "$CONF_SRC" "$CONF_DST" "$force" 0644; rc=$?
    case "$rc" in
        0)  ok=$((ok + 1));       echo "$CONF_DST" >> "$NEW_MANIFEST" ;;
        10) skip=$((skip + 1));   echo "$CONF_DST" >> "$NEW_MANIFEST" ;;
        11) keep=$((keep + 1)) ;;
        20) conflict=$((conflict + 1)) ;;
        *)  fail=$((fail + 1)) ;;
    esac

    echo "[5/5] 刷新动态链接器缓存并自检"
    if "$LDCONFIG" 2>/dev/null; then
        echo "  [OK] ldconfig 完成"
    else
        echo "  [WARN] ldconfig 返回非 0，请手工检查链接器缓存"
    fi
    self_check

    sort -u "$NEW_MANIFEST" > "$MANIFEST"
    rm -f "$NEW_MANIFEST"
    NEW_MANIFEST=""
    trap - EXIT

    echo " ── 安装结果 ──"
    printf '   新建 / 更新      : %s 项\n' "$ok"
    printf '   已安装（内容相同）: %s 项\n' "$skip"
    printf '   系统原有（保留）  : %s 项\n' "$keep"
    printf '   同名不同版本未覆盖: %s 项\n' "$conflict"
    printf '   失败              : %s 项\n' "$fail"
    printf '   安装清单          : %s\n' "$MANIFEST"
    echo " ── 结论 ──"
    if [ "$fail" -gt 0 ]; then
        echo "   ❌ 有 $fail 项写入失败，请按上方 [FAIL] 提示处理后重跑本脚本。"
    elif [ "$CHK_TOTAL" -gt 0 ] && [ "$CHK_RESOLVED" -ne "$CHK_TOTAL" ]; then
        echo "   ❌ 仍有 $((CHK_TOTAL - CHK_RESOLVED)) 个库无法被动态链接器解析，请检查 $LIB_DST 权限与 ldconfig。"
    elif [ "$CHK_NF" != 0 ]; then
        echo "   ⚠️ 库已就位，但演示程序仍有 $CHK_NF 项未解析依赖，请查看上方 ldd 输出。"
    elif [ "$conflict" -gt 0 ]; then
        echo "   ⚠️ 安装完成：$CHK_RESOLVED/$CHK_TOTAL 个库可解析；有 $conflict 个同名不同版本文件按策略未覆盖（见上方 [WARN]）。"
    else
        echo "   ✅ 安装完成：$CHK_RESOLVED/$CHK_TOTAL 个库可被动态链接器解析，演示程序关键依赖 $CHK_CORE/$CHK_CORE_TOTAL 解析正常。"
    fi
    echo "      确认状态: sudo $0 --status    卸载: sudo $0 --uninstall"
    echo "      验证解码: sudo $DEMO_BIN <H.264 裸流文件>   （需内核提供 /dev/cedar_dev）"
}

do_status() {
    echo "=============================================="
    echo " VE 用户态栈状态"
    echo "=============================================="
    echo " ── 1. 库文件（目标 $LIB_DST） ──"
    local f base dst n=0 miss=0
    for f in "$LIB_SRC"/*.so*; do
        [ -f "$f" ] || continue
        base="$(basename "$f")"
        dst="$LIB_DST/$base"
        n=$((n + 1))
        if [ -f "$dst" ]; then
            if cmp -s "$f" "$dst"; then
                printf '   ✅ %-22s %8s 字节  md5 %s\n' "$base" "$(stat -c%s "$dst")" "$(md5sum "$dst" | cut -c1-8)"
            else
                printf '   ⚠️ %-22s 已存在但内容与仓库不同（%s 字节）\n' "$base" "$(stat -c%s "$dst")"
            fi
        else
            printf '   ⭕ %-22s 未安装\n' "$base"
            miss=$((miss + 1))
        fi
    done
    printf '   合计: %s 个库，缺失 %s 个\n' "$n" "$miss"

    echo " ── 2. 头文件（目标 $INC_DST） ──"
    local h ok_h=0
    for h in "$INC_SRC"/*.h; do
        [ -f "$h" ] || continue
        [ -f "$INC_DST/$(basename "$h")" ] && ok_h=$((ok_h + 1))
    done
    printf '   已就位 %s/%s\n' "$ok_h" "$(count_files "$INC_SRC" '*.h')"

    echo " ── 3. 配置文件 ──"
    if [ -f "$CONF_DST" ]; then
        if cmp -s "$CONF_SRC" "$CONF_DST"; then
            echo "   ✅ $CONF_DST（与仓库一致，$(stat -c%s "$CONF_DST") 字节）"
        else
            echo "   ⚠️ $CONF_DST 已存在但内容与仓库不同（$(stat -c%s "$CONF_DST") 字节）"
        fi
    else
        echo "   ⭕ $CONF_DST 未安装"
    fi

    echo " ── 4. 动态链接器解析情况 ──"
    self_check

    echo " ── 5. 内核侧（仅供参考，本脚本不修改） ──"
    local dev
    for dev in /dev/cedar_dev /dev/cedar_dev_ve2; do
        [ -e "$dev" ] && printf '   ✅ %s\n' "$dev" || printf '   ⭕ %s 不存在（缺内核 VE 驱动）\n' "$dev"
    done
    printf '   已加载模块: %s\n' "$(lsmod 2>/dev/null | awk '/^sunxi_ve/{print $1}' | tr '\n' ' ')"

    echo " ── 6. 安装清单 ──"
    if [ -f "$MANIFEST" ]; then
        printf '   记录 %s 个路径: %s\n' "$(wc -l < "$MANIFEST" | tr -d ' ')" "$MANIFEST"
    else
        echo "   无 manifest（本脚本未安装过）"
    fi

    echo " ── 结论 ──"
    if [ "$miss" -eq 0 ] && [ "$CHK_RESOLVED" -eq "$CHK_TOTAL" ] && [ "$CHK_TOTAL" -gt 0 ]; then
        echo "   ✅ 用户态栈已就位（$CHK_RESOLVED/$CHK_TOTAL 个库可解析）"
    else
        echo "   ⭕ 尚未装好：缺失 $miss 个库 / 可解析 $CHK_RESOLVED/$CHK_TOTAL"
        echo "      → sudo $0"
    fi
}

do_uninstall() {
    need_root

    if [ ! -f "$MANIFEST" ]; then
        echo "没有安装清单（$MANIFEST），本脚本未安装过文件，无需卸载。"
        exit 0
    fi

    echo "=============================================="
    echo " VE 用户态栈卸载"
    echo "=============================================="
    echo "[1/3] 删除清单中记录的文件"
    local n=0 p
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        if [ -e "$p" ]; then
            rm -f -- "$p" && { echo "  [OK] 删除 $p"; n=$((n + 1)); }
        else
            echo "  [SKIP] 已不存在: $p"
        fi
    done < "$MANIFEST"
    echo "   共删除 $n 个文件"

    echo "[2/3] 还原 --force 覆盖时的备份"
    local bdir
    bdir="$(ls -1d "$BACKUP_ROOT"/* 2>/dev/null | tail -1 || true)"
    if [ -n "$bdir" ]; then
        ( cd "$bdir" && find . -type f | while IFS= read -r f; do
            cp -a "$bdir/${f#./}" "/${f#./}" && echo "  [OK] 还原 /${f#./}"
        done )
    else
        echo "   无备份需要还原"
    fi

    echo "[3/3] 刷新链接器缓存并清理清单"
    rm -rf "$STATE_DIR"
    if "$LDCONFIG" 2>/dev/null; then
        echo "  [OK] ldconfig 完成"
    else
        echo "  [WARN] ldconfig 返回非 0，请手工检查链接器缓存"
    fi
    echo "  完成：已按清单卸载（未列入清单的同名文件不受影响）。"
}

case "${1:-}" in
    ""|install)
        [ $# -gt 0 ] && shift
        do_install "$@"
        ;;
    --force)
        shift
        do_install --force "$@"
        ;;
    --status)    do_status ;;
    --uninstall) do_uninstall ;;
    -h|--help)   usage ;;
    *) echo "[FAIL] 未知参数: $1" >&2; echo; usage >&2; exit 1 ;;
esac
