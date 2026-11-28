#include "internal.h"

#ifdef __linux__

#include <libayatana-appindicator/app-indicator.h>
#include <string.h>

/* Lucid's icon in the panel, and the menu it opens.

   A Linux desktop shows the menu itself, from a description Lucid gives it, and does not
   say when it is about to. So the menu is made again whenever the app says something has
   changed, and every few seconds in case something else has. */

#define MOST_ITEMS 96

typedef struct {
    int command;
    int flags;
    char *title;
} Item;

static Item items[MOST_ITEMS];
static int item_count;

static AppIndicator *indicator;
static GtkWidget *menu;
/* The menu the desktop was last given, as text, to tell whether a new one is needed. */
static char *given;
static int state = LUCID_TRAY_IDLE;
static guint refresh_timer;

static const char *icon_name(int look) {
    switch (look) {
    case LUCID_TRAY_RECORDING: return "lucid-tray-recording";
    case LUCID_TRAY_ATTENTION: return "lucid-tray-attention";
    default: return "lucid-tray-idle";
    }
}

static void round_box(cairo_t *cr, double x, double y, double width, double height, double radius) {
    cairo_new_sub_path(cr);
    cairo_arc(cr, x + width - radius, y + radius, radius, -G_PI / 2, 0);
    cairo_arc(cr, x + width - radius, y + height - radius, radius, 0, G_PI / 2);
    cairo_arc(cr, x + radius, y + height - radius, radius, G_PI / 2, G_PI);
    cairo_arc(cr, x + radius, y + radius, radius, G_PI, 3 * G_PI / 2);
    cairo_close_path(cr);
}

/* Five bars, the middle one tallest: the same shape the pill shows while recording. They
   are white on a dark square, because a panel may be light or dark and does not say. */
static void draw_icon(cairo_t *cr, int look, double size) {
    double unit = size / 32;
    round_box(cr, 0, 0, size, size, 7 * unit);
    cairo_set_source_rgb(cr, 0.08, 0.08, 0.08);
    cairo_fill(cr);
    if (look == LUCID_TRAY_RECORDING) cairo_set_source_rgb(cr, 1.0, 0.35, 0.31);
    else cairo_set_source_rgb(cr, 1, 1, 1);
    static const double heights[5] = {8, 16, 22, 16, 8};
    static const double lefts[5] = {5, 10, 14.5, 19, 24};
    for (int index = 0; index < 5; index++) {
        round_box(cr, lefts[index] * unit, (32 - heights[index]) / 2 * unit, 3 * unit, heights[index] * unit, 1.5 * unit);
        cairo_fill(cr);
    }
    if (look == LUCID_TRAY_ATTENTION) {
        cairo_set_source_rgb(cr, 1.0, 0.62, 0.04);
        cairo_arc(cr, size - 7 * unit, size - 7 * unit, 6 * unit, 0, 2 * G_PI);
        cairo_fill(cr);
    }
}

bool lucid_icon_save(int look, const char *path, double size) {
    cairo_surface_t *picture = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, (int)size, (int)size);
    cairo_t *cr = cairo_create(picture);
    draw_icon(cr, look, size);
    cairo_destroy(cr);
    bool saved = cairo_surface_write_to_png(picture, path) == CAIRO_STATUS_SUCCESS;
    cairo_surface_destroy(picture);
    return saved;
}

/* The menu as lines of text. */
static char *describe(void) {
    GString *text = g_string_new(NULL);
    int depth = 0;
    for (int index = 0; index < item_count; index++) {
        const Item *item = &items[index];
        if (item->flags & LUCID_MENU_CLOSES) {
            if (depth > 0) depth--;
            continue;
        }
        g_string_append_printf(
            text, "%s%s%s%s\n", depth > 0 ? "    " : "",
            (item->flags & LUCID_MENU_CHECKED) ? "* " : "",
            (item->flags & LUCID_MENU_SEPARATOR) ? "---" : item->title,
            (item->flags & LUCID_MENU_DISABLED) ? "  (disabled)" : "");
        if (item->flags & LUCID_MENU_OPENS) depth++;
    }
    return g_string_free(text, FALSE);
}

static void chosen(GtkMenuItem *widget, gpointer command) {
    (void)widget;
    if (lucid_callbacks.menu_chosen) lucid_callbacks.menu_chosen(GPOINTER_TO_INT(command));
}

/* Builds the menu that starts at `*index`, up to the end of that submenu. */
static GtkWidget *build(int *index) {
    GtkWidget *built = gtk_menu_new();
    while (*index < item_count) {
        const Item *item = &items[(*index)++];
        if (item->flags & LUCID_MENU_CLOSES) break;
        GtkWidget *widget;
        if (item->flags & LUCID_MENU_SEPARATOR) {
            widget = gtk_separator_menu_item_new();
        } else if (item->flags & LUCID_MENU_OPENS) {
            widget = gtk_menu_item_new_with_label(item->title);
            gtk_menu_item_set_submenu(GTK_MENU_ITEM(widget), build(index));
        } else {
            if (item->flags & LUCID_MENU_CHECKED) {
                widget = gtk_check_menu_item_new_with_label(item->title);
                gtk_check_menu_item_set_active(GTK_CHECK_MENU_ITEM(widget), TRUE);
            } else {
                widget = gtk_menu_item_new_with_label(item->title);
            }
            /* After the tick is set, or setting it would count as the user choosing it. */
            g_signal_connect(widget, "activate", G_CALLBACK(chosen), GINT_TO_POINTER(item->command));
        }
        if (item->flags & LUCID_MENU_DISABLED) gtk_widget_set_sensitive(widget, FALSE);
        gtk_menu_shell_append(GTK_MENU_SHELL(built), widget);
    }
    gtk_widget_show_all(built);
    return built;
}

/* Asks the app what the menu should be, and gives the desktop a new one if it differs. */
static void refresh(void) {
    if (!indicator) return;
    if (lucid_callbacks.menu_opening) lucid_callbacks.menu_opening();
    char *now = describe();
    if (given && strcmp(given, now) == 0) {
        g_free(now);
        return;
    }
    g_free(given);
    given = now;
    int index = 0;
    menu = build(&index);
    app_indicator_set_menu(indicator, GTK_MENU(menu));
}

static gboolean refresh_later(gpointer unused) {
    (void)unused;
    refresh();
    return G_SOURCE_CONTINUE;
}

void lucid_tray_make(void) {
    if (indicator) return;
    const char *folder = lucid_cache_folder();
    for (int look = LUCID_TRAY_IDLE; look <= LUCID_TRAY_ATTENTION; look++) {
        char *path = g_strdup_printf("%s/%s.png", folder, icon_name(look));
        lucid_icon_save(look, path, 64);
        g_free(path);
    }
    indicator = app_indicator_new_with_path(
        "lucid", icon_name(state), APP_INDICATOR_CATEGORY_APPLICATION_STATUS, folder);
    if (!indicator) return;
    app_indicator_set_title(indicator, "Lucid");
    app_indicator_set_status(indicator, APP_INDICATOR_STATUS_ACTIVE);
    /* A panel shows nothing for an icon that has no menu. */
    refresh();
    if (!menu) {
        menu = gtk_menu_new();
        app_indicator_set_menu(indicator, GTK_MENU(menu));
    }
    refresh_timer = g_timeout_add_seconds(5, refresh_later, NULL);
}

void lucid_tray_destroy(void) {
    if (refresh_timer) g_source_remove(refresh_timer);
    refresh_timer = 0;
    if (indicator) {
        app_indicator_set_status(indicator, APP_INDICATOR_STATUS_PASSIVE);
        g_object_unref(indicator);
    }
    indicator = NULL;
    menu = NULL;
    g_free(given);
    given = NULL;
}

bool lucid_tray_shown(void) {
    if (!indicator) return false;
    /* True when a panel has taken the icon. A desktop with nowhere to show one leaves it out. */
    gboolean connected = FALSE;
    g_object_get(indicator, "connected", &connected, NULL);
    return connected != FALSE;
}

void lucid_tray_update(int new_state, const char *tooltip) {
    if (!indicator) return;
    if (new_state != state) {
        state = new_state;
        app_indicator_set_icon_full(indicator, icon_name(state), "Lucid");
    }
    /* Panels that show anything on hover show the title. */
    if (tooltip && tooltip[0]) app_indicator_set_title(indicator, tooltip);
    refresh();
}

void lucid_tray_notify(const char *title, const char *text) {
    char *arguments[] = {
        (char *)"notify-send", (char *)"--app-name=Lucid", (char *)(title ? title : "Lucid"), (char *)(text ? text : ""), NULL,
    };
    g_spawn_async(
        NULL, arguments, NULL, G_SPAWN_SEARCH_PATH | G_SPAWN_STDOUT_TO_DEV_NULL | G_SPAWN_STDERR_TO_DEV_NULL,
        NULL, NULL, NULL, NULL);
}

void lucid_menu_clear(void) {
    for (int index = 0; index < item_count; index++) g_free(items[index].title);
    item_count = 0;
}

void lucid_menu_add(int command, const char *title, int flags) {
    if (item_count >= MOST_ITEMS) return;
    items[item_count].command = command;
    items[item_count].flags = flags;
    items[item_count].title = g_strdup(title ? title : "");
    item_count++;
}

bool lucid_test_tray_picture(const char *path, uint32_t background) {
    int size = 32, margin = 16;
    cairo_surface_t *picture = cairo_image_surface_create(CAIRO_FORMAT_RGB24, size + margin * 2, size + margin * 2);
    cairo_t *cr = cairo_create(picture);
    cairo_set_source_rgb(cr, ((background >> 16) & 0xff) / 255.0, ((background >> 8) & 0xff) / 255.0, (background & 0xff) / 255.0);
    cairo_paint(cr);
    cairo_translate(cr, margin, margin);
    draw_icon(cr, state, size);
    cairo_destroy(cr);
    bool saved = cairo_surface_write_to_png(picture, path) == CAIRO_STATUS_SUCCESS;
    cairo_surface_destroy(picture);
    return saved;
}

size_t lucid_test_menu(char *out, size_t capacity) {
    if (!out || capacity == 0) return 0;
    char *text = describe();
    g_strlcpy(out, text, capacity);
    g_free(text);
    return strlen(out);
}

#endif
