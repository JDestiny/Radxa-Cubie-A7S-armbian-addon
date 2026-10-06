# Unified Driver (galcore) + TIM-VX 评估记录 (2026-09-05) — **已搁置**

## 结论
- **2026-09-05 收尾: 项目搁置** — 官方 A733 Linux 路线为 VIPLite (见文末), unified 非官方且驱动版本渠道未解决;
- 如需重启: 从"获取 6.4.15 驱动"开始 (MaverickLong 路线或全志 SDK 渠道)
- **冲突**: galcore 与 vipcore 硬件互斥, rmmod/insmod 无损切换 (实测)
- **6.4.18 glibc 用户态无公开分发**; Android SDK 6.4.18 为 bionic (APS2 packed 重定位, glibc 不处理)
- **6.4.15 glibc 用户态 (本地 ai-sdk) + 6.4.18 驱动 (radxa BSP) = malfunction 实测确认** (tensor create fail + segfault)
- 性能对比**未完成**: 需要 6.4.15 内核驱动配 6.4.15 glibc 用户态 (MaverickLong 路线), 驱动源码需从 radxa allwinner-bsp 历史/全志 SDK 获取 (当前网络拉取失败)

## 已完成
| 步骤 | 状态 |
|---|---|
| galcore 6.4.18.6.904649 驱动 (radxa cubie-aiot-v1.4.6) 编译 | ✅ galcore.ko 9.9MB |
| 驱动加载/切换/恢复 (vipcore↔galcore) | ✅ 无损 |
| bionic 6.4.18 用户态 glibc 移植 (7 库加载, objcopy+stub) | ✅ 加载级; ❌ 运行级卡 APS2 重定位 |
| 6.4.15 glibc 用户态 + 6.4.18 驱动 | ❌ malfunction (实测) |
| TIM-VX 编译 (libtim-vx.so + lenet sample) | ✅ 就绪, 待匹配驱动/用户态 |
| NPU 恢复 vipcore + golden | ✅ 3/3 |

## 技术要点 (供后续)
- Android libGAL NEEDED: libcutils/liblog/libsync/libc++ (stub 已写, /tmp/ud/stub/); @LIBC 版本符号可清 (.gnu.version 段/dynamic 条目)
- .rela.dyn 为 APS2 packed 格式 (magic "APS2") — glibc 不支持, 解包需实现 APS2 解码+重定位表重建
- TIM-VX 构建: cmake -DEXTERNAL_VIV_SDK=<sdk> -DTIM_VX_BUILD_EXAMPLES=ON (sdk = inc/{HAL,VX,CL} + lib/{GAL,OpenVX,VSC,ovxlib,NN*,CLC,OpenVXU,GLSLC})
- 参考: github.com/MaverickLong/Radxa-A733-NPU-Unified-Driver-Support-Package (6.4.15 驱动 patch 版)
- 待办: 获取 6.4.15 驱动源码 → 编译加载 → TIM-VX lenet 推理 → 与 vpm_run 同模型性能对比

## Radxa 官方教程核对 (2026-09-05, docs.radxa.com/cubie/a7s/app-dev/npu-dev)
- **官方 A733 Linux NPU 路线 = VIPLite (vipcore) + vpm_run + NBG** (与本地 B2 实现完全一致, 无改动需要)
- 官方 ai-sdk 源 = github.com/ZIFENG278/ai-sdk (本地 npu/ai-sdk 同源 ✅)
- ACUITY Toolkit (模型转换) 仅 X86 容器 (ubuntu-npu:v2.0.10.2 for A733); Model Zoo = dl.radxa.com/cubie/allwinner-model-zoo.tar.gz
- **官方无 A733 Linux unified/galcore 安装指引** (unified 文档仅通用说明) → unified 属非官方实验路线
- 结论: 性能对比的官方可比场景 = VIPLite 多模型 (已完成 resnet50/yolact/yolov5); unified 对比需先解决 6.4.15 驱动渠道 (低优先)
