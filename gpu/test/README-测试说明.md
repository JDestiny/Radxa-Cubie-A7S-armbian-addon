# GPU 验证测试程序

| 程序 | 验证内容 | 编译 | 运行 |
|---|---|---|---|
| egl_render | OpenGL ES 2.0/3.2 实渲染（红色三角形 + 像素读回验证） | gcc -o egl_render egl_render.c -lEGL -lGLESv2 | ./egl_render（需 pvrsrvkm 已加载） |
| egl_dev_test | EGL_EXT_platform_device 初始化（绑定 /dev/dri/renderD128） | gcc -o egl_dev_test egl_dev_test.c -lEGL -lGLESv2 | ./egl_dev_test |
| egl_info | EGL 厂商/扩展信息 | gcc -o egl_info egl_info.c -lEGL | ./egl_info |
| ocl_test | OpenCL 3.0 向量加法计算（1M 元素） | gcc -o ocl_test ocl_test.c -lOpenCL | ./ocl_test |

预期结果:
- egl_render: center RGBA = 255,0,0,255 (纯红), corner = 16,12,16 (深灰背景)
- ocl_test: OpenCL vector add (1048576 elems): PASS

依赖: pvrsrvkm.ko 已加载 + /usr/local/lib 用户态 + rgx 固件已安装
（安装流程见 `../../README.md`; 驱动 DKMS 重建见 `../../../A-编译期修复/README.md`）
