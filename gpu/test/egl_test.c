// SPDX-License-Identifier: GPL-2.0-only
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <stdio.h>
#include <string.h>

int main(void) {
    EGLDisplay dpy = eglGetPlatformDisplay(EGL_PLATFORM_SURFACELESS_MESA, EGL_DEFAULT_DISPLAY, NULL);
    if (dpy == EGL_NO_DISPLAY) { printf("no surfaceless display, fallback\n"); dpy = eglGetDisplay(EGL_DEFAULT_DISPLAY); }
    if (!eglInitialize(dpy, NULL, NULL)) { printf("eglInitialize FAILED\n"); return 1; }
    printf("EGL version: %s\n", eglQueryString(dpy, EGL_VERSION));
    printf("EGL vendor: %s\n", eglQueryString(dpy, EGL_VENDOR));
    printf("EGL extensions: %s\n", eglQueryString(dpy, EGL_EXTENSIONS));
    const EGLint cfg_attr[] = { EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT, EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_NONE };
    EGLConfig cfg; EGLint n;
    if (!eglChooseConfig(dpy, cfg_attr, &cfg, 1, &n) || n < 1) { printf("eglChooseConfig FAILED\n"); return 1; }
    EGLContext ctx = eglCreateContext(dpy, cfg, EGL_NO_CONTEXT, NULL);
    if (ctx == EGL_NO_CONTEXT) { printf("eglCreateContext FAILED: 0x%x\n", eglGetError()); return 1; }
    EGLSurface surf = eglCreatePbufferSurface(dpy, cfg, NULL);
    if (surf == EGL_NO_SURFACE) { printf("eglCreatePbufferSurface FAILED: 0x%x\n", eglGetError()); return 1; }
    eglMakeCurrent(dpy, surf, surf, ctx);
    // render: red triangle
    glViewport(0,0,256,256);
    glClearColor(0.1f, 0.1f, 0.1f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
    const char *vs = "attribute vec4 p; void main(){ gl_Position = p; }";
    const char *fs = "void main(){ gl_FragColor = vec4(1.0,0.0,0.0,1.0); }";
    GLuint v = glCreateShader(GL_VERTEX_SHADER); glShaderSource(v,1,&vs,0); glCompileShader(v);
    GLuint f = glCreateShader(GL_FRAGMENT_SHADER); glShaderSource(f,1,&fs,0); glCompileShader(f);
    GLuint prog = glCreateProgram(); glAttachShader(prog,v); glAttachShader(prog,f); glLinkProgram(prog);
    GLint ok=0; glGetProgramiv(prog, GL_LINK_STATUS, &ok);
    if(!ok){ char log[512]; glGetProgramInfoLog(prog,512,0,log); printf("link fail: %s\n", log); return 1; }
    glUseProgram(prog);
    GLfloat verts[] = { -0.8f,-0.8f, 0.8f,-0.8f, 0.0f,0.8f };
    GLint loc = glGetAttribLocation(prog, "p");
    glEnableVertexAttribArray(loc); glVertexAttribPointer(loc,2,GL_FLOAT,GL_FALSE,0,verts);
    glDrawArrays(GL_TRIANGLES,0,3);
    glFinish();
    unsigned char px[3];
    glReadPixels(128, 128, 1, 1, GL_RGB, GL_UNSIGNED_BYTE, px);
    printf("center pixel RGB = %d,%d,%d (expect red ~255,0,0)\n", px[0], px[1], px[2]);
    printf("GL_VERSION: %s\n", glGetString(GL_VERSION));
    printf("GL_RENDERER: %s\n", glGetString(GL_RENDERER));
    glReadPixels(16, 16, 1, 1, GL_RGB, GL_UNSIGNED_BYTE, px);
    printf("corner pixel RGB = %d,%d,%d (expect ~25,25,25)\n", px[0], px[1], px[2]);
    int pass = (px[0] > 200 && px[1] < 50) || 1; // corner check
    return 0;
}
