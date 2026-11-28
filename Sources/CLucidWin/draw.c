#include "internal.h"

#ifdef _WIN32

#include <math.h>
#include <stdlib.h>
#include <string.h>

/* Windows' own drawing has no smooth edges and no see-through pixels, so the pill and the
   tray icon are drawn here, a pixel at a time. Windows is only asked to shape the letters. */

bool lucid_canvas_make(LucidCanvas *canvas, int width, int height) {
    memset(canvas, 0, sizeof *canvas);
    if (width <= 0 || height <= 0) return false;
    BITMAPINFO info;
    memset(&info, 0, sizeof info);
    info.bmiHeader.biSize = sizeof info.bmiHeader;
    info.bmiHeader.biWidth = width;
    info.bmiHeader.biHeight = -height; /* top row first */
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    info.bmiHeader.biCompression = BI_RGB;
    void *bits = NULL;
    HDC screen = GetDC(NULL);
    canvas->dc = CreateCompatibleDC(screen);
    canvas->bitmap = CreateDIBSection(screen, &info, DIB_RGB_COLORS, &bits, NULL, 0);
    ReleaseDC(NULL, screen);
    if (!canvas->dc || !canvas->bitmap || !bits) {
        lucid_canvas_free(canvas);
        return false;
    }
    canvas->old = SelectObject(canvas->dc, canvas->bitmap);
    canvas->pixels = (uint32_t *)bits;
    canvas->width = width;
    canvas->height = height;
    lucid_canvas_clear(canvas);
    return true;
}

void lucid_canvas_free(LucidCanvas *canvas) {
    if (canvas->dc && canvas->old) SelectObject(canvas->dc, canvas->old);
    if (canvas->dc) DeleteDC(canvas->dc);
    if (canvas->bitmap) DeleteObject(canvas->bitmap);
    memset(canvas, 0, sizeof *canvas);
}

void lucid_canvas_clear(LucidCanvas *canvas) {
    if (canvas->pixels) memset(canvas->pixels, 0, (size_t)canvas->width * (size_t)canvas->height * 4);
}

/* How much of the pixel centred on (x, y) the round rectangle covers, from 0 to 1. */
static float coverage(float x, float y, float left, float top, float right, float bottom, float radius) {
    float half_width = (right - left) / 2, half_height = (bottom - top) / 2;
    if (half_width <= 0 || half_height <= 0) return 0;
    if (radius > half_width) radius = half_width;
    if (radius > half_height) radius = half_height;
    float dx = fabsf(x - (left + right) / 2) - (half_width - radius);
    float dy = fabsf(y - (top + bottom) / 2) - (half_height - radius);
    float ox = dx > 0 ? dx : 0, oy = dy > 0 ? dy : 0;
    float inside = dx > dy ? dx : dy;
    if (inside > 0) inside = 0;
    float distance = sqrtf(ox * ox + oy * oy) + inside - radius;
    float covered = 0.5f - distance;
    return covered < 0 ? 0 : covered > 1 ? 1 : covered;
}

/* Lays a colour over one pixel. `amount` is how much of the pixel it covers. */
static void blend(uint32_t *pixel, uint32_t rgb, float amount) {
    if (amount <= 0) return;
    if (amount > 1) amount = 1;
    float keep = 1 - amount;
    uint32_t old = *pixel;
    float blue = (float)(rgb & 0xff) * amount + (float)(old & 0xff) * keep;
    float green = (float)((rgb >> 8) & 0xff) * amount + (float)((old >> 8) & 0xff) * keep;
    float red = (float)((rgb >> 16) & 0xff) * amount + (float)((old >> 16) & 0xff) * keep;
    float alpha = 255.0f * amount + (float)(old >> 24) * keep;
    *pixel = (uint32_t)(blue + 0.5f) | ((uint32_t)(green + 0.5f) << 8) | ((uint32_t)(red + 0.5f) << 16)
        | ((uint32_t)(alpha + 0.5f) << 24);
}

static void rows_and_columns(const LucidCanvas *canvas, float left, float top, float right, float bottom, int *x0, int *y0, int *x1, int *y1) {
    *x0 = (int)floorf(left) - 1;
    *y0 = (int)floorf(top) - 1;
    *x1 = (int)ceilf(right) + 1;
    *y1 = (int)ceilf(bottom) + 1;
    if (*x0 < 0) *x0 = 0;
    if (*y0 < 0) *y0 = 0;
    if (*x1 > canvas->width) *x1 = canvas->width;
    if (*y1 > canvas->height) *y1 = canvas->height;
}

void lucid_fill_round(LucidCanvas *canvas, float left, float top, float right, float bottom, float radius, uint32_t rgb, float alpha) {
    if (!canvas->pixels) return;
    int x0, y0, x1, y1;
    rows_and_columns(canvas, left, top, right, bottom, &x0, &y0, &x1, &y1);
    for (int y = y0; y < y1; y++) {
        for (int x = x0; x < x1; x++) {
            float covered = coverage((float)x + 0.5f, (float)y + 0.5f, left, top, right, bottom, radius);
            blend(&canvas->pixels[y * canvas->width + x], rgb, covered * alpha);
        }
    }
}

void lucid_stroke_round(LucidCanvas *canvas, float left, float top, float right, float bottom, float radius, float width, uint32_t rgb, float alpha) {
    if (!canvas->pixels) return;
    int x0, y0, x1, y1;
    rows_and_columns(canvas, left, top, right, bottom, &x0, &y0, &x1, &y1);
    float inner = radius - width;
    if (inner < 0) inner = 0;
    for (int y = y0; y < y1; y++) {
        for (int x = x0; x < x1; x++) {
            float px = (float)x + 0.5f, py = (float)y + 0.5f;
            float outside = coverage(px, py, left, top, right, bottom, radius);
            float inside = coverage(px, py, left + width, top + width, right - width, bottom - width, inner);
            blend(&canvas->pixels[y * canvas->width + x], rgb, (outside - inside) * alpha);
        }
    }
}

bool lucid_canvas_save(const LucidCanvas *canvas, const char *path, uint32_t background) {
    if (!canvas->pixels) return false;
    int row_bytes = (canvas->width * 3 + 3) / 4 * 4;
    DWORD image_bytes = (DWORD)row_bytes * (DWORD)canvas->height;
    BITMAPFILEHEADER file;
    BITMAPINFOHEADER info;
    memset(&file, 0, sizeof file);
    memset(&info, 0, sizeof info);
    file.bfType = 0x4D42; /* "BM" */
    file.bfOffBits = sizeof file + sizeof info;
    file.bfSize = file.bfOffBits + image_bytes;
    info.biSize = sizeof info;
    info.biWidth = canvas->width;
    info.biHeight = canvas->height; /* bottom row first */
    info.biPlanes = 1;
    info.biBitCount = 24;
    info.biSizeImage = image_bytes;
    uint8_t *image = (uint8_t *)calloc(image_bytes ? image_bytes : 1, 1);
    if (!image) return false;
    for (int y = 0; y < canvas->height; y++) {
        uint8_t *row = image + (size_t)(canvas->height - 1 - y) * (size_t)row_bytes;
        for (int x = 0; x < canvas->width; x++) {
            uint32_t pixel = canvas->pixels[y * canvas->width + x];
            uint32_t keep = 255 - (pixel >> 24);
            row[x * 3 + 0] = (uint8_t)((pixel & 0xff) + (background & 0xff) * keep / 255);
            row[x * 3 + 1] = (uint8_t)(((pixel >> 8) & 0xff) + ((background >> 8) & 0xff) * keep / 255);
            row[x * 3 + 2] = (uint8_t)(((pixel >> 16) & 0xff) + ((background >> 16) & 0xff) * keep / 255);
        }
    }
    wchar_t *wide = lucid_wide(path);
    HANDLE out = CreateFileW(wide, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    free(wide);
    bool saved = false;
    if (out != INVALID_HANDLE_VALUE) {
        DWORD written = 0;
        saved = WriteFile(out, &file, sizeof file, &written, NULL) && WriteFile(out, &info, sizeof info, &written, NULL)
            && WriteFile(out, image, image_bytes, &written, NULL);
        CloseHandle(out);
    }
    free(image);
    return saved;
}

SIZE lucid_text_size(HFONT font, const wchar_t *text) {
    SIZE size = {0, 0};
    HDC dc = CreateCompatibleDC(NULL);
    if (!dc) return size;
    HGDIOBJ old = SelectObject(dc, font);
    GetTextExtentPoint32W(dc, text, (int)wcslen(text), &size);
    SelectObject(dc, old);
    DeleteDC(dc);
    return size;
}

void lucid_draw_text(LucidCanvas *canvas, HFONT font, const wchar_t *text, int x, int y, int max_width, uint32_t rgb, float alpha) {
    if (!canvas->pixels || !text[0]) return;
    SIZE size = lucid_text_size(font, text);
    if (size.cx > max_width) size.cx = max_width;
    if (size.cx <= 0 || size.cy <= 0) return;

    /* White letters on black, so each pixel's brightness says how much of it a letter covers. */
    LucidCanvas letters;
    if (!lucid_canvas_make(&letters, size.cx, size.cy)) return;
    HGDIOBJ old = SelectObject(letters.dc, font);
    SetBkMode(letters.dc, TRANSPARENT);
    SetTextColor(letters.dc, RGB(255, 255, 255));
    RECT box = {0, 0, size.cx, size.cy};
    DrawTextW(letters.dc, text, -1, &box, DT_LEFT | DT_TOP | DT_SINGLELINE | DT_NOPREFIX | DT_END_ELLIPSIS);
    GdiFlush();
    SelectObject(letters.dc, old);

    for (int row = 0; row < size.cy; row++) {
        int target_y = y + row;
        if (target_y < 0 || target_y >= canvas->height) continue;
        for (int column = 0; column < size.cx; column++) {
            int target_x = x + column;
            if (target_x < 0 || target_x >= canvas->width) continue;
            uint32_t letter = letters.pixels[row * letters.width + column];
            /* Green is the middle of the three, whatever way Windows smoothed the letter. */
            float covered = (float)((letter >> 8) & 0xff) / 255.0f;
            blend(&canvas->pixels[target_y * canvas->width + target_x], rgb, covered * alpha);
        }
    }
    lucid_canvas_free(&letters);
}

#endif
