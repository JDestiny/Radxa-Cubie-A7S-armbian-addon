#!/bin/bash
# ============================================================
# stress.sh — Cubie A7S 综合测试一键入口 (总分总; 位于 TOOL/ 根, 报告落 TOOL/reports/)
# ============================================================
# 结构:
#   [总] 环境快照 + 配置概览
#   [分] 按配置依次运行各模块 (全硬件验证 + CPU/内存带宽/存储IO/加密/GPU/NPU/混合/网络/governor/容器/长时)
#   [总] 汇总表 + PASS/FAIL/SKIP 统计 + 温度
#
# 模式:
#   全测 (默认): 全硬件验证全章节 (85+ 项) + 标准压测  (~40min)
#   --quick:     硬件验证快速 + 短压测 (冒烟)          (~6-7min)
#   --no-stress: 只做验证类模块 (硬件验证; 等价 --only verify)  (~5min)
#
# 报告: 单个日志文件, 直接落在 TOOL/ 根目录 (不建子文件夹):
#   测试报告-<YYYYMMDD>-stress-full.log   全测 (默认)
#   测试报告-<YYYYMMDD>-quick.log         --quick 快速模式
#   测试报告-<YYYYMMDD>-no-stress.log     仅验证类模块 (--no-stress / --only verify / 配置只开 VERIFY)
#   文件内含: 环境快照 + 各模块输出(含工具原始输出) + 汇总表 + 统计 + 温度 + 结论
#
# 用法:
#   sudo ./stress.sh                      # 使用 stress.conf (本脚本位于 TOOL/ 根, 直接运行)
#   sudo ./stress.sh --quick              # 快速模式 (短时长, 覆盖配置)
#   sudo ./stress.sh -c my.conf           # 指定配置文件
#   sudo ./stress.sh --only gpu,npu       # 只跑指定模块 (逗号分隔)
#   sudo ./stress.sh --list               # 列出模块与启用状态
#   sudo ./stress.sh --no-stress          # 只跑验证类模块: 全硬件验证 + A/B 适配项核验
# ============================================================
set -u
SELF_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"   # = TOOL 根目录 (脚本直接位于此)
TOOL_DIR="$SELF_DIR"
TOOLS_DIR="${SELF_DIR}/modules/tools"   # 底层工具 (GPU / NPU / CPU / 温度)
CONF="${SELF_DIR}/stress.conf"
QUICK=0
ONLY=""

while [ $# -gt 0 ]; do
    case "$1" in
        --quick) QUICK=1 ;;
        -c) shift; CONF="$1" ;;
        --only) shift; ONLY="$1" ;;
        # --no-stress = 只做"验证"类模块: 全硬件验证 + A/B 适配项核验（后者 2026-09-20 新增, 只增不减）
        --no-stress) ONLY="verify" ;;
        --list) LIST_ONLY=1 ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "未知参数: $1"; exit 2 ;;
    esac
    shift
done

# ---------- 载入配置 ----------
[ -f "$CONF" ] || { echo "配置文件不存在: $CONF"; exit 2; }
# shellcheck disable=SC1090
source "$CONF"

# ---------- 快速模式覆盖 ----------
if [ "$QUICK" = "1" ]; then
    CPU_SECONDS="${QUICK_CPU_SECONDS:-60}"
    GPU_SECONDS="${QUICK_GPU_SECONDS:-30}"
    NPU_COUNT="${QUICK_NPU_COUNT:-50}"
    MIXED_SECONDS="${QUICK_MIXED_SECONDS:-60}"
    LONGRUN_SECONDS="${QUICK_LONGRUN_SECONDS:-120}"
    STORAGE_RUNTIME="${QUICK_STORAGE_RUNTIME:-10}"
    CRYPTO_SECONDS="${QUICK_CRYPTO_SECONDS:-1}"
    NETWORK_SECONDS="${QUICK_NETWORK_SECONDS:-10}"
    GOVERNOR_SECONDS="${QUICK_GOVERNOR_SECONDS:-8}"
fi

# ---------- 报告输出: 单个报告文件, 直接落 TOOL 根 (OUT_DIR 可覆盖) ----------
: "${OUT_DIR:=${SELF_DIR}}"
mkdir -p "$OUT_DIR"
MODE_TAG="stress-full"                       # 默认全测
[ "$QUICK" = "1" ] && MODE_TAG="quick"       # 快速模式
# 仅"验证类"模块 (verify) → 报告名用 no-stress
if [ "$QUICK" != "1" ] && [ -n "$ONLY" ]; then
    _only_vmods=1
    IFS=',' read -ra _om <<< "$ONLY"
    for _m in "${_om[@]}"; do
        case "$_m" in verify) ;; *) _only_vmods=0 ;; esac
    done
    [ "$_only_vmods" = "1" ] && MODE_TAG="no-stress"
    unset _om _only_vmods
fi
REPORT_FILE="${OUT_DIR}/测试报告-$(date +%Y%m%d)-${MODE_TAG}.log"
MERGED_LOG="$REPORT_FILE"                    # 所有内容写入这一个文件
RESULTS_TSV="$(mktemp /tmp/stress-results-$$-XXXXXX)"   # 内部结果表 (结束即删)
trap 'rm -f "$RESULTS_TSV"' EXIT
: > "$REPORT_FILE"
: > "$RESULTS_TSV"

source "${SELF_DIR}/modules/lib.sh"
# 快速模式标志 (供模块内部判断, 如 verify 调用 v8 --quick)
QUICK_MODE_INT="$QUICK"
# 加载全部模块 (modules/NN-name.sh, 按文件名排序)
for _m in "${SELF_DIR}"/modules/[0-9]*.sh; do
    # shellcheck disable=SC1090
    source "$_m"
done
unset _m

# ---------- 模块注册表 (顺序 = 执行顺序) ----------
MODULES=(verify cpu membw storage crypto gpu npu mixed network governor container longrun)
declare -A MOD_FUNC=(
    [verify]=mod_verify
    [cpu]=mod_cpu [membw]=mod_membw [storage]=mod_storage [crypto]=mod_crypto
    [gpu]=mod_gpu [npu]=mod_npu [mixed]=mod_mixed [network]=mod_network
    [governor]=mod_governor [container]=mod_container [longrun]=mod_longrun
)
declare -A MOD_ENABLE=(
    [verify]=${VERIFY:-1}
    [cpu]=${CPU:-1} [membw]=${MEMBW:-1} [storage]=${STORAGE:-1} [crypto]=${CRYPTO:-1}
    [gpu]=${GPU:-1} [npu]=${NPU:-1} [mixed]=${MIXED:-1} [network]=${NETWORK:-1}
    [governor]=${GOVERNOR:-1} [container]=${CONTAINER:-1} [longrun]=${LONGRUN:-0}
)

# 仅验证配置 (VERIFY=1 且压测模块全关) → 报告名用 no-stress
_only_verify=1
for _m in cpu membw storage crypto gpu npu mixed network governor container longrun; do
    [ "${MOD_ENABLE[$_m]:-0}" = "1" ] && _only_verify=0
done
if [ "$_only_verify" = "1" ] && [ "$QUICK" != "1" ]; then
    MODE_TAG="no-stress"; REPORT_FILE="${OUT_DIR}/测试报告-$(date +%Y%m%d)-${MODE_TAG}.log"; MERGED_LOG="$REPORT_FILE"; : > "$REPORT_FILE"
fi

enabled() { # enabled <mod> → 1/0 (考虑 --only)
    local m="$1"
    [ "${MOD_ENABLE[$m]:-0}" = "1" ] || return 1
    if [ -n "$ONLY" ]; then
        case ",$ONLY," in *",$m,"*) return 0;; *) return 1;; esac
    fi
    return 0
}

# ---------- --list ----------
if [ "${LIST_ONLY:-0}" = "1" ]; then
    echo "模块           启用  说明"
    echo "----           ----  ----"
    for m in "${MODULES[@]}"; do
        local_en="禁用"; enabled "$m" && local_en="启用"
        printf "%-14s %-5s\n" "$m" "$local_en"
    done
    echo; echo "配置文件: $CONF"
    exit 0
fi

# ---------- [总] 开始 ----------
echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║   Cubie A7S 综合压测 (stress)                        ║"
echo "║   报告文件: ${REPORT_FILE}"
echo "╚══════════════════════════════════════════════════════╝"
{
    echo "══════════════════════════════════════════════════════"
    echo " Cubie A7S 压测报告"
    echo " 开始时间: $(date '+%F %T %Z')"
    echo " 模式: ${MODE_TAG} $([ "$QUICK" = "1" ] && echo '(快速)')"
    echo " 配置文件: ${CONF}"
    echo "══════════════════════════════════════════════════════"
} >> "$REPORT_FILE"
env_snapshot >/dev/null
info "配置: $CONF $([ "$QUICK" = 1 ] && echo '(快速模式)')"
info "启用模块: $(for m in "${MODULES[@]}"; do enabled "$m" && printf '%s ' "$m"; done)"
T_START=$(date +%s)

# ---------- [分] 逐模块 ----------
FAILED_MODULES=()
for m in "${MODULES[@]}"; do
    if enabled "$m"; then
        run_module "$m" 1 "${MOD_FUNC[$m]}" || FAILED_MODULES+=("$m")
    else
        run_module "$m" 0 "${MOD_FUNC[$m]}" >/dev/null 2>&1
    fi
done

# ---------- [总] 汇总 ----------
T_TOTAL=$(( $(date +%s) - T_START ))
SUM="$REPORT_FILE"
{
    echo "══════════════════════════════════════════════════════"
    echo " Cubie A7S 压测汇总报告"
    echo " 生成时间: $(date '+%F %T %Z')"
    echo " 系统: $(uname -r)  总耗时: ${T_TOTAL}s"
    echo " 报告输出: ${OUT_DIR}"
    echo "══════════════════════════════════════════════════════"
    echo
    echo "── 各模块结果 ──"
    printf "%-12s %-22s %-12s %-6s\n" "模块" "指标" "数值" "状态"
    printf "%-12s %-22s %-12s %-6s\n" "----" "----" "----" "----"
    awk -F'\t' '{printf "%-12s %-22s %-12s %-6s\n", $1, $2, $3" "$4, $5}' "$RESULT_TSV"
    echo
    echo "── 统计 ──"
    local_pass=$(awk -F'\t' '$5=="pass"' "$RESULT_TSV" | wc -l)
    local_fail=$(awk -F'\t' '$5=="fail"' "$RESULT_TSV" | wc -l)
    local_skip=$(awk -F'\t' '$5=="skip"' "$RESULT_TSV" | wc -l)
    echo "  PASS=$local_pass  FAIL=$local_fail  SKIP=$local_skip"
    [ ${#FAILED_MODULES[@]} -gt 0 ] && echo "  失败模块: ${FAILED_MODULES[*]}"
    echo
    echo "── 温度 (结束) ──"
    for z in cpub cpul gpu npu ddr; do printf "  %-6s %s°C\n" "$z" "$(temp_of $z)"; done
    echo
    echo "── 失败详情 (若有) ──"
    grep -B1 -A3 "\[FAIL\]" "$MERGED_LOG" 2>/dev/null | head -20 || echo "  (无)"
    echo
    echo "── 报告 ──"
    echo "  $(basename "$REPORT_FILE")   (单文件: 环境快照 + 各模块输出 + 工具原始输出 + 本汇总)"
    echo
    echo "══════════════════════════════════════════════════════"
    if [ ${#FAILED_MODULES[@]} -eq 0 ] && [ "$local_fail" = "0" ]; then
        echo " 结论: 全部通过 🎉"
    else
        echo " 结论: 存在失败项 ❌ (见上)"
    fi
    echo "══════════════════════════════════════════════════════"
} >> "$SUM"

# 终端只显示汇总段 (报告文件已含全部模块与工具输出, 不重复刷屏)
_sum_line=$(grep -n "── 各模块结果 ──" "$SUM" | head -1 | cut -d: -f1)
if [ -n "$_sum_line" ]; then tail -n +"$_sum_line" "$SUM"; else cat "$SUM"; fi
echo
echo "报告已保存: ${REPORT_FILE}"
[ ${#FAILED_MODULES[@]} -eq 0 ] && exit 0 || exit 1
