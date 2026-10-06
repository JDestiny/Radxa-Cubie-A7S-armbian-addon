#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <stdio.h>
int main(void){
    EGLDisplay dpy = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (!eglInitialize(dpy,NULL,NULL)) { printf("init fail\n"); return 1; }
    printf("vendor: %s\n", eglQueryString(dpy, EGL_VENDOR));
    printf("exts: %s\n", eglQueryString(dpy, EGL_EXTENSIONS));
    return 0;
}
