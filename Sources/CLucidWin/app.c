#include "internal.h"

#ifdef _WIN32

#include <string.h>

HWND lucid_window;
LucidCallbacks lucid_callbacks;

static HANDLE instance_mutex;
static UINT taskbar_created;
static int exit_code;

bool lucid_claim_single_instance(void) {
    instance_mutex = CreateMutexW(NULL, FALSE, L"Local\\Lucid.Dictation.Running");
    if (instance_mutex && GetLastError() == ERROR_ALREADY_EXISTS) {
        CloseHandle(instance_mutex);
        instance_mutex = NULL;
        /* Starting Lucid again is how people look for its window. */
        HWND running = FindWindowW(LUCID_WINDOW_CLASS, NULL);
        if (running) PostMessageW(running, LUCID_WM_OPEN, 0, 0);
        return false;
    }
    return true;
}

static LRESULT CALLBACK window_proc(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    switch (message) {
    case LUCID_WM_KEY:
        if (lucid_callbacks.key) lucid_callbacks.key((int)wparam);
        return 0;
    case LUCID_WM_WAKE:
        if (lucid_callbacks.wake) lucid_callbacks.wake();
        return 0;
    case LUCID_WM_TRAY:
        lucid_tray_clicked(lparam);
        return 0;
    case LUCID_WM_OPEN:
        if (lucid_callbacks.activated) lucid_callbacks.activated();
        return 0;
    case MM_WIM_DATA:
        lucid_mic_data((HWAVEIN)wparam);
        return 0;
    case WM_TIMER:
        if (wparam == LUCID_TIMER_CLIPBOARD) lucid_clipboard_timer();
        else lucid_pill_timer((UINT_PTR)wparam);
        return 0;
    case WM_CLOSE:
        DestroyWindow(window);
        return 0;
    case WM_DESTROY:
        /* While the window still exists: the tray icon cannot be taken away without it. */
        lucid_tray_remove();
        lucid_mic_stop();
        lucid_pill_destroy();
        lucid_window = NULL;
        PostQuitMessage(exit_code);
        return 0;
    default:
        /* Windows Explorer restarted, and took every tray icon with it. */
        if (taskbar_created != 0 && message == taskbar_created) {
            lucid_tray_add();
            return 0;
        }
        return DefWindowProcW(window, message, wparam, lparam);
    }
}

bool lucid_start(const LucidCallbacks *callbacks) {
    if (lucid_window) return true;
    if (callbacks) lucid_callbacks = *callbacks;
    /* Without this, Windows draws Lucid at 96 dots to the inch and stretches it. */
    SetProcessDPIAware();

    WNDCLASSEXW window_class;
    memset(&window_class, 0, sizeof window_class);
    window_class.cbSize = sizeof window_class;
    window_class.lpfnWndProc = window_proc;
    window_class.hInstance = GetModuleHandleW(NULL);
    window_class.lpszClassName = LUCID_WINDOW_CLASS;
    RegisterClassExW(&window_class);

    /* Never shown. It is where Windows sends Lucid's messages. */
    lucid_window = CreateWindowExW(
        WS_EX_TOOLWINDOW, LUCID_WINDOW_CLASS, L"Lucid", WS_POPUP, 0, 0, 0, 0,
        NULL, NULL, GetModuleHandleW(NULL), NULL);
    if (!lucid_window) return false;

    taskbar_created = RegisterWindowMessageW(L"TaskbarCreated");
    lucid_pill_make();
    lucid_tray_add();
    lucid_keyboard_start();
    /* Anything posted before the window existed is due now. */
    PostMessageW(lucid_window, LUCID_WM_WAKE, 0, 0);
    return true;
}

int lucid_run(void) {
    MSG message;
    while (GetMessageW(&message, NULL, 0, 0) > 0) {
        TranslateMessage(&message);
        DispatchMessageW(&message);
    }
    return exit_code;
}

void lucid_pump(int milliseconds) {
    DWORD end = GetTickCount() + (DWORD)(milliseconds < 0 ? 0 : milliseconds);
    for (;;) {
        MSG message;
        while (PeekMessageW(&message, NULL, 0, 0, PM_REMOVE)) {
            if (message.message == WM_QUIT) return;
            TranslateMessage(&message);
            DispatchMessageW(&message);
        }
        DWORD now = GetTickCount();
        if ((int)(end - now) <= 0) return;
        MsgWaitForMultipleObjects(0, NULL, FALSE, end - now, QS_ALLINPUT);
    }
}

void lucid_quit(void) {
    HWND window = lucid_window;
    if (window) PostMessageW(window, WM_CLOSE, 0, 0);
}

void lucid_stop(void) {
    lucid_keyboard_stop();
    /* Destroying the window takes the tray icon, the microphone and the pill with it. */
    if (lucid_window) DestroyWindow(lucid_window);
    lucid_window = NULL;
    if (instance_mutex) {
        CloseHandle(instance_mutex);
        instance_mutex = NULL;
    }
}

void lucid_wake(void) {
    HWND window = lucid_window;
    if (window) PostMessageW(window, LUCID_WM_WAKE, 0, 0);
}

#endif
