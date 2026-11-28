#include "internal.h"

#ifdef __linux__

#include <X11/Xatom.h>
#include <X11/Xutil.h>
#include <X11/extensions/XTest.h>
#include <X11/keysym.h>
#include <fcntl.h>
#include <linux/uinput.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

/* Finding out where the user is typing, and putting the dictated text there.

   The text goes on the clipboard and Lucid presses Shift+Insert, which pastes in ordinary
   apps and in terminals alike, where Ctrl+V does not. The keys are the same on every
   keyboard layout.

   With X11, any app may press keys in another. With Wayland none may, so Lucid has to
   make a keyboard of its own in /dev/uinput, which the user has to allow. Without that
   the text stays on the clipboard for them to paste. */

static bool can_press_x11;
static int made_keyboard = -1;
static volatile int can_type;

/* ---- The window in front ---- */

static Atom atom(Display *display, const char *name) {
    return XInternAtom(display, name, False);
}

/* One value of a window's property, or 0. */
static unsigned long window_number(Display *display, Window window, const char *property, Atom type) {
    Atom actual = None;
    int format = 0;
    unsigned long count = 0, left = 0;
    unsigned char *data = NULL;
    unsigned long value = 0;
    if (XGetWindowProperty(display, window, atom(display, property), 0, 1, False, type, &actual, &format, &count, &left, &data)
            == Success
        && data) {
        if (count > 0 && format == 32) value = *(unsigned long *)(void *)data;
        XFree(data);
    }
    return value;
}

static bool is_desktop_or_panel(Display *display, Window window) {
    unsigned long kind = window_number(display, window, "_NET_WM_WINDOW_TYPE", XA_ATOM);
    return kind != 0
        && (kind == atom(display, "_NET_WM_WINDOW_TYPE_DESKTOP") || kind == atom(display, "_NET_WM_WINDOW_TYPE_DOCK"));
}

uintptr_t lucid_front_window(
    char *program, size_t program_capacity, char *name, size_t name_capacity,
    bool *secure, bool *not_text) {
    if (program && program_capacity) program[0] = 0;
    if (name && name_capacity) name[0] = 0;
    /* Linux has no one way to tell a password box, so Lucid cannot. */
    if (secure) *secure = false;
    if (not_text) *not_text = false;

    Display *display = lucid_display();
    if (!display) return 0;
    if (lucid_is_wayland()) {
        /* Wayland does not say which window is in front. There is one, as far as Lucid
           knows, and text may go to it. */
        return 1;
    }

    GdkDisplay *gdk = gdk_display_get_default();
    /* The window may close while it is being asked about, which is not worth dying for. */
    gdk_x11_display_error_trap_push(gdk);
    Window root = DefaultRootWindow(display);
    Window window = (Window)window_number(display, root, "_NET_ACTIVE_WINDOW", XA_WINDOW);
    if (window == None) {
        /* A desktop with nothing to say which window is active: the one with the keyboard. */
        int revert = 0;
        XGetInputFocus(display, &window, &revert);
        if (window == root || window == PointerRoot) window = None;
    }
    if (window != None) {
        XClassHint hint = {NULL, NULL};
        if (XGetClassHint(display, window, &hint)) {
            if (name && hint.res_class) g_strlcpy(name, hint.res_class, name_capacity);
            if (program && hint.res_name) g_strlcpy(program, hint.res_name, program_capacity);
            if (hint.res_name) XFree(hint.res_name);
            if (hint.res_class) XFree(hint.res_class);
        }
        /* The program's own file name says more than what its window calls itself. */
        unsigned long process = window_number(display, window, "_NET_WM_PID", XA_CARDINAL);
        if (process != 0 && program) {
            char link[64], path[512];
            g_snprintf(link, sizeof link, "/proc/%lu/exe", process);
            ssize_t length = readlink(link, path, sizeof path - 1);
            if (length > 0) {
                path[length] = 0;
                const char *file = strrchr(path, '/');
                g_strlcpy(program, file ? file + 1 : path, program_capacity);
            }
        }
        if (not_text) *not_text = is_desktop_or_panel(display, window);
    } else if (not_text) {
        *not_text = true;
    }
    gdk_x11_display_error_trap_pop_ignored(gdk);
    return (uintptr_t)window;
}

/* ---- The clipboard ---- */

static GtkClipboard *clipboard(void) {
    return gtk_clipboard_get(GDK_SELECTION_CLIPBOARD);
}

bool lucid_copy(const char *text) {
    if (!lucid_display()) return false;
    gtk_clipboard_set_text(clipboard(), text ? text : "", -1);
    /* So the text outlives Lucid, where the desktop keeps clipboards. */
    gtk_clipboard_set_can_store(clipboard(), NULL, 0);
    return true;
}

size_t lucid_clipboard_text(char *out, size_t capacity) {
    if (!out || capacity == 0) return 0;
    out[0] = 0;
    if (!lucid_display()) return 0;
    char *text = gtk_clipboard_wait_for_text(clipboard());
    if (!text) return 0;
    g_strlcpy(out, text, capacity);
    g_free(text);
    return strlen(out);
}

/* ---- Pressing the keys that paste ---- */

/* A keyboard of Lucid's own, with only the keys it presses. */
static void make_keyboard(void) {
    const char *path = g_getenv("LUCID_TEST_UINPUT");
    int fd = open(path ? path : "/dev/uinput", O_WRONLY | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) return;
    if (!path) {
        struct uinput_setup setup;
        memset(&setup, 0, sizeof setup);
        setup.id.bustype = BUS_VIRTUAL;
        g_strlcpy(setup.name, "Lucid dictation", sizeof setup.name);
        if (ioctl(fd, UI_SET_EVBIT, EV_KEY) < 0 || ioctl(fd, UI_SET_KEYBIT, KEY_LEFTSHIFT) < 0
            || ioctl(fd, UI_SET_KEYBIT, KEY_INSERT) < 0 || ioctl(fd, UI_DEV_SETUP, &setup) < 0
            || ioctl(fd, UI_DEV_CREATE) < 0) {
            close(fd);
            return;
        }
    }
    made_keyboard = fd;
}

static bool made_key(int code, int value) {
    struct input_event events[2];
    memset(events, 0, sizeof events);
    events[0].type = EV_KEY;
    events[0].code = (unsigned short)code;
    events[0].value = value;
    events[1].type = EV_SYN;
    events[1].code = SYN_REPORT;
    return write(made_keyboard, events, sizeof events) == (ssize_t)sizeof events;
}

static bool press_made_keys(void) {
    if (made_keyboard < 0) return false;
    bool pressed = made_key(KEY_LEFTSHIFT, 1) && made_key(KEY_INSERT, 1);
    /* A desktop takes a moment to see a key. Let go too soon and it sees none. */
    g_usleep(8000);
    return made_key(KEY_INSERT, 0) && made_key(KEY_LEFTSHIFT, 0) && pressed;
}

static bool press_x11(void) {
    Display *display = lucid_display();
    if (!display || !can_press_x11) return false;
    KeyCode shift = XKeysymToKeycode(display, XK_Shift_L), insert = XKeysymToKeycode(display, XK_Insert);
    if (!shift || !insert) return false;

    /* Ctrl, Alt or the Super key still held down would turn the paste into something
       else. The user's own Shift does no harm. */
    char down[32];
    XQueryKeymap(display, down);
    XModifierKeymap *modifiers = XGetModifierMapping(display);
    if (modifiers) {
        static const int rows[] = {ControlMapIndex, Mod1MapIndex, Mod4MapIndex};
        for (size_t row = 0; row < G_N_ELEMENTS(rows); row++) {
            for (int each = 0; each < modifiers->max_keypermod; each++) {
                KeyCode code = modifiers->modifiermap[rows[row] * modifiers->max_keypermod + each];
                if (code && (down[code / 8] & (1 << (code % 8)))) XTestFakeKeyEvent(display, code, False, CurrentTime);
            }
        }
        XFreeModifiermap(modifiers);
    }
    XTestFakeKeyEvent(display, shift, True, CurrentTime);
    XTestFakeKeyEvent(display, insert, True, CurrentTime);
    XTestFakeKeyEvent(display, insert, False, CurrentTime);
    XTestFakeKeyEvent(display, shift, False, CurrentTime);
    XFlush(display);
    return true;
}

void lucid_typing_start(void) {
    Display *display = lucid_display();
    int event = 0, error = 0, major = 0, minor = 0;
    can_press_x11 = display && XTestQueryExtension(display, &event, &error, &major, &minor);
    if (lucid_is_wayland() || g_getenv("LUCID_TEST_UINPUT")) {
        make_keyboard();
        can_type = made_keyboard >= 0;
    } else {
        can_type = can_press_x11;
    }
}

void lucid_typing_retry(void) {
    if (made_keyboard >= 0 || !(lucid_is_wayland() || g_getenv("LUCID_TEST_UINPUT"))) return;
    make_keyboard();
    can_type = made_keyboard >= 0;
}

void lucid_typing_stop(void) {
    if (lucid_display()) gtk_clipboard_store(clipboard());
    if (made_keyboard >= 0) {
        if (!g_getenv("LUCID_TEST_UINPUT")) ioctl(made_keyboard, UI_DEV_DESTROY);
        close(made_keyboard);
    }
    made_keyboard = -1;
    can_type = 0;
}

bool lucid_can_type(void) {
    return can_type != 0;
}

/* ---- Pasting, and putting the clipboard back ---- */

/* The dictation on its way through the clipboard. */
static char *passing;
/* What the user had there, to put back. */
static char *kept;
static bool keeping;
static guint restore_timer;
/* Counts pastes, so an answer that comes late for an earlier one is known to be late. */
static unsigned turn;
static guint give_up_timer;
/* True from asking what is on the clipboard until the answer comes, or Lucid stops waiting. */
static bool asking;
/* True while Lucid itself is changing the clipboard, which is not someone else taking it. */
static bool changing;

static void hand_over(GtkClipboard *board, GtkSelectionData *data, guint info, gpointer unused) {
    (void)board;
    (void)unused;
    if (info == 1) {
        /* Tells clipboard managers that this is not worth remembering. */
        gtk_selection_data_set(data, gtk_selection_data_get_target(data), 8, (const guchar *)"secret", 6);
    } else {
        gtk_selection_data_set_text(data, passing ? passing : "", -1);
    }
}

static void taken_over(GtkClipboard *board, gpointer unused) {
    (void)board;
    (void)unused;
    if (changing) return;
    /* Someone copied something else. What Lucid kept is no longer the clipboard's past. */
    if (restore_timer) g_source_remove(restore_timer);
    restore_timer = 0;
    g_free(kept);
    kept = NULL;
    keeping = false;
}

static gboolean restore(gpointer unused) {
    (void)unused;
    restore_timer = 0;
    if (!keeping) return G_SOURCE_REMOVE;
    char *back = kept;
    kept = NULL;
    keeping = false;
    changing = true;
    if (back) {
        gtk_clipboard_set_text(clipboard(), back, -1);
        gtk_clipboard_set_can_store(clipboard(), NULL, 0);
    } else {
        gtk_clipboard_clear(clipboard());
    }
    changing = false;
    g_free(back);
    return G_SOURCE_REMOVE;
}

/* Puts the dictation on the clipboard and presses the keys. */
static void paste_now(void) {
    GtkTargetList *list = gtk_target_list_new(NULL, 0);
    gtk_target_list_add_text_targets(list, 0);
    gtk_target_list_add(list, gdk_atom_intern_static_string("x-kde-passwordManagerHint"), 0, 1);
    gint count = 0;
    GtkTargetEntry *targets = gtk_target_table_new_from_list(list, &count);
    changing = true;
    gtk_clipboard_set_with_data(clipboard(), targets, (guint)count, hand_over, taken_over, NULL);
    changing = false;
    gtk_target_table_free(targets, count);
    gtk_target_list_unref(list);
    /* Terminals paste what is selected rather than what was copied. */
    gtk_clipboard_set_text(gtk_clipboard_get(GDK_SELECTION_PRIMARY), passing ? passing : "", -1);

    if (made_keyboard >= 0) press_made_keys();
    else press_x11();
    /* Give the app time to read the clipboard, then put back what was there. */
    if (restore_timer) g_source_remove(restore_timer);
    restore_timer = g_timeout_add(700, restore, NULL);
}

static void had_text(GtkClipboard *board, const gchar *text, gpointer which) {
    (void)board;
    if (GPOINTER_TO_UINT(which) != turn || !asking) return;
    asking = false;
    if (give_up_timer) g_source_remove(give_up_timer);
    give_up_timer = 0;
    kept = g_strdup(text);
    keeping = true;
    paste_now();
}

static gboolean gave_up(gpointer which) {
    give_up_timer = 0;
    if (GPOINTER_TO_UINT(which) != turn || !asking) return G_SOURCE_REMOVE;
    /* Whoever holds the clipboard is not answering. Paste without anything to put back. */
    asking = false;
    paste_now();
    return G_SOURCE_REMOVE;
}

bool lucid_paste(const char *text) {
    if (!lucid_display()) return false;
    bool not_text = false;
    uintptr_t front = lucid_front_window(NULL, 0, NULL, 0, NULL, &not_text);
    /* The user may have allowed it since Lucid started. */
    if (!can_type) lucid_typing_retry();
    if (!can_type || front == 0 || not_text) {
        lucid_copy(text);
        return false;
    }
    g_free(passing);
    passing = g_strdup(text ? text : "");
    turn++;
    if (keeping) {
        /* An earlier paste has not been put back yet, so what the user had is already kept. */
        asking = false;
        paste_now();
        return true;
    }
    /* What is on the clipboard now is asked for, not waited for: waiting would let other
       things happen in the middle of this. The answer comes within moments, and at once
       when the clipboard is Lucid's own, so the timer is set first. */
    asking = true;
    if (give_up_timer) g_source_remove(give_up_timer);
    give_up_timer = g_timeout_add(400, gave_up, GUINT_TO_POINTER(turn));
    gtk_clipboard_request_text(clipboard(), had_text, GUINT_TO_POINTER(turn));
    return true;
}

#endif
