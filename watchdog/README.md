# watchdog —— 启用 systemd 硬件看门狗

板上有一个硬件看门狗设备 `/dev/watchdog0`（`sunxi-wdt` 驱动），默认**没有任何服务喂它**，
所以系统卡死后只能人工断电。

`install-watchdog.sh` 让 **systemd** 接管：systemd 周期性喂狗，一旦 systemd 自己或整个系统卡死超过超时时间，
硬件看门狗直接把机器复位。

## 功能

- 在 `/etc/systemd/system.conf` 中写入 `RuntimeWatchdogSec=16`，再执行 `systemctl daemon-reexec` 使配置生效。
- 超时固定为 **16 秒**（`sunxi-wdt` 的硬件上限），systemd 每 8 秒喂一次。
- 子命令：`on`（启用）、`off`（关闭）、`status`（查看，不带参数时的默认动作）。

## 前置条件

- 硬件 / 系统：Radxa Cubie A7S（全志 A733）+ Armbian（systemd 系统），root 权限。
- 看门狗设备存在：`ls -l /dev/watchdog0`。
- ⚠️ **超时不要设成大于 16 秒的值**：`sunxi-wdt` 的硬件上限就是 16 秒。
  若按常见做法写 60，systemd 会报
  `Failed to set watchdog hardware timeout to 1min: Invalid argument` 并**放弃使用看门狗** ——
  看起来"配好了"，实际完全没有生效。本脚本固定使用 16。

## 安装（启用）

```bash
sudo ./install-watchdog.sh on
```

脚本 3 步：

```
[1/3] 写 /etc/systemd/system.conf（RuntimeWatchdogSec=16）
[2/3] systemctl daemon-reexec 让 systemd 重新读取配置
[3/3] 校验（打印 status）
```

> 脚本只替换文件里已有的 `RuntimeWatchdogSec=` / `#RuntimeWatchdogSec=` 行。
> 如果你的 `system.conf` 里两者都不存在，请手动在 `[Manager]` 段内加一行 `RuntimeWatchdogSec=16`，
> 再执行 `sudo systemctl daemon-reexec`。

配置写在 `/etc/systemd/system.conf` 里，**重启后依然有效**。

## 验证

```bash
sudo ./install-watchdog.sh status
dmesg | grep -i "Watchdog running"   # 期望：Watchdog running with a hardware timeout of 16s
wdctl /dev/watchdog0                 # 期望：Device or resource busy
```

- `status` 的结论显示 **"✅ 已启用（16 s 硬件超时，systemd 每 8 s 喂一次）"** 即为生效。
- `wdctl` 报 `Device or resource busy`，表示设备**已被 systemd 持有**（正在喂狗）；
  反过来，`wdctl` 能正常读出信息说明当前**没有**进程持有看门狗，也就是没在喂狗。
- **`/sys/class/watchdog/watchdog0/state`、`timeout` 读出来是空的，并不代表没生效**：
  该内核没有打开可选的 `CONFIG_WATCHDOG_SYSFS`，请以上面两条判据为准，不要以这两个文件为空判断失败。
- `wdctl` 由 `util-linux` 提供，Debian / Armbian 默认已安装。

## 注意事项（重要）

- **系统挂死会由硬件看门狗复位**：本板内核的策略是"一次内核错误即 panic 且不自动重启"，
  叠加看门狗之后，卡死 / panic 的机器会在超时（16 秒）内自动硬复位，而不是永久卡在那里等人来断电。
- 复位等于硬重启：**未写入磁盘的数据会丢失**。复位后可用 `journalctl -b -1` 查看上一次启动的内核消息，定位卡死原因。
- 正常关机 / 重启不会触发看门狗复位；如果关机过程本身卡死，则会被看门狗复位（属预期行为）。
- 需要 systemd 正常在跑才有喂狗；systemd 被停掉或本身卡住时，机器会按超时复位。

## 卸载 / 回滚

```bash
sudo ./install-watchdog.sh off
```

脚本把该行注释掉（改为 `#RuntimeWatchdogSec=off`）并再次 `daemon-reexec`。
之后 systemd 不再喂狗，看门狗由内核在超时后关闭，机器回到"卡死不会自动复位"的默认行为。

手动等价的恢复：

```bash
sudo sed -i 's/^RuntimeWatchdogSec=.*/#RuntimeWatchdogSec=off/' /etc/systemd/system.conf
sudo systemctl daemon-reexec
sudo ./install-watchdog.sh status     # 复查，结论应变为"未启用"
```

- 停用必须改配置：`systemctl daemon-reexec` 本身不会关掉看门狗，只有把 `RuntimeWatchdogSec` 设为 `off`
  （或注释掉）之后再执行一次 `daemon-reexec`，systemd 才会停止喂狗。
- 若只想换一个更短的超时（1–16 秒之间），把 `RuntimeWatchdogSec` 改成目标值再 `daemon-reexec` 即可。
