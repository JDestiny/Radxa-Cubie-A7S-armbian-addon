#include <CL/cl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int main(void){
    cl_int err;
    cl_uint np; clGetPlatformIDs(0,NULL,&np);
    cl_platform_id plat[np?np:1]; clGetPlatformIDs(np,plat,NULL);
    printf("platforms: %u\n", np);
    cl_device_id dev; clGetDeviceIDs(plat[0], CL_DEVICE_TYPE_GPU, 1, &dev, NULL);
    char name[128]; clGetDeviceInfo(dev, CL_DEVICE_NAME, 128, name, NULL);
    printf("device: %s\n", name);
    cl_context ctx = clCreateContext(NULL,1,&dev,NULL,NULL,&err);
    cl_command_queue q = clCreateCommandQueue(ctx, dev, 0, &err);
    const char* src = "__kernel void add(__global float*a, __global float*b, __global float*c, int n){ int i=get_global_id(0); if(i<n) c[i]=a[i]+b[i]; }";
    cl_program prog = clCreateProgramWithSource(ctx,1,&src,NULL,&err);
    if (clBuildProgram(prog,1,&dev,NULL,NULL,NULL) != CL_SUCCESS) {
        char log[2048]; clGetProgramBuildInfo(prog,dev,CL_PROGRAM_BUILD_LOG,2048,log,NULL);
        printf("build fail: %s\n", log); return 1;
    }
    cl_kernel k = clCreateKernel(prog,"add",&err);
    const int N = 1<<20;
    float *ha=malloc(N*4), *hb=malloc(N*4), *hc=malloc(N*4);
    for(int i=0;i<N;i++){ha[i]=i*0.5f;hb[i]=i*0.25f;}
    cl_mem da = clCreateBuffer(ctx,CL_MEM_READ_ONLY|CL_MEM_COPY_HOST_PTR,N*4,ha,&err);
    cl_mem db = clCreateBuffer(ctx,CL_MEM_READ_ONLY|CL_MEM_COPY_HOST_PTR,N*4,hb,&err);
    cl_mem dc = clCreateBuffer(ctx,CL_MEM_WRITE_ONLY,N*4,NULL,&err);
    clSetKernelArg(k,0,sizeof(da),&da); clSetKernelArg(k,1,sizeof(db),&db);
    clSetKernelArg(k,2,sizeof(dc),&dc); clSetKernelArg(k,3,sizeof(int),&N);
    size_t gs=N; clEnqueueNDRangeKernel(q,k,1,NULL,&gs,NULL,0,NULL,NULL);
    clFinish(q);
    clEnqueueReadBuffer(q,dc,CL_TRUE,0,N*4,hc,0,NULL,NULL);
    int ok=1;
    for(int i=0;i<N;i+=N/16) if(hc[i] != ha[i]+hb[i]) { ok=0; printf("MISMATCH at %d: %f != %f\n", i, hc[i], ha[i]+hb[i]); break; }
    printf("OpenCL vector add (%d elems): %s\n", N, ok?"PASS":"FAIL");
    return ok?0:1;
}
