#!/bin/bash
# ============================================================
# gpu-driver-stability.sh — GPU 驱动动态负载稳定性压测 (默认 2h)
#
# 目的: 验证"带 GPU 利用率记账补丁"的 pvrsrvkm 在**动态负载**下的稳定性
#       (动态 = 负载类型/强度随时间变化, 而不是恒定跑一个工具)
#
# 用法:
#   sudo ./gpu-driver-stability.sh [总时长秒数] [日志目录]
#     默认 7200 秒 (2h); 日志默认 /var/log/gpu-driver-stability-<时间戳>/
#
# 负载循环 (每轮约 4 分钟):
#   A. GLES 渲染 60s → B. OpenCL 计算 60s → C. Vulkan compute 60s
#   → D. 混合 (GLES + NPU + CPU×4) 45s → E. 空闲 15s
#
# 每轮相位 (2026-09-15 扩充, 更动态):
#   gles 60s → ocl 60s → vk 60s → mixed(GLES+NPU+CPU×4) 45s → multi(GLES×4 并发) 45s
#   → vkgl(GLES+Vulkan 并发) 60s → burst(短命客户端 churn) 30s → idle 15s
# 每 15s 采样一次 (写入 metrics.tsv):
#   温度(6 路) / 驱动 debugfs 计数器(Server Errors·HWR·CRR·SLR·APM·利用率)
#   / dmesg 新增错误数 / 当前 GPU 进程 fdinfo 的 drm-engine-pvr (验证单调)
#
# 结束判定: 阶段成功率 / dmesg 新增错误 / 驱动计数器增量 / 记账单调性 / 温度峰值
# ============================================================
set -uo pipefail

DURATION="${1:-7200}"
OUTDIR="${2:-/var/log/gpu-driver-stability-$(date +%Y%m%d-%H%M%S)}"
TOOLS_DIR="${TOOLS_DIR:-/home/radxa/armbian/TOOL/modules/tools}"
PCIE_STATUS=/sys/kernel/debug/pvr/status
METRICS="$OUTDIR/metrics.tsv"
SUMMARY="$OUTDIR/summary.txt"
GLOG="$OUTDIR/phases.log"

mkdir -p "$OUTDIR"
: > "$METRICS"
: > "$GLOG"

log()  { echo "[$(date '+%F %T')] $*" | tee -a "$GLOG"; }
have() { command -v "$1" >/dev/null 2>&1; }

# ---------- 前置检查 ----------
[ "$(id -u)" = "0" ] || { echo "需要 root: sudo $0"; exit 1; }
[ -r "$PCIE_STATUS" ] || { echo "读不到 $PCIE_STATUS (驱动未加载或 debugfs 未挂载)"; exit 1; }
for t in "$TOOLS_DIR/gpu/gpu_stress" "$TOOLS_DIR/gpu/ocl_stress" "$TOOLS_DIR/gpu/vk_stress"; do
    [ -x "$t" ] || { echo "缺少 $t"; exit 1; }
done

# 负载以哪个用户身份运行 (默认 radxa): 该用户自己的 htop 才能读到这些进程的 fdinfo;
# 若以 root 跑, 只有 sudo htop 看得到。监控部分仍需 root (dmesg / debugfs)。
LOAD_USER="${LOAD_USER:-radxa}"
id "$LOAD_USER" >/dev/null 2>&1 || LOAD_USER="$(id -un)"
run_load() {
    if [ "$(id -u)" = "0" ] && [ "$LOAD_USER" != "root" ]; then
        runuser -u "$LOAD_USER" -- "$@"
    else
        "$@"
    fi
}

VARIANT="unknown"
if lsmod | grep -q "^pvrsrvkm"; then
    if grep -qw "PVRGpuAcctKick" /proc/kallsyms 2>/dev/null; then
        VARIANT="patched(GPU 记账补丁)"
    else
        VARIANT="stock(原生)"
    fi
fi

log "=== GPU 驱动动态负载稳定性压测 ==="
log "时长: ${DURATION}s  日志: $OUTDIR  负载用户: $LOAD_USER"
log "驱动: $(modinfo -F version pvrsrvkm 2>/dev/null || echo '?')  vermagic: $(modinfo -F vermagic pvrsrvkm 2>/dev/null | awk '{print $1}')"
log "起始 pvrsrvkm 模块大小: $(lsmod | awk '/^pvrsrvkm/{print $2}') B"

# ---------- 计数器基线 ----------
read_status() {   # 输出: util gpu_active ... 关键错误计数
    awk '
      /^GPU Utilisation:/            {util=$3}
      /^Server Errors:/              {srv=$3}
      /^HWR Event Count:/            {hwr=$4}
      /^CRR Event Count:/            {crr=$4}
      /^SLR Event Count:/            {slr=$4}
      /^FWF Event Count:/            {fwf=$4}
      /^APM Event Count:/            {apm=$4}
      END{printf "%s %s %s %s %s %s %s", util, srv, hwr, crr, slr, fwf, apm}
    ' "$PCIE_STATUS" 2>/dev/null
}
read_temps() {    # 6 路温度 (m°C → °C, 1 位小数)
    for z in cpub cpul gpu npu ddr skin; do
        for d in /sys/class/thermal/thermal_zone*; do
            case "$(cat $d/type 2>/dev/null)" in ${z}*) awk '{printf "%.1f ", $1/1000}' $d/temp; break;; esac
        done
    done
}
dmesg_errs() {    # 内核错误计数 (PVR 错误 / Oops / BUG / panic / GPU fault)
    dmesg 2>/dev/null | grep -ciE "PVR_K:.*(error|fail|timeout)|Oops|BUG:|kernel panic|GPU fault|pvrsrvkm.*(error|fail)" || true
}
ACCT_PID=""; ACCT_FRESH=1; ACCT_VAL="-"
acct_sample() {   # 固定跟踪同一个客户端 PID 的 drm-engine-pvr 值 (验证单调)
    # 2026-09-13 修: 原来取 "pgrep 命中的第一个进程", 在 vk 阶段会先读到上一阶段残留的
    # ocl 客户端的冻结值、下一采样切到新客户端 → 被误判成"记账回退"。
    # 现在锁定一个 PID 跟到底; 换 PID/新段首个样本输出 "-" 作"基线重置"标记 (复核时跳过比较)。
    # ⚠️ 必须**直接调用**(写入全局 ACCT_VAL), 不能用 $(...) 取返回值 —— 命令替换在子 shell 里跑,
    #    锁定的 PID 会丢失。
    local p v
    [ -n "$ACCT_PID" ] && [ ! -d "/proc/$ACCT_PID" ] && ACCT_PID=""
    if [ -z "$ACCT_PID" ]; then
        for p in $(pgrep -x gpu_stress 2>/dev/null; pgrep -x ocl_stress 2>/dev/null; pgrep -x vk_stress 2>/dev/null); do
            if grep -qs "drm-engine-pvr" /proc/$p/fdinfo/* 2>/dev/null; then
                ACCT_PID=$p; ACCT_FRESH=1; break
            fi
        done
    fi
    ACCT_VAL="-"
    [ -z "$ACCT_PID" ] && return
    v=$(awk '/drm-engine-pvr/{print $2; exit}' /proc/$ACCT_PID/fdinfo/* 2>/dev/null | head -1)
    [ -n "$v" ] || return
    if [ "$ACCT_FRESH" = 1 ]; then ACCT_FRESH=0; return; fi   # 新段首个样本只作基线
    ACCT_VAL="$v"
}

BASE_DMESG=$(dmesg_errs)
BASE_STAT=$(read_status)
log "基线: dmesg 错误=$BASE_DMESG  debugfs[$BASE_STAT]"

printf 'time\tphase\tutil%%\tsrv\thwr\tcrr\tslr\tfwf\tapm\tcpuB\tcpuL\tgpu\tnpu\tddr\tskin\tdmesg_err\tacct_ns\tfps_or_thr\n' >> "$METRICS"

# ---------- 采样器 (后台, 15s 一次) ----------
PHASE_FILE="$OUTDIR/.phase"
: > "$PHASE_FILE"
(
    while :; do
        read -r u srv hwr crr slr fwf apm <<< "$(read_status)"
        read -r t_cpub t_cpul t_gpu t_npu t_ddr t_skin <<< "$(read_temps)"
        acct_sample                       # 直接调用: 状态(锁定 PID)保存在本 shell
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$(date '+%F %T')" "$(cat $PHASE_FILE 2>/dev/null | tr -d '\n')" \
            "${u:-0}" "${srv:-0}" "${hwr:-0}" "${crr:-0}" "${slr:-0}" "${fwf:-0}" "${apm:-0}" \
            "${t_cpub:-0}" "${t_cpul:-0}" "${t_gpu:-0}" "${t_npu:-0}" "${t_ddr:-0}" "${t_skin:-0}" \
            "$(dmesg_errs)" "$ACCT_VAL" "$(tail -1 $PHASE_FILE.metric 2>/dev/null)" >> "$METRICS"
        sleep 15
    done
) &
SAMPLER_PID=$!
trap 'kill $SAMPLER_PID 2>/dev/null' EXIT

# ---------- 负载阶段 ----------
run_phase() {  # run_phase <名称> <秒数> <命令...>
    local name="$1" secs="$2"; shift 2
    echo "$name" > "$PHASE_FILE"
    log "阶段: $name (${secs}s) — $*"
    local t0=$SECONDS rc=0
    "$@" > "$OUTDIR/phase-$name.out" 2>&1 &
    local pid=$!
    while kill -0 $pid 2>/dev/null && [ $((SECONDS - t0)) -lt "$secs" ]; do sleep 5; done
    kill -0 $pid 2>/dev/null && kill $pid 2>/dev/null && wait $pid 2>/dev/null
    wait $pid 2>/dev/null || rc=$?
    local dur=$((SECONDS - t0))
    local metric
    # 我们到达时长后主动终止 (SIGTERM=143 / SIGKILL=137): 跑满时长即算成功
    case "$rc" in
        0|137|143) [ "$dur" -ge $((secs - 10)) ] && rc=0 || rc=1 ;;
        *) rc=1 ;;
    esac
    metric=$(grep -aoE "(平均帧率: *[0-9.]+|计算吞吐: *[0-9.]+|吞吐: *[0-9.]+|PASS|FAIL)" "$OUTDIR/phase-$name.out" 2>/dev/null | tail -2 | tr '\n' ' ')
    echo "$metric" > "$PHASE_FILE.metric"
    if grep -qaiE "\[FAIL\]|异常: *[1-9]|失败" "$OUTDIR/phase-$name.out" 2>/dev/null; then rc=1; fi
    if [ "$dur" -lt $((secs - 10)) ] && [ "$name" != "idle" ]; then rc=1; fi
    log "  完成 ${dur}s rc=$rc  $metric"
    # 计数写文件: run_phase 在子 shell 里执行, 变量回传不了
    {
        echo $(( $(cat "$OUTDIR/.total" 2>/dev/null || echo 0) + 1 )) > "$OUTDIR/.total"
        if [ "$rc" = "0" ]; then
            echo $(( $(cat "$OUTDIR/.ok" 2>/dev/null || echo 0) + 1 )) > "$OUTDIR/.ok"
        else
            echo $(( $(cat "$OUTDIR/.fail" 2>/dev/null || echo 0) + 1 )) > "$OUTDIR/.fail"
            echo "$name" >> "$OUTDIR/.fail_names"
        fi
    }
}
: > "$OUTDIR/.total"; : > "$OUTDIR/.ok"; : > "$OUTDIR/.fail"; : > "$OUTDIR/.fail_names"

T_START=$SECONDS
ROUND=0
while [ $((SECONDS - T_START)) -lt "$DURATION" ]; do
    ROUND=$((ROUND + 1))
    log "──────── 第 $ROUND 轮 (已跑 $((SECONDS - T_START))s / ${DURATION}s) ────────"
    ( cd "$TOOLS_DIR/gpu" && run_phase "gles-r$ROUND"  60 run_load ./gpu_stress 60 )
    ( cd "$TOOLS_DIR/gpu" && run_phase "ocl-r$ROUND"   60 run_load ./ocl_stress 60 )
    ( cd "$TOOLS_DIR/gpu" && run_phase "vk-r$ROUND"    60 run_load env VK_SPV="$TOOLS_DIR/gpu/cs.spv" ./vk_stress 60 )
    # 混合: GLES + NPU + CPU×4
    run_phase "mixed-r$ROUND" 45 run_load bash -c '
        '"$TOOLS_DIR"'/gpu/gpu_stress 45 >/dev/null 2>&1 &
        g=$!
        [ -x '"$TOOLS_DIR"'/npu/npu_stress.sh ] && '"$TOOLS_DIR"'/npu/npu_stress.sh 100 >/dev/null 2>&1 &
        n=$!
        have() { command -v "$1" >/dev/null 2>&1; }
        command -v stress-ng >/dev/null && stress-ng --cpu 4 --timeout 45s >/dev/null 2>&1 &
        s=$!
        wait $g $n $s 2>/dev/null
        exit 0'
    # 多客户端: 4 个并发 GLES 客户端 (验证按 kick 分摊的多客户端归属)
    run_phase "multi-r$ROUND" 45 run_load bash -c '
        for i in 1 2 3 4; do '"$TOOLS_DIR"'/gpu/gpu_stress 45 >/dev/null 2>&1 & done
        wait
        exit 0'
    # 跨引擎并发: GLES 渲染 + Vulkan compute 同时跑
    run_phase "vkgl-r$ROUND" 60 run_load bash -c '
        VK_SPV='"$TOOLS_DIR"'/gpu/cs.spv '"$TOOLS_DIR"'/gpu/vk_stress 60 >/dev/null 2>&1 &
        v=$!
        '"$TOOLS_DIR"'/gpu/gpu_stress 60 >/dev/null 2>&1 &
        g=$!
        wait $g $v 2>/dev/null
        exit 0'
    # 短命客户端 churn: 连续起/停一批 1 秒客户端 (条目创建+回收、fdinfo 读抖动、PID 复用)
    run_phase "burst-r$ROUND" 30 run_load bash -c '
        end=$((SECONDS+30))
        while [ $SECONDS -lt $end ]; do
            for i in 1 2 3; do '"$TOOLS_DIR"'/gpu/gpu_stress 1 >/dev/null 2>&1 & done
            wait
        done
        exit 0'
    run_phase "idle-r$ROUND" 15 sleep 15
done

kill $SAMPLER_PID 2>/dev/null; trap - EXIT
T_TOTAL=$((SECONDS - T_START))
PHASE_TOTAL=$(cat "$OUTDIR/.total" 2>/dev/null); PHASE_TOTAL=${PHASE_TOTAL:-0}
PHASE_OK=$(cat "$OUTDIR/.ok" 2>/dev/null);          PHASE_OK=${PHASE_OK:-0}
PHASE_FAIL=$(cat "$OUTDIR/.fail" 2>/dev/null);      PHASE_FAIL=${PHASE_FAIL:-0}
PHASE_FAIL_NAMES=$(sort -u "$OUTDIR/.fail_names" 2>/dev/null | tr '\n' ' ')

# ---------- 判定 ----------
END_DMESG=$(dmesg_errs)
END_STAT=$(read_status)
MODSIZE=$(lsmod | awk '/^pvrsrvkm/{print $2}')
log "=== 结束: 驱动变体=$VARIANT 模块大小 $MODSIZE B ==="

{
echo "══════════════════════════════════════════════════════"
echo " GPU 驱动动态负载稳定性压测 — 报告"
echo " 时间: $(date '+%F %T')   总时长: ${T_TOTAL}s (${ROUND} 轮)"
echo " 驱动: variant=${VARIANT}  pvrsrvkm size=${MODSIZE}B"
echo "══════════════════════════════════════════════════════"
echo "── 阶段 ──"
echo "  成功 ${PHASE_OK} / 失败 ${PHASE_FAIL}  (共 ${PHASE_TOTAL})"
[ -n "$PHASE_FAIL_NAMES" ] && echo "  失败阶段:${PHASE_FAIL_NAMES}"
echo
echo "── 内核错误 (dmesg) ──"
echo "  基线 ${BASE_DMESG} → 结束 ${END_DMESG}   新增 $((END_DMESG - BASE_DMESG))"
echo
echo "── 驱动计数器 (基线 → 结束) ──"
echo "  基线: $BASE_STAT"
echo "  结束: $END_STAT"
echo "  (字段: util% server_errors hwr crr slr fwf apm)"
echo
echo "── GPU 记账单调性 (fdinfo drm-engine-pvr, 固定 PID 跟踪) ──"
awk -F'\t' 'NR>1 && $17 != "" {
    if ($2 != ph) { ph=$2; prev=""; seg++; }        # 跨阶段: 重置基线
    if ($17 == "-") { prev=""; next }               # 无客户端/换客户端: 重置基线, 不计比较
    if (prev == "") { prev=$17; next }             # 新段首个数值: 只作基线
    n++; if ($17+0 < prev+0) bad++; prev=$17
} END{printf "  阶段内比较 %d 次 (跨阶段/换客户端重置 %d 段), 真实回退 %d 次\n", n, seg+0, bad+0}' "$METRICS"
echo "  ── util 健康度 ──"
awk -F'\t' 'NR>1 {n++; if ($3+0==0) z++} END{printf "  util=0 采样 %d / %d (%.1f%%, 其中含空闲阶段)\n", z+0, n, 100*z/n}' "$METRICS"
awk -F'\t' '$2 ~ /^gles/ {n++; if ($3+0==0) z++} END{printf "  gles(渲染)阶段 util=0: %d / %d  ← v1 缺陷会接近 100%%\n", z+0, n}' "$METRICS"
echo
echo "── 温度峰值 ──"
awk -F'\t' 'NR>1 && $10!="" {for(i=10;i<=15;i++) if($i+0>m[i]) m[i]=$i} END{printf "  cpub=%.1f cpul=%.1f gpu=%.1f npu=%.1f ddr=%.1f skin=%.1f °C\n", m[10],m[11],m[12],m[13],m[14],m[15]}' "$METRICS"
echo
echo "── 结论 ──"
if [ "${PHASE_FAIL:-0}" = "0" ] && [ $((END_DMESG - BASE_DMESG)) -le 0 ]; then
    echo "  ✅ 动态负载下稳定: 全部阶段成功, dmesg 无新增错误"
else
    echo "  ❌ 存在异常项 (见上)"
fi
echo "  日志: $OUTDIR  (metrics.tsv 每 15s 一行, phases.log 全过程)"
echo "══════════════════════════════════════════════════════"
} | tee "$SUMMARY"
