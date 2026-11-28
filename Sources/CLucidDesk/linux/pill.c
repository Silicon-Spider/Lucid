#include "internal.h"

#ifdef __linux__

#include <math.h>
#include <string.h>

/* The on-screen indicator: a small dark capsule at the bottom of the screen. It never takes
   the keyboard or a click, or the dictated text would go to the wrong place. */

#define FRAME_MS 33
#define HANDS_FREE "Hands-free. Press the key again to finish."
#define MARGIN 6
#define HEIGHT 34
#define PADDING 15
#define GAP 9
#define BARS_WIDTH (3 * 5 + 3 * 4)
#define DOTS_WIDTH (6 * 3 + 5 * 2)

static GtkWidget *pill;
static bool see_through;
static int status = LUCID_PILL_HIDDEN;
static char *message;
static char *preview;
static bool pulsing;
static double shown_level;
static int shown_step = -1;
static gint64 began;
static guint frame_timer;
static guint hide_timer;
static guint pulse_timer;
static int width;

static void set_text(char **slot, const char *text) {
    g_free(*slot);
    *slot = g_strdup(text ? text : "");
}

/* What the pill says now, and how much of it fits. */
static PangoLayout *words(cairo_t *cr) {
    const char *text = "";
    bool is_preview = false;
    if (status == LUCID_PILL_MESSAGE) {
        text = message ? message : "";
    } else if (status == LUCID_PILL_RECORDING || status == LUCID_PILL_HANDS_FREE) {
        if (preview && preview[0]) {
            text = preview;
            is_preview = true;
        } else if (status == LUCID_PILL_HANDS_FREE) {
            text = HANDS_FREE;
        }
    }
    if (!text[0]) return NULL;

    PangoLayout *layout = pango_cairo_create_layout(cr);
    /* The desktop's own font, a little heavier, so it stays readable in white on black. */
    PangoFontDescription *font = pango_font_description_copy(
        pango_context_get_font_description(gtk_widget_get_pango_context(pill)));
    pango_font_description_set_weight(font, PANGO_WEIGHT_SEMIBOLD);
    pango_font_description_set_absolute_size(font, 13 * PANGO_SCALE);
    pango_layout_set_font_description(layout, font);
    pango_font_description_free(font);
    pango_layout_set_single_paragraph_mode(layout, TRUE);
    pango_layout_set_text(layout, text, -1);
    /* The last words heard lose their start if they are too long. A message loses its end. */
    int limit = is_preview ? 330 : 520;
    int natural = 0;
    pango_layout_get_pixel_size(layout, &natural, NULL);
    if (natural > limit) {
        pango_layout_set_width(layout, limit * PANGO_SCALE);
        pango_layout_set_ellipsize(layout, is_preview ? PANGO_ELLIPSIZE_START : PANGO_ELLIPSIZE_END);
    }
    return layout;
}

/* A box with its two short ends fully rounded, lying down or standing up. */
static void capsule(cairo_t *cr, double left, double top, double right, double bottom) {
    double radius = MIN(right - left, bottom - top) / 2;
    cairo_new_sub_path(cr);
    cairo_arc(cr, right - radius, top + radius, radius, -G_PI / 2, 0);
    cairo_arc(cr, right - radius, bottom - radius, radius, 0, G_PI / 2);
    cairo_arc(cr, left + radius, bottom - radius, radius, G_PI / 2, G_PI);
    cairo_arc(cr, left + radius, top + radius, radius, G_PI, 3 * G_PI / 2);
    cairo_close_path(cr);
}

/* How wide the pill is for what it shows now, without the room around it. */
static int measure(cairo_t *cr) {
    PangoLayout *layout = words(cr);
    int text_width = 0;
    if (layout) {
        pango_layout_get_pixel_size(layout, &text_width, NULL);
        g_object_unref(layout);
    }
    int content;
    if (status == LUCID_PILL_RECORDING || status == LUCID_PILL_HANDS_FREE) {
        content = BARS_WIDTH + (text_width ? GAP + text_width : 0);
    } else if (status == LUCID_PILL_PROCESSING) {
        content = DOTS_WIDTH;
    } else {
        content = text_width;
    }
    return PADDING * 2 + content;
}

/* Draws the pill with its top left corner at (MARGIN, MARGIN). */
static void paint(cairo_t *cr, bool solid) {
    double grow = pulsing ? 3 : 0;
    double left = MARGIN - grow, right = MARGIN + width + grow;
    double top = MARGIN - grow, bottom = MARGIN + HEIGHT + grow;
    capsule(cr, left, top, right, bottom);
    if (solid) cairo_set_source_rgb(cr, 0.09, 0.09, 0.09);
    else cairo_set_source_rgba(cr, 0, 0, 0, 0.84);
    cairo_fill(cr);
    capsule(cr, left + 0.5, top + 0.5, right - 0.5, bottom - 0.5);
    cairo_set_source_rgba(cr, 1, 1, 1, solid ? 0.3 : 0.16);
    cairo_set_line_width(cr, 1);
    cairo_stroke(cr);

    double x = MARGIN + PADDING;
    double middle = MARGIN + HEIGHT / 2.0;
    if (status == LUCID_PILL_RECORDING || status == LUCID_PILL_HANDS_FREE) {
        static const double weights[5] = {0.45, 0.75, 1.0, 0.75, 0.45};
        double strength = shown_level * 9;
        if (strength > 1) strength = 1;
        cairo_set_source_rgb(cr, 1, 1, 1);
        for (int index = 0; index < 5; index++) {
            double bar_height = 4 + 16 * strength * weights[index];
            double bar_left = x + index * 6;
            capsule(cr, bar_left, middle - bar_height / 2, bar_left + 3, middle + bar_height / 2);
            cairo_fill(cr);
        }
        x += BARS_WIDTH + GAP;
    } else if (status == LUCID_PILL_PROCESSING) {
        int step = (int)((g_get_monotonic_time() - began) / 250000) % 3;
        shown_step = step;
        for (int index = 0; index < 3; index++) {
            cairo_set_source_rgba(cr, 1, 1, 1, index == step ? 1.0 : 0.35);
            cairo_arc(cr, x + index * 11 + 3, middle, 3, 0, 2 * G_PI);
            cairo_fill(cr);
        }
    }
    PangoLayout *layout = words(cr);
    if (layout) {
        int text_height = 0;
        pango_layout_get_pixel_size(layout, NULL, &text_height);
        cairo_set_source_rgb(cr, 1, 1, 1);
        cairo_move_to(cr, x, MARGIN + (HEIGHT - text_height) / 2.0);
        pango_cairo_show_layout(cr, layout);
        g_object_unref(layout);
    }
}

static gboolean on_draw(GtkWidget *widget, cairo_t *cr, gpointer unused) {
    (void)widget;
    (void)unused;
    cairo_set_operator(cr, CAIRO_OPERATOR_SOURCE);
    if (see_through) cairo_set_source_rgba(cr, 0, 0, 0, 0);
    else cairo_set_source_rgb(cr, 0.09, 0.09, 0.09);
    cairo_paint(cr);
    cairo_set_operator(cr, CAIRO_OPERATOR_OVER);
    paint(cr, !see_through);
    return TRUE;
}

/* Sizes the pill for what it shows, puts it in its place, and draws it. */
static void show(void) {
    if (!pill || status == LUCID_PILL_HIDDEN) return;
    cairo_surface_t *scratch = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 1, 1);
    cairo_t *cr = cairo_create(scratch);
    width = measure(cr);
    cairo_destroy(cr);
    cairo_surface_destroy(scratch);
    int full_width = width + MARGIN * 2, full_height = HEIGHT + MARGIN * 2;

    /* Bottom centre of the screen the mouse pointer is on, clear of any panel. */
    GdkDisplay *display = gdk_display_get_default();
    int pointer_x = 0, pointer_y = 0;
    GdkSeat *seat = gdk_display_get_default_seat(display);
    if (seat && gdk_seat_get_pointer(seat)) gdk_device_get_position(gdk_seat_get_pointer(seat), NULL, &pointer_x, &pointer_y);
    GdkMonitor *monitor = gdk_display_get_monitor_at_point(display, pointer_x, pointer_y);
    GdkRectangle area = {0, 0, 1280, 800};
    if (monitor) gdk_monitor_get_workarea(monitor, &area);
    gtk_window_resize(GTK_WINDOW(pill), full_width, full_height);
    gtk_window_move(GTK_WINDOW(pill), area.x + (area.width - full_width) / 2, area.y + area.height - 24 - HEIGHT - MARGIN);

    if (!gtk_widget_get_realized(pill)) gtk_widget_realize(pill);
    if (!see_through) {
        /* Nothing on this desktop blends windows, so the corners cannot be see-through.
           The window itself is cut to the capsule's shape instead. */
        cairo_surface_t *mask = cairo_image_surface_create(CAIRO_FORMAT_A1, full_width, full_height);
        cairo_t *cut = cairo_create(mask);
        capsule(cut, MARGIN, MARGIN, MARGIN + width, MARGIN + HEIGHT);
        cairo_fill(cut);
        cairo_destroy(cut);
        cairo_region_t *shape = gdk_cairo_region_create_from_surface(mask);
        gtk_widget_shape_combine_region(pill, shape);
        cairo_region_destroy(shape);
        cairo_surface_destroy(mask);
    }
    /* Clicks go through it to whatever is underneath. */
    cairo_region_t *nothing = cairo_region_create();
    gtk_widget_input_shape_combine_region(pill, nothing);
    cairo_region_destroy(nothing);

    gtk_widget_show(pill);
    gtk_widget_queue_draw(pill);
}

bool lucid_pill_make(void) {
    if (pill) return true;
    pill = gtk_window_new(GTK_WINDOW_POPUP);
    gtk_window_set_title(GTK_WINDOW(pill), "Lucid pill");
    gtk_window_set_accept_focus(GTK_WINDOW(pill), FALSE);
    gtk_window_set_focus_on_map(GTK_WINDOW(pill), FALSE);
    gtk_window_set_keep_above(GTK_WINDOW(pill), TRUE);
    gtk_window_set_type_hint(GTK_WINDOW(pill), GDK_WINDOW_TYPE_HINT_NOTIFICATION);
    gtk_window_set_decorated(GTK_WINDOW(pill), FALSE);
    gtk_window_set_skip_taskbar_hint(GTK_WINDOW(pill), TRUE);
    gtk_window_set_skip_pager_hint(GTK_WINDOW(pill), TRUE);
    gtk_widget_set_app_paintable(pill, TRUE);
    GdkScreen *screen = gtk_widget_get_screen(pill);
    GdkVisual *visual = gdk_screen_get_rgba_visual(screen);
    see_through = visual != NULL && gdk_screen_is_composited(screen);
    if (see_through) gtk_widget_set_visual(pill, visual);
    g_signal_connect(pill, "draw", G_CALLBACK(on_draw), NULL);
    return true;
}

static void stop_timer(guint *timer) {
    if (*timer) g_source_remove(*timer);
    *timer = 0;
}

void lucid_pill_destroy(void) {
    stop_timer(&frame_timer);
    stop_timer(&hide_timer);
    stop_timer(&pulse_timer);
    if (pill) gtk_widget_destroy(pill);
    pill = NULL;
    status = LUCID_PILL_HIDDEN;
}

static gboolean frame(gpointer unused) {
    (void)unused;
    if (status == LUCID_PILL_PROCESSING) {
        int step = (int)((g_get_monotonic_time() - began) / 250000) % 3;
        if (step != shown_step && pill) gtk_widget_queue_draw(pill);
        return G_SOURCE_CONTINUE;
    }
    /* The bars follow the microphone, but not in jumps. */
    double level = lucid_mic_level();
    double next = shown_level + (level - shown_level) * 0.5;
    /* Too small a change to see is not worth drawing. */
    if (fabs(next - shown_level) >= 0.0004) {
        shown_level = next;
        if (pill) gtk_widget_queue_draw(pill);
    }
    return G_SOURCE_CONTINUE;
}

void lucid_pill_show(int new_status, const char *text) {
    if (!pill) return;
    stop_timer(&hide_timer);
    /* Words heard belong to one recording. Hands-free carries on the same one. */
    if (new_status != LUCID_PILL_HANDS_FREE) set_text(&preview, "");
    if (new_status == LUCID_PILL_MESSAGE) set_text(&message, text);
    if (new_status != status) began = g_get_monotonic_time();
    status = new_status;
    if (status == LUCID_PILL_HIDDEN) {
        stop_timer(&frame_timer);
        gtk_widget_hide(pill);
        return;
    }
    shown_level = lucid_mic_level();
    show();
    /* The bars and the dots move. A message stays as it is. */
    if (status == LUCID_PILL_MESSAGE) stop_timer(&frame_timer);
    else if (!frame_timer) frame_timer = g_timeout_add(FRAME_MS, frame, NULL);
}

static gboolean hide_after_message(gpointer unused) {
    (void)unused;
    hide_timer = 0;
    lucid_pill_show(LUCID_PILL_HIDDEN, NULL);
    return G_SOURCE_REMOVE;
}

void lucid_pill_flash(const char *text, int milliseconds) {
    if (!pill) return;
    lucid_pill_show(LUCID_PILL_MESSAGE, text);
    hide_timer = g_timeout_add((guint)(milliseconds < 0 ? 0 : milliseconds), hide_after_message, NULL);
}

static gboolean pulse_over(gpointer unused) {
    (void)unused;
    pulse_timer = 0;
    pulsing = false;
    if (pill && status != LUCID_PILL_HIDDEN) gtk_widget_queue_draw(pill);
    return G_SOURCE_REMOVE;
}

void lucid_pill_pulse(void) {
    if (!pill || status == LUCID_PILL_HIDDEN) return;
    pulsing = true;
    gtk_widget_queue_draw(pill);
    stop_timer(&pulse_timer);
    pulse_timer = g_timeout_add(150, pulse_over, NULL);
}

void lucid_pill_preview(const char *text) {
    if (!pill) return;
    set_text(&preview, text);
    show();
}

bool lucid_pill_visible(void) {
    return pill && gtk_widget_get_visible(pill);
}

bool lucid_test_pill_picture(const char *path, uint32_t background) {
    if (!pill || status == LUCID_PILL_HIDDEN) return false;
    cairo_surface_t *picture = cairo_image_surface_create(CAIRO_FORMAT_RGB24, width + MARGIN * 2, HEIGHT + MARGIN * 2);
    cairo_t *cr = cairo_create(picture);
    cairo_set_source_rgb(cr, ((background >> 16) & 0xff) / 255.0, ((background >> 8) & 0xff) / 255.0, (background & 0xff) / 255.0);
    cairo_paint(cr);
    paint(cr, false);
    cairo_destroy(cr);
    bool saved = cairo_surface_write_to_png(picture, path) == CAIRO_STATUS_SUCCESS;
    cairo_surface_destroy(picture);
    return saved;
}

#endif
