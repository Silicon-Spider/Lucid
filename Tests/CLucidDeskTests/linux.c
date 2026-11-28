/* Drives Lucid's Linux layer without the rest of the app: the pill, the tray icon and its
   menu, the dictation key, the clipboard, the microphone, and typing into another
   program's window.

   scripts/test-linux-layer.sh builds this and runs it on a display that only exists in
   memory. It presses keys, opens windows to type into, and uses the clipboard, so on a
   real desktop leave the computer alone while it runs. */

#define _GNU_SOURCE
#include <gtk/gtk.h>
#include <linux/input.h>

#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#include "luciddesk.h"

/* Key codes, as in <linux/input-event-codes.h>. */
#define K_ESCAPE 1
#define K_A 30
#define K_RIGHT_CTRL 97
#define K_RIGHT_ALT 100

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
static int chosen_command;
static int activations;
static bool test_menu;

static void on_key(int signal) {
    if (key_count < 64) keys[key_count++] = signal;
}
static bool on_wants_escape(void) { return escape_is_ours; }
static void on_wake(void) { wakes++; }
static void on_menu_opening(void) {
    if (!test_menu) return;
    lucid_menu_clear();
    lucid_menu_add(41, "First", 0);
    lucid_menu_add(0, "Cleanup", LUCID_MENU_OPENS);
    lucid_menu_add(42, "Second", LUCID_MENU_CHECKED);
    lucid_menu_add(0, NULL, LUCID_MENU_CLOSES);
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
static char self[1024];

static const char *in_folder(const char *name) {
    static char path[4][700];
    static int turn;
    turn = (turn + 1) % 4;
    snprintf(path[turn], sizeof path[turn], "%s/%s", folder, name);
    return path[turn];
}

static char *contents(const char *path) {
    char *text = NULL;
    if (!g_file_get_contents(path, &text, NULL, NULL)) return g_strdup("");
    return text;
}

/* ---- The pill and the tray icon ---- */

static void test_pill(void) {
    printf("Pill\n");
    check(!lucid_pill_visible(), "is hidden to begin with");

    lucid_test_level(0.08f);
    lucid_pill_show(LUCID_PILL_RECORDING, NULL);
    lucid_pump(300);
    check(lucid_pill_visible(), "shows while recording");
    check(lucid_test_pill_picture(in_folder("pill-recording.png"), 0x7a8aa0), "draws the level bars");

    lucid_pill_preview("so let's meet at three");
    lucid_pump(100);
    check(lucid_test_pill_picture(in_folder("pill-words.png"), 0x7a8aa0), "draws the words heard so far");
    /* What is really on the screen, to look at. */
    if (system("command -v import >/dev/null 2>&1 && import -window root \"$LUCID_HARNESS_SCREEN\" 2>/dev/null") != 0) {
        /* Nothing to take the picture with. It is only for looking at. */
    }

    lucid_pill_preview("this is a much longer run of words than the pill has room for, so the start of it must go and only the end stay");
    lucid_pump(100);
    check(lucid_test_pill_picture(in_folder("pill-long-words.png"), 0x7a8aa0), "cuts the start of words that are too long");

    lucid_pill_show(LUCID_PILL_HANDS_FREE, NULL);
    lucid_pump(100);
    check(lucid_test_pill_picture(in_folder("pill-hands-free-words.png"), 0x7a8aa0), "keeps the words when going hands-free");

    lucid_pill_show(LUCID_PILL_RECORDING, NULL);
    lucid_pill_show(LUCID_PILL_HANDS_FREE, NULL);
    lucid_pump(100);
    check(lucid_test_pill_picture(in_folder("pill-hands-free.png"), 0x7a8aa0), "explains hands-free when there are no words yet");

    lucid_pill_pulse();
    check(lucid_test_pill_picture(in_folder("pill-pulse.png"), 0x7a8aa0), "bumps to acknowledge a key press");
    lucid_pump(250);

    lucid_test_level(-1);
    lucid_pill_show(LUCID_PILL_PROCESSING, NULL);
    lucid_pump(300);
    check(lucid_test_pill_picture(in_folder("pill-processing.png"), 0xf2f2f2), "draws the dots while working");

    lucid_pill_flash("Copied. Press Ctrl+V", 400);
    lucid_pump(100);
    check(lucid_pill_visible(), "shows a message");
    check(lucid_test_pill_picture(in_folder("pill-message.png"), 0x7a8aa0), "draws the message");
    lucid_pump(600);
    check(!lucid_pill_visible(), "hides by itself after a message");

    lucid_pill_show(LUCID_PILL_RECORDING, NULL);
    lucid_pill_show(LUCID_PILL_HIDDEN, NULL);
    check(!lucid_pill_visible(), "hides when told to");
}

/* Asks Lucid's menu something the way a panel does: over the session's message bus. The
   panel is another program. Here the asker and the asked are the same one, so the question
   is sent and the answer waited for while Lucid goes about its business. */
static GVariant *menu_answer;
static bool menu_answered;

static void menu_replied(GObject *bus, GAsyncResult *result, gpointer unused) {
    (void)unused;
    GError *error = NULL;
    menu_answer = g_dbus_connection_call_finish(G_DBUS_CONNECTION(bus), result, &error);
    if (error) {
        printf("        the bus said: %s\n", error->message);
        g_error_free(error);
    }
    menu_answered = true;
}

static GVariant *ask_menu(const char *method, GVariant *arguments) {
    GDBusConnection *bus = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, NULL);
    if (!bus) return NULL;
    menu_answer = NULL;
    menu_answered = false;
    g_dbus_connection_call(
        bus, g_dbus_connection_get_unique_name(bus), "/org/ayatana/NotificationItem/lucid/Menu",
        "com.canonical.dbusmenu", method, arguments, NULL, G_DBUS_CALL_FLAGS_NONE, 3000, NULL, menu_replied, NULL);
    for (int attempt = 0; attempt < 80 && !menu_answered; attempt++) lucid_pump(50);
    g_object_unref(bus);
    return menu_answer;
}

static void test_tray(void) {
    printf("Tray icon\n");
    printf("        taken by a panel: %s\n", lucid_tray_shown() ? "yes" : "no");
    lucid_tray_update(LUCID_TRAY_IDLE, "Lucid: ready. Hold Right Ctrl and speak.");
    check(lucid_test_tray_picture(in_folder("tray-idle.png"), 0x7a8aa0), "draws its icon");
    lucid_tray_update(LUCID_TRAY_RECORDING, "Lucid: recording");
    check(lucid_test_tray_picture(in_folder("tray-recording.png"), 0x7a8aa0), "draws its icon while recording");
    lucid_tray_update(LUCID_TRAY_ATTENTION, "Lucid needs a few things first");
    check(lucid_test_tray_picture(in_folder("tray-attention.png"), 0x7a8aa0), "draws its icon when setup is needed");

    test_menu = true;
    lucid_tray_update(LUCID_TRAY_IDLE, "Lucid");
    char menu[2048];
    lucid_test_menu(menu, sizeof menu);
    check_text(menu, "First\nCleanup\n    * Second\n", "keeps the menu it is given, submenus included");

    /* A panel reads the menu from the bus, and says there when an item is clicked. */
    lucid_pump(300);
    GVariant *layout = ask_menu("GetLayout", g_variant_new("(iias)", 0, -1, NULL));
    if (!layout) {
        printf("        skipped: this session has no message bus for a panel to ask on\n");
        return;
    }
    char *described = g_variant_print(layout, FALSE);
    g_variant_unref(layout);
    check(strstr(described, "'First'") && strstr(described, "'Cleanup'") && strstr(described, "'Second'"), "offers the menu to the panel");
    check(strstr(described, "'toggle-state': <1>") != NULL, "with the tick on the item that has one");
    /* The number the panel knows "Second" by comes just before its details. */
    int item = -1;
    GRegex *pattern = g_regex_new("\\((\\d+), \\{[^{}]*'label': <'Second'>", 0, 0, NULL);
    GMatchInfo *match = NULL;
    if (g_regex_match(pattern, described, 0, &match)) {
        char *number = g_match_info_fetch(match, 1);
        item = atoi(number);
        g_free(number);
    }
    g_match_info_free(match);
    g_regex_unref(pattern);
    g_free(described);
    check(item >= 0, "each item has a number the panel can name");
    chosen_command = 0;
    GVariant *done = ask_menu("Event", g_variant_new("(isvu)", item, "clicked", g_variant_new_int32(0), (guint32)0));
    if (done) g_variant_unref(done);
    lucid_pump(300);
    check(chosen_command == 42, "reports the item that the panel says was clicked");
    test_menu = false;
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
    check(lucid_keyboard_watched(), "the display lets Lucid watch the keyboard");
    check(lucid_can_type(), "and press keys in other apps");
    char seen[512];

    /* Keys pressed by programs are not the user's, and Lucid's own pasting is among them. */
    key_count = 0;
    press(K_RIGHT_CTRL);
    keys_as_text(seen);
    check_text(seen, "", "ignores keys that a program pressed");

    lucid_test_accept_made_up_keys(true);
    key_count = 0;
    press(K_RIGHT_CTRL);
    keys_as_text(seen);
    check_text(seen, "down up", "reports the dictation key going down and up");

    key_count = 0;
    lucid_test_press(K_RIGHT_CTRL, true);
    lucid_pump(60);
    press(K_A);
    lucid_test_press(K_RIGHT_CTRL, false);
    lucid_pump(60);
    keys_as_text(seen);
    check_text(seen, "down other up", "reports another key pressed meanwhile");

    key_count = 0;
    escape_is_ours = false;
    press(K_ESCAPE);
    keys_as_text(seen);
    check_text(seen, "", "says nothing of Escape when nothing is being recorded");
    escape_is_ours = true;
    press(K_ESCAPE);
    keys_as_text(seen);
    check_text(seen, "escape", "reports Escape while recording");
    escape_is_ours = false;

    lucid_set_hotkey(K_RIGHT_ALT);
    key_count = 0;
    press(K_RIGHT_CTRL);
    press(K_RIGHT_ALT);
    keys_as_text(seen);
    check_text(seen, "other down up", "follows a change of dictation key");
    lucid_set_hotkey(K_RIGHT_CTRL);
    lucid_test_accept_made_up_keys(false);

    wakes = 0;
    lucid_wake();
    check(wakes == 0, "does not run posted work at once");
    lucid_pump(50);
    check(wakes == 1, "wakes the main thread when asked");
}

/* ---- Another program to type into ---- */

static void editor_changed(GtkTextBuffer *buffer, gpointer unused) {
    (void)unused;
    GtkTextIter start, end;
    gtk_text_buffer_get_bounds(buffer, &start, &end);
    char *text = gtk_text_buffer_get_text(buffer, &start, &end, FALSE);
    g_file_set_contents(g_getenv("LUCID_HARNESS_EDITOR"), text, -1, NULL);
    g_free(text);
}

/* This program again, as a window with one box for text. It writes down what is in the box
   each time that changes, which is how the test reads it. */
static int run_editor(void) {
    gtk_init(NULL, NULL);
    GtkWidget *window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
    gtk_window_set_title(GTK_WINDOW(window), "Lucid test editor");
    gtk_window_set_default_size(GTK_WINDOW(window), 520, 320);
    GtkWidget *box = gtk_text_view_new();
    gtk_container_add(GTK_CONTAINER(window), box);
    g_signal_connect(gtk_text_view_get_buffer(GTK_TEXT_VIEW(box)), "changed", G_CALLBACK(editor_changed), NULL);
    g_signal_connect(window, "destroy", G_CALLBACK(gtk_main_quit), NULL);
    gtk_widget_show_all(window);
    gtk_window_present(GTK_WINDOW(window));
    gtk_main();
    return 0;
}

static GPid start(const char *first, const char *second, const char *third, const char *fourth) {
    char *arguments[] = {(char *)first, (char *)second, (char *)third, (char *)fourth, NULL};
    GPid process = 0;
    if (!g_spawn_async(NULL, arguments, NULL, G_SPAWN_SEARCH_PATH | G_SPAWN_DO_NOT_REAP_CHILD, NULL, NULL, &process, NULL)) return 0;
    return process;
}

static void wait_for(const char *path, const char *wanted) {
    for (int attempt = 0; attempt < 40; attempt++) {
        char *text = contents(path);
        bool there = strcmp(text, wanted) == 0;
        g_free(text);
        if (there) return;
        lucid_pump(50);
    }
}

static void test_clipboard_and_typing(void) {
    printf("Clipboard\n");
    char got[1024];
    const char *words = "Caf\xC3\xA9, na\xC3\xAFve \xE2\x80\x94 \xF0\x9F\x8E\x89 done.";
    check(lucid_copy(words), "copies text");
    lucid_clipboard_text(got, sizeof got);
    check_text(got, words, "keeps accents, dashes and emoji");

    printf("Typing into the app in front\n");
    const char *file = in_folder("editor.txt");
    g_setenv("LUCID_HARNESS_EDITOR", file, TRUE);
    GPid editor = start(self, "editor", NULL, NULL);
    check(editor != 0, "another program opens a window");
    bool in_front = false;
    char program[260], name[260];
    bool secure = true, not_text = true;
    for (int attempt = 0; attempt < 60 && !in_front; attempt++) {
        lucid_pump(100);
        lucid_front_window(program, sizeof program, name, sizeof name, &secure, &not_text);
        in_front = strcmp(program, "linux-layer-tests") == 0;
    }
    check(in_front, "sees which program's window is in front");
    printf("        program \"%s\", called \"%s\"\n", program, name);
    check(name[0] != 0, "knows what the window calls itself");
    check(!secure && !not_text, "takes it for somewhere to type");
    lucid_pump(300);

    lucid_copy("what the user had copied");
    check(lucid_paste("So let's meet at three."), "pastes into it");
    wait_for(file, "So let's meet at three.");
    char *typed = contents(file);
    check_text(typed, "So let's meet at three.", "the text arrives in the document");
    g_free(typed);
    lucid_pump(900);
    lucid_clipboard_text(got, sizeof got);
    check_text(got, "what the user had copied", "puts back what was on the clipboard");

    /* Two in a row, the second before the clipboard has been put back. */
    check(lucid_paste(" Second."), "pastes again");
    lucid_pump(250);
    check(lucid_paste(" Third."), "and again straight away");
    wait_for(file, "So let's meet at three. Second. Third.");
    typed = contents(file);
    check_text(typed, "So let's meet at three. Second. Third.", "each text follows the one before");
    g_free(typed);
    lucid_pump(900);
    lucid_clipboard_text(got, sizeof got);
    check_text(got, "what the user had copied", "and what the user had is still put back");

    /* The user copies something else straight after the paste. That must not be undone. */
    lucid_paste(" Fourth.");
    lucid_pump(250);
    lucid_copy("copied by the user meanwhile");
    lucid_pump(900);
    lucid_clipboard_text(got, sizeof got);
    check_text(got, "copied by the user meanwhile", "leaves alone what the user copied in the meantime");

    printf("Lucid's window\n");
    check(!lucid_focus_window("No such window"), "does not find a window that is not there");
    check(lucid_focus_window("Lucid test editor"), "finds a window by its title and brings it forward");
    lucid_close_window("Lucid test editor");
    int status = -1;
    for (int attempt = 0; attempt < 50 && waitpid(editor, &status, WNOHANG) == 0; attempt++) lucid_pump(100);
    check(status == 0, "asks it to close, as on quitting");
    if (status != 0) kill(editor, SIGTERM);

    /* A terminal pastes what is selected, not what was copied, and takes Ctrl+V for
       something else. This one reads 21 characters and writes them down. */
    char *xterm = g_find_program_in_path("xterm");
    if (!xterm) {
        printf("        skipped the terminal: xterm is not installed\n");
        return;
    }
    g_free(xterm);
    printf("Typing into a terminal\n");
    const char *heard = in_folder("terminal.txt");
    char *command = g_strdup_printf("stty -icanon -echo; head -c 21 > '%s'", heard);
    GPid terminal = 0;
    char *arguments[] = {(char *)"xterm", (char *)"-e", (char *)"sh", (char *)"-c", command, NULL};
    g_spawn_async(NULL, arguments, NULL, G_SPAWN_SEARCH_PATH | G_SPAWN_DO_NOT_REAP_CHILD, NULL, NULL, &terminal, NULL);
    in_front = false;
    for (int attempt = 0; attempt < 60 && !in_front; attempt++) {
        lucid_pump(100);
        lucid_front_window(program, sizeof program, name, sizeof name, &secure, &not_text);
        in_front = strcmp(program, "xterm") == 0;
    }
    check(in_front, "a terminal comes to the front");
    lucid_pump(500);
    check(lucid_paste("echo typed by dictation"), "pastes into it");
    wait_for(heard, "echo typed by dictati");
    typed = contents(heard);
    check_text(typed, "echo typed by dictati", "the text arrives at the program in the terminal");
    g_free(typed);
    g_free(command);
    kill(terminal, SIGTERM);
    waitpid(terminal, NULL, 0);
    lucid_pump(900);
}

/* ---- The desktop itself ---- */

/* Runs this program again to add Lucid to the menu, with `shared` as the only folder of
   things installed for everyone. */
static bool add_to_menu(bool replace, const char *shared) {
    char **environment = g_environ_setenv(g_get_environ(), "XDG_DATA_DIRS", shared, TRUE);
    char *arguments[] = {self, "launcher", replace ? "replace" : "keep", NULL};
    int status = -1;
    bool ran = g_spawn_sync(NULL, arguments, environment, G_SPAWN_DEFAULT, NULL, NULL, NULL, NULL, &status, NULL);
    g_strfreev(environment);
    return ran && WIFEXITED(status) && WEXITSTATUS(status) == 0;
}

static void test_system(void) {
    printf("Opening at sign-in\n");
    check(!lucid_opens_at_login(), "is off to begin with");
    check(lucid_set_opens_at_login(true), "can be switched on");
    check(lucid_opens_at_login(), "is then on");
    char *entry = g_build_filename(g_get_user_config_dir(), "autostart", "lucid.desktop", NULL);
    char *listed = contents(entry);
    check(strstr(listed, "Type=Application") && strstr(listed, "Terminal=false") && strstr(listed, self), "by a file the desktop reads when the user signs in");
    g_free(listed);
    g_free(entry);
    check(lucid_set_opens_at_login(false), "can be switched off");
    check(!lucid_opens_at_login(), "is then off");

    printf("The applications menu\n");
    /* Whether Lucid adds itself depends on what is installed for everyone, so each try is a
       copy of this program that is shown a folder of our own in place of the system's. */
    char *nothing_shared = g_strdup(in_folder("shared-empty"));
    char *package_shared = g_strdup(in_folder("shared-package"));
    char *package_folder = g_build_filename(package_shared, "applications", NULL);
    char *package_entry = g_build_filename(package_folder, "lucid.desktop", NULL);
    g_mkdir_with_parents(nothing_shared, 0755);
    g_mkdir_with_parents(package_folder, 0755);
    g_file_set_contents(package_entry, "[Desktop Entry]\nType=Application\nName=Lucid\nExec=/opt/lucid/Lucid\n", -1, NULL);
    char *launcher = g_build_filename(g_get_user_data_dir(), "applications", "lucid.desktop", NULL);
    unlink(launcher);
    check(add_to_menu(false, package_shared), "Lucid installed for everyone is in the menu already");
    check(!g_file_test(launcher, G_FILE_TEST_EXISTS), "so it adds nothing for this user");
    check(add_to_menu(false, nothing_shared), "any other Lucid adds itself");
    listed = contents(launcher);
    check(strstr(listed, "Name=Lucid") && strstr(listed, "Terminal=false") && strstr(listed, "Icon=lucid") && strstr(listed, self), "with an entry that starts this copy");
    g_free(listed);
    char *icon = g_build_filename(g_get_user_data_dir(), "icons", "hicolor", "256x256", "apps", "lucid.png", NULL);
    check(g_file_test(icon, G_FILE_TEST_EXISTS), "and its icon");
    g_free(icon);
    /* Another copy of Lucid, still there, keeps its entry. One that is gone does not. */
    g_file_set_contents(launcher, "[Desktop Entry]\nType=Application\nName=Lucid\nExec=/bin/sh\n", -1, NULL);
    add_to_menu(false, nothing_shared);
    listed = contents(launcher);
    check(strstr(listed, "Exec=/bin/sh") != NULL, "leaves the entry of another copy alone");
    g_free(listed);
    g_file_set_contents(launcher, "[Desktop Entry]\nType=Application\nName=Lucid\nExec=\"/no/such folder/Lucid\"\n", -1, NULL);
    add_to_menu(false, nothing_shared);
    listed = contents(launcher);
    check(strstr(listed, self) != NULL, "takes over the entry of a copy that is gone");
    g_free(listed);
    g_file_set_contents(launcher, "[Desktop Entry]\nType=Application\nName=Lucid\nExec=/bin/sh\n", -1, NULL);
    add_to_menu(true, nothing_shared);
    listed = contents(launcher);
    check(strstr(listed, self) != NULL, "and any entry when told to");
    g_free(listed);
    unlink(launcher);
    g_free(launcher);
    g_free(package_entry);
    g_free(package_folder);
    g_free(package_shared);
    g_free(nothing_shared);

    printf("Allowing the keyboard in a Wayland session\n");
    /* A stand-in for the desktop's password prompt: this program again, which writes down
       what it was asked to run. */
    g_setenv("LUCID_TEST_PKEXEC", self, TRUE);
    g_setenv("LUCID_HARNESS_NOTE", in_folder("allowed.txt"), TRUE);
    unlink(in_folder("allowed.txt"));
    check(lucid_allow_keys(), "asks with the desktop's password prompt");
    char *asked = NULL;
    for (int attempt = 0; attempt < 50; attempt++) {
        lucid_pump(100);
        g_free(asked);
        asked = contents(in_folder("allowed.txt"));
        if (asked[0]) break;
    }
    check(strstr(asked, "[/bin/sh] [-c]") != NULL, "to run one command as someone who may change the system");
    check(strstr(asked, "/etc/udev/rules.d/70-lucid.rules") && strstr(asked, "KERNEL==\"uinput\"") && strstr(asked, "ID_INPUT_KEYBOARD") && strstr(asked, "udevadm trigger"),
          "which lets whoever is signed in read the keyboards and make one");
    g_free(asked);
    g_unsetenv("LUCID_TEST_PKEXEC");

    printf("Microphone\n");
    char recorder[64];
    lucid_mic_recorder(recorder, sizeof recorder);
    /* The sound system is asked in the background, and answers within moments. */
    lucid_mic_devices();
    lucid_pump(500);
    printf("        microphones: %d, recorded with: %s\n", lucid_mic_devices(), recorder[0] ? recorder : "nothing");
    if (recorder[0] && lucid_mic_devices() > 0) {
        check(lucid_mic_start(), "starts recording");
        /* A microphone takes a moment to get going, so the second that is measured is a later one. */
        lucid_pump(900);
        size_t settled = lucid_mic_count();
        lucid_pump(1000);
        size_t so_far = lucid_mic_count();
        int16_t latest[1600];
        size_t newest = lucid_mic_latest(latest, 1600);
        float level = lucid_mic_level();
        size_t total = lucid_mic_stop();
        printf("        %u samples in one second, %u in all, level %.3f\n", (unsigned)(so_far - settled), (unsigned)total, (double)level);
        check(so_far - settled > 14400 && so_far - settled < 17600, "records about 16,000 samples a second");
        check(newest == 1600, "hands over the newest samples while recording");
        check(level > 0.01f, "measures how loud it is");
        int16_t *all = (int16_t *)calloc(total + 1, sizeof(int16_t));
        check(lucid_mic_take(all, total) == total && total >= so_far, "hands over the whole recording");
        FILE *out = fopen(in_folder("recorded.raw"), "wb");
        if (out) {
            fwrite(all, sizeof(int16_t), total, out);
            fclose(out);
        }
        free(all);
        check(lucid_mic_count() == 0, "then lets it go");
        check(lucid_mic_level() == 0, "and the level falls back to nothing");
    } else {
        printf("        skipped: nothing to record with, or no microphone\n");
    }

    printf("Opening Lucid's window\n");
    /* A stand-in for the browser: this program again, which writes down how it was started. */
    g_setenv("LUCID_BROWSER", self, TRUE);
    g_setenv("LUCID_HARNESS_NOTE", in_folder("browser.txt"), TRUE);
    unlink(in_folder("browser.txt"));
    check(lucid_open_window("http://127.0.0.1:5123/#home&key=0123abcd", "/home/some one/.local/share/Lucid/window"), "starts the browser");
    char *started = NULL;
    for (int attempt = 0; attempt < 50; attempt++) {
        lucid_pump(100);
        g_free(started);
        started = contents(in_folder("browser.txt"));
        if (started[0]) break;
    }
    printf("        %s", started);
    check(strstr(started, "[--app=http://127.0.0.1:5123/#home&key=0123abcd]") != NULL, "gives it the page's address, key included");
    check(strstr(started, "[--user-data-dir=/home/some one/.local/share/Lucid/window]") != NULL, "gives it a profile folder of its own, spaces and all");
    g_free(started);
    g_unsetenv("LUCID_BROWSER");

    printf("Running twice\n");
    activations = 0;
    GPid second = start(self, "second", NULL, NULL);
    int status = -1;
    for (int attempt = 0; attempt < 50 && waitpid(second, &status, WNOHANG) == 0; attempt++) lucid_pump(100);
    lucid_pump(300);
    check(WIFEXITED(status) && WEXITSTATUS(status) == 7, "a second copy sees that Lucid is already running");
    check(activations == 1, "and the first is asked to show its window");
}

/* ---- A Wayland session, as far as it can be made up ----

   There, Lucid reads the keyboards themselves and presses keys through a keyboard of its
   own. Both are files to a program, so files stand in for them here. */

static void write_key(int fd, int code, int value) {
    struct input_event event;
    memset(&event, 0, sizeof event);
    event.type = EV_KEY;
    event.code = (unsigned short)code;
    event.value = value;
    if (write(fd, &event, sizeof event) != (ssize_t)sizeof event) printf("        could not write a key\n");
}

static void test_without_the_display(const LucidCallbacks *callbacks) {
    printf("Reading the keyboard itself, and pressing keys through one of Lucid's own\n");
    const char *keyboard = in_folder("keyboard"), *made = in_folder("made-keyboard");
    unlink(keyboard);
    check(mkfifo(keyboard, 0600) == 0, "a stand-in keyboard is made");
    int out = open(made, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (out >= 0) close(out);
    /* Opened for reading and writing, so that Lucid's reading end always has a writer. */
    int typing = open(keyboard, O_RDWR | O_NONBLOCK);
    g_setenv("LUCID_TEST_KEYBOARD", keyboard, TRUE);
    g_setenv("LUCID_TEST_UINPUT", made, TRUE);
    check(lucid_start(callbacks), "Lucid starts again");
    check(lucid_keyboard_watched(), "it reads the keyboard");
    check(lucid_can_type(), "and has a keyboard to press keys with");

    char seen[512];
    key_count = 0;
    escape_is_ours = true;
    write_key(typing, K_RIGHT_CTRL, 1);
    write_key(typing, K_RIGHT_CTRL, 2); /* held down, the key repeats */
    write_key(typing, K_A, 1);
    write_key(typing, K_A, 0);
    write_key(typing, K_ESCAPE, 1);
    write_key(typing, K_ESCAPE, 0);
    write_key(typing, K_RIGHT_CTRL, 0);
    lucid_pump(400);
    keys_as_text(seen);
    check_text(seen, "down other escape up", "reports what was pressed on it");
    escape_is_ours = false;

    lucid_copy("before");
    GPid editor = start(self, "editor", NULL, NULL);
    lucid_pump(1500);
    check(lucid_paste("typed without the display's help"), "pastes");
    lucid_pump(600);
    struct input_event pressed[16];
    memset(pressed, 0, sizeof pressed);
    int in = open(made, O_RDONLY);
    ssize_t got = in >= 0 ? read(in, pressed, sizeof pressed) : 0;
    if (in >= 0) close(in);
    char keys_pressed[256] = "";
    for (size_t index = 0; index < (size_t)(got > 0 ? got : 0) / sizeof pressed[0]; index++) {
        if (pressed[index].type != EV_KEY) continue;
        char one[32];
        snprintf(one, sizeof one, "%s%d:%d", keys_pressed[0] ? " " : "", pressed[index].code, pressed[index].value);
        strcat(keys_pressed, one);
    }
    /* 42 is the left Shift key and 110 is Insert. */
    check_text(keys_pressed, "42:1 110:1 110:0 42:0", "by pressing Shift+Insert on its own keyboard");
    char got_text[256];
    lucid_clipboard_text(got_text, sizeof got_text);
    check_text(got_text, "typed without the display's help", "with the text on the clipboard meanwhile");
    lucid_pump(900);
    lucid_clipboard_text(got_text, sizeof got_text);
    check_text(got_text, "before", "and what was there put back afterwards");
    if (editor) {
        kill(editor, SIGTERM);
        waitpid(editor, NULL, 0);
    }
    if (typing >= 0) close(typing);
    g_unsetenv("LUCID_TEST_KEYBOARD");
    g_unsetenv("LUCID_TEST_UINPUT");
}

int main(int argc, char **argv) {
    ssize_t length = readlink("/proc/self/exe", self, sizeof self - 1);
    self[length > 0 ? length : 0] = 0;

    /* Started as the stand-in browser, or the stand-in password prompt: write down how, and leave. */
    const char *note = g_getenv("LUCID_HARNESS_NOTE");
    if (note && argc > 1 && (strncmp(argv[1], "--app=", 6) == 0 || strcmp(argv[1], "/bin/sh") == 0)) {
        FILE *file = fopen(note, "wb");
        if (file) {
            for (int index = 1; index < argc; index++) fprintf(file, "[%s] ", argv[index]);
            fputs("\n", file);
            fclose(file);
        }
        return 0;
    }
    if (argc > 1 && strcmp(argv[1], "second") == 0) return lucid_claim_single_instance() ? 0 : 7;
    if (argc > 1 && strcmp(argv[1], "editor") == 0) return run_editor();
    if (argc > 2 && strcmp(argv[1], "launcher") == 0) return lucid_install_launcher(strcmp(argv[2], "replace") == 0) ? 0 : 7;

    snprintf(folder, sizeof folder, "%s", argc > 1 ? argv[1] : ".");
    g_setenv("LUCID_HARNESS_SCREEN", in_folder("screen.png"), TRUE);

    check(lucid_claim_single_instance(), "the first copy of Lucid may run");
    LucidCallbacks callbacks = {on_key, on_wants_escape, on_wake, on_menu_opening, on_menu_chosen, on_activated};
    check(lucid_start(&callbacks), "the desktop gives Lucid its window");
    lucid_pump(200);

    test_pill();
    test_tray();
    test_keyboard();
    test_clipboard_and_typing();
    test_system();

    lucid_quit();
    int code = lucid_run();
    lucid_stop();
    check(code == 0, "quits cleanly");

    test_without_the_display(&callbacks);
    lucid_stop();

    printf("%s  %d checks, %d failed\n", failures ? "FAILED" : "PASSED", checks, failures);
    return failures ? 1 : 0;
}
