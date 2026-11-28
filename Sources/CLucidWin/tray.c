#include "internal.h"

#ifdef _WIN32

#include <stdlib.h>
#include <string.h>

/* Lucid's icon beside the clock, and the menu it opens. */

#define TRAY_ID 1
#define MOST_ITEMS 96

typedef struct {
    int command;
    int flags;
    wchar_t *title;
} Item;

static Item items[MOST_ITEMS];
static int item_count;

static bool added;
static int state = LUCID_TRAY_IDLE;
static wchar_t tip[128] = L"Lucid";
static HICON icon;

/* True when the taskbar is light, so a white icon would not show. */
static bool light_taskbar(void) {
    DWORD light = 0, bytes = sizeof light;
    LSTATUS status = RegGetValueW(
        HKEY_CURRENT_USER, L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
        L"SystemUsesLightTheme", RRF_RT_REG_DWORD, NULL, &light, &bytes);
    return status == ERROR_SUCCESS && light != 0;
}

/* Five bars, the middle one tallest: the same shape the pill shows while recording. */
static HICON draw_icon(int look) {
    int size = GetSystemMetrics(SM_CXSMICON);
    if (size < 16) size = 16;
    LucidCanvas canvas;
    if (!lucid_canvas_make(&canvas, size, size)) return NULL;

    uint32_t colour = light_taskbar() ? 0x1f1f1f : 0xffffff;
    if (look == LUCID_TRAY_RECORDING) colour = 0xff5a4f;
    static const float weights[5] = {0.4f, 0.7f, 1.0f, 0.7f, 0.4f};
    float unit = (float)size / 16.0f;
    float bar = 2 * unit, gap = 1 * unit;
    float left = ((float)size - (bar * 5 + gap * 4)) / 2;
    for (int index = 0; index < 5; index++) {
        float height = 13 * unit * weights[index];
        float x = left + (float)index * (bar + gap);
        lucid_fill_round(&canvas, x, ((float)size - height) / 2, x + bar, ((float)size + height) / 2, bar / 2, colour, 1);
    }
    if (look == LUCID_TRAY_ATTENTION) {
        float dot = 6 * unit;
        lucid_fill_round(&canvas, (float)size - dot, (float)size - dot, (float)size, (float)size, dot / 2, 0xff9f0a, 1);
    }

    /* An icon keeps colour and see-through apart, where the canvas has them multiplied. */
    for (int index = 0; index < size * size; index++) {
        uint32_t pixel = canvas.pixels[index];
        uint32_t alpha = pixel >> 24;
        if (alpha == 0 || alpha == 255) continue;
        uint32_t blue = (pixel & 0xff) * 255 / alpha, green = ((pixel >> 8) & 0xff) * 255 / alpha;
        uint32_t red = ((pixel >> 16) & 0xff) * 255 / alpha;
        if (blue > 255) blue = 255;
        if (green > 255) green = 255;
        if (red > 255) red = 255;
        canvas.pixels[index] = blue | (green << 8) | (red << 16) | (alpha << 24);
    }
    GdiFlush();

    /* The mask is not used when the picture says what is see-through, but must exist. */
    size_t mask_bytes = (size_t)((size + 15) / 16 * 2) * (size_t)size;
    void *zeros = calloc(mask_bytes, 1);
    HBITMAP mask = CreateBitmap(size, size, 1, 1, zeros);
    free(zeros);
    ICONINFO info;
    memset(&info, 0, sizeof info);
    info.fIcon = TRUE;
    info.hbmMask = mask;
    info.hbmColor = canvas.bitmap;
    /* Windows wants the picture to itself while it copies it. */
    SelectObject(canvas.dc, canvas.old);
    HICON made = CreateIconIndirect(&info);
    if (mask) DeleteObject(mask);
    lucid_canvas_free(&canvas);
    return made;
}

static void fill(NOTIFYICONDATAW *data) {
    memset(data, 0, sizeof *data);
    data->cbSize = sizeof *data;
    data->hWnd = lucid_window;
    data->uID = TRAY_ID;
    data->uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP;
    data->uCallbackMessage = LUCID_WM_TRAY;
    data->hIcon = icon;
    lstrcpynW(data->szTip, tip, (int)LUCID_COUNT(data->szTip));
}

void lucid_tray_add(void) {
    if (!lucid_window) return;
    if (!icon) icon = draw_icon(state);
    NOTIFYICONDATAW data;
    fill(&data);
    /* After Windows Explorer restarts, the icon is gone although Lucid added it. */
    if (added) Shell_NotifyIconW(NIM_DELETE, &data);
    added = Shell_NotifyIconW(NIM_ADD, &data) != FALSE;
}

void lucid_tray_remove(void) {
    if (added) {
        NOTIFYICONDATAW data;
        fill(&data);
        Shell_NotifyIconW(NIM_DELETE, &data);
        added = false;
    }
    if (icon) DestroyIcon(icon);
    icon = NULL;
}

bool lucid_tray_shown(void) {
    return added;
}

void lucid_tray_update(int new_state, const char *tooltip) {
    wchar_t *wide = lucid_wide(tooltip);
    bool same_tip = lstrcmpW(wide, tip) == 0;
    lstrcpynW(tip, wide, (int)LUCID_COUNT(tip));
    free(wide);

    HICON old = NULL;
    if (new_state != state || !icon) {
        old = icon;
        state = new_state;
        icon = draw_icon(state);
    } else if (same_tip) {
        return;
    }
    if (added) {
        NOTIFYICONDATAW data;
        fill(&data);
        Shell_NotifyIconW(NIM_MODIFY, &data);
    }
    if (old) DestroyIcon(old);
}

void lucid_tray_notify(const char *title, const char *text) {
    if (!added) return;
    NOTIFYICONDATAW data;
    fill(&data);
    data.uFlags |= NIF_INFO;
    data.dwInfoFlags = NIIF_INFO;
    wchar_t *wide_title = lucid_wide(title), *wide_text = lucid_wide(text);
    lstrcpynW(data.szInfoTitle, wide_title, (int)LUCID_COUNT(data.szInfoTitle));
    lstrcpynW(data.szInfo, wide_text, (int)LUCID_COUNT(data.szInfo));
    free(wide_title);
    free(wide_text);
    Shell_NotifyIconW(NIM_MODIFY, &data);
}

void lucid_menu_clear(void) {
    for (int index = 0; index < item_count; index++) free(items[index].title);
    item_count = 0;
}

void lucid_menu_add(int command, const char *title, int flags) {
    if (item_count >= MOST_ITEMS) return;
    items[item_count].command = command;
    items[item_count].flags = flags;
    items[item_count].title = lucid_wide(title);
    item_count++;
}

/* Builds the menu that starts at `*index`, up to the end of that submenu. */
static HMENU build(int *index) {
    HMENU menu = CreatePopupMenu();
    if (!menu) return NULL;
    while (*index < item_count) {
        const Item *item = &items[(*index)++];
        if (item->flags & LUCID_MENU_CLOSES) break;
        if (item->flags & LUCID_MENU_SEPARATOR) {
            AppendMenuW(menu, MF_SEPARATOR, 0, NULL);
            continue;
        }
        UINT look = MF_STRING;
        if (item->flags & LUCID_MENU_CHECKED) look |= MF_CHECKED;
        if (item->flags & LUCID_MENU_DISABLED) look |= MF_GRAYED;
        if (item->flags & LUCID_MENU_OPENS) {
            HMENU inner = build(index);
            if (inner) AppendMenuW(menu, look | MF_POPUP, (UINT_PTR)inner, item->title);
        } else {
            AppendMenuW(menu, look, (UINT_PTR)item->command, item->title);
        }
    }
    return menu;
}

static void show_menu(void) {
    if (lucid_callbacks.menu_opening) lucid_callbacks.menu_opening();
    int index = 0;
    HMENU menu = build(&index);
    if (!menu) return;
    POINT pointer = {0, 0};
    GetCursorPos(&pointer);
    /* Without this, the menu stays open when the user clicks somewhere else. */
    SetForegroundWindow(lucid_window);
    int chosen = (int)TrackPopupMenu(
        menu, TPM_RIGHTBUTTON | TPM_RETURNCMD | TPM_NONOTIFY, pointer.x, pointer.y, 0, lucid_window, NULL);
    PostMessageW(lucid_window, WM_NULL, 0, 0);
    DestroyMenu(menu);
    if (chosen != 0 && lucid_callbacks.menu_chosen) lucid_callbacks.menu_chosen(chosen);
}

void lucid_tray_clicked(LPARAM event) {
    switch (LOWORD(event)) {
    case WM_LBUTTONUP:
    case WM_LBUTTONDBLCLK:
        if (lucid_callbacks.activated) lucid_callbacks.activated();
        break;
    case WM_RBUTTONUP:
    case WM_CONTEXTMENU:
        show_menu();
        break;
    default:
        break;
    }
}

bool lucid_test_tray_picture(const char *path, uint32_t background) {
    if (!icon) icon = draw_icon(state);
    int size = GetSystemMetrics(SM_CXSMICON);
    int margin = size / 2;
    LucidCanvas canvas;
    if (!icon || !lucid_canvas_make(&canvas, size + margin * 2, size + margin * 2)) return false;
    /* The colour goes on first, so that what Windows draws over it is what gets saved. */
    lucid_fill_round(&canvas, 0, 0, (float)canvas.width, (float)canvas.height, 0, background, 1);
    DrawIconEx(canvas.dc, margin, margin, icon, size, size, 0, NULL, DI_NORMAL);
    GdiFlush();
    /* Windows leaves the pixels it drew marked see-through. They are not. */
    for (int index = 0; index < canvas.width * canvas.height; index++) canvas.pixels[index] |= 0xff000000u;
    bool saved = lucid_canvas_save(&canvas, path, background);
    lucid_canvas_free(&canvas);
    return saved;
}

size_t lucid_test_menu(char *out, size_t capacity) {
    if (!out || capacity == 0) return 0;
    out[0] = 0;
    size_t length = 0;
    int depth = 0;
    for (int index = 0; index < item_count; index++) {
        const Item *item = &items[index];
        if (item->flags & LUCID_MENU_CLOSES) {
            if (depth > 0) depth--;
            continue;
        }
        char title[512];
        lucid_narrow(item->title, title, sizeof title);
        char line[640];
        int written = wsprintfA(
            line, "%s%s%s%s\n", depth > 0 ? "    " : "",
            (item->flags & LUCID_MENU_CHECKED) ? "* " : "",
            (item->flags & LUCID_MENU_SEPARATOR) ? "---" : title,
            (item->flags & LUCID_MENU_DISABLED) ? "  (disabled)" : "");
        if (written <= 0 || length + (size_t)written >= capacity) break;
        memcpy(out + length, line, (size_t)written + 1);
        length += (size_t)written;
        if (item->flags & LUCID_MENU_OPENS) depth++;
    }
    return length;
}

#endif
