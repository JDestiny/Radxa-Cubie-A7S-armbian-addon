# tz2hwmon —— 把 thermal_zone 桥接成 hwmon（让 htop / btop / sensors 显示温度）

`tz2hwmon` 是一个**只读**内核模块。全志 BSP 把 SoC 温度只注册在 `/sys/class/thermal/thermal_zone*`，
而 `libsensors` 系的工具（`sensors` / `btop` / `htop`）只认 `/sys/class/hwmon/*`，中间是断的。
本模块把每个 thermal zone 转发成一个 hwmon 温度通道。

**它不注册温控回调、不修改 trip 点、不参与降频决策**：纯展示，卸载后无任何残留。

## 功能

- 把 thermal zone 的温度（毫摄氏度）逐路转发为 hwmon 的 `temp1_input`，并附带 `temp1_label`。
- 芯片名按 `htop` 3.x 的白名单命名，使 htop 的温度表头能显示 CPU 温度：

| thermal zone（`type`） | hwmon 芯片名 | `temp1_label` | htop 可见 |
|---|---|---|---|
| `cpub_thermal_zone` | `cpu_thermal` | `cpub` | ✅ |
| `cpul_thermal_zone` | `soc_thermal` | `cpul` | ✅ |
| `ddr_thermal_zone` | `ddr_thermal` | `ddr` | sensors / btop |
| `npu_thermal_zone` | `npu_thermal` | `npu` | sensors / btop |
| `gpu_thermal_zone` | `gpu_thermal` | `gpu` | sensors / btop |
| `skin_zone` | `skin_thermal` | `skin` | sensors / btop |
| `cpub_idle_zone` / `cpul_idle_zone` | 默认跳过 | — | 可用 `include_aliases=1` 保留 |

- 表中未列出的其它 zone 会以 `tz2hwmon_<label>` 命名，`sensors` / `btop` 照常可读。
- 可选参数 `include_aliases=1`：把 `*_idle_zone` 这类同源别名也单独暴露（默认关闭，避免重复计数）。

> 芯片名和标签只是**显示用的名字**，不代表可靠的物理位置；`cpub` / `cpul` 与大小核的对应关系随内核、
> 设备树版本而异。另外 `*_idle_zone`、`skin` 等通道并不是独立传感器，读数可能与其他通道重复或经过折算。

## 前置条件

- 硬件 / 系统：Radxa Cubie A7S（全志 A733）+ Armbian。
- 权限：安装与卸载需要 root；`--status` 是只读查看，普通用户也能运行。
- 安装方式**二选一**：
  - **预编译**：仓库内已有 `tz2hwmon.ko`，是针对内核 `6.6.98-vendor-sun60iw2` 编译的。
    脚本会用 `modinfo` 校验 `vermagic`，与当前 `uname -r` 不一致时会直接报错中止。
  - **源码编译**：需要与当前内核匹配的头文件（即 `/lib/modules/$(uname -r)/build` 存在），
    并且**本目录下要有 kbuild 用的 `Makefile`**（仓库未附带，内容只有一行，见下）。
- ⚠️ **换内核 / 重刷系统后必须重新安装或重新编译**：内核模块与内核版本强绑定（vermagic），
  新内核下旧的 `.ko` 不会被加载，htop 的温度表头会重新变回空白。
  用安装脚本装的不带 DKMS 自动重建，换内核后请重跑一次安装（或改用方式 C 的 DKMS）。

## 安装

### 方式 A：使用预编译模块（内核版本与预编译一致时最省事）

```bash
cd radxa-cubie-a7s-armbian-addon/tz2hwmon
sudo ./install-tz2hwmon.sh --prebuilt
```

### 方式 B：从源码编译

```bash
cd radxa-cubie-a7s-armbian-addon/tz2hwmon

# 1) 装与当前内核匹配的头文件
sudo apt install linux-headers-$(uname -r)
# 若源里没有这个包名，先 apt search linux-headers 找到与当前内核分支对应的头文件包

# 2) 补一个 kbuild 用的 Makefile（kbuild 构建外部模块必需）
cat > Makefile <<'EOF'
obj-m := tz2hwmon.o
EOF

# 3) 编译 → 安装 → 写开机自启 → 加载 → 校验，一步完成
sudo ./install-tz2hwmon.sh
```

只想手动编译、不装的话：

```bash
make -C /lib/modules/$(uname -r)/build M=$PWD modules
sudo ./install-tz2hwmon.sh --prebuilt   # 会用刚编出来的 ko 走安装流程（仍会校验 vermagic）
```

脚本共 5 步，任一步失败都会明确报错并中止：

```
[0/5] 前置检查（内核、头文件、thermal_zone 数量）
[1/5] 编译并校验 vermagic
[2/5] 安装到 /lib/modules/$(uname -r)/extra/ ，写 /etc/modules-load.d/tz2hwmon.conf
[3/5] modprobe tz2hwmon
[4/5] 校验 hwmon 通道与 htop 可见性
[5/5] 使用提示
```

| 选项 | 说明 |
|---|---|
| `--prebuilt` | 跳过编译，直接使用仓库内的 `tz2hwmon.ko`（仍校验 vermagic） |
| `--no-autoload` | 安装但不写 `/etc/modules-load.d/tz2hwmon.conf`（不随开机加载） |
| `--status` | 只读查看：模块状态、hwmon 通道读数、thermal_zone 原始读数 |
| `--uninstall` | 卸载：`rmmod` + 删除模块文件与自启配置 + `depmod` |
| `-h` / `--help` | 用法 |

### 方式 C：DKMS（换内核后自动重建，可选）

```bash
sudo apt install dkms linux-headers-$(uname -r)

sudo mkdir -p /usr/src/tz2hwmon-2.0
sudo cp tz2hwmon.c Makefile /usr/src/tz2hwmon-2.0/     # Makefile 见"方式 B"第 2 步
sudo tee /usr/src/tz2hwmon-2.0/dkms.conf >/dev/null <<'EOF'
PACKAGE_NAME="tz2hwmon"
PACKAGE_VERSION="2.0"
BUILT_MODULE_NAME[0]="tz2hwmon"
AUTOINSTALL="yes"
EOF

sudo dkms add     -m tz2hwmon -v 2.0
sudo dkms build   -m tz2hwmon -v 2.0
sudo dkms install -m tz2hwmon -v 2.0

# 开机自动加载（DKMS 只负责编译/安装模块，不会替你写自启配置）
echo tz2hwmon | sudo tee /etc/modules-load.d/tz2hwmon.conf
sudo modprobe tz2hwmon
```

> 不要两种方式同时用：`extra/` 与 DKMS 的 `updates/dkms/` 会各留一份同名模块，容易混淆。

### 可选参数（`include_aliases`）

```bash
# 本次加载有效
sudo rmmod tz2hwmon && sudo modprobe tz2hwmon include_aliases=1

# 永久生效（安装脚本不会创建这个文件）
echo 'options tz2hwmon include_aliases=1' | sudo tee /etc/modprobe.d/tz2hwmon.conf
```

## 验证

```bash
sudo ./install-tz2hwmon.sh --status      # 通道清单 + 是否命中 htop 白名单
ls /sys/class/hwmon/hwmon*/name          # 应出现 cpu_thermal / soc_thermal / ddr_thermal ...
cat /sys/class/hwmon/hwmon*/temp1_input  # 毫摄氏度，例如 34162 = 34.162 ℃
dmesg | grep tz2hwmon                    # 加载时一行 "N channels registered, M alias(es) skipped"
```

- `--status` 输出中带 **"← htop 可见"** 标记的通道，表示芯片名命中了 htop 白名单；若一个都没有，
  htop 的温度表头仍会是空白。
- `htop`：F2 → Display options → 勾选 "Also show CPU temperature"
  （等价于在 `~/.config/htop/htoprc` 里设 `show_cpu_temperature=1`）。
- `sensors`（可选）：`sudo apt install lm-sensors` 后直接运行 `sensors`；`btop` 同理，读的就是这些 hwmon 通道。

## 卸载 / 回滚

```bash
sudo ./install-tz2hwmon.sh --uninstall
```

等价的手动步骤：

```bash
sudo rmmod tz2hwmon
sudo rm -f /etc/modules-load.d/tz2hwmon.conf /lib/modules/$(uname -r)/extra/tz2hwmon.ko
sudo depmod -a
```

- 模块只注册 hwmon 设备，**卸载后 `thermal_zone`、温控策略与 trip 点完全不受影响**，也没有残留状态。
- 用 DKMS 安装的：`sudo dkms remove -m tz2hwmon -v 2.0 --all`。
- 写过 `/etc/modprobe.d/tz2hwmon.conf` 的，一并删除。
- 只想临时停用而不卸载：`sudo rmmod tz2hwmon`（下次开机仍会自动加载）；
  删掉 `/etc/modules-load.d/tz2hwmon.conf` 后重启，即不再自动加载。

## 文件

| 文件 | 说明 |
|---|---|
| `install-tz2hwmon.sh` | 安装 / 卸载 / 状态脚本（编译、安装、自启、校验一体） |
| `tz2hwmon.c` | 模块源码（GPL-2.0，版本 2.0） |
| `tz2hwmon.ko` | 预编译模块，对应内核 `6.6.98-vendor-sun60iw2` |
