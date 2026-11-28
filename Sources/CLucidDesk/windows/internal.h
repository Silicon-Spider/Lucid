/* Shared by the files of the Windows half of this library. Not for Lucid's Swift code. */
#ifndef LUCIDWIN_INTERNAL_H
#define LUCIDWIN_INTERNAL_H

#ifdef _WIN32

#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif

#include <windows.h>
#include <mmsystem.h>
#include <shellapi.h>
#include <commdlg.h>
#include <winver.h>

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <wchar.h>

#include "../include/luciddesk.h"

#define LUCID_COUNT(array) (sizeof(array) / sizeof((array)[0]))

/* Messages to Lucid's own window. */
#define LUCID_WM_KEY (WM_APP + 1)
#define LUCID_WM_WAKE (WM_APP + 2)
#define LUCID_WM_TRAY (WM_APP + 3)
#define LUCID_WM_OPEN (WM_APP + 4)

/* Timers on Lucid's own window. */
#define LUCID_TIMER_PILL 1
#define LUCID_TIMER_PILL_HIDE 2
#define LUCID_TIMER_PILL_PULSE 3
#define LUCID_TIMER_CLIPBOARD 4

#define LUCID_WINDOW_CLASS L"LucidMainWindow"

extern HWND lucid_window;
extern LucidCallbacks lucid_callbacks;

/* text.c */
/* A wide copy of UTF-8 text. Never NULL. The caller frees it. */
wchar_t *lucid_wide(const char *text);
/* Wide text as UTF-8 in `out`, always ended. Returns its length in bytes. */
size_t lucid_narrow(const wchar_t *text, char *out, size_t capacity);
/* Reads a text value from the registry. False if it is not there. */
bool lucid_registry_text(HKEY root, const wchar_t *key, const wchar_t *value, wchar_t *out, DWORD capacity);

/* draw.c: a picture with a see-through background, to draw the pill and the tray icon on. */
typedef struct {
    uint32_t *pixels; /* blue, green, red, alpha: already multiplied by alpha */
    int width;
    int height;
    HBITMAP bitmap;
    HDC dc;
    HGDIOBJ old; /* what the drawing context held before the picture */
} LucidCanvas;

bool lucid_canvas_make(LucidCanvas *canvas, int width, int height);
void lucid_canvas_free(LucidCanvas *canvas);
void lucid_canvas_clear(LucidCanvas *canvas);
/* A rectangle with round corners, with smooth edges. `rgb` is 0xRRGGBB. */
void lucid_fill_round(LucidCanvas *canvas, float left, float top, float right, float bottom, float radius, uint32_t rgb, float alpha);
/* Its outline, one `width` thick, inside the rectangle. */
void lucid_stroke_round(LucidCanvas *canvas, float left, float top, float right, float bottom, float radius, float width, uint32_t rgb, float alpha);
/* How wide and tall this text is in this font. */
SIZE lucid_text_size(HFONT font, const wchar_t *text);
/* Text with its top left corner at (x, y), no wider than `max_width`. */
/* For tests: saves the picture over a plain colour (0xRRGGBB) as a .bmp file. */
bool lucid_canvas_save(const LucidCanvas *canvas, const char *path, uint32_t background);
void lucid_draw_text(LucidCanvas *canvas, HFONT font, const wchar_t *text, int x, int y, int max_width, uint32_t rgb, float alpha);

/* Each part's share of what the window receives. */
void lucid_mic_data(HWAVEIN device);
void lucid_pill_timer(UINT_PTR timer);
bool lucid_pill_make(void);
void lucid_pill_destroy(void);
void lucid_tray_add(void);
void lucid_tray_remove(void);
void lucid_tray_clicked(LPARAM event);
void lucid_clipboard_timer(void);
bool lucid_keyboard_start(void);
void lucid_keyboard_stop(void);

#endif /* _WIN32 */
#endif
