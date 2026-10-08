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

/* ---- Upcasts (the GTK_*() / G_*() macros) ---------------------------------- */

static inline GtkWindow    *mp_window(GtkWidget *w)    { return GTK_WINDOW(w); }
static inline GtkWidget    *mp_window_widget(GtkWindow *w) { return GTK_WIDGET(w); }
static inline GtkBox       *mp_box(GtkWidget *w)       { return GTK_BOX(w); }
static inline GtkLabel     *mp_label(GtkWidget *w)     { return GTK_LABEL(w); }
static inline GtkEntry     *mp_entry(GtkWidget *w)     { return GTK_ENTRY(w); }
static inline GtkTextView  *mp_text_view(GtkWidget *w) { return GTK_TEXT_VIEW(w); }
static inline GApplication *mp_gapp(GtkApplication *a) { return G_APPLICATION(a); }
static inline GActionMap   *mp_action_map(GtkApplication *a) { return G_ACTION_MAP(a); }
static inline GActionGroup *mp_action_group(GtkApplication *a) { return G_ACTION_GROUP(a); }
static inline GAction      *mp_action(GSimpleAction *a) { return G_ACTION(a); }

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
