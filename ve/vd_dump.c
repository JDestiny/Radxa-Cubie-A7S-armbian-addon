// SPDX-License-Identifier: MIT
/* vd_dump.c — VE 硬解完整管线验证: 解码 + dma_buf 读取 + YUV 落盘
 *
 * 验证: VideoPicture.nBufFd (dma_buf) → DMA_BUF_IOCTL_SYNC → mmap
 *       → 读 NV12 数据写文件 → 供 ffmpeg 校验图像内容。
 * 编译: gcc -o vd_dump vd_dump.c -lvdecoder -lvdecVcs -lMemAdapter -lVE \
 *          -lvideoengine -lcdc_base -lfbm -lsbm -ldl
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/mman.h>
#include <sys/ioctl.h>
#include <linux/dma-buf.h>

#include "vdecoder.h"
#include "vbasetype.h"
#include "memoryAdapter.h"
#include "sc_interface.h"
#include "veAdapter.h"
#include "veInterface.h"

#define VE_OPS_TYPE_AW 0

static int load_file(const char *path, unsigned char **out, size_t *outsz)
{
    struct stat st;
    FILE *f;
    if (stat(path, &st) || st.st_size <= 0)
        return -1;
    f = fopen(path, "rb");
    if (!f) return -1;
    *out = malloc(st.st_size);
    if (!*out) { fclose(f); return -1; }
    if (fread(*out, 1, st.st_size, f) != (size_t)st.st_size) {
        free(*out); fclose(f); return -1;
    }
    fclose(f);
    *outsz = (size_t)st.st_size;
    return 0;
}

int main(int argc, char **argv)
{
    const char *path = argc > 1 ? argv[1] : "input.h264";
    const char *outpath = argc > 2 ? argv[2] : "out.yuv";
    int codec = argc > 3 ? strtol(argv[3], NULL, 0) : VIDEO_CODEC_FORMAT_H264;
    int want_frames = argc > 4 ? atoi(argv[4]) : 10;
    unsigned char *stream = NULL;
    size_t streamsz = 0;
    struct ScMemOpsS *memops;
    VideoDecoder *dec;
    VideoStreamInfo si;
    VConfig vc;
    FILE *yuvf = NULL;
    int frames = 0, i;

    AddVDPlugin();
    if (load_file(path, &stream, &streamsz)) { printf("[FAIL] 读流\n"); return 1; }
    memops = MemAdapterGetOpsS();
    if (!memops || CdcMemOpen(memops) != 0) { printf("[FAIL] memops\n"); return 1; }
    dec = CreateVideoDecoder();
    if (!dec) { printf("[FAIL] CreateVideoDecoder\n"); return 1; }

    memset(&si, 0, sizeof(si));
    si.eCodecFormat = codec;
    si.bIsFramePackage = 0;
    memset(&vc, 0, sizeof(vc));
    vc.memops = memops;
    vc.veOpsS = GetVeOpsS(VE_OPS_TYPE_AW);
    vc.eOutputPixelFormat = PIXEL_FORMAT_NV12;
    vc.nFrameBufferNum = 8;
    vc.bDispErrorFrame = 1;
    vc.nDisplayHoldingFrameBufferNum = 2;
    /* VCU 模式 (VP9 等可能走 VCU) */
    vc.sVcuConfig.bEnableVcu = 1;
    vc.sVcuConfig.bVcuAutoMode = 1;
    if (InitializeVideoDecoder(dec, &si, &vc) != 0) {
        printf("[FAIL] InitializeVideoDecoder\n");
        return 1;
    }
    printf("[OK] 解码器初始化 (codec=0x%x)\n", codec);

    /* 喂流 */
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
            di.bValid = 1;
            SubmitVideoStreamData(dec, &di, 0);
        }
    }

    yuvf = fopen(outpath, "wb");
    if (!yuvf) { printf("[FAIL] 无法写 %s\n", outpath); return 1; }

    for (i = 0; i < 500 && frames < want_frames; i++) {
        VideoPicture *pic;

        DecodeVideoStream(dec, 0, 0, 0, 0);
        pic = RequestPicture(dec, 0);
        if (!pic)
            continue;
        frames++;
        printf("[帧 %d] %dx%d fmt=%d stride=%d nBufFd=%d\n",
               frames, pic->nWidth, pic->nHeight, pic->ePixelFormat,
               pic->nLineStride, pic->nBufFd);

        if (pic->nBufFd > 0 && pic->ePixelFormat == PIXEL_FORMAT_NV12) {
            struct dma_buf_sync sync = { 0 };
            int fd = pic->nBufFd;
            size_t ysize = (size_t)pic->nLineStride * pic->nHeight;
            size_t uvsize = ysize / 2;   /* NV12: UV 交错, 半高 */
            unsigned char *map;

            sync.flags = DMA_BUF_SYNC_START | DMA_BUF_SYNC_READ;
            ioctl(fd, DMA_BUF_IOCTL_SYNC, &sync);
            map = mmap(NULL, ysize + uvsize, PROT_READ, MAP_SHARED, fd, 0);
            if (map != MAP_FAILED) {
                fwrite(map, 1, ysize + uvsize, yuvf);
                munmap(map, ysize + uvsize);
                printf("  → 已读 %zu 字节写入 %s\n", ysize + uvsize, outpath);
            } else {
                printf("  [WARN] mmap dma_buf 失败\n");
            }
            sync.flags = DMA_BUF_SYNC_END | DMA_BUF_SYNC_READ;
            ioctl(fd, DMA_BUF_IOCTL_SYNC, &sync);
        }
        ReturnPicture(dec, pic);
    }

    fclose(yuvf);
    printf("共解出 %d 帧, YUV 已写 %s\n", frames, outpath);
    DestroyVideoDecoder(dec);
    CdcMemClose(memops);
    free(stream);
    return frames > 0 ? 0 : 1;
}
