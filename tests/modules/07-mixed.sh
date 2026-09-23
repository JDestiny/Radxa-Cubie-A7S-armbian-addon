#!/bin/bash
# 模块 07: 混合并发满载   (由 stress.sh source)

mod_mixed() {
    local T="$TOOLS_DIR"
    info "混合并发 ${MIXED_SECONDS}s: GPU GLES + NPU + CPU×${MIXED_CPU_LOAD} 同时"
    local pids=()
    local fps_log="${RAW_PREFIX}.gles_mixed"
    [ -x "$T/gpu/gpu_stress" ] && { ( cd "$T/gpu" && ./gpu_stress "$MIXED_SECONDS" ) > "$fps_log" 2>&1 & pids+=($!); }
    [ -x "$T/npu/npu_stress.sh" ] && { "$T/npu/npu_stress.sh" 200 > "${RAW_PREFIX}.npu_mixed" 2>&1 & pids+=($!); }
    need_cmd stress-ng && { stress-ng --cpu "$MIXED_CPU_LOAD" --timeout "${MIXED_SECONDS}s" >/dev/null 2>&1 & pids+=($!); }
    # 温度采样
    local tpeak=0
    local i
    for i in $(seq 1 $((MIXED_SECONDS / 5 + 1))); do
        local tg; tg=$(temp_of gpu)
        [ "$tg" != "N/A" ] && awk -v a="$tg" -v b="$tpeak" 'BEGIN{exit !(a>b)}' && tpeak=$tg
        sleep 5
    done
    local p; for p in "${pids[@]}"; do wait "$p" 2>/dev/null; done
    local fps; fps=$(grep -oE "平均帧率: *[0-9.]+" "$fps_log" | grep -oE "[0-9.]+" | head -1)
    local npu_ok="?"
    grep -q "NPU 压测汇总: PASS=2 FAIL=0" "${RAW_PREFIX}.npu_mixed" 2>/dev/null && npu_ok="OK" || npu_ok="FAIL"
    ok "混合满载完成: GLES ${fps:-?} fps / NPU $npu_ok / CPU ${MIXED_CPU_LOAD}核 (峰值 ${tpeak}°C)"
    record mixed GLES_fps "$fps" "fps" pass
    record mixed NPU "$npu_ok" "" "$([ "$npu_ok" = OK ] && echo pass || echo fail)"
    record mixed peak_temp "$tpeak" "C" pass
    [ "$npu_ok" = "OK" ] && return 0 || return 1
}


# ── 直接运行支持 (./modules/07-mixed.sh — 仅终端输出, 不生成报告; 报告请用 TOOL/stress.sh) ──
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    STANDALONE=1
    source "$(dirname "$(readlink -f "$0")")/lib.sh"
    standalone_init
    mod_mixed "$@"
fi
