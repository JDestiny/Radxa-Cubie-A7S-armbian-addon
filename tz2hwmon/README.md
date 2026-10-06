# tz2hwmon —— thermal_zone → hwmon 只读桥接模块（B 类工具）

> **用途**：全志 BSP 把温度只注册在 `thermal_zone`（cpub/cpul/ddr/npu/gpu/skin），
> 而 `libsensors` 只认 `hwmon` → `sensors` / `btop` / **`htop` 温度表头**都读不到。
> 本模块把这些 zone 桥接成 hwmon 通道（只读转发），让标准工具能显示温度；**不影响内核温控与 trip 点**。
>
> **归类**：B 类（装完系统手动跑 `install-tz2hwmon.sh`）。**不是 DKMS** → **换内核 / 刷完新镜像必须重跑一次**。
> 本文原为 `htop磁盘IO与温度-结论.md` 的温度部分（2026-09-11 排查、09-12 实装）；2026-09-13 按类拆分并入。
> 磁盘 I/O 部分见 `A-编译期修复/README.md` 的 A13 专题；GPU 部分见 `../gpu/htop-GPU显示-原理与门控.md`。
>
> ⚠️ **2026-09-14 实测更正**（完整证据链见同目录 **`温度传感器与风扇-实测结论.md`**）：
> **`skin_zone` 不是外壳/板面温度** —— 它是驱动用**大核温度 ÷5** 合成的虚拟值，crit 50 °C 对应真实 ~160 °C，**实际不可达**；
> **`cpub_thermal_zone` / `cpul_thermal_zone` 两个主热区的名字与真实簇相反**（实测 `cpul` 才是大核 A76）。

## 一、为什么 htop 读不到温度（根因）

htop 3.4.1 支持温度（二进制内有 `LibSensors_getCPUTemperatures`），但它走 **libsensors**，而 libsensors **只认 hwmon**。本板实测：

```
/sys/class/hwmon/hwmon0 = tcpm_source_psy_14_004e  → temp*_input 数量 = 0
/sys/class/hwmon/hwmon1 = pwmfan                   → temp*_input 数量 = 0
/sys/class/thermal/thermal_zone0..7                → 8 个温度源，但全部无 hwmon 映射
```

**库在、数据源在，中间断了** —— 所以 `show_cpu_temperature=1` 也只会得到空白。

两个关键事实（2026-09-12 实测确认）：

1. htop 3.x 是**用 `dlopen("libsensors.so.5")` 动态加载** libsensors 的
   （`readelf -d $(which htop)` 里没有该 NEEDED，但符号表有 `dlopen/dlsym`，二进制里有 `libsensors.so.5` 字符串）
   → 本机 `/usr/lib/aarch64-linux-gnu/libsensors.so.5` 已在位，**不需要自编 htop**。
2. htop **只接受白名单芯片名**（二进制内置：`cpu_thermal` `soc_thermal` `acpitz` `coretemp` `k10temp` `zenpower`）
   → 桥接模块必须用这些名字，否则即使加载也照样空白。v1 用 `tz2hwmonN` 就是因此完全不可见。

## 二、本板 8 路 thermal zone（不装模块也能直读）

```bash
for z in /sys/class/thermal/thermal_zone*; do
  printf '%-24s %s %s\n' "$(basename $z)" "$(cat $z/type)" "$(cat $z/temp)"
done
```

| zone | type | **真实来源（2026-09-14 实测）** |
|---|---|---|
| 0 | `cpub_thermal_zone` | CPU **小核 A55**（名字与实测相反） |
| 1 | `ddr_thermal_zone` | DDR (LPDDR5) |
| 2 | `npu_thermal_zone` | NPU |
| 3 | `cpul_thermal_zone` | CPU **大核 A76**（名字与实测相反） |
| 4 | `gpu_thermal_zone` | GPU |
| 5 | `cpul_idle_zone` | ⚠️ **交叉引用**：读的是 0 号通道 = **小核**（不是 3 号） |
| 6 | `cpub_idle_zone` | ⚠️ **交叉引用**：读的是 3 号通道 = **大核**（不是 0 号） |
| 7 | `skin_zone` | ⚠️ **虚拟值**：**大核温度 ÷5 压缩**（≥30 °C 下限）；crit 50 °C ↔ 真实 ~160 °C，**不可达** |

- 读数单位是**毫摄氏度**（`34162` = 34.162 °C）。
- `cpul_idle_zone`/`cpub_idle_zone` 是内核 thermal 策略用的**虚拟别名**，与主 zone 是**交叉**对应的：
  `cpul_idle_zone` ≡ `cpub_thermal_zone`（通道 0）、`cpub_idle_zone` ≡ `cpul_thermal_zone`（通道 3），
  同一时刻读数**逐位相同**（实测）。统计均值时不应重复计入 —— 模块默认跳过它们（`include_aliases=1` 可保留）。
- ⚠️ 传感器归属与命名的完整证据链（电路图无温度器件 / 5 个物理传感器 / 虚拟通道公式 / taskset 交叉实验）
  见同目录 `温度传感器与风扇-实测结论.md`。

## 三、其他温度/散热接口

- `/sys/class/devfreq/` 只有 **NPU**（`3600000.npu`），**没有 GPU** 调频节点。
- 风扇：`/sys/class/hwmon/hwmon1/pwm1` 可读占空比（0–255），`pwm1_enable` 为 `manual`；
  **无 `fan1_input`，读不到转速**。
- `sensors` 命令未安装（`lm-sensors` 没装），**且装了也没用** —— 理由同第一节：hwmon 里没有温度项。

## 四、v2 的通道映射（htop 白名单是关键坑）

| thermal_zone | v2 hwmon 芯片名 | temp1_label | htop 可见 |
|---|---|---|---|
| `cpub_thermal_zone`（**实为 A55 小核**） | `cpu_thermal` | `cpub` | ✅ 显示 CPU 温度 |
| `cpul_thermal_zone`（**实为 A76 大核**） | `soc_thermal` | `cpul` | ✅ |
| `ddr_thermal_zone` | `ddr_thermal` | `ddr` | sensors/btop |
| `npu_thermal_zone` | `npu_thermal` | `npu` | sensors/btop |
| `gpu_thermal_zone` | `gpu_thermal` | `gpu` | sensors/btop |
| `skin_zone`（**虚拟值，非壳温**） | `skin_thermal` | `skin` | sensors/btop |
| `cpub_idle_zone` / `cpul_idle_zone` | **默认跳过**（虚拟别名，与主 zone 交叉对应，避免重复计数） | — | 可用 `include_aliases=1` 保留 |

## 五、安装（脚本自动完成：检查 → 编译 → 安装 → 自启 → 加载 → 校验）

```bash
cd /home/radxa/armbian/B-安装后配置/tz2hwmon
sudo ./install-tz2hwmon.sh              # 编译 + 安装到 /lib/modules/$(uname -r)/extra + modules-load.d + 校验
sudo ./install-tz2hwmon.sh --prebuilt   # 用仓库内已编好的 tz2hwmon.ko（会校验 vermagic）
sudo ./install-tz2hwmon.sh --no-autoload# 装但不随开机自动加载
sudo ./install-tz2hwmon.sh --status     # 查看模块/通道/温度（只读）
sudo ./install-tz2hwmon.sh --uninstall  # 卸载（rmmod + 删模块与自启配置 + depmod）
```

前置：`linux-headers-$(uname -r)`（本机 `/usr/src/linux-headers-6.6.98-vendor-sun60iw2` 已有）。
换内核后需**重新编译安装**（vermagic 绑定内核版本；脚本第 1 步会校验并报错）。

> ⚠️ 与 GPU 驱动（DKMS，换内核**自动重建**）不同：**本模块不是 DKMS**，
> 换内核 / 刷完新镜像后**必须重跑一次本脚本**，否则 htop 的温度表头会变回空白。
> 完整的"换内核 / 换系统后必做清单"见主 `README.md` 第七节（自检 3 条命令也在那里）。

## 六、验证 + 实装结果

```bash
sudo ./install-tz2hwmon.sh --status            # 通道清单 + 是否命中 htop 白名单
ls /sys/class/hwmon/hwmon*/name
grep -r . /sys/class/hwmon/hwmon*/temp1_input 2>/dev/null
# htop: 按 F2 → Display options → 勾 "Also show CPU temperature"（或 htoprc 里 show_cpu_temperature=1）
```

预期：每个 CPU 温度通道 → `/sys/class/hwmon/hwmonN/{name,temp1_input,temp1_label}`，
其中 `name=cpu_thermal` / `soc_thermal` 会被 htop 采信。

**实装结果（2026-09-12）**：`sudo ./install-tz2hwmon.sh` 装出 6 路通道
（`cpu_thermal(cpub)` / `soc_thermal(cpul)` / `ddr` / `npu` / `gpu` / `skin`，`*_idle_zone` 按默认跳过）；
htop 抓屏显示 **33 °C / 34 °C** —— 温度显示可用。

## 七、卸载 / 回退

```bash
sudo ./install-tz2hwmon.sh --uninstall
# 或手动: sudo rmmod tz2hwmon; sudo rm -f /etc/modules-load.d/tz2hwmon.conf /lib/modules/$(uname -r)/extra/tz2hwmon.ko; sudo depmod -a
```
模块只注册 hwmon 设备，卸载后 `thermal_zone` 与内核温控完全不受影响（无残留状态）。

## 八、可选参数

```bash
sudo modprobe tz2hwmon include_aliases=1   # 连 *_idle_zone 同源别名一起暴露（默认关闭）
```

## 九、文件与变更记录

| 文件 | 说明 |
|---|---|
| `tz2hwmon.c` | 模块源码（v2，GPL-2.0） |
| `Makefile` | `make -C /lib/modules/$(uname -r)/build M=$PWD modules` |
| `install-tz2hwmon.sh` | B 类安装脚本 `[0/5]`前置检查 → `[1/5]`编译(校验 vermagic) → `[2/5]`装 `/lib/modules/$(uname -r)/extra` + `modules-load.d` → `[3/5]`加载 → `[4/5]`校验通道与 htop 可见性 → `[5/5]`使用提示；另有 `--status`/`--uninstall`/`--prebuilt`/`--no-autoload` |
| `tz2hwmon-v1-to-v2.patch` | v1→v2 源码差异存档（审阅/回放用） |
| `tz2hwmon.ko` | 编译产物（**可选保留**；换内核后须重编，vermagic 与运行内核一致才可用） |

- **v1**（2026-09-03）：统一命名 `tz2hwmonN`，8 路全暴露（含同源别名）→ 仅 `sensors/btop` 可用，htop 看不到。
- **v2**（2026-09-12）：htop 白名单命名（`cpu_thermal`/`soc_thermal`）+ `temp1_label` + 默认跳过 `*_idle_zone` + `include_aliases` 参数。
- 风险等级：**低**（只读、无 governor 回调、可 `rmmod` 完全回退）。新系统装完需重跑本脚本（B 组组件不在镜像内）。

## 附：如需重建温度工具（当时构建后按要求删除的临时脚本）

直读 `/sys/class/thermal/thermal_zone*`，按 大核/小核/GPU/NPU/DDR/外壳 分组，彩色条形图，
`--watch` 刷新、`--json` 输出、`--all` 含别名、`--fan` 显示 PWM 占空比；
默认**排除** `*_idle_zone` 别名（与主 zone 同源，避免重复计数）。
