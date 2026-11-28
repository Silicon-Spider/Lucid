#include "internal.h"

#ifdef _WIN32

#include <stdlib.h>
#include <string.h>

/* Finding out where the user is typing, and putting the dictated text there. */

/* ---- The window in front ---- */

/* The desktop and the taskbar: in front when no app is, and nowhere to type. */
static bool is_shell(HWND window) {
    wchar_t name[64];
    if (!GetClassNameW(window, name, (int)LUCID_COUNT(name))) return false;
    return lstrcmpW(name, L"Progman") == 0 || lstrcmpW(name, L"WorkerW") == 0
        || lstrcmpW(name, L"Shell_TrayWnd") == 0 || lstrcmpW(name, L"Shell_SecondaryTrayWnd") == 0;
}

/* True when the keyboard is in a classic password box. Browsers draw their own and do
   not say. */
static bool in_password_box(HWND window) {
    GUITHREADINFO info;
    memset(&info, 0, sizeof info);
    info.cbSize = sizeof info;
    if (!GetGUIThreadInfo(GetWindowThreadProcessId(window, NULL), &info) || !info.hwndFocus) return false;
    wchar_t name[64];
    if (!GetClassNameW(info.hwndFocus, name, (int)LUCID_COUNT(name))) return false;
    if (lstrcmpiW(name, L"Edit") != 0) return false;
    return (GetWindowLongPtrW(info.hwndFocus, GWL_STYLE) & ES_PASSWORD) != 0;
}

/* What a program calls itself in its file's details, such as "Notepad". */
static bool description(const wchar_t *path, wchar_t *out, size_t capacity) {
    DWORD ignored = 0;
    DWORD size = GetFileVersionInfoSizeW(path, &ignored);
    if (size == 0) return false;
    void *details = malloc(size);
    if (!details) return false;
    bool found = false;
    struct { WORD language; WORD page; } *languages = NULL;
    UINT bytes = 0;
    if (GetFileVersionInfoW(path, 0, size, details)
        && VerQueryValueW(details, L"\\VarFileInfo\\Translation", (LPVOID *)&languages, &bytes)
        && bytes >= sizeof *languages) {
        wchar_t query[64];
        wsprintfW(query, L"\\StringFileInfo\\%04x%04x\\FileDescription", languages[0].language, languages[0].page);
        wchar_t *text = NULL;
        UINT length = 0;
        if (VerQueryValueW(details, query, (LPVOID *)&text, &length) && text && length > 1) {
            lstrcpynW(out, text, (int)capacity);
            found = out[0] != 0;
        }
    }
    free(details);
    return found;
}

uintptr_t lucid_front_window(
    char *program, size_t program_capacity, char *name, size_t name_capacity,
    bool *secure, bool *not_text) {
    if (program && program_capacity) program[0] = 0;
    if (name && name_capacity) name[0] = 0;
    if (secure) *secure = false;
    if (not_text) *not_text = false;
    HWND window = GetForegroundWindow();
    if (!window) return 0;

    DWORD process_id = 0;
    GetWindowThreadProcessId(window, &process_id);
    HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, process_id);
    if (process) {
        wchar_t path[1024];
        DWORD length = (DWORD)LUCID_COUNT(path);
        if (QueryFullProcessImageNameW(process, 0, path, &length)) {
            const wchar_t *file = path;
            for (const wchar_t *each = path; *each; each++) {
                if (*each == L'\\' || *each == L'/') file = each + 1;
            }
            lucid_narrow(file, program, program_capacity);
            wchar_t friendly[256];
            if (description(path, friendly, LUCID_COUNT(friendly))) {
                lucid_narrow(friendly, name, name_capacity);
            } else {
                /* The file name without ".exe" is the next best thing. */
                lstrcpynW(friendly, file, (int)LUCID_COUNT(friendly));
                size_t end = wcslen(friendly);
                if (end > 4 && lstrcmpiW(friendly + end - 4, L".exe") == 0) friendly[end - 4] = 0;
                lucid_narrow(friendly, name, name_capacity);
            }
        }
        CloseHandle(process);
    }
    if (secure) *secure = in_password_box(window);
    if (not_text) *not_text = is_shell(window);
    return (uintptr_t)window;
}

/* ---- The clipboard ---- */

/* Another program may be using the clipboard this instant. It rarely takes long. */
static bool open_clipboard(void) {
    for (int attempt = 0; attempt < 12; attempt++) {
        if (OpenClipboard(lucid_window)) return true;
        Sleep(10);
    }
    return false;
}

static HGLOBAL global_copy(const void *bytes, size_t size) {
    HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE, size ? size : 1);
    if (!memory) return NULL;
    void *target = GlobalLock(memory);
    if (!target) {
        GlobalFree(memory);
        return NULL;
    }
    if (size) memcpy(target, bytes, size);
    GlobalUnlock(memory);
    return memory;
}

/* Puts text on the clipboard, which must be open. With `passing`, it is marked as not
   worth remembering, so clipboard history and other devices do not record every dictation. */
static bool set_text(const char *text, bool passing) {
    wchar_t *wide = lucid_wide(text);
    HGLOBAL memory = global_copy(wide, (wcslen(wide) + 1) * sizeof(wchar_t));
    free(wide);
    if (!memory) return false;
    EmptyClipboard();
    if (!SetClipboardData(CF_UNICODETEXT, memory)) {
        GlobalFree(memory);
        return false;
    }
    if (passing) {
        static const wchar_t *marks[] = {
            L"ExcludeClipboardContentFromMonitorProcessing",
            L"CanIncludeInClipboardHistory",
            L"CanUploadToCloudClipboard",
        };
        for (size_t index = 0; index < LUCID_COUNT(marks); index++) {
            UINT format = RegisterClipboardFormatW(marks[index]);
            DWORD no = 0;
            HGLOBAL mark = format ? global_copy(&no, sizeof no) : NULL;
            if (mark && !SetClipboardData(format, mark)) GlobalFree(mark);
        }
    }
    return true;
}

bool lucid_copy(const char *text) {
    if (!open_clipboard()) return false;
    bool done = set_text(text, false);
    CloseClipboard();
    return done;
}

size_t lucid_clipboard_text(char *out, size_t capacity) {
    if (!out || capacity == 0) return 0;
    out[0] = 0;
    if (!open_clipboard()) return 0;
    size_t length = 0;
    HANDLE memory = GetClipboardData(CF_UNICODETEXT);
    if (memory) {
        const wchar_t *text = (const wchar_t *)GlobalLock(memory);
        if (text) {
            length = lucid_narrow(text, out, capacity);
            GlobalUnlock(memory);
        }
    }
    CloseClipboard();
    return length;
}

/* What was on the clipboard before a dictation was pasted, to put back afterwards. */
#define MOST_KINDS 48
#define MOST_BYTES ((size_t)96 * 1024 * 1024)

typedef struct {
    UINT format;
    HGLOBAL memory;
} Kept;

static Kept kept[MOST_KINDS];
static int kept_count;
static bool keeping;
static DWORD ours;

static void forget_kept(void) {
    for (int index = 0; index < kept_count; index++) GlobalFree(kept[index].memory);
    kept_count = 0;
    keeping = false;
}

/* Kinds of clipboard content that are not plain memory, or that Windows makes from
   another kind by itself. Copying those would fail or only waste memory. */
static bool skipped(UINT format, bool have_text, bool have_picture) {
    switch (format) {
    case CF_BITMAP:
    case CF_PALETTE:
    case CF_METAFILEPICT:
    case CF_ENHMETAFILE:
    case CF_LOCALE:
        return true;
    case CF_TEXT:
    case CF_OEMTEXT:
    case CF_UNICODETEXT:
        return have_text;
    case CF_DIB:
    case CF_DIBV5:
        return have_picture;
    default:
        break;
    }
    if (format >= CF_OWNERDISPLAY && format <= CF_DSPENHMETAFILE) return true;
    if (format >= CF_PRIVATEFIRST && format <= CF_PRIVATELAST) return true;
    if (format >= CF_GDIOBJFIRST && format <= CF_GDIOBJLAST) return true;
    return false;
}

/* Copies what is on the clipboard, which must be open. */
static void keep_clipboard(void) {
    forget_kept();
    keeping = true;
    size_t total = 0;
    bool have_text = false, have_picture = false;
    for (UINT format = EnumClipboardFormats(0); format != 0; format = EnumClipboardFormats(format)) {
        if (skipped(format, have_text, have_picture)) continue;
        if (kept_count >= MOST_KINDS) break;
        HANDLE memory = GetClipboardData(format);
        if (!memory) continue;
        SIZE_T size = GlobalSize(memory);
        if (size == 0) continue;
        if (total + size > MOST_BYTES) {
            /* Too much to copy. Putting back only part would be worse than leaving the
               dictation there. */
            forget_kept();
            return;
        }
        const void *bytes = GlobalLock(memory);
        if (!bytes) continue;
        HGLOBAL copy = global_copy(bytes, size);
        GlobalUnlock(memory);
        if (!copy) continue;
        kept[kept_count].format = format;
        kept[kept_count].memory = copy;
        kept_count++;
        total += size;
        if (format == CF_TEXT || format == CF_OEMTEXT || format == CF_UNICODETEXT) have_text = true;
        if (format == CF_DIB || format == CF_DIBV5) have_picture = true;
    }
}

void lucid_clipboard_timer(void) {
    KillTimer(lucid_window, LUCID_TIMER_CLIPBOARD);
    if (!keeping) return;
    /* If the count moved, the user copied something else. Leave that alone. */
    if (GetClipboardSequenceNumber() != ours || !open_clipboard()) {
        forget_kept();
        return;
    }
    EmptyClipboard();
    for (int index = 0; index < kept_count; index++) {
        if (!SetClipboardData(kept[index].format, kept[index].memory)) GlobalFree(kept[index].memory);
    }
    /* Windows owns the copies now. */
    kept_count = 0;
    keeping = false;
    CloseClipboard();
}

static void key(INPUT *input, WORD virtual_key, bool down) {
    memset(input, 0, sizeof *input);
    input->type = INPUT_KEYBOARD;
    input->ki.wVk = virtual_key;
    input->ki.wScan = (WORD)MapVirtualKeyW(virtual_key, MAPVK_VK_TO_VSC);
    input->ki.dwFlags = down ? 0 : KEYEVENTF_KEYUP;
}

static bool is_down(int virtual_key) {
    return (GetAsyncKeyState(virtual_key) & 0x8000) != 0;
}

bool lucid_paste(const char *text) {
    HWND front = GetForegroundWindow();
    if (!front || is_shell(front) || in_password_box(front)) {
        lucid_copy(text);
        return false;
    }
    if (!open_clipboard()) return false;
    /* A paste that has not been put back yet still holds what the user had. */
    if (!keeping) keep_clipboard();
    bool set = set_text(text, true);
    CloseClipboard();
    if (!set) {
        forget_kept();
        return false;
    }
    ours = GetClipboardSequenceNumber();

    INPUT inputs[12];
    UINT count = 0;
    /* If the user still holds Ctrl, pressing it again would let go of it for them. */
    bool control_held = is_down(VK_CONTROL);
    if (!control_held) key(&inputs[count++], VK_CONTROL, true);
    /* Shift, Alt or the Windows key would turn Ctrl+V into something else. They are let
       go after Ctrl is down, so that Alt or the Windows key alone does not open a menu. */
    static const WORD others[] = {VK_LSHIFT, VK_RSHIFT, VK_LMENU, VK_RMENU, VK_LWIN, VK_RWIN};
    for (size_t index = 0; index < LUCID_COUNT(others); index++) {
        if (is_down(others[index])) key(&inputs[count++], others[index], false);
    }
    key(&inputs[count++], 'V', true);
    key(&inputs[count++], 'V', false);
    if (!control_held) key(&inputs[count++], VK_CONTROL, false);
    if (SendInput(count, inputs, sizeof(INPUT)) != count) {
        /* Windows would not press the keys. The text stays on the clipboard for the user
           to paste, so what was there before is not put back. */
        forget_kept();
        lucid_copy(text);
        return false;
    }
    /* Give the app time to read the clipboard, then put back what was there. */
    SetTimer(lucid_window, LUCID_TIMER_CLIPBOARD, 700, NULL);
    return true;
}

#endif
