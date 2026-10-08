#if os(Linux)
import CGtk
import Foundation
import MonkeysPawCore
import XCTest
@testable import MonkeysPawLinux

final class LinuxPanelLifecycleTests: XCTestCase {
    func testFirstInteractiveLaunchShowsSetupOnce() throws {
        let application = try GTKTestSupport.application()
        defer { GTKTestSupport.destroy(application) }
        let tools = try FakeLinuxTools()
        let environment = LinuxEnvironment(application: application, environment: [
            "PATH": tools.directory.path, "XDG_CONFIG_HOME": tools.directory.path,
        ])
        environment.presentFromLauncher()
        XCTAssertTrue(GTKTestSupport.spin {
            guard let window = gtk_application_get_active_window(application),
                  let title = gtk_window_get_title(window) else { return false }
            return String(cString: title) == LinuxStrings.setup
                && gtk_widget_get_visible(mp_window_widget(window)) != 0
        })
        let first = try XCTUnwrap(gtk_application_get_active_window(application))
        XCTAssertEqual(String(cString: gtk_window_get_title(first)), LinuxStrings.setup)
        XCTAssertTrue(FileManager.default.fileExists(atPath:
            tools.directory.appendingPathComponent("monkeyspaw/setup-shown").path))
        gtk_window_close(first)
        environment.presentFromLauncher()
        XCTAssertTrue(GTKTestSupport.spin {
            guard let window = gtk_application_get_active_window(application),
                  let title = gtk_window_get_title(window) else { return false }
            return String(cString: title) == AppIdentity.displayName
                && gtk_widget_get_visible(mp_window_widget(window)) != 0
        })
    }

    func testSelfTestFieldStartsEmptyAndCanBeReused() throws {
        let application = try GTKTestSupport.application()
        defer { GTKTestSupport.destroy(application) }
        let target = GTKSelfTestTarget(application: application)
        target.present(fieldExpecting: DeliveryStrings.testPrompt)
        XCTAssertEqual(target.readBack(), "")

        let window = try XCTUnwrap(gtk_application_get_active_window(application))
        let entry = try XCTUnwrap(gtk_window_get_child(window))
        mp_entry_set_text(entry, DeliveryStrings.testPrompt)
        XCTAssertEqual(target.readBack(), DeliveryStrings.testPrompt)

        target.close()
        XCTAssertEqual(gtk_widget_get_visible(mp_window_widget(window)), 0)
        gtk_window_close(window)
        target.present(fieldExpecting: DeliveryStrings.testPrompt)
        XCTAssertEqual(target.readBack(), "")
        XCTAssertEqual(gtk_window_get_application(window), application)
    }

    func testSetupRowsAndFixUseThePresentationModel() throws {
        let application = try GTKTestSupport.application()
        defer { GTKTestSupport.destroy(application) }
        let environment = LinuxEnvironment(application: application, environment: [
            "PATH": "/nonexistent", "XDG_CURRENT_DESKTOP": "KDE", "XDG_SESSION_TYPE": "wayland",
        ])
        let model = environment.setupModel
        XCTAssertTrue(GTKTestSupport.spin { model.session != nil })
        XCTAssertEqual(model.rows.first { $0.kind == .accessibility }?.status, .notApplicable)
        XCTAssertEqual(model.rows.first { $0.kind == .portal }?.status, .unknown)
        XCTAssertEqual(model.rows.first { $0.kind == .hotkey }?.registration?.mechanism, .manual)
        XCTAssertEqual(model.rows.first { $0.kind == .ydotool }?.status, .needsAction(fix: LinuxStrings.ydotoolMissing))
        XCTAssertEqual(model.rows.first { $0.kind == .kde }?.status,
                       .needsAction(fix: SetupStrings.kdeShortcut + " (Added in M1d)"))

        model.fix(.hotkey)
        XCTAssertTrue(GTKTestSupport.spin {
            guard let window = gtk_application_get_active_window(application),
                  let title = gtk_window_get_title(window) else { return false }
            return String(cString: title) == LinuxStrings.setup
                && gtk_widget_get_visible(mp_window_widget(window)) != 0
        })
        let window = try XCTUnwrap(gtk_application_get_active_window(application))
        let view = try XCTUnwrap(gtk_window_get_child(window))
        let buffer = gtk_text_view_get_buffer(mp_text_view(view))
        var start = GtkTextIter()
        var end = GtkTextIter()
        gtk_text_buffer_get_bounds(buffer, &start, &end)
        let raw = try XCTUnwrap(gtk_text_buffer_get_text(buffer, &start, &end, 0))
        defer { g_free(raw) }
        XCTAssertEqual(String(cString: raw), GnomeKeybindingInstaller.command)
    }

    func testNativeCloseKeepsThePanelAvailableForTheShortcut() throws {
        try GTKTestSupport.requireDisplay()

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

            panel.show()
            XCTAssertNotEqual(gtk_widget_get_visible(widget), 0)
            XCTAssertEqual(gtk_application_get_active_window(application), window)
            XCTAssertTrue(environment.panel === panel)
        }
    }
}
#endif
