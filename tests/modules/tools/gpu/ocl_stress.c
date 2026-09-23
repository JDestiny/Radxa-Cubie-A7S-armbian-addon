/* ocl_stress.c — PowerVR OpenCL 真实计算压测
 * 大矩阵乘 (1024x1024) 循环执行, 校验结果, 统计 GFLOPS
 * 编译: gcc -O2 -o ocl_stress ocl_stress.c -lOpenCL -lm
 * 用法: ./ocl_stress [秒数=120]
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <CL/cl.h>

#define N 1024

#define TS 16
static const char *kernel_src =
    "__kernel void matmul(__global const float *a, __global const float *bt,\n"
    "                     __global float *c, int n) {\n"
    "  int row = get_global_id(0);\n"
    "  int col = get_global_id(1);\n"
    "  int lr = get_local_id(0), lc = get_local_id(1);\n"
    "  __local float ta[16][16], tb[16][16];\n"
    "  float sum = 0.0f;\n"
    "  for (int k0 = 0; k0 < n; k0 += 16) {\n"
    "    ta[lr][lc] = a[(row) * n + k0 + lc];\n"
    "    tb[lr][lc] = bt[(col) * n + k0 + lr];\n"
    "    barrier(CLK_LOCAL_MEM_FENCE);\n"
    "    for (int k = 0; k < 16; k++)\n"
    "      sum += ta[lr][k] * tb[k][lc];\n"
    "    barrier(CLK_LOCAL_MEM_FENCE);\n"
    "  }\n"
    "  c[row * n + col] = sum;\n"
    "}\n";

static double now_s(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

int main(int argc, char **argv)
{
    int secs = argc > 1 ? atoi(argv[1]) : 120;
    cl_platform_id plat;
    cl_device_id dev;
    cl_context ctx;
    cl_command_queue q;
    cl_program prog;
    cl_kernel kern;
    cl_mem da, db, dc;
    float *ha, *hb, *hc;
    int err, i;
    size_t gsz[2] = { N, N };
    size_t lsz[2] = { 16, 16 };
    double t0, last_report;
    long iters = 0;
    double gflop = 2.0 * N * N * N / 1e9;

    err = clGetPlatformIDs(1, &plat, NULL);
    if (err || clGetDeviceIDs(plat, CL_DEVICE_TYPE_GPU, 1, &dev, NULL)) {
        printf("[FAIL] 平台/设备: %d\n", err); return 1;
    }
    {
        char name[128];
        clGetDeviceInfo(dev, CL_DEVICE_NAME, sizeof(name), name, NULL);
        printf("[OK] OpenCL 设备: %s\n", name);
    }
    ctx = clCreateContext(NULL, 1, &dev, NULL, NULL, &err);
    q = clCreateCommandQueue(ctx, dev, 0, &err);
    prog = clCreateProgramWithSource(ctx, 1, &kernel_src, NULL, &err);
    if (clBuildProgram(prog, 1, &dev, NULL, NULL, NULL) != CL_SUCCESS) {
        char log[2048];
        clGetProgramBuildInfo(prog, dev, CL_PROGRAM_BUILD_LOG, sizeof(log), log, NULL);
        printf("[FAIL] build: %s\n", log); return 1;
    }
    kern = clCreateKernel(prog, "matmul", &err);

    ha = malloc(N * N * 4); hb = malloc(N * N * 4); hc = malloc(N * N * 4);
    /* 构造: a 全 1; b[row*N+col] = (row%7==0)?1:0
     * c[row][col] = sum_k a[row][k]*b[k][col] = count{k: k%7==0} = 147 全等
     * db 存转置 bt[col*N+row] = b[row*N+col] */
    for (i = 0; i < N * N; i++) {
        ha[i] = 1.0f;
        hb[i] = ((i / N) % 7 == 0) ? 1.0f : 0.0f;   /* b 行主序 */
    }
    for (i = 0; i < N * N; i++) {
        int row = i / N, col = i % N;
        hb[i] = ((row % 7) == 0) ? 1.0f : 0.0f;     /* 覆写: b[row][col] 按行填 */
    }
    {
        float *bt = malloc(N * N * 4);
        int r, c2;
        for (r = 0; r < N; r++)
            for (c2 = 0; c2 < N; c2++)
                bt[c2 * N + r] = hb[r * N + c2];
        free(hb);
        hb = bt;
    }
    da = clCreateBuffer(ctx, CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR, N*N*4, ha, &err);
    db = clCreateBuffer(ctx, CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR, N*N*4, hb, &err);
    dc = clCreateBuffer(ctx, CL_MEM_WRITE_ONLY, N*N*4, NULL, &err);
    clSetKernelArg(kern, 0, sizeof(da), &da);
    clSetKernelArg(kern, 1, sizeof(db), &db);
    clSetKernelArg(kern, 2, sizeof(dc), &dc);
    clSetKernelArg(kern, 3, sizeof(int), &(int){N});

    t0 = now_s(); last_report = t0;
    while (now_s() - t0 < secs) {
        clEnqueueNDRangeKernel(q, kern, 2, NULL, gsz, lsz, 0, NULL, NULL);
        clFinish(q);
        iters++;
        if (now_s() - last_report >= 10) {
            printf("... %ld 次矩阵乘, %.1f GFLOPS, %.0fs\n",
                   iters, iters * gflop / (now_s() - t0), now_s() - t0);
            last_report = now_s();
        }
    }
    {
        double dt = now_s() - t0;
        clEnqueueReadBuffer(q, dc, CL_TRUE, 0, N*N*4, hc, 0, NULL, NULL);
        /* 校验: hb 每 7 个 1 个 1 → 每行和 = N/7 ≈ 146 */
        int bad = 0;
        printf("样本值: ");
        for (i = 0; i < 8; i++) printf("%.0f ", hc[i * 137]);
        printf("\n");
        for (i = 0; i < N * N; i += 997)
            if (hc[i] != 147.0f) bad++;
        printf("\n===== OpenCL 压测结果 =====\n");
        printf("矩阵乘次数: %ld, 耗时 %.1fs\n", iters, dt);
        printf("平均单次: %.2f ms\n", dt / iters * 1000);
        printf("计算吞吐: %.1f GFLOPS\n", iters * gflop / dt);
        printf("结果校验异常: %d (合法值 146/147)\n", bad);
    }
    return 0;
}
