#!/bin/bash
# SPDX-License-Identifier: MIT
# 模块 03: 存储随机 IO (fio)   (由 stress.sh source)

mod_storage() {
    if ! need_cmd fio; then
        skip "fio 未安装 (apt install fio) — 跳过存储随机 IO"
        record storage fio missing "" skip
        return 1
    fi
    local dev="$STORAGE_DEV" dir="$STORAGE_DIR"
    # 安全性: 只测指定分区上的文件, 不写裸设备; 要求目录可写
    mkdir -p "$dir" || { bad "无法创建 $dir"; return 1; }
    local testf="${dir}/fio-test.bin"
    info "fio 4K 随机读写/顺序 混合 (文件 $STORAGE_SIZE @ $dir, ${STORAGE_RUNTIME}s×4 job)"
    # 1) 4K 随机读
    fio --name=randread --filename="$testf" --size="$STORAGE_SIZE" --rw=randread --bs=4k \
        --ioengine=libaio --iodepth=32 --numjobs="$STORAGE_JOBS" --runtime="$STORAGE_RUNTIME" \
        --time_based --group_reporting --direct=1 > "${RAW_PREFIX}.randread" 2>&1
    local rr; rr=$(grep -oE "read: IOPS=[0-9.k]+" "${RAW_PREFIX}.randread" | head -1 | cut -d= -f2)
    # 2) 4K 随机写
    fio --name=randwrite --filename="$testf" --size="$STORAGE_SIZE" --rw=randwrite --bs=4k \
        --ioengine=libaio --iodepth=32 --numjobs="$STORAGE_JOBS" --runtime="$STORAGE_RUNTIME" \
        --time_based --group_reporting --direct=1 > "${RAW_PREFIX}.randwrite" 2>&1
    local rw; rw=$(grep -oE "write: IOPS=[0-9.k]+" "${RAW_PREFIX}.randwrite" | head -1 | cut -d= -f2)
    # 3) 顺序读 (对照 dd 结果)
    fio --name=seqread --filename="$testf" --size="$STORAGE_SIZE" --rw=read --bs=1M \
        --ioengine=libaio --iodepth=8 --numjobs=1 --runtime="$STORAGE_RUNTIME" \
        --time_based --group_reporting --direct=1 > "${RAW_PREFIX}.seqread" 2>&1
    local sr; sr=$(grep -oE "BW=[0-9.]+[kKMGT]?iB/s" "${RAW_PREFIX}.seqread" | head -1)
    rm -f "$testf"
    if [ -n "$rr" ] && [ -n "$rw" ]; then
        ok "存储 4K 随机: 读 $rr IOPS / 写 $rw IOPS (${STORAGE_JOBS} jobs, iodepth 32)"
        ok "存储顺序读: ${sr:-?}"
        record storage randread_iops "$rr" "IOPS" pass
        record storage randwrite_iops "$rw" "IOPS" pass
        return 0
    fi
    bad "fio 未取得有效结果"; tail -5 "${RAW_PREFIX}.randread" | tee -a "$CUR_LOG"; record storage iops "fail" "" fail; return 1
}


# ── 直接运行支持 (./modules/03-storage.sh — 仅终端输出, 不生成报告; 报告请用 TOOL/stress.sh) ──
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    STANDALONE=1
    source "$(dirname "$(readlink -f "$0")")/lib.sh"
    standalone_init
    mod_storage "$@"
fi
