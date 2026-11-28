#include "internal.h"

#ifdef _WIN32

#include <math.h>
#include <stdlib.h>
#include <string.h>

/* The on-screen indicator: a small dark capsule at the bottom of the screen. It never takes
   the keyboard or a click, or the dictated text would go to the wrong place. */

#define PILL_CLASS L"LucidPill"
#define FRAME_MS 33
#define HANDS_FREE L"Hands-free. Press the key again to finish."

static HWND pill;
static HFONT font;
static float scale = 1;
static int status = LUCID_PILL_HIDDEN;
static wchar_t *message;
static wchar_t *preview;
static bool pulsing;
static float shown_level;
static int shown_step;
static DWORD began;
static LucidCanvas canvas;

static int px(float points) {
    return (int)(points * scale + 0.5f);
}

static void set_text(wchar_t **slot, const char *text) {
    free(*slot);
    *slot = lucid_wide(text);
}

/* The last words heard, with the start cut off if they are too wide for the pill. */
static wchar_t *fitted_preview(int max_width) {
    const wchar_t *text = preview ? preview : L"";
    size_t length = wcslen(text);
    wchar_t *fitted = (wchar_t *)calloc(length + 2, sizeof(wchar_t));
    if (!fitted) return NULL;
    memcpy(fitted, text, length * sizeof(wchar_t));
    size_t start = 0;
    while (lucid_text_size(font, fitted).cx > max_width && start < length) {
        start++;
        /* Not between the two halves of one character. */
        if (start < length && text[start] >= 0xDC00 && text[start] <= 0xDFFF) start++;
        fitted[0] = 0x2026; /* … */
        memcpy(fitted + 1, text + start, (length - start + 1) * sizeof(wchar_t));
    }
    return fitted;
}

static void draw(void) {
    if (!pill || status == LUCID_PILL_HIDDEN) return;

    int height = px(34), padding = px(15), gap = px(9);
    int bars_width = px(3) * 5 + px(3) * 4;
    int dots_width = px(6) * 3 + px(5) * 2;
    bool bars = status == LUCID_PILL_RECORDING || status == LUCID_PILL_HANDS_FREE;
    wchar_t *words = NULL;
    const wchar_t *text = L"";
    if (status == LUCID_PILL_MESSAGE) {
        text = message ? message : L"";
    } else if (bars) {
        if (preview && preview[0]) {
            words = fitted_preview(px(330));
            text = words ? words : L"";
        } else if (status == LUCID_PILL_HANDS_FREE) {
            text = HANDS_FREE;
        }
    }
    SIZE text_size = lucid_text_size(font, text);
    int text_limit = px(520);
    if (text_size.cx > text_limit) text_size.cx = text_limit;

    int content = 0;
    if (bars) content = bars_width + (text[0] ? gap + text_size.cx : 0);
    else if (status == LUCID_PILL_PROCESSING) content = dots_width;
    else content = text_size.cx;
    int width = padding * 2 + content;

    /* Room around the capsule, for the bump that acknowledges a key press. */
    int margin = px(6);
    int full_width = width + margin * 2, full_height = height + margin * 2;
    if (canvas.width != full_width || canvas.height != full_height) {
        lucid_canvas_free(&canvas);
        if (!lucid_canvas_make(&canvas, full_width, full_height)) {
            free(words);
            return;
        }
    }
    lucid_canvas_clear(&canvas);

    float grow = pulsing ? (float)px(3) : 0;
    float left = (float)margin - grow, right = (float)(margin + width) + grow;
    float top = (float)margin - grow, bottom = (float)(margin + height) + grow;
    float radius = (bottom - top) / 2;
    lucid_fill_round(&canvas, left, top, right, bottom, radius, 0x000000, 0.84f);
    lucid_stroke_round(&canvas, left, top, right, bottom, radius, scale < 1 ? 1 : scale, 0xffffff, 0.16f);

    int x = margin + padding;
    float middle = (float)margin + (float)height / 2;
    if (bars) {
        static const float weights[5] = {0.45f, 0.75f, 1.0f, 0.75f, 0.45f};
        float strength = shown_level * 9;
        if (strength > 1) strength = 1;
        for (int index = 0; index < 5; index++) {
            float bar_height = (4 + 16 * strength * weights[index]) * scale;
            float bar_left = (float)(x + index * (px(3) + px(3)));
            lucid_fill_round(
                &canvas, bar_left, middle - bar_height / 2, bar_left + (float)px(3), middle + bar_height / 2,
                (float)px(3) / 2, 0xffffff, 1);
        }
        x += bars_width + gap;
    } else if (status == LUCID_PILL_PROCESSING) {
        int step = (int)((GetTickCount() - began) / 250) % 3;
        shown_step = step;
        for (int index = 0; index < 3; index++) {
            float dot_left = (float)(x + index * (px(6) + px(5)));
            float size = (float)px(6);
            lucid_fill_round(
                &canvas, dot_left, middle - size / 2, dot_left + size, middle + size / 2,
                size / 2, 0xffffff, index == step ? 1.0f : 0.35f);
        }
    }
    if (text[0]) {
        lucid_draw_text(&canvas, font, text, x, margin + (height - text_size.cy) / 2, text_size.cx, 0xffffff, 1);
    }
    free(words);

    /* Bottom centre of the screen the mouse pointer is on, clear of the taskbar. */
    POINT pointer = {0, 0};
    GetCursorPos(&pointer);
    MONITORINFO monitor;
    memset(&monitor, 0, sizeof monitor);
    monitor.cbSize = sizeof monitor;
    RECT area = {0, 0, GetSystemMetrics(SM_CXSCREEN), GetSystemMetrics(SM_CYSCREEN)};
    if (GetMonitorInfoW(MonitorFromPoint(pointer, MONITOR_DEFAULTTOPRIMARY), &monitor)) area = monitor.rcWork;
    POINT position = {(area.left + area.right - full_width) / 2, area.bottom - px(24) - height - margin};
    SIZE size = {full_width, full_height};
    POINT origin = {0, 0};
    BLENDFUNCTION blend_function = {AC_SRC_OVER, 0, 255, AC_SRC_ALPHA};
    HDC screen = GetDC(NULL);
    UpdateLayeredWindow(pill, screen, &position, &size, canvas.dc, &origin, 0, &blend_function, ULW_ALPHA);
    ReleaseDC(NULL, screen);
    if (!IsWindowVisible(pill)) ShowWindow(pill, SW_SHOWNOACTIVATE);
    SetWindowPos(pill, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
}

bool lucid_pill_make(void) {
    if (pill) return true;
    HDC screen = GetDC(NULL);
    scale = (float)GetDeviceCaps(screen, LOGPIXELSX) / 96.0f;
    ReleaseDC(NULL, screen);
    if (scale < 0.5f) scale = 1;

    LOGFONTW look;
    memset(&look, 0, sizeof look);
    look.lfHeight = -px(13);
    look.lfWeight = FW_SEMIBOLD;
    look.lfCharSet = DEFAULT_CHARSET;
    /* Smooth, but in greys: coloured fringes would show against the see-through edge. */
    look.lfQuality = ANTIALIASED_QUALITY;
    lstrcpynW(look.lfFaceName, L"Segoe UI", LF_FACESIZE);
    font = CreateFontIndirectW(&look);

    WNDCLASSEXW window_class;
    memset(&window_class, 0, sizeof window_class);
    window_class.cbSize = sizeof window_class;
    window_class.lpfnWndProc = DefWindowProcW;
    window_class.hInstance = GetModuleHandleW(NULL);
    window_class.lpszClassName = PILL_CLASS;
    RegisterClassExW(&window_class);
    pill = CreateWindowExW(
        WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_NOACTIVATE | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW,
        PILL_CLASS, L"", WS_POPUP, 0, 0, 0, 0, NULL, NULL, GetModuleHandleW(NULL), NULL);
    return pill != NULL;
}

void lucid_pill_destroy(void) {
    if (lucid_window) {
        KillTimer(lucid_window, LUCID_TIMER_PILL);
        KillTimer(lucid_window, LUCID_TIMER_PILL_HIDE);
        KillTimer(lucid_window, LUCID_TIMER_PILL_PULSE);
    }
    if (pill) DestroyWindow(pill);
    pill = NULL;
    if (font) DeleteObject(font);
    font = NULL;
    lucid_canvas_free(&canvas);
    status = LUCID_PILL_HIDDEN;
}

void lucid_pill_show(int new_status, const char *text) {
    if (!pill) return;
    KillTimer(lucid_window, LUCID_TIMER_PILL_HIDE);
    /* Words heard belong to one recording. Hands-free carries on the same one. */
    if (new_status != LUCID_PILL_HANDS_FREE) set_text(&preview, "");
    if (new_status == LUCID_PILL_MESSAGE) set_text(&message, text);
    if (new_status != status) began = GetTickCount();
    status = new_status;
    if (status == LUCID_PILL_HIDDEN) {
        KillTimer(lucid_window, LUCID_TIMER_PILL);
        ShowWindow(pill, SW_HIDE);
        return;
    }
    shown_level = lucid_mic_level();
    draw();
    /* The bars and the dots move. A message stays as it is. */
    if (status == LUCID_PILL_MESSAGE) KillTimer(lucid_window, LUCID_TIMER_PILL);
    else SetTimer(lucid_window, LUCID_TIMER_PILL, FRAME_MS, NULL);
}

void lucid_pill_flash(const char *text, int milliseconds) {
    if (!pill) return;
    lucid_pill_show(LUCID_PILL_MESSAGE, text);
    SetTimer(lucid_window, LUCID_TIMER_PILL_HIDE, (UINT)(milliseconds < 0 ? 0 : milliseconds), NULL);
}

void lucid_pill_pulse(void) {
    if (!pill || status == LUCID_PILL_HIDDEN) return;
    pulsing = true;
    draw();
    SetTimer(lucid_window, LUCID_TIMER_PILL_PULSE, 150, NULL);
}

void lucid_pill_preview(const char *text) {
    if (!pill) return;
    set_text(&preview, text);
    draw();
}

bool lucid_pill_visible(void) {
    return pill && IsWindowVisible(pill);
}

bool lucid_test_pill_picture(const char *path, uint32_t background) {
    GdiFlush();
    return lucid_canvas_save(&canvas, path, background);
}

void lucid_pill_timer(UINT_PTR timer) {
    if (!pill) return;
    switch (timer) {
    case LUCID_TIMER_PILL: {
        if (status == LUCID_PILL_PROCESSING) {
            int step = (int)((GetTickCount() - began) / 250) % 3;
            if (step != shown_step) draw();
            break;
        }
        /* The bars follow the microphone, but not in jumps. */
        float level = lucid_mic_level();
        float next = shown_level + (level - shown_level) * 0.5f;
        /* Too small a change to see is not worth drawing. */
        if (fabsf(next - shown_level) < 0.0004f) break;
        shown_level = next;
        draw();
        break;
    }
    case LUCID_TIMER_PILL_HIDE:
        lucid_pill_show(LUCID_PILL_HIDDEN, NULL);
        break;
    case LUCID_TIMER_PILL_PULSE:
        KillTimer(lucid_window, LUCID_TIMER_PILL_PULSE);
        pulsing = false;
        draw();
        break;
    default:
        break;
    }
}

#endif
