#if os(Linux)
import CGtk
import Foundation
import MonkeysPawCore
import XCTest
@testable import MonkeysPawLinux

enum GTKTestSupport {
    // GTK initialization is one-shot even when opening the display fails.
    // Rechecking can report initialized with no display and crash widget creation.
    private static let hasDisplay: Bool = {
        // Use GTK's local test context so accessibility assertions inspect
        // real properties without requiring the host's AT-SPI service.
        g_setenv("GTK_A11Y", "test", 1)
        return gtk_init_check() != 0 && gdk_display_get_default() != nil
    }()

    static func requireDisplay() throws {
        guard hasDisplay else {
            if ProcessInfo.processInfo.environment["MONKEYSPAW_REQUIRE_DISPLAY"] == "1" {
                XCTFail("A working GTK display is required.")
                throw NSError(domain: "GTKTestSupport", code: 1)
            }
            throw XCTSkip("Requires a GTK display such as Xvfb.")
        }
    }

    private static var applicationCount = 0

    static func application() throws -> UnsafeMutablePointer<GtkApplication> {
        try requireDisplay()

        // GLib exports every NULL-id application at /org/gtk/Application/anonymous.
        // Test apps outlive their test, so a shared path fails the next register
        // on a session bus (CI's dbus-run-session). Unique ids keep paths distinct.
        applicationCount += 1
        let id = "\(AppIdentity.linuxAppID).tests.app\(applicationCount)"
        let application = try XCTUnwrap(gtk_application_new(id, G_APPLICATION_NON_UNIQUE))

        var error: UnsafeMutablePointer<GError>?
        guard g_application_register(mp_gapp(application), nil, &error) != 0 else {
            let message = error.map { String(cString: $0.pointee.message) } ?? "unknown error"
            g_clear_error(&error)
            g_object_unref(application)
            XCTFail("Could not register test application \(id): \(message)")
            throw NSError(domain: "GTKTestSupport", code: 2)
        }
        return application
    }

    static func destroy(_ application: UnsafeMutablePointer<GtkApplication>) {
        while let windows = gtk_application_get_windows(application), let data = windows.pointee.data {
            gtk_window_destroy(data.assumingMemoryBound(to: GtkWindow.self))
        }
        g_object_unref(application)
    }

    /// Overflow items must be mapped before GtkButton's timed activation.
    /// Exercise the visible menu instead of activating an unmapped child.
    static func activate(_ widget: GTK.Widget) -> gboolean {
        if let popover = gtk_widget_get_ancestor(widget, gtk_popover_get_type()),
           let window = gtk_widget_get_ancestor(widget, gtk_window_get_type()),
           gtk_widget_get_visible(window) != 0 {
            gtk_popover_popup(mp_popover(popover))
            XCTAssertTrue(spin { gtk_widget_get_mapped(widget) != 0 })
        }
        return gtk_widget_activate(widget)
    }

    static func selectAssistantTab(in window: GTK.Widget) throws {
        let stack = try settingsWidget("settings-stack", in: window)
        let page = try settingsWidget("settings-assistant-page", in: window)
        XCTAssertNotNil(gtk_stack_get_page(mp_stack(stack), page), "Assistant page is missing from the Settings stack")
        gtk_stack_set_visible_child(mp_stack(stack), page)
    }

    /// First descendant that can take keyboard focus, for focus-move assertions.
    static func firstFocusable(_ widget: GTK.Widget) -> GTK.Widget? {
        // can-focus permits focus within a subtree; focusable identifies a
        // widget that can receive it, rather than a switcher container.
        if gtk_widget_get_focusable(widget) != 0, gtk_widget_is_sensitive(widget) != 0,
           gtk_widget_get_mapped(widget) != 0 { return widget }
        var child = gtk_widget_get_first_child(widget)
        while let current = child {
            if let found = firstFocusable(current) { return found }
            child = gtk_widget_get_next_sibling(current)
        }
        return nil
    }

    static func spin(until predicate: () -> Bool, timeout: Duration = .seconds(3)) -> Bool {
        let deadline = ContinuousClock().now.advanced(by: timeout)
        while !predicate(), ContinuousClock().now < deadline {
            // Bound iteration too: a repeating idle must not trap this test loop.
            _ = g_main_context_iteration(nil, 0)
            Thread.sleep(forTimeInterval: 0.005)
        }
        return predicate()
    }
}
#endif
