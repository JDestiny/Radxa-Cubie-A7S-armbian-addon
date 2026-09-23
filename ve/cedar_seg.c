// SPDX-License-Identifier: MIT
/* cedar_seg.c — A733 VE 硬解长流压测 (分段整流提交)
 *
 * cedar_smoke 的整流模式已验证可用, 但解码器输入 SBM 仅 8MB,
 * 长视频须分段: 每段 ≤ seg_max 字节且切在完整 NAL 边界,
 * 首段 bIsFirstPart=1, 末段 bIsLastPart=1, 段间轮询出帧。
 * 配置与 cedar_smoke 完全一致 (smooth/deinterlace/display)。
 *
 * 编译: gcc -O2 -o cedar_seg cedar_seg.c -I<ve>/include -lvdecoder \
 *          -lMemAdapter -lVE -lvideoengine -lcdc_base -lfbm -lsbm \
 *          -lvdecVcs -ldl
 * 用法: sudo ./cedar_seg <h264流> [codec=0x115] [segMB=5]
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <time.h>

#include "vdecoder.h"
#include "vbasetype.h"
#include "memoryAdapter.h"
#include "sc_interface.h"
#include "veAdapter.h"
#include "veInterface.h"

#define VE_OPS_TYPE_AW 0

static double now_s(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

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
    const char *path = argc > 1 ? argv[1] : "input.h264";
    int codec = argc > 2 ? strtol(argv[2], NULL, 0) : VIDEO_CODEC_FORMAT_H264;
    long segmax = argc > 3 ? atol(argv[3]) * 1024 * 1024 : 4 * 1024 * 1024;
    unsigned char *stream = NULL;
    size_t streamsz = 0;
    struct ScMemOpsS *memops;
    VideoDecoder *dec;
    VideoStreamInfo si;
    VConfig vc;
    int frames = 0, seg = 0;
    double t0;

    printf("== A733 VE 硬解压测 (分段整流) ==\n");
    if (load_file(path, &stream, &streamsz)) { printf("[FAIL] 读流\n"); return 1; }
    printf("流: %s (%zu 字节, 段上限 %ld MB)\n", path, streamsz, segmax / 1048576);

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
    vc.eOutputPixelFormat = PIXEL_FORMAT_NV12;
    vc.nFrameBufferNum = 8;
    vc.bDispErrorFrame = 1;
    vc.nDecodeSmoothFrameBufferNum = 2;
    vc.nDeInterlaceHoldingFrameBufferNum = 2;
    vc.nDisplayHoldingFrameBufferNum = 2;
    if (InitializeVideoDecoder(dec, &si, &vc) != 0) {
        printf("[FAIL] InitializeVideoDecoder\n");
        return 1;
    }
    printf("[OK] InitializeVideoDecoder (H264/NV12)\n");

    t0 = now_s();

    /* 分段: 每段切在完整 NAL 边界, ≤ segmax */
    {
        size_t segstart = 0;
        int is_first = 1;

        while (segstart < streamsz) {
            size_t segend = segstart + (size_t)segmax;
            int is_last;
            char *buf = NULL, *ring = NULL;
            int bufsz = 0, ringsz = 0;
            size_t len;
            VideoStreamDataInfo di;
            int tries = 0;

            if (segend >= streamsz) {
                segend = streamsz;
                is_last = 1;
            } else {
                /* 回退到 segend 之前的最后一个 NAL 边界 */
                size_t p = segend;
                is_last = 0;
                while (p > segstart + 4) {
                    if (stream[p-1] == 1 && stream[p-2] == 0 && stream[p-3] == 0 &&
                        (p - 4 == segstart || stream[p-4] != 0)) {
                        /* 00 00 01; 若 p-4 也是 0 则是 00 00 00 01 */
                        if (p >= 5 && stream[p-4] == 0 && stream[p-5] == 0)
                            p -= 1;
                        break;
                    }
                    p--;
                }
                if (p <= segstart + 4) {
                    /* 找不到边界: 直接整段 (解码器容忍?) */
                    p = segend;
                }
                segend = p;
            }
            len = segend - segstart;

            /* 请求缓冲; SBM 满则轮询出帧释放后重试 */
            while (RequestVideoStreamBuffer(dec, (int)len, &buf, &bufsz,
                                            &ring, &ringsz, 0) != 0 || !buf ||
                   (size_t)(bufsz + ringsz) < len) {
                VideoPicture *pic;
                DecodeVideoStream(dec, 0, 0, 0, 0);
                pic = RequestPicture(dec, 0);
                if (pic) { frames++; ReturnPicture(dec, pic); }
                if (++tries > 40000) {
                    printf("[FAIL] 段 %d SBM 无法取得 %zu 字节 (tries=%d)\n",
                           seg, len, tries);
                    goto out;
                }
                usleep(2000);
            }
            {
                size_t copy = (size_t)bufsz;
                if (copy > len) copy = len;
                memcpy(buf, stream + segstart, copy);
                if (ringsz > 0 && len > copy)
                    memcpy(ring, stream + segstart + copy, len - copy);
            }
            memset(&di, 0, sizeof(di));
            di.pData = buf;
            di.nLength = (int)len;
            di.bIsFirstPart = 1;
            di.bIsLastPart = 1;
            di.bValid = 1;
            SubmitVideoStreamData(dec, &di, 0);
            seg++;
            segstart = segend;
            is_first = 0;

            /* 段间轮询出帧 (不排空, 交 SBM 重试机制) */
            {
                int poll;
                for (poll = 0; poll < 8000; poll++) {
                    VideoPicture *pic;
                    DecodeVideoStream(dec, 0, 0, 0, 0);
                    pic = RequestPicture(dec, 0);
                    if (!pic)
                        break;
                    frames++;
                    ReturnPicture(dec, pic);
                }
            }
            if (seg % 5 == 0)
                printf("... 段 %d: 已喂 %zu/%zu 字节, %d 帧, %.1fs\n",
                       seg, segstart, streamsz, frames, now_s() - t0);
        }
    }

    /* EOF flush */
    {
        int guard;
        for (guard = 0; guard < 200000; guard++) {
            VideoPicture *pic;
            int r = DecodeVideoStream(dec, 1, 0, 0, 0);
            pic = RequestPicture(dec, 0);
            if (!pic) {
                if (guard > 500 && r <= 0)
                    break;
                continue;
            }
            frames++;
            ReturnPicture(dec, pic);
        }
    }

out:
    {
        double dt = now_s() - t0;
        printf("\n===== 结果 =====\n");
        printf("段数: %d, 解出帧数: %d\n", seg, frames);
        printf("耗时: %.2f s\n", dt);
        if (dt > 0)
            printf("吞吐: %.1f fps (%.2fx 实时 @25fps)\n", frames / dt, frames / dt / 25.0);
    }
    DestroyVideoDecoder(dec);
    CdcMemClose(memops);
    free(stream);
    return frames > 0 ? 0 : 1;
}
