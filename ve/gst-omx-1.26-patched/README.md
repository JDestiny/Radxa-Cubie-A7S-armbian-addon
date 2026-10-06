# gst-omx 1.26 (自编译, 三处补丁) — 逆向修复记录

源码: gitlab.freedesktop.org/gstreamer/gst-omx (master)。为 gstreamer 1.26 (trixie) + 全志 OMX 组件适配。

## 补丁 (omx/gstomxvideodec.c)
1. negotiate: 格式不在 OMX map 时强制 NV12 (原 g_assert 崩) — 绕过组件畸形格式枚举
2. codec_data 只提交一次 (codec_data_sent_once) — 组件把每次 CODECCONFIG 累加进 20KB 缓冲不清零
3. 禁用 USE_BUFFER_DYNAMIC 输入分配 (强制 ALLOCATE_BUFFER) — 1.26 新并发提交特性

## 逆向发现 (libOmxVdec.so, 闭源, 带符号表可反汇编)
- liDealWithInitData (0xe788): 每个 OMX_BUFFERFLAG_CODECCONFIG buffer 数据 memcpy 累加至
  pCtx+0x190 缓冲, mCodecSpecificDataLen(pCtx+392) 累加不清零, 断言上限 0x5000(20KB)
  (line 402: nFilledLen + mCodecSpecificDataLen <= 0x5000)
- 非 CODECCONFIG 帧到达时: 累积 codec data 搬移到新缓冲 (offset 44 存长度) 传给解码器, 但 392 不清零

## 结论 (2026-09-04)
- 三处补丁后: **gdb 下完整跑通, 非 gdb 必崩 (SIGSEGV)** — 纯时序竞态, 位于组件内部
  解码线程 (onMessageReceived→judgeThreadKeepGoing→OmxVdecoderPrepare→liDealWithInitData),
  与 gst core 1.26 的 buffer 提交时序相关, 插件层无法根治
- gst 1.26 core 与全志 OMX 组件不兼容 (竞态); gst 1.18 环境 (Radxa bullseye r6 / eMMC 系统) 完全可用
- 可用硬解路径: gst 1.18 chroot 或 eMMC bullseye 系统 (装 gstreamer1.0-tools 即可)
