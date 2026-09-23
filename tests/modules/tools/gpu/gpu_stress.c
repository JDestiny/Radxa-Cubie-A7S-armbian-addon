// SPDX-License-Identifier: GPL-2.0-only
/* gpu_stress.c — A733 PowerVR GPU 真实渲染压测 (EGL surfaceless + GLES2)
 *
 * headless 环境: EGL_PLATFORM=surfaceless 无窗口渲染;
 * 持续提交几何+纹理渲染负载, 统计 FPS; 可选 glReadPixels 校验像素非全零。
 * 编译: gcc -O2 -o gpu_stress gpu_stress.c -lEGL -lGLESv2
 * 用法: ./gpu_stress [秒数=180]
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>

static double now_s(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

/* 简单纹理着色器: 输出 checker 纹理 */
static const char *vs_src =
    "attribute vec4 pos; attribute vec2 uv; varying vec2 vuv;\n"
    "void main(){ vuv=uv; gl_Position=pos; }";
static const char *fs_src =
    "precision mediump float; varying vec2 vuv; uniform float t;\n"
    "void main(){ vec2 p=floor(vuv*64.0+t); float c=mod(p.x+p.y,2.0);\n"
    "  gl_FragColor=vec4(c, 1.0-c, vuv.x, 1.0); }";

static GLuint prog;
static GLuint buf[2];

static int init_gl(void)
{
    GLuint vs, fs;
    int ok;
    vs = glCreateShader(GL_VERTEX_SHADER);
    glShaderSource(vs, 1, &vs_src, NULL); glCompileShader(vs);
    fs = glCreateShader(GL_FRAGMENT_SHADER);
    glShaderSource(fs, 1, &fs_src, NULL); glCompileShader(fs);
    prog = glCreateProgram();
    glAttachShader(prog, vs); glAttachShader(prog, fs); glLinkProgram(prog);
    glGetProgramiv(prog, GL_LINK_STATUS, &ok);
    if (!ok) { fprintf(stderr, "link fail\n"); return -1; }
    glUseProgram(prog);
    glGenBuffers(2, buf);
    /* 三角形 */
    {
        float v[] = { -1,-1,0, 3,-1,0, -1,3,0 };
        float uv[] = { 0,0, 2,0, 0,2 };
        glBindBuffer(GL_ARRAY_BUFFER, buf[0]);
        glBufferData(GL_ARRAY_BUFFER, sizeof(v), v, GL_STATIC_DRAW);
        glBindBuffer(GL_ARRAY_BUFFER, buf[1]);
        glBufferData(GL_ARRAY_BUFFER, sizeof(uv), uv, GL_STATIC_DRAW);
    }
    glEnableVertexAttribArray(0);
    glEnableVertexAttribArray(1);
    return 0;
}

static void draw_frame(float t)
{
    glClearColor(0.1f, 0.1f, 0.2f, 1);
    glClear(GL_COLOR_BUFFER_BIT);
    glUniform1f(glGetUniformLocation(prog, "t"), t);
    glBindBuffer(GL_ARRAY_BUFFER, buf[0]);
    glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 0, 0);
    glBindBuffer(GL_ARRAY_BUFFER, buf[1]);
    glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 0, 0);
    glDrawArrays(GL_TRIANGLES, 0, 3);
    glFinish();
}

int main(int argc, char **argv)
{
    int secs = argc > 1 ? atoi(argv[1]) : 180;
    EGLDisplay dpy;
    EGLConfig cfg;
    EGLContext ctx;
    EGLint n, attrs[] = { EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
                          EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT, EGL_NONE };
    EGLint ctx_attr[] = { EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE };
    EGLSurface surf;
    EGLint pb[] = { EGL_WIDTH, 1920, EGL_HEIGHT, 1080, EGL_NONE };
    unsigned char *pixels;
    double t0, tlast, tfps0;
    long frames = 0;
    int bad = 0;

    dpy = eglGetPlatformDisplay(EGL_PLATFORM_SURFACELESS_MESA, EGL_DEFAULT_DISPLAY, NULL);
    if (dpy == EGL_NO_DISPLAY)
        dpy = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (!eglInitialize(dpy, NULL, NULL)) { printf("[FAIL] eglInitialize\n"); return 1; }
    if (!eglChooseConfig(dpy, attrs, &cfg, 1, &n) || n < 1) {
        printf("[FAIL] eglChooseConfig\n"); return 1;
    }
    ctx = eglCreateContext(dpy, cfg, EGL_NO_CONTEXT, ctx_attr);
    surf = eglCreatePbufferSurface(dpy, cfg, pb);
    if (ctx == EGL_NO_CONTEXT || surf == EGL_NO_SURFACE) {
        printf("[FAIL] context/surface\n"); return 1;
    }
    eglMakeCurrent(dpy, surf, surf, ctx);
    printf("[OK] EGL %s | GL %s | %s\n",
           eglQueryString(dpy, EGL_VERSION),
           glGetString(GL_VERSION), glGetString(GL_RENDERER));
    if (init_gl() != 0) { printf("[FAIL] shader init\n"); return 1; }
    pixels = malloc(1920 * 1080 * 4);

    t0 = now_s(); tlast = t0; tfps0 = t0;
    while (now_s() - t0 < secs) {
        draw_frame((float)(now_s() - t0) * 20.0f);
        frames++;
        if ((frames % 300) == 0) {
            double tn = now_s();
            /* 周期性读回校验 */
            glReadPixels(960, 540, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
            int blank = (pixels[0]==0 && pixels[1]==0 && pixels[2]==0 && pixels[3]==0);
            if (blank) { bad++; printf("[WARN] 中心像素全零 @%ld 帧\n", frames); }
            if (frames % 3000 == 0)
                printf("... %ld 帧, %.1f fps, %.1fs\n", frames,
                       frames / (tn - tfps0), tn - t0);
        }
    }
    {
        double dt = now_s() - t0;
        printf("\n===== GPU 渲染压测结果 =====\n");
        printf("总帧数: %ld, 耗时 %.1fs\n", frames, dt);
        printf("平均帧率: %.1f fps\n", frames / dt);
        printf("中心像素校验异常: %d 次\n", bad);
    }
    free(pixels);
    eglDestroySurface(dpy, surf);
    eglDestroyContext(dpy, ctx);
    eglTerminate(dpy);
    return bad == 0 ? 0 : 1;
}
