# htop 的 GPU 数据：原理、驱动变体方案、5 s 门控实测（B1 专题）

> 本文原为 `htop磁盘IO与温度-结论.md` 的 GPU 部分（排查 2026-09-11 · 方案 2026-09-12 · 门控实测 2026-09-13），
> 2026-09-13 按类拆分并入 B 类文档。
>
> 相关文档：`GPU记账补丁-稳定性分析.md`（补丁 v1→v4 演进与 2h 长测结论）· `install-gpu-driver-stock.sh` / `install-gpu-driver-gpuacct.sh`（两版驱动各自独立的安装/切换/自检）·
> `../README.md`（B 组安装 + 快速判成功）· 温度部分见 `../tz2hwmon/README.md` · 磁盘 I/O 部分见 `../../A-编译期修复/README.md`（A13 专题）。

## 一、htop 的 GPU 支持到底要什么（源码事实）

- htop 只认两种数据源：AMD 的 `/sys/class/drm/card*/device/gpu_busy_percent`，或**进程 DRM fdinfo** 里的
  `drm-engine-<名>: <N> ns`（且同一 fdinfo 里必须先出现 `drm-client-id:` 与 `drm-driver:`）。
- 本板原版 `pvrsrvkm` 的 `pvr_show_fdinfo()` **只输出内存类键**（`drm-memory-*`），驱动内部也没有逐进程 GPU 时间
  → htop 的 GPU 表头与进程 GPU%/GPU TIME 列**原版永远是空的**。
- 内核 6.6 的 `kernel_read()` 读 PVR 的旧式 debugfs 文件返回 `-EINVAL`（该文件没有 `read_iter`），
  且本内核未开 `KPROBES`/`FTRACE` → 不要指望在内核里"转一手"。
- 但**驱动自己的 debugfs 是有利用率的**：`/sys/kernel/debug/pvr/status` 给出
  `GPU Utilisation: 110%` 与 `2D/GEOM/3D/CDM/RAY/GEOM2` 分块百分比（`/sys/kernel/debug/pvr/{status,driver_stats,version}` 均在）
  → htop 用不上，但自建工具/压测模块可以用它记录真实利用率。

## 二、方案演进：B8 桥接模块 → B1 驱动变体（B8 已删除）

1. **先做了桥接模块 B8 `pvr2fdinfo`**（用户态喂数器 + 字符设备 fdinfo 注入）：实测可用但结构复杂
   —— 需要 root 喂数、需要包装器持有 fd、多写者/假设备节点等一堆工程坑。**2026-09-12 按要求删除**
   （`/usr/local/bin/pvr-util-*`、`/etc/modules-load.d/pvr2fdinfo.conf`、模块与设备节点全部清理）。
2. **最终改为驱动原生实现（B1 变体 `gpuacct`）**：`img-bxm-dkms-src-gpuacct/` = 原始驱动 + `pvr-gpuacct.patch`：
   - 用 `SORgxGpuUtilStatsRegister()` 注册**独立利用率用户**，取"自上次调用以来"的 GPU 忙时（µs → ns）；
   - 在 4 个提交入口（KickTA3D / KickCDM / SubmitTransfer×2）插一行 `PVRGpuAcctKick()`，
     按 kick 次数把忙时分摊到各进程（单客户端 = 100% 归属）；
   - fdinfo 里直接输出 `drm-client-id` / `drm-driver: pvr` / `drm-engine-pvr: <ns> ns`。
   **不再需要包装器、喂数器、桥接设备或 root 介入**；htop（含普通用户）直接读。

补丁版本演进（细节与失败分析见 `GPU记账补丁-稳定性分析.md` 第五~十一节）：

| 版本 | 采样策略 | 长测结果 |
|---|---|---|
| v1 | 固定 250 ms | ❌ 约 4.5 分钟后打挂驱动统计 |
| v2 | 1 s + 按需 + 退避 ≤8 s | ⚠️ 可用但 util 零值 10.4%，出现约 4 分钟冻结窗口 |
| v3 | 首次取零即退避、上限 32 s | ❌ **更糟**：零值 91.9%，第 6 分钟起冻结 1h54m |
| **v4** | **固定 1 s** + 空闲自停 + 冻结自愈（连续 5 次"有 kick 却为 0"→ 重置自己的 util-user） | ✅ 2h 长测：150/150 阶段、dmesg 0、**fdinfo 记账无冻结** |
| **v5** | v4 + **日志语义拆分**：`recovered` 只在 `kicks>0` 时打印（带 busy 值），空闲清零降为 `pr_debug` | ✅ 行为实测通过（空闲不再刷日志）；记账逻辑未变 |
| **v6**（当前，2026-09-15 装 + 重启验证） | v5 + **热路径无锁化**（kick 快路径 RCU + atomic64，不取锁）+ **记账条目回收**（进程消失即回收，PID 复用不再继承旧值）+ **fdinfo 去重**（不再重复打 client-id/driver，engine 行移到内核输出之后） | ✅ fdinfo 每字段仅一份且顺序满足 htop 契约（按其状态机复算）；240 次短命客户端爆发后条目被回收、重复爆发平台期不增长 |

## 三、当前形态：B1 变体 `gpuacct`（v4）

- 数据源 = 驱动自己的利用率 API（"该用户自上次调用以来的忙时"）→ 不再有窗口平均的积分误差；
- 归属 = 按 kick 次数分摊（单客户端精确）→ 不再有 first_only / 包装器 / 喂数器；
- 任何用户（含 radxa）跑自己的 GPU 程序，**自己的 htop** 就能看到 GPU%（root 进程仍需 `sudo htop`）；
- **2026-09-13 起按 DKMS 持久化安装**（`img-bxm-dkms/0.1.0-3+gpuacct` + 开机 `/etc/modules-load.d/pvr.conf` 加载
  + 换内核自动重建）→ **重启后 htop 的 GPU 数据仍在**；切换 = 重跑 `install-gpu-driver-stock.sh`（或 `-v6.sh`）
  （实测 `gpuacct → stock → gpuacct` 三轮全 `[OK]`）。

实测（2026-09-12 首次）：驱动加载成功 · GPU 574 fps · fdinfo 原生给出 `drm-engine-pvr`（2.98s → 6.30s 增长）；
htop 抓屏 `pvr: 142.5%(186ms)` / `145.1%(191ms)`（引擎名 `pvr` + 百分比 + 时间）。

## 四、为什么 htop 的 GPU% 会 >100%

htop 的百分比是**分子分母口径不一致**造成的（与驱动无关，驱动输出的 ns 是单调递增的真值）：

```
GPU% = 100 × Δ(该进程 drm-engine 时间) / 1e6 / Δ(全局上一帧)
        └── 分子窗口最长 = 门控 + 刷新周期 ──┘   └── 分母只有 1 个刷新周期 ──┘
```

- 门控只挡**空闲**进程：一旦某进程上次读到 GPU 时间 > 0，`gpu_activityMs` 被清 0 → **每帧都重读**；
- 于是"空闲 → 变活跃"的那一帧，分子可能累积了（门控 + 刷新）那么久，分母却只有一帧；
- 实测（真实负载 + 按 htop 公式复算）：真实 **99.1%** 会被显示成 **199%**（1.5 s 刷新）/ **598%**（0.5 s 刷新）；
- htop 内部对 delta 有 `saturatingSub` 保护，但**不做 100% 钳位**。

## 五、5 s 扫描门控：实测与 1 s 推算（2026-09-13）

### 结论先说

**保持现状**：把门控从 5 s 改成 1 s，要多付约 **4 倍扫描开销**（+2.1 个百分点单大核），
换来的只是把虚高从最坏 **4.3×** 压到 **1.7×**（本机 delay=15 时）——**仍然是错的**。
真要治 >100%，应该改**分母**（用每进程自己上次被读的时间戳）+ 结果钳位，**一次重编译、零额外开销**；方案见本节末，**本次不做**。

### 源码事实（为什么会有 5 s 这个数）

`linux/GPU.c:89`（htop 3.4.1；**3.5.0 与 main 分支同样未改**，只是搬到了 `linux/Platform.c`）：

```c
/* check only if active in last check or last scan was more than 5s ago */
if (lp->gpu_activityMs != 0 && host->monotonicMs - lp->gpu_activityMs < 5000) {
   lp->gpu_percent = 0.0F;    /* 空闲进程：不重读，% 直接归零 */
   return;
}
lp->gpu_activityMs = host->monotonicMs;
...
if (new_gpu_time > 0)
   lp->gpu_activityMs = 0;    /* 活跃进程：清零 → 下一帧必读 */
```

三条关键语义：

1. **门控只挡空闲进程**：活跃 GPU 进程本来就每帧重读，所以降低门控**不会**让它们更准。
2. 扫描是**全量**的：`openat(procFd,"fdinfo")` + 逐个 `readdir`/`xReadfileat`，读**每个进程的所有 fdinfo**
   （不预筛 DRM fd），与该进程有没有 GPU 无关。
3. 百分比分母是**全局上一帧**（`host->prevMonotonicMs`），不是本进程上次被读的时刻 —— **这才是 >100% 的根因**。

### 实测一：单次全量扫描的本机成本

环境：Cubie A7S（2×A76 cpu6-7 2.0 GHz + 6×A55 cpu0-5 1.79 GHz，共 8 核）· 206 进程 · **3228 个 fdinfo 文件**（其中仅 9 个含 `drm-engine-`）。

| 口径 | 方法 | 单次全量扫描 |
|---|---|---|
| 独立基准 | `gcc -O2` 手写扫描器（openat+read 每个 fdinfo），`taskset` 绑 A76 | **31.9 ms** |
| 真 htop 内省 | `LD_PRELOAD` 探针统计真 htop 每趟的 open/read 次数与耗时 | 内核态 **33.4 ms/趟** |
| A/B 反推（见实测二） | 扫描净开销 ÷ 每分趟数 | 总计 **≈42 ms/趟**（含 htop 用户态解析） |

三法互相吻合 → 取 **≈40 ms/趟（单大核）** 作为推算基准（保守用 42 ms）。

### 实测二：5 s 门控现在到底花多少（A/B 对照）

对照手法：探针加"快速失败"模式（fdinfo 目录 `openat` 直接返回 -1 → htop 立刻 `goto out`），
等于**保留 htop 全部代码路径但不做扫描**；两组都 `taskset -c 6`，各跑 2 次 60 s：

| 运行（60 s 窗口） | user | sys | 合计（单 A76 核） |
|---|---|---|---|
| 真扫描（5 s 门控）#1 / #2 | 0.33 / 0.42 % | 2.55 / 2.73 % | **2.88 / 3.15 %** |
| 不扫描（快速失败）#1 / #2 | 0.28 / 0.62 % | 1.52 / 1.73 % | **1.80 / 2.35 %** |

- **扫描本身 ≈ 0.94 个百分点单大核**（探针量到的纯系统调用为 0.78 %，两法吻合）；
- 即 htop 自身 CPU 里约 **1/3** 花在 fdinfo 扫描上；
- 实测趟数 **13.3~14 趟/分**：5 s 门控 + 1 s 刷新本应 12 趟/分，多出的来自 9 个**活跃** GPU 进程被每帧重读。

### 推算：改成 1 s 门控要多少

扫描频率（全量趟数/分）＝ 60 ⁄ max(门控, 刷新周期)，活跃进程再叠加每帧重读：

| 配置 | 全量扫描频率 | 扫描 CPU（单 A76 核） | htop 合计（含自身底噪） |
|---|---|---|---|
| 现状：门控 5 s + delay=15（1.5 s） | 每 6 s 一趟 ≈ **10 趟/分** | ≈ 0.42 s/分 = **0.70 %** | ≈ **2.1 %**（底噪 ~1.4 %） |
| 改为：门控 1 s + delay=15 | 每帧一趟 ≈ **40 趟/分** | ≈ 1.68 s/分 = **2.80 %** | ≈ **4.2 %** |
| （参考）门控 1 s + delay=10（1 s） | 60 趟/分 | 2.52 s/分 = 4.2 % | ≈ 6.3 % |

> 底噪按 A/B 实测的"不扫描"组（delay=10 时 2.08 %）按刷新率折算到 delay=15（×2/3）得到；扫描列与底噪列相互独立，可直接相加。

**代价（按本机实际 delay=15 口径）**：

- CPU：**+2.1 个百分点单 A76 核** ≈ 每小时多 ~76 秒 CPU、每秒多 2.1 ms；
- 系统调用：每小时多扫 **1800 趟**、多打开约 **580 万个** fdinfo 文件（1.9 M/h → 7.7 M/h）；
- 折算全机 8 核：**+0.26 %** 总算力（绝对值可忽略，但单核观感是 htop 自身占用近乎翻倍）；
- 若 htop 落到 A55 小核，上述绝对值**再乘约 2**（未绑核的对照运行里，同负载出现过 2.88 % 与 5.23 % 的差异，探针 t_sum 也差 2.2 倍）。

**收益**：只有一条 —— 虚高上限从 `1 + 门控/刷新` 降下来：

| 门控 | delay=15（1.5 s） | delay=10（1 s） | delay=5（0.5 s） |
|---|---|---|---|
| 5 s（现状） | 最坏 4.3×（实测 2.0×） | 最坏 6×（实测 ~2×） | 最坏 11×（实测 6.0×） |
| 1 s | 最坏 1.7× | 最坏 2× | 最坏 3× |

即：**1 s 门控不是修复，只是把误差压小**；对"正在跑 GPU"的进程精度毫无改善。

### 正确的修法（留档，本次不实施）

两处改动即可根治，且**不增加任何扫描开销**：

1. 分母改成**该进程自己上次被读的时刻**：在 `LinuxProcess` 增加 `uint64_t gpu_lastReadMs;`
   （与 `gpu_activityMs` 同一处赋值），`gpu_percent = 100 × gputimeDelta / 1e6 / (now - lp->gpu_lastReadMs)`；
2. 结果钳位（`MIN(100.0, ...)`／`saturatingSub`），避免驱动/时钟回绕导致的尖峰。

这样即使保持 5 s 门控，首次读到活跃进程时用的就是 6 s 分子 ÷ 6 s 分母 = 真值。

### 复测方法（探针为临时件，位于 /tmp，重启即失）

```bash
# 1) 探针：LD_PRELOAD 包装 openat/read，识别 basename=="fdinfo" 的目录与
#    其下数字名文件（dirfd 反查 /proc/self/fd/N 确认父目录），累计次数与耗时；
#    FDPROBE_FAIL=1 时对 fdinfo 目录直接返回 -1（对照组）。
gcc -O2 -shared -fPIC -o /tmp/libfdprobe6.so /tmp/fdprobe6.c -ldl
# 2) A/B：绑定大核、每组 60 s，比较 /proc/<htop_pid>/stat 的 utime+stime
sudo env HOME=/tmp/c-gpu FDPROBE_OUT=/tmp/ab-real.txt LD_PRELOAD=/tmp/libfdprobe6.so \
  script -qec "taskset -c 6 sh -c 'echo \$\$ >/tmp/pid; exec htop -d 10'" /dev/null
sudo env HOME=/tmp/c-gpu FDPROBE_FAIL=1 ...   # 同上，即"不扫描"对照
```

本次为**只读测量**：htop 未重编译、门控未改、用户 htoprc 未改、驱动与系统配置均未动。
⚠️ 一处过程副作用：前两次测量用 `pkill -x htop` 收尾，会**连带结束当时开着的其它 htop 实例**（之后改为只结束探针自己启动的 PID）。

## 六、htop 侧配置与 TOOL 取数口径

用户自己的 `~/.config/htop/htoprc`（radxa 家目录，**本会话曾误改一次，已从备份逐字节还原并核对一致**）：

```
show_cpu_temperature=1
delay=15                                        # 1.5 s 刷新
column_meters_0=LeftCPUs Memory Swap DiskIO NetworkIO
column_meters_1=RightCPUs GPU Tasks LoadAverage Uptime
fields=0 48 17 18 38 39 40 2 46 47 49 131 132 1
       # 131=M_PRIV  132=GPU_TIME(总 GPU 时间)  133=GPU_PERCENT(未启用)
```

要点：**GPU 表头在 `column_meters_1`**（不在 `_0`）；进程列表里放的是 **GPU_TIME(132)** 而不是 GPU%(133)；
`delay=15`（1.5 s）决定了 5 s 门控下实际是**每 ~6 s 跳一次**（见第五节）。

**TOOL 压测体系的取数口径**（`TOOL/modules/lib.sh` 的 `gpu_util_start()`/`gpu_util_stop()`）：
每秒采一次 GPU 利用率，**首选按进程 fdinfo 的 `drm-engine-pvr` 斜率折算**（`Δns/1e7` = %/s，驱动变体提供；
与 htop 同源但用真实时间差，不受门控/分母问题影响），**回退**读驱动 debugfs `/sys/kernel/debug/pvr/status`
的 `GPU Utilisation`（stock 驱动也能用），把 `util_avg`/`util_peak` 记入报告：

```
gpu  GLES_fps    572.2 fps    pass
gpu  OpenCL_GFLOPS 0.8 GFLOPS pass
gpu  Vulkan_MPix 113.1 MPix/s pass
gpu  util_avg    89.5 %       pass      ← 驱动真实利用率
gpu  util_peak   100 %        pass
```

> 注：2026-09-13 的 2h 长测发现**驱动 debugfs 的利用率读数会进入 ~52 分钟零值窗口**，
> 而 **fdinfo 记账不受影响** → 优先 fdinfo 的口径正好规避了这个坑（详见 `GPU记账补丁-稳定性分析.md` 第十节）。
