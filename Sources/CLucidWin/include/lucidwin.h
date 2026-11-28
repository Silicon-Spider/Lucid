/* Everything Lucid asks of Windows, in plain C: the tray icon and its menu, the dictation
   key, the microphone, the pill, and typing into the app in front.

   All text is UTF-8. Unless a function says "any thread", call it on the thread that
   called lucid_start, which is also the thread every callback arrives on. */
#ifndef LUCIDWIN_H
#define LUCIDWIN_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* What the keyboard reports. */
enum {
    LUCID_KEY_DOWN = 0,   /* the dictation key went down */
    LUCID_KEY_UP = 1,     /* the dictation key came up */
    LUCID_KEY_OTHER = 2,  /* any other key went down */
    LUCID_KEY_ESCAPE = 3  /* Escape went down, and Lucid kept it from the app in front */
};

/* What the pill shows. */
enum {
    LUCID_PILL_HIDDEN = 0,
    LUCID_PILL_RECORDING = 1,
    LUCID_PILL_HANDS_FREE = 2,
    LUCID_PILL_PROCESSING = 3,
    LUCID_PILL_MESSAGE = 4
};

/* How a menu item looks. Add them together. */
enum {
    LUCID_MENU_CHECKED = 1,
    LUCID_MENU_DISABLED = 2,
    LUCID_MENU_SEPARATOR = 4,
    LUCID_MENU_OPENS = 8,  /* the items that follow belong to this one's submenu */
    LUCID_MENU_CLOSES = 16 /* ends the submenu. Not an item itself */
};

/* What the tray icon looks like. */
enum {
    LUCID_TRAY_IDLE = 0,
    LUCID_TRAY_RECORDING = 1,
    LUCID_TRAY_ATTENTION = 2
};

typedef struct {
    /* One of LUCID_KEY_*, soon after the key. */
    void (*key)(int signal);
    /* Whether Escape belongs to Lucid at this moment. Asked on another thread while
       Windows waits for the answer, so answer at once. */
    bool (*wants_escape)(void);
    /* Someone called lucid_wake. */
    void (*wake)(void);
    /* The tray menu is about to open. Describe it now, with lucid_menu_clear and lucid_menu_add. */
    void (*menu_opening)(void);
    void (*menu_chosen)(int command);
    /* The tray icon was clicked, or the user started Lucid again while it was running. */
    void (*activated)(void);
} LucidCallbacks;

/* ---- The app ---- */

/* False when Lucid is already running. That copy has been asked to show its window. */
bool lucid_claim_single_instance(void);
/* Lucid's engines are console programs, and Windows opens a console window for each one
   that an app starts. This gives Lucid a console with no window, which they then share.
   Call it before starting them. False if Windows would not, and the windows will show. */
bool lucid_hide_consoles(void);
/* Creates the tray icon and the pill, and starts watching the keyboard. False when
   Windows would not even give Lucid a window. */
bool lucid_start(const LucidCallbacks *callbacks);
/* Handles what Windows sends until lucid_quit. Returns the exit code. */
int lucid_run(void);
/* For tests: handles what Windows sends for this long, then returns. */
void lucid_pump(int milliseconds);
/* Any thread. */
void lucid_quit(void);
/* Takes the tray icon away and stops watching the keyboard. */
void lucid_stop(void);
/* Any thread: has `wake` called on the main thread, soon. */
void lucid_wake(void);

/* ---- The keyboard ---- */

/* Which key starts a dictation, as a Windows virtual-key code. Any thread. */
void lucid_set_hotkey(int virtual_key);
bool lucid_keyboard_watched(void);
/* For tests: also act on key presses made by programs, and make one. */
void lucid_test_accept_made_up_keys(bool accept);
bool lucid_test_press(int virtual_key, bool down);

/* ---- The microphone: 16 kHz, one channel, 16 bits ---- */

int lucid_mic_devices(void);
/* False when Windows' privacy settings keep apps from the microphone. Any thread. */
bool lucid_mic_allowed(void);
bool lucid_mic_start(void);
/* How many samples have been recorded so far. Any thread. */
size_t lucid_mic_count(void);
/* Copies the newest samples, at most `capacity` of them. Returns how many. Any thread. */
size_t lucid_mic_latest(int16_t *out, size_t capacity);
/* Stops recording. Returns how many samples are waiting for lucid_mic_take. */
size_t lucid_mic_stop(void);
/* Copies the recording from its start, at most `capacity` samples, then lets it go. */
size_t lucid_mic_take(int16_t *out, size_t capacity);
/* How loud the last moment was, where speech is roughly 0.02 to 0.2. Any thread. */
float lucid_mic_level(void);
/* For tests: pretend the microphone is this loud. Negative to stop pretending. */
void lucid_test_level(float level);

/* ---- The pill ---- */

/* `text` is only used with LUCID_PILL_MESSAGE. */
void lucid_pill_show(int status, const char *text);
/* Shows a message, then hides the pill. */
void lucid_pill_flash(const char *text, int milliseconds);
void lucid_pill_pulse(void);
/* The last few words heard, beside the level bars. */
void lucid_pill_preview(const char *text);
bool lucid_pill_visible(void);
/* For tests: saves the pill as it was last drawn, over a plain colour (0xRRGGBB), as a .bmp file. */
bool lucid_test_pill_picture(const char *path, uint32_t background);

/* ---- The tray icon and its menu ---- */

bool lucid_tray_shown(void);
void lucid_tray_update(int state, const char *tooltip);
/* A notification from the tray icon. */
void lucid_tray_notify(const char *title, const char *text);
void lucid_menu_clear(void);
void lucid_menu_add(int command, const char *title, int flags);
/* For tests: saves the tray icon as Windows draws it, over a plain colour, as a .bmp file. */
bool lucid_test_tray_picture(const char *path, uint32_t background);
/* For tests: the menu as lines of text, as lucid_menu_add built it. Returns its length. */
size_t lucid_test_menu(char *out, size_t capacity);

/* ---- The app in front ---- */

/* Describes the window the user is typing in. `program` gets its file name, such as
   "notepad.exe", and `name` what it calls itself, such as "Notepad". `secure` is set in a
   password box, and `not_text` on the desktop or taskbar. Returns 0 when nothing is in front. */
uintptr_t lucid_front_window(
    char *program, size_t program_capacity, char *name, size_t name_capacity,
    bool *secure, bool *not_text);
/* Puts text on the clipboard, to stay. */
bool lucid_copy(const char *text);
/* The text on the clipboard. Returns its length in bytes. */
size_t lucid_clipboard_text(char *out, size_t capacity);
/* Types text into the app in front: puts it on the clipboard, presses Ctrl+V, and a moment
   later puts back what was on the clipboard. False when there was nowhere to type, and the
   text was left on the clipboard instead. */
bool lucid_paste(const char *text);

/* ---- Windows itself ---- */

/* Opens a folder, a link, or a page of Windows' settings such as "ms-settings:sound". */
bool lucid_open(const char *target);
/* Opens a page in a window of its own, without a browser's toolbar. `profile` is a folder
   the browser may keep that window's settings in. */
bool lucid_open_window(const char *address, const char *profile);
/* Brings forward the window with this title that lucid_open_window made. */
bool lucid_focus_window(const char *title);
void lucid_close_window(const char *title);
/* Shows the file chooser. `patterns` is like "*.bin;*.gguf". Returns the path's length, or
   0 if the user chose nothing. */
size_t lucid_choose_file(const char *title, const char *kinds, const char *patterns, char *out, size_t capacity);
bool lucid_opens_at_login(void);
bool lucid_set_opens_at_login(bool on);
void lucid_alert(const char *title, const char *text);

#ifdef __cplusplus
}
#endif

#endif
