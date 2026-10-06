# VE 硬解 —— ✅ 成功 (2026-09-04)

> **2026-09-07 更新 (新系统 #6)**: 本文为 2026-09-04 旧系统探索记录。新系统 #6 全套复测通过 —
> H.264 全片 18505 帧 83.5fps / MJPEG 冒烟 / vd_dump dma_buf 路径 10 帧, 均一致。
> **HEVC Main10 真实流结论已变**: NV12(pixfmt=6) 路径在新系统确定性 segfault (旧系统是错帧不崩);
> P010(pixfmt=22) 为唯一可用路径 (90s 段跨旧 fault 点正常)。最新矩阵与命令见 **testcases/README.md**。

## 关键发现 (a733-zero-copy 项目的做法)
直调 libvdecoder 必须:
1. **AddVDPlugin()** — 注册解码服务 (OMX 层在 Prepare 时内部调用, 缺失则解码器链表为空 → 所有格式 unsupported)
2. **解码器插件库** — libawh264.so / libawh265.so / libawavs.so / libawavs2.so / libawmjpeg.so / libawmpeg2.so (从 r6 镜像提取, 已装 /usr/lib + 归档 usr-lib/)

## 验证结果 (6.6.98-vendor 内核)
- 1280x720 H.264 90 帧全部解码: **0.22s** (~400fps 硬解)
- dma_buf fd 每帧可拿 (VideoPicture.nBufFd): 8, 9, 10...
- CPU 占用极低 (user 0.067s)
- 输出 NV12 (PIXEL_FORMAT_NV12=6)

## 全片压测 (2026-09-04, 真实视频 The Box 1080p25 H.264 High L4.0)
- 源: The Box mp4 (149MB 保留 /home/radxa) — 案例 ES 流归档 `testcases/thebox_h264_1080p25_full.h264` (137MB 全片)
- 提取 Annex-B: `ffmpeg -i x.mp4 -c copy -bsf:v h264_mp4toannexb -f h264 x.h264` (137MB)
- 结果 (cedar_seg, 4MB/段): **18505/18543 帧 (99.8%), 221s → 83.7fps; 优化段间轮询后 204s → 90.6fps = 3.62x 实时**
- 1080p 实测 ~140fps (简单流), The Box CG 内容 ~90fps; 720p ~330fps
- 帧差 38 = 段切换重置丢帧 (每切换 1 段丢 1 帧; 39 段丢 38, 单/双段验证吻合)

## ⚠️ 重要教训: 不要强杀解码进程 (2026-09-04 踩坑)
- `timeout`/SIGTERM 强杀 cedar_smoke 等进程 → sunxi_ve 驱动 `lost-lock`, 之后**所有解码变 ~1s/帧** (dmesg: `_cedardev_release(): release lost-lock`)
- 恢复: `sudo modprobe -r sunxi_ve && sudo modprobe sunxi_ve` (无需重启)
- 解码器输入 SBM 仅 8MB, 实际单次整流 ≤ ~5MB (smooth/deint 配置下 ~4.83MB); 长流必须分段

## HEVC 10bit 验证 (2026-09-04, SMB 网络直读)
- 内核无 CIFS (vendor 6.6 CONFIG_CIFS=n) → 用 **smbclient 管道**直读, 零落盘:
  `smbclient //host/share -U u%p -c 'cd "目录"; get 文件.mkv -' | ffmpeg -i pipe:0 -map 0:v:0 -c copy -bsf:v hevc_mp4toannexb -f hevc pipe:1 | sudo ./cedar_stdin 0x116 22`
- 实测: Secret.2007 1080p x265 **Main10** (1920x816) 4.6GB SMB 流式硬解: 出帧 fmt=22 (P010_UV), ~128fps
- 10bit 输出必须 PIXEL_FORMAT_P010_UV=22; 用 NV12=6 也能解 (VE 内部降 8bit, 有损)
- mkv 在 pipe 上 demux 可行 (seek 失败有 fallback; ffprobe 截断读会报 File ended prematurely 属正常)

## ⚠️ 真实压制 HEVC (Main10) 限制与崩溃风险 (2026-09-04/05 复现)

**测试片**: Secret.2007.1080p.BluRay.x265.10bit.DTS (原 mkv 4.6GB 已清理) — 案例 ES 流归档 `testcases/secret_h265_main10_1916x808_head300m.h265` (300MB, 覆盖 fault 点)
HEVC **Main10 L4.0, 1916x808, 23.976fps** (真实 x265 压制, 非测试生成流)

| 模式 | 结果 |
|---|---|
| 传统模式 60s 段 | 1267/1438 帧 (88%), **219 ref missing + ctuNum 错帧**, 无 fault, 正常退出 (多次复现一致) |
| 传统模式 ≥90s 段 | **确定性卡在 1564 帧 (输入 ~33MB/65s 处)** → IOMMU fault (地址 0xfeaf1000/0xf97ea000 每次不同) → 死锁 |
| VCU 模式 | 开头即 **IOMMU fault** (0xfdfea000) → 死锁; **两次导致整个系统重启** ⛔ |
| 软解兜底 | ffmpeg 软解 **38fps = 1.6x 实时** ✅ (该片播放请用软解) |

**dmesg 崩溃证据**:
```
L2 PageTable Invalid — Bug is in VE_DEC0 module, invalid address: 0xfeaf1000 (not mapped!)
sunxi_iommu_irq WARNING / ve_dec0_iommu: Runtime PM usage count underflow!
```

**能力边界** (对照矩阵, 全部干净 ~100-130fps): 8bit/10bit × 1920x1080/1916x808 ×
x265 ultrafast~medium (ref/sao/bframes 变体) 生成流 → 传统/VCU 均正常。
**仅真实压制流特定帧触发库 bug** → 闭源库 DMA 地址计算缺陷, 无配置可绕 (库 MD5 全同无版本可换)。

**Android SDK 源码复用结论 (2026-09-05, U盘 A733_Android15_SDK)**:
- SDK 内 cedarc 源码 (libcedarc v1.3.0/v2.0.0): 框架层完整 (vdecoder.c/sbm/fbm/cdc_base/memory/openmax/demo)
  —— 字符串比对确认 **Linux 闭源 libvdecoder.so = v2.0.0 源码同源编译**
- SDK 内**无** ve/(libVE)、vdecoder/videoengine/(解码引擎)、codec 插件源码 (Android 也用 prebuilt);
  Android prebuilt 为 bionic 编译 (@LIBC 版本化符号) 不能直接 Linux 加载
- **v1.3.0 有 Tina aarch64-glibc 版 prebuilt (标准 libc.so.6 依赖, Linux 可直接加载)**:
  替换 libawh265.so 实测 Secret 60s → 结果与系统版**完全一致** (1267 帧/219 错帧)
  → **bug 存在于所有 libawh265 版本 (v1.3.0/v2.0.0/系统版), Android SDK 无法修复**;
  修复只能等全志更新闭源库, 或软解 (38fps)

**SDK 全盘二次排查 (2026-09-05, sqfs 挂载随机搜索)**:
- SDK tar.gz 已转 squashfs 可挂载全搜: vendor/aw/public (prebuild/lib 仅 decrypt/boot/ncnn/opencv/rild, 无解码库);
  hardware/aw/media 仅 libcedarc/libcedarx
- libawh265.so MD5 矩阵全不同但**行为一致**: v1.3.0 {aarch64-glibc b51397(已实测同bug), musl 2f77e4, androideabi 2301df,
  no_grf 63560f} + v2.0.0 androideabi e588d0 + 系统 9ac1db — 全部 bionic/不可加载或行为同系统
- 10bit 路径源码确认: vdecoder.c 仅 P010→sink 格式映射 (1728行), fbm.c 分配调用闭源 GetBufferSize
  (拒绝 P010=22); **10bit 解码正确性全在闭源 libawh265 插件** — 框架源码无修复点
- VE 补充测试: 输出 YUV_MB32_420 (VE 原生 tile, pixfmt=7) 同样错帧 (1233帧/222 ref missing) — 格式不绕开

**红线**:
- ⛔ 未知真实 HEVC 流慎用 VCU 模式 (IOMMU 中断风暴 → 系统重启)
- 测未知流: 先 60s 内小段 + 传统模式; fault/死锁后 `sudo modprobe -r sunxi_ve && sudo modprobe sunxi_ve` 恢复
- 工具已支持: `cedar_stdin <codec> <pixfmt> <segMB> <vcu:0/1> <auto> <group>`

## 用法
```bash
# 冒烟 (短流 ≤4MB): 一次整流提交
sudo ./cedar_smoke <h264文件> [codec=0x115] [pixfmt=6]
# 长流全片压测: 自动分段整流 (默认 4MB/段, NAL 边界对齐)
sudo ./cedar_seg <h264文件> [codec=0x115] [segMB=4]
# 流式 (stdin): 网络/管道直测不落盘; HEVC 10bit: codec=0x116 pixfmt=22
sudo ./cedar_stdin [codec=0x116] [pixfmt=22] < x.hevc
# 解码 + dma_buf mmap YUV 落盘 (验证画面, ≤500 帧)
sudo ./vd_dump <h264文件> <out.yuv> [codec=0x115] [帧数=10]
```
(codec: H264=0x115 HEVC=0x116; 需 libawh265.so 已装; 退出前 ReturnPicture 释放)

## 文件
- cedar_smoke.c — 冒烟程序 (含 AddVDPlugin, 整流一次提交)
- cedar_seg.c — 分段整流压测 (SBM 8MB 限制; 段切换每段丢 ~1 帧为库语义)
- cedar_stdin.c — 流式 stdin 解码 (SMB/管道直测; NAL 对齐切段 ≤4MB)
- vd_dump.c — dma_buf 读取 + YUV 落盘
- usr-lib/libaw*.so — 解码器插件 (r6 提取)
- include/ — 头文件
