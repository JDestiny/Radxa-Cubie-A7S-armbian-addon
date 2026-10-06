# GPU 驱动「利用率记账补丁」稳定性分析（B1 变体 gpuacct）

> 对象：`img-bxm-dkms-src-gpuacct/`（= Radxa r6 原始 pvrsrvkm + `pvr-gpuacct.patch`，**v6：5 文件 / +391 行**）
> 目的：驱动原生在 DRM fdinfo 输出 `drm-engine-pvr: <累计ns> ns`，让 htop 的 GPU 表头与
> 进程 `GPU%` / `GPU TIME` 列直接可用（取代原 B8 桥接模块，B8 已删除）。
> 分析日期：2026-09-12 · **R1–R6 风险复核：2026-09-13（v4 2h 长测完成后）** · 长测工具：`gpu-driver-stability.sh`

## 一、补丁到底改了什么（风险面清单）

| # | 改动 | 位置 | 规模 |
|---|---|---|---|
| 1 | 新增一个周期 `delayed_work`（调 `pfnGetGpuUtilStats()` 取该用户自上次调用以来的忙时）。**v4 = 固定 1 s** + 空闲自停 + 冻结自愈；v1 曾用 250 ms（会把统计打挂，见 §五） | `devices/rogue/rgxinit.c` | +~210 行 |
| 2 | 新增一个全局 mutex + 一个"pid→累计忙时"链表 | 同上 | — |
| 3 | 4 个 GPU 提交入口各插一行 `PVRGpuAcctKick()` | `rogue/rgxta3d.c`、`rgxcompute.c`、`rogx/rgxtransfer.c`(×2) | 4 行 |
| 4 | fdinfo 多输出 3 行（`drm-client-id` / `drm-driver` / `drm-engine-pvr`） | `env/linux/pvr_drm.c` | +10 行 |
| 5 | 设备 init/unload 各挂一个 `PVRGpuAcctInit/Deinit` | 同上 | 2 行 |

**未触碰**：固件通信、命令提交内容、调度、内存/电源管理、DVFS、上下文与 MMU 管理 —— 这是风险可控的关键。

## 二、逐项风险与缓解

### R1 周期任务与固件共享内存竞争（**中**）
- **机制**：`pfnGetGpuUtilStats()` 会 `RGXFwSharedMemCacheOpPtr(...)` 失效固件共享内存缓存，并取
  `psDevInfo->hGpuUtilStatsLock`；内部还有"多次尝试取可靠数据"的重试循环。
- **风险**：与驱动自带的利用率读者（DVFS `pvr_dvfs_device.c`、debugfs `status`、健康检查）串行/争抢；
  固件繁忙或异常时该调用可能变慢 → `system_wq` 的工作项偶尔拉长。
- **缓解/现状**：工作项在**结尾重新排队**，天然不可重入（不会堆积）；采样频率仅 4Hz；取不到数据只计数跳过。
- **可观测**：驱动 debugfs 计数器与 dmesg（长测每 15s 采样）；补丁本身不额外暴露接口。

### R2 提交热路径加锁（**中**）
- **机制**：每次 kick 取一次全局 mutex；遇到新 pid 时 `kzalloc(GFP_ATOMIC)`。
- **风险**：GLES/Vulkan 高频提交下引入串行化；理论上增加帧时间抖动。
- **为什么不会死锁**：该锁**只在记账内部使用**，持锁期间不回调驱动、不分配可睡眠内存、不做 IO →
  不存在与其他驱动锁的循环等待。
- **实测**：长测中 GLES 帧率 531–574 fps（stock 约 555–575 fps）→ 未见可测退化；
  若要进一步降低开销，可改为 per-CPU 计数或原子计数（**待优化项，非必须**）。

### R3 生命周期 / 卸载竞态（**中**）
- **机制**：`pvr_gpuacct_stop()` 由 `pvr_drm_unload()` 调用。
- **已做的正确性保证**：先 `cancel_delayed_work_sync()`（确保工作项不再运行/不再排队）→
  再 `SORgxGpuUtilStatsUnregister()` → 最后清空链表并置 `g_devnode=NULL`。
- **残留风险**：若驱动**强制卸载**（`rmmod -f`）或 probe 失败回滚路径绕过 `pvr_drm_unload()`，
  工作项可能仍引用已释放的 device node。正常卸载路径已覆盖（长测结束会做一次
  `modprobe -r` + `modprobe` 循环验证）。
- **suspend/resume**：本板 suspend 本来就不可用（pvrsrvkm resume 空指针）；
  补丁**未**挂 suspend 钩子 → 若将来要启用 suspend，需在 suspend 前 `cancel_delayed_work_sync`
  （**已知待办**，不影响当前使用）。

### R4 记账条目无回收（**低**，长期运行才有感）
- 每有一个"提交过 GPU 工作的 pid"就在链表留一条（≈40 B），**直到模块卸载才释放**；
  PID 复用会复用旧累计值（**数据略错，不影响稳定性**）。
- 影响面：长时间运行 + 大量短命 GPU 进程（如 CI）→ 数万条 = 数 MB 内核内存。
- **待优化**：空闲超时回收，或改成"哈希表 + LRU"。

### R5 fdinfo 与工具兼容性（**低**）
- 我们在 `pvr_show_fdinfo()` 里**自己打印了一份 `drm-client-id`**，而内核的 `dr_show_fdinfo()` 随后
  也会打印一份 → **同一 fdinfo 出现两个 client-id**。
  - htop：兼容（顺序解析、后者覆盖前者；engine 行在前者之后仍被采纳）—— 已抓包实测 ✓
  - 其他按 DRM usage-stats 规范实现的工具（nvtop 等）：可能出现重复/歧义解析。
  - **待优化**：把 engine 行移到内核 `drm_show_fdinfo()` 之后，或复用内核真实 client id。
- **归属语义**：按"本周期 kick 次数"分摊（启发式），非硬件逐进程统计；单客户端准确、多客户端为近似。

### R6 构建/安装层（**低**）
- 变体切换用不同 DKMS 版本号（`0.1.0-3` / `0.1.0-3+gpuacct`），安装器会**先移除另一变体**再装，
  避免同名模块重复构建；`dkms status` 可直接看出当前是哪一个。
- 手工 `dkms` 操作（不经安装器）可能同时装上两个变体 → 同名模块冲突，文档已注明用安装器。
- 模块体积：带调试符号 24 MB（stock 2.2 MB 为 strip 过）；DKMS 安装默认 strip，不影响运行。

### R1–R6 现状复核（2026-09-13，v4 2h 长测后）

| 风险 | 原评级 | 现状 | 结论 | 证据/去处 |
|---|---|---|---|---|
| **R1** 周期任务与固件共享内存竞争 | 中 | **已定位、已收敛，但残留一项**：v1(250ms) 4.5 min 打挂统计、v3(退避到 32s) 第 6 分钟起冻结 1h54m → **v4 固定 1 s + 冻结自愈** 后，2h 长测**按进程的 fdinfo 记账全程无冻结**（每阶段净增 17–36 s）；残留：驱动自身 **debugfs 利用率读数出现 ~52 分钟零值窗口**（第 11 轮末~第 24 轮）——**2026-09-14 stock 2h 对照实验证明这与本补丁无关**（stock 上同样出现，起始时间几乎相同，见 §十二），不影响 htop/TOOL 取数 | ✅ **已解决**（补丁自身无残留；零值窗口归因驱动/FW） | §五~§七（v2/v3 失败）、§九（v4 设计）、§十（2h 结果）、§十一（DKMS 持久化） |
| **R2** 提交热路径加锁 | 中 | **v6 已彻底改掉**：kick 快路径 = `rcu_read_lock` + `list_for_each_entry_rcu` + `atomic64_inc`，**不取任何锁**；只有"新 pid"才走慢路径（spinlock + `kzalloc(GFP_ATOMIC)` + 双重检查）；"采样是否在跑"也改成 atomic。v5 前实测 GLES 556–573 fps（stock 555–575），无退化 | ✅ **已解决**（v6） | §十三 |
| **R3** 生命周期 / 卸载竞态 | 中 | 正常卸载路径已多次验证：3 轮变体切换（`gpuacct→stock→gpuacct`）+ 长测后重载，均 `modprobe -r`/`modprobe` 干净通过，无 oops/use-after-free；**v4 新增的自愈路径（运行时 unregister+register）实际触发 4 次也全部安全**（全天 `dmesg: stalled - util user state reset` ×4：长测前 2 次、长测中 2 次，每次之后按进程记账继续增长） | ✅ **正常路径已解决**；`rmmod -f`/probe 回滚、suspend 钩子仍为待办 | §二 R3、§十一 |
| **R4** 记账条目无回收 | 低 | **v6 已加回收**：tick 里回收"进程已消失"的条目（RCU 判活 → `list_del_rcu` + `kfree_rcu`），并设 4096 条上限兜底（超限淘汰最久未活动的一条）→ PID 复用不再继承旧值；实测 240 次短命 GPU 客户端爆发后条目被回收，重复爆发平台期不增长（见 §十三） | ✅ **已解决**（v6） | §十三 |
| **R5** fdinfo 与工具兼容性 | 低 | **v6 已去重**：不再自己打 `drm-client-id`/`drm-driver`，engine 行移到内核 `drm_show_fdinfo()` **之后** → 一份 fdinfo 里每个字段只出现一次，且 client-id 仍排在 engine 之前（**htop 契约不变**，已按 htop 的状态机复算验证）；归属语义仍为"按 kick 次数分摊"的启发式（单客户端准确、多客户端近似） | ✅ **已解决**（v6） | §十三 |
| **R6** 构建 / 安装层 | 低 | **已解决且超出原计划**：两变体**互斥**（安装器 `dkms remove --all`，内核升级时不会双份竞争）、源树绝对软链自愈（DKMS 树自包含）、`--status` 直接显示"重启后会加载谁"、失败自动重建 stock 兜底；实测三轮切换全 `[OK]`，运行中模块 build-id 与磁盘 ko 完全一致；DKMS 安装体积 2,236,896 B（strip 后，与 stock 2,231,304 B 相当；早先 24 MB 是仓库内未 strip 的手工构建产物） | ✅ **已解决** | §十一 |

> 小结：**6 项里 3 项已解决（R2 实测缓解、R3 正常路径、R6），2 项收敛为"待办但不影响当前使用"（R4、R5），
> 1 项（R1）从"未知风险"变成"已定位的固件侧利用率统计缺陷"** —— 补丁自身的记账不再冻结，残留的是驱动 debugfs 读数窗口。
> 收尾三件事的进展（2026-09-13 晚）：
> - ① ✅ **stock 驱动 2h 对照实验已完成**（2026-09-14 00:55→02:55，日志 `/var/log/gpu-driver-stability-20260914-005502`）→ **结论：零值窗口与补丁无关**（stock 同样出现），见 §十二；
> - ② ✅ **监测脚本已改**：`acct_value()` → `acct_sample()`，锁定同一个客户端 PID 跟踪，换客户端时写 `-` 作基线重置标记，
>   复核 awk 同步改为"遇 `-` 重置基线"（消除 19 次表观回退）；
> - ③ ✅ **补丁 v5 已装**（`util stats recovered` 拆成 "kicks>0 恢复" 与 "空闲→pr_debug"）；
> - ④ ✅ **补丁 v6（2026-09-14/15）把 R2/R4/R5 三个"不影响使用"的待办也一并做掉**：热路径无锁化、条目回收、fdinfo 去重 → 详见 §十三；
> - ⑤ ✅ **重启验证完毕**（2026-09-14 23:56 真实重启）：开机自动加载 gpuacct，运行中模块 build-id 与磁盘 ko 一致 → DKMS 持久化确实成立。

## 三、验证手段（本次 2h 动态负载长测）

`gpu-driver-stability.sh` 每轮（≈6.3 分钟；**2026-09-15 扩充相位**）依次施加
**GLES 渲染 60s → OpenCL 计算 60s → Vulkan compute 60s → 混合(GLES+NPU+CPU×4) 45s →
多客户端(GLES×4 并发) 45s → 跨引擎(GLES+Vulkan 并发) 60s → 短命客户端 churn 30s → 空闲 15s**，
并在每 15s 记录（新增三个相位专门压 v6 的三项修复：多客户端归属、跨引擎竞争、条目回收/PID 复用）：

| 指标 | 判据 |
|---|---|
| dmesg 内核错误（PVR_K error/fail/timeout、Oops、BUG、panic、GPU fault） | 必须 **0 新增** |
| 驱动 debugfs 计数器：Server Errors / HWR / CRR / SLR / FWF / APM | 必须**不增长** |
| 温度（cpub/cpul/gpu/npu/ddr/skin） | 记录峰值，不应接近 trip 点 |
| 记账单调性（fdinfo `drm-engine-pvr` 逐次采样） | 必须**单调不减**（回退 = 记账异常） |
| 各阶段成功率（fps/吞吐 + 无 FAIL 标记） | 全部成功 |
| 模块常驻（`lsmod` 大小不异常） | 不消失、不膨胀 |

日志：`/var/log/gpu-driver-stability-<时间戳>/{summary.txt,metrics.tsv,phases.log,phase-*.out}`

## 四、结论与回滚

- **回滚成本极低**：`sudo ./install-gpu-driver-stock.sh`（或直接 `sudo modprobe -r pvrsrvkm &&
  sudo modprobe pvrsrvkm`，若 stock 仍在 DKMS 中）；源码/补丁都留在仓库里可随时重装。
- 风险等级评定：**中低**。周期任务与热路径加锁是主要两点，已用"不可重入 + 4Hz + 独立锁"控制；
  2h 动态负载长测作为验收依据（结果见运行结束后的 `summary.txt`）。
- 已知待办（不影响当前使用，2026-09-13 复核状态）：suspend 前 cancel（未做）、记账条目回收（未做，影响极小）、
  fdinfo client-id 去重（未做，htop 兼容）、热路径计数改为无锁（未做，实测无退化）、
  **debugfs 利用率零值窗口的定性对照实验（新增，见 §二 现状复核 R1）**。

## 五、2h 长测暴露的真实缺陷与根因（2026-09-12 23:00 发现）

**现象**：长测中（补丁驱动）GPU 以 500+ fps 渲染时，驱动 debugfs 的 `GPU Utilisation` 与
我们 fdinfo 里的 `drm-engine-pvr` **同时冻结在 0**；GPU 仍正常渲染、dmesg 无错误，
重载驱动后立刻恢复 → 是**可恢复的统计路径卡死**，不是崩溃。

**隔离实验（都在 stock 驱动上做，排除补丁自身）**：

| 实验 | 条件 | 结果 |
|---|---|---|
| A | 5.5 min 负载，每 **30s** 读一次 `pvr/status` | ✅ 74–77% 全程正常 |
| B | 5.5 min 负载，**4Hz** 读 `pvr/status` | ❌ 约 **4.5 min** 后 util 卡在 **0%**（负载仍在跑） |
| C | 反复 `kill -9` GPU 进程（无高频读取） | ✅ 无影响（28–58% 正常） |

**结论**：触发条件是**高频读取驱动利用率**（4Hz），与"负载时长"无关、与"杀进程"无关。
驱动的利用率统计路径在**被读取频率超过其固件更新节奏**时会进入卡死状态（此后无论读多少次都返回 0，
直到驱动重载）。

**对补丁的影响**：补丁的 `delayed_work` 每 **250ms** 无条件调用 `pfnGetGpuUtilStats()` ——
正是实验 B 的压力模式（且空闲时也在调）。所以：
- **不是稳定性问题**（不崩、不影响渲染/DVFS 在本板的可用性——本板未注册 GPU devfreq）；
- **是功能可靠性问题**：连续跑几分钟后记账会冻结在 0（htop 显示 0%）。

**修复方向（待验证）**：
1. 把 tick 间隔从 250ms 放宽到 **≥1s**（实验 D：1Hz 是否安全，进行中）；
2. 仅在"有进程在提交 GPU 工作"时采样（空闲不读），减少读取次数；
3. 检测到连续 N 次返回 0 而同期有 kick 时，**退避**（如降到 5s 一次）并记录日志；
4. 更彻底：不复用自己的 user handle 调 API，而是复用驱动已缓存的 `sGpuUtilStats`
   （调试用输出同源），从根上避免额外读取压力。

## 六、v1→v2 修复（2026-09-12 23:30，已实现并编译验证）

根据第五章的根因，补丁改为 **v2**（`pvr-gpuacct.patch`；v1 存档为 `pvr-gpuacct-v1-250ms.patch`）：

| 项 | v1 | v2 |
|---|---|---|
| 采样间隔 | 250ms（4Hz，实测 ~4.5 min 打挂统计） | **1000ms**（实测 11 min 负载稳定 74–82%） |
| 采样时机 | 模块加载后**无条件**常驻采样 | **按需**：只在有 GPU 提交（kick）时采样；连续 5 次无提交 → 停止采样循环，下次 kick 再拉起 |
| 异常处理 | 无 | **退避**：有提交却连续取到 0（统计被打死的早期征兆）→ 间隔指数退避到 8s 上限 |

实测证据（均在 stock 驱动上做，排除补丁自身影响）：

| 实验 | 条件 | 结果 |
|---|---|---|
| A | 5.5 min 负载，30s/次 读取 | ✅ 74–77% 全程 |
| B | 5.5 min 负载，**4Hz** 读取 | ❌ ~4.5 min 后卡在 0%（负载仍在跑），需重载驱动才恢复 |
| C | 反复 kill -9 GPU 进程 | ✅ 无影响 |
| D | 11 min 负载，**1Hz** 读取 | ✅ 74–82% 全程 |

结论：**4Hz 是危险区，1Hz 安全**；v2 采用 1Hz + 按需 + 退避三重措施。
（v2 已用同一套 2h 动态负载长测再做一次验收，日志 `/var/log/gpu-driver-stability-<时间戳>/`。）

**仍未解决/待办**：若将来发现 1Hz 在超长（>10h）运行下也会退化，退避机制会把频率继续压低并保持可用；
彻底方案是复用驱动已缓存的 `sGpuUtilStats`（不额外调用 API）。

## 七、2h 动态负载长测结果（2026-09-13 01:35 完成，v2 驱动）

日志：`/var/log/gpu-driver-stability-20260912-233518/`（30 轮 / 150 个阶段 / 7214s）

| 指标 | 结果 | 判定 |
|---|---|---|
| 阶段成功率 | **150 / 150**（GLES 20s·OpenCL·Vulkan·混合·空闲 循环 30 轮） | ✅ |
| 内核错误 (dmesg) | 基线 0 → 结束 **0 新增**（无 PVR error/fail/timeout、无 Oops/BUG/panic） | ✅ |
| 驱动计数器 | Server Errors / HWR / CRR / SLR / FWF **全程 0**（仅 APM 事件 1→140，属正常电源管理） | ✅ |
| 温度峰值 | cpub 40.9 / cpul 43.5 / gpu 38.8 / npu 38.4 / ddr 39.6 / skin 32.7 °C | ✅ 远低于 trip 点 |
| 记账单调性 | 阶段内比较 322 次，**真实回退 0 次** | ✅ |
| GLES 帧率 | 全程 530–575 fps（与 stock 一致，无退化） | ✅ |

**唯一的异常窗口**：23:51–23:58（第 5–6 轮，约 4 分钟）出现 `util` 与 `acct` 同时为 0 —— 即
v1 那种"利用率统计被打死"的征兆在 v2 下**仍会偶发**，但 v2 的**退避 + 空闲自停**让它
**自行恢复**（v1 时会永久卡死，必须重载驱动）。之后第 7–30 轮全部正常：
后 11 轮平均 util **82.7%**（173 次采样），gles 阶段 util=0 仅 12/113 次（含每轮起始的爬坡样本）。

**结论**：驱动层面**稳定**（2h 无错误、无崩溃、温度与帧率正常）；
利用率记账**可用但有偶发冻结**（约 2 小时一次、持续数分钟、可自恢复）。

**v3 待改进（不改也能用）**：
1. 首次检测到"有 kick 却取 0"就退避（当前连续 5 次才退避），并把上限提到 16–32s；
2. 每次冻结**打一条限速警告**（本轮长测就是因为补丁不打日志、只能靠外部采样才发现）；
3. 彻底方案：不自己调 `pfnGetGpuUtilStats`，改为复用驱动缓存的 `sGpuUtilStats`。

## 八、v3 改进（2026-09-13，已编译并加载验证）

针对第七章"约 2 小时一次、持续数分钟的冻结"，v3 做三处改动（`pvr-gpuacct.patch`；v2 存档 `pvr-gpuacct-v2-1s-ondemand.patch`）：

| 项 | v2 | v3 |
|---|---|---|
| 退避触发 | 连续 **5** 次取零才开始退避（约 5s 才反应） | **首次**取零立即退避 |
| 退避上限 | 8s | **32s**（1s→2s→4s→8s→16s→32s） |
| 可观测性 | 无任何日志（长测只能靠外部采样发现冻结） | **`pr_warn` 状态转换告警**：首次冻结打 `util stats stalled … backing off`，恢复时打 `util stats recovered`；加载时打一行 `started (tick 1000ms, on-demand, backoff to 32s)` |
| 为什么用 pr_warn | — | 实测 `PVR_DPF(PVR_DBG_WARNING)` 在本 release 构建里**不输出**（v1/v2 的启动信息就是因此没进 dmesg） |

加载后实测（2026-09-13 10:47）：
```
dmesg: [464543.419857] pvr_gpuacct: started (tick 1000ms, on-demand, backoff to 32s)
radxa 身份跑 GPU: fdinfo 2.30s → 6.10s 增长 · 驱动 util 74% · 0 像素异常
```
> 冻结告警/恢复告警要等真实发生冻结时才会出现（下一次长测可验证）。

**使用建议**：v3 在遇到冻结时会更快降频自保 → 记账最多丢几分钟的数据然后恢复；
若需要"绝对连续"的数据，唯一彻底方案仍是复用驱动缓存的 `sGpuUtilStats`（见第七章待办 3）。

## 九、v3 长测失败 → v4（2026-09-13 15:20）

### v3 的 2h 长测结果：**未通过**

日志 `/var/log/gpu-driver-stability-20260913-120459/`（30 轮 / 150 阶段）——⚠️ 该轮目录已清理，数据以本节表格为准

| 项 | 结果 |
|---|---|
| 阶段成功率 | 150/150 ✅（渲染本身没问题） |
| dmesg 错误 | 0 新增 ✅ |
| 记账单调性 | 0 回退 ✅（但"持平 290 次 vs 增长 28 次"= 大部分时间**冻结**） |
| **util 健康度** | **零值 432/470 = 91.9%；gles 阶段 109/120 为 0** ❌ |

**时间线**：第 1–2 轮完全健康（util 74–99%、记账 12s→48s 增长）→ **12:11（第 6 分钟）起彻底冻结，
之后 1h54m 再没恢复**（v3 日志里只有一次 "recovered"）。

### 根因（对照实验）

| 实验（stock 驱动） | 结果 |
|---|---|
| 1s 读取 90s | ✅ 75–79% |
| 改 30s 读取 150s | ✅ 依然 75–76%（**稀疏读取本身不会锁死**） |
| v3 长测（我们自己的 util-user + 退避到 32s） | ❌ 第 6 分钟起永久冻结 |

结论：**问题出在"我们自己注册的 util-user 状态"上** —— `pfnGetGpuUtilStats()` 是按用户维护
"自上次调用以来"的增量状态的，它必须跟上固件计数器的**环形缓冲**：稳定 ~1s 轮询能跟上，
一旦被拉长到 32s，每次解析都失败并且**无法自行恢复**（新数据覆盖了旧数据）。debugfs 那条路之所以
没受影响，是因为驱动自己的 DVFS/健康检查用户仍以较高频率在轮询。

**v3 的"激进退避"方向是错的**：越退避越死。

### v4 设计（已实现并编译/加载验证）

| 项 | v4 |
|---|---|
| 采样节奏 | **固定 1s**（不做退避；空闲无 kick 时仍然自停，完全不读） |
| 冻结自愈 | 连续 5 次"有 kick 却为 0" → **unregister + register 我们自己的 util-user**，让驱动侧累计状态从头开始（而不是放宽间隔） |
| 可观测性 | 保留 `pr_warn`：`started (tick 1000ms steady, on-demand, self-heal on stall)` / `util stats stalled - util user state reset` / `util stats recovered` |

补丁归档：`pvr-gpuacct.patch`(**v5**) · `pvr-gpuacct-v4-1s-selfheal.patch` · `v3-backoff-32s` · `v2-1s-ondemand` · `v1-250ms`。
验证：30 分钟动态负载（v3 是在第 6 分钟死的）→ 通过后再跑 2h。

### v5：日志语义拆分（2026-09-13 晚，源码已改、待重编安装）

**动机**：v4 的 `util stats recovered` 在两种情况都会打印 —— 真恢复（有 kick 且取到忙时）与 **GPU 空闲**（本轮无 kick，
只是把零值计数清零）。实测 2h 跑出 72~80 条 recovered，其中绝大多数是空闲噪声，容易被误读成"利用率恢复了"。

**改动**（`rgxinit.c`，只在日志分支，不碰记账逻辑）：

```c
} else if (g_pvr_gpuacct_zeros) {
    if (kicks) {                 /* 有活儿且取到忙时 → 真恢复 */
        IMG_CHAR szMsg[96];
        OSSNPrintf(szMsg, sizeof(szMsg),
                   "util stats recovered (kicks>0, busy=%llu ns)",
                   (unsigned long long)ui64BusyNs);
        PVRGpuAcctWarn(szMsg);   /* 注: PVRGpuAcctWarn() 只收一个字符串, 非 printf 风格 */
    } else {                     /* 只是空闲 → 降为 debug, 默认不打印 */
        pr_debug("pvr_gpuacct: zero-streak cleared while idle (no kicks)\n");
    }
    g_pvr_gpuacct_zeros = 0;
}
```

**状态**：✅ **已安装并实测（2026-09-14 02:59）**。
- 补丁验证：stock 树副本上 `git apply --check` ✅、应用后 5 文件与工作树逐字节一致 ✅；
- 首轮编译失败（我把 `PVRGpuAcctWarn()` 当成 printf 风格用了）→ 安装器**自动回滚 stock** 成功，改成 `OSSNPrintf` 到缓冲区后重编通过
  （这次也顺带真实验证了 R6 的失败回滚路径）；
- 安装后校验：DKMS `0.1.0-3+gpuacct`、运行中 build-id 与磁盘 ko 一致（`f1429f5c…`）、
  dmesg `started (tick 1000ms steady, on-demand, self-heal on stall)`；
- 行为实测：dmesg 出现新格式 `util stats recovered (kicks>0, busy=752537000 ns)` ✅；
  空闲路径编译为 `pr_debug`（本内核未开 DYNAMIC_DEBUG → 不产生任何日志）→ **空闲噪声消失** ✅。

> 注：htop 侧即使记账完全正确也会显示 **>100%** —— 那是 htop 自己的口径问题
> （分子窗口 = 门控 + 刷新周期，分母只有一帧），**不是驱动的问题**；实测数据、代价推算与"为什么不改 htop"
> 见 `htop-GPU显示-原理与门控.md` 第四节。驱动侧 `drm-engine-pvr` 输出的是单调递增的真实 ns。

---

## 十、v4 的 2h 动态负载长测结果（2026-09-13 19:01 完成）

日志：`/var/log/gpu-driver-stability-20260913-170142/`（30 轮 / 150 阶段 / 7214 s，负载用户 radxa）

| 项 | 结果 |
|---|---|
| 阶段成功率 | **150 / 150 ✅**（GLES 60s → OpenCL 60s → Vulkan 60s → 混合 45s → 空闲 15s × 30 轮） |
| 内核错误 | **新增 0 ✅**（Server/HWR/CRR/SLR/FWF 计数器全程 0） |
| 温度峰值 | cpub 43.4 / cpul 46.3 / gpu 42.1 / npu 40.7 / ddr 41.5 / skin 33.1 °C ✅ |
| 渲染性能 | 冻结窗口内外一致：GLES 556–573 fps、Vulkan 97–101 MPix/s ✅ |
| **按进程记账（fdinfo `drm-engine-pvr`）** | **全程无冻结 ✅**（每阶段净增 17–36 s；20 次表观回退经复核为口径假象/客户端重启，见下）—— 这是 htop 真正读的数据 |
| 驱动 debugfs `GPU Utilisation` | ❌ **第 11 轮末~第 24 轮（约 52 分钟）读数几乎恒为 0%**（其中第 13–23 轮 11 轮全零），其余时间 58–99% |
| 记账"回退"告警 | 20 次 → 逐条复核：**19 次是监测口径造成的表观回退**（阶段切换时读到的进程换人：vk 阶段 16 次 + 第 1 轮客户端重启 3 次），**1 次是真异常尖峰**（第 11 轮，见发现 4） |

### 逐轮利用率时间线（debugfs 口径，30 轮共 470 个采样）

```
轮 1–10   ✅ 健康      gles 57–93% / ocl 94–99% / vk 97–99% / mixed 80–93%
轮 11–12  ⚠️ 过渡      17:43 起陆续归零（11 轮 9/15 采样为 0，12 轮 13/14 为 0）
轮 13–23  ❌ 全零      11 轮全部阶段 util=0
轮 24     ⚠️ 恢复中    8/14 采样为 0
轮 25–30  ✅ 健康      gles 59–74% / ocl 93–97% / vk 98% / mixed 79–83%
```

**关键：这 52 分钟里，我们的 fdinfo 记账一直正常增长**（每阶段 17–36 s），
渲染也完全正常 → **用户可见功能（htop GPU TIME、TOOL 的 fdinfo 斜率）不受影响**，
坏掉的只是"驱动自身给 debugfs 的那个利用率读数"。

### 三条发现（附机理）

1. **debugfs 的 `GPU Utilisation` 是"每次读文件时现算"的**（`debug_common.c:660`：
   读取时调用 `pfnGetGpuUtilStats(psDeviceNode, hGpuUtilUserDebugFS, &sGpuUtilStats)`），
   所以 `0%` 的含义是"**固件在这一段窗口里报告的有效时段为 0**"（cumulative>0 才会打印百分比，否则是 `-`）。
   它与我们自己的 util-user 是**两个独立的用户句柄**，理论上互不影响；
   但时间点与本次运行里的两次 `util stats stalled - util user state reset`（17:43:47 / 17:47:47）**高度重合**，
   怀疑与我们 1 s 的高频轮询共享固件利用率时段（环形缓冲）有关。**根因待定论。**
2. **`util stats recovered` 不能当作"利用率恢复"的信号**：该分支在"GPU 空闲（本轮无 kick）+ 之前有零值计数"时也会触发。
   本次 dmesg 里 72 条 recovered，真正对应一次有效恢复的只有极少数。将来若再改，应把它拆成
   "zero-streak cleared (kicks>0)" 与 "idle (kicks=0)" 两种日志。
3. **20 次"阶段内回退"里 19 次是监测假象**：`gpu-driver-stability.sh` 的 `acct_value()` 取
   `pgrep -x gpu_stress|ocl_stress|vk_stress` **命中的第一个进程**的 fdinfo 值；Vulkan 阶段开始时上一个
   OpenCL 客户端尚未退干净，于是"先读到旧客户端的冻结值、下一采样切到新客户端"→ 表观回退
   （vk 阶段 16 次；第 1 轮客户端重启 3 次）。
   （单进程的 `drm-engine-pvr` 由驱动累加，本身不可能回退。）→ **建议：改为固定跟踪一个 PID 或对所有客户端求和。**
4. 唯一一次真异常：第 11 轮 17:44:12 某进程的 fdinfo 值从 **23.5 s 跳到 2418 s**（≈开机以来全部 GPU 忙时），
   下一采样又落到 1060 s、再回到 23.5 s。时间点同样紧邻 17:43:47 的 stall/reset →
   怀疑 stall 期间固件侧累计的忙时在恢复后被**一次性计入**。**待复现/待查**（不影响正常时段数值）。

### 结论

- 对目标"**让 htop / 普通用户看到 GPU 数据**"而言：**v4 达标** —— 2h 内 fdinfo 记账无冻结、无内核错误、性能无退化。
- 但**驱动的 debugfs 利用率读数在长时间负载后会进入 ~50 分钟零值窗口**（v2 10.4% 零值、v3 91.9%、v4 52 分钟窗口），
  所以 **TOOL 把取数口径切成"优先 fdinfo 斜率、debugfs 仅作回退"是对的**，这次长测正好验证了这一点。
- **本轮不做任何改动**（按用户决定）。若将来要收尾，建议按顺序做两件事：
  1. **对照实验**：stock 驱动（无我们的 util-user）同样跑 2h，看 debugfs 是否也归零 →
     区分"固件/负载本身"还是"我们的额外轮询导致"；
  2. 监测脚本 `acct_value()` 改为固定 PID 跟踪（消除 19 次表观回退），并把 `recovered` 日志语义拆开。

---

## 十一、持久化安装与变体切换实测（2026-09-13 19:46–19:50）

**背景**：此前 v4 只是 `insmod` 临时加载（重启即回 stock）。现按需求定型为：
**安装脚本在安装时让用户选变体（stock / gpuacct），装完即持久化；换版本只需重跑脚本选另一个。**

实现要点（`install-gpu-driver-gpuacct.sh`，本轮加固）：

| 环节 | 行为 |
|---|---|
| 持久化 | 源树复制到 `/usr/src/img-bxm-dkms-<ver>` → `dkms install` → `/lib/modules/$(uname -r)/updates/dkms/pvrsrvkm.ko`；开机由 `/etc/modules-load.d/pvr.conf` 按名加载；`AUTOINSTALL=yes` + `/etc/kernel/postinst.d/dkms` → **换内核自动重建** |
| 互斥 | 两个脚本各自会把**另一变体**从 DKMS 树里彻底摘掉（`dkms remove --all`，含所有内核）→ 内核升级时只会重建当前变体，**变体不会漂移** |
| 切换 | 跑另一个专用脚本即可（`install-gpu-driver-stock.sh` ↔ `install-gpu-driver-gpuacct.sh`）：摘旧 → 装新 → `modprobe -r`/`modprobe` → 校验；无需手工清理 |
| 失败兜底 | DKMS 构建失败时**不动正在运行的模块**（系统仍用原驱动），报错退出；重装原版跑 `install-gpu-driver-stock.sh` 即可 |
| 移植性 | 复制后**自愈绝对软链**：gpuacct 源树的生成期目录里原有 143 个指向仓库路径的软链，原样带进 `/usr/src` 会让 DKMS 构建反过来依赖仓库目录（仓库一移动就编不过）→ 已全部改为相对链接，安装器也加了自动修正步骤 |
| 自检 | `[5/5]` 用**补丁特征**判定"运行中 = 磁盘 ko = DKMS = 本次所选"，直接回答"重启后会加载谁"；`--status` 同样显示这三项 |

**三轮实测（本机）**：`--gpuacct` → `--stock` → `--gpuacct`，全部 `[OK]`：

| 验证点 | 结果 |
|---|---|
| 每轮后 `dkms status` | 只剩当前变体（无另一变体残留），`/usr/src`、`/var/lib/dkms` 同样无残留 ✅ |
| 行为级验证 | 切 stock 后 radxa 进程 fdinfo **无** `drm-engine-*`；切回 gpuacct 后 `drm-client-id` / `drm-driver: pvr` / `drm-engine-pvr: <ns> ns` 重新出现 ✅ |
| "运行的就是持久化那份" | 运行中模块 build-id（`/sys/module/pvrsrvkm/notes/.note.gnu.build-id`）= `a15ed216aca9e6f28dc5a25785a80aabf7204eba`，与 `/lib/modules/.../updates/dkms/pvrsrvkm.ko` **完全一致** ✅（排除"还是 insmod 的老模块"） |
| 最终状态 | DKMS `img-bxm-dkms/0.1.0-3+gpuacct` + 已加载 gpuacct + 磁盘 ko gpuacct（2,236,896 B @19:49:58） ✅ |

⇒ 重启或换内核后，htop 的 GPU 表头/进程 GPU% 仍然可用；要回到原版驱动只需
`sudo B-安装后配置/gpu/install-gpu-driver-stock.sh`（同样持久化）。

### 换内核后的行为（DKMS 自动重建）

- `dkms.conf` 为 `AUTOINSTALL=yes`，且 `/etc/kernel/postinst.d/dkms` 钩子在位 →
  **装新内核包时会自动为新内核重建当前变体**，无需人工介入；两变体互斥保证了重建的只会是当前这一个。
- 换内核后自检（任一即可判断变体是否生效）：

```bash
sudo B-安装后配置/gpu/install-gpu-driver-gpuacct.sh --status   # 三行看清: 已加载 / DKMS / 磁盘 ko(=重启后加载谁)
dkms status | grep img-bxm                              # 应显示当前变体 + 新内核版本
modinfo -n pvrsrvkm                                     # 应指向 /lib/modules/<新krel>/updates/dkms/pvrsrvkm.ko
grep -qw PVRGpuAcctKick /proc/kallsyms && echo gpuacct  # 运行中的确实是带补丁的那份
```
- 若刷的是**整机新镜像**（DKMS 树不在镜像里）：重跑 `install-gpu-userspace.sh` 用户态 + 二选一 `install-gpu-driver-stock.sh` / `install-gpu-driver-gpuacct.sh` 即可。
- 万一自动重建没发生（`dkms status` 里没有新内核）：手动 `sudo dkms autoinstall -k $(uname -r)`；
  构建失败看 `/var/lib/dkms/img-bxm-dkms/<版本>/<内核>/<arch>/log/make.log`（常见原因：新内核的
  `linux-headers-<新内核>` 没装，或 `/usr/src/img-bxm-dkms-*` 被清理 —— 后者重跑一次安装脚本即可恢复）。

---

## 十二、stock 驱动 2h 对照实验：debugfs 零值窗口与本补丁**无关**（2026-09-14 02:55 完成）

> 附注（2026-09-15）：驱动安装脚本已按"用户态 / 原版驱动 / V6 驱动"**拆成三个互相独立的脚本**
> （`install-gpu-userspace.sh`、`install-gpu-driver-stock.sh`、`install-gpu-driver-gpuacct.sh`，旧的 `install-gpu.sh` 与
> 变体安装器 `install-gpu-driver.sh` 已删除）。两个驱动脚本各自实测通过：原版 → 三态=stock、fdinfo 无 `drm-engine-*`；
> V6 → 三态=gpuacct、fdinfo 恰好 1 条 `drm-engine-pvr`。详见 `../README.md` §3.2/§3.5。

**问题**：§十 的 v4 2h 长测里，驱动自身 debugfs 的 `GPU Utilisation` 出现约 52 分钟零值窗口。
由于该窗口与我们的 `util stats stalled - util user state reset` 时间点接近，怀疑是**补丁的 1 s 轮询**干扰了
固件侧利用率统计（环形缓冲被快速消费者打断）。

**实验设计**：把驱动切回 **stock**（无补丁、无我们注册的 util 用户、dmesg 里没有任何 `pvr_gpuacct` 消息），
用**同一个脚本**、同样 30 轮/150 阶段/2 h 动态负载跑一遍，其余条件（负载用户 radxa、每 15 s 采样、同机同内核）完全一致。
唯一差异 = 有没有我们这个 1 s 轮询的 util 用户。

| 指标 | **stock 对照**（09-14 00:55→02:55） | **gpuacct v4 基准**（09-13 17:01→19:01） |
|---|---|---|
| 阶段成功 / dmesg 新增错误 | 150/150 · **0** | 150/150 · **0** |
| util=0 采样占比 | **60.0 %**（282/470） | 43.6 %（205/470） |
| gles 阶段 util=0 | 75/120 | 52/118 |
| **首个零值窗口起始（相对开跑）** | **41 分 58 秒** | **41 分 43 秒** |
| 主零值窗口长度 | 47.3 分钟（+ 前段 23.8 分钟，两段仅隔 30 s） | 48.4 分钟 |
| 全零轮 | 第 12–28 轮（16 轮） | 第 13–23 轮（11 轮） |
| 窗口结束 | 零到结束（02:48 之后才有读数） | 02:35 前后自行恢复 |
| 温度峰值 | 42.3/43.6/40.7/38.3/39.1/32.7 °C | 43.4/46.3/42.1/40.7/41.5/33.1 °C |
| dmesg 里 `pvr_gpuacct` 消息 | 0（stock 无补丁） | 少量 started/stalled/recovered |

**结论**：

1. **零值窗口在 stock 上照样出现，而且更严重**（60.0 % vs 43.6 %；主窗口 47.3 vs 48.4 分钟几乎相同；
   **起始时间几乎逐秒重合：开跑后 41 分 58 秒 vs 41 分 43 秒**）。
   ⇒ 这是**驱动/固件自身在持续负载约 42 分钟后利用率统计失效**的行为，**与本补丁、与我们的 1 s 轮询无关**。
2. 由此 **R1 的最后一项残留被排除**：补丁的记账（fdinfo `drm-engine-pvr`）在 2 h 内从未冻结；
   坏掉的只是"驱动 debugfs 那个读数"，而它对 htop / TOOL 都不重要（TOOL 已优先用 fdinfo 斜率）。
3. 两次的细部差异（stock 从头零到尾、gpuacct 在窗口后自行恢复；全零轮 16 vs 11）**不足以断言补丁有正面作用**——
   每组只有 1 次样本，且负载相位、窗口内的温度/频率状态并非逐点对齐。若要追这条，需要多轮重复实验。
4. **对使用者的影响**：无。htop 读 fdinfo、TOOL 读 fdinfo 斜率；只有直接读
   `/sys/kernel/debug/pvr/status` 的人会遇到"跑久了 util 变 0"，属驱动既有行为。

> 附带验证：本次对照也顺手验证了监测脚本的修法 —— stock 无 fdinfo 记账时，
> 报告输出 `阶段内比较 0 次 (跨阶段/换客户端重置 150 段), 真实回退 0 次`，**不再产生任何假回退**。

---

## 十三、v6：R2/R4/R5 三项修复（2026-09-14 实现，09-15 重启后验证）

> 目标：把 §二 里三条"不影响使用"的待办做掉。**只改 gpuacct 变体，stock 源树保持 Radxa 原样不动**
> （两个变体并行、安装时选择 —— 这是既有约定，也是做对照实验的前提）。
> v6 = 5 文件 / +391 行；v5 存档为 `pvr-gpuacct-v5-log-semantics.patch`。

### 13.1 R2 热路径无锁化

| 之前（v1~v5） | 现在（v6） |
|---|---|
| 每次 kick：`mutex_lock` → 遍历链表 → 计数 → `mutex_unlock`；新 pid 还要 `kzalloc(GFP_ATOMIC)` | 快路径：`rcu_read_lock` → RCU 遍历 → `atomic64_inc`（**无锁**）；只有新 pid 才走慢路径 |
| `g_pvr_gpuacct_total_kicks` 普通变量、受 mutex 保护 | `atomic64_t`，`atomic64_xchg` 取走本周期值 |
| "采样循环是否在跑" 普通 bool、受 mutex 保护 | `atomic_t`，`atomic_read/set`（`schedule_delayed_work` 对已排队的 work 重复调用是安全的） |
| 慢路径竞态：两个 CPU 同时为新 pid 建条目 → 现在 spinlock 内**双重检查**，重复者丢弃并复用已存在条目 | |

读侧（`pvr_show_fdinfo`）也从 mutex 改成 `rcu_read_lock`；tick 的忙时分配改为
`atomic64_xchg(&e->kicks, 0)` + RCU 遍历，不再持锁。

### 13.2 R4 记账条目回收

- 每个 tick 扫一遍条目：用 `pid_task(find_vpid(pid), PIDTYPE_PID)`（RCU 下）判断进程是否还在；
  已消失的条目 `list_del_rcu()` + `kfree_rcu()` 回收 → **PID 复用不会再继承旧的累计忙时**。
- 兜底：条目数 > `PVR_GPUACCT_MAX_ENTRIES`(4096) 时，淘汰最久未活动的一条（正常永不触发）。
- 卸载路径加固：先 `list_del_rcu` 摘链 → `synchronize_rcu()` → 再收一次（兜住卸载瞬间走慢路径的 kick）
  → 第二个宽限期 → `kfree`，避免 use-after-free 与泄漏。

### 13.3 R5 fdinfo 去重

- 之前：我们打 `drm-client-id: <pid>` + `drm-driver` + `drm-engine-pvr`，而内核 `drm_show_fdinfo()`
  之后又打一遍 `drm-driver`/`drm-client-id` → **同名字段出现两次**。
- 现在：**不再自己打 client-id/driver**，engine 行改到内核输出**之后**：

```
drm-driver:      pvr            ← 内核打（唯一一份）
drm-client-id:   6              ← 内核打（真实 client id，唯一一份）
drm-engine-pvr:  1473896000 ns  ← 我们打（唯一一份）
```
  文件顺序仍是"client-id 在 engine 之前"，htop 的契约不变（见 13.4 验证）。
  老内核（< 6.5，没有 `drm_show_fdinfo()` 助手）保留自打 client-id/driver 的分支。

### 13.4 验证证据（2026-09-15）

| 项 | 方法与结果 |
|---|---|
| 编译/安装 | DKMS 构建通过；`--gpuacct` 装成功，磁盘 ko 2,239,480 B，`--status` 三行同为 gpuacct |
| **真实重启** | 2026-09-14 23:56 重启 → 开机自动加载 gpuacct；运行中模块 build-id = 磁盘 ko（`6055ecd4…`）→ **DKMS 持久化成立**（这项此前只是推断，现在实测） |
| R5 去重 | 实跑 GPU 客户端后取 fdinfo：`drm-driver`×1、`drm-client-id`×1、`drm-engine-pvr`×1，顺序 driver → client-id → engine ✅ |
| htop 兼容 | 按 htop 3.4.1 `linux/GPU.c` 的状态机在真实 fdinfo 上复算：`client_id=11`、`engine=[('pvr', 1.52s)]` → 会被采纳 ✅ |
| 记账仍正常 | 记账 1.52 s → 5.45 s（5 s wall，约 79% 占空比）单调增长 ✅ |
| R4 回收 | 非 GPU 对照（240×`/bin/true`）残留 0；GPU 爆发（240×`egl_render`，53 ms/次）后 4 s 内 kmalloc-96 从 22,839 落回 4,830；随后 3 轮各 120 次的重复爆发，平台期**不增长**（96: 4264→3855→4296→3965；64: 9013→8390→8946→8968，纯噪声）→ 条目确实被回收 ✅ |

> 说明：条目结构约 64~72 B，落在 `kmalloc-64/96`；slab 计数有 ±几十的噪声，故用"重复爆发平台期是否单调增长"作为判据
> （若无回收，每轮 +120 应累加）。

：debugfs 零值窗口与本补丁**无关**（2026-09-14 02:55 完成）

---

## 十四、4h 增强相位长测（2026-09-15 06:02 完成）与一个待定问题

**跑法**：`gpu-driver-stability.sh 14400`（gpuacct v6，39 轮 / 14653 s；相位集扩充为 8 个：gles 60s → ocl 60s →
vk 60s → mixed 45s → **multi（4×GLES 并发）45s** → **vkgl（GLES+Vulkan 并发）60s** → **burst（短命客户端 churn）30s** → idle 15s）。

### 14.1 健康面（全部通过）

| 项 | 结果 |
|---|---|
| 阶段成功率 | **312 / 312**（含 116 次 multi、153 次 vkgl、77 次 burst） |
| 记账单调性（固定 PID 跟踪） | **阶段内比较 335 次，真实回退 0 次** |
| fdinfo 记账冻结 | **无**（跑完现场复测：1.60 s → 3.19 s 单调增长） |
| 温度峰值 | cpub 41.6 / cpul 44.4 / gpu 39.7 / npu 37.7 / ddr 39.7 / skin 32.6 °C |
| 新相位实测 | multi：4 客户端各 ~201 fps（合计 806 fps）；vkgl：Vulkan 74.9 MPix/s + GLES 495 fps 并发；burst：15 s 起停 42 个客户端 —— 均 rc=0 |

### 14.2 唯一的异常：7 次 debugfs 利用率取数失败（**全部落在 multi 相位**）

| 现象 | 值 |
|---|---|
| dmesg 新增 error | **2 条**（`PVR_K:(Error): _DebugStatusDINext: Failed to get GPU statistics (PVRSRV_ERROR_RESOURCE_UNAVAILABLE)`，05:35:18 / 05:35:34）——dmesg 环形缓冲只保留到 04:25，更早的被冲掉 |
| 驱动 `Server Errors` 计数 | 0 → **7**（该计数 = error 级 DPF 条数 `ui32DPFErrorCount`，经源码确认） |
| 自增时刻 | 03:55:12 / 03:55:27（multi-r19）、04:07:41 / 04:07:56（multi-r21）、04:20:25（multi-r23）、05:35:19 / 05:35:34（multi-r35）——**7 次全部在 multi 相位内** |
| 我们脚本的 util 列 | 出现 **7 个 "-"**（与 7 次失败一一对应；其余 952 个采样正常） |
| 影响面 | **仅监控口径**：渲染、记账、htop 取数（fdinfo）都不受影响；出问题的 multi 相位本身 `rc=0`；跑完后驱动健康（debugfs util 可读、无新错误） |

**机制**（源码层面）：`RGXGetGpuUtilStats()` 内部有"多次尝试取可靠数据"的重试；失败即返回 `PVRSRV_ERROR_RESOURCE_UNAVAILABLE`，
驱动注释写明**当固件正在更新 GPU 状态时 Host 可能读到不可靠的时段数据**。4 个客户端并发提交时固件时段更新最频繁 →
15 s 一次的 debugfs 读取偶尔正好撞上不可靠窗口。同一时段我们的 util-user 也出现过 2 次 `stalled - reset`（05:27、05:33），属同一类现象。

### 14.3 对照实验结论：**与补丁无关**（2026-09-15 09:53）

**做法**：切到 **stock 原版驱动**，用**同一套 8 相位**（含 20 次 multi）跑 2 h
（日志 `/var/log/gpu-driver-stability-20260915-074745`，20 轮 / 160 相位）。

| 指标 | **stock 对照（2h）** | 补丁版 v6（4h） |
|---|---|---|
| 阶段成功 | 160/160 ✅ | 312/312 ✅ |
| `Server Errors` 增量 | **0**（基线 0 → 结束 0） | 0 → **7** |
| util 取不到值（`"-"`） | **0 / 490** | 7 / 959 |
| `_DebugStatusDINext` 失败 | **0 条** | 2 条（dmesg 缓冲外的另 5 条已被冲掉） |
| 温度峰值 | 41.0/41.9/38.7/37.1/38.6/32.5 °C | 41.6/44.4/39.7/37.7/39.7/32.6 °C |

**结论：与补丁无关，属驱动/FW 侧的固有间歇现象。** 三条依据：

1. **源码级**：`RGXGetGpuUtilStats()` 对固件共享区**只读**（本次核对：函数内没有任何写回 `psRGXFWIfGpuUtilFW` 的语句），
   且所有可靠性判据（"abnormal time difference between reads"、DM 计数器回绕、`ui64GpuStatCumulative == 0`）都是
   **拿"该用户自己上次读数"作基准**（每用户独立聚合状态 `hGpuUtilUser`）→ **我们 1 s 的 util-user 既不能改坏共享状态，
   也不会让 debugfs 那个用户（15 s 间隔）失败**；相反，间隔越大越容易撞上"固件正在更新"的窗口。
2. **相位相关性**：补丁版 4 h 里 7 次失败**全部落在 multi（4 客户端并发）相位**——固件时段更新最频繁的相位，
   正是"慢读者"最易踩中的场景；出错相位本身 `rc=0`，渲染与记账不受影响。
3. **间歇性**：同一份 stock 驱动在 2026-09-14 的 2 h 对照里反而出现过**最大**的零值窗口（60.0%），
   这次 2 h 只有 0.4% → 该现象**本身就是间歇的**，没复现不等于不存在（本次 stock 是 20 次 multi，补丁版是 39 次，曝光量本就不同）。

**影响面**：仅监控口径（我们脚本的 util 列 + 内核日志一行 + 驱动 `Server Errors` 计数），
**渲染、按进程记账、htop 取数（fdinfo）全不受影响**；跑完现场复测：记账 1.60 s → 3.19 s 单调增长，debugfs util 可读，无新错误。

**残余不确定性**：若要把"没复现"钉死，可再跑一次 **4 h 的 stock 对照**（与补丁版同曝光量）；当前判断已足够（源码 + 相位相关性 + 间歇性三条一致）。

### 14.4 顺带修正 §十二 的一个措辞

§十二 写的是"持续负载约 42 分钟后失效"，本次两轮证据说明它**不是定时触发，而是间歇发生**：
四次长测的 util 零值率分别为 **43.6%（gpuacct v4 2h）/ 60.0%（stock 2h，9-14）/ 34.3%（gpuacct v6 4h）/ 0.4%（stock 2h，9-15）**。
"起始时间 41m43s vs 41m58s 几乎重合"是那两次恰好如此；**"与补丁无关"的结论不变**（stock 上出现过最大窗口）。
