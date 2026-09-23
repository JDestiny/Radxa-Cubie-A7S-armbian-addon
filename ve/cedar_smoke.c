// SPDX-License-Identifier: GPL-2.0-only
/* cedar_smoke.c — A733 VE 硬解冒烟测试 (libvdecoder 直调, 兼容性验证)
 *
 * 目的: 验证从 r6 镜像提取的闭源 VE 解码栈 (配套 vendor 5.15 内核)
 *       在当前 6.6.98-vendor 内核上能否工作 (ioctl 兼容性)。
 * 流程: 读 H.264 Annex-B 流 → CreateVideoDecoder → InitializeVideoDecoder
 *       → 喂流 → DecodeVideoStream → RequestPicture (解出≥1帧即成功)
 *
 * 编译: gcc -o cedar_smoke cedar_smoke.c -lvdecoder -lMemAdapter -lVE \
 *          -lvideoengine -lcdc_base -lfbm -lsbm -ldl
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>

#include "vdecoder.h"
#include "vbasetype.h"
#include "memoryAdapter.h"
#include "sc_interface.h"
#include "veAdapter.h"
#include "veInterface.h"

#define VE_OPS_TYPE_AW 0

/* AddVDPlugin 已在 vdecoder.h 声明 (void) */

static int load_file(const char *path, unsigned char **out, size_t *outsz)
{
    struct stat st;
    FILE *f;
    unsigned char *buf;

    if (stat(path, &st) || st.st_size <= 0)
        return -1;
    f = fopen(path, "rb");
    if (!f)
        return -1;
    buf = malloc(st.st_size);
    if (!buf) { fclose(f); return -1; }
    if (fread(buf, 1, st.st_size, f) != (size_t)st.st_size) {
        free(buf); fclose(f); return -1;
    }
    fclose(f);
    *out = buf;
    *outsz = (size_t)st.st_size;
    return 0;
}

int main(int argc, char **argv)
{
    const char *path = argc > 1 ? argv[1] : "/home/radxa/smoke.h264";
    int codec = argc > 2 ? strtol(argv[2], NULL, 0) : VIDEO_CODEC_FORMAT_H264;
    int pixfmt = argc > 3 ? strtol(argv[3], NULL, 0) : PIXEL_FORMAT_NV12;
    unsigned char *stream = NULL;
    size_t streamsz = 0;
    struct ScMemOpsS *memops = NULL;
    VideoDecoder *dec = NULL;
    VideoStreamInfo si;
    VConfig vc;
    int ret, frames = 0, i;

    printf("== A733 VE 硬解冒烟测试 ==\n");
    printf("流: %s codec=0x%x pixfmt=%d\n", path, codec, pixfmt);
    if (load_file(path, &stream, &streamsz)) {
        printf("[FAIL] 读流失败\n");
        return 1;
    }
    printf("流大小: %zu 字节\n", streamsz);

    /* 0. 注册解码服务插件 (OMX 层同样在初始化时调用, 缺失则解码器链表为空) */
    AddVDPlugin();
    printf("[OK] AddVDPlugin\n");

    /* 1. 内存适配层 */
    memops = MemAdapterGetOpsS();
    if (!memops) { printf("[FAIL] MemAdapterGetOpsS\n"); return 1; }
    if (CdcMemOpen(memops) != 0) {
        printf("[FAIL] CdcMemOpen (VE 设备打开? 检查 /dev/cedar_dev)\n");
        return 1;
    }
    printf("[OK] CdcMemOpen (memops)\n");

    /* 2. 创建解码器 */
    dec = CreateVideoDecoder();
    if (!dec) { printf("[FAIL] CreateVideoDecoder\n"); CdcMemClose(memops); return 1; }
    printf("[OK] CreateVideoDecoder\n");

    /* 3. 初始化 (H.264, NV12, 8 帧缓冲) — 关键兼容性点 */
    memset(&si, 0, sizeof(si));
    si.eCodecFormat = codec;
    si.bIsFramePackage = 0;                       /* Annex-B */

    memset(&vc, 0, sizeof(vc));
    vc.memops = memops;
    vc.veOpsS = GetVeOpsS(VE_OPS_TYPE_AW);
    vc.eOutputPixelFormat = pixfmt;
    vc.nFrameBufferNum = 8;
    vc.bDispErrorFrame = 1;
    vc.nDecodeSmoothFrameBufferNum = 2;
    vc.nDeInterlaceHoldingFrameBufferNum = 2;
    vc.nDisplayHoldingFrameBufferNum = 2;
    /* 先试传统模式 (不启 VCU); 若 unsupported 再开 VCU */

    ret = InitializeVideoDecoder(dec, &si, &vc);
    if (ret != 0) {
        printf("[FAIL] InitializeVideoDecoder ret=%d (VE ioctl 不兼容?)\n", ret);
        DestroyVideoDecoder(dec);
        CdcMemClose(memops);
        return 1;
    }
    printf("[OK] InitializeVideoDecoder (H264/NV12)\n");

    /* 4. 喂流解码: 整流一次提交, 轮询出帧 */
    {
        char *buf = NULL, *ring = NULL;
        int bufsz = 0, ringsz = 0;

        if (RequestVideoStreamBuffer(dec, (int)streamsz, &buf, &bufsz,
                                     &ring, &ringsz, 0) == 0 && buf) {
            VideoStreamDataInfo di;
            size_t copy = (size_t)bufsz;
            if (copy > streamsz) copy = streamsz;
            memcpy(buf, stream, copy);
            if (ringsz > 0 && streamsz > copy)
                memcpy(ring, stream + copy, streamsz - copy);

            memset(&di, 0, sizeof(di));
            di.pData = buf;
            di.nLength = (int)streamsz;
            di.bIsFirstPart = 1;
            di.bIsLastPart = 1;
            di.nPts = 0;
            di.bValid = 1;
            SubmitVideoStreamData(dec, &di, 0);
            printf("[OK] 流已提交 (%d 字节)\n", (int)streamsz);
        } else {
            printf("[WARN] RequestVideoStreamBuffer 失败, 尝试小段喂\n");
        }
    }

    /* 5. 解码轮询出帧 (最多 300 轮) */
    for (i = 0; i < 300; i++) {
        VideoPicture *pic;

        DecodeVideoStream(dec, 0, 0, 0, 0);
        pic = RequestPicture(dec, 0);
        if (pic) {
            frames++;
            printf("[OK] 第 %d 帧解码成功: %dx%d 格式=%d nBufFd=%d\n",
                   frames, pic->nWidth, pic->nHeight,
                   pic->ePixelFormat, pic->nBufFd);
            ReturnPicture(dec, pic);
            if (frames >= 200)
                break;
        }
    }

    DestroyVideoDecoder(dec);
    CdcMemClose(memops);
    free(stream);

    if (frames > 0) {
        printf("\n===== 结果: ✅ VE 硬解可用 (%d 帧) — 6.6.98 内核兼容 =====\n", frames);
        return 0;
    }
    printf("\n===== 结果: ❌ 未解出帧 (ioctl/库不兼容或流问题) =====\n");
    return 1;
}
