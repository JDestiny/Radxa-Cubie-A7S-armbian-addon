#!/bin/bash
# 模块 11: 长时稳定性 (可选)   (由 stress.sh source)

mod_longrun() {
    local total="$LONGRUN_SECONDS"
    [ "${LONGRUN_CYCLES:-0}" -gt 0 ] && total=$((LONGRUN_CYCLES * 300))
    info "长时稳定性 ${total}s (CPU+GPU+NPU 循环, 每 300s 一轮)"
    local T="$TOOLS_DIR" t0=$SECONDS round=0 fails=0
    local tpeak=0
    while [ $((SECONDS - t0)) -lt "$total" ]; do
        round=$((round + 1))
        local rem=$((total - (SECONDS - t0))); [ $rem -gt 300 ] && rem=300
        echo "--- round $round (${rem}s) ---" >> "$CUR_LOG"
        local pids=()
        need_cmd stress-ng && { stress-ng --cpu "$(nproc)" --timeout "${rem}s" >/dev/null 2>&1 & pids+=($!); }
        [ -x "$T/gpu/gpu_stress" ] && { ( cd "$T/gpu" && ./gpu_stress "$rem" ) > "${RAW_PREFIX}.g$round" 2>&1 & pids+=($!); }
        [ -x "$T/npu/npu_stress.sh" ] && { "$T/npu/npu_stress.sh" 100 > "${RAW_PREFIX}.n$round" 2>&1 & pids+=($!); }
        local p; for p in "${pids[@]}"; do wait "$p" 2>/dev/null || true; done
        grep -q "NPU 压测汇总: PASS=2 FAIL=0" "${RAW_PREFIX}.n$round" 2>/dev/null || fails=$((fails+1))
        local tg; tg=$(temp_of gpu)
        [ "$tg" != "N/A" ] && awk -v a="$tg" -v b="$tpeak" 'BEGIN{exit !(a>b)}' && tpeak=$tg
        info "round $round 完成 (累计 $((SECONDS - t0))s, 失败轮 $fails, 峰值 ${tpeak}°C)"
    done
    if [ "$fails" -eq 0 ]; then
        ok "长时稳定性 ${round} 轮全部通过 (峰值 ${tpeak}°C)"
        record longrun rounds "$round" "rounds" pass
        record longrun peak_temp "$tpeak" "C" pass
        return 0
    fi
    bad "长时稳定性 $fails/$round 轮失败"; record longrun fails "$fails/$round" "" fail; return 1
}


# ── 直接运行支持 (./modules/11-longrun.sh — 仅终端输出, 不生成报告; 报告请用 TOOL/stress.sh) ──
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    STANDALONE=1
    source "$(dirname "$(readlink -f "$0")")/lib.sh"
    standalone_init
    mod_longrun "$@"
fi
