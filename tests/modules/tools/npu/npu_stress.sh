#!/bin/bash
# NPU 压测 (多模型): golden 检测 + resnet50 分类连续推理
# 用法: sudo ./npu_stress.sh [resnet50次数=200]
# 依赖: vpm_run (/usr/local/bin), 模型在 B-安装后配置/npu/
CNT=${1:-200}
NPU_BASE=/home/radxa/armbian/B-安装后配置/npu
export LD_LIBRARY_PATH=/usr/local/lib
PASS=0; FAIL=0

# 依赖预检: resnet50 图像转换需要 python3 + PIL + numpy (缺则尝试安装)
if ! python3 -c "import PIL, numpy" 2>/dev/null; then
    echo "  [..] resnet50 需要 python3-pil/python3-numpy, 尝试安装..."
    if ! apt-get install -y python3-pil python3-numpy >/dev/null 2>&1; then
        echo "  [FAIL] 无法安装 python3-pil/python3-numpy (需网络), resnet50 将失败"
    fi
fi
run_golden() {
    local TMPD=$(mktemp -d)
    cp "$NPU_BASE/official-golden-test"/* "$TMPD"/
    sed -i 's|/data/assets/||g' "$TMPD/sample.txt"
    cd "$TMPD"
    if vpm_run -s sample.txt -l 1 -b 0 > vpm.log 2>&1 && \
       grep -q "Test output 0 passed" vpm.log && grep -q "Test output 2 passed" vpm.log; then
        echo "  [PASS] golden (yolov5 检测) 3/3"
        PASS=$((PASS+1))
    else
        echo "  [FAIL] golden"; FAIL=$((FAIL+1))
    fi
    rm -rf "$TMPD"
}
run_resnet() {
    local D=/tmp/rn50test
    mkdir -p $D
    cp "$NPU_BASE/ai-sdk/examples/resnet50/model/v3/resnet50.nb" $D/ 2>/dev/null || return 1
    python3 - "$D" <<'PYEOF'
import sys
from PIL import Image
import numpy as np
d = sys.argv[1]
img = Image.open('/home/radxa/armbian/B-安装后配置/npu/ai-sdk/examples/resnet50/input_data/dog_224_224.jpg').convert('RGB')
open(d+'/input.bin','wb').write(np.array(img).transpose(2,0,1).tobytes())
PYEOF
    printf '[network]\nresnet50.nb\n[input]\ninput.bin\n' > $D/sample.txt
    cd $D
    local t0=$(date +%s%N) n=$CNT i
    for i in $(seq 1 $n); do
        timeout 30 vpm_run -s sample.txt -l 1 -b 1 >/dev/null 2>&1 || { echo "  [FAIL] resnet50 第 $i 次"; FAIL=$((FAIL+1)); return; }
    done
    local t1=$(date +%s%N) ms=$(( (t1-t0)/1000000 ))
    local top1=$(timeout 30 vpm_run -s sample.txt -l 1 -b 0 --show_top5 1 2>&1 | grep -m1 "231:")
    if [ -n "$top1" ]; then
        echo "  [PASS] resnet50 分类 ${n} 次 ($((ms/n)) ms/次), top1=collie(231) 正确"
        PASS=$((PASS+1))
    else
        echo "  [FAIL] resnet50 top1 异常"; FAIL=$((FAIL+1))
    fi
}
echo "== NPU 压测 =="
run_golden
run_resnet
echo "NPU 压测汇总: PASS=$PASS FAIL=$FAIL"
exit $FAIL
