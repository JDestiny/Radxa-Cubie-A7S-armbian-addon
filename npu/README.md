# npu —— NPU 支持（VIPLite）：中间件与运行时安装

Cubie A7S 的 NPU（全志 A733）在 Linux 上的官方路线是 **VIPLite**：内核驱动 `vipcore` 提供 `/dev/vipcore`，
用户态由中间件 `libNBGlinker` / `libVIPhal` 与模型运行工具 `vpm_run` 组成，模型格式为 **NBG**（`.nb`）。

装完系统后，NPU 往往只有内核驱动、没有用户态中间件与 `vpm_run`，`.nb` 模型跑不起来 —— 本组件补齐的就是这部分。

本目录的 `install-npu.sh` 负责**用户态那部分**：检查驱动 → 安装中间件 → 安装 `vpm_run` → 用官方 golden 模型验证。
它**不安装内核驱动**（由内核提供），也**不下载 AI SDK**（需你自行取得，见 [组件来源](#组件来源)）。

## 功能

`install-npu.sh` 的四步（脚本会逐步打印结果，任一步失败即以非 0 退出）：

| 步骤 | 内容 |
|---|---|
| `[1/4]` 检查 NPU 内核驱动 | 确认 `vipcore` 已加载且 `/dev/vipcore` 存在；未加载则尝试 `modprobe vipcore`；内核里没有该模块则直接报错退出 |
| `[2/4]` 安装中间件 | 把 `ai-sdk/viplite-tina/lib/aarch64-none-linux-gnu/v2.0/` 下的 `libNBGlinker.so`、`libVIPhal.so` 安装到 `/usr/local/lib/`，然后 `ldconfig` |
| `[3/4]` 安装 `vpm_run` | 优先安装 AI SDK 里已编译好的 `ai-sdk/examples/vpm_run/vpm_run` 到 `/usr/local/bin/`；没有则在该目录用 `make AI_SDK_PLATFORM=a733` 现场编译后再安装 |
| `[4/4]` golden 验证 | 用官方测试套件（`yolov5.nb` + `sample.txt`）跑一遍 `vpm_run`，比对官方 golden 输出；文件缺失时跳过（不影响安装） |

安装到 `/usr/local/` 而不进系统目录，卸载时删掉即可，不会影响系统里的其它包。

## 前置条件

- **板卡 / 系统**：Radxa Cubie A7S（全志 A733 / sun60iw2p1）+ Armbian（内核分支 `6.6.98-vendor-sun60iw2`）。
- **root 权限**：脚本要 `sudo`（要写 `/usr/local/lib`、`/usr/local/bin`）。
- **内核带 NPU 驱动**：Armbian 的 sun60iw2 BSP 内核自带 `CONFIG_AW_NNA_VIP`，模块名 `vipcore`。
  可以先确认：

```bash
modinfo vipcore                    # 能查到说明当前内核有该驱动
lsmod | grep vipcore               # 是否已加载
ls -l /dev/vipcore                 # 设备节点是否存在
```

  若内核没有该模块，脚本会报错并提示需要启用 `CONFIG_AW_NNA_VIP` —— 那是内核配置层面的问题，本脚本不处理。
- **AI SDK 已放到位**：`npu/ai-sdk/`（约 800 MB，见 [组件来源](#组件来源)）。缺失时脚本在第 `[2/4]` 步报错退出。
- **编译工具链**（仅当 SDK 里没有预编译的 `vpm_run` 时需要）：`build-essential`、`libc6-dev`；
  按官方文档建议先装：`sudo apt install build-essential libc6-dev`。
- **版本对应**：A733 用 VIPLite **v2.0**（即 `.../lib/aarch64-none-linux-gnu/v2.0/`）；T527 用 v1.13。本板取 v2.0。
- **脚本可执行权限**：若从 ZIP 包解压导致权限丢失，先 `chmod +x npu/install-npu.sh`。

## 安装

### 1. 取得 AI SDK

```bash
cd /path/to/radxa-cubie-a7s-armbian-addon
git clone --depth 1 https://github.com/ZIFENG278/ai-sdk npu/ai-sdk
```

克隆后确认中间件与示例都在：

```bash
ls -l npu/ai-sdk/viplite-tina/lib/aarch64-none-linux-gnu/v2.0/{libNBGlinker.so,libVIPhal.so}
ls -l npu/ai-sdk/examples/vpm_run/
```

### 2. 运行安装脚本

```bash
cd npu
sudo ./install-npu.sh
```

脚本会依次完成上面四步。如果第 `[3/4]` 步提示"未找到预编译 vpm_run"并自行编译，
需要机器上有 `gcc` / `make`；也可以先手动编译好再跑脚本：

```bash
cd ai-sdk/examples/vpm_run
make AI_SDK_PLATFORM=a733            # 产出 ./vpm_run
# 官方文档还提供安装方式（可选）：
# make install AI_SDK_PLATFORM=a733 INSTALL_PREFIX=./
```

### 3. 关于 golden 测试文件（可选）

第 `[4/4]` 步用到的 `yolov5.nb` 与 `sample.txt` 需要放在 `npu/official-golden-test/` 下
（这套文件随 AI SDK 分发，属于全志官方测试套件）。脚本会把它们复制到临时目录、
把 `sample.txt` 里的绝对路径改成相对路径，再执行：

```bash
LD_LIBRARY_PATH=/usr/local/lib vpm_run -s sample.txt -l 1 -b 0
```

放不放都不影响前两步的安装结果 —— 目录不存在时脚本会打印"跳过"。

## 验证

```bash
# 1) 内核驱动与设备节点
lsmod | grep vipcore
ls -l /dev/vipcore

# 2) 中间件是否装好（ldconfig 缓存里能找到）
ls -l /usr/local/lib/libNBGlinker.so /usr/local/lib/libVIPhal.so
ldconfig -p | grep -E 'NBGlinker|VIPhal'

# 3) 工具是否就位
command -v vpm_run
vpm_run -h                       # 打印参数说明即说明运行库依赖正常
```

`vpm_run` 的判读要点：

- **成功**：进程返回 0，且输出里出现 `Test output 0 passed` 与 `Test output 2 passed`（脚本按这两条判定 golden 比对）；
- **失败**：脚本会打印 `vpm_run` 的最后几行输出，常见原因是中间件没装好（`LD_LIBRARY_PATH` 找不到 `libVIPhal.so`）或模型/输入文件缺失。

手工复现 golden 验证（等价于脚本第 `[4/4]` 步）：

```bash
export LD_LIBRARY_PATH=/usr/local/lib
tmp=$(mktemp -d) && cp /path/to/radxa-cubie-a7s-armbian-addon/npu/official-golden-test/* "$tmp"/
cd "$tmp" && sed -i 's|/data/assets/||g' sample.txt
vpm_run -s sample.txt -l 1 -b 0
```

跑自己的模型：`sample.txt` 就是配置文件，按 `[network]`（`.nb` 模型）/ `[input]`（输入数据）/
`[golden]`（可选，golden 数据）/ `[output]`（可选，保存输出）分段填写，然后 `vpm_run -s sample.txt -l 1 -b 0`
（`-l` 循环次数、`-b 1` 跳过输出文件、`-d` 指定设备、`-t` 超时毫秒，详见 `vpm_run -h` 与官方文档）。

## 卸载 / 回滚

本脚本只往 `/usr/local/` 里放三个文件，删除即可回到安装前：

```bash
sudo rm -f /usr/local/bin/vpm_run
sudo rm -f /usr/local/lib/libNBGlinker.so* /usr/local/lib/libVIPhal.so*
sudo ldconfig
```

- `vipcore` 由内核提供，**不需要**（也不应）随本组件卸载；`sudo modprobe -r vipcore` 可临时卸载，重启后恢复。
- `npu/ai-sdk/` 与 `npu/official-golden-test/` 是下载来的资料，脚本不会往里写任何东西，直接删除或保留都行。
- 想重新安装：放回 `ai-sdk/` 后再跑一次 `sudo ./install-npu.sh`（脚本是幂等的，重复执行只会覆盖同样几个文件）。

## 组件来源

| 内容 | 体积 | 来源 |
|---|---|---|
| `ai-sdk/` | 约 800 MB | Radxa 官方文档为 Cubie A7S 指定的 AI SDK 仓库：<https://github.com/ZIFENG278/ai-sdk>（含 VIPLite 中间件、`vpm_run` 例程、模型与样例数据） |
| `official-golden-test/`（`yolov5.nb` + `sample.txt`） | 随 SDK | 全志官方测试套件，随 AI SDK 分发；可选，缺失时脚本跳过验证 |
| `install-npu.sh` | — | 本项目编写（调用上述厂商组件） |

```bash
git clone --depth 1 https://github.com/ZIFENG278/ai-sdk npu/ai-sdk
```

- 仓库约 300 MB（克隆后展开约 800 MB），下载时间取决于网络；若 `git clone` 受限，也可以在 GitHub 页面用
  **Code → Download ZIP** 下载后解压，并把目录重命名为 `ai-sdk`。
- 若官方仓库地址有更新，以 Radxa 文档的 NPU 页面为准：
  <https://docs.radxa.com/en/cubie/a7s/app-dev/npu-dev>（其中的 `vpm_run` 页给出了 SDK 下载与编译命令）。
- 模型转换（把 ONNX 等转成 `.nb`）由 **ACUITY Toolkit** 在 x86 容器里完成，不在这块板上运行；
  可直接使用的模型见官方文档的 Model Zoo 页面。
- 各组件的获取步骤汇总见 [`../tools/厂商组件获取.md`](../tools/厂商组件获取.md)，
  来源与许可说明见 [`../THIRD-PARTY.md`](../THIRD-PARTY.md)。
