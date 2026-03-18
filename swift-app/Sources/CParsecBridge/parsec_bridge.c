/*
 * parsec_bridge.c — Thin C wrapper around parsec-dso.h for Swift interop.
 *
 * We include parsec-dso.h ONLY for the ParsecInit static function and struct
 * definitions. All subsequent calls go through dso->api.FuncName(dso->ps, ...)
 * directly to avoid macro conflicts.
 */

#define GL_SILENCE_DEPRECATION
#include <dlfcn.h>
#include <stdlib.h>
#include <stdio.h>
#include <OpenGL/OpenGL.h>
#include <OpenGL/gl.h>
#include "include/parsec_bridge.h"

/* We do NOT include parsec-dso.h here because its macro/static-function
   pattern is incompatible with our approach. Instead we define the ParsecAPI
   struct and ParsecDSO struct ourselves, matching the memory layout. */

typedef struct ParsecAPI {
    uint32_t (*ParsecVersion)(void);
    ParsecStatus (*ParsecInit)(uint32_t, const ParsecConfig *, const void *, Parsec **);
    void (*ParsecDestroy)(Parsec *);
    ParsecStatus (*ParsecGetConfig)(Parsec *, ParsecConfig *);
    void * (*ParsecGetBuffer)(Parsec *, uint32_t);
    void (*ParsecFree)(Parsec *, void *);
    void (*ParsecSetLogCallback)(ParsecLogCallback, const void *);
    uint32_t (*ParsecGetOutputs)(ParsecOutput *, uint32_t);
    uint32_t (*ParsecGetDecoders)(ParsecDecoder *, uint32_t);
    ParsecStatus (*ParsecClientConnect)(Parsec *, const ParsecClientConfig *, const char *, const char *);
    void (*ParsecClientDisconnect)(Parsec *);
    ParsecStatus (*ParsecClientGetStatus)(Parsec *, ParsecClientStatus *);
    ParsecStatus (*ParsecClientGetGuests)(Parsec *, ParsecGuest *, uint32_t *);
    ParsecStatus (*ParsecClientSetConfig)(Parsec *, const ParsecClientConfig *);
    ParsecStatus (*ParsecClientSetDimensions)(Parsec *, uint8_t, uint32_t, uint32_t, float);
    ParsecStatus (*ParsecClientPollFrame)(Parsec *, uint8_t, ParsecFrameCallback, uint32_t, const void *);
    ParsecStatus (*ParsecClientPollAudio)(Parsec *, ParsecAudioCallback, uint32_t, const void *);
    bool (*ParsecClientPollEvents)(Parsec *, uint32_t, ParsecClientEvent *);
    ParsecStatus (*ParsecClientGLRenderFrame)(Parsec *, uint8_t, ParsecPreRenderCallback, const void *, uint32_t);
    ParsecStatus (*ParsecClientMetalRenderFrame)(Parsec *, uint8_t, void *, void **, ParsecPreRenderCallback, const void *, uint32_t);
    void (*ParsecClientGLDestroy)(Parsec *, uint8_t);
    ParsecStatus (*ParsecClientSendMessage)(Parsec *, const ParsecMessage *);
    ParsecStatus (*ParsecClientSendUserData)(Parsec *, uint32_t, const char *);
    ParsecStatus (*ParsecClientPause)(Parsec *, bool, bool);
    ParsecStatus (*ParsecClientEnableStream)(Parsec *, uint8_t, bool);
} ParsecAPI;

/* ParsecDSO is our internal name; pmux_handle is the public opaque type */
typedef struct ParsecDSO {
    Parsec *ps;
    void *so;
    ParsecAPI api;

    /* Offscreen GL state for rendering */
    CGLContextObj gl_ctx;
    GLuint gl_fbo;
    GLuint gl_tex;
    uint32_t gl_width;
    uint32_t gl_height;
} ParsecDSO;

/* The header declares pmux_handle as the opaque type — it's the same struct */
struct pmux_handle { char _opaque; }; /* dummy — we cast pmux_handle* <-> ParsecDSO* */

#define HANDLE_TO_DSO(h) ((ParsecDSO *)(h))
#define DSO_TO_HANDLE(d) ((pmux_handle *)(d))

/* ── Lifecycle ─────────────────────────────────────────────── */

/* ParsecInit was a static inline in parsec-dso.h — we need our own copy
   since the #undef removed the macro that the static function depended on.
   We call dlopen/dlsym directly via the pattern from parsec-dso.h. */
int32_t pmux_init(const char *dylib_path, uint16_t client_port, pmux_handle **out)
{
    /* Re-implement the DSO init since the macros are gone */
    ParsecDSO *ctx = (ParsecDSO *)calloc(1, sizeof(ParsecDSO));
    if (!ctx) return -1;

    ctx->so = dlopen(dylib_path, RTLD_NOW);
    if (!ctx->so) { free(ctx); return -1; }

    /* Load all API function pointers */
    #define LOAD(name) do { \
        *(void **)&ctx->api.name = dlsym(ctx->so, #name); \
        if (!ctx->api.name) { dlclose(ctx->so); free(ctx); return -1; } \
    } while(0)

    LOAD(ParsecVersion);
    if ((ctx->api.ParsecVersion() >> 16) != PARSEC_VER_MAJOR) {
        dlclose(ctx->so); free(ctx); return -38000; /* PARSEC_ERR_VERSION */
    }

    LOAD(ParsecInit); LOAD(ParsecDestroy); LOAD(ParsecGetConfig);
    LOAD(ParsecGetBuffer); LOAD(ParsecFree); LOAD(ParsecSetLogCallback);
    LOAD(ParsecGetOutputs); LOAD(ParsecGetDecoders);
    LOAD(ParsecClientConnect); LOAD(ParsecClientDisconnect);
    LOAD(ParsecClientGetStatus); LOAD(ParsecClientGetGuests);
    LOAD(ParsecClientSetConfig); LOAD(ParsecClientSetDimensions);
    LOAD(ParsecClientPollFrame); LOAD(ParsecClientPollAudio);
    LOAD(ParsecClientPollEvents);
    LOAD(ParsecClientGLRenderFrame); LOAD(ParsecClientMetalRenderFrame);
    LOAD(ParsecClientGLDestroy);
    LOAD(ParsecClientSendMessage); LOAD(ParsecClientSendUserData);
    LOAD(ParsecClientPause); LOAD(ParsecClientEnableStream);
    #undef LOAD

    /* Init the Parsec instance */
    ParsecConfig cfg = {0};
    cfg.upnp = 0;
    cfg.clientPort = (int32_t)client_port;
    cfg.hostPort = 0;

    ParsecStatus r = ctx->api.ParsecInit(PARSEC_VER, &cfg, NULL, &ctx->ps);
    if (r != PARSEC_OK) {
        dlclose(ctx->so); free(ctx); return (int32_t)r;
    }

    *out = DSO_TO_HANDLE(ctx);
    return 0;
}

void pmux_destroy(pmux_handle *handle)
{
    ParsecDSO *dso = HANDLE_TO_DSO(handle);
    if (!dso) return;
    if (dso->ps) dso->api.ParsecDestroy(dso->ps);
    if (dso->so) dlclose(dso->so);
    free(dso);
}

uint32_t pmux_version(pmux_handle *handle)
{
    ParsecDSO *dso = HANDLE_TO_DSO(handle);
    return dso ? dso->api.ParsecVersion() : 0;
}

/* ── Connection ────────────────────────────────────────────── */

int32_t pmux_connect(pmux_handle *handle, const char *session_id, const char *peer_id,
                     bool h265, bool color444, int32_t decoder_index,
                     int32_t res_x, int32_t res_y)
{
    ParsecDSO *dso = HANDLE_TO_DSO(handle);
    ParsecClientConfig cfg = PARSEC_CLIENT_DEFAULTS;
    cfg.video[0].decoderH265 = h265;
    cfg.video[0].decoder444 = color444;
    cfg.video[0].decoderIndex = (uint32_t)decoder_index;
    cfg.video[0].resolutionX = res_x;
    cfg.video[0].resolutionY = res_y;
    cfg.video[1].decoderH265 = h265;
    cfg.video[1].decoder444 = color444;
    cfg.video[1].decoderIndex = (uint32_t)decoder_index;
    return (int32_t)dso->api.ParsecClientConnect(dso->ps, &cfg, session_id, peer_id);
}

void pmux_disconnect(pmux_handle *handle)
{
    if (!handle) return;
    ParsecDSO *dso = HANDLE_TO_DSO(handle);
    dso->api.ParsecClientDisconnect(dso->ps);
}

int32_t pmux_get_status(pmux_handle *handle, ParsecClientStatus *out)
{
    if (!handle) return -1;
    ParsecDSO *dso = HANDLE_TO_DSO(handle);
    return (int32_t)dso->api.ParsecClientGetStatus(dso->ps, out);
}

int32_t pmux_set_dimensions(pmux_handle *handle, uint8_t stream,
                            uint32_t w, uint32_t h, float scale)
{
    if (!handle) return -1;
    ParsecDSO *dso = HANDLE_TO_DSO(handle);
    return (int32_t)dso->api.ParsecClientSetDimensions(dso->ps, stream, w, h, scale);
}

int32_t pmux_enable_stream(pmux_handle *handle, uint8_t stream, bool enable)
{
    if (!handle) return -1;
    ParsecDSO *dso = HANDLE_TO_DSO(handle);
    return (int32_t)dso->api.ParsecClientEnableStream(dso->ps, stream, enable);
}

/* ── Input ─────────────────────────────────────────────────── */

int32_t pmux_send_keyboard(pmux_handle *handle, uint32_t code, uint16_t mod, bool pressed)
{
    if (!handle) return -1;
    ParsecDSO *dso = HANDLE_TO_DSO(handle);
    ParsecMessage msg = {0};
    msg.type = MESSAGE_KEYBOARD;
    msg.keyboard.code = (ParsecKeycode)code;
    msg.keyboard.mod = mod;
    msg.keyboard.pressed = pressed;
    return (int32_t)dso->api.ParsecClientSendMessage(dso->ps, &msg);
}

int32_t pmux_send_mouse_motion(pmux_handle *handle, int32_t x, int32_t y,
                               bool relative, uint8_t stream)
{
    if (!handle) return -1;
    ParsecDSO *dso = HANDLE_TO_DSO(handle);
    ParsecMessage msg = {0};
    msg.type = MESSAGE_MOUSE_MOTION;
    msg.mouseMotion.x = x;
    msg.mouseMotion.y = y;
    msg.mouseMotion.relative = relative;
    msg.mouseMotion.stream = stream;
    return (int32_t)dso->api.ParsecClientSendMessage(dso->ps, &msg);
}

int32_t pmux_send_mouse_button(pmux_handle *handle, uint32_t button, bool pressed)
{
    if (!handle) return -1;
    ParsecDSO *dso = HANDLE_TO_DSO(handle);
    ParsecMessage msg = {0};
    msg.type = MESSAGE_MOUSE_BUTTON;
    msg.mouseButton.button = (ParsecMouseButton)button;
    msg.mouseButton.pressed = pressed;
    return (int32_t)dso->api.ParsecClientSendMessage(dso->ps, &msg);
}

int32_t pmux_send_mouse_wheel(pmux_handle *handle, int32_t x, int32_t y)
{
    if (!handle) return -1;
    ParsecDSO *dso = HANDLE_TO_DSO(handle);
    ParsecMessage msg = {0};
    msg.type = MESSAGE_MOUSE_WHEEL;
    msg.mouseWheel.x = x;
    msg.mouseWheel.y = y;
    return (int32_t)dso->api.ParsecClientSendMessage(dso->ps, &msg);
}

int32_t pmux_send_gamepad_button(pmux_handle *handle, uint32_t pad_id,
                                 uint32_t button, bool pressed)
{
    if (!handle) return -1;
    ParsecDSO *dso = HANDLE_TO_DSO(handle);
    ParsecMessage msg = {0};
    msg.type = MESSAGE_GAMEPAD_BUTTON;
    msg.gamepadButton.id = pad_id;
    msg.gamepadButton.button = button;
    msg.gamepadButton.pressed = pressed;
    return (int32_t)dso->api.ParsecClientSendMessage(dso->ps, &msg);
}

int32_t pmux_send_gamepad_axis(pmux_handle *handle, uint32_t pad_id,
                               uint32_t axis, int16_t value)
{
    if (!handle) return -1;
    ParsecDSO *dso = HANDLE_TO_DSO(handle);
    ParsecMessage msg = {0};
    msg.type = MESSAGE_GAMEPAD_AXIS;
    msg.gamepadAxis.id = pad_id;
    msg.gamepadAxis.axis = axis;
    msg.gamepadAxis.value = value;
    return (int32_t)dso->api.ParsecClientSendMessage(dso->ps, &msg);
}

int32_t pmux_send_clipboard(pmux_handle *handle, const char *text)
{
    if (!handle || !text) return -1;
    ParsecDSO *dso = HANDLE_TO_DSO(handle);
    return (int32_t)dso->api.ParsecClientSendUserData(dso->ps, 7, text);
}

/* ── Rendering ─────────────────────────────────────────────── */

int32_t pmux_metal_render(pmux_handle *handle, uint8_t stream,
                          void *cq, void **target, uint32_t timeout)
{
    if (!handle) return -1;
    ParsecDSO *dso = HANDLE_TO_DSO(handle);
    return (int32_t)dso->api.ParsecClientMetalRenderFrame(
        dso->ps, stream, cq, target, NULL, NULL, timeout);
}

int32_t pmux_poll_frame(pmux_handle *handle, uint8_t stream,
                        pmux_frame_cb callback, uint32_t timeout, void *opaque)
{
    if (!handle) return -1;
    ParsecDSO *dso = HANDLE_TO_DSO(handle);
    return (int32_t)dso->api.ParsecClientPollFrame(
        dso->ps, stream, (ParsecFrameCallback)callback, timeout, opaque);
}

/* ── GL Offscreen Rendering ────────────────────────────────── */

int32_t pmux_gl_init(pmux_handle *handle, uint32_t width, uint32_t height)
{
    ParsecDSO *dso = HANDLE_TO_DSO(handle);
    if (dso->gl_ctx) return 0; /* already initialized */

    /* Create offscreen CGL context */
    CGLPixelFormatAttribute attrs[] = {
        kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_Legacy,
        kCGLPFAColorSize, (CGLPixelFormatAttribute)24,
        kCGLPFAAlphaSize, (CGLPixelFormatAttribute)8,
        kCGLPFAAccelerated,
        kCGLPFAAllowOfflineRenderers,
        (CGLPixelFormatAttribute)0
    };

    CGLPixelFormatObj pix;
    GLint npix;
    CGLError err = CGLChoosePixelFormat(attrs, &pix, &npix);
    if (err != kCGLNoError) {
        fprintf(stderr, "[gl] CGLChoosePixelFormat failed: %d\n", err);
        return -1;
    }

    err = CGLCreateContext(pix, NULL, &dso->gl_ctx);
    CGLDestroyPixelFormat(pix);
    if (err != kCGLNoError) {
        fprintf(stderr, "[gl] CGLCreateContext failed: %d\n", err);
        return -1;
    }

    CGLSetCurrentContext(dso->gl_ctx);

    /* Create FBO + texture for offscreen rendering */
    dso->gl_width = width;
    dso->gl_height = height;

    glGenTextures(1, &dso->gl_tex);
    glBindTexture(GL_TEXTURE_2D, dso->gl_tex);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, width, height, 0,
                 GL_BGRA, GL_UNSIGNED_BYTE, NULL);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);

    glGenFramebuffers(1, &dso->gl_fbo);
    glBindFramebuffer(GL_FRAMEBUFFER, dso->gl_fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                           GL_TEXTURE_2D, dso->gl_tex, 0);

    GLenum fbStatus = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    if (fbStatus != GL_FRAMEBUFFER_COMPLETE) {
        fprintf(stderr, "[gl] FBO incomplete: 0x%x\n", fbStatus);
        return -1;
    }

    glViewport(0, 0, width, height);
    glBindFramebuffer(GL_FRAMEBUFFER, 0);

    fprintf(stderr, "[gl] Offscreen GL initialized: %dx%d\n", width, height);
    return 0;
}

int32_t pmux_gl_render(pmux_handle *handle, uint8_t stream, uint32_t timeout,
                       void *out_pixels, uint32_t buf_size,
                       uint32_t *out_w, uint32_t *out_h)
{
    ParsecDSO *dso = HANDLE_TO_DSO(handle);
    if (!dso->gl_ctx) return -1;

    CGLSetCurrentContext(dso->gl_ctx);

    /* SDK renders to framebuffer 0 (default) — don't bind FBO */
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    glViewport(0, 0, dso->gl_width, dso->gl_height);

    ParsecStatus status = dso->api.ParsecClientGLRenderFrame(
        dso->ps, stream, NULL, NULL, timeout);

    if (status == PARSEC_OK || status > 0) {
        /* Copy rendered pixels from framebuffer 0 */
        uint32_t needed = dso->gl_width * dso->gl_height * 4;
        if (out_pixels && buf_size >= needed) {
            glFinish();
            glReadPixels(0, 0, dso->gl_width, dso->gl_height,
                         GL_BGRA, GL_UNSIGNED_BYTE, out_pixels);
        }
        if (out_w) *out_w = dso->gl_width;
        if (out_h) *out_h = dso->gl_height;
    }

    return (int32_t)status;
}

void pmux_gl_destroy(pmux_handle *handle)
{
    ParsecDSO *dso = HANDLE_TO_DSO(handle);
    if (!dso->gl_ctx) return;

    CGLSetCurrentContext(dso->gl_ctx);

    /* Tell SDK to clean up GL resources */
    dso->api.ParsecClientGLDestroy(dso->ps, 0);

    if (dso->gl_fbo) { glDeleteFramebuffers(1, &dso->gl_fbo); dso->gl_fbo = 0; }
    if (dso->gl_tex) { glDeleteTextures(1, &dso->gl_tex); dso->gl_tex = 0; }

    CGLSetCurrentContext(NULL);
    CGLDestroyContext(dso->gl_ctx);
    dso->gl_ctx = NULL;
}

int32_t pmux_gl_direct_render(pmux_handle *handle, uint8_t stream, uint32_t timeout)
{
    ParsecDSO *dso = HANDLE_TO_DSO(handle);
    return (int32_t)dso->api.ParsecClientGLRenderFrame(
        dso->ps, stream, NULL, NULL, timeout);
}

void pmux_gl_stream_destroy(pmux_handle *handle, uint8_t stream)
{
    if (!handle) return;
    ParsecDSO *dso = HANDLE_TO_DSO(handle);
    dso->api.ParsecClientGLDestroy(dso->ps, stream);
}

/* ── Audio ─────────────────────────────────────────────────── */

int32_t pmux_poll_audio(pmux_handle *handle, pmux_audio_cb callback,
                        uint32_t timeout, void *opaque)
{
    if (!handle) return -1;
    ParsecDSO *dso = HANDLE_TO_DSO(handle);
    return (int32_t)dso->api.ParsecClientPollAudio(
        dso->ps, (ParsecAudioCallback)callback, timeout, opaque);
}

/* ── Events ────────────────────────────────────────────────── */

bool pmux_poll_events(pmux_handle *handle, uint32_t timeout, ParsecClientEvent *out)
{
    if (!handle) return false;
    ParsecDSO *dso = HANDLE_TO_DSO(handle);
    return dso->api.ParsecClientPollEvents(dso->ps, timeout, out);
}

void *pmux_get_buffer(pmux_handle *handle, uint32_t key)
{
    if (!handle) return NULL;
    ParsecDSO *dso = HANDLE_TO_DSO(handle);
    return dso->api.ParsecGetBuffer(dso->ps, key);
}

void pmux_free_buffer(pmux_handle *handle, void *buf)
{
    if (!handle || !buf) return;
    ParsecDSO *dso = HANDLE_TO_DSO(handle);
    dso->api.ParsecFree(dso->ps, buf);
}

/* ── Log ───────────────────────────────────────────────────── */

void pmux_set_log_callback(pmux_handle *handle, pmux_log_cb callback, void *opaque)
{
    if (!handle) return;
    ParsecDSO *dso = HANDLE_TO_DSO(handle);
    dso->api.ParsecSetLogCallback((ParsecLogCallback)callback, opaque);
}
