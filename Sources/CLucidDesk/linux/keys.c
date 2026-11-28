#include "internal.h"

#ifdef __linux__

#include <X11/extensions/XInput2.h>
#include <X11/extensions/XTest.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <poll.h>
#include <pthread.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

/* Seeing the dictation key while another app has the keyboard.

   With X11, the display server tells any app that asks about every key that goes down or
   up. With Wayland it tells none, so the only way is to read the keyboards themselves,
   in /dev/input, which the user has to allow.

   Either way the watching has a thread of its own, and passes on only what the dictation
   machine needs. Neither way can keep a key from the app in front. */

static pthread_t thread;
static bool thread_running;
static int wake_pipe[2] = {-1, -1};
static volatile int stopping;
static volatile int hotkey = KEY_RIGHTCTRL;
static volatile int accept_made_up;
static volatile int watched;
/* The dictation key that is down now, or 0. Only the watching thread uses it. */
static int held;

/* The display server's own way. */
static Display *watch_display;
static int input_opcode;
static int made_up_device = -1;

/* The keyboards themselves. */
#define MOST_KEYBOARDS 32
static int keyboards[MOST_KEYBOARDS];
static char keyboard_names[MOST_KEYBOARDS][32];
static int keyboard_count;
static const char *test_keyboard;

static gboolean deliver(gpointer signal) {
    if (lucid_callbacks.key) lucid_callbacks.key(GPOINTER_TO_INT(signal));
    return G_SOURCE_REMOVE;
}

static void tell(int signal) {
    g_idle_add_full(G_PRIORITY_HIGH, deliver, GINT_TO_POINTER(signal), NULL);
}

/* One key going down or up, whichever way Lucid came to know. */
static void key_changed(int code, bool down) {
    int key = hotkey;
    /* The user chose another key while the old one was down. */
    if (held != 0 && held != key) held = 0;
    if (code == key) {
        /* A key held down repeats. Only the first press counts. */
        if (down && held == 0) {
            held = key;
            tell(LUCID_KEY_DOWN);
        } else if (!down && held != 0) {
            held = 0;
            tell(LUCID_KEY_UP);
        }
    } else if (down && code == LUCID_KEY_CODE_ESCAPE) {
        if (lucid_callbacks.wants_escape && lucid_callbacks.wants_escape()) tell(LUCID_KEY_ESCAPE);
    } else if (down) {
        tell(LUCID_KEY_OTHER);
    }
}

/* ---- Through the display server ---- */

static bool x11_begin(void) {
    watch_display = XOpenDisplay(NULL);
    if (!watch_display) return false;
    int event = 0, error = 0, major = 2, minor = 0;
    if (!XQueryExtension(watch_display, "XInputExtension", &input_opcode, &event, &error)
        || XIQueryVersion(watch_display, &major, &minor) != Success) {
        XCloseDisplay(watch_display);
        watch_display = NULL;
        return false;
    }
    unsigned char bits[XIMaskLen(XI_LASTEVENT)];
    memset(bits, 0, sizeof bits);
    XISetMask(bits, XI_RawKeyPress);
    XISetMask(bits, XI_RawKeyRelease);
    XIEventMask mask;
    mask.deviceid = XIAllMasterDevices;
    mask.mask_len = sizeof bits;
    mask.mask = bits;
    XISelectEvents(watch_display, DefaultRootWindow(watch_display), &mask, 1);

    /* Keys that programs press come from a keyboard of the server's own. They are not the
       user's, and Lucid's own pasting is among them. */
    int count = 0;
    XIDeviceInfo *devices = XIQueryDevice(watch_display, XIAllDevices, &count);
    for (int index = 0; devices && index < count; index++) {
        if (devices[index].use == XISlaveKeyboard && strstr(devices[index].name, "XTEST")) {
            made_up_device = devices[index].deviceid;
        }
    }
    if (devices) XIFreeDeviceInfo(devices);
    XSync(watch_display, False);
    return true;
}

static void *x11_watch(void *unused) {
    (void)unused;
    struct pollfd waiting[2];
    waiting[0].fd = ConnectionNumber(watch_display);
    waiting[0].events = POLLIN;
    waiting[1].fd = wake_pipe[0];
    waiting[1].events = POLLIN;
    while (!stopping) {
        while (XPending(watch_display)) {
            XEvent event;
            XNextEvent(watch_display, &event);
            XGenericEventCookie *cookie = &event.xcookie;
            if (cookie->type != GenericEvent || cookie->extension != input_opcode) continue;
            if (!XGetEventData(watch_display, cookie)) continue;
            if (cookie->evtype == XI_RawKeyPress || cookie->evtype == XI_RawKeyRelease) {
                const XIRawEvent *raw = (const XIRawEvent *)cookie->data;
                bool made_up = raw->sourceid == made_up_device;
                if (!made_up || accept_made_up) {
                    key_changed(raw->detail - LUCID_X11_OFFSET, cookie->evtype == XI_RawKeyPress);
                }
            }
            XFreeEventData(watch_display, cookie);
        }
        waiting[0].revents = waiting[1].revents = 0;
        if (poll(waiting, 2, -1) < 0 && errno != EINTR) break;
        if (waiting[0].revents & (POLLERR | POLLHUP)) break;
    }
    return NULL;
}

/* ---- By reading the keyboards ---- */

static bool has_key(const unsigned long *bits, int key) {
    size_t width = 8 * sizeof(unsigned long);
    return (bits[(size_t)key / width] >> ((size_t)key % width)) & 1;
}

/* True for something with the keys of a keyboard. Mice and power buttons are in the same
   folder, and so is the keyboard Lucid itself makes to paste with, which has four keys. */
static bool is_keyboard(int fd) {
    unsigned long bits[KEY_MAX / (8 * sizeof(unsigned long)) + 1];
    memset(bits, 0, sizeof bits);
    if (ioctl(fd, EVIOCGBIT(EV_KEY, sizeof bits), bits) < 0) return false;
    return has_key(bits, KEY_A) && has_key(bits, KEY_ENTER) && has_key(bits, KEY_ESC);
}

static void forget_keyboard(int index) {
    close(keyboards[index]);
    keyboard_count--;
    keyboards[index] = keyboards[keyboard_count];
    memcpy(keyboard_names[index], keyboard_names[keyboard_count], sizeof keyboard_names[index]);
}

/* Opens the keyboards that are not open yet. One may be plugged in at any time. */
static void find_keyboards(void) {
    if (test_keyboard) {
        if (keyboard_count == 0) {
            int fd = open(test_keyboard, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
            if (fd >= 0) {
                keyboards[0] = fd;
                g_strlcpy(keyboard_names[0], "test", sizeof keyboard_names[0]);
                keyboard_count = 1;
            }
        }
    } else {
        DIR *folder = opendir("/dev/input");
        if (folder) {
            struct dirent *entry;
            while ((entry = readdir(folder)) != NULL && keyboard_count < MOST_KEYBOARDS) {
                if (strncmp(entry->d_name, "event", 5) != 0 || strlen(entry->d_name) >= sizeof keyboard_names[0]) continue;
                bool open_already = false;
                for (int index = 0; index < keyboard_count; index++) {
                    if (strcmp(keyboard_names[index], entry->d_name) == 0) open_already = true;
                }
                if (open_already) continue;
                char path[64];
                g_snprintf(path, sizeof path, "/dev/input/%s", entry->d_name);
                int fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
                if (fd < 0) continue;
                if (!is_keyboard(fd)) {
                    close(fd);
                    continue;
                }
                keyboards[keyboard_count] = fd;
                g_strlcpy(keyboard_names[keyboard_count], entry->d_name, sizeof keyboard_names[0]);
                keyboard_count++;
            }
            closedir(folder);
        }
    }
    watched = keyboard_count > 0;
}

static void *keyboards_watch(void *unused) {
    (void)unused;
    while (!stopping) {
        struct pollfd waiting[MOST_KEYBOARDS + 1];
        for (int index = 0; index < keyboard_count; index++) {
            waiting[index].fd = keyboards[index];
            waiting[index].events = POLLIN;
            waiting[index].revents = 0;
        }
        waiting[keyboard_count].fd = wake_pipe[0];
        waiting[keyboard_count].events = POLLIN;
        waiting[keyboard_count].revents = 0;
        int count = keyboard_count;
        /* Every few seconds, look for a keyboard that was plugged in. */
        int ready = poll(waiting, (nfds_t)count + 1, 3000);
        if (ready < 0 && errno != EINTR) break;
        if (stopping) break;

        for (int index = count - 1; index >= 0; index--) {
            if (!waiting[index].revents) continue;
            struct input_event events[32];
            ssize_t got = read(keyboards[index], events, sizeof events);
            if (got < 0 && (errno == EAGAIN || errno == EINTR)) continue;
            if (got <= 0) {
                /* Unplugged. For the test's stand-in, the end of what it had to say. */
                if (!test_keyboard || got < 0) forget_keyboard(index);
                else g_usleep(20000);
                continue;
            }
            for (size_t each = 0; each < (size_t)got / sizeof events[0]; each++) {
                /* 1 is down, 0 is up, and 2 is the key repeating. */
                if (events[each].type != EV_KEY || events[each].value > 1) continue;
                key_changed(events[each].code, events[each].value == 1);
            }
        }
        find_keyboards();
    }
    return NULL;
}

bool lucid_keys_start(void) {
    if (thread_running) return watched;
    stopping = 0;
    held = 0;
    watched = 0;
    if (pipe2(wake_pipe, O_CLOEXEC | O_NONBLOCK) != 0) return false;

    test_keyboard = g_getenv("LUCID_TEST_KEYBOARD");
    /* For tests that drive the whole app with keys a program presses. */
    if (g_getenv("LUCID_TEST_MADE_UP_KEYS")) accept_made_up = 1;
    void *(*watch)(void *) = NULL;
    /* In a Wayland session the display server reports keys only while one of the few apps
       that still use X11 is in front, which is worse than not at all. */
    if (!test_keyboard && !lucid_is_wayland() && x11_begin()) {
        watch = x11_watch;
        watched = 1;
    } else {
        find_keyboards();
        watch = keyboards_watch;
    }
    if (pthread_create(&thread, NULL, watch, NULL) != 0) {
        watched = 0;
        return false;
    }
    thread_running = true;
    return watched;
}

void lucid_keys_stop(void) {
    if (!thread_running) return;
    stopping = 1;
    if (write(wake_pipe[1], "x", 1) < 0) { /* The thread is on its way out anyway. */ }
    pthread_join(thread, NULL);
    thread_running = false;
    close(wake_pipe[0]);
    close(wake_pipe[1]);
    wake_pipe[0] = wake_pipe[1] = -1;
    if (watch_display) XCloseDisplay(watch_display);
    watch_display = NULL;
    while (keyboard_count > 0) forget_keyboard(keyboard_count - 1);
    watched = 0;
}

void lucid_set_hotkey(int virtual_key) {
    hotkey = virtual_key;
}

bool lucid_keyboard_watched(void) {
    return watched != 0;
}

void lucid_test_accept_made_up_keys(bool accept) {
    accept_made_up = accept ? 1 : 0;
}

bool lucid_test_press(int virtual_key, bool down) {
    Display *display = lucid_display();
    int event = 0, error = 0, major = 0, minor = 0;
    if (!display || !XTestQueryExtension(display, &event, &error, &major, &minor)) return false;
    XTestFakeKeyEvent(display, (unsigned int)(virtual_key + LUCID_X11_OFFSET), down ? True : False, CurrentTime);
    XFlush(display);
    return true;
}

#endif
