#include "internal.h"

#ifdef _WIN32

#include <stdlib.h>
#include <string.h>

/* The rest of what Lucid asks of Windows: opening things, its own window, the file
   chooser, and starting when the user signs in. */

bool lucid_open(const char *target) {
    wchar_t *wide = lucid_wide(target);
    HINSTANCE result = ShellExecuteW(NULL, L"open", wide, NULL, NULL, SW_SHOWNORMAL);
    free(wide);
    return (INT_PTR)result > 32;
}

/* ---- Lucid's window: a page shown by the browser, without the browser's toolbar ---- */

static bool exists(const wchar_t *path) {
    DWORD attributes = GetFileAttributesW(path);
    return attributes != INVALID_FILE_ATTRIBUTES && !(attributes & FILE_ATTRIBUTE_DIRECTORY);
}

/* Where a browser is installed, as Windows records it. */
static bool registered(const wchar_t *program, wchar_t *path, DWORD capacity) {
    wchar_t key[160];
    wsprintfW(key, L"Software\\Microsoft\\Windows\\CurrentVersion\\App Paths\\%s", program);
    static const HKEY roots[] = {HKEY_CURRENT_USER, HKEY_LOCAL_MACHINE};
    for (size_t index = 0; index < LUCID_COUNT(roots); index++) {
        if (lucid_registry_text(roots[index], key, NULL, path, capacity) && exists(path)) return true;
    }
    return false;
}

/* A browser that can show a page in a window of its own. Edge comes with Windows. Setting
   LUCID_BROWSER to the path of another one, built on Chromium, uses that instead. */
static bool find_browser(wchar_t *path, DWORD capacity) {
    DWORD chosen = GetEnvironmentVariableW(L"LUCID_BROWSER", path, capacity);
    if (chosen > 0 && chosen < capacity && exists(path)) return true;
    static const wchar_t *programs[] = {L"msedge.exe", L"chrome.exe", L"brave.exe"};
    for (size_t index = 0; index < LUCID_COUNT(programs); index++) {
        if (registered(programs[index], path, capacity)) return true;
    }
    static const wchar_t *usual[] = {
        L"%ProgramFiles(x86)%\\Microsoft\\Edge\\Application\\msedge.exe",
        L"%ProgramFiles%\\Microsoft\\Edge\\Application\\msedge.exe",
    };
    for (size_t index = 0; index < LUCID_COUNT(usual); index++) {
        DWORD length = ExpandEnvironmentStringsW(usual[index], path, capacity);
        if (length > 0 && length <= capacity && exists(path)) return true;
    }
    return false;
}

bool lucid_open_window(const char *address, const char *profile) {
    wchar_t browser[1024];
    if (!find_browser(browser, (DWORD)LUCID_COUNT(browser))) {
        /* No such browser. The page still works as a tab in whichever one there is. */
        return lucid_open(address);
    }
    wchar_t *wide_address = lucid_wide(address), *wide_profile = lucid_wide(profile);
    size_t length = wcslen(browser) + wcslen(wide_address) + wcslen(wide_profile) + 200;
    wchar_t *command = (wchar_t *)calloc(length, sizeof(wchar_t));
    bool started = false;
    if (command) {
        /* A profile of its own keeps the page away from the extensions of the user's
           browser, which could otherwise read what they dictated. */
        lstrcpyW(command, L"\"");
        lstrcatW(command, browser);
        lstrcatW(command, L"\" \"--app=");
        lstrcatW(command, wide_address);
        lstrcatW(command, L"\" \"--user-data-dir=");
        lstrcatW(command, wide_profile);
        lstrcatW(command, L"\" --no-first-run --no-default-browser-check --hide-crash-restore-bubble --window-size=1040,760");
        STARTUPINFOW startup;
        PROCESS_INFORMATION process;
        memset(&startup, 0, sizeof startup);
        memset(&process, 0, sizeof process);
        startup.cb = sizeof startup;
        if (CreateProcessW(browser, command, NULL, NULL, FALSE, 0, NULL, NULL, &startup, &process)) {
            CloseHandle(process.hThread);
            CloseHandle(process.hProcess);
            started = true;
        }
        free(command);
    }
    free(wide_address);
    free(wide_profile);
    return started || lucid_open(address);
}

typedef struct {
    const wchar_t *title;
    HWND found;
} Search;

static BOOL CALLBACK look(HWND window, LPARAM context) {
    Search *search = (Search *)context;
    if (!IsWindowVisible(window)) return TRUE;
    wchar_t class_name[64];
    if (!GetClassNameW(window, class_name, (int)LUCID_COUNT(class_name))) return TRUE;
    /* The windows of Edge, Chrome and their relatives. */
    if (wcsncmp(class_name, L"Chrome_WidgetWin", 16) != 0) return TRUE;
    wchar_t title[256];
    GetWindowTextW(window, title, (int)LUCID_COUNT(title));
    if (lstrcmpW(title, search->title) != 0) return TRUE;
    search->found = window;
    return FALSE;
}

static HWND find_window(const char *title) {
    wchar_t *wide = lucid_wide(title);
    Search search = {wide, NULL};
    EnumWindows(look, (LPARAM)&search);
    free(wide);
    return search.found;
}

/* Windows only lets the program the user is working in bring a window forward. Joining
   that program's input for a moment makes Lucid count as it. */
static void bring_forward(HWND window) {
    DWORD mine = GetCurrentThreadId();
    DWORD front = GetWindowThreadProcessId(GetForegroundWindow(), NULL);
    bool joined = front != 0 && front != mine && AttachThreadInput(mine, front, TRUE);
    if (IsIconic(window)) ShowWindow(window, SW_RESTORE);
    SetForegroundWindow(window);
    BringWindowToTop(window);
    if (joined) AttachThreadInput(mine, front, FALSE);
}

bool lucid_focus_window(const char *title) {
    HWND window = find_window(title);
    if (!window) return false;
    bring_forward(window);
    return true;
}

void lucid_close_window(const char *title) {
    HWND window = find_window(title);
    if (window) PostMessageW(window, WM_CLOSE, 0, 0);
}

/* ---- The file chooser ---- */

size_t lucid_choose_file(const char *title, const char *kinds, const char *patterns, char *out, size_t capacity) {
    if (out && capacity) out[0] = 0;
    wchar_t *wide_title = lucid_wide(title), *wide_kinds = lucid_wide(kinds), *wide_patterns = lucid_wide(patterns);

    /* "Models (*.gguf)", then the pattern, then "All files" and its pattern, each ended
       by a zero and the whole by two. */
    wchar_t filter[512];
    memset(filter, 0, sizeof filter);
    size_t used = 0, room = LUCID_COUNT(filter) - 2;
    const wchar_t *parts[] = {wide_kinds, L" (", wide_patterns, L")", NULL, wide_patterns, NULL, L"All files", NULL, L"*.*", NULL};
    for (size_t index = 0; index < LUCID_COUNT(parts); index++) {
        if (!parts[index]) {
            if (used < room) used++; /* the zero between two parts */
            continue;
        }
        for (const wchar_t *each = parts[index]; *each && used < room; each++) filter[used++] = *each;
    }

    /* The request comes from Lucid's page in the browser, so the chooser would open behind
       it. A window that stays on top, to own the chooser, keeps it in front. */
    HWND owner = CreateWindowExW(
        WS_EX_TOPMOST | WS_EX_TOOLWINDOW, L"STATIC", L"", WS_POPUP, 0, 0, 0, 0, NULL, NULL, GetModuleHandleW(NULL), NULL);
    if (owner) bring_forward(owner);

    wchar_t path[2048];
    path[0] = 0;
    OPENFILENAMEW request;
    memset(&request, 0, sizeof request);
    request.lStructSize = sizeof request;
    request.hwndOwner = owner;
    request.lpstrFilter = filter;
    request.lpstrFile = path;
    request.nMaxFile = (DWORD)LUCID_COUNT(path);
    request.lpstrTitle = wide_title;
    request.Flags = OFN_EXPLORER | OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_HIDEREADONLY | OFN_NOCHANGEDIR;
    size_t length = 0;
    if (GetOpenFileNameW(&request)) length = lucid_narrow(path, out, capacity);

    if (owner) DestroyWindow(owner);
    free(wide_title);
    free(wide_kinds);
    free(wide_patterns);
    return length;
}

/* ---- Starting when the user signs in ---- */

#define RUN_KEY L"Software\\Microsoft\\Windows\\CurrentVersion\\Run"
#define RUN_NAME L"Lucid"

/* This program's path in quotes, as Windows wants it in the list of what to start. */
static bool own_command(wchar_t *out, DWORD capacity) {
    wchar_t path[1024];
    DWORD length = GetModuleFileNameW(NULL, path, (DWORD)LUCID_COUNT(path));
    if (length == 0 || length >= LUCID_COUNT(path) || length + 3 > capacity) return false;
    out[0] = L'"';
    memcpy(out + 1, path, length * sizeof(wchar_t));
    out[length + 1] = L'"';
    out[length + 2] = 0;
    return true;
}

bool lucid_opens_at_login(void) {
    wchar_t listed[1100], mine[1100];
    if (!lucid_registry_text(HKEY_CURRENT_USER, RUN_KEY, RUN_NAME, listed, (DWORD)LUCID_COUNT(listed))) return false;
    /* A copy of Lucid somewhere else being listed does not make this one start. */
    return own_command(mine, (DWORD)LUCID_COUNT(mine)) && lstrcmpiW(listed, mine) == 0;
}

bool lucid_set_opens_at_login(bool on) {
    if (!on) {
        LSTATUS status = RegDeleteKeyValueW(HKEY_CURRENT_USER, RUN_KEY, RUN_NAME);
        return status == ERROR_SUCCESS || status == ERROR_FILE_NOT_FOUND;
    }
    wchar_t mine[1100];
    if (!own_command(mine, (DWORD)LUCID_COUNT(mine))) return false;
    DWORD bytes = (DWORD)((wcslen(mine) + 1) * sizeof(wchar_t));
    return RegSetKeyValueW(HKEY_CURRENT_USER, RUN_KEY, RUN_NAME, REG_SZ, mine, bytes) == ERROR_SUCCESS;
}

void lucid_alert(const char *title, const char *text) {
    wchar_t *wide_title = lucid_wide(title), *wide_text = lucid_wide(text);
    MessageBoxW(NULL, wide_text, wide_title, MB_OK | MB_ICONINFORMATION | MB_SETFOREGROUND);
    free(wide_title);
    free(wide_text);
}

#endif
