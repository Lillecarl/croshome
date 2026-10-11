/* Headless GLES probe: each step draws into a 64x64 FBO and reads the
 * centre pixel back, so a black zink window splits into the one GL
 * feature that loses the draw. Surfaceless EGL: no compositor involved. */
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <GLES2/gl2ext.h>
#include <stdio.h>
#include <stdlib.h>

#define W 64

static GLuint program(const char *vs, const char *fs)
{
   const char *src[2] = {vs, fs};
   GLenum type[2] = {GL_VERTEX_SHADER, GL_FRAGMENT_SHADER};
   GLuint p = glCreateProgram();
   for (int i = 0; i < 2; i++) {
      GLuint s = glCreateShader(type[i]);
      glShaderSource(s, 1, &src[i], NULL);
      glCompileShader(s);
      GLint ok;
      glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
      if (!ok) {
         char log[1024];
         glGetShaderInfoLog(s, sizeof(log), NULL, log);
         printf("compile failed: %s\n", log);
         exit(1);
      }
      glAttachShader(p, s);
   }
   glBindAttribLocation(p, 0, "pos");
   glLinkProgram(p);
   glUseProgram(p);
   return p;
}

static void check(const char *name, unsigned er, unsigned eg, unsigned eb)
{
   unsigned char px[4] = {0};
   glReadPixels(W / 2, W / 2, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);
   int ok = abs(px[0] - (int)er) < 8 && abs(px[1] - (int)eg) < 8 && abs(px[2] - (int)eb) < 8;
   printf("%-4s %-28s got %3u %3u %3u  want %3u %3u %3u  glError 0x%x\n", ok ? "PASS" : "FAIL",
          name, px[0], px[1], px[2], er, eg, eb, glGetError());
}

static const char *vs_const =
   "attribute vec4 pos;\n"
   "void main() { gl_Position = pos; }\n";
static const char *vs_mvp =
   "attribute vec4 pos;\n"
   "uniform mat4 mvp;\n"
   "void main() { gl_Position = mvp * pos; }\n";
static const char *fs_green =
   "precision mediump float;\n"
   "void main() { gl_FragColor = vec4(0.0, 1.0, 0.0, 1.0); }\n";
static const char *fs_uniform =
   "precision mediump float;\n"
   "uniform vec4 color;\n"
   "void main() { gl_FragColor = color; }\n";

static const GLfloat tri[] = {
   -3.0f, -1.0f, 0.5f, 1.0f,
    3.0f, -1.0f, 0.5f, 1.0f,
    0.0f,  3.0f, 0.5f, 1.0f,
};

static void clear_red(void)
{
   glClearColor(1, 0, 0, 1);
   glClearDepthf(1.0f);
   glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
}

int main(void)
{
   EGLDisplay dpy = eglGetPlatformDisplay(EGL_PLATFORM_SURFACELESS_MESA, EGL_DEFAULT_DISPLAY, NULL);
   if (!eglInitialize(dpy, NULL, NULL)) {
      printf("eglInitialize failed 0x%x\n", eglGetError());
      return 1;
   }
   eglBindAPI(EGL_OPENGL_ES_API);
   const EGLint cattr[] = {EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT, EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_NONE};
   EGLConfig cfg;
   EGLint n = 0;
   eglChooseConfig(dpy, cattr, &cfg, 1, &n);
   /* ES3 for GL_RGB10_A2 renderbuffers; every other step is ES2. */
   const EGLint xattr[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
   EGLContext ctx = eglCreateContext(dpy, n ? cfg : NULL, EGL_NO_CONTEXT, xattr);
   if (!ctx || !eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx)) {
      printf("context failed 0x%x\n", eglGetError());
      return 1;
   }
   printf("renderer: %s\n", glGetString(GL_RENDERER));

   GLuint fbo, color, depth;
   glGenFramebuffers(1, &fbo);
   glBindFramebuffer(GL_FRAMEBUFFER, fbo);
   glGenRenderbuffers(1, &color);
   glBindRenderbuffer(GL_RENDERBUFFER, color);
   glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8_OES, W, W);
   glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, color);
   glGenRenderbuffers(1, &depth);
   glBindRenderbuffer(GL_RENDERBUFFER, depth);
   glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH_COMPONENT16, W, W);
   glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, depth);
   printf("fbo status 0x%x\n", glCheckFramebufferStatus(GL_FRAMEBUFFER));
   glViewport(0, 0, W, W);

   clear_red();
   check("clear", 255, 0, 0);

   GLuint vbo;
   glGenBuffers(1, &vbo);
   glBindBuffer(GL_ARRAY_BUFFER, vbo);
   glBufferData(GL_ARRAY_BUFFER, sizeof(tri), tri, GL_STATIC_DRAW);
   glEnableVertexAttribArray(0);
   glVertexAttribPointer(0, 4, GL_FLOAT, GL_FALSE, 0, 0);

   program(vs_const, fs_green);
   clear_red();
   glDrawArrays(GL_TRIANGLES, 0, 3);
   check("vbo tri, const color", 0, 255, 0);

   GLuint p = program(vs_const, fs_uniform);
   glUniform4f(glGetUniformLocation(p, "color"), 0, 0, 1, 1);
   clear_red();
   glDrawArrays(GL_TRIANGLES, 0, 3);
   check("fs uniform color", 0, 0, 255);

   p = program(vs_mvp, fs_green);
   const GLfloat ident[16] = {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1};
   glUniformMatrix4fv(glGetUniformLocation(p, "mvp"), 1, GL_FALSE, ident);
   clear_red();
   glDrawArrays(GL_TRIANGLES, 0, 3);
   check("vs uniform mvp", 0, 255, 0);

   glEnable(GL_DEPTH_TEST);
   glDepthFunc(GL_LESS);
   clear_red();
   glDrawArrays(GL_TRIANGLES, 0, 3);
   check("depth test LESS, z=0.5", 0, 255, 0);

   glEnable(GL_CULL_FACE);
   glCullFace(GL_BACK);
   clear_red();
   glDrawArrays(GL_TRIANGLES, 0, 3);
   check("+cull back (ccw front)", 0, 255, 0);
   glDisable(GL_CULL_FACE);
   glDisable(GL_DEPTH_TEST);

   glBindBuffer(GL_ARRAY_BUFFER, 0);
   glVertexAttribPointer(0, 4, GL_FLOAT, GL_FALSE, 0, tri);
   clear_red();
   glDrawArrays(GL_TRIANGLES, 0, 3);
   check("client-memory vertices", 0, 255, 0);

   GLushort idx[] = {0, 1, 2};
   clear_red();
   glDrawElements(GL_TRIANGLES, 3, GL_UNSIGNED_SHORT, idx);
   check("indexed draw", 0, 255, 0);

   /* es2gears' layout: one VBO, position and normal interleaved, stride 24. */
   static const GLfloat inter[] = {
      -3.0f, -1.0f, 0.5f, 0.0f, 0.0f, 1.0f,
       3.0f, -1.0f, 0.5f, 0.0f, 0.0f, 1.0f,
       0.0f,  3.0f, 0.5f, 0.0f, 0.0f, 1.0f,
   };
   GLuint ivbo;
   glGenBuffers(1, &ivbo);
   glBindBuffer(GL_ARRAY_BUFFER, ivbo);
   glBufferData(GL_ARRAY_BUFFER, sizeof(inter), inter, GL_STATIC_DRAW);
   const char *vs_inter =
      "attribute vec3 pos;\n"
      "attribute vec3 normal;\n"
      "varying vec3 c;\n"
      "void main() { c = normal; gl_Position = vec4(pos, 1.0); }\n";
   const char *fs_varying =
      "precision mediump float;\n"
      "varying vec3 c;\n"
      "void main() { gl_FragColor = vec4(c, 1.0); }\n";
   p = program(vs_inter, fs_varying);
   GLint nloc = glGetAttribLocation(p, "normal");
   glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 24, (void *)0);
   glEnableVertexAttribArray(nloc);
   glVertexAttribPointer(nloc, 3, GL_FLOAT, GL_FALSE, 24, (void *)12);
   clear_red();
   glDrawArrays(GL_TRIANGLES, 0, 3);
   check("interleaved pos+normal s24", 0, 0, 255);

   /* es2gears draws strips with a non-zero first vertex. Three dummy
    * vertices, then the triangle the earlier steps drew. */
   static const GLfloat strip[] = {
       9.0f,  9.0f, 0.5f, 1.0f, 0.0f, 0.0f,
       9.0f,  9.0f, 0.5f, 1.0f, 0.0f, 0.0f,
       9.0f,  9.0f, 0.5f, 1.0f, 0.0f, 0.0f,
      -3.0f, -1.0f, 0.5f, 0.0f, 0.0f, 1.0f,
       3.0f, -1.0f, 0.5f, 0.0f, 0.0f, 1.0f,
       0.0f,  3.0f, 0.5f, 0.0f, 0.0f, 1.0f,
   };
   glBufferData(GL_ARRAY_BUFFER, sizeof(strip), strip, GL_STATIC_DRAW);
   clear_red();
   glDrawArrays(GL_TRIANGLE_STRIP, 3, 3);
   check("strip, first=3", 0, 0, 255);
   clear_red();
   glDrawArrays(GL_TRIANGLES, 3, 3);
   check("triangles, first=3", 0, 0, 255);

   /* zink picks an A2R10G10B10 swapchain for es2gears' 10-bit config.
    * Render into that format offscreen: a pass leaves only presentation. */
   GLuint c10;
   glGenRenderbuffers(1, &c10);
   glBindRenderbuffer(GL_RENDERBUFFER, c10);
   glRenderbufferStorage(GL_RENDERBUFFER, 0x8059 /* GL_RGB10_A2 */, W, W);
   glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, c10);
   printf("rgb10a2 fbo status 0x%x glError 0x%x\n", glCheckFramebufferStatus(GL_FRAMEBUFFER), glGetError());
   clear_red();
   check("rgb10a2 clear", 255, 0, 0);
   glDrawArrays(GL_TRIANGLES, 3, 3);
   check("rgb10a2 draw", 0, 0, 255);

   return 0;
}
