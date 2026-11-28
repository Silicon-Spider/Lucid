/* Drives Lucid's Windows layer without the rest of the app: the pill, the tray icon and its
   menu, the dictation key, the clipboard, and typing into another program's window.

   scripts/test-windows-layer.sh builds this for Windows and runs it under Wine. On a
   Windows PC, build it with the Swift toolchain's clang, as .github/workflows/ci.yml does.
   It presses keys, opens a window to type into, and uses the clipboard, so leave the PC
   alone while it runs. Where nobody is signed in, the checks that need a desktop are skipped. */

#ifndef UNICODE
#define UNICODE
#endif
#define _WIN32_WINNT 0x0A00
#include <windows.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "luciddesk.h"

static int failures;
static int checks;

static void check(bool passed, const char *what) {
    checks++;
    if (!passed) failures++;
    printf("  %s  %s\n", passed ? "ok  " : "FAIL", what);
    fflush(stdout);
}

static void check_text(const char *got, const char *wanted, const char *what) {
    bool same = strcmp(got, wanted) == 0;
    check(same, what);
    if (!same) printf("        wanted \"%s\"\n        got    \"%s\"\n", wanted, got);
}

/* ---- What the layer told us ---- */

static int keys[64];
static int key_count;
static bool escape_is_ours;
static int wakes;
static int menus_opened;
static int chosen_command;
static int activations;
/* False on a PC nobody is signed in to: there is no keyboard for a program to press. */
static bool keys_work;

static void on_key(int signal) {
    if (key_count < 64) keys[key_count++] = signal;
}
static bool on_wants_escape(void) { return escape_is_ours; }
static void on_wake(void) { wakes++; }
static void on_menu_opening(void) {
    menus_opened++;
    lucid_menu_clear();
    lucid_menu_add(41, "First", 0);
    lucid_menu_add(42, "Second", 0);
}
static void on_menu_chosen(int command) { chosen_command = command; }
static void on_activated(void) { activations++; }

static void keys_as_text(char *out) {
    out[0] = 0;
    static const char *names[] = {"down", "up", "other", "escape"};
    for (int index = 0; index < key_count; index++) {
        if (index) strcat(out, " ");
        strcat(out, keys[index] >= 0 && keys[index] < 4 ? names[keys[index]] : "?");
    }
}

static char folder[512];

static const char *in_folder(const char *name) {
    static char path[4][600];
    static int turn;
    turn = (turn + 1) % 4;
    snprintf(path[turn], sizeof path[turn], "%s\\%s", folder, name);
    return path[turn];
}

/* ---- The pill and the tray icon ---- */

static void test_pill(void) {
    printf("Pill\n");
    check(!lucid_pill_visible(), "is hidden to begin with");

    lucid_test_level(0.08f);
    lucid_pill_show(LUCID_PILL_RECORDING, NULL);
    lucid_pump(300);
    check(lucid_pill_visible(), "shows while recording");
    check(lucid_test_pill_picture(in_folder("pill-recording.bmp"), 0x7a8aa0), "draws the level bars");

    lucid_pill_preview("so let's meet at three");
    lucid_pump(100);
    check(lucid_test_pill_picture(in_folder("pill-words.bmp"), 0x7a8aa0), "draws the words heard so far");

    lucid_pill_preview("this is a much longer run of words than the pill has room for, so the start of it must go and only the end stay");
    lucid_pump(100);
    check(lucid_test_pill_picture(in_folder("pill-long-words.bmp"), 0x7a8aa0), "cuts the start of words that are too long");

    lucid_pill_show(LUCID_PILL_HANDS_FREE, NULL);
    lucid_pump(100);
    check(lucid_test_pill_picture(in_folder("pill-hands-free-words.bmp"), 0x7a8aa0), "keeps the words when going hands-free");

    lucid_pill_show(LUCID_PILL_RECORDING, NULL);
    lucid_pill_show(LUCID_PILL_HANDS_FREE, NULL);
    lucid_pump(100);
    check(lucid_test_pill_picture(in_folder("pill-hands-free.bmp"), 0x7a8aa0), "explains hands-free when there are no words yet");

    lucid_pill_pulse();
    check(lucid_test_pill_picture(in_folder("pill-pulse.bmp"), 0x7a8aa0), "bumps to acknowledge a key press");
    lucid_pump(250);

    lucid_test_level(-1);
    lucid_pill_show(LUCID_PILL_PROCESSING, NULL);
    lucid_pump(300);
    check(lucid_test_pill_picture(in_folder("pill-processing.bmp"), 0xf2f2f2), "draws the dots while working");

    lucid_pill_flash("Copied. Press Ctrl+V", 400);
    lucid_pump(100);
    check(lucid_pill_visible(), "shows a message");
    check(lucid_test_pill_picture(in_folder("pill-message.bmp"), 0x7a8aa0), "draws the message");
    lucid_pump(600);
    check(!lucid_pill_visible(), "hides by itself after a message");

    lucid_pill_show(LUCID_PILL_RECORDING, NULL);
    lucid_pill_show(LUCID_PILL_HIDDEN, NULL);
    check(!lucid_pill_visible(), "hides when told to");
}

static void test_tray(void) {
    printf("Tray icon\n");
    printf("        shown beside the clock: %s\n", lucid_tray_shown() ? "yes" : "no");
    /* The icon is white on a dark taskbar and dark on a light one. The pictures are on a
       colour that shows either. */
    lucid_tray_update(LUCID_TRAY_IDLE, "Lucid: ready. Hold Right Ctrl and speak.");
    check(lucid_test_tray_picture(in_folder("tray-idle.bmp"), 0x7a8aa0), "draws its icon");
    lucid_tray_update(LUCID_TRAY_RECORDING, "Lucid: recording");
    check(lucid_test_tray_picture(in_folder("tray-recording.bmp"), 0x7a8aa0), "draws its icon while recording");
    lucid_tray_update(LUCID_TRAY_ATTENTION, "Lucid needs a few things first");
    check(lucid_test_tray_picture(in_folder("tray-attention.bmp"), 0x7a8aa0), "draws its icon when setup is needed");
    lucid_tray_update(LUCID_TRAY_IDLE, "Lucid");

    lucid_menu_clear();
    lucid_menu_add(0, "Ready. Hold Right Ctrl and speak.", LUCID_MENU_DISABLED);
    lucid_menu_add(0, NULL, LUCID_MENU_SEPARATOR);
    lucid_menu_add(0, "Cleanup", LUCID_MENU_OPENS);
    lucid_menu_add(10, "Off: exactly what you said", 0);
    lucid_menu_add(11, "Light: remove fillers, fix punctuation", LUCID_MENU_CHECKED);
    lucid_menu_add(0, NULL, LUCID_MENU_CLOSES);
    lucid_menu_add(1, "Open Lucid\xE2\x80\xA6", 0);
    char menu[2048];
    lucid_test_menu(menu, sizeof menu);
    check_text(
        menu,
        "Ready. Hold Right Ctrl and speak.  (disabled)\n"
        "---\n"
        "Cleanup\n"
        "    Off: exactly what you said\n"
        "    * Light: remove fillers, fix punctuation\n"
        "Open Lucid\xE2\x80\xA6\n",
        "keeps the menu it is given, submenus included");
}

/* Presses Down and Enter a moment after the menu opens. */
static DWORD WINAPI choose_second(LPVOID unused) {
    (void)unused;
    Sleep(700);
    lucid_test_press(VK_DOWN, true);
    lucid_test_press(VK_DOWN, false);
    Sleep(100);
    lucid_test_press(VK_DOWN, true);
    lucid_test_press(VK_DOWN, false);
    Sleep(100);
    lucid_test_press(VK_RETURN, true);
    lucid_test_press(VK_RETURN, false);
    /* If the keys did not reach the menu, close it, or the test would wait for ever. */
    Sleep(1500);
    HWND window = FindWindowW(L"LucidMainWindow", NULL);
    if (window) PostMessageW(window, WM_CANCELMODE, 0, 0);
    return 0;
}

static void test_menu_choice(void) {
    printf("Tray menu\n");
    HWND window = FindWindowW(L"LucidMainWindow", NULL);
    check(window != NULL, "Lucid's own window exists");
    HANDLE presser = CreateThread(NULL, 0, choose_second, NULL, 0, NULL);
    /* What Windows sends when the icon is clicked with the right button. */
    SendMessageW(window, WM_APP + 3, 1, WM_RBUTTONUP);
    WaitForSingleObject(presser, 8000);
    CloseHandle(presser);
    lucid_pump(200);
    check(menus_opened == 1, "asks for the menu when the icon is right-clicked");
    if (keys_work) check(chosen_command == 42, "reports the item that was chosen");

    SendMessageW(window, WM_APP + 3, 1, WM_LBUTTONUP);
    check(activations == 1, "reports a click on the icon");
}

/* ---- The keyboard ---- */

static void press(int key) {
    lucid_test_press(key, true);
    lucid_pump(60);
    lucid_test_press(key, false);
    lucid_pump(60);
}

static void test_keyboard(void) {
    printf("Dictation key\n");
    check(lucid_keyboard_watched(), "Windows lets Lucid watch the keyboard");
    char seen[512];

    /* A key that no keyboard has, to find out whether keys can be pressed at all. */
    lucid_test_accept_made_up_keys(true);
    key_count = 0;
    bool sent = lucid_test_press(0xE8, true) && lucid_test_press(0xE8, false);
    lucid_pump(200);
    lucid_test_accept_made_up_keys(false);
    keys_work = sent && key_count > 0;
    if (!keys_work) {
        printf("        skipped: this desktop does not let a program press keys\n");
        return;
    }

    /* Keys pressed by programs are not the user's, and Lucid's own Ctrl+V is one of them. */
    key_count = 0;
    press(VK_RCONTROL);
    keys_as_text(seen);
    check_text(seen, "", "ignores keys that a program pressed");

    lucid_test_accept_made_up_keys(true);
    key_count = 0;
    lucid_test_press(VK_RCONTROL, true);
    lucid_pump(60);
    lucid_test_press(VK_RCONTROL, true); /* held down, the key repeats */
    lucid_pump(60);
    lucid_test_press(VK_RCONTROL, false);
    lucid_pump(60);
    keys_as_text(seen);
    check_text(seen, "down up", "reports the dictation key going down and up, once each");

    key_count = 0;
    lucid_test_press(VK_RCONTROL, true);
    lucid_pump(60);
    press('A');
    lucid_test_press(VK_RCONTROL, false);
    lucid_pump(60);
    keys_as_text(seen);
    check_text(seen, "down other up", "reports another key pressed meanwhile");

    key_count = 0;
    escape_is_ours = false;
    press(VK_ESCAPE);
    keys_as_text(seen);
    check_text(seen, "", "leaves Escape alone when nothing is being recorded");
    escape_is_ours = true;
    press(VK_ESCAPE);
    keys_as_text(seen);
    check_text(seen, "escape", "takes Escape while recording");
    escape_is_ours = false;

    lucid_set_hotkey(VK_RMENU);
    key_count = 0;
    press(VK_RCONTROL);
    press(VK_RMENU);
    keys_as_text(seen);
    check_text(seen, "other down up", "follows a change of dictation key");
    lucid_set_hotkey(VK_RCONTROL);
    lucid_test_accept_made_up_keys(false);

    wakes = 0;
    lucid_wake();
    lucid_pump(50);
    check(wakes == 1, "wakes the main thread when asked");
}

/* ---- The clipboard and typing ---- */

/* Another program to type into: this program again, as a window with one box for text. Which
   editor comes with Windows, and what it is made of, differs from one version to the next. */
#define EDITOR_CLASS L"LucidTestEditor"

static LRESULT CALLBACK editor_proc(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    static HWND box;
    switch (message) {
    case WM_CREATE:
        box = CreateWindowExW(
            0, L"EDIT", L"", WS_CHILD | WS_VISIBLE | ES_MULTILINE | ES_AUTOVSCROLL, 0, 0, 0, 0,
            window, NULL, GetModuleHandleW(NULL), NULL);
        return 0;
    case WM_SIZE:
        MoveWindow(box, 0, 0, LOWORD(lparam), HIWORD(lparam), TRUE);
        return 0;
    case WM_SETFOCUS:
        SetFocus(box);
        return 0;
    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    default:
        return DefWindowProcW(window, message, wparam, lparam);
    }
}

static int run_editor(void) {
    WNDCLASSEXW window_class;
    memset(&window_class, 0, sizeof window_class);
    window_class.cbSize = sizeof window_class;
    window_class.lpfnWndProc = editor_proc;
    window_class.hInstance = GetModuleHandleW(NULL);
    window_class.hCursor = LoadCursorW(NULL, (LPCWSTR)IDC_ARROW);
    window_class.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    window_class.lpszClassName = EDITOR_CLASS;
    RegisterClassExW(&window_class);
    HWND window = CreateWindowExW(
        0, EDITOR_CLASS, L"Lucid test editor", WS_OVERLAPPEDWINDOW, 80, 80, 520, 320,
        NULL, NULL, GetModuleHandleW(NULL), NULL);
    if (!window) return 1;
    ShowWindow(window, SW_SHOWNORMAL);
    SetForegroundWindow(window);
    MSG message;
    while (GetMessageW(&message, NULL, 0, 0) > 0) {
        TranslateMessage(&message);
        DispatchMessageW(&message);
    }
    return 0;
}

static HWND editor_box(HWND *frame) {
    HWND window = FindWindowW(EDITOR_CLASS, NULL);
    if (frame) *frame = window;
    return window ? FindWindowExW(window, NULL, L"Edit", NULL) : NULL;
}

/* Windows only lets the program the user is working in bring a window forward. Joining
   that program's input for a moment makes this one count as it. */
static bool bring_forward(HWND window) {
    for (int attempt = 0; attempt < 5 && GetForegroundWindow() != window; attempt++) {
        DWORD mine = GetCurrentThreadId();
        DWORD front = GetWindowThreadProcessId(GetForegroundWindow(), NULL);
        bool joined = front != 0 && front != mine && AttachThreadInput(mine, front, TRUE);
        SetForegroundWindow(window);
        BringWindowToTop(window);
        if (joined) AttachThreadInput(mine, front, FALSE);
        lucid_pump(200);
    }
    return GetForegroundWindow() == window;
}

static void text_of(HWND edit, char *out, size_t capacity) {
    wchar_t wide[1024];
    wide[0] = 0;
    SendMessageW(edit, WM_GETTEXT, 1024, (LPARAM)wide);
    WideCharToMultiByte(CP_UTF8, 0, wide, -1, out, (int)capacity, NULL, NULL);
}

static void test_clipboard_and_typing(void) {
    printf("Clipboard\n");
    char got[1024];
    const char *words = "Caf\xC3\xA9, na\xC3\xAFve \xE2\x80\x94 \xF0\x9F\x8E\x89 done.";
    check(lucid_copy(words), "copies text");
    lucid_clipboard_text(got, sizeof got);
    check_text(got, words, "keeps accents, dashes and emoji");

    printf("Typing into the app in front\n");
    if (!keys_work) {
        printf("        skipped: this desktop does not let a program press keys\n");
        return;
    }
    STARTUPINFOW startup;
    PROCESS_INFORMATION process;
    memset(&startup, 0, sizeof startup);
    startup.cb = sizeof startup;
    wchar_t command[700];
    wchar_t self_path[600];
    GetModuleFileNameW(NULL, self_path, 600);
    wsprintfW(command, L"\"%s\" editor", self_path);
    if (!CreateProcessW(NULL, command, NULL, NULL, FALSE, 0, NULL, NULL, &startup, &process)) {
        check(false, "another program opens a window");
        return;
    }
    HWND frame = NULL, edit = NULL;
    for (int attempt = 0; attempt < 100 && !edit; attempt++) {
        lucid_pump(100);
        edit = editor_box(&frame);
    }
    check(edit != NULL, "another program opens a window");
    if (!edit) return;
    if (!bring_forward(frame)) {
        /* A PC nobody is signed in to has no window "in front" at all. */
        printf("        skipped: this desktop does not let a window be brought to the front\n");
        TerminateProcess(process.hProcess, 0);
        CloseHandle(process.hThread);
        CloseHandle(process.hProcess);
        return;
    }
    lucid_pump(300);

    char program[260], name[260];
    bool secure = true, not_text = true;
    uintptr_t front = lucid_front_window(program, sizeof program, name, sizeof name, &secure, &not_text);
    check(front == (uintptr_t)frame, "sees which window is in front");
    char own_name[600];
    GetModuleFileNameA(NULL, own_name, sizeof own_name);
    const char *own_file = strrchr(own_name, '\\') ? strrchr(own_name, '\\') + 1 : own_name;
    check(_stricmp(program, own_file) == 0, "knows the program by its file name");
    printf("        program \"%s\", called \"%s\"\n", program, name);
    check(name[0] != 0, "knows what the program calls itself");
    check(!secure && !not_text, "takes it for somewhere to type");

    lucid_copy("what the user had copied");
    check(lucid_paste("So let's meet at three."), "pastes into it");
    lucid_pump(400);
    text_of(edit, got, sizeof got);
    check_text(got, "So let's meet at three.", "the text arrives in the document");
    lucid_pump(700);
    lucid_clipboard_text(got, sizeof got);
    check_text(got, "what the user had copied", "puts back what was on the clipboard");

    /* Something that is not text: a picture's worth of bytes under a format of its own. */
    UINT format = RegisterClipboardFormatW(L"Lucid Test Format");
    unsigned char picture[5000];
    for (size_t index = 0; index < sizeof picture; index++) picture[index] = (unsigned char)(index * 7);
    HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE, sizeof picture);
    memcpy(GlobalLock(memory), picture, sizeof picture);
    GlobalUnlock(memory);
    OpenClipboard(NULL);
    EmptyClipboard();
    SetClipboardData(format, memory);
    CloseClipboard();
    check(lucid_paste(" Second."), "pastes again");
    lucid_pump(400);
    text_of(edit, got, sizeof got);
    check_text(got, "So let's meet at three. Second.", "the second text follows the first");
    lucid_pump(700);
    bool same = false;
    if (OpenClipboard(NULL)) {
        HANDLE back = GetClipboardData(format);
        if (back && GlobalSize(back) >= sizeof picture) {
            same = memcmp(GlobalLock(back), picture, sizeof picture) == 0;
            GlobalUnlock(back);
        }
        check(!IsClipboardFormatAvailable(CF_UNICODETEXT), "the dictation does not stay on the clipboard");
        CloseClipboard();
    }
    check(same, "puts back a clipboard that held something other than text");

    /* The user copies something else straight after the paste. That must not be undone. */
    lucid_copy("before");
    lucid_paste(" Third.");
    lucid_pump(200);
    lucid_copy("copied by the user meanwhile");
    lucid_pump(900);
    lucid_clipboard_text(got, sizeof got);
    check_text(got, "copied by the user meanwhile", "leaves alone what the user copied in the meantime");

    TerminateProcess(process.hProcess, 0);
    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);
    lucid_pump(300);
}

/* ---- Windows itself ---- */

static void test_system(const char *self) {
    printf("Opening at sign-in\n");
    /* A real Lucid on this PC may be set to open at sign-in. Remember that, and put it back. */
    const wchar_t *run_key = L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
    wchar_t before[1200];
    DWORD before_bytes = sizeof before;
    bool had = RegGetValueW(HKEY_CURRENT_USER, run_key, L"Lucid", RRF_RT_REG_SZ, NULL, before, &before_bytes) == ERROR_SUCCESS;
    lucid_set_opens_at_login(false);
    check(!lucid_opens_at_login(), "is off to begin with");
    check(lucid_set_opens_at_login(true), "can be switched on");
    check(lucid_opens_at_login(), "is then on");
    check(lucid_set_opens_at_login(false), "can be switched off");
    check(!lucid_opens_at_login(), "is then off");
    if (had) RegSetKeyValueW(HKEY_CURRENT_USER, run_key, L"Lucid", REG_SZ, before, before_bytes);

    printf("Microphone\n");
    printf("        microphones: %d, allowed by Windows: %s\n", lucid_mic_devices(), lucid_mic_allowed() ? "yes" : "no");
    if (lucid_mic_devices() > 0) {
        check(lucid_mic_start(), "starts recording");
        /* A microphone takes a moment to get going, so the second that is measured is a later one. */
        lucid_pump(700);
        size_t settled = lucid_mic_count();
        lucid_pump(1000);
        size_t so_far = lucid_mic_count();
        int16_t latest[1600];
        size_t newest = lucid_mic_latest(latest, 1600);
        size_t total = lucid_mic_stop();
        printf("        %u samples in one second, %u in all\n", (unsigned)(so_far - settled), (unsigned)total);
        check(so_far - settled > 14400 && so_far - settled < 17600, "records about 16,000 samples a second");
        check(newest == 1600, "hands over the newest samples while recording");
        int16_t *all = (int16_t *)calloc(total + 1, sizeof(int16_t));
        check(lucid_mic_take(all, total) == total && total >= so_far, "hands over the whole recording");
        long loud = 0;
        for (size_t index = 0; index < total; index++) loud += all[index] > 500 || all[index] < -500;
        printf("        %ld of them louder than silence\n", loud);
        FILE *file = fopen(in_folder("recorded.raw"), "wb");
        if (file) {
            fwrite(all, sizeof(int16_t), total, file);
            fclose(file);
        }
        free(all);
        check(lucid_mic_count() == 0, "then lets it go");
    }

    /* Wine has no consoles without windows, so this is only reported. */
    printf("Engines without console windows\n");
    printf("        a console for them to share: %s\n", lucid_hide_consoles() ? "yes" : "no");

    printf("Lucid's window\n");
    /* A stand-in for the browser: this program again, which writes down how it was started. */
    SetEnvironmentVariableA("LUCID_BROWSER", self);
    SetEnvironmentVariableA("LUCID_HARNESS_NOTE", in_folder("browser.txt"));
    DeleteFileA(in_folder("browser.txt"));
    check(lucid_open_window("http://127.0.0.1:5123/#home&key=0123abcd", "C:\\Users\\Some One\\Lucid\\window"), "starts the browser");
    char started[2048];
    started[0] = 0;
    for (int attempt = 0; attempt < 50 && !started[0]; attempt++) {
        lucid_pump(100);
        FILE *file = fopen(in_folder("browser.txt"), "rb");
        if (file) {
            size_t length = fread(started, 1, sizeof started - 1, file);
            started[length] = 0;
            fclose(file);
        }
    }
    printf("        %s\n", started);
    check(strstr(started, "\"--app=http://127.0.0.1:5123/#home&key=0123abcd\"") != NULL, "gives it the page's address, key included");
    check(strstr(started, "\"--user-data-dir=C:\\Users\\Some One\\Lucid\\window\"") != NULL, "gives it a profile folder of its own, spaces and all");
    SetEnvironmentVariableA("LUCID_BROWSER", NULL);

    printf("Running twice\n");
    activations = 0;
    STARTUPINFOA startup;
    PROCESS_INFORMATION process;
    memset(&startup, 0, sizeof startup);
    startup.cb = sizeof startup;
    char command[700];
    snprintf(command, sizeof command, "\"%s\" second", self);
    if (CreateProcessA(NULL, command, NULL, NULL, FALSE, 0, NULL, NULL, &startup, &process)) {
        WaitForSingleObject(process.hProcess, 10000);
        DWORD code = 99;
        GetExitCodeProcess(process.hProcess, &code);
        CloseHandle(process.hThread);
        CloseHandle(process.hProcess);
        lucid_pump(300);
        check(code == 7, "a second copy sees that Lucid is already running");
        check(activations == 1, "and the first is asked to show its window");
    } else {
        check(false, "a second copy starts");
    }
}

int main(int argc, char **argv) {
    /* Started as the stand-in browser: write down the command and leave. */
    const char *note = getenv("LUCID_HARNESS_NOTE");
    if (note && argc > 1 && strncmp(argv[1], "--app=", 6) == 0) {
        FILE *file = fopen(note, "wb");
        if (file) {
            char command[2048];
            WideCharToMultiByte(CP_UTF8, 0, GetCommandLineW(), -1, command, sizeof command, NULL, NULL);
            fputs(command, file);
            fclose(file);
        }
        return 0;
    }
    if (argc > 1 && strcmp(argv[1], "second") == 0) return lucid_claim_single_instance() ? 0 : 7;
    if (argc > 1 && strcmp(argv[1], "editor") == 0) return run_editor();

    snprintf(folder, sizeof folder, "%s", argc > 1 ? argv[1] : ".");
    char self[600];
    GetModuleFileNameA(NULL, self, sizeof self);

    check(lucid_claim_single_instance(), "the first copy of Lucid may run");
    LucidCallbacks callbacks = {on_key, on_wants_escape, on_wake, on_menu_opening, on_menu_chosen, on_activated};
    check(lucid_start(&callbacks), "Windows gives Lucid its window");
    lucid_pump(200);

    test_pill();
    test_tray();
    test_keyboard();
    test_clipboard_and_typing();
    test_menu_choice();
    test_system(self);

    lucid_quit();
    int code = lucid_run();
    lucid_stop();
    check(code == 0, "quits cleanly");
    printf("%s  %d checks, %d failed\n", failures ? "FAILED" : "PASSED", checks, failures);
    return failures ? 1 : 0;
}
