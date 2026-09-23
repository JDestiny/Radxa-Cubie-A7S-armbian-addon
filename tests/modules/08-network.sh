#!/bin/bash
# 模块 08: 网络 (iperf3)   (由 stress.sh source)

mod_network() {
    if ! need_cmd iperf3; then skip "iperf3 未安装"; return 1; fi
    local peer="" spid=""
    if [ "$NETWORK_MODE" = "loopback" ]; then
        info "iperf3 loopback 模式 (本机自测, 服务端自动起)"
        iperf3 -s --logfile "${RAW_PREFIX}.server" >/dev/null 2>&1 &
        spid=$!
        sleep 2
        peer="127.0.0.1"
    else
        peer="$NETWORK_PEER"
        info "iperf3 peer 模式: $peer (需对端已运行 iperf3 -s)"
    fi
    local okc=0
    # TCP 上行 (client → server)
    iperf3 -c "$peer" -t "$NETWORK_SECONDS" -P "$NETWORK_PARALLEL" -f m > "${RAW_PREFIX}.tcp_up" 2>&1
    local up; up=$(grep -oE "[0-9.]+ Mbits/sec" "${RAW_PREFIX}.tcp_up" | tail -1)
    if [ -n "$up" ]; then
        ok "TCP 上行 (${NETWORK_PARALLEL} 并发流): $up"; record network tcp_up "$(echo $up|cut -d' ' -f1)" "Mbits/s" pass; okc=1
    else bad "TCP 上行失败"; record network tcp_up "fail" "" fail; fi
    # TCP 下行
    iperf3 -c "$peer" -t "$NETWORK_SECONDS" -P "$NETWORK_PARALLEL" -R -f m > "${RAW_PREFIX}.tcp_down" 2>&1
    local dn; dn=$(grep -oE "[0-9.]+ Mbits/sec" "${RAW_PREFIX}.tcp_down" | tail -1)
    if [ -n "$dn" ]; then
        ok "TCP 下行 (reverse): $dn"; record network tcp_down "$(echo $dn|cut -d' ' -f1)" "Mbits/s" pass
    else bad "TCP 下行失败"; record network tcp_down "fail" "" fail; fi
    # UDP (丢包率)
    if [ "$NETWORK_UDP" = "1" ]; then
        iperf3 -c "$peer" -u -b 500M -t "$NETWORK_SECONDS" -f m > "${RAW_PREFIX}.udp" 2>&1
        local uj; uj=$(grep -E "receiver|sender" "${RAW_PREFIX}.udp" | tail -1)
        local loss; loss=$(grep -oE "\([0-9.]+%\)" "${RAW_PREFIX}.udp" | tail -1)
        if [ -n "$uj" ]; then
            ok "UDP: $uj 丢包 $loss"; record network udp "$(echo $uj|grep -oE '[0-9.]+ Mbits/sec')" "Mbits/s" pass
            record network udp_loss "${loss//[()%]/}" "%" pass
        else bad "UDP 失败"; record network udp "fail" "" fail; fi
    fi
    if [ -n "$spid" ]; then kill $spid 2>/dev/null; pkill -f "iperf3 -s" 2>/dev/null; fi
    [ $okc -eq 1 ] && return 0 || return 1
}

# ---------- 10. 容器负载 (rootless docker) ----------


# ── 直接运行支持 (./modules/08-network.sh — 仅终端输出, 不生成报告; 报告请用 TOOL/stress.sh) ──
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    STANDALONE=1
    source "$(dirname "$(readlink -f "$0")")/lib.sh"
    standalone_init
    mod_network "$@"
fi
