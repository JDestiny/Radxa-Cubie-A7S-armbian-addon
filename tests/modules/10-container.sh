#!/bin/bash
# SPDX-License-Identifier: MIT
# 模块 10: 容器负载 (rootless docker)   (由 stress.sh source)

mod_container() {
    local DK=/home/radxa/k8s/docker-rootless
    if [ ! -x "$DK/bin/docker" ]; then skip "rootless docker 不可用 ($DK)"; record container docker missing "" skip; return 1; fi
    export XDG_RUNTIME_DIR=/run/user/1000
    export PATH="$DK/bin:$PATH"
    export DOCKER_HOST=unix:///run/user/1000/docker.sock
    if ! docker info >/dev/null 2>&1; then skip "docker daemon 未运行 (systemctl --user start docker)"; record container daemon "down" "" skip; return 1; fi
    info "容器负载: ${CONTAINER_N} 并发容器 (镜像 $CONTAINER_IMAGE)"
    # 镜像检查 (离线则用本地已有)
    if ! docker image inspect "$CONTAINER_IMAGE" >/dev/null 2>&1; then
        info "本地无 $CONTAINER_IMAGE, 尝试拉取 ..."
        if ! timeout 120 docker pull "$CONTAINER_IMAGE" >/dev/null 2>&1; then
            local localimg; localimg=$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -v "<none>" | head -1)
            if [ -n "$localimg" ]; then
                info "拉取失败, 改用本地镜像: $localimg"; CONTAINER_IMAGE="$localimg"
            else
                skip "无可用镜像且拉取失败"; record container image "unavailable" "" skip; return 1
            fi
        fi
    fi
    local t0=$SECONDS pids=()
    local i
    for i in $(seq 1 "$CONTAINER_N"); do
        docker run --rm --name stress-c$i "$CONTAINER_IMAGE" sh -c "$CONTAINER_CMD" >> "${RAW_PREFIX}.run" 2>&1 &
        pids+=($!)
    done
    local failn=0 p
    for p in "${pids[@]}"; do wait "$p" || failn=$((failn+1)); done
    local dt=$((SECONDS - t0))
    local done_n; done_n=$(grep -c "^done$" "${RAW_PREFIX}.run" 2>/dev/null || echo 0)
    if [ "$failn" -eq 0 ] && [ "$done_n" -ge "$CONTAINER_N" ]; then
        ok "容器负载: ${CONTAINER_N} 容器全部完成 (${dt}s, 镜像 $CONTAINER_IMAGE)"
        record container runs "$CONTAINER_N" "containers" pass
        return 0
    fi
    bad "容器负载: $failn/$CONTAINER_N 失败 (完成 $done_n)"; record container runs "$done_n/$CONTAINER_N" "" fail; return 1
}

# ---------- 11. 长时稳定性 (可选) ----------


# ── 直接运行支持 (./modules/10-container.sh — 仅终端输出, 不生成报告; 报告请用 TOOL/stress.sh) ──
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    STANDALONE=1
    source "$(dirname "$(readlink -f "$0")")/lib.sh"
    standalone_init
    mod_container "$@"
fi
