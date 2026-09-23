#!/bin/bash
# 温度监控: 打印所有 thermal zone
# 用法: ./temp_mon.sh [间隔秒=10] [次数=6]
INT=${1:-10}; N=${2:-6}
for i in $(seq 1 $N); do
    line="$(date +%H:%M:%S)"
    for z in /sys/class/thermal/thermal_zone*; do
        t=$(cat $z/type 2>/dev/null); v=$(cat $z/temp 2>/dev/null)
        [ -n "$t" ] && line="$line ${t%%_thermal_zone}:$((v/1000))C"
    done
    echo "$line"
    sleep $INT
done
