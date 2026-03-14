/*
 * pmux-viewer — tmux-style multi-session Parsec client with grid mode.
 *
 * Architecture:
 *   - One Parsec SDK instance per session (up to 9)
 *   - Single-active in 1x1 mode, multi-active in grid mode
 *   - Grid mode: 2x2 layout, all visible sessions connected simultaneously
 *   - Staggered connections to avoid NAT hole-punch collisions
 *   - Each instance on unique port (1000-port spacing)
 *   - Multi-display: stream 0 + stream 1 per connection (NUM_VSTREAMS=2)
 *
 * Keybindings:
 *   Cmd+1-7    jump to session slot (1x1 mode)
 *   Cmd+9      next session
 *   Cmd+8      previous session
 *   Cmd+`      disconnect active session
 *   Cmd+R      reconnect active session
 *   Cmd+G      toggle grid mode (1x1 <-> 2x2)
 *   Cmd+Q      quit
 *
 * Grid mode:
 *   Click a quadrant to focus it (keyboard/mouse go there)
 *   Cmd+F      expand focused quadrant to fullscreen (1x1)
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

#define MSG_CLIPBOARD 7
#define MAX_SESSIONS  9
#define GRID_MAX      4         /* max sessions visible in grid */
#define SDK_PATH      "sdk/libparsec.dylib"

/* OpenGL constants */
#define GL_COLOR_BUFFER_BIT 0x4000
#define GL_SCISSOR_TEST     0x0C11

/* ── types ─────────────────────────────────────────────────── */

enum health_state { HEALTH_OK = 0, HEALTH_DEGRADED, HEALTH_BAD, HEALTH_LOST };
enum view_mode    { MODE_SINGLE = 0, MODE_GRID };

#define RECONNECT_DELAY_MS  3000
#define HEALTH_CHECK_MS     1000
#define NETWORK_FAIL_MAX    5
#define STAGGER_DELAY_MS    2000  /* delay between staggered connects */

struct session {
    char peer_id[64];
    char name[64];
    int  slot;
};

struct conn_health {
    enum health_state state;
    float    latency;
    float    bitrate;
    uint32_t queued_frames;
    int      net_fail_count;
    uint32_t last_check;
    uint32_t lost_at;
    int      retries;
    bool     reconnecting;
};

struct viewer {
    ParsecDSO        *parsec[MAX_SESSIONS];
    bool              connected[MAX_SESSIONS];
    struct conn_health health[MAX_SESSIONS];

    struct session    sessions[MAX_SESSIONS];
    int               session_count;
    int               active;       /* focused session index */

    /* Grid mode */
    enum view_mode    mode;
    int               grid[GRID_MAX]; /* indices into sessions[] shown in grid */
    int               grid_count;

    char              session_id[128];

    SDL_Window       *window;
    SDL_Surface      *cursor_surface;
    SDL_Cursor       *cursor;
    SDL_AudioDeviceID audio;

    float             scale;
    int               win_w, win_h;
    int               gl_w, gl_h;   /* cached GL drawable size */

    bool              done;
};

/* ── signal handler ────────────────────────────────────────── */

static volatile bool g_quit = false;

static void signal_handler(int sig)
{
    (void)sig;
    g_quit = true;
}

/* ── callbacks ─────────────────────────────────────────────── */

static void log_cb(ParsecLogLevel level, const char *msg, void *opaque)
{
    (void)opaque;
    printf("[%s] %s\n", level == LOG_DEBUG ? "D" : "I", msg);
}

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
            SDL_FreeCursor(v->cursor);
            v->cursor = c;
            SDL_FreeSurface(v->cursor_surface);
            v->cursor_surface = s;
            ParsecFree(v->parsec[a], img);
        }
    }
    if (SDL_GetRelativeMouseMode() && !cur->relative) {
        SDL_SetRelativeMouseMode(SDL_DISABLE);
        SDL_WarpMouseInWindow(v->window, cur->positionX, cur->positionY);
    } else if (!SDL_GetRelativeMouseMode() && cur->relative) {
        SDL_SetRelativeMouseMode(SDL_ENABLE);
    }
}

/* ── title bar ─────────────────────────────────────────────── */

static const char *health_icon(int state)
{
    switch (state) {
    case HEALTH_OK:       return "=";
    case HEALTH_DEGRADED: return "~";
    case HEALTH_BAD:      return "!";
    case HEALTH_LOST:     return "X";
    default:              return "?";
    }
}

/* Forward declarations */
static void update_dimensions(struct viewer *v, int idx);

static void update_title(struct viewer *v)
{
    char title[512];
    char slots[256] = "";
    int off = 0;

    for (int i = 0; i < v->session_count; i++) {
        const char *mark = " ";
        if (i == v->active) mark = v->connected[i] ? ">" : "x";
        else if (v->connected[i]) mark = "+";
        off += snprintf(slots + off, sizeof(slots) - off, " [%d]%s%s",
            v->sessions[i].slot, mark, v->sessions[i].name);
    }

    int a = v->active;
    const char *mode_str = v->mode == MODE_GRID ? "GRID" : "1x1";

    if (a >= 0 && v->connected[a]) {
        struct conn_health *h = &v->health[a];
        char quality[64] = "";
        if (h->latency > 0)
            snprintf(quality, sizeof(quality), " [%s %.0fms %.1fMbps]",
                health_icon(h->state), h->latency, h->bitrate);

        snprintf(title, sizeof(title),
            "pmux %s | %s%s |%s",
            mode_str, v->sessions[a].name, quality, slots);
    } else if (a >= 0 && v->health[a].reconnecting) {
        snprintf(title, sizeof(title),
            "pmux %s | %s [reconnecting...] |%s",
            mode_str, v->sessions[a].name, slots);
    } else {
        snprintf(title, sizeof(title),
            "pmux %s | disconnected |%s", mode_str, slots);
    }

    SDL_SetWindowTitle(v->window, title);
}

/* ── health monitoring ─────────────────────────────────────── */

static void check_health(struct viewer *v)
{
    uint32_t now = SDL_GetTicks();

    /* In grid mode, monitor all grid sessions. In single mode, only active. */
    for (int gi = 0; gi < (v->mode == MODE_GRID ? v->grid_count : 1); gi++) {
        int i = (v->mode == MODE_GRID) ? v->grid[gi] : v->active;
        if (i < 0) continue;
        struct conn_health *h = &v->health[i];

        if (!v->connected[i]) {
            /* Auto-reconnect with exponential backoff */
            if (h->lost_at > 0 && !h->reconnecting) {
                uint32_t delay = RECONNECT_DELAY_MS * (1u << (h->retries > 4 ? 4 : h->retries));
                if ((now - h->lost_at) > delay) {
                    h->reconnecting = true;
                    h->retries++;
                    printf("[pmux] Auto-reconnecting to %s (attempt %d)...\n",
                        v->sessions[i].name, h->retries);
                    ParsecStatus e = ParsecClientConnect(v->parsec[i], NULL,
                        v->session_id, v->sessions[i].peer_id);
                    if (e == PARSEC_OK) {
                        v->connected[i] = true;
                        h->state = HEALTH_OK;
                        h->net_fail_count = 0;
                        h->lost_at = 0;
                        h->retries = 0;
                        h->reconnecting = false;
                        update_dimensions(v, i);
                        printf("[pmux] Reconnected to %s\n", v->sessions[i].name);
                    } else {
                        h->lost_at = now;
                        h->reconnecting = false;
                    }
                    update_title(v);
                }
            }
            continue;
        }

        if ((now - h->last_check) < HEALTH_CHECK_MS) continue;
        h->last_check = now;

        ParsecClientStatus status;
        ParsecStatus cs = ParsecClientGetStatus(v->parsec[i], &status);

        if (cs == PARSEC_CONNECTING) continue;

        if (cs < 0) {
            printf("[pmux] Connection to %s lost (status %d)\n", v->sessions[i].name, cs);
            v->connected[i] = false;
            h->state = HEALTH_LOST;
            h->lost_at = now;
            h->net_fail_count = 0;
            update_title(v);
            continue;
        }

        ParsecMetrics *m = &status.self.metrics[0];
        h->latency = m->networkLatency;
        h->bitrate = m->bitrate;
        h->queued_frames = m->queuedFrames;

        if (status.networkFailure) h->net_fail_count++;
        else h->net_fail_count = 0;

        if (h->net_fail_count >= NETWORK_FAIL_MAX) {
            h->state = HEALTH_LOST;
            printf("[pmux] Network failure on %s\n", v->sessions[i].name);
            ParsecClientDisconnect(v->parsec[i]);
            v->connected[i] = false;
            h->lost_at = now;
            h->net_fail_count = 0;
        } else if (h->latency > 150 || h->queued_frames > 10) {
            h->state = HEALTH_BAD;
        } else if (h->latency > 60 || h->queued_frames > 3) {
            h->state = HEALTH_DEGRADED;
        } else {
            h->state = HEALTH_OK;
        }

        if (i == v->active) update_title(v);
    }
}

/* ── connection management ─────────────────────────────────── */

static void update_dimensions(struct viewer *v, int idx)
{
    if (idx < 0 || !v->connected[idx]) return;

    if (v->mode == MODE_GRID && v->grid_count > 1) {
        /* In grid: each quadrant is half the window */
        int qw = v->win_w / 2;
        int qh = v->win_h / 2;
        ParsecClientSetDimensions(v->parsec[idx], 0, qw, qh, v->scale);
    } else {
        ParsecClientSetDimensions(v->parsec[idx], 0, v->win_w, v->win_h, v->scale);
    }
}

static void connect_session(struct viewer *v, int idx)
{
    if (idx < 0 || idx >= v->session_count) return;
    if (v->connected[idx]) return;

    printf("[pmux] Connecting to %s...\n", v->sessions[idx].name);
    ParsecStatus e = ParsecClientConnect(v->parsec[idx], NULL,
        v->session_id, v->sessions[idx].peer_id);

    if (e == PARSEC_OK) {
        v->connected[idx] = true;
        v->health[idx] = (struct conn_health){0};
        update_dimensions(v, idx);
        /* Enable second display stream if host has multiple monitors */
        ParsecClientEnableStream(v->parsec[idx], 1, true);
        printf("[pmux] Connected to %s\n", v->sessions[idx].name);
    } else {
        printf("[pmux] Connect to %s failed: %d\n", v->sessions[idx].name, e);
    }
}

static void disconnect_session(struct viewer *v, int idx)
{
    if (idx < 0 || idx >= v->session_count) return;
    if (!v->connected[idx]) return;

    ParsecClientDisconnect(v->parsec[idx]);
    v->connected[idx] = false;
    v->health[idx] = (struct conn_health){0};
    printf("[pmux] Disconnected from %s\n", v->sessions[idx].name);
}

static void disconnect_all(struct viewer *v)
{
    for (int i = 0; i < v->session_count; i++)
        disconnect_session(v, i);
}

/* Staggered connect: connects sessions sequentially with delays
 * to avoid NAT hole-punch collisions on same-IP hosts. */
static void connect_staggered(struct viewer *v, int *indices, int count)
{
    for (int i = 0; i < count; i++) {
        connect_session(v, indices[i]);
        /* Wait for NAT to settle before next connection */
        if (i < count - 1)
            SDL_Delay(STAGGER_DELAY_MS);
    }
}

/* ── mode switching ────────────────────────────────────────── */

static void enter_grid_mode(struct viewer *v)
{
    if (v->mode == MODE_GRID) return;
    v->mode = MODE_GRID;

    /* Populate grid with up to 4 sessions, starting from active */
    v->grid_count = 0;
    int start = v->active >= 0 ? v->active : 0;
    for (int i = 0; i < v->session_count && v->grid_count < GRID_MAX; i++) {
        int idx = (start + i) % v->session_count;
        v->grid[v->grid_count++] = idx;
    }

    /* Disconnect all first, then stagger-connect grid sessions */
    disconnect_all(v);
    SDL_Delay(500);
    connect_staggered(v, v->grid, v->grid_count);

    /* Focus stays on active */
    if (v->active < 0 && v->grid_count > 0)
        v->active = v->grid[0];

    printf("[pmux] Grid mode: %d sessions\n", v->grid_count);
    update_title(v);
}

static void enter_single_mode(struct viewer *v)
{
    if (v->mode == MODE_SINGLE) return;
    v->mode = MODE_SINGLE;

    /* Disconnect all grid sessions except the focused one */
    int keep = v->active;
    for (int i = 0; i < v->grid_count; i++) {
        if (v->grid[i] != keep)
            disconnect_session(v, v->grid[i]);
    }

    /* Update dimensions for fullscreen */
    update_dimensions(v, keep);

    printf("[pmux] Single mode: %s\n",
        keep >= 0 ? v->sessions[keep].name : "none");
    update_title(v);
}

static void toggle_grid(struct viewer *v)
{
    if (v->mode == MODE_SINGLE)
        enter_grid_mode(v);
    else
        enter_single_mode(v);
}

/* ── session switching ─────────────────────────────────────── */

static void switch_to(struct viewer *v, int idx)
{
    if (idx < 0 || idx >= v->session_count) return;
    if (idx == v->active && v->connected[idx]) return;

    if (v->mode == MODE_SINGLE) {
        /* Disconnect current, connect new */
        if (v->active >= 0 && v->connected[v->active]) {
            disconnect_session(v, v->active);
            SDL_Delay(200);
        }
        SDL_ClearQueuedAudio(v->audio);
        SDL_SetRelativeMouseMode(SDL_DISABLE);
        v->active = idx;
        connect_session(v, idx);
    } else {
        /* Grid mode: just change focus (all already connected) */
        SDL_ClearQueuedAudio(v->audio);
        SDL_SetRelativeMouseMode(SDL_DISABLE);
        v->active = idx;
    }

    printf("[pmux] Focus -> %s [slot %d]\n", v->sessions[idx].name, v->sessions[idx].slot);
    update_title(v);
}

static void switch_slot(struct viewer *v, int slot)
{
    for (int i = 0; i < v->session_count; i++)
        if (v->sessions[i].slot == slot) { switch_to(v, i); return; }
}

static void switch_prev(struct viewer *v)
{
    if (v->session_count == 0) return;
    int cur = v->active < 0 ? 0 : v->active;
    switch_to(v, (cur - 1 + v->session_count) % v->session_count);
}

static void switch_next(struct viewer *v)
{
    if (v->session_count == 0) return;
    int cur = v->active < 0 ? -1 : v->active;
    switch_to(v, (cur + 1) % v->session_count);
}

/* In grid mode: which quadrant did the user click? */
static int grid_quadrant_at(struct viewer *v, int mx, int my)
{
    if (v->grid_count <= 1) return 0;
    int col = (mx < v->win_w / 2) ? 0 : 1;
    int row = (my < v->win_h / 2) ? 0 : 1;
    int qi = row * 2 + col;
    return (qi < v->grid_count) ? qi : -1;
}

/* ── threads ───────────────────────────────────────────────── */

static int32_t render_thread(void *opaque)
{
    struct viewer *v = (struct viewer *)opaque;
    SDL_GLContext gl = SDL_GL_CreateContext(v->window);
    SDL_GL_SetSwapInterval(1);

    void (*glClearColor)(float, float, float, float) =
        (void (*)(float, float, float, float))SDL_GL_GetProcAddress("glClearColor");
    void (*glClear)(unsigned int) =
        (void (*)(unsigned int))SDL_GL_GetProcAddress("glClear");
    void (*glFinish)(void) =
        (void (*)(void))SDL_GL_GetProcAddress("glFinish");
    void (*glViewport_)(int, int, int, int) =
        (void (*)(int, int, int, int))SDL_GL_GetProcAddress("glViewport");
    void (*glScissor_)(int, int, int, int) =
        (void (*)(int, int, int, int))SDL_GL_GetProcAddress("glScissor");
    void (*glEnable_)(unsigned int) =
        (void (*)(unsigned int))SDL_GL_GetProcAddress("glEnable");
    void (*glDisable_)(unsigned int) =
        (void (*)(unsigned int))SDL_GL_GetProcAddress("glDisable");

    while (!v->done && !g_quit) {
        /* Use cached GL drawable size (updated on resize events) */
        int gw = v->gl_w;
        int gh = v->gl_h;

        glClearColor(0.06f, 0.06f, 0.10f, 1.0f);
        glClear(GL_COLOR_BUFFER_BIT);

        if (v->mode == MODE_GRID && v->grid_count > 1) {
            int qw = gw / 2;
            int qh = gh / 2;
            glEnable_(GL_SCISSOR_TEST);

            for (int gi = 0; gi < v->grid_count && gi < 4; gi++) {
                int idx = v->grid[gi];
                int col = gi % 2;
                int row = gi / 2;
                int vx = col * qw;
                int vy = (1 - row) * qh;

                glViewport_(vx, vy, qw, qh);
                glScissor_(vx, vy, qw, qh);

                if (v->connected[idx]) {
                    ParsecClientGLRenderFrame(v->parsec[idx], 0, NULL, NULL, 16);
                } else {
                    glClearColor(0.10f, 0.06f, 0.06f, 1.0f);
                    glClear(GL_COLOR_BUFFER_BIT);
                }
            }

            glDisable_(GL_SCISSOR_TEST);
            glViewport_(0, 0, gw, gh);
        } else {
            glViewport_(0, 0, gw, gh);
            int a = v->active;
            if (a >= 0 && v->connected[a]) {
                ParsecClientGLRenderFrame(v->parsec[a], 0, NULL, NULL, 100);
            }
        }

        SDL_GL_SwapWindow(v->window);
        glFinish();
    }

    for (int i = 0; i < v->session_count; i++)
        if (v->parsec[i])
            ParsecClientGLDestroy(v->parsec[i], 0);

    SDL_GL_DeleteContext(gl);
    return 0;
}

static int32_t audio_thread(void *opaque)
{
    struct viewer *v = (struct viewer *)opaque;
    while (!v->done && !g_quit) {
        int a = v->active;
        if (a >= 0 && v->connected[a]) {
            ParsecClientPollAudio(v->parsec[a], audio_cb, 50, v);
        } else {
            SDL_Delay(10);
        }
    }
    return 0;
}

/* ── config parsing ────────────────────────────────────────── */

static int load_sessions(const char *path, struct session *sessions)
{
    FILE *f = fopen(path, "r");
    if (!f) { fprintf(stderr, "Cannot open: %s\n", path); return 0; }

    int count = 0;
    char line[256];
    while (count < MAX_SESSIONS && fgets(line, sizeof(line), f)) {
        char *nl = strchr(line, '\n');
        if (nl) *nl = 0;
        if (line[0] == '#' || line[0] == 0) continue;

        int slot = 0;
        char peer_id[64] = "", name[64] = "";
        if (sscanf(line, "%d\t%63s\t%63[^\n]", &slot, peer_id, name) >= 3) {
            sessions[count].slot = slot;
            strncpy(sessions[count].peer_id, peer_id, 63);
            strncpy(sessions[count].name, name, 63);
            count++;
        }
    }
    fclose(f);
    return count;
}

/* ── main ──────────────────────────────────────────────────── */

int32_t main(int32_t argc, char **argv)
{
    if (argc < 3) {
        printf("Usage: pmux-viewer <session_id> <sessions_file>\n\n");
        printf("Keys (Cmd = Command):\n");
        printf("  Cmd+1-7    jump to session slot\n");
        printf("  Cmd+9/8    next/prev session\n");
        printf("  Cmd+`      disconnect active\n");
        printf("  Cmd+R      reconnect active\n");
        printf("  Cmd+G      toggle grid mode (1x1 <-> 2x2)\n");
        printf("  Cmd+F      fullscreen focused quadrant\n");
        printf("  Cmd+Q      quit\n");
        printf("\nGrid mode: click a quadrant to focus it.\n");
        return 1;
    }

    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);

    struct viewer v = {0};
    v.active = -1;
    v.mode = MODE_SINGLE;
    strncpy(v.session_id, argv[1], sizeof(v.session_id) - 1);

    v.session_count = load_sessions(argv[2], v.sessions);
    if (v.session_count == 0) {
        fprintf(stderr, "No sessions found.\n");
        return 1;
    }

    printf("[pmux] Loaded %d sessions:\n", v.session_count);
    for (int i = 0; i < v.session_count; i++)
        printf("  [Cmd+%d] %s\n", v.sessions[i].slot, v.sessions[i].name);

    /* ── SDL init ──────────────────────────────────────────── */
    SDL_SetHint(SDL_HINT_MOUSE_FOCUS_CLICKTHROUGH, "1");
    SDL_SetHint(SDL_HINT_VIDEO_MAC_FULLSCREEN_SPACES, "0");
    SDL_SetHint(SDL_HINT_MAC_CTRL_CLICK_EMULATE_RIGHT_CLICK, "1");
    SDL_Init(SDL_INIT_VIDEO | SDL_INIT_AUDIO | SDL_INIT_GAMECONTROLLER);

    SDL_AudioSpec want = {0}, have;
    want.freq = 48000;
    want.format = AUDIO_S16;
    want.channels = 2;
    want.samples = 2048;
    v.audio = SDL_OpenAudioDevice(NULL, 0, &want, &have, 0);
    SDL_PauseAudioDevice(v.audio, 0);

    SDL_Rect usable;
    SDL_GetDisplayUsableBounds(0, &usable);
    printf("[pmux] Usable display: %dx%d\n", usable.w, usable.h);

    v.window = SDL_CreateWindow("pmux",
        usable.x, usable.y, usable.w, usable.h,
        SDL_WINDOW_OPENGL | SDL_WINDOW_RESIZABLE | SDL_WINDOW_ALLOW_HIGHDPI);

    v.win_w = usable.w;
    v.win_h = usable.h;
    SDL_GL_GetDrawableSize(v.window, &v.gl_w, &v.gl_h);
    v.scale = (float)v.gl_w / (float)usable.w;

    /* ── Init SDK instances with UNIQUE PORTS ──────────────── */
    printf("[pmux] Initializing SDK instances...\n");
    ParsecStatus e = PARSEC_OK;
    for (int i = 0; i < v.session_count; i++) {
        ParsecConfig cfg = {0};
        cfg.upnp = 0;
        cfg.clientPort = 13000 + (i * 1000);  /* 13000, 14000, 15000, ... */
        cfg.hostPort = 0;

        /* NOTE: correct arg order is (cfg, reserved, path, dso) */
        e = ParsecInit(&cfg, NULL, SDK_PATH, &v.parsec[i]);
        if (e != PARSEC_OK) {
            fprintf(stderr, "ParsecInit failed for slot %d: %d\n", v.sessions[i].slot, e);
            goto cleanup;
        }
        ParsecSetLogCallback(v.parsec[i], log_cb, NULL);

        /* Verify port was applied */
        ParsecConfig actual = {0};
        ParsecGetConfig(v.parsec[i], &actual);
        printf("[pmux] Instance %d (%s): port %d\n",
            i, v.sessions[i].name, actual.clientPort);
    }

    /* Connect first session */
    v.active = 0;
    connect_session(&v, 0);
    update_title(&v);

    /* ── Start threads ─────────────────────────────────────── */
    SDL_Thread *rt = SDL_CreateThread(render_thread, "render", &v);
    SDL_Thread *at = SDL_CreateThread(audio_thread, "audio", &v);

    /* ── Event loop ────────────────────────────────────────── */
    while (!v.done && !g_quit) {
        for (SDL_Event msg; SDL_PollEvent(&msg);) {
            ParsecMessage pmsg = {0};

            /* Cmd+key: session management */
            if (msg.type == SDL_KEYDOWN && (msg.key.keysym.mod & KMOD_GUI)) {
                SDL_Keycode key = msg.key.keysym.sym;

                if (key >= SDLK_1 && key <= SDLK_7) { switch_slot(&v, key - SDLK_1 + 1); continue; }
                if (key == SDLK_8) { switch_prev(&v); continue; }
                if (key == SDLK_9) { switch_next(&v); continue; }
                if (key == SDLK_BACKQUOTE) {
                    if (v.active >= 0) { disconnect_session(&v, v.active); update_title(&v); }
                    continue;
                }
                if (key == SDLK_r) {
                    if (v.active >= 0 && !v.connected[v.active]) connect_session(&v, v.active);
                    continue;
                }
                if (key == SDLK_g) { toggle_grid(&v); continue; }
                if (key == SDLK_f) {
                    if (v.mode == MODE_GRID) enter_single_mode(&v);
                    continue;
                }
                if (key == SDLK_q) { v.done = true; continue; }
            }

            switch (msg.type) {
            case SDL_QUIT:
                v.done = true;
                break;

            case SDL_WINDOWEVENT:
                if (msg.window.event == SDL_WINDOWEVENT_CLOSE) {
                    v.done = true;
                    break;
                }
                if (msg.window.event == SDL_WINDOWEVENT_SIZE_CHANGED) {
                    v.win_w = msg.window.data1;
                    v.win_h = msg.window.data2;
                    SDL_GL_GetDrawableSize(v.window, &v.gl_w, &v.gl_h);
                    v.scale = (float)v.gl_w / (float)v.win_w;
                    for (int i = 0; i < v.session_count; i++)
                        update_dimensions(&v, i);
                }
                break;

            case SDL_KEYDOWN:
            case SDL_KEYUP:
                pmsg.type = MESSAGE_KEYBOARD;
                pmsg.keyboard.code = (ParsecKeycode)msg.key.keysym.scancode;
                pmsg.keyboard.mod = msg.key.keysym.mod;
                pmsg.keyboard.pressed = msg.key.type == SDL_KEYDOWN;
                break;

            case SDL_MOUSEMOTION:
                pmsg.type = MESSAGE_MOUSE_MOTION;
                pmsg.mouseMotion.relative = SDL_GetRelativeMouseMode();
                if (pmsg.mouseMotion.relative) {
                    pmsg.mouseMotion.x = msg.motion.xrel;
                    pmsg.mouseMotion.y = msg.motion.yrel;
                } else if (v.mode == MODE_GRID && v.grid_count > 1) {
                    /* Map mouse to quadrant-local coords */
                    int qw = v.win_w / 2;
                    int qh = v.win_h / 2;
                    int lx = msg.motion.x % qw;
                    int ly = msg.motion.y % qh;
                    pmsg.mouseMotion.x = (int32_t)(lx * v.scale);
                    pmsg.mouseMotion.y = (int32_t)(ly * v.scale);
                } else {
                    pmsg.mouseMotion.x = (int32_t)(msg.motion.x * v.scale);
                    pmsg.mouseMotion.y = (int32_t)(msg.motion.y * v.scale);
                }
                break;

            case SDL_MOUSEBUTTONDOWN:
            case SDL_MOUSEBUTTONUP:
                /* In grid mode: click to focus quadrant */
                if (v.mode == MODE_GRID && msg.type == SDL_MOUSEBUTTONDOWN) {
                    int qi = grid_quadrant_at(&v, msg.button.x, msg.button.y);
                    if (qi >= 0 && qi < v.grid_count) {
                        int new_focus = v.grid[qi];
                        if (new_focus != v.active) {
                            SDL_ClearQueuedAudio(v.audio);
                            v.active = new_focus;
                            printf("[pmux] Grid focus -> %s\n", v.sessions[new_focus].name);
                            update_title(&v);
                        }
                    }
                }
                pmsg.type = MESSAGE_MOUSE_BUTTON;
                pmsg.mouseButton.button = (ParsecMouseButton)msg.button.button;
                pmsg.mouseButton.pressed = msg.button.type == SDL_MOUSEBUTTONDOWN;
                break;

            case SDL_MOUSEWHEEL:
                pmsg.type = MESSAGE_MOUSE_WHEEL;
                pmsg.mouseWheel.x = msg.wheel.x * 120;
                pmsg.mouseWheel.y = msg.wheel.y * 120;
                break;

            case SDL_CLIPBOARDUPDATE:
                if (v.active >= 0 && v.connected[v.active]) {
                    char *clip = SDL_GetClipboardText();
                    if (clip) {
                        ParsecClientSendUserData(v.parsec[v.active], MSG_CLIPBOARD, clip);
                        SDL_free(clip);
                    }
                }
                break;

            case SDL_CONTROLLERBUTTONDOWN:
            case SDL_CONTROLLERBUTTONUP:
                pmsg.type = MESSAGE_GAMEPAD_BUTTON;
                pmsg.gamepadButton.id = msg.cbutton.which;
                pmsg.gamepadButton.button = msg.cbutton.button;
                pmsg.gamepadButton.pressed = msg.cbutton.type == SDL_CONTROLLERBUTTONDOWN;
                break;

            case SDL_CONTROLLERAXISMOTION:
                pmsg.type = MESSAGE_GAMEPAD_AXIS;
                pmsg.gamepadAxis.id = msg.caxis.which;
                pmsg.gamepadAxis.axis = msg.caxis.axis;
                pmsg.gamepadAxis.value = msg.caxis.value;
                break;

            case SDL_CONTROLLERDEVICEADDED:
                SDL_GameControllerOpen(msg.cdevice.which);
                break;

            case SDL_CONTROLLERDEVICEREMOVED:
                pmsg.type = MESSAGE_GAMEPAD_UNPLUG;
                pmsg.gamepadUnplug.id = msg.cdevice.which;
                SDL_GameControllerClose(SDL_GameControllerFromInstanceID(msg.cdevice.which));
                break;
            }

            /* Send input to focused session only */
            if (pmsg.type != 0 && v.active >= 0 && v.connected[v.active])
                ParsecClientSendMessage(v.parsec[v.active], &pmsg);
        }

        /* Poll events from all connected sessions */
        for (int i = 0; i < v.session_count; i++) {
            if (!v.connected[i]) continue;
            for (ParsecClientEvent ev; ParsecClientPollEvents(v.parsec[i], 0, &ev);) {
                switch (ev.type) {
                case CLIENT_EVENT_CURSOR:
                    if (i == v.active)
                        handle_cursor(&v, &ev.cursor.cursor, ev.cursor.key);
                    else if (ev.cursor.cursor.imageUpdate)
                        ParsecFree(v.parsec[i], ParsecGetBuffer(v.parsec[i], ev.cursor.key));
                    break;
                case CLIENT_EVENT_USER_DATA:
                    {
                        char *ud = ParsecGetBuffer(v.parsec[i], ev.userData.key);
                        if (i == v.active && ud && ev.userData.id == MSG_CLIPBOARD)
                            SDL_SetClipboardText(ud);
                        ParsecFree(v.parsec[i], ud);
                    }
                    break;
                case CLIENT_EVENT_STREAM:
                    if (ev.stream.status < 0) {
                        printf("[pmux] Stream error on %s: %d\n",
                            v.sessions[i].name, ev.stream.status);
                        v.connected[i] = false;
                        v.health[i].state = HEALTH_LOST;
                        v.health[i].lost_at = SDL_GetTicks();
                        update_title(&v);
                    }
                    break;
                default:
                    break;
                }
            }
        }

        check_health(&v);
        SDL_Delay(1);
    }

    /* ── Cleanup ───────────────────────────────────────────── */
    printf("[pmux] Shutting down...\n");
    v.done = true;
    g_quit = true;
    SDL_WaitThread(rt, NULL);
    SDL_WaitThread(at, NULL);
    disconnect_all(&v);

cleanup:
    for (int i = 0; i < v.session_count; i++)
        if (v.parsec[i]) ParsecDestroy(v.parsec[i]);

    SDL_FreeCursor(v.cursor);
    SDL_FreeSurface(v.cursor_surface);
    SDL_DestroyWindow(v.window);
    SDL_CloseAudioDevice(v.audio);
    SDL_Quit();

    printf("[pmux] Clean exit.\n");
    return (e != PARSEC_OK) ? 1 : 0;
}
