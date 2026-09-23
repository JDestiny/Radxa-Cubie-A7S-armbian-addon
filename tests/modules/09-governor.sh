#!/bin/bash
# SPDX-License-Identifier: MIT
# 模块 09: CPU governor 调频   (由 stress.sh source)

mod_governor() {
    local cf=/sys/devices/system/cpu/cpu0/cpufreq
    [ -d "$cf" ] || { skip "无 cpufreq 接口"; return 1; }
    local orig; orig=$(cat $cf/scaling_governor)
    info "原 governor: $orig;  测试列表: $GOVERNOR_LIST"
    local g
    for g in $GOVERNOR_LIST; do
        grep -qw "$g" $cf/scaling_available_governors || { skip "$g 不支持"; continue; }
        echo "$g" | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor >/dev/null 2>&1
        sleep 1
        # 负载 20s, 采样频率
        local f0 fmax=0 fmin=999999999
        ( stress-ng --cpu "$(nproc)" --timeout "${GOVERNOR_SECONDS}s" >/dev/null 2>&1 ) &
        local lpid=$!
        local i
        for i in $(seq 1 $((GOVERNOR_SECONDS))); do
            local f; f=$(cat $cf/scaling_cur_freq 2>/dev/null || echo 0)
            [ "$f" -gt "$fmax" ] && fmax=$f
            [ "$f" -lt "$fmin" ] && [ "$f" -gt 0 ] && fmin=$f
            sleep 1
        done
        wait $lpid 2>/dev/null
        local gov_now; gov_now=$(cat $cf/scaling_governor)
        ok "$g: cur_freq ${fmin}-${fmax} kHz (governor=$gov_now)"
        record governor "$g/max_freq" "$fmax" "kHz" pass
        record governor "$g/min_freq" "$fmin" "kHz" pass
    done
    # 恢复
    echo "$orig" | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor >/dev/null 2>&1
    info "已恢复 governor=$orig ($(cat $cf/scaling_governor))"
    return 0
}


# ── 直接运行支持 (./modules/09-governor.sh — 仅终端输出, 不生成报告; 报告请用 TOOL/stress.sh) ──
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    STANDALONE=1
    source "$(dirname "$(readlink -f "$0")")/lib.sh"
    standalone_init
    mod_governor "$@"
fi
