#include <jni.h>
#include <stdint.h>
#include <stdlib.h>
#include <dlfcn.h>
#include <android/log.h>

#define LOG_TAG "LinassJNI"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

// ============================================================================
// libass 类型定义（从 libass 头文件提取的最小定义）
// ============================================================================

typedef struct ass_library ASS_Library;
typedef struct ass_renderer ASS_Renderer;
typedef struct ass_track ASS_Track;

typedef struct ass_image {
    int w, h;
    int stride;
    unsigned char *bitmap;
    uint32_t color;
    int dst_x, dst_y;
    struct ass_image *next;
} ASS_Image;

// ============================================================================
// 函数指针（从 libass.so 或 libmpv.so 动态加载）
// ============================================================================

static struct {
    void *handle;

    ASS_Library* (*ass_library_init)(void);
    void (*ass_library_done)(ASS_Library *priv);
    void (*ass_set_extract_fonts)(ASS_Library *priv, int extract);
    void (*ass_set_style_overrides)(ASS_Library *priv, char **list);

    ASS_Renderer* (*ass_renderer_init)(ASS_Library *);
    void (*ass_renderer_done)(ASS_Renderer *priv);
    void (*ass_set_frame_size)(ASS_Renderer *priv, int w, int h);
    void (*ass_set_storage_size)(ASS_Renderer *priv, int w, int h);
    void (*ass_set_use_margins)(ASS_Renderer *priv, int use);
    void (*ass_set_font_scale)(ASS_Renderer *priv, double font_scale);
    void (*ass_set_hinting)(ASS_Renderer *priv, int hinting);
    void (*ass_set_line_spacing)(ASS_Renderer *priv, double line_spacing);
    void (*ass_set_default_font)(ASS_Renderer *priv, const char *default_font,
                                 const char *default_family);

    ASS_Track* (*ass_read_file)(ASS_Library *library, char *fname, char *codepage);
    ASS_Track* (*ass_read_memory)(ASS_Library *library, char *buf, size_t bufsize,
                                  char *codepage);
    void (*ass_free_track)(ASS_Track *track);

    ASS_Image* (*ass_render_frame)(ASS_Renderer *priv, ASS_Track *track,
                                   long long now, int *detect_change);

    int available;
} g_ass = {NULL};

static struct {
    ASS_Library *library;
    ASS_Renderer *renderer;
    ASS_Track *track;
} g_ctx = {NULL, NULL, NULL};

// ============================================================================
// 动态加载 libass 符号
// ============================================================================

static int load_libass_symbols(void *handle) {
    #define LOAD_SYM(name) \
        g_ass.name = (decltype(g_ass.name))dlsym(handle, #name); \
        if (!g_ass.name) { \
            LOGE("Failed to load symbol: " #name); \
            return 0; \
        }

    LOAD_SYM(ass_library_init)
    LOAD_SYM(ass_library_done)
    LOAD_SYM(ass_set_extract_fonts)
    LOAD_SYM(ass_set_style_overrides)
    LOAD_SYM(ass_renderer_init)
    LOAD_SYM(ass_renderer_done)
    LOAD_SYM(ass_set_frame_size)
    LOAD_SYM(ass_set_storage_size)
    LOAD_SYM(ass_set_use_margins)
    LOAD_SYM(ass_set_font_scale)
    LOAD_SYM(ass_set_hinting)
    LOAD_SYM(ass_set_line_spacing)
    LOAD_SYM(ass_set_default_font)
    LOAD_SYM(ass_read_file)
    LOAD_SYM(ass_read_memory)
    LOAD_SYM(ass_free_track)
    LOAD_SYM(ass_render_frame)

    #undef LOAD_SYM
    return 1;
}

static void init_libass() {
    if (g_ass.available) return;

    // 1. 尝试加载独立的 libass.so
    g_ass.handle = dlopen("libass.so", RTLD_NOW | RTLD_GLOBAL);
    if (g_ass.handle) {
        LOGI("Loaded libass.so");
    } else {
        LOGI("libass.so not found, trying libmpv.so...");
        // 2. 回退到 libmpv.so（静态链接了 libass）
        g_ass.handle = dlopen("libmpv.so", RTLD_NOW | RTLD_GLOBAL);
        if (g_ass.handle) {
            LOGI("Loaded libmpv.so, extracting libass symbols");
        } else {
            LOGE("Neither libass.so nor libmpv.so found");
            return;
        }
    }

    if (load_libass_symbols(g_ass.handle)) {
        g_ass.available = 1;
        LOGI("libass symbols loaded successfully");
    } else {
        dlclose(g_ass.handle);
        g_ass.handle = NULL;
        LOGE("Failed to load libass symbols");
    }
}

// ============================================================================
// JNI 实现（C++ 语法：env->...）
// ============================================================================

JNIEXPORT jboolean JNICALL
Java_com_example_linplayer_1mobile_LibassBridge_nativeIsAvailable(JNIEnv *env, jobject thiz) {
    init_libass();
    return g_ass.available ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT jlong JNICALL
Java_com_example_linplayer_1mobile_LibassBridge_nativeInit(JNIEnv *env, jobject thiz, jint width, jint height) {
    init_libass();
    if (!g_ass.available) {
        LOGE("libass not available");
        return 0;
    }

    if (g_ctx.library) {
        g_ass.ass_library_done(g_ctx.library);
    }
    if (g_ctx.renderer) {
        g_ass.ass_renderer_done(g_ctx.renderer);
    }

    g_ctx.library = g_ass.ass_library_init();
    if (!g_ctx.library) {
        LOGE("Failed to init ass_library");
        return 0;
    }

    g_ass.ass_set_extract_fonts(g_ctx.library, 1);
    g_ass.ass_set_style_overrides(g_ctx.library, NULL);

    g_ctx.renderer = g_ass.ass_renderer_init(g_ctx.library);
    if (!g_ctx.renderer) {
        LOGE("Failed to init ass_renderer");
        g_ass.ass_library_done(g_ctx.library);
        g_ctx.library = NULL;
        return 0;
    }

    g_ass.ass_set_frame_size(g_ctx.renderer, width, height);
    g_ass.ass_set_storage_size(g_ctx.renderer, width, height);
    g_ass.ass_set_use_margins(g_ctx.renderer, 0);
    g_ass.ass_set_font_scale(g_ctx.renderer, 1.0);
    g_ass.ass_set_hinting(g_ctx.renderer, 1); // ASS_HINTING_LIGHT
    g_ass.ass_set_line_spacing(g_ctx.renderer, 0.0);

    LOGI("libass init: %dx%d", width, height);
    return (jlong)(intptr_t)g_ctx.library;
}

JNIEXPORT jlong JNICALL
Java_com_example_linplayer_1mobile_LibassBridge_nativeLoadFile(JNIEnv *env, jobject thiz, jlong handle, jstring path) {
    if (!g_ass.available || !g_ctx.library) return 0;
    const char *cpath = env->GetStringUTFChars(path, NULL);
    g_ctx.track = g_ass.ass_read_file(g_ctx.library, (char *)cpath, NULL);
    env->ReleaseStringUTFChars(path, cpath);
    if (!g_ctx.track) {
        LOGE("Failed to load sub file");
        return 0;
    }
    LOGI("Loaded sub file");
    return (jlong)(intptr_t)g_ctx.track;
}

JNIEXPORT jlong JNICALL
Java_com_example_linplayer_1mobile_LibassBridge_nativeLoadMemory(JNIEnv *env, jobject thiz, jlong handle, jbyteArray data, jstring codec) {
    if (!g_ass.available || !g_ctx.library) return 0;
    jsize len = env->GetArrayLength(data);
    jbyte *buf = env->GetByteArrayElements(data, NULL);
    const char *ccodec = env->GetStringUTFChars(codec, NULL);

    g_ctx.track = g_ass.ass_read_memory(g_ctx.library, (char *)buf, (size_t)len, (char *)ccodec);

    env->ReleaseByteArrayElements(data, buf, JNI_ABORT);
    env->ReleaseStringUTFChars(codec, ccodec);

    if (!g_ctx.track) {
        LOGE("Failed to load sub from memory");
        return 0;
    }
    LOGI("Loaded sub memory");
    return (jlong)(intptr_t)g_ctx.track;
}

JNIEXPORT void JNICALL
Java_com_example_linplayer_1mobile_LibassBridge_nativeSetFontSize(JNIEnv *env, jobject thiz, jlong handle, jint size) {
    if (!g_ass.available || !g_ctx.renderer) return;
    g_ass.ass_set_font_scale(g_ctx.renderer, (double)size / 48.0);
}

JNIEXPORT void JNICALL
Java_com_example_linplayer_1mobile_LibassBridge_nativeSetFontName(JNIEnv *env, jobject thiz, jlong handle, jstring name) {
    if (!g_ass.available || !g_ctx.renderer) return;
    const char *cname = env->GetStringUTFChars(name, NULL);
    g_ass.ass_set_default_font(g_ctx.renderer, cname, NULL);
    env->ReleaseStringUTFChars(name, cname);
}

JNIEXPORT jbyteArray JNICALL
Java_com_example_linplayer_1mobile_LibassBridge_nativeRenderFrame(JNIEnv *env, jobject thiz, jlong rhandle, jlong thandle, jlong ptsMs) {
    if (!g_ass.available || !g_ctx.renderer || !g_ctx.track) return NULL;

    int changed = 0;
    ASS_Image *img = g_ass.ass_render_frame(g_ctx.renderer, g_ctx.track, ptsMs * 1000, &changed);

    if (!img) return NULL;

    int totalSize = 0;
    ASS_Image *cur = img;
    while (cur) {
        totalSize += cur->w * cur->h * 4 + 20; // 4 ints: w, h, stride, dst_x, dst_y
        cur = cur->next;
    }
    if (totalSize == 0) return NULL;

    jbyteArray result = env->NewByteArray(totalSize);
    jbyte *out = env->GetByteArrayElements(result, NULL);
    int offset = 0;

    cur = img;
    while (cur) {
        int w = cur->w;
        int h = cur->h;
        int stride = cur->stride;
        int dst_x = cur->dst_x;
        int dst_y = cur->dst_y;
        unsigned int color = cur->color;
        unsigned char r = (color >> 24) & 0xFF;
        unsigned char g = (color >> 16) & 0xFF;
        unsigned char b = (color >> 8) & 0xFF;
        unsigned char a = (color) & 0xFF;

        ((int *)out)[offset / 4] = w; offset += 4;
        ((int *)out)[offset / 4] = h; offset += 4;
        ((int *)out)[offset / 4] = stride; offset += 4;
        ((int *)out)[offset / 4] = dst_x; offset += 4;
        ((int *)out)[offset / 4] = dst_y; offset += 4;

        for (int y = 0; y < h; y++) {
            for (int x = 0; x < w; x++) {
                unsigned char alpha = cur->bitmap[y * stride + x];
                out[offset++] = r;
                out[offset++] = g;
                out[offset++] = b;
                out[offset++] = (unsigned char)((alpha * (255 - a)) / 255);
            }
        }
        cur = cur->next;
    }

    env->ReleaseByteArrayElements(result, out, 0);
    return result;
}

JNIEXPORT void JNICALL
Java_com_example_linplayer_1mobile_LibassBridge_nativeDispose(JNIEnv *env, jobject thiz, jlong lhandle, jlong rhandle, jlong thandle) {
    if (!g_ass.available) return;
    if (g_ctx.track) {
        g_ass.ass_free_track(g_ctx.track);
        g_ctx.track = NULL;
    }
    if (g_ctx.renderer) {
        g_ass.ass_renderer_done(g_ctx.renderer);
        g_ctx.renderer = NULL;
    }
    if (g_ctx.library) {
        g_ass.ass_library_done(g_ctx.library);
        g_ctx.library = NULL;
    }
    LOGI("libass disposed");
}
