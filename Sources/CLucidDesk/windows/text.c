#include "internal.h"

#ifdef _WIN32

#include <stdlib.h>

wchar_t *lucid_wide(const char *text) {
    if (!text) text = "";
    int count = MultiByteToWideChar(CP_UTF8, 0, text, -1, NULL, 0);
    if (count <= 0) count = 1;
    wchar_t *wide = (wchar_t *)calloc((size_t)count, sizeof(wchar_t));
    /* With no memory left even for a few words, nothing else here can work either. */
    if (!wide) abort();
    MultiByteToWideChar(CP_UTF8, 0, text, -1, wide, count);
    wide[count - 1] = 0;
    return wide;
}

size_t lucid_narrow(const wchar_t *text, char *out, size_t capacity) {
    if (!out || capacity == 0) return 0;
    out[0] = 0;
    if (!text) return 0;
    int limit = capacity > 0x7fffffff ? 0x7fffffff : (int)capacity;
    int written = WideCharToMultiByte(CP_UTF8, 0, text, -1, out, limit, NULL, NULL);
    if (written <= 0) {
        /* Too long for `out`. Keep as many whole characters as fit. */
        size_t length = wcslen(text);
        while (length > 0) {
            length--;
            /* Do not cut a pair of code units in half. */
            if (length > 0 && text[length] >= 0xDC00 && text[length] <= 0xDFFF) length--;
            written = WideCharToMultiByte(CP_UTF8, 0, text, (int)length, out, limit - 1, NULL, NULL);
            if (written > 0 || length == 0) {
                out[written > 0 ? written : 0] = 0;
                return (size_t)(written > 0 ? written : 0);
            }
        }
        out[0] = 0;
        return 0;
    }
    return (size_t)written - 1;
}

bool lucid_registry_text(HKEY root, const wchar_t *key, const wchar_t *value, wchar_t *out, DWORD capacity) {
    DWORD bytes = capacity * (DWORD)sizeof(wchar_t);
    out[0] = 0;
    LSTATUS status = RegGetValueW(root, key, value, RRF_RT_REG_SZ, NULL, out, &bytes);
    return status == ERROR_SUCCESS;
}

#endif
