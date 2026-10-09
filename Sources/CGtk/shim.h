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
static inline GtkTextView  *mp_text_view(GtkWidget *w) { return GTK_TEXT_VIEW(w); }
static inline GApplication *mp_gapp(GtkApplication *a) { return G_APPLICATION(a); }
static inline GActionMap   *mp_action_map(GtkApplication *a) { return G_ACTION_MAP(a); }
static inline GActionGroup *mp_action_group(GtkApplication *a) { return G_ACTION_GROUP(a); }
static inline GAction      *mp_action(GSimpleAction *a) { return G_ACTION(a); }
static inline GtkScrolledWindow *mp_scrolled_window(GtkWidget *w) { return GTK_SCROLLED_WINDOW(w); }
static inline gboolean mp_is_button(GtkWidget *w) { return GTK_IS_BUTTON(w); }
static inline GDBusConnection *mp_dbus_connection(gpointer object) { return G_DBUS_CONNECTION(object); }

/* ---- M1b delivery and setup --------------------------------------------- */

static inline void mp_clipboard_set_text(GtkWidget *owner, const char *text) {
    gdk_clipboard_set_text(gtk_widget_get_clipboard(owner), text);
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

static inline gulong mp_connect(gpointer instance,
                                const char *signal,
                                GCallback handler,
                                gpointer user_data,
                                GClosureNotify destroy) {
    return g_signal_connect_data(instance, signal, handler, user_data, destroy, (GConnectFlags)0);
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
