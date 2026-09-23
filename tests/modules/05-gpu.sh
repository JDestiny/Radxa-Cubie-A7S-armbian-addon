#!/bin/bash
# 模块 05: GPU 三栈 (GLES/OpenCL/Vulkan)   (由 stress.sh source)

mod_gpu() {
    local T="$TOOLS_DIR"
    local ran=0
    # GLES
    local upid; upid="$(gpu_util_start)"      # 桥接可用时: 后台采样驱动利用率
    if [ -x "$T/gpu/gpu_stress" ]; then
        info "GPU GLES ${GPU_SECONDS}s ..."
        ( cd "$T/gpu" && ./gpu_stress "$GPU_SECONDS" ) > "${RAW_PREFIX}.gles" 2>&1   # cd 使驱动 shader 缓存放 tools/gpu/
        local fps; fps=$(grep -oE "平均帧率: *[0-9.]+" "${RAW_PREFIX}.gles" | grep -oE "[0-9.]+" | head -1)
        if grep -qE "像素异常: *0|0 像素异常" "${RAW_PREFIX}.gles" 2>/dev/null || [ -n "$fps" ]; then
            ok "GLES ${GPU_SECONDS}s: ${fps:-?} fps, 0 像素异常"
            record gpu GLES_fps "$fps" "fps" pass; ran=1
        else
            bad "GLES 失败"; tail -3 "${RAW_PREFIX}.gles" | tee -a "$CUR_LOG"; record gpu GLES "fail" "" fail
        fi
    else skip "gpu_stress 缺失"; fi
    # OpenCL
    if [ -x "$T/gpu/ocl_stress" ]; then
        info "GPU OpenCL ${GPU_SECONDS}s ..."
        ( cd "$T/gpu" && ./ocl_stress "$GPU_SECONDS" ) > "${RAW_PREFIX}.ocl" 2>&1
        local mpix; mpix=$(grep -oE "计算吞吐: *[0-9.]+" "${RAW_PREFIX}.ocl" | grep -oE "[0-9.]+" | head -1)
        if grep -q "结果校验异常: 0" "${RAW_PREFIX}.ocl"; then
            ok "OpenCL ${GPU_SECONDS}s: 计算正确稳定 (0 异常, 吞吐 ${mpix:-?} GFLOPS)"
            record gpu OpenCL_GFLOPS "$mpix" "GFLOPS" pass; ran=1
        else
            bad "OpenCL 失败"; tail -3 "${RAW_PREFIX}.ocl" | tee -a "$CUR_LOG"; record gpu OpenCL "fail" "" fail
        fi
    else skip "ocl_stress 缺失"; fi
    # Vulkan
    if [ -x "$T/gpu/vk_stress" ]; then
        info "GPU Vulkan ${GPU_SECONDS}s ..."
        ( cd "$T/gpu" && env VK_SPV="$T/gpu/cs.spv" ./vk_stress "$GPU_SECONDS" ) > "${RAW_PREFIX}.vk" 2>&1
        local vmp; vmp=$(grep -oE "(计算)?吞吐: *[0-9.]+" "${RAW_PREFIX}.vk" | grep -oE "[0-9.]+" | head -1)
        if grep -q "结果校验异常: 0" "${RAW_PREFIX}.vk"; then
            ok "Vulkan ${GPU_SECONDS}s: compute 稳定 (0 异常, 吞吐 ${vmp:-?})"
            record gpu Vulkan_MPix "$vmp" "MPix/s" pass; ran=1
        else
            bad "Vulkan 失败"; tail -3 "${RAW_PREFIX}.vk" | tee -a "$CUR_LOG"; record gpu Vulkan "fail" "" fail
        fi
    else skip "vk_stress 缺失"; fi

    gpu_util_stop "$upid" gpu
    [ $ran -eq 1 ] && return 0 || return 1
}

# ---------- 6. NPU ----------


# ── 直接运行支持 (./modules/05-gpu.sh — 仅终端输出, 不生成报告; 报告请用 TOOL/stress.sh) ──
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    STANDALONE=1
    source "$(dirname "$(readlink -f "$0")")/lib.sh"
    standalone_init
    mod_gpu "$@"
fi
