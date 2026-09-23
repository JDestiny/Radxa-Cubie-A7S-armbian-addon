#!/bin/bash
# ============================================================
# modules/lib.sh — 模块公共库 (双模式)
# ============================================================
# 报告模式: 由 TOOL/stress.sh source → 写入 TOOL/测试报告-<日期>-<模式>.log 单文件
# 独立模式: 模块脚本被直接运行 (./modules/NN-xxx.sh) → 仅终端输出, 不生成报告
#
# 变量:
#   TOOLS_DIR  底层工具目录 (modules/tools; 由 stress.sh 或 standalone_init 设置)
#   RAW_PREFIX 工具原始输出的前缀 (报告模式=临时目录; 独立模式=临时前缀, 退出即清理)
#   OUT_DIR    报告输出目录 (= TOOL 根; 仅报告模式)
#   MERGED_LOG 单一报告文件 (TOOL/测试报告-<日期>-<模式>.log; 含全部模块输出与工具原始输出)
#   CUR_LOG    人读输出目标 (报告模式 = 报告文件本身 → 边跑边写入; 独立模式 = 终端)
#   MERGED_LOG 单一报告文件 (TOOL/测试报告-<日期>-<模式>.log; 含全部模块输出与工具原始输出)
# ============================================================
set -u

# ---------- 颜色 ----------
C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_CYN=$'\033[36m'; C_RST=$'\033[0m'

# ---------- 模式 ----------
: "${STANDALONE:=0}"     # 1 = 模块独立运行 (不生成报告)

# ---------- 工具目录 ----------
# 独立模式默认 = 本文件所在目录下的 tools/
: "${TOOLS_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")/tools" 2>/dev/null && pwd || echo "")}"

# ---------- 参数默认值 (仅供报告模式: 精简自定义配置缺项也不会崩) ----------
apply_defaults() {
    : "${CPU_SECONDS:=600}"; : "${MEMBW_MB:=512}"; : "${MEMBW_RUNS:=3}"; : "${MEMBW_METHODS:=memcpy dumb}"
    : "${STORAGE_DEV:=/dev/mmcblk1p2}"; : "${STORAGE_DIR:=/home/radxa/stress-io-test}"; : "${STORAGE_SIZE:=256M}"
    : "${STORAGE_RUNTIME:=10}"; : "${STORAGE_JOBS:=4}"
    : "${CRYPTO_SECONDS:=5}"; : "${CRYPTO_ALGS:=aes-256-gcm sha256 sha512 chacha20-poly1305}"
    : "${GPU_SECONDS:=300}"; : "${NPU_COUNT:=300}"; : "${MIXED_SECONDS:=300}"; : "${MIXED_CPU_LOAD:=6}"
    : "${NETWORK_MODE:=loopback}"; : "${NETWORK_PEER:=192.168.123.9}"; : "${NETWORK_SECONDS:=10}"
    : "${NETWORK_UDP:=1}"; : "${NETWORK_PARALLEL:=4}"
    : "${GOVERNOR_SECONDS:=10}"; : "${GOVERNOR_LIST:=schedutil performance powersave ondemand}"
    : "${CONTAINER_IMAGE:=docker.io/library/alpine:latest}"; : "${CONTAINER_N:=2}"
    : "${CONTAINER_CMD:=i=0; while [ \$i -lt 200000 ]; do i=\$((i+1)); done; echo done}"
    : "${LONGRUN_SECONDS:=3600}"; : "${LONGRUN_CYCLES:=0}"
}

if [ "$STANDALONE" = "1" ]; then
    # ---- 独立模式: 仅终端, 不写任何文件 ----
    REPORT_DIR=""
    RESULT_TSV="/dev/null"
    CUR_LOG="/dev/stdout"        # 人读输出直接打终端 (不落盘)
    # 工具原始输出写到临时前缀文件 (模块里用 "${RAW_PREFIX}.xxx"), 退出即清理
    RAW_PREFIX="$(mktemp -u /tmp/stress-standalone-$$-XXXXXX)"
    trap 'rm -f "${RAW_PREFIX}"* 2>/dev/null' EXIT
    trap 'exit 143' TERM INT
    _to_report() { :; }          # 独立模式不写文件
    log()  { echo "$*"; }
    # 硬件验证等内嵌代码用的输出原语 (具体实现, 不做函数名委托, 避免递归)
    _emit_log()  { echo "$*"; }
    _emit_head() { echo ""; echo "${C_CYN}── $* ──${C_RST}"; }
    _emit_ok()   { echo "  [${C_GRN}PASS${C_RST}] $*"; }
    _emit_bad()  { echo "  [${C_RED}FAIL${C_RST}] $*"; }
    _emit_skip() { echo "  [${C_YEL}SKIP${C_RST}] $*"; }
    record() { :; }      # 独立运行不记录结果
    run_module() { "$3"; }   # 兼容 (直接调用)
else
    # ---- 报告模式 (stress.sh) ----
    # 报告直接落在 TOOL 根目录 (不加子文件夹), 全部内容合并进单一报告文件
    : "${OUT_DIR:=${SELF_DIR:-.}}"
    # 单一报告文件 (stress.sh 传入 "测试报告-<日期>-<模式>.log"); 未传入时给默认名
    : "${MERGED_LOG:=${OUT_DIR}/测试报告-$(date +%Y%m%d)-stress-full.log}"
    : "${RESULTS_TSV:=$(mktemp /tmp/stress-results-$$-XXXXXX)}"
    RESULT_TSV="$RESULTS_TSV"
    # 报告文件写纯文本 (剥离 ANSI 颜色码); 终端仍带颜色
    _to_report() { sed -E $'s/\033\\[[0-9;]*[A-Za-z]//g' >> "${CUR_LOG:-$MERGED_LOG}"; }
    log()  { printf '%s\n' "$*" | _to_report; printf '%s\n' "$*" >&2; }
    # 硬件验证等内嵌代码用的输出原语 (具体实现, 直接进报告文件 + 终端)
    _emit_log()  { printf '%s\n' "$*" | _to_report; printf '%s\n' "$*" >&2; }
    _emit_head() { local m="${C_CYN}── $* ──${C_RST}"; printf '\n%s\n' "$m" | _to_report; printf '\n%s\n' "$m" >&2; }
    _emit_ok()   { local m="  [${C_GRN}PASS${C_RST}] $*"; printf '%s\n' "$m" | _to_report; printf '%s\n' "$m" >&2; }
    _emit_bad()  { local m="  [${C_RED}FAIL${C_RST}] $*"; printf '%s\n' "$m" | _to_report; printf '%s\n' "$m" >&2; }
    _emit_skip() { local m="  [${C_YEL}SKIP${C_RST}] $*"; printf '%s\n' "$m" | _to_report; printf '%s\n' "$m" >&2; }
    apply_defaults          # 报告模式: 补齐 stress.conf 未定义的参数
fi


# ---------- 输出 ----------
info() { log "  [..] $*"; }
ok()   { log "  [${C_GRN}PASS${C_RST}] $*"; }
bad()  { log "  [${C_RED}FAIL${C_RST}] $*"; }
skip() { log "  [${C_YEL}SKIP${C_RST}] $*"; }
head1(){ log ""; log "${C_CYN}══════════════════════════════════════════${C_RST}"; log "${C_CYN} $*${C_RST}"; log "${C_CYN}══════════════════════════════════════════${C_RST}"; }
head2(){ log ""; log "${C_CYN}── $* ──${C_RST}"; }

# ---------- 结果记录 (报告模式: 写入 results.tsv; 独立模式: 空操作) ----------
# record <module> <metric> <value> <unit> <status>
if [ "$STANDALONE" != "1" ]; then
    record() { printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" >> "$RESULT_TSV"; }
fi

# ---------- GPU 利用率采样 (读驱动 debugfs; stock/patched 驱动都适用) ----------
# 说明: 驱动原生提供按进程 GPU 时间(补丁版驱动会输出到 fdinfo, htop 直接可见),
#       这里只做"压测期间利用率统计", 数据源 = /sys/kernel/debug/pvr/status (需 root)。
GPU_UTIL_STATUS="${GPU_UTIL_STATUS:-/sys/kernel/debug/pvr/status}"
gpu_util_available() { [ -r "$GPU_UTIL_STATUS" ]; }
gpu_util_start() {   # 采样 GPU 利用率 → ${RAW_PREFIX}.util; 回显 PID
    # 优先: 补丁驱动的原生 fdinfo 记账 (drm-engine-pvr 的增速 = 真实利用率, 不受
    #       驱动 debugfs 利用率抖动影响); 回退: 读 debugfs 的 GPU Utilisation。
    (
        prev=""
        while :; do
            v=""
            for t in gpu_stress ocl_stress vk_stress; do
                pid=$(pgrep -x "$t" 2>/dev/null | head -1)
                [ -n "$pid" ] || continue
                v=$(awk '/drm-engine-pvr/{print $2; exit}' /proc/$pid/fdinfo/* 2>/dev/null | head -1)
                [ -n "$v" ] && break
            done
            if [ -n "$v" ]; then
                if [ -n "$prev" ] && [ "$v" -ge "$prev" ]; then
                    echo $(( (v - prev) / 10000000 ))          # Δns/1e7 = 每秒百分比
                else
                    echo 0
                fi
                prev="$v"
            else
                prev=""
                awk '/^GPU Utilisation/{print $3}' "$GPU_UTIL_STATUS" 2>/dev/null | tr -dc '0-9'
            fi
            sleep 1
        done
    ) >> "${RAW_PREFIX}.util" >/dev/null 2>&1 &
    echo $!
}
gpu_util_stop() {    # gpu_util_stop <PID> [模块名]  → 记录平均/峰值利用率
    local pid="${1:-}" name="${2:-gpu}"
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
    local f="${RAW_PREFIX}.util"
    [ -s "$f" ] || return 0
    local n avg peak
    read -r n avg peak < <(awk 'NF && $1+0>=0 {c++; s+=$1; if ($1+0>m) m=$1+0} END{printf "%d %.1f %d\n", c, (c?s/c:0), m}' "$f")
    [ "${n:-0}" -gt 0 ] && {
        record "$name" util_avg "$avg" "%" pass
        record "$name" util_peak "$peak" "%" pass
    }
}

# ---------- 环境快照 (报告模式) ----------
env_snapshot() {
    local f="${MERGED_LOG:-/dev/stdout}"
    {
        echo "=== 压测环境快照 $(date '+%F %T %Z') ==="
        echo "--- 系统 ---"; uname -a
        echo "--- 发行版 ---"; grep PRETTY_NAME /etc/os-release
        echo "--- CPU ---"; nproc; lscpu | grep -E "^Model name|^CPU\(s\)|MHz|BogoMIPS" | head -6
        echo "--- 内存 ---"; free -h
        echo "--- 磁盘 ---"; df -h / /boot 2>/dev/null | grep -vE "^tmpfs"
        echo "--- governor ---"; cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null
        echo "--- 温度(起始) ---"; for z in /sys/class/thermal/thermal_zone*/; do printf "%s=%s " "$(cat $z/type 2>/dev/null)" "$(awk '{printf "%.1f", $1/1000}' $z/temp 2>/dev/null)"; done; echo
        echo "--- 关键设备 ---"
        for d in /dev/dri/renderD128 /dev/vipcore /dev/cedar_dev; do [ -e "$d" ] && echo "  $d OK" || echo "  $d 缺失"; done
        echo "--- 工具 ---"
        for t in stress-ng iperf3 openssl fio mbw python3; do printf "  %-10s %s\n" "$t" "$(command -v $t || echo '-')"; done
        echo "--- 底层工具 ($TOOLS_DIR) ---"
        ls "${TOOLS_DIR}"/{gpu/gpu_stress,gpu/ocl_stress,gpu/vk_stress,npu/npu_stress.sh,cpu/cpu_benchmark.py,thermal/temp_mon.sh} 2>/dev/null | sed 's/^/  /'
        if [ -x /home/radxa/k8s/docker-rootless/bin/docker ]; then
            echo "--- rootless docker ---"
            XDG_RUNTIME_DIR=/run/user/1000 /home/radxa/k8s/docker-rootless/bin/docker info 2>/dev/null | grep -E "Server Version|Storage Driver|Cgroup" | sed 's/^/  /'
        fi
    } > "$f"
    echo "$f"
}

# ---------- 温度读取 ----------
temp_of() { # temp_of <zone_type_substr>  → 例如 cpub/gpu/npu/cpul
    local t
    t=$(for z in /sys/class/thermal/thermal_zone*/; do
            case "$(cat $z/type 2>/dev/null)" in *"$1"*) awk '{printf "%.1f", $1/1000}' $z/temp 2>/dev/null; break;; esac
        done)
    echo "${t:-N/A}"
}

# ---------- 依赖检查 ----------
need_cmd() { command -v "$1" >/dev/null 2>&1; }

# ---------- 模块统一入口包装 (报告模式) ----------
# run_module <name> <enable(0/1)> <func>
if [ "$STANDALONE" != "1" ]; then
    run_module() {
        local name="$1" enable="$2" func="$3"
        if [ "$enable" != "1" ]; then
            record "$name" "enabled" "0" "" "skip"
            return 0
        fi

        # 人读输出直接写报告文件 (边跑边写入), 工具原始输出先落临时目录, 模块结束再追加
        local _rawdir; _rawdir="$(mktemp -d /tmp/stress-raw-$$-XXXXXX)"
        RAW_PREFIX="${_rawdir}/raw"
        CUR_LOG="$MERGED_LOG"
        {
            echo ""
            echo "══════════════════════════════════════════════════════"
            echo " 模块 ${name} — 开始 $(date '+%F %T')"
            echo "══════════════════════════════════════════════════════"
        } >> "$MERGED_LOG"
        # 兜底: 模块若自定义了输出函数, 运行结束后恢复本体系版本 (避免影响后续模块)
        local _saved_out
        _saved_out="$(declare -f log info ok bad skip head1 head2 _emit_log _emit_head _emit_ok _emit_bad _emit_skip 2>/dev/null)"
        local _rm_t0; _rm_t0=$(date +%s)      # 不用 SECONDS/通用名, 避免被模块代码覆盖
        "$func"
        local rc=$?
        local dt=$(( $(date +%s) - _rm_t0 ))
        eval "$_saved_out"
        {
            echo ""
            echo "──────────────────────────────────────────────────────"
            echo " 模块 ${name} — 结束 (${dt}s, rc=${rc})"
            echo "──────────────────────────────────────────────────────"
        } >> "$MERGED_LOG"
        record "$name" "_duration_s" "$dt" "s" "$([ $rc -eq 0 ] && echo pass || echo fail)"
        merge_raw_outputs "$name"
        rm -rf "$_rawdir"
        return $rc
    }

    # 把该模块产生的工具原始输出追加进报告 (逐段标注来源)
    merge_raw_outputs() {
        local name="$1" f suffix
        for f in "${RAW_PREFIX}".*; do
            [ -e "$f" ] || continue
            suffix="${f#${RAW_PREFIX}.}"
            {
                echo ""
                echo "── 原始输出: ${name}.${suffix} ──"
                cat "$f" 2>/dev/null
            } >> "$MERGED_LOG"
        done
    }
fi

# ============================================================
# standalone_init — 模块脚本被直接运行时的初始化
# 用法 (模块脚本末尾):
#   if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
#       standalone_init
#       mod_xxx "$@"
#   fi
# 效果: 载入默认配置 (stress.conf 如存在) + 打印提示 (不生成任何报告文件)
# ============================================================
standalone_init() {
    # 独立运行: 不读 stress.conf (避免长时长), 用下方快速默认值;
    # 所有参数均可用环境变量覆盖, 例如:  GPU_SECONDS=10 ./modules/05-gpu.sh
    # 需要完整配置请用 TOOL/stress.sh
    : "${CPU_SECONDS:=60}"; : "${MEMBW_MB:=512}"; : "${MEMBW_RUNS:=3}"; : "${MEMBW_METHODS:=memcpy dumb}"
    : "${STORAGE_DEV:=/dev/mmcblk1p2}"; : "${STORAGE_DIR:=/home/radxa/stress-io-test}"; : "${STORAGE_SIZE:=256M}"
    : "${STORAGE_RUNTIME:=10}"; : "${STORAGE_JOBS:=4}"
    : "${CRYPTO_SECONDS:=3}"; : "${CRYPTO_ALGS:=aes-256-gcm sha256 sha512 chacha20-poly1305}"
    : "${GPU_SECONDS:=30}"; : "${NPU_COUNT:=50}"; : "${MIXED_SECONDS:=60}"; : "${MIXED_CPU_LOAD:=6}"
    : "${NETWORK_MODE:=loopback}"; : "${NETWORK_PEER:=192.168.123.9}"; : "${NETWORK_SECONDS:=10}"
    : "${NETWORK_UDP:=1}"; : "${NETWORK_PARALLEL:=4}"
    : "${GOVERNOR_SECONDS:=10}"; : "${GOVERNOR_LIST:=schedutil performance powersave ondemand}"
    : "${CONTAINER_IMAGE:=docker.io/library/alpine:latest}"; : "${CONTAINER_N:=2}"
    : "${CONTAINER_CMD:=i=0; while [ \$i -lt 200000 ]; do i=\$((i+1)); done; echo done}"
    : "${LONGRUN_SECONDS:=120}"; : "${LONGRUN_CYCLES:=0}"
    echo "${C_CYN}── 模块独立运行模式 (不生成报告; 报告请用 TOOL/stress.sh) ──${C_RST}"
}
