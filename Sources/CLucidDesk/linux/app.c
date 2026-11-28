#include "internal.h"

#ifdef __linux__

#include <errno.h>
#include <glib-unix.h>
#include <locale.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

LucidCallbacks lucid_callbacks;

static bool started;
static bool quit_asked;
/* Where a second copy of Lucid finds the first, to ask it to show its window. */
static int instance_socket = -1;
static char instance_path[108];
static guint instance_watch;

bool lucid_is_wayland(void) {
    const char *kind = g_getenv("XDG_SESSION_TYPE");
    if (kind && g_ascii_strcasecmp(kind, "wayland") == 0) return true;
    const char *wayland = g_getenv("WAYLAND_DISPLAY");
    return wayland && wayland[0];
}

bool lucid_hide_consoles(void) {
    return true;
}

Display *lucid_display(void) {
    GdkDisplay *display = started ? gdk_display_get_default() : NULL;
    return display && GDK_IS_X11_DISPLAY(display) ? gdk_x11_display_get_xdisplay(display) : NULL;
}

const char *lucid_cache_folder(void) {
    static char *folder;
    if (!folder) {
        folder = g_build_filename(g_get_user_cache_dir(), "lucid", NULL);
        g_mkdir_with_parents(folder, 0700);
    }
    return folder;
}

bool lucid_claim_single_instance(void) {
    if (instance_socket >= 0) return true;
    const char *folder = g_get_user_runtime_dir();
    if (g_snprintf(instance_path, sizeof instance_path, "%s/lucid.sock", folder) >= (int)sizeof instance_path) return true;

    struct sockaddr_un address;
    memset(&address, 0, sizeof address);
    address.sun_family = AF_UNIX;
    memcpy(address.sun_path, instance_path, strlen(instance_path) + 1);
    int fd = socket(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
    if (fd < 0) return true;

    if (bind(fd, (struct sockaddr *)&address, sizeof address) != 0) {
        /* Someone has the address. If they take a message, Lucid is running, and starting
           it again is how people look for its window. */
        if (sendto(fd, "open", 4, 0, (struct sockaddr *)&address, sizeof address) >= 0) {
            close(fd);
            return false;
        }
        /* Nobody is listening: it was left behind by a copy that did not get to tidy up. */
        unlink(instance_path);
        if (bind(fd, (struct sockaddr *)&address, sizeof address) != 0) {
            close(fd);
            return true;
        }
    }
    instance_socket = fd;
    return true;
}

static gboolean second_copy_started(gint fd, GIOCondition condition, gpointer unused) {
    (void)condition;
    (void)unused;
    char message[16];
    while (recv(fd, message, sizeof message, 0) > 0) {}
    if (lucid_callbacks.activated) lucid_callbacks.activated();
    return G_SOURCE_CONTINUE;
}

bool lucid_start(const LucidCallbacks *callbacks) {
    if (started) return true;
    if (callbacks) lucid_callbacks = *callbacks;
    /* Lucid puts its pill where it wants it and presses keys in other apps. Only X11 lets
       an app do either, so in a Wayland session Lucid goes through its X11 bridge. */
    gdk_set_allowed_backends("x11");
    if (!gtk_init_check(NULL, NULL)) return false;
    /* GTK turns on the user's language. Numbers must stay as programs write them. */
    setlocale(LC_NUMERIC, "C");
    started = true;
    quit_asked = false;

    /* Asked now, so that the answer is there by the time anyone needs it. */
    lucid_mic_devices();
    lucid_typing_start();
    lucid_pill_make();
    lucid_tray_make();
    lucid_keys_start();
    if (instance_socket >= 0) {
        instance_watch = g_unix_fd_add(instance_socket, G_IO_IN, second_copy_started, NULL);
    }
    return true;
}

int lucid_run(void) {
    if (!started) return 1;
    if (!quit_asked) gtk_main();
    return 0;
}

void lucid_pump(int milliseconds) {
    if (!started) return;
    gint64 end = g_get_monotonic_time() + (gint64)(milliseconds < 0 ? 0 : milliseconds) * 1000;
    for (;;) {
        while (g_main_context_iteration(NULL, FALSE)) {}
        gint64 left = end - g_get_monotonic_time();
        if (left <= 0) return;
        g_usleep((gulong)(left < 3000 ? left : 3000));
    }
}

static gboolean quit_now(gpointer unused) {
    (void)unused;
    quit_asked = true;
    if (gtk_main_level() > 0) gtk_main_quit();
    return G_SOURCE_REMOVE;
}

void lucid_quit(void) {
    g_idle_add_full(G_PRIORITY_HIGH, quit_now, NULL, NULL);
}

void lucid_stop(void) {
    if (started) {
        lucid_keys_stop();
        lucid_mic_stop();
        lucid_tray_destroy();
        lucid_pill_destroy();
        lucid_typing_stop();
        started = false;
    }
    if (instance_watch) g_source_remove(instance_watch);
    instance_watch = 0;
    if (instance_socket >= 0) {
        close(instance_socket);
        unlink(instance_path);
        instance_socket = -1;
    }
}

static gboolean woken(gpointer unused) {
    (void)unused;
    if (lucid_callbacks.wake) lucid_callbacks.wake();
    return G_SOURCE_REMOVE;
}

void lucid_wake(void) {
    /* Always later, never at once, even when called on the main thread: whoever posted
       work expects to finish what they are doing first. */
    g_idle_add_full(G_PRIORITY_DEFAULT, woken, NULL, NULL);
}

#endif
