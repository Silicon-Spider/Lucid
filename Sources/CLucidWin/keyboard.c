#include "internal.h"

#ifdef _WIN32

/* Windows shows Lucid every key press before the app in front gets it, and waits for Lucid
   to answer. A slow answer makes typing lag for the whole PC, and Windows stops asking a
   program that is slow too often. So the watching has a thread of its own that does nothing
   else, and only passes on what the dictation machine needs. */

static HANDLE thread;
static DWORD thread_id;
static HANDLE ready;
static HHOOK hook;
static volatile LONG hotkey = VK_RCONTROL;
static volatile LONG accept_made_up;
/* The dictation key that is down now, or 0. */
static DWORD held;

static void tell(int signal) {
    HWND window = lucid_window;
    if (window) PostMessageW(window, LUCID_WM_KEY, (WPARAM)signal, 0);
}

static LRESULT CALLBACK key_proc(int code, WPARAM wparam, LPARAM lparam) {
    if (code == HC_ACTION) {
        const KBDLLHOOKSTRUCT *event = (const KBDLLHOOKSTRUCT *)lparam;
        /* Keys that programs press, Lucid's own Ctrl+V among them, are not the user's. */
        bool made_up = (event->flags & LLKHF_INJECTED) != 0;
        if (!made_up || accept_made_up) {
            bool down = wparam == WM_KEYDOWN || wparam == WM_SYSKEYDOWN;
            DWORD key = (DWORD)hotkey;
            /* The user chose another key while the old one was down. */
            if (held != 0 && held != key) held = 0;
            if (event->vkCode == key) {
                /* A key held down repeats. Only the first press counts. */
                if (down && held == 0) {
                    held = key;
                    tell(LUCID_KEY_DOWN);
                } else if (!down && held != 0) {
                    held = 0;
                    tell(LUCID_KEY_UP);
                }
            } else if (down && event->vkCode == VK_ESCAPE) {
                if (lucid_callbacks.wants_escape && lucid_callbacks.wants_escape()) {
                    tell(LUCID_KEY_ESCAPE);
                    /* It cancelled a recording. The app in front must not also act on it. */
                    return 1;
                }
            } else if (down) {
                /* On keyboards with AltGr, Windows makes up a Left Ctrl press before every
                   Right Alt. It is not a key the user pressed. */
                bool made_up_control = event->vkCode == VK_LCONTROL && event->scanCode == 0x21D;
                if (!made_up_control) tell(LUCID_KEY_OTHER);
            }
        }
    }
    return CallNextHookEx(NULL, code, wparam, lparam);
}

static DWORD WINAPI watch(LPVOID unused) {
    (void)unused;
    MSG message;
    /* Makes this thread's message queue exist before anyone posts to it. */
    PeekMessageW(&message, NULL, WM_USER, WM_USER, PM_NOREMOVE);
    hook = SetWindowsHookExW(WH_KEYBOARD_LL, key_proc, GetModuleHandleW(NULL), 0);
    SetEvent(ready);
    if (!hook) return 1;
    while (GetMessageW(&message, NULL, 0, 0) > 0) {
        TranslateMessage(&message);
        DispatchMessageW(&message);
    }
    UnhookWindowsHookEx(hook);
    hook = NULL;
    return 0;
}

bool lucid_keyboard_start(void) {
    if (thread) return hook != NULL;
    held = 0;
    ready = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (!ready) return false;
    thread = CreateThread(NULL, 0, watch, NULL, 0, &thread_id);
    if (!thread) {
        CloseHandle(ready);
        ready = NULL;
        return false;
    }
    WaitForSingleObject(ready, 5000);
    return hook != NULL;
}

void lucid_keyboard_stop(void) {
    if (!thread) return;
    PostThreadMessageW(thread_id, WM_QUIT, 0, 0);
    WaitForSingleObject(thread, 2000);
    CloseHandle(thread);
    thread = NULL;
    if (ready) CloseHandle(ready);
    ready = NULL;
}

void lucid_set_hotkey(int virtual_key) {
    InterlockedExchange(&hotkey, (LONG)virtual_key);
}

bool lucid_keyboard_watched(void) {
    return hook != NULL;
}

void lucid_test_accept_made_up_keys(bool accept) {
    InterlockedExchange(&accept_made_up, accept ? 1 : 0);
}

bool lucid_test_press(int virtual_key, bool down) {
    INPUT input;
    ZeroMemory(&input, sizeof input);
    input.type = INPUT_KEYBOARD;
    input.ki.wVk = (WORD)virtual_key;
    input.ki.wScan = (WORD)MapVirtualKeyW((UINT)virtual_key, MAPVK_VK_TO_VSC);
    input.ki.dwFlags = down ? 0 : KEYEVENTF_KEYUP;
    return SendInput(1, &input, sizeof input) == 1;
}

#endif
