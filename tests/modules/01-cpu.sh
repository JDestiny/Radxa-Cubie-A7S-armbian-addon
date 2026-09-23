#!/bin/bash
# 模块 01: CPU 满载 (stress-ng)   (由 stress.sh source)

mod_cpu() {
    if ! need_cmd stress-ng; then
        skip "stress-ng 未安装 (apt install stress-ng)"; record cpu stress-ng missing "" skip; return 1
    fi
    local n; n=$(nproc)
    info "stress-ng ${n} 核 ${CPU_SECONDS}s ..."
    local t0 tmax=0
    local peak=0
    # 后台采样峰值温度
    ( peak=0
      for _ in $(seq 1 $((CPU_SECONDS / 5 + 2))); do
          t=$(temp_of cpub)
          [ "$t" != "N/A" ] && awk -v a="$t" -v b="$peak" 'BEGIN{exit !(a>b)}' && peak=$t
          sleep 5
      done
      echo "$peak" > /tmp/.stress_cpu_peak ) &
    local sampler=$!
    stress-ng --cpu "$n" --timeout "${CPU_SECONDS}s" --metrics-brief > "${RAW_PREFIX}.stressng" 2>&1
    local rc=$?
    wait $sampler 2>/dev/null
    peak=$(cat /tmp/.stress_cpu_peak 2>/dev/null || echo "N/A"); rm -f /tmp/.stress_cpu_peak
    grep -E "stress-ng: info:.*\[.*\] *(cpu|successful|failed)" "${RAW_PREFIX}.stressng" | tail -3 | tee -a "$CUR_LOG"
    local bogo; bogo=$(grep -oE "cpu +[0-9.]+ +[0-9]+ +[0-9]+ +[0-9.]+ +[0-9.]+ +[0-9.]+" "${RAW_PREFIX}.stressng" | awk '{print $5}' | head -1)
    if [ $rc -eq 0 ]; then
        ok "CPU ${n} 核 ${CPU_SECONDS}s 满载 0 失败 (峰值 ${peak}°C${bogo:+, bogo ops/s $bogo})"
        record cpu "peak_temp" "$peak" "C" pass
        if [ -n "$bogo" ]; then record cpu "bogo_ops" "$bogo" "ops/s" pass; fi
        [ -n "$bogo" ] || true
        return 0
    fi
    bad "stress-ng 失败 rc=$rc"; record cpu stress "fail" "" fail; return 1
}

# ---------- 4. 加密性能 (openssl speed) ----------


# ── 直接运行支持 (./modules/01-cpu.sh — 仅终端输出, 不生成报告; 报告请用 TOOL/stress.sh) ──
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    STANDALONE=1
    source "$(dirname "$(readlink -f "$0")")/lib.sh"
    standalone_init
    mod_cpu "$@"
fi
