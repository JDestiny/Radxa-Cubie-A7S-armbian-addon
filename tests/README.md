# 测试脚本

本目录是配套的测试工具集：**装好系统、或装完本仓库的附加组件之后，用来确认硬件与各组件是否正常**。

> 这里只放脚本，不放测试报告。报告由你运行时在本机生成。

## 一、一键入口：`stress.sh`

```bash
sudo ./stress.sh                 # 全测（默认）：全硬件验证 + 标准压测（约 40 分钟）
sudo ./stress.sh --quick         # 快速：硬件验证快速版 + 短压测（约 6-7 分钟，适合装完组件后冒烟）
sudo ./stress.sh --no-stress     # 只做验证类模块（硬件验证，约 5 分钟，不压测）
sudo ./stress.sh --only verify,gpu    # 只跑指定模块
sudo ./stress.sh --help          # 全部参数
```

- 运行报告落在 `reports/`（自动创建），文件名形如 `测试报告-<日期>-<模式>.log`；
- 每个模块脚本**也能单独直接运行**（例如 `sudo ./modules/05-gpu.sh`），此时只在终端打印，不写报告文件；
- 输出统一为 `[PASS] / [FAIL] / [SKIP]`，结尾给汇总统计（含温度）。

## 二、模块一览（`modules/`）

| 模块 | 内容 | 依赖 |
|---|---|---|
| `00-verify.sh` | 全硬件验证：CPU 拓扑/调频、内存、存储、网络、WiFi/BT、USB、显示、温度、watchdog、dmesg 体检等 80+ 项 | 无（缺失项自动 SKIP） |
| `01-cpu.sh` | CPU 满载压力 | `stress-ng` |
| `02-membw.sh` | 内存带宽 | `mbw` |
| `03-storage.sh` | 存储随机/顺序 IO（只在分区内写文件） | `fio` |
| `04-crypto.sh` | 加密性能 | `openssl` |
| `05-gpu.sh` | GPU 三栈：GLES / OpenCL / Vulkan | 已装 GPU 用户态（见 `../gpu/`） |
| `06-npu.sh` | NPU：官方 golden 测试 + resnet50 多轮推理 | 已装 NPU 组件（见 `../npu/`） |
| `07-mixed.sh` | GPU + NPU + CPU 混合并发 | 同上 |
| `08-network.sh` | 网络吞吐（iperf3，回环或指定对端） | `iperf3` |
| `09-governor.sh` | CPU 调频爬升（结束后自动恢复原 governor） | 无 |
| `10-container.sh` | 容器负载（rootless docker） | `docker`（可选） |
| `11-longrun.sh` | 长时稳定性（默认关闭，需在 `stress.conf` 打开） | 无 |

底层小工具在 `modules/tools/`（GPU/NPU/CPU/温度的压测程序与脚本），一般不需要直接调用。

## 三、配置

`stress.conf`（首次运行会自动生成）可设置：是否压测、各模块时长、长时测试开关、网络对端地址等。命令行参数优先于配置文件。

## 四、说明

- 涉及满载/IO 的模块**不要在其他重要任务运行时执行**；
- `03-storage.sh` 只在指定分区内创建/删除自己的文件，不会碰其他数据；
- `09-governor.sh` 与 `10-container.sh` 会在结束时恢复原有状态；
- 部分项目需要硬件才能测（摄像头、PCIe 设备、外接 USB 等），缺失时如实标为 `SKIP` 并在报告中说明原因，而不是判失败。
