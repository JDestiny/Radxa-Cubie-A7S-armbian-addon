#!/bin/bash
# 模块 06: NPU (golden + resnet50)   (由 stress.sh source)

mod_npu() {
    local S="$TOOLS_DIR/npu/npu_stress.sh"
    [ -x "$S" ] || { skip "npu_stress.sh 缺失"; return 1; }
    info "NPU golden + resnet50 ${NPU_COUNT} 次 ..."
    "$S" "$NPU_COUNT" > "${RAW_PREFIX}.npu" 2>&1
    grep -E "\[PASS\]|\[FAIL\]" "${RAW_PREFIX}.npu" | tee -a "$CUR_LOG"
    if grep -q "NPU 压测汇总: PASS=2 FAIL=0" "${RAW_PREFIX}.npu"; then
        local ms; ms=$(grep -oE "top1=[a-z]+\([0-9]+\)" "${RAW_PREFIX}.npu" | head -1)
        ok "NPU golden 3/3 + resnet50 ${NPU_COUNT} 次 $ms"
        record npu resnet50 "$NPU_COUNT" "runs" pass
        return 0
    fi
    bad "NPU 压测有失败项"; record npu stress "fail" "" fail; return 1
}

# ---------- 7. 混合并发满载 ----------


# ── 直接运行支持 (./modules/06-npu.sh — 仅终端输出, 不生成报告; 报告请用 TOOL/stress.sh) ──
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    STANDALONE=1
    source "$(dirname "$(readlink -f "$0")")/lib.sh"
    standalone_init
    mod_npu "$@"
fi
