/*
 * pmux-viewer — tmux-style multi-session Parsec client.
 *
 * Single window, single GL context. Grid mode renders each session
 * sequentially to the back buffer, captures via glCopyTexSubImage2D
 * (with glFinish to ensure GPU completion), then composites as quads.
 *
 * Usage: pmux-viewer [--grid] <sessions_file>
 *        PARSEC_SESSION_ID env var required.
 *
 * Cmd+Shift+1-7=slot 8/9=prev/next S=swap G=grid F=single Cmd+Q=quit
 */

#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <signal.h>

#include "sdk/parsec-dso.h"

#define SDL_MAIN_HANDLED
#include <SDL2/SDL.h>
#define GL_SILENCE_DEPRECATION
#include <OpenGL/gl.h>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreText/CoreText.h>

#define MSG_CLIPBOARD       7
#define MAX_SESSIONS        9
#define GRID_MAX            4
#define SDK_PATH            "sdk/libparsec.dylib"

enum health_state { HEALTH_OK=0, HEALTH_DEGRADED, HEALTH_BAD, HEALTH_LOST };
enum view_mode    { MODE_SINGLE=0, MODE_GRID };

#define RECONNECT_DELAY_MS  3000
#define HEALTH_CHECK_MS     1000
#define NETWORK_FAIL_MAX    5
#define STAGGER_DELAY_MS    2500

struct session { char peer_id[64]; char name[64]; int slot; };

struct conn_health {
    enum health_state state;
    float latency, bitrate;
    uint32_t queued_frames;
    int net_fail_count;
    uint32_t last_check, lost_at;
    int retries;
    bool reconnecting;
};

struct viewer {
    ParsecDSO        *parsec[MAX_SESSIONS];
    bool              connected[MAX_SESSIONS];
    struct conn_health health[MAX_SESSIONS];

    struct session    sessions[MAX_SESSIONS];
    int               session_count;
    int               active;

    enum view_mode    mode;
    int               grid_idx[GRID_MAX];  /* session indices in grid */
    int               grid_count;

    /* Grid: per-slot frame data captured via ParsecClientPollFrame */
    unsigned int      grid_tex[GRID_MAX];
    bool              grid_tex_ready;
    uint8_t          *grid_pixels[GRID_MAX];    /* RGBA pixel buffers */
    int               grid_frame_w[GRID_MAX];
    int               grid_frame_h[GRID_MAX];
    bool              grid_frame_dirty[GRID_MAX];

    char              session_id[128];

    SDL_Window       *window;
    SDL_Surface      *cursor_surface;
    SDL_Cursor       *cursor;
    SDL_AudioDeviceID audio;

    float             scale;
    int               win_w, win_h, gl_w, gl_h;

    bool              show_debug;
    uint32_t          frame_count;
    uint32_t          fps_last_tick;
    float             fps;

    /* Session picker (Cmd+Shift+S) */
    bool              picker_open;
    int               picker_cursor;   /* highlighted index into sessions[] */
    char              picker_filter[64];
    int               picker_filter_len;

    bool              done;
};

/* (system font rendering via CoreText/CoreGraphics below) */

static volatile bool g_quit = false;
static void signal_handler(int sig) { (void)sig; g_quit = true; }

/* ── GL function pointer types ─────────────────────────────── */
typedef void (*GLvoid_f)(void);
typedef void (*GL1u_f)(unsigned int);
typedef void (*GL2u_f)(unsigned int, unsigned int);
typedef void (*GL4f_f)(float, float, float, float);
typedef void (*GL4i_f)(int, int, int, int);
typedef void (*GL1i_u_f)(int, unsigned int *);

/* ── callbacks ─────────────────────────────────────────────── */

static void log_cb(ParsecLogLevel level, const char *msg, void *opaque)
{ (void)opaque; printf("[%s] %s\n", level == LOG_DEBUG ? "D" : "I", msg); }

static void audio_cb(const int16_t *pcm, uint32_t frames, void *opaque)
{
    struct viewer *v = (struct viewer *)opaque;
    if (SDL_GetQueuedAudioSize(v->audio) < 20000)
        SDL_QueueAudio(v->audio, (const void *)pcm, frames * 2 * sizeof(int16_t));
}

static void handle_cursor(struct viewer *v, ParsecCursor *cur, uint32_t key)
{
    int a = v->active;
    if (a < 0) return;
    if (cur->imageUpdate) {
        uint8_t *img = ParsecGetBuffer(v->parsec[a], key);
        if (img) {
            SDL_Surface *s = SDL_CreateRGBSurfaceFrom(img, cur->width, cur->height,
                32, cur->width * 4, 0xff, 0xff00, 0xff0000, 0xff000000);
            SDL_Cursor *c = SDL_CreateColorCursor(s, cur->hotX, cur->hotY);
            SDL_SetCursor(c);
            SDL_FreeCursor(v->cursor); v->cursor = c;
            SDL_FreeSurface(v->cursor_surface); v->cursor_surface = s;
            ParsecFree(v->parsec[a], img);
        }
    }
    if (SDL_GetRelativeMouseMode() && !cur->relative)
        SDL_SetRelativeMouseMode(SDL_DISABLE);
    else if (!SDL_GetRelativeMouseMode() && cur->relative)
        SDL_SetRelativeMouseMode(SDL_ENABLE);
}

/* ── title / health ────────────────────────────────────────── */

static const char *health_icon(int s) {
    return s==HEALTH_OK?"=":s==HEALTH_DEGRADED?"~":s==HEALTH_BAD?"!":"X";
}

static void update_dimensions(struct viewer *v, int idx);

static void update_title(struct viewer *v)
{
    char title[512], slots[256]="";
    int off=0;
    for (int i=0; i<v->session_count; i++) {
        const char *m=" ";
        if (i==v->active) m=v->connected[i]?">":"x";
        else if (v->connected[i]) m="+";
        off+=snprintf(slots+off, sizeof(slots)-off, " [%d]%s%s",
            v->sessions[i].slot, m, v->sessions[i].name);
    }
    int a=v->active;
    const char *ms=v->mode==MODE_GRID?"GRID":"1x1";
    if (a>=0 && v->connected[a]) {
        struct conn_health *h=&v->health[a];
        char q[64]="";
        if (h->latency>0) snprintf(q,64," [%s %.0fms %.1fMbps]",
            health_icon(h->state), h->latency, h->bitrate);
        snprintf(title,512,"pmux %s | %s%s |%s",ms,v->sessions[a].name,q,slots);
    } else snprintf(title,512,"pmux %s | disconnected |%s",ms,slots);
    SDL_SetWindowTitle(v->window, title);
}

static void check_health(struct viewer *v)
{
    uint32_t now=SDL_GetTicks();
    for (int gi=0; gi<(v->mode==MODE_GRID?v->grid_count:1); gi++) {
        int i=(v->mode==MODE_GRID)?v->grid_idx[gi]:v->active;
        if (i<0) continue;
        struct conn_health *h=&v->health[i];
        if (!v->connected[i]) {
            if (h->lost_at>0 && !h->reconnecting) {
                uint32_t delay=RECONNECT_DELAY_MS*(1u<<(h->retries>4?4:h->retries));
                if ((now-h->lost_at)>delay) {
                    h->reconnecting=true; h->retries++;
                    printf("[pmux] Reconnecting %s (#%d)...\n",v->sessions[i].name,h->retries);
                    if (ParsecClientConnect(v->parsec[i],NULL,v->session_id,v->sessions[i].peer_id)==PARSEC_OK) {
                        v->connected[i]=true; h->state=HEALTH_OK; h->net_fail_count=0;
                        h->lost_at=0; h->retries=0; h->reconnecting=false;
                        update_dimensions(v,i);
                    } else { h->lost_at=now; h->reconnecting=false; }
                    update_title(v);
                }
            }
            continue;
        }
        if ((now-h->last_check)<HEALTH_CHECK_MS) continue;
        h->last_check=now;
        ParsecClientStatus st;
        ParsecStatus cs=ParsecClientGetStatus(v->parsec[i],&st);
        if (cs==PARSEC_CONNECTING) continue;
        if (cs<0) { v->connected[i]=false; h->state=HEALTH_LOST; h->lost_at=now;
            printf("[pmux] Lost %s (%d)\n",v->sessions[i].name,cs); update_title(v); continue; }
        ParsecMetrics *m=&st.self.metrics[0];
        h->latency=m->networkLatency; h->bitrate=m->bitrate; h->queued_frames=m->queuedFrames;
        if (st.networkFailure) h->net_fail_count++; else h->net_fail_count=0;
        if (h->net_fail_count>=NETWORK_FAIL_MAX) {
            h->state=HEALTH_LOST; ParsecClientDisconnect(v->parsec[i]);
            v->connected[i]=false; h->lost_at=now; h->net_fail_count=0;
        } else if (h->latency>150||h->queued_frames>10) h->state=HEALTH_BAD;
        else if (h->latency>60||h->queued_frames>3) h->state=HEALTH_DEGRADED;
        else h->state=HEALTH_OK;
        if (i==v->active) update_title(v);
    }
}

/* ── connection management ─────────────────────────────────── */

static void update_dimensions(struct viewer *v, int idx)
{
    if (idx<0 || !v->connected[idx]) return;
    if (v->mode==MODE_GRID) {
        ParsecClientSetDimensions(v->parsec[idx], 0, v->win_w/2, v->win_h/2, v->scale);
    } else {
        ParsecClientSetDimensions(v->parsec[idx], 0, v->win_w, v->win_h, v->scale);
    }
}

static void connect_session(struct viewer *v, int idx)
{
    if (idx<0||idx>=v->session_count||v->connected[idx]) return;
    printf("[pmux] Connecting to %s...\n", v->sessions[idx].name);
    ParsecStatus e=ParsecClientConnect(v->parsec[idx],NULL,v->session_id,v->sessions[idx].peer_id);
    if (e==PARSEC_OK) {
        v->connected[idx]=true; v->health[idx]=(struct conn_health){0};
        update_dimensions(v,idx);
        ParsecClientEnableStream(v->parsec[idx],1,true);
        printf("[pmux] Connected to %s\n",v->sessions[idx].name);
    } else printf("[pmux] Connect %s failed: %d\n",v->sessions[idx].name,e);
}

static void disconnect_session(struct viewer *v, int idx)
{
    if (idx<0||idx>=v->session_count||!v->connected[idx]) return;
    ParsecClientDisconnect(v->parsec[idx]);
    v->connected[idx]=false; v->health[idx]=(struct conn_health){0};
    printf("[pmux] Disconnected %s\n",v->sessions[idx].name);
}

static void disconnect_all(struct viewer *v)
{ for (int i=0;i<v->session_count;i++) disconnect_session(v,i); }

/* ── mode switching ────────────────────────────────────────── */

static void enter_grid_mode(struct viewer *v)
{
    if (v->mode==MODE_GRID) return;
    v->mode=MODE_GRID;
    int start=v->active>=0?v->active:0;
    v->grid_count=0;
    for (int i=0; i<v->session_count && v->grid_count<GRID_MAX; i++)
        v->grid_idx[v->grid_count++]=(start+i)%v->session_count;

    /* All sessions already connected (KVM style) — no disconnect/reconnect needed */
    if (v->active<0 && v->grid_count>0) v->active=v->grid_idx[0];
    printf("[pmux] Grid mode: %d sessions\n", v->grid_count);
    update_title(v);
}

static void enter_single_mode(struct viewer *v)
{
    if (v->mode==MODE_SINGLE) return;
    /* KVM: keep all sessions connected, just switch render target */
    v->mode=MODE_SINGLE;
    update_dimensions(v, v->active);
    printf("[pmux] Single mode: %s\n", v->active>=0?v->sessions[v->active].name:"none");
    update_title(v);
}

static void toggle_grid(struct viewer *v) {
    if (v->mode==MODE_SINGLE) enter_grid_mode(v); else enter_single_mode(v);
}

/* ── session switching ─────────────────────────────────────── */

static void switch_to(struct viewer *v, int idx)
{
    if (idx<0||idx>=v->session_count) return;
    if (idx==v->active && v->connected[idx]) return;

    /* KVM: all sessions stay connected, just change which one renders/gets input */
    SDL_ClearQueuedAudio(v->audio);
    SDL_SetRelativeMouseMode(SDL_DISABLE);
    v->active=idx;

    /* Connect if not already (e.g. first time selecting this session) */
    if (!v->connected[idx]) connect_session(v,idx);

    /* Update dimensions for the newly active session */
    update_dimensions(v,idx);

    printf("[pmux] Focus -> %s\n",v->sessions[idx].name);
    update_title(v);
}

static void switch_slot(struct viewer *v, int slot) {
    for (int i=0;i<v->session_count;i++) if (v->sessions[i].slot==slot) { switch_to(v,i); return; }
}
static void switch_prev(struct viewer *v) {
    if (!v->session_count) return;
    switch_to(v, ((v->active<0?0:v->active)-1+v->session_count)%v->session_count);
}
static void switch_next(struct viewer *v) {
    if (!v->session_count) return;
    switch_to(v, ((v->active<0?-1:v->active)+1)%v->session_count);
}

static void open_picker(struct viewer *v)
{
    v->picker_open = true;
    v->picker_cursor = v->active >= 0 ? v->active : 0;
    v->picker_filter_len = 0;
    v->picker_filter[0] = 0;
}

static void close_picker(struct viewer *v)
{
    v->picker_open = false;
    v->picker_filter_len = 0;
    v->picker_filter[0] = 0;
}

/* Get the nth visible (filter-matched) session index */
static int picker_nth_visible(struct viewer *v, int n)
{
    int count = 0;
    for (int i = 0; i < v->session_count; i++) {
        if (v->picker_filter_len > 0) {
            bool match = false;
            for (int j = 0; v->sessions[i].name[j]; j++) {
                bool found = true;
                for (int k = 0; k < v->picker_filter_len && found; k++) {
                    char a = v->sessions[i].name[j+k];
                    char b = v->picker_filter[k];
                    if (a >= 'A' && a <= 'Z') a += 32;
                    if (b >= 'A' && b <= 'Z') b += 32;
                    if (a != b) found = false;
                }
                if (found) { match = true; break; }
            }
            if (!match) continue;
        }
        if (count == n) return i;
        count++;
    }
    return -1;
}

static void picker_confirm(struct viewer *v)
{
    int idx = v->picker_cursor;
    if (idx < 0 || idx >= v->session_count) { close_picker(v); return; }

    if (v->mode == MODE_GRID) {
        /* Replace the focused grid slot with the selected session */
        for (int gi = 0; gi < v->grid_count; gi++) {
            if (v->grid_idx[gi] == v->active) {
                disconnect_session(v, v->active);
                SDL_Delay(300);
                v->grid_idx[gi] = idx;
                v->active = idx;
                connect_session(v, idx);
                printf("[pmux] Swapped to %s\n", v->sessions[idx].name);
                update_title(v);
                break;
            }
        }
    } else {
        switch_to(v, idx);
    }
    close_picker(v);
}

/* ── config parsing ────────────────────────────────────────── */

static int load_sessions(const char *path, struct session *sessions)
{
    FILE *f=fopen(path,"r");
    if (!f) { fprintf(stderr,"Cannot open: %s\n",path); return 0; }
    int count=0; char line[256];
    while (count<MAX_SESSIONS && fgets(line,sizeof(line),f)) {
        char *nl=strchr(line,'\n'); if (nl) *nl=0;
        if (line[0]=='#'||line[0]==0) continue;
        int slot=0; char pid[64]="",name[64]="";
        if (sscanf(line,"%d\t%63s\t%63[^\n]",&slot,pid,name)>=3) {
            sessions[count].slot=slot;
            strncpy(sessions[count].peer_id,pid,63);
            strncpy(sessions[count].name,name,63);
            count++;
        }
    }
    fclose(f);
    return count;
}

/* ── debug overlay: system font via CoreText + CoreGraphics ── */

/* Cached debug label textures — re-rendered at 1Hz, not every frame */
static GLuint g_debug_textures[GRID_MAX + 1]; /* +1 for single mode */
static int    g_debug_tex_w[GRID_MAX + 1];
static int    g_debug_tex_h[GRID_MAX + 1];
static uint32_t g_debug_last_render = 0;

static void render_label_texture(GLuint *tex, int tw, int th, const char *text, float font_size)
{
    if (tw < 10 || th < 5) return;

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    uint8_t *px = (uint8_t *)calloc(tw * th, 4);
    CGContextRef cg = CGBitmapContextCreate(px, tw, th, 8, tw * 4,
        cs, kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (!cg) { free(px); return; }

    CGContextSetRGBFillColor(cg, 0, 0, 0, 0.7);
    CGContextFillRect(cg, CGRectMake(0, 0, tw, th));

    CFStringRef cfstr = CFStringCreateWithCString(NULL, text, kCFStringEncodingUTF8);
    CTFontRef font = CTFontCreateWithName(CFSTR("Menlo"), font_size, NULL);
    CGFloat white[] = {1,1,1,1};
    CGColorSpaceRef wcs = CGColorSpaceCreateDeviceRGB();
    CGColorRef color = CGColorCreate(wcs, white);
    CGColorSpaceRelease(wcs);

    const void *keys[] = { kCTFontAttributeName, kCTForegroundColorAttributeName };
    const void *vals[] = { font, color };
    CFDictionaryRef attrs = CFDictionaryCreate(NULL, keys, vals, 2,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFAttributedStringRef astr = CFAttributedStringCreate(NULL, cfstr, attrs);
    CTLineRef line = CTLineCreateWithAttributedString(astr);

    CGContextSetTextPosition(cg, 8, (th - font_size) / 2 + 2);
    CTLineDraw(line, cg);

    CFRelease(line); CFRelease(astr); CFRelease(attrs);
    CGColorRelease(color); CFRelease(font); CFRelease(cfstr);

    if (*tex == 0) glGenTextures(1, tex);
    glBindTexture(GL_TEXTURE_2D, *tex);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, tw, th, 0, GL_RGBA, GL_UNSIGNED_BYTE, px);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glBindTexture(GL_TEXTURE_2D, 0);

    CGContextRelease(cg);
    free(px);
}

static void draw_cached_label(GLuint tex, float x0, float y0, float x1, float y1)
{
    if (!tex) return;
    glBindTexture(GL_TEXTURE_2D, tex);
    glColor4f(1,1,1,1);
    glBegin(GL_QUADS);
    glTexCoord2f(0,1); glVertex2f(x0,y0);
    glTexCoord2f(1,1); glVertex2f(x1,y0);
    glTexCoord2f(1,0); glVertex2f(x1,y1);
    glTexCoord2f(0,0); glVertex2f(x0,y1);
    glEnd();
    glBindTexture(GL_TEXTURE_2D, 0);
}

/* Render a multi-line text block to a GL texture via CoreText */
static void draw_text_block(const char *text, float x0, float y0, float x1, float y1,
    float font_size, float r, float g, float b, float bg_a)
{
    int tw = (int)(x1 - x0);
    int th = (int)(y1 - y0);
    if (tw < 10 || th < 5) return;

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    uint8_t *px = (uint8_t *)calloc(tw * th, 4);
    CGContextRef cg = CGBitmapContextCreate(px, tw, th, 8, tw * 4,
        cs, kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (!cg) { free(px); return; }

    CGContextSetRGBFillColor(cg, 0, 0, 0, bg_a);
    CGContextFillRect(cg, CGRectMake(0, 0, tw, th));

    /* Draw each line */
    CTFontRef font = CTFontCreateWithName(CFSTR("Menlo"), font_size, NULL);
    const char *p = text;
    float line_y = th - font_size - 8;

    while (*p && line_y > 0) {
        const char *nl = strchr(p, '\n');
        int len = nl ? (int)(nl - p) : (int)strlen(p);

        CFStringRef line_str = CFStringCreateWithBytes(NULL, (const uint8_t *)p, len,
            kCFStringEncodingUTF8, false);

        CGFloat clr[] = {r, g, b, 1};
        CGColorRef color = CGColorCreate(CGColorSpaceCreateDeviceRGB(), clr);
        const void *keys[] = { kCTFontAttributeName, kCTForegroundColorAttributeName };
        const void *vals[] = { font, color };
        CFDictionaryRef attrs = CFDictionaryCreate(NULL, keys, vals, 2,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFAttributedStringRef astr = CFAttributedStringCreate(NULL, line_str, attrs);
        CTLineRef ct_line = CTLineCreateWithAttributedString(astr);

        CGContextSetTextPosition(cg, 12, line_y);
        CTLineDraw(ct_line, cg);

        CFRelease(ct_line); CFRelease(astr); CFRelease(attrs);
        CGColorRelease(color); CFRelease(line_str);

        line_y -= font_size + 4;
        p = nl ? nl + 1 : p + len;
    }
    CFRelease(font);

    GLuint tex;
    glGenTextures(1, &tex);
    glBindTexture(GL_TEXTURE_2D, tex);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, tw, th, 0, GL_RGBA, GL_UNSIGNED_BYTE, px);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    CGContextRelease(cg);
    free(px);

    glColor4f(1, 1, 1, 1);
    glBegin(GL_QUADS);
    glTexCoord2f(0, 1); glVertex2f(x0, y0);
    glTexCoord2f(1, 1); glVertex2f(x1, y0);
    glTexCoord2f(1, 0); glVertex2f(x1, y1);
    glTexCoord2f(0, 0); glVertex2f(x0, y1);
    glEnd();
    glBindTexture(GL_TEXTURE_2D, 0);
    glDeleteTextures(1, &tex);
}

/* ── PollFrame callback for grid mode ──────────────────────── */

struct frame_ctx {
    struct viewer *v;
    int grid_slot;
};

static inline uint8_t clamp8(int x) { return x < 0 ? 0 : x > 255 ? 255 : (uint8_t)x; }

static void grid_frame_cb(const ParsecFrame *frame, const void *image, void *opaque)
{
    struct frame_ctx *ctx = (struct frame_ctx *)opaque;
    struct viewer *v = ctx->v;
    int gi = ctx->grid_slot;
    int w = frame->width, h = frame->height;
    int fw = frame->fullWidth;  /* stride (may have padding) */
    int fh = frame->fullHeight;

    /* Log format on first frame */
    static bool fmt_logged[GRID_MAX] = {0};
    if (!fmt_logged[gi]) {
        printf("[pmux] Grid %d frame: %dx%d (full %dx%d) format=%d\n",
            gi, w, h, fw, fh, frame->format);
        fmt_logged[gi] = true;
    }

    /* Allocate/resize RGBA buffer */
    int rgba_size = w * h * 4;
    if (!v->grid_pixels[gi] || v->grid_frame_w[gi] != w || v->grid_frame_h[gi] != h) {
        free(v->grid_pixels[gi]);
        v->grid_pixels[gi] = (uint8_t *)malloc(rgba_size);
        v->grid_frame_w[gi] = w;
        v->grid_frame_h[gi] = h;
    }

    uint8_t *dst = v->grid_pixels[gi];
    const uint8_t *src = (const uint8_t *)image;

    if (frame->format == 5 /* FORMAT_BGRA */) {
        /* Row-by-row copy to handle stride padding, flip Y for GL */
        for (int row = 0; row < h; row++) {
            int src_row = row;
            int dst_row = h - 1 - row;  /* flip for GL Y-up */
            const uint8_t *sp = src + src_row * fw * 4;
            uint8_t *dp = dst + dst_row * w * 4;
            for (int col = 0; col < w; col++) {
                dp[col*4+0] = sp[col*4+2];
                dp[col*4+1] = sp[col*4+1];
                dp[col*4+2] = sp[col*4+0];
                dp[col*4+3] = 255;
            }
        }
    } else if (frame->format == 6 /* FORMAT_RGBA */) {
        for (int row = 0; row < h; row++) {
            int dst_row = h - 1 - row;
            memcpy(dst + dst_row * w * 4, src + row * fw * 4, w * 4);
        }
    } else if (frame->format == 1 /* FORMAT_NV12 */) {
        /* NV12: Y plane (fullWidth * fullHeight) then UV interleaved (fullWidth * fullHeight/2) */
        const uint8_t *y_plane = src;
        const uint8_t *uv_plane = src + fw * frame->fullHeight;
        for (int row = 0; row < h; row++) {
            int dst_row = h - 1 - row;  /* flip Y */
            for (int col = 0; col < w; col++) {
                int Y  = y_plane[row * fw + col];
                int Cb = uv_plane[(row/2) * fw + (col & ~1)] - 128;     /* U */
                int Cr = uv_plane[(row/2) * fw + (col | 1)] - 128;      /* V */
                int pi = (dst_row * w + col) * 4;
                dst[pi+0] = clamp8(Y + (int)(1.402f * Cr));
                dst[pi+1] = clamp8(Y - (int)(0.344f * Cb) - (int)(0.714f * Cr));
                dst[pi+2] = clamp8(Y + (int)(1.772f * Cb));
                dst[pi+3] = 255;
            }
        }
    } else {
        for (int i = 0; i < w * h; i++) {
            dst[i*4+0] = 255; dst[i*4+1] = 0; dst[i*4+2] = 255; dst[i*4+3] = 255;
        }
    }

    v->grid_frame_dirty[gi] = true;
}

/* ── render thread ─────────────────────────────────────────── */

static int32_t render_thread(void *opaque)
{
    struct viewer *v=(struct viewer *)opaque;
    SDL_GLContext gl=SDL_GL_CreateContext(v->window);
    SDL_GL_SetSwapInterval(-1);

    GL4f_f  glClearColor_ = (GL4f_f)SDL_GL_GetProcAddress("glClearColor");
    GL1u_f  glClear_      = (GL1u_f)SDL_GL_GetProcAddress("glClear");
    GLvoid_f glFinish_    = (GLvoid_f)SDL_GL_GetProcAddress("glFinish");
    GL4i_f  glViewport_   = (GL4i_f)SDL_GL_GetProcAddress("glViewport");
    GL1u_f  glEnable_     = (GL1u_f)SDL_GL_GetProcAddress("glEnable");
    GL1u_f  glDisable_    = (GL1u_f)SDL_GL_GetProcAddress("glDisable");

    /* Extension functions not in base OpenGL framework */
    void (*glUseProgram_)(unsigned)=(void(*)(unsigned))SDL_GL_GetProcAddress("glUseProgram");

    while (!v->done && !g_quit) {
        int gw=v->gl_w, gh=v->gl_h;

        if (v->mode==MODE_GRID && v->grid_count>1) {
            int qw=gw/2, qh=gh/2;

            /* Init grid textures once */
            if (!v->grid_tex_ready) {
                glGenTextures(GRID_MAX, v->grid_tex);
                for (int i=0;i<GRID_MAX;i++) {
                    glBindTexture(GL_TEXTURE_2D, v->grid_tex[i]);
                    glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA,4,4,0,GL_RGBA,GL_UNSIGNED_BYTE,NULL);
                    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_LINEAR);
                    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_LINEAR);
                    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_S,GL_CLAMP_TO_EDGE);
                    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_T,GL_CLAMP_TO_EDGE);
                }
                glBindTexture(GL_TEXTURE_2D,0);
                v->grid_tex_ready=true;
            }

            /* Poll raw frames via PollFrame and upload to textures */
            for (int gi=0; gi<v->grid_count && gi<GRID_MAX; gi++) {
                int idx=v->grid_idx[gi];
                if (idx>=0 && v->connected[idx]) {
                    struct frame_ctx fctx = { v, gi };
                    ParsecClientPollFrame(v->parsec[idx], 0, grid_frame_cb, 0, &fctx);
                }
                /* Upload dirty pixels to GL texture */
                if (v->grid_frame_dirty[gi] && v->grid_pixels[gi]) {
                    glBindTexture(GL_TEXTURE_2D, v->grid_tex[gi]);
                    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA,
                        v->grid_frame_w[gi], v->grid_frame_h[gi],
                        0, GL_RGBA, GL_UNSIGNED_BYTE, v->grid_pixels[gi]);
                    glBindTexture(GL_TEXTURE_2D, 0);
                    v->grid_frame_dirty[gi] = false;
                }
            }

            /* Composite textures as 2x2 grid */
            glViewport_(0, 0, gw, gh);
            glUseProgram_(0);
            glDisable_(GL_DEPTH_TEST);

            glClearColor_(0.06f,0.06f,0.10f,1.0f);
            glClear_(GL_COLOR_BUFFER_BIT);

            glMatrixMode(GL_PROJECTION); glLoadIdentity();
            glOrtho(0, gw, 0, gh, -1, 1);
            glMatrixMode(GL_MODELVIEW); glLoadIdentity();

            glEnable_(GL_TEXTURE_2D);
            glActiveTexture(GL_TEXTURE0);

            for (int gi=0; gi<v->grid_count && gi<GRID_MAX; gi++) {
                int col=gi%2, row=gi/2;
                float x0=col*qw, y0=(1-row)*qh;
                float x1=x0+qw, y1=y0+qh;

                glBindTexture(GL_TEXTURE_2D, v->grid_tex[gi]);
                glColor4f(1,1,1,1);
                glBegin(GL_QUADS);
                glTexCoord2f(0,0); glVertex2f(x0,y0);
                glTexCoord2f(1,0); glVertex2f(x1,y0);
                glTexCoord2f(1,1); glVertex2f(x1,y1);
                glTexCoord2f(0,1); glVertex2f(x0,y1);
                glEnd();

                /* Dim inactive quadrants */
                int idx=v->grid_idx[gi];
                if (idx!=v->active) {
                    glEnable_(GL_BLEND);
                    glBlendFunc(GL_SRC_ALPHA,GL_ONE_MINUS_SRC_ALPHA);
                    glBindTexture(GL_TEXTURE_2D,0);
                    glColor4f(0,0,0,0.3f);
                    glBegin(GL_QUADS);
                    glVertex2f(x0,y0); glVertex2f(x1,y0);
                    glVertex2f(x1,y1); glVertex2f(x0,y1);
                    glEnd();
                    glDisable_(GL_BLEND);
                }
            }

            /* Focus border */
            int fgi=-1;
            for (int gi=0;gi<v->grid_count;gi++)
                if (v->grid_idx[gi]==v->active) { fgi=gi; break; }
            if (fgi>=0) {
                int col=fgi%2, row=fgi/2;
                float x0=col*qw, y0=(1-row)*qh;
                float x1=x0+qw, y1=y0+qh;
                float t=3.0f*v->scale;

                glEnable_(GL_BLEND);
                glBlendFunc(GL_SRC_ALPHA,GL_ONE_MINUS_SRC_ALPHA);
                glBindTexture(GL_TEXTURE_2D,0);
                glColor4f(0.2f,0.7f,1.0f,0.85f);
                glBegin(GL_QUADS);
                glVertex2f(x0,y0);   glVertex2f(x1,y0);
                glVertex2f(x1,y0+t); glVertex2f(x0,y0+t);
                glVertex2f(x0,y1-t); glVertex2f(x1,y1-t);
                glVertex2f(x1,y1);   glVertex2f(x0,y1);
                glVertex2f(x0,y0);   glVertex2f(x0+t,y0);
                glVertex2f(x0+t,y1); glVertex2f(x0,y1);
                glVertex2f(x1-t,y0); glVertex2f(x1,y0);
                glVertex2f(x1,y1);   glVertex2f(x1-t,y1);
                glEnd();
                glDisable_(GL_BLEND);
            }

            glDisable_(GL_TEXTURE_2D);
        } else {
            /* Single mode */
            glViewport_(0, 0, gw, gh);
            int a=v->active;
            if (a>=0 && v->connected[a]) {
                /* Keep SetDimensions in sync with actual window size */
                ParsecClientSetDimensions(v->parsec[a], 0, v->win_w, v->win_h, v->scale);
                ParsecClientGLRenderFrame(v->parsec[a], 0, NULL, NULL, 100);
            } else {
                glClearColor_(0.06f,0.06f,0.10f,1.0f);
                glClear_(GL_COLOR_BUFFER_BIT);
            }
        }

        /* ── Debug overlay (Cmd+Shift+D) ────────────────── */
        if (v->show_debug) {
            v->frame_count++;
            uint32_t now_t = SDL_GetTicks();
            if (now_t - v->fps_last_tick >= 1000) {
                v->fps = v->frame_count * 1000.0f / (now_t - v->fps_last_tick);
                v->frame_count = 0;
                v->fps_last_tick = now_t;
            }

            /* Re-render label textures at ~2Hz (not every frame) */
            bool need_render = (now_t - g_debug_last_render) > 500;

            glUseProgram_(0);
            glViewport_(0, 0, gw, gh);
            glMatrixMode(GL_PROJECTION); glLoadIdentity();
            glOrtho(0, gw, 0, gh, -1, 1);
            glMatrixMode(GL_MODELVIEW); glLoadIdentity();
            glEnable_(GL_BLEND);
            glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
            glEnable_(GL_TEXTURE_2D);

            float fs = 11.0f * v->scale;
            int label_tw = (int)(320 * v->scale);
            int label_th = (int)((fs + 8 * v->scale));
            float pad = 6 * v->scale;

            if (v->mode == MODE_GRID && v->grid_count > 1) {
                int qw = gw/2, qh = gh/2;
                for (int gi = 0; gi < v->grid_count && gi < GRID_MAX; gi++) {
                    int idx = v->grid_idx[gi];
                    int col = gi%2, row = gi/2;
                    float ox = col * qw, oy = (1-row) * qh;

                    if (need_render) {
                        struct conn_health *h = (idx>=0) ? &v->health[idx] : NULL;
                        char buf[128];
                        if (h && v->connected[idx])
                            snprintf(buf, sizeof(buf), "%s  %.0f FPS  %.1f Mbps  %.0fms",
                                v->sessions[idx].name, v->fps, h->bitrate, h->latency);
                        else
                            snprintf(buf, sizeof(buf), "%s  disconnected",
                                idx>=0 ? v->sessions[idx].name : "---");
                        g_debug_tex_w[gi] = label_tw;
                        g_debug_tex_h[gi] = label_th;
                        render_label_texture(&g_debug_textures[gi], label_tw, label_th, buf, fs);
                    }

                    float x1 = ox + qw - pad;
                    float x0 = x1 - label_tw;
                    float y1 = oy + qh - pad;
                    float y0 = y1 - label_th;
                    draw_cached_label(g_debug_textures[gi], x0, y0, x1, y1);
                }
            } else {
                if (need_render) {
                    int a = v->active;
                    struct conn_health *h = (a>=0) ? &v->health[a] : NULL;
                    char buf[128];
                    if (h && a>=0 && v->connected[a])
                        snprintf(buf, sizeof(buf), "%s  %.0f FPS  %.1f Mbps  %.0fms",
                            v->sessions[a].name, v->fps, h->bitrate, h->latency);
                    else
                        snprintf(buf, sizeof(buf), "disconnected");
                    g_debug_tex_w[GRID_MAX] = label_tw;
                    g_debug_tex_h[GRID_MAX] = label_th;
                    render_label_texture(&g_debug_textures[GRID_MAX], label_tw, label_th, buf, fs);
                }

                float x1 = gw - pad;
                float x0 = x1 - label_tw;
                float y1 = gh - pad;
                float y0 = y1 - label_th;
                draw_cached_label(g_debug_textures[GRID_MAX], x0, y0, x1, y1);
            }

            if (need_render) g_debug_last_render = now_t;

            glDisable_(GL_BLEND);
            glDisable_(GL_TEXTURE_2D);
        }

        /* ── Session picker overlay ─────────────────────── */
        if (v->picker_open) {
            glUseProgram_(0);
            glViewport_(0, 0, gw, gh);
            glMatrixMode(GL_PROJECTION); glLoadIdentity();
            glOrtho(0, gw, 0, gh, -1, 1);
            glMatrixMode(GL_MODELVIEW); glLoadIdentity();
            glEnable_(GL_BLEND);
            glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
            glEnable_(GL_TEXTURE_2D);

            /* Build picker text */
            char picker_buf[2048] = "";
            int off = 0;
            float fs = 13.0f * v->scale;

            if (v->picker_filter_len > 0)
                off += snprintf(picker_buf + off, sizeof(picker_buf) - off,
                    "Search: %s\n\n", v->picker_filter);
            else
                off += snprintf(picker_buf + off, sizeof(picker_buf) - off,
                    "Select session (arrows + enter, esc to cancel):\n\n");

            int visible_count = 0;
            for (int i = 0; i < v->session_count; i++) {
                /* Filter by search string */
                if (v->picker_filter_len > 0) {
                    bool match = false;
                    /* Case-insensitive substring match */
                    for (int j = 0; v->sessions[i].name[j]; j++) {
                        bool found = true;
                        for (int k = 0; k < v->picker_filter_len && found; k++) {
                            char a = v->sessions[i].name[j+k];
                            char b = v->picker_filter[k];
                            if (a >= 'A' && a <= 'Z') a += 32;
                            if (b >= 'A' && b <= 'Z') b += 32;
                            if (a != b) found = false;
                        }
                        if (found) { match = true; break; }
                    }
                    if (!match) continue;
                }

                const char *prefix = (i == v->picker_cursor) ? " >> " : "    ";
                const char *status = v->connected[i] ? " (connected)" : "";
                off += snprintf(picker_buf + off, sizeof(picker_buf) - off,
                    "%s[%d] %s%s\n", prefix, v->sessions[i].slot,
                    v->sessions[i].name, status);
                visible_count++;
            }

            if (visible_count == 0)
                off += snprintf(picker_buf + off, sizeof(picker_buf) - off, "    (no matches)");

            /* Size and position the picker */
            float pw = 400 * v->scale;
            float ph = (visible_count + 3) * (fs + 4) + 20 * v->scale;
            if (ph > gh * 0.8f) ph = gh * 0.8f;
            float px0 = (gw - pw) / 2;
            float py0 = (gh - ph) / 2;

            draw_text_block(picker_buf, px0, py0, px0 + pw, py0 + ph,
                fs, 1, 1, 1, 0.85);

            glDisable_(GL_BLEND);
            glDisable_(GL_TEXTURE_2D);
        }

        SDL_GL_SwapWindow(v->window);
        if (v->mode!=MODE_GRID) glFinish_(); /* only in single mode */
    }

    for (int i=0;i<v->session_count;i++)
        if (v->parsec[i]) ParsecClientGLDestroy(v->parsec[i],0);
    SDL_GL_DeleteContext(gl);
    return 0;
}

static int32_t audio_thread(void *opaque)
{
    struct viewer *v=(struct viewer *)opaque;
    while (!v->done && !g_quit) {
        int a=v->active;
        if (a>=0 && v->connected[a]) ParsecClientPollAudio(v->parsec[a],audio_cb,50,v);
        else SDL_Delay(10);
    }
    return 0;
}

/* ── main ──────────────────────────────────────────────────── */

int32_t main(int32_t argc, char **argv)
{
    if (argc<2) {
        printf("Usage: pmux-viewer [--grid] <sessions_file>\n");
        printf("  PARSEC_SESSION_ID env var required.\n");
        return 1;
    }

    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);

    bool start_grid=false;
    const char *sessions_path=NULL;
    for (int i=1;i<argc;i++) {
        if (strcmp(argv[i],"--grid")==0) start_grid=true;
        else sessions_path=argv[i];
    }
    if (!sessions_path) { fprintf(stderr,"No sessions file.\n"); return 1; }

    struct viewer v={0};
    v.active=-1;

    const char *sid=getenv("PARSEC_SESSION_ID");
    if (!sid||!sid[0]) { fprintf(stderr,"PARSEC_SESSION_ID not set\n"); return 1; }
    strncpy(v.session_id,sid,sizeof(v.session_id)-1);

    v.session_count=load_sessions(sessions_path, v.sessions);
    if (v.session_count==0) { fprintf(stderr,"No sessions.\n"); return 1; }

    printf("[pmux] %d sessions loaded\n", v.session_count);
    for (int i=0;i<v.session_count;i++)
        printf("  [%d] %s\n", v.sessions[i].slot, v.sessions[i].name);

    SDL_SetHint(SDL_HINT_MOUSE_FOCUS_CLICKTHROUGH,"1");
    SDL_SetHint(SDL_HINT_VIDEO_MAC_FULLSCREEN_SPACES,"1");
    SDL_SetHint(SDL_HINT_MAC_CTRL_CLICK_EMULATE_RIGHT_CLICK,"1");
    SDL_Init(SDL_INIT_VIDEO|SDL_INIT_AUDIO|SDL_INIT_GAMECONTROLLER);

    SDL_AudioSpec want={0},have;
    want.freq=48000; want.format=AUDIO_S16; want.channels=2; want.samples=2048;
    v.audio=SDL_OpenAudioDevice(NULL,0,&want,&have,0);
    SDL_PauseAudioDevice(v.audio,0);

    SDL_Rect usable;
    SDL_GetDisplayUsableBounds(0,&usable);

    v.window=SDL_CreateWindow("pmux", usable.x, usable.y, usable.w, usable.h,
        SDL_WINDOW_OPENGL|SDL_WINDOW_RESIZABLE|SDL_WINDOW_ALLOW_HIGHDPI
        |SDL_WINDOW_FULLSCREEN_DESKTOP);

    SDL_GetWindowSize(v.window,&v.win_w,&v.win_h);
    SDL_GL_GetDrawableSize(v.window,&v.gl_w,&v.gl_h);
    v.scale=(float)v.gl_w/(float)v.win_w;

    /* Init SDK instances */
    ParsecStatus e=PARSEC_OK;
    for (int i=0;i<v.session_count;i++) {
        ParsecConfig cfg={0};
        cfg.clientPort=13000+(i*1000);
        e=ParsecInit(&cfg,NULL,SDK_PATH,&v.parsec[i]);
        if (e!=PARSEC_OK) { fprintf(stderr,"ParsecInit %d failed: %d\n",i,e); goto cleanup; }
        ParsecSetLogCallback(v.parsec[i],log_cb,NULL);
    }

    /* Start render + audio threads */
    SDL_Thread *rt=SDL_CreateThread(render_thread,"render",&v);
    SDL_Thread *at=SDL_CreateThread(audio_thread,"audio",&v);

    /* KVM: connect favorites (slot > 0) on startup, staggered */
    v.active=0;
    printf("[pmux] Connecting favorites...\n");
    for (int i=0; i<v.session_count; i++) {
        if (v.sessions[i].slot > 0) {
            connect_session(&v, i);
            SDL_Delay(STAGGER_DELAY_MS);
        }
    }

    if (start_grid)
        enter_grid_mode(&v);

    update_title(&v);

    /* Event loop */
    while (!v.done && !g_quit) {
        for (SDL_Event msg; SDL_PollEvent(&msg);) {
            ParsecMessage pmsg={0};

            /* Picker intercepts all keyboard input when open */
            if (v.picker_open && msg.type == SDL_KEYDOWN) {
                SDL_Keycode key = msg.key.keysym.sym;
                if (key == SDLK_ESCAPE) { close_picker(&v); continue; }
                if (key == SDLK_RETURN || key == SDLK_KP_ENTER) { picker_confirm(&v); continue; }
                if (key == SDLK_UP) {
                    /* Move cursor up through visible items */
                    for (int i = v.picker_cursor - 1; i >= 0; i--) {
                        if (picker_nth_visible(&v, 0) <= i || v.picker_filter_len == 0) {
                            /* Check if this index is visible */
                            bool vis = true;
                            if (v.picker_filter_len > 0) {
                                vis = false;
                                for (int j = 0; v.sessions[i].name[j]; j++) {
                                    bool found = true;
                                    for (int k = 0; k < v.picker_filter_len && found; k++) {
                                        char a = v.sessions[i].name[j+k];
                                        char b = v.picker_filter[k];
                                        if (a >= 'A' && a <= 'Z') a += 32;
                                        if (b >= 'A' && b <= 'Z') b += 32;
                                        if (a != b) found = false;
                                    }
                                    if (found) { vis = true; break; }
                                }
                            }
                            if (vis) { v.picker_cursor = i; break; }
                        }
                    }
                    continue;
                }
                if (key == SDLK_DOWN) {
                    for (int i = v.picker_cursor + 1; i < v.session_count; i++) {
                        bool vis = true;
                        if (v.picker_filter_len > 0) {
                            vis = false;
                            for (int j = 0; v.sessions[i].name[j]; j++) {
                                bool found = true;
                                for (int k = 0; k < v.picker_filter_len && found; k++) {
                                    char a = v.sessions[i].name[j+k];
                                    char b = v.picker_filter[k];
                                    if (a >= 'A' && a <= 'Z') a += 32;
                                    if (b >= 'A' && b <= 'Z') b += 32;
                                    if (a != b) found = false;
                                }
                                if (found) { vis = true; break; }
                            }
                        }
                        if (vis) { v.picker_cursor = i; break; }
                    }
                    continue;
                }
                if (key == SDLK_BACKSPACE) {
                    if (v.picker_filter_len > 0) {
                        v.picker_filter[--v.picker_filter_len] = 0;
                        /* Reset cursor to first visible */
                        int first = picker_nth_visible(&v, 0);
                        if (first >= 0) v.picker_cursor = first;
                    }
                    continue;
                }
                /* Typing to filter */
                if (key >= SDLK_a && key <= SDLK_z && v.picker_filter_len < 62) {
                    v.picker_filter[v.picker_filter_len++] = 'a' + (key - SDLK_a);
                    v.picker_filter[v.picker_filter_len] = 0;
                    int first = picker_nth_visible(&v, 0);
                    if (first >= 0) v.picker_cursor = first;
                    continue;
                }
                if (key >= SDLK_0 && key <= SDLK_9 && v.picker_filter_len < 62) {
                    v.picker_filter[v.picker_filter_len++] = '0' + (key - SDLK_0);
                    v.picker_filter[v.picker_filter_len] = 0;
                    int first = picker_nth_visible(&v, 0);
                    if (first >= 0) v.picker_cursor = first;
                    continue;
                }
                if (key == SDLK_SPACE && v.picker_filter_len < 62) {
                    v.picker_filter[v.picker_filter_len++] = ' ';
                    v.picker_filter[v.picker_filter_len] = 0;
                    continue;
                }
                if (key == SDLK_MINUS && v.picker_filter_len < 62) {
                    v.picker_filter[v.picker_filter_len++] = '-';
                    v.picker_filter[v.picker_filter_len] = 0;
                    continue;
                }
                continue; /* Eat all other keys while picker is open */
            }
            if (v.picker_open && (msg.type == SDL_KEYUP || msg.type == SDL_MOUSEMOTION ||
                msg.type == SDL_MOUSEBUTTONDOWN || msg.type == SDL_MOUSEBUTTONUP))
                continue; /* Don't forward input while picker is open */

            if (msg.type==SDL_KEYDOWN &&
                (msg.key.keysym.mod&KMOD_GUI) && (msg.key.keysym.mod&KMOD_SHIFT)) {
                SDL_Keycode key=msg.key.keysym.sym;
                if (key>=SDLK_1&&key<=SDLK_7) { switch_slot(&v,key-SDLK_1+1); continue; }
                if (key==SDLK_8) { switch_prev(&v); continue; }
                if (key==SDLK_9) { switch_next(&v); continue; }
                if (key==SDLK_BACKQUOTE) {
                    if (v.active>=0) { disconnect_session(&v,v.active); update_title(&v); } continue;
                }
                if (key==SDLK_r) {
                    if (v.active>=0&&!v.connected[v.active]) connect_session(&v,v.active); continue;
                }
                if (key==SDLK_g) { toggle_grid(&v); continue; }
                if (key==SDLK_f) { if (v.mode==MODE_GRID) enter_single_mode(&v); continue; }
                if (key==SDLK_s) { open_picker(&v); continue; }
                if (key==SDLK_d) { v.show_debug=!v.show_debug; continue; }
                /* Arrow keys navigate grid quadrants */
                if (v.mode==MODE_GRID && v.grid_count>1) {
                    int fgi=-1;
                    for (int gi=0;gi<v.grid_count;gi++)
                        if (v.grid_idx[gi]==v.active) { fgi=gi; break; }
                    if (fgi>=0) {
                        int col=fgi%2, row=fgi/2, ngi=-1;
                        if (key==SDLK_LEFT  && col>0) ngi=row*2+(col-1);
                        if (key==SDLK_RIGHT && col<1 && (row*2+col+1)<v.grid_count) ngi=row*2+(col+1);
                        if (key==SDLK_UP    && row>0) ngi=(row-1)*2+col;
                        if (key==SDLK_DOWN  && row<1 && ((row+1)*2+col)<v.grid_count) ngi=(row+1)*2+col;
                        if (ngi>=0 && ngi<v.grid_count) {
                            SDL_ClearQueuedAudio(v.audio);
                            v.active=v.grid_idx[ngi];
                            printf("[pmux] Grid -> %s\n",v.sessions[v.active].name);
                            update_title(&v);
                            continue;
                        }
                    }
                }
            }

            switch (msg.type) {
            case SDL_QUIT: v.done=true; break;
            case SDL_WINDOWEVENT:
                if (msg.window.event==SDL_WINDOWEVENT_CLOSE) { v.done=true; break; }
                if (msg.window.event==SDL_WINDOWEVENT_SIZE_CHANGED) {
                    v.win_w=msg.window.data1; v.win_h=msg.window.data2;
                    int glW; SDL_GL_GetDrawableSize(v.window,&glW,NULL);
                    v.gl_w=glW; v.gl_h=v.win_h*(glW/v.win_w);
                    v.scale=(float)v.gl_w/(float)v.win_w;
                    for (int i=0;i<v.session_count;i++) update_dimensions(&v,i);
                }
                /* Grid: click quadrant to focus */
                if (msg.window.event==SDL_WINDOWEVENT_FOCUS_GAINED && v.mode==MODE_GRID) {
                    /* handled by mouse click below */
                }
                break;
            case SDL_KEYDOWN:
            case SDL_KEYUP:
                pmsg.type=MESSAGE_KEYBOARD;
                pmsg.keyboard.code=(ParsecKeycode)msg.key.keysym.scancode;
                pmsg.keyboard.mod=msg.key.keysym.mod;
                pmsg.keyboard.pressed=msg.key.type==SDL_KEYDOWN;
                break;
            case SDL_MOUSEMOTION:
                pmsg.type=MESSAGE_MOUSE_MOTION;
                pmsg.mouseMotion.relative=SDL_GetRelativeMouseMode();
                if (pmsg.mouseMotion.relative) {
                    pmsg.mouseMotion.x=msg.motion.xrel;
                    pmsg.mouseMotion.y=msg.motion.yrel;
                } else if (v.mode==MODE_GRID && v.grid_count>1) {
                    int qw=v.win_w/2, qh=v.win_h/2;
                    pmsg.mouseMotion.x=msg.motion.x%qw;
                    pmsg.mouseMotion.y=msg.motion.y%qh;
                } else {
                    pmsg.mouseMotion.x=msg.motion.x;
                    pmsg.mouseMotion.y=msg.motion.y;
                }
                break;
            case SDL_MOUSEBUTTONDOWN:
            case SDL_MOUSEBUTTONUP:
                /* Grid: click to focus quadrant */
                if (v.mode==MODE_GRID && msg.type==SDL_MOUSEBUTTONDOWN && v.grid_count>1) {
                    int col=(msg.button.x<v.win_w/2)?0:1;
                    int row=(msg.button.y<v.win_h/2)?0:1;
                    int qi=row*2+col;
                    if (qi<v.grid_count) {
                        int nf=v.grid_idx[qi];
                        if (nf!=v.active) {
                            SDL_ClearQueuedAudio(v.audio);
                            v.active=nf;
                            printf("[pmux] Grid focus -> %s\n",v.sessions[nf].name);
                            update_title(&v);
                        }
                    }
                }
                pmsg.type=MESSAGE_MOUSE_BUTTON;
                pmsg.mouseButton.button=(ParsecMouseButton)msg.button.button;
                pmsg.mouseButton.pressed=msg.button.type==SDL_MOUSEBUTTONDOWN;
                break;
            case SDL_MOUSEWHEEL:
                pmsg.type=MESSAGE_MOUSE_WHEEL;
                pmsg.mouseWheel.x=msg.wheel.x*120;
                pmsg.mouseWheel.y=msg.wheel.y*120;
                break;
            case SDL_CLIPBOARDUPDATE:
                if (v.active>=0&&v.connected[v.active]) {
                    char *clip=SDL_GetClipboardText();
                    if (clip) { ParsecClientSendUserData(v.parsec[v.active],MSG_CLIPBOARD,clip); SDL_free(clip); }
                }
                break;
            case SDL_CONTROLLERBUTTONDOWN:
            case SDL_CONTROLLERBUTTONUP:
                pmsg.type=MESSAGE_GAMEPAD_BUTTON;
                pmsg.gamepadButton.id=msg.cbutton.which;
                pmsg.gamepadButton.button=msg.cbutton.button;
                pmsg.gamepadButton.pressed=msg.cbutton.type==SDL_CONTROLLERBUTTONDOWN;
                break;
            case SDL_CONTROLLERAXISMOTION:
                pmsg.type=MESSAGE_GAMEPAD_AXIS;
                pmsg.gamepadAxis.id=msg.caxis.which;
                pmsg.gamepadAxis.axis=msg.caxis.axis;
                pmsg.gamepadAxis.value=msg.caxis.value;
                break;
            case SDL_CONTROLLERDEVICEADDED: SDL_GameControllerOpen(msg.cdevice.which); break;
            case SDL_CONTROLLERDEVICEREMOVED:
                pmsg.type=MESSAGE_GAMEPAD_UNPLUG;
                pmsg.gamepadUnplug.id=msg.cdevice.which;
                SDL_GameControllerClose(SDL_GameControllerFromInstanceID(msg.cdevice.which));
                break;
            }

            if (pmsg.type!=0 && v.active>=0 && v.connected[v.active])
                ParsecClientSendMessage(v.parsec[v.active],&pmsg);
        }

        for (int i=0;i<v.session_count;i++) {
            if (!v.connected[i]) continue;
            for (ParsecClientEvent ev; ParsecClientPollEvents(v.parsec[i],0,&ev);) {
                if (ev.type==CLIENT_EVENT_CURSOR && i==v.active)
                    handle_cursor(&v,&ev.cursor.cursor,ev.cursor.key);
                else if (ev.type==CLIENT_EVENT_CURSOR && ev.cursor.cursor.imageUpdate)
                    ParsecFree(v.parsec[i],ParsecGetBuffer(v.parsec[i],ev.cursor.key));
                else if (ev.type==CLIENT_EVENT_USER_DATA) {
                    char *ud=ParsecGetBuffer(v.parsec[i],ev.userData.key);
                    if (i==v.active && ud && ev.userData.id==MSG_CLIPBOARD)
                        SDL_SetClipboardText(ud);
                    ParsecFree(v.parsec[i],ud);
                } else if (ev.type==CLIENT_EVENT_STREAM && ev.stream.status<0) {
                    v.connected[i]=false; v.health[i].state=HEALTH_LOST;
                    v.health[i].lost_at=SDL_GetTicks();
                }
            }
        }

        check_health(&v);
        SDL_Delay(1);
    }

    printf("[pmux] Shutting down...\n");
    v.done=true; g_quit=true;
    SDL_WaitThread(rt,NULL);
    SDL_WaitThread(at,NULL);
    disconnect_all(&v);

cleanup:
    for (int i=0;i<v.session_count;i++) if (v.parsec[i]) ParsecDestroy(v.parsec[i]);
    SDL_FreeCursor(v.cursor); SDL_FreeSurface(v.cursor_surface);
    SDL_DestroyWindow(v.window); SDL_CloseAudioDevice(v.audio);
    SDL_Quit();
    printf("[pmux] Done.\n");
    return (e!=PARSEC_OK)?1:0;
}
