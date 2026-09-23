# dsufreq —— DSU / L3 集群调频的受控启用流程

DSU（DynamIQ Shared Unit）是 CPU 集群级共享单元，它的频率与 CPU 频率是分开的。
内核驱动 `sunxi-dsufreq` 负责这部分调频，并在加载后提供 `/sys/class/dsufreq/` 接口。

`dsufreq-test.sh` 把这个驱动的启用过程拆成**显式、可分步、可回滚**的动作。
它**不安装任何东西、不写 `/boot`、不改内核配置、不自动重启**；只处理 `modprobe` 黑名单、手动加载、判据与自动加载的恢复。

## 功能

| 子命令 | 作用 |
|---|---|
| `sudo ./dsufreq-test.sh status` | 只读：内核配置、模块文件、黑名单、加载状态、`/sys/class/dsufreq` 接口、`dmesg` 相关行 |
| `sudo ./dsufreq-test.sh blacklist` | 写 `/etc/modprobe.d/blacklist-sunxi-dsufreq.conf`，并卸载已加载的模块 |
| `sudo ./dsufreq-test.sh test` | 受控加载一次模块并判定结果（**这一步可能让机器 panic / 死机**） |
| `sudo ./dsufreq-test.sh promote` | 加载成功后删除黑名单，恢复"开机自动加载" |
| `sudo ./dsufreq-test.sh unload` | 卸载已加载的模块 |

## ⚠️ 为什么必须先黑名单、再手动加载（顺序不能颠倒）

1. `sunxi-dsufreq` 驱动里有一条 `BUG_ON`，**probe 阶段可能直接触发内核 panic**。
   触发条件是「DSU 的最低 OPP 电压高于 CPU 的最低 OPP 电压」，这两个电压取自 nvmem 中选中的 VF 变体，
   **读设备树判断不出来** —— 也就是说，加载之前无法预知会不会命中。
2. 该模块带有 `of:` 设备别名（`MODULE_DEVICE_TABLE`），**udev 会在开机时按平台设备自动加载它**。
   不先写黑名单，它就一直留在开机启动路径上，"手动加载一次看看"也不再是一次受控操作。
3. 因此正确顺序是 **`blacklist` → `test` → `promote`**：
   - 先黑名单：让 probe 只可能由你手动触发；
   - 再 `test`：受控加载一次并按判据判定；
   - 最后 `promote`：确认没问题后，才撤销黑名单、恢复自动加载。
   - 颠倒顺序（例如不写黑名单就直接 `modprobe`）意味着 probe 落在不受控的时机：一旦命中触发条件，
     机器会立刻挂掉，而且重启后还会再次自动加载、再次挂掉。

> 本仓库适用的内核已把 `CONFIG_AW_SUNXI_DSUFREQ` 由内建（`=y`）改为模块（`=m`）：
> 没人 `modprobe`，就没人 probe，开机启动路径上不再有这个 probe。
> `CONFIG_AW_SUNXI_DSUFREQ_ADJUST` 与 `CONFIG_AW_SUNXI_DSUFREQ_TEST` 建议保持关闭。

## 前置条件

- root 权限（`status` 只读，普通用户也能运行，其中 `dmesg` 部分需要 root）。
- 当前内核提供该模块：`modinfo sunxi-dsufreq` 能查到（查不到说明这个内核没有该驱动，也就无需做这套流程）。
- `/boot/config-$(uname -r)` 可读（`status` 用它显示 `CONFIG_AW_SUNXI_DSUFREQ` 的取值）。
- **确认你能物理断电 / 重新上电**：`test` 命中触发条件时机器会立刻停机。
  建议接好调试串口——panic 时调用栈会打印在串口上，便于确认原因。
- 不要在无人值守的远程机器上执行 `test`。

## 安装（= 启用）

### 1. 先看当前状态

```bash
sudo ./dsufreq-test.sh status
```

重点看这几项：`CONFIG_AW_SUNXI_DSUFREQ` 是否 `=m`、`modinfo` 是否找得到模块、黑名单是否存在、模块当前是否已加载。

### 2. 写黑名单（挡住 udev 自动加载）

```bash
sudo ./dsufreq-test.sh blacklist
```

脚本会写入 `/etc/modprobe.d/blacklist-sunxi-dsufreq.conf`（内容一行 `blacklist sunxi-dsufreq`），
并卸载当前已加载的模块。之后**重启也不会自动加载**。

### 3. 受控加载一次

```bash
sudo ./dsufreq-test.sh test
```

脚本会先做前置检查（黑名单在、模块未加载、模块文件存在），打印风险提示并**等待你输入 `y` 确认**，
然后执行一次 `modprobe sunxi-dsufreq`，等待 2 秒后逐条打印判据。

**这一步有让机器立刻 panic / 死机的风险**，确认前请确保能物理断电、并且黑名单已经写好（上一步）。

### 4. 成功后恢复自动加载

```bash
sudo ./dsufreq-test.sh promote
```

删除黑名单。模块仍为 `=m` 时，udev 会在开机时按平台设备自动加载它（等于恢复默认行为）。
另一种选择是在内核配置里把 `CONFIG_AW_SUNXI_DSUFREQ` 改回内建（`=y`）并重新构建内核，随内核启动即生效。

## 验证

```bash
# 1) 模块是否加载（lsmod 里名字显示为下划线）
lsmod | grep -E 'sunxi[_-]dsufreq'

# 2) 调频接口是否出现，读数是否可读
ls /sys/class/dsufreq/
cat /sys/class/dsufreq/scaling_cur_freq
cat /sys/class/dsufreq/scaling_available_frequencies

# 3) 是否命中触发条件 / 是否有内核报错
dmesg | grep -aiE 'dsu|BUG|Call trace'
```

`test` 的成功判据（脚本会逐条打印）：

- `lsmod` 里出现 `sunxi_dsufreq`；
- `/sys/class/dsufreq/` 出现，且 `scaling_cur_freq` 可读；
- `dmesg` 中没有 `dsu min volt is err`，也没有 `BUG` / `Call trace`。

**如果刚才机器 panic 或重启了**：

- 系统盘内容不会因此损坏，**断电重新上电即可恢复**；
- 黑名单仍然保留，所以重启后系统照常启动，**不要再次手动加载**；
- 重新上电后跑一次 `sudo ./dsufreq-test.sh status`，应看到：黑名单在、模块未加载；
  若 `dmesg` 里有 `dsu min volt is err`，说明命中的正是那个触发条件，此机器不要加载该模块。

## 卸载 / 回滚

```bash
# 立刻卸下模块并恢复黑名单（回到"不会自动加载"的状态，最安全的回滚）
sudo ./dsufreq-test.sh blacklist

# 只卸载模块，其他不动
sudo ./dsufreq-test.sh unload

# 恢复默认行为（允许开机自动加载）
sudo ./dsufreq-test.sh promote
```

- `blacklist` 是幂等的：文件存在时覆盖写入，并尝试卸载模块（被占用时会报 `[FAIL]`）。
- 手动等价的回滚：
  - 禁止自动加载：`echo 'blacklist sunxi-dsufreq' | sudo tee /etc/modprobe.d/blacklist-sunxi-dsufreq.conf`
  - 恢复自动加载：`sudo rm -f /etc/modprobe.d/blacklist-sunxi-dsufreq.conf`
- 脚本不改内核配置、`/boot` 或任何启动文件，所以"回滚"只需处理黑名单与模块的加载状态。
