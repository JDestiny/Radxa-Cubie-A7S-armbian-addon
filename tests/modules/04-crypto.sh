#!/bin/bash
# SPDX-License-Identifier: MIT
# 模块 04: 加密性能 (openssl speed)   (由 stress.sh source)

mod_crypto() {
    if ! need_cmd openssl; then skip "openssl 未安装"; return 1; fi
    info "openssl speed (每算法 ${CRYPTO_SECONDS}s): ${CRYPTO_ALGS}"
    local alg
    for alg in $CRYPTO_ALGS; do
        local out; out=$(openssl speed -seconds "$CRYPTO_SECONDS" -evp "$alg" 2>/dev/null | tail -1)
        # 输出格式: "aes-256-gcm  123456.78k  456789.01k ..." (16B/64B/256B/1KB/8KB/16KB, k=KB/s)
        local k16 k8k
        k16=$(echo "$out" | awk '{print $2}')
        k8k=$(echo "$out" | awk '{print $(NF-1)}')
        echo "$alg: $out" >> "$CUR_LOG"
        if [ -n "$k16" ]; then
            local mb16 mb8k
            mb16=$(awk -v k="$k16" 'BEGIN{printf "%.1f", k/1024}')
            mb8k=$(awk -v k="$k8k" 'BEGIN{printf "%.1f", k/1024}')
            ok "$alg: 16B ${mb16} MB/s | 8KB ${mb8k} MB/s"
            record crypto "$alg/16B" "$mb16" "MB/s" pass
            record crypto "$alg/8KB" "$mb8k" "MB/s" pass
        else
            bad "$alg 无输出"; record crypto "$alg" "unknown" "" fail
        fi
    done
    return 0
}

# ---------- 9. governor / 调频压力 ----------


# ── 直接运行支持 (./modules/04-crypto.sh — 仅终端输出, 不生成报告; 报告请用 TOOL/stress.sh) ──
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    STANDALONE=1
    source "$(dirname "$(readlink -f "$0")")/lib.sh"
    standalone_init
    mod_crypto "$@"
fi
