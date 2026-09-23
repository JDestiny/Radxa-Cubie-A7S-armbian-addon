# modules — 各领域测试模块（均可单独运行）

本目录是 `../stress.sh` 的模块集合。**每个模块脚本既能被 `stress.sh` 调用（写报告），也能直接运行（只打印终端、不生成任何报告文件）。**

```
modules/
├── README.md      ← 本文件
├── lib.sh         公共库 (输出/记录/温度/依赖检查; 双模式)
├── 00-verify.sh   全硬件验证（CPU/内存/存储/网络/USB/显示/温度/watchdog 等 80+ 项）
├── 01-cpu.sh      CPU 满载 (stress-ng)
├── 02-membw.sh    内存带宽 (mbw)
├── 03-storage.sh  存储随机/顺序 IO (fio, 只写分区上的文件)
├── 04-crypto.sh   加密性能 (openssl speed)
├── 05-gpu.sh      GPU 三栈 (GLES / OpenCL / Vulkan)
├── 06-npu.sh      NPU (golden 3/3 + resnet50 N 次)
├── 07-mixed.sh    混合并发 (GPU+NPU+CPU 同时满载)
├── 08-network.sh  网络 (iperf3 TCP/UDP, loopback 或 peer)
├── 09-governor.sh CPU governor 调频 (结束自动恢复原 governor)
├── 10-container.sh 容器负载 (rootless docker)
├── 11-longrun.sh  长时稳定性 (默认在 stress.conf 中关闭)
└── tools/         底层测试工具 (被模块调用; 一般不需直接运行)
    ├── gpu/{gpu_stress,ocl_stress,vk_stress}(.c) + cs.comp / cs.spv
    ├── npu/npu_stress.sh             NPU 压测 (自动预检 PIL/numpy)
    ├── cpu/cpu_benchmark.py          CPU 多场景跑分
    └── thermal/temp_mon.sh           thermal zone 温度监控
```

> 运行 GPU 模块后，GPU 驱动会在 `tools/gpu/.shaders/` 生成 shader 运行时缓存（可随时删除，会自动重建）；
> GPU 工具均在该目录内执行，因此 TOOL 根目录不会被写入缓存。

## 单独运行

```bash
cd /home/radxa/armbian/TOOL
sudo ./modules/01-cpu.sh                    # 默认 60s
sudo CPU_SECONDS=180 ./modules/01-cpu.sh    # 环境变量覆盖任意参数
sudo ./modules/00-verify.sh --quick         # 只跑硬件验证 0-33 章 (快速)
```

- **不生成任何文件**：独立模式下结果只打印到终端；模块内部工具原始输出写 `/tmp` 临时文件，退出即删（不写日志、不写报告）。
- **不读 `stress.conf`**：独立运行使用下表快速默认值，避免误跑 40 分钟长测；需要完整配置请用 `../stress.sh`。
- 需要报告 → `cd .. && sudo ./stress.sh [--quick|--no-stress|--only ...]`；报告是**单个文件**，直接生成在 `../`（TOOL 根）：`测试报告-<日期>-stress-full.log` / `-quick.log` / `-no-stress.log`。
- 需要 root 的模块：00/01/03/05/06/07/09/10/11（温度、NPU、governor、docker、设备节点）。

## 模块参数与独立默认值

| 模块 | 函数 | 主要环境变量（独立默认值） | 说明 |
|---|---|---|---|
| 00-verify | `mod_verify` | `QUICK_MODE_INT=1`（快速）或 `--quick` | 硬件验证 0-33 章：逐条 PASS/FAIL/SKIP 直接写入报告；计数取自本函数变量（不解析子进程输出） |
| 01-cpu | `mod_cpu` | `CPU_SECONDS=60` | `stress-ng --cpu $(nproc)`，记录 bogo ops/s 与峰值温度 |
| 02-membw | `mod_membw` | `MEMBW_MB=512`、`MEMBW_RUNS=3`、`MEMBW_METHODS="memcpy dumb"` | mbw 平均带宽 |
| 03-storage | `mod_storage` | `STORAGE_DEV=/dev/mmcblk1p2`、`STORAGE_DIR=/home/radxa/stress-io-test`、`STORAGE_SIZE=256M`、`STORAGE_RUNTIME=10`、`STORAGE_JOBS=4` | fio 4K 随机读/写 + 顺序读；**不写裸设备**，eMMC 只读策略下用 SD 分区 |
| 04-crypto | `mod_crypto` | `CRYPTO_SECONDS=3`、`CRYPTO_ALGS="aes-256-gcm sha256 sha512 chacha20-poly1305"` | openssl speed 单核吞吐 |
| 05-gpu | `mod_gpu` | `GPU_SECONDS=30` | GLES（EGL surfaceless 1080p）/ OpenCL / Vulkan 三栈顺序跑；额外记录 `util_avg`/`util_peak`（读驱动 debugfs `/sys/kernel/debug/pvr/status`，需 root） |
| 06-npu | `mod_npu` | `NPU_COUNT=50` | golden 3/3 校验 + resnet50 推理 N 次 |
| 07-mixed | `mod_mixed` | `MIXED_SECONDS=60`、`MIXED_CPU_LOAD=6` | GPU+NPU+CPU 同时满载，检测降级 |
| 08-network | `mod_network` | `NETWORK_MODE=loopback`、`NETWORK_SECONDS=10`、`NETWORK_UDP=1`、`NETWORK_PARALLEL=4`、`NETWORK_PEER=192.168.123.9` | loopback 自起 iperf3 服务端；peer 模式需对端 `iperf3 -s` |
| 09-governor | `mod_governor` | `GOVERNOR_SECONDS=10`、`GOVERNOR_LIST="schedutil performance powersave ondemand"` | 逐个 governor 加负载采频率，**结束恢复原值** |
| 10-container | `mod_container` | `CONTAINER_N=2`、`CONTAINER_IMAGE=docker.io/library/alpine:latest`、`CONTAINER_CMD=…`（空转计数） | rootless docker 并发容器 |
| 11-longrun | `mod_longrun` | `LONGRUN_SECONDS=120`、`LONGRUN_CYCLES=0` | 每 300s 一轮 CPU+GPU+NPU，统计失败轮与峰值温度 |

## 公共库 `lib.sh`

- **输出原语** `_emit_log/_emit_head/_emit_ok/_emit_bad/_emit_skip`：供模块内自实现的检查（如 00-verify 的 0-33 章）直接写入报告/终端；具体实现（不按函数名委托），模块覆盖 `log/ok/bad/skip` 也不会递归。
- **报告是纯文本**：写文件前统一剥离 ANSI 颜色码（终端保留颜色）。
- **GPU 利用率采样**：`gpu_util_start()` / `gpu_util_stop()` —— 压测期间每秒读驱动 debugfs 的
  `GPU Utilisation`，把 `util_avg`/`util_peak` 记入结果；读不到时静默跳过（无副作用）。
  htop 侧的 GPU 显示由驱动变体提供（见 `B-安装后配置/gpu/GPU记账补丁-稳定性分析.md`），与 TOOL 无关。
- **报告模式**（被 `stress.sh` source）：`record` 写 `/tmp` 内部结果表（仅用于生成汇总表，结束即删）；模块的人读输出**直接写入报告文件 `../测试报告-<日期>-<模式>.log`（边跑边写）**；工具原始输出先写 `/tmp` 临时目录（模块内用 `${RAW_PREFIX}.xxx`），模块结束时由 `merge_raw_outputs` 逐段追加进报告（`── 原始输出: 模块.来源 ──`）后删除。`run_module <name> <enable> <func>` 负责计时、结果记录与合并。
- **独立模式**（模块直接运行，脚本末尾检测 `BASH_SOURCE[0] = $0` 后 `STANDALONE=1`）：`record` 为空操作，`log` 仅终端输出，工具原始输出写 `/tmp` 临时文件并在退出时删除 —— **不产生报告、不产生日志**。
- 辅助函数：`info/ok/bad/skip`、`head1/head2`、`temp_of <zone 关键字>`、`need_cmd`、`env_snapshot`。

## 新增模块约定

1. 文件名 `NN-名称.sh`（两位数字前缀决定执行顺序），内部只定义一个 `mod_<名称>()` 函数。
2. 结果用 `record <模块> <指标> <值> <单位> <pass|fail|skip>` 记录；无依赖/无外设时用 `skip`，真失败用 `bad`。
3. 结尾加统一入口：

```bash
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    STANDALONE=1
    source "$(dirname "$(readlink -f "$0")")/lib.sh"
    standalone_init
    mod_<名称> "$@"
fi
```

4. 在 `../stress.conf` 增加开关与参数，在 `../stress.sh` 的模块加载段加入 `run_module` 调用，并更新本文件与 `../README.md` 的模块表。
