/*
 * Umbrella header for the CGtk system-library target.
 *
 * gtk/gtk.h transitively pulls in GLib, GObject, GIO, Pango and GDK, which is
 * everything the Linux front end talks to. It is included through pkg-config's
 * include paths rather than an absolute path, because those differ by distribution
 * and architecture (Debian multiarch puts glib's config header under
 * /usr/lib/<triple>/glib-2.0/include).
 *
 * Everything below it exists because of three hard limits on what Swift can import
 * from C, each of which would otherwise have to be worked around in Swift with
 * unsafe pointer arithmetic:
 *
 *   1. **Function-like macros are invisible to Swift.** GTK_WINDOW(), G_OBJECT(),
 *      G_CALLBACK() and g_signal_connect() are all macros, so every upcast and every
 *      signal connection needs a real function to call.
 *   2. **Swift cannot call C variadics at all.** g_object_set/get, g_variant_new and
 *      g_markup_printf_escaped are unreachable; where one is needed, a fixed-arity
 *      wrapper stands in for it.
 *   3. **Swift's #if cannot see the GTK version.** A call that is deprecated in one
 *      supported release and absent in another has to be forked here, where
 *      GTK_CHECK_VERSION works.
 *
 * A second, quieter reason: the Clang importer represents an opaque GTK type
 * (GtkLabel, GtkScrolledWindow, GtkEventController) as OpaquePointer and a complete
 * one (GtkWidget, GtkWindow) as UnsafeMutablePointer<T>, and which is which is not
 * something the Swift side should have to know. Casting in C means it never has to.
 */
#ifndef MONKEYSPAW_CGTK_SHIM_H
#define MONKEYSPAW_CGTK_SHIM_H

#include <gtk/gtk.h>
#include <fcntl.h>
#include <linux/stat.h>
#include <linux/fs.h>
#include <sys/syscall.h>
#include <unistd.h>

/* Swift cannot call variadic syscall; never replace an occupied sync target. */
static inline int mp_rename_exclusive(const char *source, const char *destination) {
    return (int)syscall(SYS_renameat2, AT_FDCWD, source, AT_FDCWD, destination, RENAME_NOREPLACE);
}

/* Birth time distinguishes an immediately reused inode without using mtime. */
static inline int mp_directory_birth(const char *path, int64_t *seconds, uint32_t *nanos) {
    struct statx info;
    if (syscall(SYS_statx, AT_FDCWD, path, AT_SYMLINK_NOFOLLOW, STATX_BTIME, &info) != 0
        || !(info.stx_mask & STATX_BTIME)) return -1;
    *seconds = info.stx_btime.tv_sec;
    *nanos = info.stx_btime.tv_nsec;
    return 0;
}

/* GtkTextTag properties require a C variadic; the buffer's table owns the tag. */
static inline GtkTextTag *mp_text_buffer_background_tag(GtkTextBuffer *buffer,
                                                       const char *name, const char *color) {
    GtkTextTag *tag = gtk_text_tag_new(name);
    g_object_set(tag, "background", color, "foreground", "#1b1b1b", NULL);
    gtk_text_tag_table_add(gtk_text_buffer_get_tag_table(buffer), tag);
    g_object_unref(tag);
    return tag;
}
#ifdef GDK_WINDOWING_X11
#include <gdk/x11/gdkx.h>
#endif
#ifdef GDK_WINDOWING_WAYLAND
#include <gdk/wayland/gdkwayland.h>
#endif

/* ---- Upcasts (the GTK_*() / G_*() macros) ---------------------------------- */

static inline GtkWindow    *mp_window(GtkWidget *w)    { return GTK_WINDOW(w); }
static inline GtkWidget    *mp_window_widget(GtkWindow *w) { return GTK_WIDGET(w); }
static inline GtkButton    *mp_button(GtkWidget *w)  { return GTK_BUTTON(w); }
static inline GtkBox       *mp_box(GtkWidget *w)       { return GTK_BOX(w); }
static inline GtkLabel     *mp_label(GtkWidget *w)     { return GTK_LABEL(w); }
static inline GtkEntry     *mp_entry(GtkWidget *w)     { return GTK_ENTRY(w); }
static inline GtkWidget    *mp_entry_text_delegate(GtkWidget *w) {
    GtkEditable *delegate = gtk_editable_get_delegate(GTK_EDITABLE(w));
    return delegate != NULL ? GTK_WIDGET(delegate) : NULL;
}
static inline GtkTextView  *mp_text_view(GtkWidget *w) { return GTK_TEXT_VIEW(w); }
static inline GtkCheckButton *mp_check_button(GtkWidget *w) { return GTK_CHECK_BUTTON(w); }
static inline GtkListBox   *mp_list_box(GtkWidget *w) { return GTK_LIST_BOX(w); }
static inline GtkListBoxRow *mp_list_box_row(GtkWidget *w) { return GTK_LIST_BOX_ROW(w); }
static inline GtkComboBox  *mp_combo_box(GtkWidget *w) { return GTK_COMBO_BOX(w); }
static inline GtkComboBoxText *mp_combo_box_text(GtkWidget *w) { return GTK_COMBO_BOX_TEXT(w); }
static inline GtkStack     *mp_stack(GtkWidget *w) { return GTK_STACK(w); }
static inline GtkNotebook  *mp_notebook(GtkWidget *w) { return GTK_NOTEBOOK(w); }
static inline GtkNativeDialog *mp_native_dialog(GtkFileChooserNative *d) { return GTK_NATIVE_DIALOG(d); }
static inline GtkFileChooser *mp_file_chooser(GtkFileChooserNative *d) { return GTK_FILE_CHOOSER(d); }
static inline GApplication *mp_gapp(GtkApplication *a) { return G_APPLICATION(a); }
static inline GActionMap   *mp_action_map(GtkApplication *a) { return G_ACTION_MAP(a); }
static inline GActionGroup *mp_action_group(GtkApplication *a) { return G_ACTION_GROUP(a); }
static inline GAction      *mp_action(GSimpleAction *a) { return G_ACTION(a); }
static inline GtkScrolledWindow *mp_scrolled_window(GtkWidget *w) { return GTK_SCROLLED_WINDOW(w); }
static inline gboolean mp_is_button(GtkWidget *w) { return GTK_IS_BUTTON(w); }
static inline void mp_accessible_label(GtkWidget *w, const char *label) {
    gtk_accessible_update_property(GTK_ACCESSIBLE(w), GTK_ACCESSIBLE_PROPERTY_LABEL, label, -1);
}
static inline void mp_accessible_description(GtkWidget *w, const char *description) {
    gtk_accessible_update_property(GTK_ACCESSIBLE(w), GTK_ACCESSIBLE_PROPERTY_DESCRIPTION, description, -1);
}
static inline GDBusConnection *mp_dbus_connection(gpointer object) { return G_DBUS_CONNECTION(object); }

/* ---- M1b delivery and setup --------------------------------------------- */

static inline void mp_clipboard_set_text(GtkWidget *owner, const char *text) {
    gdk_clipboard_set_text(gtk_widget_get_clipboard(owner), text);
}

typedef void (*MPClipboardRead)(const char *, gpointer);
typedef struct {
    MPClipboardRead callback;
    gpointer data;
    GDestroyNotify destroy;
} MPClipboardReadBox;

static inline void mp_clipboard_read_box_free(gpointer data) {
    MPClipboardReadBox *box = data;
    if (box->destroy) box->destroy(box->data);
    g_free(box);
}

static inline void mp_clipboard_read_complete(GObject *source, GAsyncResult *result, gpointer data) {
    GTask *task = G_TASK(data);
    GError *error = NULL;
    char *text = gdk_clipboard_read_text_finish(GDK_CLIPBOARD(source), result, &error);
    if (error) {
        g_clear_error(&error);
        g_clear_pointer(&text, g_free);
    }
    g_task_return_pointer(task, text, g_free);
    g_object_unref(task);
}

static inline void mp_clipboard_read_deliver(GObject *source, GAsyncResult *result, gpointer data) {
    GTask *task = G_TASK(result);
    MPClipboardReadBox *box = g_task_get_task_data(task);
    char *text = g_task_propagate_pointer(task, NULL);
    box->callback(text && *text ? text : NULL, box->data);
    g_free(text);
}

/* Call on the owning GTK thread. GTask returns once on its captured
 * thread-default context. The destroy notify releases Swift's callback box. */
static inline void mp_clipboard_read_text_from_clipboard(GdkClipboard *clipboard, MPClipboardRead callback,
                                                        gpointer data, GDestroyNotify destroy) {
    GTask *task = g_task_new(clipboard, NULL, mp_clipboard_read_deliver, NULL);
    MPClipboardReadBox *box = g_new(MPClipboardReadBox, 1);
    *box = (MPClipboardReadBox){callback, data, destroy};
    g_task_set_task_data(task, box, mp_clipboard_read_box_free);
    gdk_clipboard_read_text_async(clipboard, NULL, mp_clipboard_read_complete, task);
}

static inline void mp_clipboard_read_text(GtkWidget *owner, MPClipboardRead callback,
                                          gpointer data, GDestroyNotify destroy) {
    mp_clipboard_read_text_from_clipboard(gtk_widget_get_clipboard(owner), callback, data, destroy);
}

/* Fixed-arity access to the string provider's variadic constructor. Caller owns
 * the reference; set_content takes its own, without first clearing the clipboard. */
static inline GdkContentProvider *mp_clipboard_text_provider(const char *text) {
    return gdk_content_provider_new_typed(G_TYPE_STRING, text);
}

typedef struct {
    MPClipboardReadBox read;
    GInputStream *stream;
    char *buffer;
    gsize limit;
} MPClipboardSnapshotBox;

static inline void mp_clipboard_snapshot_free(gpointer data) {
    MPClipboardSnapshotBox *box = data;
    g_clear_object(&box->stream);
    g_free(box->buffer);
    if (box->read.destroy) box->read.destroy(box->read.data);
    g_free(box);
}

static inline void mp_clipboard_snapshot_deliver(GObject *source, GAsyncResult *result, gpointer data) {
    GTask *task = G_TASK(result);
    MPClipboardSnapshotBox *box = g_task_get_task_data(task);
    char *text = g_task_propagate_pointer(task, NULL);
    /* Unlike the base read, a readable empty string is a valid snapshot. */
    box->read.callback(text, box->read.data);
    g_free(text);
}

static inline void mp_clipboard_snapshot_read_complete(GObject *source, GAsyncResult *result, gpointer data) {
    GTask *task = G_TASK(data);
    MPClipboardSnapshotBox *box = g_task_get_task_data(task);
    GError *error = NULL;
    gsize count = 0;
    gboolean ok = g_input_stream_read_all_finish(G_INPUT_STREAM(source), result, &count, &error);
    /* Positive-length validation also rejects embedded NUL, which a string
     * provider could only republish partially. Never decode truncated UTF-8. */
    if (ok && count <= box->limit && g_utf8_validate(box->buffer, count, NULL)) {
        box->buffer[count] = '\0';
        g_task_return_pointer(task, g_steal_pointer(&box->buffer), g_free);
    } else {
        g_task_return_pointer(task, NULL, NULL);
    }
    g_clear_error(&error);
    g_object_unref(task);
}

static inline void mp_clipboard_snapshot_open_complete(GObject *source, GAsyncResult *result, gpointer data) {
    GTask *task = G_TASK(data);
    MPClipboardSnapshotBox *box = g_task_get_task_data(task);
    GError *error = NULL;
    box->stream = gdk_clipboard_read_finish(GDK_CLIPBOARD(source), result, NULL, &error);
    g_clear_error(&error);
    if (!box->stream || g_cancellable_is_cancelled(g_task_get_cancellable(task))) {
        g_task_return_pointer(task, NULL, NULL);
        g_object_unref(task);
        return;
    }

    /* Read at most limit + 1 bytes before any text allocation/decoding. The
     * extra byte distinguishes exact-limit text from an oversized stream. */
    box->buffer = g_malloc(box->limit + 1);
    g_input_stream_read_all_async(box->stream, box->buffer, box->limit + 1,
                                 G_PRIORITY_DEFAULT, g_task_get_cancellable(task),
                                 mp_clipboard_snapshot_read_complete, task);
}

/* Call under the driver's captured thread-default context. GTask delivers one
 * callback, followed by one destroy notify, including failure/cancellation.
 * The native request retains its cancellable until all I/O callbacks drain. */
static inline void mp_clipboard_snapshot_text(GdkClipboard *clipboard, gsize byte_limit,
                                               GCancellable *cancellable, MPClipboardRead callback,
                                               gpointer data, GDestroyNotify destroy) {
    static const char *mime_types[] = {"text/plain;charset=utf-8", NULL};
    GTask *task = g_task_new(clipboard, cancellable, mp_clipboard_snapshot_deliver, NULL);
    MPClipboardSnapshotBox *box = g_new0(MPClipboardSnapshotBox, 1);
    box->read = (MPClipboardReadBox){callback, data, destroy};
    box->limit = byte_limit;
    g_task_set_task_data(task, box, mp_clipboard_snapshot_free);
    if (byte_limit >= G_MAXSSIZE) {
        g_task_return_pointer(task, NULL, NULL);
        g_object_unref(task);
        return;
    }
    gdk_clipboard_read_async(clipboard, mime_types, G_PRIORITY_DEFAULT, cancellable,
                            mp_clipboard_snapshot_open_complete, task);
}

static inline void mp_notify(GtkApplication *app, const char *title, const char *body) {
    GNotification *notification = g_notification_new(title);
    g_notification_set_body(notification, body);
    /* No buttons or default action: delivery guidance must not take focus. */
    g_application_send_notification(G_APPLICATION(app), "delivery", notification);
    g_object_unref(notification);
}

static inline void mp_entry_set_text(GtkWidget *entry, const char *text) {
    gtk_editable_set_text(GTK_EDITABLE(entry), text);
}

static inline const char *mp_entry_text(GtkWidget *entry) {
    return gtk_editable_get_text(GTK_EDITABLE(entry));
}

/* Parse gsettings output as GVariant, failing closed on malformed lists.
 * Both results transfer ownership to Swift; free with g_strfreev / g_free. */
static inline char **mp_parse_string_array(const char *text) {
    GVariant *value = g_variant_parse(G_VARIANT_TYPE_STRING_ARRAY, text, NULL, NULL, NULL);
    if (!value) return NULL;
    char **strings = g_variant_dup_strv(value, NULL);
    g_variant_unref(value);
    return strings;
}

static inline char *mp_parse_string(const char *text) {
    GVariant *value = g_variant_parse(G_VARIANT_TYPE_STRING, text, NULL, NULL, NULL);
    if (!value) return NULL;
    char *string = g_variant_dup_string(value, NULL);
    g_variant_unref(value);
    return string;
}

/* Swift cannot call GApplicationCommandLine's variadic print functions. */
static inline void mp_command_line_print(GApplicationCommandLine *command, const char *text) {
    g_application_command_line_print(command, "%s\n", text);
}

/* Portal window identities, with runtime backend checks. */
static inline char *mp_portal_x11_parent(GtkWindow *window) {
    GdkSurface *surface = gtk_native_get_surface(GTK_NATIVE(window));
#ifdef GDK_WINDOWING_X11
    if (surface && GDK_IS_X11_SURFACE(surface))
        return g_strdup_printf("x11:%lx", (unsigned long)gdk_x11_surface_get_xid(surface));
#endif
    return NULL;
}

typedef void (*MPPortalExported)(GdkToplevel *, const char *, gpointer);
static inline GdkSurface *mp_portal_export(GtkWindow *window, MPPortalExported callback,
                                           gpointer data, GDestroyNotify destroy) {
    GdkSurface *surface = gtk_native_get_surface(GTK_NATIVE(window));
#ifdef GDK_WINDOWING_WAYLAND
    if (surface && GDK_IS_WAYLAND_TOPLEVEL(surface) &&
        gdk_wayland_toplevel_export_handle(GDK_TOPLEVEL(surface), callback, data, destroy))
        return g_object_ref(surface);
#endif
    return NULL;
}

static inline void mp_portal_unexport(GdkSurface *surface) {
#ifdef GDK_WINDOWING_WAYLAND
    if (GDK_IS_WAYLAND_TOPLEVEL(surface))
        gdk_wayland_toplevel_unexport_handle(GDK_TOPLEVEL(surface));
#endif
}

/* ---- Signals (g_signal_connect is a macro; G_CALLBACK is another) ---------- */

/* GTK-thread-only, with no serializer: row identities stay in this process.
 * Look up the shared name because this header is imported by multiple modules. */
static inline GType mp_library_row_type(void) {
    GType type = g_type_from_name("MonkeysPawLibraryRow");
    if (!type)
        type = g_boxed_type_register_static("MonkeysPawLibraryRow", (GBoxedCopyFunc)g_strdup, g_free);
    return type;
}
static inline GdkContentProvider *mp_library_row_provider(const char *payload) {
    return gdk_content_provider_new_typed(mp_library_row_type(), payload);
}
static inline const char *mp_library_row_string(const GValue *value) {
    return G_VALUE_HOLDS(value, mp_library_row_type()) ? g_value_get_boxed(value) : NULL;
}

static inline GType mp_string_type(void) { return G_TYPE_STRING; }
static inline GtkEventController *mp_drag_source_controller(GtkDragSource *source) {
    return GTK_EVENT_CONTROLLER(source);
}

static inline gulong mp_connect(gpointer instance,
                                const char *signal,
                                GCallback handler,
                                gpointer user_data,
                                GClosureNotify destroy) {
    return g_signal_connect_data(instance, signal, handler, user_data, destroy, (GConnectFlags)0);
}

/* Test bridges for C variadics. Keys enter the installed capture controller,
 * including its Swift trampoline, rather than calling panel intents directly. */
static inline void mp_test_emit_preedit_changed(GtkWidget *w, const char *text) {
    g_signal_emit_by_name(w, "preedit-changed", text);
}

static inline void mp_test_emit_native_response(GtkFileChooserNative *dialog, gint response) {
    g_signal_emit_by_name(dialog, "response", response);
}

static inline gboolean mp_test_emit_key_pressed(GtkWidget *w, guint key, GdkModifierType modifiers) {
    GListModel *controllers = gtk_widget_observe_controllers(w);
    gboolean handled = FALSE;
    for (guint i = 0; i < g_list_model_get_n_items(controllers); i++) {
        GtkEventController *controller = g_list_model_get_item(controllers, i);
        if (GTK_IS_EVENT_CONTROLLER_KEY(controller) &&
            gtk_event_controller_get_propagation_phase(controller) == GTK_PHASE_CAPTURE) {
            g_signal_emit_by_name(controller, "key-pressed", key, 0, modifiers, &handled);
            g_object_unref(controller);
            break;
        }
        g_object_unref(controller);
    }
    g_object_unref(controllers);
    return handled;
}

/* GFileMonitor is non-recursive; the driver attaches one per directory.
 * Request move pairs, and leave all debounce policy to Core's Scheduler. */
static inline GFileMonitor *mp_monitor_directory(const char *path, GError **error) {
    GFile *file = g_file_new_for_path(path);
    GFileMonitor *monitor = g_file_monitor_directory(file, G_FILE_MONITOR_WATCH_MOVES, NULL, error);
    g_object_unref(file);
    if (monitor) g_file_monitor_set_rate_limit(monitor, 0);
    return monitor;
}

/* Run after default-priority monitor events, ahead of GTK resize/redraw work
 * so a busy frame clock cannot starve the scan and consume the picker budget.
 * The destroy notify releases its callback context on completion or removal. */
static inline guint mp_rescan_idle(GSourceFunc rescan, gpointer data, GDestroyNotify destroy) {
    GSource *source = g_idle_source_new();
    g_source_set_priority(source, G_PRIORITY_HIGH_IDLE);
    g_source_set_callback(source, rescan, data, destroy);
    GMainContext *context = g_main_context_ref_thread_default();
    guint id = g_source_attach(source, context);
    g_main_context_unref(context);
    g_source_unref(source);
    return id;
}

/* ---- Version forks ------------------------------------------------------- */

/*
 * gtk_css_provider_load_from_string() arrived in 4.12, deprecating
 * load_from_data(). Both are in scope here; Swift can see neither version.
 */
static inline void mp_css_load(GtkCssProvider *provider, const char *css) {
#if GTK_CHECK_VERSION(4, 12, 0)
    gtk_css_provider_load_from_string(provider, css);
#else
    gtk_css_provider_load_from_data(provider, css, -1);
#endif
}

/* GTK_STYLE_PROVIDER_PRIORITY_APPLICATION is a macro constant. */
static inline void mp_add_style_provider(GdkDisplay *display, GtkCssProvider *provider) {
    gtk_style_context_add_provider_for_display(display, GTK_STYLE_PROVIDER(provider),
                                               GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
}

/* G_APPLICATION_DEFAULT_FLAGS is GLib 2.74+; FLAGS_NONE before that. */
static inline GApplicationFlags mp_app_default_flags(void) {
#if GLIB_CHECK_VERSION(2, 74, 0)
    return G_APPLICATION_DEFAULT_FLAGS;
#else
    return G_APPLICATION_FLAGS_NONE;
#endif
}

#endif
