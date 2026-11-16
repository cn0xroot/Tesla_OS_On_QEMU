/*
 * LD_PRELOAD 诊断/修复 shim：拦截 eglChooseConfig。
 * 用环境变量 EGLFIX_DROP="0x3026,0x3025" 这种逗号分隔的十六进制 attrib
 * 键列表来控制"这次运行去掉哪些键"，每次只改一个变量、重新起一个全新
 * 进程测试，避免在同一个 hook 调用里递归重入 eglChooseConfig（实测会
 * 导致返回值不可信，见 docs Stage 10 记录）。
 *
 * 编译：gcc -shared -fPIC -O2 -o egl_trace_shim.so egl_trace_shim.c -ldl
 * 用法：EGLFIX_DROP=0x3026 LD_PRELOAD=.../egl_trace_shim.so \
 *       LD_LIBRARY_PATH=/usr/tesla/UI/lib DISPLAY=:0 \
 *       /usr/tesla/UI/bin/QtCar ... 2>&1 | grep EGLTRACE
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <dlfcn.h>
#include <stdint.h>
#include <string.h>

typedef void *EGLDisplay;
typedef void *EGLConfig;
typedef int32_t EGLint;
typedef unsigned int EGLBoolean;

static EGLBoolean (*real_eglChooseConfig)(EGLDisplay, const EGLint *, EGLConfig *, EGLint, EGLint *) = NULL;

#define EGL_NONE_ATTR 0x3038

static const char *attr_name(EGLint a)
{
	switch (a) {
	case 0x3020: return "EGL_BUFFER_SIZE";
	case 0x3021: return "EGL_ALPHA_SIZE";
	case 0x3022: return "EGL_BLUE_SIZE";
	case 0x3023: return "EGL_GREEN_SIZE";
	case 0x3024: return "EGL_RED_SIZE";
	case 0x3025: return "EGL_DEPTH_SIZE";
	case 0x3026: return "EGL_STENCIL_SIZE";
	case 0x3027: return "EGL_CONFIG_CAVEAT";
	case 0x3031: return "EGL_SAMPLES";
	case 0x3032: return "EGL_SAMPLE_BUFFERS";
	case 0x3033: return "EGL_SURFACE_TYPE";
	case 0x3034: return "EGL_TRANSPARENT_TYPE";
	case 0x3040: return "EGL_RENDERABLE_TYPE";
	case 0x3042: return "EGL_CONFORMANT";
	case EGL_NONE_ATTR: return "EGL_NONE";
	default: return "?";
	}
}

/* 解析 EGLFIX_DROP 环境变量里的十六进制 key 列表 */
static EGLint drop_keys[32];
static int n_drop_keys = 0;
static int drop_inited = 0;

static void init_drop_keys(void)
{
	drop_inited = 1;
	const char *e = getenv("EGLFIX_DROP");
	if (!e) return;
	char buf[512];
	strncpy(buf, e, sizeof(buf) - 1);
	buf[sizeof(buf) - 1] = 0;
	char *tok = strtok(buf, ",");
	while (tok && n_drop_keys < 32) {
		drop_keys[n_drop_keys++] = (EGLint)strtol(tok, NULL, 16);
		tok = strtok(NULL, ",");
	}
}

static int should_drop(EGLint a)
{
	for (int i = 0; i < n_drop_keys; i++)
		if (drop_keys[i] == a)
			return 1;
	return 0;
}

static EGLDisplay (*real_eglGetDisplay)(void *) = NULL;
static EGLDisplay (*real_eglGetPlatformDisplayEXT)(unsigned int, void *, const intptr_t *) = NULL;
static EGLBoolean (*real_eglInitialize)(EGLDisplay, EGLint *, EGLint *) = NULL;
static EGLint (*real_eglGetError)(void) = NULL;

#define EGL_PLATFORM_X11_KHR 0x31D5
#define EGL_PLATFORM_SURFACELESS_MESA 0x31DD

static const char *egl_err_name(EGLint e)
{
	switch (e) {
	case 0x3000: return "EGL_SUCCESS";
	case 0x3001: return "EGL_NOT_INITIALIZED";
	case 0x3002: return "EGL_BAD_ACCESS";
	case 0x3003: return "EGL_BAD_ALLOC";
	case 0x3004: return "EGL_BAD_ATTRIBUTE";
	case 0x3005: return "EGL_BAD_CONFIG";
	case 0x3006: return "EGL_BAD_CONTEXT";
	case 0x3007: return "EGL_BAD_CURRENT_SURFACE";
	case 0x3008: return "EGL_BAD_DISPLAY";
	case 0x3009: return "EGL_BAD_MATCH";
	case 0x300A: return "EGL_BAD_NATIVE_PIXMAP";
	case 0x300B: return "EGL_BAD_NATIVE_WINDOW";
	case 0x300C: return "EGL_BAD_PARAMETER";
	case 0x300D: return "EGL_BAD_SURFACE";
	case 0x300E: return "EGL_CONTEXT_LOST";
	default: return "?";
	}
}

/*
 * 根因（2026/docs/00_overview.md Stage 10 末尾）：Qt4 走的是旧式
 * eglGetDisplay(native) 隐式平台探测，这条路径在这台机器上会先撞
 * DRI3 协商失败（"libEGL warning: DRI3 error: Could not get DRI3
 * device"），然后没有像 eglGetPlatformDisplay(EGL_PLATFORM_X11_KHR,...)
 * 那样有效地回退到能用的路径，eglInitialize 直接返回失败
 * (EGL_NOT_INITIALIZED)。而用 eglinfo -B 显式测试 X11 platform（走的
 * 正是 eglGetPlatformDisplay 这条新接口）已经证实完全能正常初始化、
 * 拿到 llvmpipe 软件渲染。这里直接把 eglGetDisplay 转成调用那条已验证
 * 能用的新接口，等价于让 Qt4 走一条它自己没有主动选用、但实际更可靠的
 * 初始化路径。
 */
EGLDisplay eglGetDisplay(void *native_display)
{
	if (!real_eglGetDisplay) real_eglGetDisplay = dlsym(RTLD_NEXT, "eglGetDisplay");
	if (!real_eglGetPlatformDisplayEXT)
		real_eglGetPlatformDisplayEXT = dlsym(RTLD_NEXT, "eglGetPlatformDisplayEXT");

	EGLDisplay d = NULL;
	const char *mode = getenv("EGLFIX_PLATFORM");
	if (real_eglGetPlatformDisplayEXT && mode && strcmp(mode, "surfaceless") == 0) {
		d = real_eglGetPlatformDisplayEXT(EGL_PLATFORM_SURFACELESS_MESA, NULL, NULL);
		fprintf(stderr, "EGLTRACE eglGetDisplay(native=%p) -> [重定向到 Surfaceless] -> %p\n", native_display, d);
	} else if (real_eglGetPlatformDisplayEXT && mode && strcmp(mode, "x11") == 0) {
		d = real_eglGetPlatformDisplayEXT(EGL_PLATFORM_X11_KHR, native_display, NULL);
		fprintf(stderr, "EGLTRACE eglGetDisplay(native=%p) -> [重定向到 X11] -> %p\n", native_display, d);
	}
	if (!d) {
		d = real_eglGetDisplay(native_display);
		fprintf(stderr, "EGLTRACE eglGetDisplay(native=%p) -> [回退到原始调用] -> %p\n", native_display, d);
	}
	return d;
}

EGLBoolean eglInitialize(EGLDisplay dpy, EGLint *major, EGLint *minor)
{
	if (!real_eglInitialize) real_eglInitialize = dlsym(RTLD_NEXT, "eglInitialize");
	if (!real_eglGetError) real_eglGetError = dlsym(RTLD_NEXT, "eglGetError");
	EGLBoolean r = real_eglInitialize(dpy, major, minor);
	EGLint err = real_eglGetError ? real_eglGetError() : -1;
	fprintf(stderr, "EGLTRACE eglInitialize(dpy=%p) -> ret=%d major=%d minor=%d err=0x%x(%s)\n",
		dpy, r, major ? *major : -1, minor ? *minor : -1, err, egl_err_name(err));
	return r;
}

EGLBoolean eglChooseConfig(EGLDisplay dpy, const EGLint *attrib_list,
			    EGLConfig *configs, EGLint config_size,
			    EGLint *num_config)
{
	if (!real_eglChooseConfig)
		real_eglChooseConfig = dlsym(RTLD_NEXT, "eglChooseConfig");
	if (!drop_inited)
		init_drop_keys();

	const EGLint *pass = attrib_list;
	EGLint fixed[256];
	if (attrib_list && n_drop_keys > 0) {
		int r = 0, w = 0;
		for (;;) {
			EGLint a = attrib_list[r];
			if (a == EGL_NONE_ATTR) { fixed[w++] = a; break; }
			EGLint v = attrib_list[r + 1];
			if (!should_drop(a)) { fixed[w++] = a; fixed[w++] = v; }
			else fprintf(stderr, "EGLTRACE dropping 0x%04x (%s)=%d\n", a, attr_name(a), v);
			r += 2;
			if (r > 200) { fixed[w++] = EGL_NONE_ATTR; break; }
		}
		pass = fixed;
	}

	if (attrib_list) {
		fprintf(stderr, "EGLTRACE call attrib_list:\n");
		for (int i = 0; pass[i] != EGL_NONE_ATTR && i < 200; i += 2)
			fprintf(stderr, "EGLTRACE   0x%04x (%-20s) = %d\n", pass[i], attr_name(pass[i]), pass[i+1]);
	}

	if (attrib_list)
		fprintf(stderr, "EGLTRACE dpy=%p configs=%p config_size=%d\n", dpy, (void*)configs, config_size);
	EGLBoolean ret = real_eglChooseConfig(dpy, pass, configs, config_size, num_config);
	fprintf(stderr, "EGLTRACE eglChooseConfig ret=%d num_config=%d\n", ret, num_config ? *num_config : -1);
	return ret;
}
