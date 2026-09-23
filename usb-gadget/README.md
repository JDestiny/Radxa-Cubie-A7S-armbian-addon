# usb-gadget —— 把 USB-C OTG 口变成 USB 串口设备

板子的 OTG 口默认当 host 用（能插 U 盘、键鼠）。内核只提供"可以当 USB device"这个能力，
具体变成串口、网卡还是 U 盘，要由用户态写 `configfs` 决定。

`usb-gadget-serial.sh` 用 `configfs` 在 OTG 口上配一个 **ACM（CDC serial）** gadget：
把板子插到 PC 上，PC 侧会出现一个串口（Linux 下是 `/dev/ttyACM0`，Windows 下是一个 COM 口），
用来登录板子或传数据，不需要网线。

> 为什么只做串口：把系统盘当 U 盘暴露给 PC 有被误格式化、误写引导区的风险，本脚本不提供 U 盘 / 网卡形态。

## 功能

- `on`：建 gadget 骨架 → 建 ACM 功能与配置 → 绑定 UDC → 打印状态。
- `off`：解绑 UDC → 删除 gadget 目录，OTG 口回到 host 模式。
- `status`：查看 gadget 目录、绑定的 UDC、UDC 状态、`/dev/ttyGS*`（不带参数时的默认动作）。

两个重要性质：

- **只影响 OTG 口**：启用后它进入 device 模式，不能再插 U 盘 / 键鼠；接在其它控制器上的 USB 口不受影响。
- **脚本不写任何开机配置**：配置只存在于运行期（`configfs`），**重启后自动恢复 host 模式**。

## 前置条件

- 硬件 / 系统：Radxa Cubie A7S（全志 A733）+ Armbian，root 权限。
- 一根 USB-C **数据线**（只能充电的线不行），用于连接 PC。
- 内核支持 USB gadget 与 configfs：`/sys/kernel/config/usb_gadget` 目录存在。
  不存在时先加载 composite 模块：

  ```bash
  sudo modprobe libcomposite
  ```

  如果连 `/sys/kernel/config` 都不存在，先挂载 configfs：`sudo mount -t configfs none /sys/kernel/config`。
  建 ACM 功能时需要内核的 `usb_f_acm`（`modinfo usb_f_acm` 可确认）；
  `on` 报 `[FAIL] configfs 未挂载` 或 `[FAIL] 无法进入 ...` 时，先查上面这两项。

- UDC（USB Device Controller）已注册，脚本默认使用 `4100000.udc-controller`：

  ```bash
  ls /sys/class/udc/
  ```

  列表为空说明当前内核没有把 OTG 控制器配成 device 模式，本脚本无法工作；
  名字与 `4100000.udc-controller` 不同时，需要改脚本里的 `UDC_NAME`。

## 安装（启用）

```bash
sudo ./usb-gadget-serial.sh on
```

脚本依次执行 4 步：

```
[1/4] 建 gadget 骨架（VID:PID = 1d6b:0104，字符串 Radxa / Cubie A7S）
[2/4] 建 acm.usb0 功能，挂到配置 c.1
[3/4] 绑定 UDC（4100000.udc-controller）
[4/4] 校验（打印 status）
```

执行完把 USB-C 线插到 PC 上即可。

## 验证

板子侧：

```bash
sudo ./usb-gadget-serial.sh status                  # 结论应为"已启用"
ls /dev/ttyGS*                                      # 应为 /dev/ttyGS0
cat /sys/class/udc/4100000.udc-controller/state     # 已连到 PC 时期望 configured
```

PC 侧（Linux）：

```bash
dmesg | tail                                        # 期望出现 cdc_acm ... ttyACM0: USB ACM device
ls /dev/ttyACM0
lsusb | grep 1d6b:0104                              # 确认看到的是这块板子
```

PC 侧（Windows）：设备管理器中出现一个新的 COM 端口（USB 串行设备）。

## 使用（可选）

```bash
# PC 侧打开串口终端（USB CDC 下波特率没有实际限制，习惯用 115200）
sudo picocom -b 115200 /dev/ttyACM0     # 或 screen /dev/ttyACM0 115200、minicom

# 板子侧：想从串口登录，需要在板子上开一个 getty（仅本次生效，重启后需重新开）
sudo systemctl start serial-getty@ttyGS0.service
```

串口本身不承载网络；传文件可用串口工具自带的传输功能（如 `picocom` 里配合 `sz` / `rz`），
或登录之后照常使用系统自带的工具。

## 卸载 / 回滚 / 恢复默认

```bash
sudo ./usb-gadget-serial.sh off
```

- `off` 会解绑 UDC 并删除 gadget 目录，**OTG 口立即回到 host 模式**，可以重新插 U 盘 / 键鼠。
- 拔线之前建议先执行 `off`。
- 什么都不做直接重启也可以：该配置在 `configfs` 里，**重启即消失，OTG 口默认就是 host 模式**。
- 想让开机自动进入 device 模式，需要自己写一个 systemd 服务在启动时调用本脚本的 `on`（本脚本不做这件事）。
