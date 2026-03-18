#pragma once

#include <stdint.h>
#include <stdbool.h>

/* Opaque handle — Swift sees as OpaquePointer.
   The actual struct is defined in parsec_bridge.c only. */
typedef struct pmux_handle pmux_handle;

/* Forward-declare types Swift needs from parsec.h */
#include "parsec.h"

/* ── Lifecycle ─────────────────────────────────────────────── */

int32_t pmux_init(const char *dylib_path, uint16_t client_port, pmux_handle **out);
void    pmux_destroy(pmux_handle *dso);
uint32_t pmux_version(pmux_handle *dso);

/* ── Connection ────────────────────────────────────────────── */

int32_t pmux_connect(pmux_handle *dso, const char *session_id, const char *peer_id,
                     bool h265, bool color444, int32_t decoder_index,
                     int32_t res_x, int32_t res_y);
void    pmux_disconnect(pmux_handle *dso);
int32_t pmux_get_status(pmux_handle *dso, ParsecClientStatus *out);
int32_t pmux_set_dimensions(pmux_handle *dso, uint8_t stream,
                            uint32_t w, uint32_t h, float scale);
int32_t pmux_enable_stream(pmux_handle *dso, uint8_t stream, bool enable);

/* ── Input ─────────────────────────────────────────────────── */

int32_t pmux_send_keyboard(pmux_handle *dso, uint32_t code, uint16_t mod, bool pressed);
int32_t pmux_send_mouse_motion(pmux_handle *dso, int32_t x, int32_t y,
                               bool relative, uint8_t stream);
int32_t pmux_send_mouse_button(pmux_handle *dso, uint32_t button, bool pressed);
int32_t pmux_send_mouse_wheel(pmux_handle *dso, int32_t x, int32_t y);
int32_t pmux_send_gamepad_button(pmux_handle *dso, uint32_t pad_id,
                                 uint32_t button, bool pressed);
int32_t pmux_send_gamepad_axis(pmux_handle *dso, uint32_t pad_id,
                               uint32_t axis, int16_t value);
int32_t pmux_send_clipboard(pmux_handle *dso, const char *text);

/* ── Rendering ─────────────────────────────────────────────── */

/* Metal: renders decoded frame into target texture.
   cq = id<MTLCommandQueue> as void*, target = id<MTLTexture>* as void** */
int32_t pmux_metal_render(pmux_handle *dso, uint8_t stream,
                          void *cq, void **target, uint32_t timeout);

/* PollFrame: calls callback with decoded pixels (for grid thumbnails) */
typedef void (*pmux_frame_cb)(const ParsecFrame *frame, const void *image, void *opaque);
int32_t pmux_poll_frame(pmux_handle *dso, uint8_t stream,
                        pmux_frame_cb callback, uint32_t timeout, void *opaque);

/* GL offscreen render: renders frame into internal FBO, reads back BGRA pixels.
   Returns dimensions via out_w/out_h. Caller must free returned buffer. */
int32_t pmux_gl_init(pmux_handle *dso, uint32_t width, uint32_t height);
int32_t pmux_gl_render(pmux_handle *dso, uint8_t stream, uint32_t timeout,
                       void *out_pixels, uint32_t buf_size,
                       uint32_t *out_w, uint32_t *out_h);
void    pmux_gl_destroy(pmux_handle *dso);

/* GL direct render: renders frame in the caller's current GL context. */
int32_t pmux_gl_direct_render(pmux_handle *dso, uint8_t stream, uint32_t timeout);

/* Destroy GL render state for a stream (call before switching to PollFrame) */
void pmux_gl_stream_destroy(pmux_handle *dso, uint8_t stream);

/* ── Audio ─────────────────────────────────────────────────── */

typedef void (*pmux_audio_cb)(const int16_t *pcm, uint32_t frames, void *opaque);
int32_t pmux_poll_audio(pmux_handle *dso, pmux_audio_cb callback,
                        uint32_t timeout, void *opaque);

/* ── Events ────────────────────────────────────────────────── */

bool pmux_poll_events(pmux_handle *dso, uint32_t timeout, ParsecClientEvent *out);
void *pmux_get_buffer(pmux_handle *dso, uint32_t key);
void  pmux_free_buffer(pmux_handle *dso, void *buf);

/* ── Log ───────────────────────────────────────────────────── */

typedef void (*pmux_log_cb)(ParsecLogLevel level, const char *msg, void *opaque);
void pmux_set_log_callback(pmux_handle *dso, pmux_log_cb callback, void *opaque);
