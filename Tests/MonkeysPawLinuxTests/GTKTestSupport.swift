#if os(Linux)
import CGtk
import Foundation
import XCTest

enum GTKTestSupport {
    // GTK initialization is one-shot even when opening the display fails.
    // Rechecking can report initialized with no display and crash widget creation.
    private static let hasDisplay = gtk_init_check() != 0 && gdk_display_get_default() != nil

    static func requireDisplay() throws {
        guard hasDisplay else {
            if ProcessInfo.processInfo.environment["MONKEYSPAW_REQUIRE_DISPLAY"] == "1" {
                XCTFail("A working GTK display is required.")
                throw NSError(domain: "GTKTestSupport", code: 1)
            }
            throw XCTSkip("Requires a GTK display such as Xvfb.")
        }
    }

    static func application() throws -> UnsafeMutablePointer<GtkApplication> {
        try requireDisplay()
        let application = try XCTUnwrap(gtk_application_new(nil, G_APPLICATION_NON_UNIQUE))
        guard g_application_register(mp_gapp(application), nil, nil) != 0 else {
            g_object_unref(application)
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
