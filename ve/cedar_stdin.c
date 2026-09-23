// SPDX-License-Identifier: GPL-2.0-only
/* cedar_stdin.c — A733 VE 硬解流式解码 (stdin 输入, 不落盘)
 *
 * 用于 SMB/网络流直测: ffmpeg/任何程序把 Annex-B 裸流写管道,
 * 本程序从 stdin 累积缓冲 → 按 NAL 边界切 ≤segmax 段 → 整流提交
 * (first=1,last=1, 同 cedar_seg 验证模式) → 轮询出帧。
 * 10bit HEVC 输出用 PIXEL_FORMAT_P010_UV=22。
 *
 * 编译: gcc -O2 -o cedar_stdin cedar_stdin.c -I<ve>/include -lvdecoder \
 *          -lMemAdapter -lVE -lvideoengine -lcdc_base -lfbm -lsbm \
 *          -lvdecVcs -ldl
 * 用法: sudo ./cedar_stdin [codec=0x116] [pixfmt=6] [segMB=4] < x.hevc
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>

#include "vdecoder.h"
#include "vbasetype.h"
#include "memoryAdapter.h"
#include "sc_interface.h"
#include "veAdapter.h"
#include "veInterface.h"

#define VE_OPS_TYPE_AW 0
#define BUFMAX (24 * 1024 * 1024)   /* 累积缓冲 */
#define READCHUNK (256 * 1024)

static double now_s(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

/* 找 ≤ segmax 的最大 NAL 边界 (start code 起点位置 = 上一 NAL 结束)。
 * 返回 0 表示当前缓冲切不出完整段 (数据不足或首 NAL 超长)。 */
static size_t find_cut(const unsigned char *b, size_t n, size_t segmax)
{
    size_t limit = n < segmax ? n : segmax;
    size_t cut = 0, i;
    for (i = 1; i + 3 <= limit; i++) {
        if (b[i] == 0 && b[i+1] == 0 &&
            ((b[i+2] == 1) ||
             (b[i+2] == 0 && i + 4 < n && b[i+3] == 1)))
            cut = i;                /* 取最后一个 ≤ segmax 的边界 */
    }
    return cut;
}

int main(int argc, char **argv)
{
    int codec = argc > 1 ? strtol(argv[1], NULL, 0) : VIDEO_CODEC_FORMAT_H265;
    int pixfmt = argc > 2 ? strtol(argv[2], NULL, 0) : PIXEL_FORMAT_NV12;
    size_t segmax = argc > 3 ? (size_t)atol(argv[3]) * 1024 * 1024 : 4 * 1024 * 1024;
    int vcu = argc > 4 ? atoi(argv[4]) : 0;
    int vcu_auto = argc > 5 ? atoi(argv[5]) : 1;
    int vcu_group = argc > 6 ? atoi(argv[6]) : 0;
    struct ScMemOpsS *memops;
    VideoDecoder *dec;
    VideoStreamInfo si;
    VConfig vc;
    unsigned char *buf;
    size_t buflen = 0, bufcap = BUFMAX;
    int frames = 0, segs = 0, eof = 0, guard;
    double t0 = now_s();
    unsigned long long bytes_in = 0;

    printf("== A733 VE 流式硬解 (stdin) ==\n");
    printf("codec=0x%x pixfmt=%d segmax=%zuMB vcu=%d\n", codec, pixfmt, segmax / 1048576, vcu);

    AddVDPlugin();
    memops = MemAdapterGetOpsS();
    if (!memops || CdcMemOpen(memops) != 0) { printf("[FAIL] CdcMemOpen\n"); return 1; }
    dec = CreateVideoDecoder();
    if (!dec) { printf("[FAIL] CreateVideoDecoder\n"); return 1; }

    memset(&si, 0, sizeof(si));
    si.eCodecFormat = codec;
    si.bIsFramePackage = 0;
    memset(&vc, 0, sizeof(vc));
    vc.memops = memops;
    vc.veOpsS = GetVeOpsS(VE_OPS_TYPE_AW);
    vc.eOutputPixelFormat = pixfmt;
    vc.nFrameBufferNum = 8;
    vc.bDispErrorFrame = 1;
    vc.nDecodeSmoothFrameBufferNum = 2;
    vc.nDeInterlaceHoldingFrameBufferNum = 2;
    vc.nDisplayHoldingFrameBufferNum = 2;
    vc.sVcuConfig.bEnableVcu = vcu;
    vc.sVcuConfig.bVcuAutoMode = vcu_auto;
    vc.sVcuConfig.nFrameNumInGroup = vcu_group;
    if (InitializeVideoDecoder(dec, &si, &vc) != 0) {
        printf("[FAIL] InitializeVideoDecoder (codec=0x%x pixfmt=%d)\n", codec, pixfmt);
        return 1;
    }
    printf("[OK] InitializeVideoDecoder\n");

    buf = malloc(bufcap);
    if (!buf) return 1;

    while (!eof) {
        ssize_t r;
        size_t cut;

        /* 1. 填充缓冲 */
        if (bufcap - buflen < READCHUNK) {
            /* 扩容或等待消费; 这里段提交后 buflen 会 memmove 缩小, 一般不会满 */
            fprintf(stderr, "[WARN] 缓冲满 %zu\n", buflen);
            break;
        }
        r = read(0, buf + buflen, READCHUNK);
        if (r < 0) { perror("read"); break; }
        if (r == 0) { eof = 1; }
        else buflen += (size_t)r;
        bytes_in += (size_t)r;

        /* 2. 找可切块: 从缓冲起点切出 ≤segmax 的最大 NAL 对齐块 */
        cut = find_cut(buf, buflen, segmax);
        while (cut > 0) {
            char *rbuf = NULL, *ring = NULL;
            int rbufsz = 0, rringsz = 0;
            VideoStreamDataInfo di;
            int tries = 0;

            while (RequestVideoStreamBuffer(dec, (int)cut, &rbuf, &rbufsz,
                                            &ring, &rringsz, 0) != 0 || !rbuf) {
                VideoPicture *pic;
                DecodeVideoStream(dec, 0, 0, 0, 0);
                pic = RequestPicture(dec, 0);
                if (pic) { frames++; ReturnPicture(dec, pic); }
                if (++tries > 40000) {
                    fprintf(stderr, "[FAIL] 段 %d SBM 满 (cut=%zu)\n", segs, cut);
                    goto out;
                }
                usleep(2000);
            }
            memcpy(rbuf, buf, cut);
            memset(&di, 0, sizeof(di));
            di.pData = rbuf;
            di.nLength = (int)cut;
            di.bIsFirstPart = 1;
            di.bIsLastPart = 1;
            di.bValid = 1;
            SubmitVideoStreamData(dec, &di, 0);
            segs++;

            memmove(buf, buf + cut, buflen - cut);
            buflen -= cut;

            cut = find_cut(buf, buflen, segmax);
            if (buflen < segmax / 2) break;  /* 边读边喂 */
        }

        /* 3. 段间轮询出帧 (有则解, 不排空) */
        for (guard = 0; guard < 400; guard++) {
            VideoPicture *pic;
            DecodeVideoStream(dec, 0, 0, 0, 0);
            pic = RequestPicture(dec, 0);
            if (!pic) break;
            frames++;
            if (frames <= 3)
                printf("[帧 %d] %dx%d fmt=%d\n", frames,
                       pic->nWidth, pic->nHeight, pic->ePixelFormat);
            ReturnPicture(dec, pic);
        }

        if (segs && segs % 20 == 0)
            printf("... 段 %d, 输入 %llu MB, %d 帧, %.1fs\n",
                   segs, bytes_in / 1048576, frames, now_s() - t0);
    }

    /* EOF: 提交残留 (若有) + flush */
    if (buflen > 4) {
        char *rbuf = NULL, *ring = NULL;
        int rbufsz = 0, rringsz = 0;
        VideoStreamDataInfo di;
        int tries = 0;
        while (RequestVideoStreamBuffer(dec, (int)buflen, &rbuf, &rbufsz,
                                        &ring, &rringsz, 0) != 0 || !rbuf) {
            VideoPicture *pic;
            DecodeVideoStream(dec, 0, 0, 0, 0);
            pic = RequestPicture(dec, 0);
            if (pic) { frames++; ReturnPicture(dec, pic); }
            if (++tries > 40000) goto flush;
            usleep(2000);
        }
        memcpy(rbuf, buf, buflen);
        memset(&di, 0, sizeof(di));
        di.pData = rbuf;
        di.nLength = (int)buflen;
        di.bIsFirstPart = 1;
        di.bIsLastPart = 1;
        di.bValid = 1;
        SubmitVideoStreamData(dec, &di, 0);
    }
flush:
    {
        int idle = 0;
        for (guard = 0; guard < 200000; guard++) {
            VideoPicture *pic;
            DecodeVideoStream(dec, 1, 0, 0, 0);
            pic = RequestPicture(dec, 0);
            if (!pic) {
                if (++idle > 3000) break;   /* 连续空转退出 */
                continue;
            }
            idle = 0;
            frames++;
            ReturnPicture(dec, pic);
        }
    }

out:
    {
        double dt = now_s() - t0;
        printf("\n===== 结果 =====\n");
        printf("输入: %llu MB (%.2f GB), 段数: %d\n",
               bytes_in / 1048576, bytes_in / 1073741824.0, segs);
        printf("解出帧数: %d\n", frames);
        printf("耗时: %.2f s\n", dt);
        if (dt > 0)
            printf("吞吐: %.2f fps\n", frames / dt);
    }
    DestroyVideoDecoder(dec);
    CdcMemClose(memops);
    free(buf);
    return frames > 0 ? 0 : 1;
}
