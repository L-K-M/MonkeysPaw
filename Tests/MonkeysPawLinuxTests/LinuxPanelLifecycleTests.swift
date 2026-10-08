#if os(Linux)
import CGtk
import Foundation
import MonkeysPawCore
import XCTest
@testable import MonkeysPawLinux

final class LinuxPanelLifecycleTests: XCTestCase {
    func testNativeCloseKeepsThePanelAvailableForTheShortcut() throws {
        guard gtk_init_check() != 0 else {
            if ProcessInfo.processInfo.environment["MONKEYSPAW_REQUIRE_DISPLAY"] == "1" {
                XCTFail("The GTK smoke test requires a working display.")
                return
            }

            throw XCTSkip("Requires a GTK display, such as Xvfb. "
                + "Set MONKEYSPAW_REQUIRE_DISPLAY=1 to fail instead of skipping.")
        }

        let application = try XCTUnwrap(gtk_application_new(nil, G_APPLICATION_NON_UNIQUE))
        defer { g_object_unref(application) }

        guard g_application_register(mp_gapp(application), nil, nil) != 0 else {
            XCTFail("Could not register the isolated test application.")
            return
        }

        let environment = LinuxEnvironment(application: application)
        let panel = environment.panel
        panel.show()

        let window = try XCTUnwrap(gtk_application_get_active_window(application))
        let widget = try XCTUnwrap(mp_window_widget(window))
        // Hold the object through a failing baseline's destruction, so assertions
        // detect lost application ownership instead of dereferencing freed memory.
        _ = g_object_ref(window)
        defer {
            gtk_window_destroy(window)
            g_object_unref(window)
        }

        XCTAssertEqual(String(cString: try XCTUnwrap(gtk_window_get_title(window))), AppIdentity.displayName)
        var width: Int32 = 0
        var height: Int32 = 0
        gtk_window_get_default_size(window, &width, &height)
        XCTAssertEqual(Int(width), Limits.panelSize.width)
        XCTAssertEqual(Int(height), Limits.panelSize.height)

        for _ in 0..<2 {
            XCTAssertNotEqual(gtk_widget_get_visible(widget), 0)
            gtk_window_close(window)

            XCTAssertEqual(gtk_widget_get_visible(widget), 0)
            XCTAssertEqual(gtk_window_get_application(window), application)
            guard gtk_window_get_application(window) == application else { return }

            panel.toggle()
            XCTAssertNotEqual(gtk_widget_get_visible(widget), 0)
            XCTAssertEqual(gtk_application_get_active_window(application), window)
            XCTAssertTrue(environment.panel === panel)
        }
    }
}
#endif
