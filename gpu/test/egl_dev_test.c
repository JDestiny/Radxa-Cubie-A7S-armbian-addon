// SPDX-License-Identifier: GPL-2.0-only
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <stdio.h>
#include <string.h>
#ifndef EGL_PLATFORM_DEVICE_EXT
#define EGL_PLATFORM_DEVICE_EXT 0x313F
#endif
typedef const char* (*PFNEGLQUERYDEVICESTRINGEXTPROC)(EGLDeviceEXT, EGLint);
int main(void){
    PFNEGLQUERYDEVICESEXTPROC qdev = (PFNEGLQUERYDEVICESEXTPROC)eglGetProcAddress("eglQueryDevicesEXT");
    PFNEGLQUERYDEVICESTRINGEXTPROC qstr = (PFNEGLQUERYDEVICESTRINGEXTPROC)eglGetProcAddress("eglQueryDeviceStringEXT");
    PFNEGLGETPLATFORMDISPLAYEXTPROC gpdisp = (PFNEGLGETPLATFORMDISPLAYEXTPROC)eglGetProcAddress("eglGetPlatformDisplayEXT");
    if (!qdev) { printf("no eglQueryDevicesEXT\n"); return 1; }
    EGLDeviceEXT devs[8]; EGLint n=0;
    if (!qdev(8, devs, &n) || n<1) { printf("no EGL devices\n"); return 1; }
    printf("found %d EGL devices\n", n);
    for (EGLint i=0;i<n;i++){
        const char* ext = qstr ? qstr(devs[i], EGL_EXTENSIONS) : "?";
        const char* name = qstr ? qstr(devs[i], 0x31C2) : "?";
        printf("  dev[%d] drm=%s ext=%s\n", i, name?name:"?", ext?ext:"?");
    }
    EGLDisplay dpy = gpdisp ? gpdisp(EGL_PLATFORM_DEVICE_EXT, devs[0], NULL) : EGL_NO_DISPLAY;
    if (dpy == EGL_NO_DISPLAY) { printf("no platform display\n"); return 1; }
    if (!eglInitialize(dpy,NULL,NULL)) { printf("init fail 0x%x\n", eglGetError()); return 1; }
    printf("EGL vendor: %s\n", eglQueryString(dpy, EGL_VENDOR));
    printf("EGL version: %s\n", eglQueryString(dpy, EGL_VERSION));
    const EGLint cfg_attr[] = { EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT, EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_NONE };
    EGLConfig cfg; EGLint cn;
    if (!eglChooseConfig(dpy, cfg_attr, &cfg, 1, &cn) || cn<1) { printf("choosecfg fail 0x%x\n", eglGetError()); return 1; }
    EGLContext ctx = eglCreateContext(dpy, cfg, EGL_NO_CONTEXT, NULL);
    if (ctx==EGL_NO_CONTEXT) { printf("ctx fail 0x%x\n", eglGetError()); return 1; }
    const EGLint pb_attr[] = { EGL_WIDTH, 256, EGL_HEIGHT, 256, EGL_NONE };
    EGLSurface surf = eglCreatePbufferSurface(dpy, cfg, pb_attr);
    if (surf==EGL_NO_SURFACE) { printf("pbuf fail 0x%x\n", eglGetError()); return 1; }
    if (!eglMakeCurrent(dpy, surf, surf, ctx)) { printf("makecurrent fail 0x%x\n", eglGetError()); return 1; }
    printf("GL_RENDERER: %s\n", glGetString(GL_RENDERER));
    printf("GL_VERSION: %s\n", glGetString(GL_VERSION));
    glClearColor(0.0f,0.0f,1.0f,1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
    glFinish();
    unsigned char px[3];
    glReadPixels(128,128,1,1,GL_RGB,GL_UNSIGNED_BYTE,px);
    printf("pixel = %d,%d,%d (expect blue 0,0,255)\n", px[0],px[1],px[2]);
    return (px[2]>200 && px[0]<50) ? 0 : 2;
}
