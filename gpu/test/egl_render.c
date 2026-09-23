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
    PFNEGLGETPLATFORMDISPLAYEXTPROC gpdisp = (PFNEGLGETPLATFORMDISPLAYEXTPROC)eglGetProcAddress("eglGetPlatformDisplayEXT");
    EGLDeviceEXT devs[8]; EGLint n=0;
    if (!qdev(8, devs, &n) || n<1) { printf("no devices\n"); return 1; }
    EGLDisplay dpy = gpdisp(EGL_PLATFORM_DEVICE_EXT, devs[0], NULL);
    if (!eglInitialize(dpy,NULL,NULL)) { printf("init fail 0x%x\n", eglGetError()); return 1; }
    const EGLint cfg_attr[] = { EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT, EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_NONE };
    EGLConfig cfg; EGLint cn;
    if (!eglChooseConfig(dpy, cfg_attr, &cfg, 1, &cn) || cn<1) { printf("cfg fail 0x%x\n", eglGetError()); return 1; }
    EGLint ctx_attr[] = { EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE };
    EGLContext ctx = eglCreateContext(dpy, cfg, EGL_NO_CONTEXT, ctx_attr);
    const EGLint pb_attr[] = { EGL_WIDTH, 256, EGL_HEIGHT, 256, EGL_NONE };
    EGLSurface surf = eglCreatePbufferSurface(dpy, cfg, pb_attr);
    if (!eglMakeCurrent(dpy, surf, surf, ctx)) { printf("mkc fail 0x%x\n", eglGetError()); return 1; }
    printf("GL_RENDERER: %s\n", glGetString(GL_RENDERER));
    printf("GL_VERSION: %s\n", glGetString(GL_VERSION));
    glViewport(0,0,256,256);
    glClearColor(0.05f,0.05f,0.05f,1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
    const char *vs = "attribute vec4 p; void main(){ gl_Position = p; }";
    const char *fs = "precision mediump float; void main(){ gl_FragColor = vec4(1.0,0.0,0.0,1.0); }";
    GLuint v = glCreateShader(GL_VERTEX_SHADER); glShaderSource(v,1,&vs,0); glCompileShader(v);
    GLuint f = glCreateShader(GL_FRAGMENT_SHADER); glShaderSource(f,1,&fs,0); glCompileShader(f);
    GLuint prog = glCreateProgram(); glAttachShader(prog,v); glAttachShader(prog,f); glLinkProgram(prog);
    GLint ok=0; glGetProgramiv(prog, GL_LINK_STATUS, &ok);
    if(!ok){ char log[512]; glGetProgramInfoLog(prog,512,0,log); printf("link fail: %s\n",log); return 1; }
    glUseProgram(prog);
    GLfloat verts[] = { -0.8f,-0.8f, 0.8f,-0.8f, 0.0f,0.8f };
    GLint loc = glGetAttribLocation(prog, "p");
    glEnableVertexAttribArray(loc); glVertexAttribPointer(loc,2,GL_FLOAT,GL_FALSE,0,verts);
    for (int i=0;i<3;i++) glDrawArrays(GL_TRIANGLES,0,3);
    glFinish();
    unsigned char px[4];
    glReadPixels(128,128,1,1,GL_RGBA,GL_UNSIGNED_BYTE,px);
    printf("center RGBA = %d,%d,%d,%d (expect red ~255,0,0,255)\n", px[0],px[1],px[2],px[3]);
    glReadPixels(8,8,1,1,GL_RGBA,GL_UNSIGNED_BYTE,px);
    printf("corner RGBA = %d,%d,%d,%d (expect ~13,13,13,255)\n", px[0],px[1],px[2],px[3]);
    return 0;
}
