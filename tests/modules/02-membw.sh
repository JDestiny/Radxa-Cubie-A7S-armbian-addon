#!/bin/bash
# 模块 02: 内存带宽 (mbw)   (由 stress.sh source)

mod_membw() {
    if ! need_cmd mbw; then
        skip "mbw 未安装 (apt install mbw) — 跳过内存带宽"
        record membw mbw missing "" skip
        return 1
    fi
    info "mbw ${MEMBW_MB}MB × ${MEMBW_RUNS} 次, 方法: ${MEMBW_METHODS}"
    local m
    for m in $MEMBW_METHODS; do
        local out best
        out=$(mbw -n "$MEMBW_RUNS" -t 2 -q "$MEMBW_MB" --"$m" 2>/dev/null || mbw -n "$MEMBW_RUNS" "$MEMBW_MB" 2>/dev/null)
        echo "--- $m ---" >> "$CUR_LOG"; echo "$out" >> "$CUR_LOG"
        # mbw 输出: "AVG   Method: MEMCPY  Elapsed: 0.12345  MiB: 512  Copy: 4148.12 MiB/s"
        best=$(echo "$out" | grep -oE "Copy: *[0-9.]+" | grep -oE "[0-9.]+" | sort -rn | head -1)
        local avg
        avg=$(echo "$out" | awk '/AVG/{for(i=1;i<=NF;i++) if($i=="Copy:") print $(i+1)}' | head -1)
        if [ -n "$avg" ]; then
            ok "内存带宽($m): 平均 ${avg} MiB/s (最佳 ${best:-$avg})"
            record membw "$m" "$avg" "MiB/s" pass
        else
            bad "mbw($m) 无有效输出"; record membw "$m" "unknown" "" fail
        fi
    done
    return 0
}

# ---------- 3. 存储随机 IO (fio) ----------


# ── 直接运行支持 (./modules/02-membw.sh — 仅终端输出, 不生成报告; 报告请用 TOOL/stress.sh) ──
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    STANDALONE=1
    source "$(dirname "$(readlink -f "$0")")/lib.sh"
    standalone_init
    mod_membw "$@"
fi
