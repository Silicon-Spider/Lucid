/* Shared by the files of the Linux half of this library. Not for Lucid's Swift code. */
#ifndef LUCIDDESK_LINUX_INTERNAL_H
#define LUCIDDESK_LINUX_INTERNAL_H

#ifdef __linux__

/* For the few things here that are Linux's own, such as pipe2. */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include <gtk/gtk.h>
#include <gdk/gdkx.h>
#include <X11/Xlib.h>

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "../include/luciddesk.h"

/* Key codes as in <linux/input-event-codes.h>. An X11 key code is the same number plus 8. */
#define LUCID_KEY_CODE_ESCAPE 1
#define LUCID_X11_OFFSET 8

extern LucidCallbacks lucid_callbacks;

/* The connection to the display that GTK draws on. NULL before lucid_start. Main thread. */
Display *lucid_display(void);
/* A folder of Lucid's own for files it can make again, such as the tray icon's pictures. */
const char *lucid_cache_folder(void);

/* Saves Lucid's icon as a .png file, `size` pixels square. `look` is one of LUCID_TRAY_*. */
bool lucid_icon_save(int look, const char *path, double size);

/* Each part's share of starting and stopping. */
/* Tries again to make the keyboard Lucid pastes with, after the user has allowed it. */
void lucid_typing_retry(void);
bool lucid_keys_start(void);
void lucid_keys_stop(void);
void lucid_typing_start(void);
void lucid_typing_stop(void);
bool lucid_pill_make(void);
void lucid_pill_destroy(void);
void lucid_tray_make(void);
void lucid_tray_destroy(void);

#endif /* __linux__ */
#endif
