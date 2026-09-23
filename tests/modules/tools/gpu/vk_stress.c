/* vk_stress.c — PowerVR Vulkan compute 压测 (headless)
 * 加载 /tmp/cs.spv (blur 计算 shader), 1920x1080 循环 dispatch
 * 编译: gcc -O2 -o vk_stress vk_stress.c -lvulkan
 * 用法: ./vk_stress [秒数=120]
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <vulkan/vulkan.h>

#define W 1920
#define H 1080

static double now_s(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

static uint32_t *load_spv(const char *path, size_t *sz)
{
    FILE *f = fopen(path, "rb");
    uint32_t *d;
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    *sz = (size_t)ftell(f);
    fseek(f, 0, SEEK_SET);
    d = malloc(*sz);
    if (fread(d, 1, *sz, f) != *sz) { fclose(f); free(d); return NULL; }
    fclose(f);
    return d;
}

int main(int argc, char **argv)
{
    int secs = argc > 1 ? atoi(argv[1]) : 120;
    VkInstance inst;
    VkPhysicalDevice phys;
    VkDevice dev;
    VkQueue queue;
    uint32_t qfam;
    VkResult r;
    size_t spvsz;
    uint32_t *spv;
    VkShaderModule shm;
    VkDescriptorSetLayout dsl;
    VkPipelineLayout pl;
    VkPipeline pipe;
    VkBuffer sbuf;
    VkDeviceMemory smem;
    VkDescriptorPool dpool;
    VkDescriptorSet dset;
    VkCommandPool cpool;
    VkCommandBuffer cmdbuf;
    VkPhysicalDeviceProperties props;
    VkMemoryRequirements mreq;
    float *host;
    double t0, last;
    long iters = 0;
    VkQueueFamilyProperties qfp[8];
    uint32_t nq = 8;

    VkApplicationInfo ai = { VK_STRUCTURE_TYPE_APPLICATION_INFO, NULL, "vk_stress",
                             VK_MAKE_VERSION(1,0,0), NULL, VK_MAKE_VERSION(1,0,0) };
    VkInstanceCreateInfo ici = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, NULL, 0, &ai };
    if (vkCreateInstance(&ici, NULL, &inst) != VK_SUCCESS) { printf("[FAIL] instance\n"); return 1; }
    {
        uint32_t n = 1;
        vkEnumeratePhysicalDevices(inst, &n, &phys);
    }
    vkGetPhysicalDeviceProperties(phys, &props);
    printf("[OK] Vulkan: %s (API %d.%d.%d)\n", props.deviceName,
           VK_VERSION_MAJOR(props.apiVersion), VK_VERSION_MINOR(props.apiVersion),
           VK_VERSION_PATCH(props.apiVersion));

    vkGetPhysicalDeviceQueueFamilyProperties(phys, &nq, qfp);
    for (qfam = 0; qfam < nq; qfam++)
        if (qfp[qfam].queueFlags & VK_QUEUE_COMPUTE_BIT) break;
    if (qfam >= nq) { printf("[FAIL] no compute queue\n"); return 1; }
    {
        float qp = 1.0f;
        VkDeviceQueueCreateInfo qci = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, NULL, 0,
                                        qfam, 1, &qp };
        VkDeviceCreateInfo dci = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, NULL, 0, 1, &qci,
                                   0, NULL, 0, NULL, NULL };
        if (vkCreateDevice(phys, &dci, NULL, &dev) != VK_SUCCESS) { printf("[FAIL] device\n"); return 1; }
    }
    vkGetDeviceQueue(dev, qfam, 0, &queue);

    {
        const char *spv_path = getenv("VK_SPV");
        spv = load_spv(spv_path ? spv_path : "./cs.spv", &spvsz);
    }
    if (!spv) { printf("[FAIL] 读 cs.spv\n"); return 1; }
    {
        VkShaderModuleCreateInfo smci = { VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, NULL, 0,
                                          spvsz, spv };
        if (vkCreateShaderModule(dev, &smci, NULL, &shm) != VK_SUCCESS) {
            printf("[FAIL] shader module\n"); return 1;
        }
    }
    {
        VkDescriptorSetLayoutBinding dslb = { 0, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1,
                                              VK_SHADER_STAGE_COMPUTE_BIT, NULL };
        VkDescriptorSetLayoutCreateInfo lci = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
                                                NULL, 0, 1, &dslb };
        vkCreateDescriptorSetLayout(dev, &lci, NULL, &dsl);
    }
    {
        VkPushConstantRange pcr = { VK_SHADER_STAGE_COMPUTE_BIT, 0, 16 };
        VkPipelineLayoutCreateInfo plci = { VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
                                            NULL, 0, 1, &dsl, 1, &pcr };
        vkCreatePipelineLayout(dev, &plci, NULL, &pl);
    }
    {
        VkPipelineShaderStageCreateInfo ssci = { VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
                                                  NULL, 0, VK_SHADER_STAGE_COMPUTE_BIT, shm,
                                                  "main", NULL };
        VkComputePipelineCreateInfo cpci = { VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
                                             NULL, 0, ssci, pl, VK_NULL_HANDLE, -1 };
        if (vkCreateComputePipelines(dev, VK_NULL_HANDLE, 1, &cpci, NULL, &pipe) != VK_SUCCESS) {
            printf("[FAIL] pipeline\n"); return 1;
        }
    }
    {
        VkBufferCreateInfo bci = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, NULL, 0,
                                   (VkDeviceSize)W * H * 4,
                                   VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
                                   VK_SHARING_MODE_EXCLUSIVE, 0, NULL };
        if (vkCreateBuffer(dev, &bci, NULL, &sbuf) != VK_SUCCESS) { printf("[FAIL] buffer\n"); return 1; }
        vkGetBufferMemoryRequirements(dev, sbuf, &mreq);
        {
            VkPhysicalDeviceMemoryProperties mprops;
            vkGetPhysicalDeviceMemoryProperties(phys, &mprops);
            uint32_t mi = 0;
            for (mi = 0; mi < mprops.memoryTypeCount; mi++)
                if (mprops.memoryTypes[mi].propertyFlags & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT) break;
            VkMemoryAllocateInfo mai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, NULL,
                                         mreq.size, mi };
            if (vkAllocateMemory(dev, &mai, NULL, &smem) != VK_SUCCESS) { printf("[FAIL] alloc\n"); return 1; }
        }
        vkBindBufferMemory(dev, sbuf, smem, 0);
    }
    {
        VkDescriptorPoolSize ps = { VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1 };
        VkDescriptorPoolCreateInfo pci = { VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
                                           NULL, 0, 1, 1, &ps };
        vkCreateDescriptorPool(dev, &pci, NULL, &dpool);
        {
            VkDescriptorSetAllocateInfo sai = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
                                                NULL, dpool, 1, &dsl };
            vkAllocateDescriptorSets(dev, &sai, &dset);
        }
        {
            VkDescriptorBufferInfo dbi = { sbuf, 0, VK_WHOLE_SIZE };
            VkWriteDescriptorSet wds = { VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, NULL, dset,
                                         0, 0, 1, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                                         NULL, &dbi, NULL };
            vkUpdateDescriptorSets(dev, 1, &wds, 0, NULL);
        }
    }
    {
        VkCommandPoolCreateInfo cpci = { VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, NULL, 0, qfam };
        vkCreateCommandPool(dev, &cpci, NULL, &cpool);
        {
            VkCommandBufferAllocateInfo cbai = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
                                                 NULL, cpool, VK_COMMAND_BUFFER_LEVEL_PRIMARY, 1 };
            vkAllocateCommandBuffers(dev, &cbai, &cmdbuf);
        }
    }

    host = malloc(W * H * 4);
    for (int i = 0; i < W * H; i++) host[i] = (i % 1000) / 1000.0f;
    vkMapMemory(dev, smem, 0, VK_WHOLE_SIZE, 0, (void**)&host);
    for (int i = 0; i < W * H; i++) host[i] = (i % 1000) / 1000.0f;

    t0 = now_s(); last = t0;
    while (now_s() - t0 < secs) {
        struct { float t; uint32_t w, h; } pc = { (float)iters, W, H };
        vkResetCommandBuffer(cmdbuf, 0);
        {
            VkCommandBufferBeginInfo bi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
                                            NULL, VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT, NULL };
            vkBeginCommandBuffer(cmdbuf, &bi);
        }
        vkCmdBindPipeline(cmdbuf, VK_PIPELINE_BIND_POINT_COMPUTE, pipe);
        vkCmdBindDescriptorSets(cmdbuf, VK_PIPELINE_BIND_POINT_COMPUTE, pl, 0, 1, &dset, 0, NULL);
        vkCmdPushConstants(cmdbuf, pl, VK_SHADER_STAGE_COMPUTE_BIT, 0, 16, &pc);
        vkCmdDispatch(cmdbuf, (W + 15) / 16, (H + 15) / 16, 1);
        vkEndCommandBuffer(cmdbuf);
        {
            VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO, NULL, 0, NULL, NULL,
                                1, &cmdbuf, 0, NULL };
            vkQueueSubmit(queue, 1, &si, VK_NULL_HANDLE);
            vkQueueWaitIdle(queue);
        }
        iters++;
        if (now_s() - last >= 10) {
            printf("... %ld 次 dispatch (%.2f MPix/s), %.0fs\n",
                   iters, iters * (double)W * H / (now_s() - t0) / 1e6, now_s() - t0);
            last = now_s();
        }
    }
    {
        double dt = now_s() - t0;
        /* 校验: 数据应为 [0,1) 小数 (v-floor(v)) */
        int bad = 0;
        for (int i = 0; i < W * H; i += 9973)
            if (!(host[i] >= 0.0f && host[i] < 1.0f)) bad++;
        printf("\n===== Vulkan compute 压测结果 =====\n");
        printf("dispatch 次数: %ld, 耗时 %.1fs\n", iters, dt);
        printf("吞吐: %.1f MPix/s (单次 %.2f ms)\n",
               iters * (double)W * H / dt / 1e6, dt / iters * 1000);
        printf("结果校验异常: %d\n", bad);
    }
    return 0;
}
