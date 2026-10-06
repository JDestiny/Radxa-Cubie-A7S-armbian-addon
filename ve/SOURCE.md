# VE 组件出处

| 内容 | 出处 |
|---|---|
| usr-lib/ (18 库 = 框架 9: libvdecoder/libVE/libvideoengine/libMemAdapter/libcdc_base/libOmx*/libvdecVcs + 解码插件 7: libaw* + 辅助 2: libfbm/libsbm) | Radxa Cubie A7S 官方 bullseye r6 镜像 rootfs `/usr/lib` 提取 (全志闭源) — https://docs.radxa.com/en/cubie/a7s/download |
| include/ (12 头文件) + etc/cedarc.conf | 同上 r6 镜像; veAdapter.h/vencoder*.h/sdecoder.h 于 2026-09-07 二次补提 (首次提取遗漏) |
| testcases/ (The Box mp4/h264, Secret h265, smoke.mjpeg) | 用户提供 (下载/NAS) |
| gst-omx-src/ | Debian 源源码 (gst-omx 1.26 自编译实验) |
| cedar_smoke/seg/stdin/vd_dump + 各 README | 本工作自研 (方案参考 github.com/skamagedon/a733-zero-copy, GPL) |

## gst-omx 源码树

| 目录 | 是否入库 | 来源 / 获取方式 |
|---|---|---|
| `gst-omx-src/` | ❌ 不入库 | 上游源码：<https://gitlab.freedesktop.org/gstreamer/gst-omx.git><br>`git clone https://gitlab.freedesktop.org/gstreamer/gst-omx.git` |
| `gst-omx-1.26-patched/` | ✅ **入库** | gst-omx 1.26 + 本项目适配补丁（上游无对应分支，随仓库分发）|
| `etc/cedarc.conf` | ✅ 入库 | 硬解测试所用 cedarc 运行期配置 |

> 大源码树仅保留必要者入库：有公开上游链接的按上表自行克隆。
