#include "internal.h"

#ifdef __linux__

#include <X11/Xatom.h>
#include <string.h>
#include <unistd.h>

/* The rest of what Lucid asks of the desktop: opening things, its own window, the file
   chooser, and starting when the user signs in. */

static bool run(char **arguments) {
    return g_spawn_async(
        NULL, arguments, NULL, G_SPAWN_SEARCH_PATH | G_SPAWN_STDOUT_TO_DEV_NULL | G_SPAWN_STDERR_TO_DEV_NULL,
        NULL, NULL, NULL, NULL);
}

bool lucid_open(const char *target) {
    char *arguments[] = {(char *)"xdg-open", (char *)(target ? target : ""), NULL};
    return run(arguments);
}

/* ---- Lucid's window: a page shown by the browser, without the browser's toolbar ---- */

/* A browser that can show a page in a window of its own, which those built on Chromium
   can. Setting LUCID_BROWSER to the path of one uses that. */
static char *find_browser(void) {
    const char *chosen = g_getenv("LUCID_BROWSER");
    if (chosen && chosen[0]) {
        char *path = g_find_program_in_path(chosen);
        if (path) return path;
    }
    static const char *programs[] = {
        "chromium", "chromium-browser", "google-chrome", "google-chrome-stable", "microsoft-edge",
        "microsoft-edge-stable", "brave-browser", "brave", "vivaldi", "vivaldi-stable",
    };
    for (size_t index = 0; index < G_N_ELEMENTS(programs); index++) {
        char *path = g_find_program_in_path(programs[index]);
        if (path) return path;
    }
    return NULL;
}

bool lucid_open_window(const char *address, const char *profile) {
    char *browser = find_browser();
    /* A browser packaged as a "snap" may only keep its files in its own folder, and
       refuses a profile anywhere else. It, and every browser not built on Chromium, shows
       the page as a tab instead. */
    if (!browser || g_str_has_prefix(browser, "/snap/")) {
        g_free(browser);
        return lucid_open(address);
    }
    /* A profile of its own keeps the page away from the extensions of the user's
       browser, which could otherwise read what they dictated. */
    char *app = g_strdup_printf("--app=%s", address);
    char *data = g_strdup_printf("--user-data-dir=%s", profile);
    char *arguments[] = {
        browser, app, data, (char *)"--no-first-run", (char *)"--no-default-browser-check",
        (char *)"--hide-crash-restore-bubble", (char *)"--window-size=1040,760", (char *)"--class=Lucid", NULL,
    };
    bool started = run(arguments);
    g_free(app);
    g_free(data);
    g_free(browser);
    return started || lucid_open(address);
}

/* The window with this title, among those the desktop manages. X11 only. */
static Window find_window(Display *display, const char *title) {
    Window root = DefaultRootWindow(display), found = None;
    Atom type = None;
    int format = 0;
    unsigned long count = 0, left = 0;
    unsigned char *data = NULL;
    if (XGetWindowProperty(
            display, root, XInternAtom(display, "_NET_CLIENT_LIST", False), 0, 4096, False, XA_WINDOW,
            &type, &format, &count, &left, &data)
            != Success
        || !data) {
        return None;
    }
    const Window *windows = (const Window *)(void *)data;
    Atom name_atom = XInternAtom(display, "_NET_WM_NAME", False), text = XInternAtom(display, "UTF8_STRING", False);
    for (unsigned long index = 0; index < count && found == None; index++) {
        unsigned char *name = NULL;
        unsigned long length = 0;
        if (XGetWindowProperty(display, windows[index], name_atom, 0, 256, False, text, &type, &format, &length, &left, &name)
                == Success
            && name) {
            if (strcmp((const char *)name, title) == 0) found = windows[index];
            XFree(name);
        }
    }
    XFree(data);
    return found;
}

/* Asks the desktop to do something to a window, the way a taskbar would. */
static void ask_desktop(Display *display, Window window, const char *what, long first) {
    XEvent event;
    memset(&event, 0, sizeof event);
    event.xclient.type = ClientMessage;
    event.xclient.window = window;
    event.xclient.message_type = XInternAtom(display, what, False);
    event.xclient.format = 32;
    event.xclient.data.l[0] = first;
    event.xclient.data.l[1] = CurrentTime;
    XSendEvent(display, DefaultRootWindow(display), False, SubstructureRedirectMask | SubstructureNotifyMask, &event);
    XFlush(display);
}

static bool with_window(const char *title, const char *what, long first) {
    Display *display = lucid_display();
    /* Wayland does not let one app find or move another's window. */
    if (!display || lucid_is_wayland()) return false;
    GdkDisplay *gdk = gdk_display_get_default();
    gdk_x11_display_error_trap_push(gdk);
    Window window = find_window(display, title ? title : "");
    if (window != None) ask_desktop(display, window, what, first);
    gdk_x11_display_error_trap_pop_ignored(gdk);
    return window != None;
}

bool lucid_focus_window(const char *title) {
    /* 2 says the request comes from something like a taskbar, which desktops obey. */
    return with_window(title, "_NET_ACTIVE_WINDOW", 2);
}

void lucid_close_window(const char *title) {
    with_window(title, "_NET_CLOSE_WINDOW", CurrentTime);
}

/* ---- The file chooser ---- */

size_t lucid_choose_file(const char *title, const char *kinds, const char *patterns, char *out, size_t capacity) {
    if (out && capacity) out[0] = 0;
    if (!lucid_display()) return 0;
    GtkFileChooserNative *chooser = gtk_file_chooser_native_new(
        title ? title : "Choose a file", NULL, GTK_FILE_CHOOSER_ACTION_OPEN, NULL, NULL);
    GtkFileFilter *wanted = gtk_file_filter_new();
    char *label = g_strdup_printf("%s (%s)", kinds ? kinds : "Files", patterns ? patterns : "*");
    gtk_file_filter_set_name(wanted, label);
    g_free(label);
    char **each = g_strsplit(patterns ? patterns : "*", ";", -1);
    for (char **pattern = each; *pattern; pattern++) gtk_file_filter_add_pattern(wanted, *pattern);
    g_strfreev(each);
    gtk_file_chooser_add_filter(GTK_FILE_CHOOSER(chooser), wanted);
    GtkFileFilter *all = gtk_file_filter_new();
    gtk_file_filter_set_name(all, "All files");
    gtk_file_filter_add_pattern(all, "*");
    gtk_file_chooser_add_filter(GTK_FILE_CHOOSER(chooser), all);

    size_t length = 0;
    if (gtk_native_dialog_run(GTK_NATIVE_DIALOG(chooser)) == GTK_RESPONSE_ACCEPT) {
        char *path = gtk_file_chooser_get_filename(GTK_FILE_CHOOSER(chooser));
        if (path && out) {
            g_strlcpy(out, path, capacity);
            length = strlen(out);
        }
        g_free(path);
    }
    g_object_unref(chooser);
    return length;
}

/* ---- Starting when the user signs in ---- */

/* Desktops start what has a file in this folder. */
static char *autostart_path(void) {
    return g_build_filename(g_get_user_config_dir(), "autostart", "lucid.desktop", NULL);
}

static char *own_path(void) {
    return g_file_read_link("/proc/self/exe", NULL);
}

/* A program's path as a desktop file wants it after "Exec=". Its rules are its own: double
   quotes around anything unusual, a backslash before the characters that mean something
   inside them, and every backslash written twice. */
static char *exec_line(const char *path) {
    bool plain = true;
    for (const char *each = path; *each; each++) {
        if (!g_ascii_isalnum(*each) && !strchr("/._-+@", *each)) plain = false;
    }
    if (plain) return g_strdup(path);
    GString *line = g_string_new("\"");
    for (const char *each = path; *each; each++) {
        if (*each == '\\') g_string_append(line, "\\\\\\\\");
        else if (strchr("\"`$", *each)) g_string_append_printf(line, "\\\\%c", *each);
        else g_string_append_c(line, *each);
    }
    g_string_append_c(line, '"');
    return g_string_free(line, FALSE);
}

bool lucid_opens_at_login(void) {
    char *path = autostart_path(), *mine = own_path();
    GKeyFile *file = g_key_file_new();
    bool listed = false;
    if (mine && g_key_file_load_from_file(file, path, G_KEY_FILE_NONE, NULL)) {
        char *command = g_key_file_get_string(file, "Desktop Entry", "Exec", NULL);
        gboolean hidden = g_key_file_get_boolean(file, "Desktop Entry", "Hidden", NULL);
        /* A copy of Lucid somewhere else being listed does not make this one start. */
        char *line = exec_line(mine);
        char *read_back = g_strcompress(line);
        listed = command && !hidden && (strcmp(command, mine) == 0 || strcmp(command, read_back) == 0);
        g_free(read_back);
        g_free(line);
        g_free(command);
    }
    g_key_file_free(file);
    g_free(path);
    g_free(mine);
    return listed;
}

bool lucid_set_opens_at_login(bool on) {
    char *path = autostart_path();
    bool done = false;
    if (!on) {
        done = unlink(path) == 0 || !g_file_test(path, G_FILE_TEST_EXISTS);
    } else {
        char *mine = own_path();
        if (mine) {
            char *folder = g_path_get_dirname(path);
            g_mkdir_with_parents(folder, 0755);
            g_free(folder);
            char *quoted = exec_line(mine);
            char *text = g_strdup_printf(
                "[Desktop Entry]\nType=Application\nName=Lucid\nComment=Dictation that runs on this computer\n"
                "Exec=%s\nIcon=lucid\nTerminal=false\nX-GNOME-Autostart-enabled=true\n",
                quoted);
            done = g_file_set_contents(path, text, -1, NULL);
            g_free(text);
            g_free(quoted);
            g_free(mine);
        }
    }
    g_free(path);
    return done;
}

/* ---- The menu of applications ---- */

/* The program that an entry in the menu starts, without the quotes its file wraps it in. */
static char *entry_program(const char *path) {
    GKeyFile *file = g_key_file_new();
    char *program = NULL;
    if (g_key_file_load_from_file(file, path, G_KEY_FILE_NONE, NULL)) {
        char *command = g_key_file_get_string(file, "Desktop Entry", "Exec", NULL);
        gint count = 0;
        char **words = NULL;
        if (command && g_shell_parse_argv(command, &count, &words, NULL) && count > 0) program = g_strdup(words[0]);
        g_strfreev(words);
        g_free(command);
    }
    g_key_file_free(file);
    return program;
}

bool lucid_install_launcher(bool replace) {
    /* A package that was installed for everyone brought its own entry. One for this user
       as well would outlive the package if it were removed. */
    for (const char *const *shared = g_get_system_data_dirs(); *shared; shared++) {
        char *entry = g_build_filename(*shared, "applications", "lucid.desktop", NULL);
        bool there = g_file_test(entry, G_FILE_TEST_EXISTS);
        g_free(entry);
        if (there) return true;
    }
    char *mine = own_path();
    if (!mine) return false;
    if (!replace) {
        /* An entry for a copy of Lucid that is still there is that copy's. */
        char *existing = g_build_filename(g_get_user_data_dir(), "applications", "lucid.desktop", NULL);
        char *program = entry_program(existing);
        bool keep = program && strcmp(program, mine) != 0 && g_file_test(program, G_FILE_TEST_IS_EXECUTABLE);
        g_free(program);
        g_free(existing);
        if (keep) {
            g_free(mine);
            return true;
        }
    }
    /* The icon, in the sizes desktops ask for. */
    static const int sizes[] = {48, 128, 256};
    for (size_t index = 0; index < G_N_ELEMENTS(sizes); index++) {
        char *size = g_strdup_printf("%dx%d", sizes[index], sizes[index]);
        char *folder = g_build_filename(g_get_user_data_dir(), "icons", "hicolor", size, "apps", NULL);
        g_mkdir_with_parents(folder, 0755);
        char *path = g_build_filename(folder, "lucid.png", NULL);
        lucid_icon_save(LUCID_TRAY_IDLE, path, sizes[index]);
        g_free(path);
        g_free(folder);
        g_free(size);
    }

    char *folder = g_build_filename(g_get_user_data_dir(), "applications", NULL);
    g_mkdir_with_parents(folder, 0755);
    char *path = g_build_filename(folder, "lucid.desktop", NULL);
    char *quoted = exec_line(mine);
    char *text = g_strdup_printf(
        "[Desktop Entry]\nType=Application\nName=Lucid\nGenericName=Dictation\n"
        "Comment=Hold a key, speak, and clean text appears where your cursor is\n"
        "Exec=%s\nIcon=lucid\nTerminal=false\nCategories=Utility;Accessibility;\n"
        "Keywords=dictation;speech;voice;transcribe;\nStartupNotify=false\n",
        quoted);
    bool done = g_file_set_contents(path, text, -1, NULL);
    g_free(text);
    g_free(quoted);
    g_free(path);
    g_free(folder);
    g_free(mine);
    return done;
}

/* ---- A Wayland session ---- */

/* What lets the person signed in at this computer read the keyboards and make one. The
   same lines are in scripts/setup-linux.sh. */
static const char allow_script[] =
    "set -e\n"
    "cat > /etc/udev/rules.d/70-lucid.rules <<'RULES'\n"
    "# Lets the person signed in at this computer use Lucid in a Wayland session: read the\n"
    "# keyboards, to see the dictation key, and make a keyboard of its own, to paste.\n"
    "KERNEL==\"uinput\", SUBSYSTEM==\"misc\", TAG+=\"uaccess\", OPTIONS+=\"static_node=uinput\"\n"
    "SUBSYSTEM==\"input\", KERNEL==\"event*\", ENV{ID_INPUT_KEYBOARD}==\"1\", TAG+=\"uaccess\"\n"
    "RULES\n"
    "udevadm control --reload\n"
    "udevadm trigger --subsystem-match=input --subsystem-match=misc\n";

static void allowed(GPid asker, gint status, gpointer unused) {
    (void)status;
    (void)unused;
    g_spawn_close_pid(asker);
    /* The keyboards are looked for again every few seconds anyway. The keyboard to paste
       with is only made when asked. */
    lucid_typing_retry();
}

bool lucid_allow_keys(void) {
    /* pkexec shows the desktop's own prompt for the password of someone who may change
       the system, and runs one command for them if they give it. */
    const char *stand_in = g_getenv("LUCID_TEST_PKEXEC");
    char *asker = g_find_program_in_path(stand_in ? stand_in : "pkexec");
    if (!asker) return false;
    char *arguments[] = {asker, (char *)"/bin/sh", (char *)"-c", (char *)allow_script, NULL};
    GPid started = 0;
    bool asked = g_spawn_async(
        NULL, arguments, NULL, G_SPAWN_DO_NOT_REAP_CHILD | G_SPAWN_STDOUT_TO_DEV_NULL | G_SPAWN_STDERR_TO_DEV_NULL,
        NULL, NULL, &started, NULL);
    if (asked) g_child_watch_add(started, allowed, NULL);
    g_free(asker);
    return asked;
}

void lucid_alert(const char *title, const char *text) {
    if (!lucid_display()) {
        /* No screen to show it on. Whoever started Lucid may be reading. */
        g_printerr("%s: %s\n", title ? title : "Lucid", text ? text : "");
        return;
    }
    GtkWidget *dialog = gtk_message_dialog_new(NULL, 0, GTK_MESSAGE_INFO, GTK_BUTTONS_OK, "%s", text ? text : "");
    gtk_window_set_title(GTK_WINDOW(dialog), title ? title : "Lucid");
    gtk_window_set_keep_above(GTK_WINDOW(dialog), TRUE);
    gtk_dialog_run(GTK_DIALOG(dialog));
    gtk_widget_destroy(dialog);
}

#endif
