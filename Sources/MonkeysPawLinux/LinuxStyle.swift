#if os(Linux)
import CGtk

/// Application-priority CSS for native chrome and GTK 4.8 list groups. One
/// provider is installed per display; every window on it shares the rules.
enum LinuxStyle {
    private static var installedDisplays: [OpaquePointer] = []

    static func install(on widget: GTK.Widget) {
        guard let display = gtk_widget_get_display(widget),
              !installedDisplays.contains(display) else { return }
        installedDisplays.append(display)
        let provider = gtk_css_provider_new()!
        mp_css_load(provider, css)
        // The display holds the provider for its own lifetime.
        mp_add_style_provider(display, provider)
        g_object_unref(UnsafeMutableRawPointer(provider))
    }

    // @borders is the theme's named border color; a theme missing it keeps
    // the alpha() fallback declared first.
    private static let css = """
        window.mp-picker {
            border-radius: 12px;
            background-color: @theme_bg_color;
            border: 1px solid alpha(currentColor, .2);
            border: 1px solid @borders;
        }
        .mp-picker-search {
            font-size: larger;
        }
        .caption, .subtitle {
            font-size: smaller;
        }
        .heading, .title {
            font-weight: bold;
        }
        .mp-inspector-switcher button, .mp-settings-switcher button {
            min-width: 0;
            padding-left: 10px;
            padding-right: 10px;
        }
        list.boxed-list {
            border: 1px solid alpha(currentColor, .16);
            border-radius: 8px;
            background-color: @theme_base_color;
        }
        list.boxed-list > row {
            padding: 0;
            border-bottom: 1px solid alpha(currentColor, .12);
        }
        list.boxed-list > row:last-child {
            border-bottom: none;
        }
        """
}
#endif
