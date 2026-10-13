#if os(Linux)
import CGtk
import Foundation
import XCTest
@testable import MonkeysPawLinux

final class LinuxImportChooserTests: XCTestCase {
    func testNativeFileChooserHasMultipleSelectionAndSupportedExtensionFilter() throws {
        let application = try GTKTestSupport.application()
        defer { GTKTestSupport.destroy(application) }
        let parent = try XCTUnwrap(gtk_application_window_new(application))
        let tools = try FakeLinuxTools()
        let url = tools.directory.appendingPathComponent("chosen.md")
        try Data("Selected".utf8).write(to: url)
        var native: OpaquePointer?
        let chooser = GTKImportChooser(showDialog: { native = $0 })
        var results: [[URL]] = []
        chooser.choose(parent: parent, mode: .files) { results.append($0) }
        let dialog = try XCTUnwrap(native)
        g_object_ref(UnsafeMutableRawPointer(dialog))
        defer { g_object_unref(UnsafeMutableRawPointer(dialog)) }
        XCTAssertEqual(gtk_native_dialog_get_modal(mp_native_dialog(dialog)), 1)
        XCTAssertEqual(gtk_native_dialog_get_transient_for(mp_native_dialog(dialog)), mp_window(parent))
        XCTAssertEqual(gtk_file_chooser_get_action(mp_file_chooser(dialog)), GTK_FILE_CHOOSER_ACTION_OPEN)
        XCTAssertEqual(gtk_file_chooser_get_select_multiple(mp_file_chooser(dialog)), 1)
        let filter = try XCTUnwrap(gtk_file_chooser_get_filter(mp_file_chooser(dialog)))
        let serialized = try XCTUnwrap(gtk_file_filter_to_gvariant(filter))
        defer { g_variant_unref(serialized) }
        let text = try XCTUnwrap(g_variant_print(serialized, 0))
        defer { g_free(text) }
        for pattern in ["*.md", "*.prompt", "*.prompty"] { XCTAssertTrue(String(cString: text).contains(pattern)) }
        try select(url, in: dialog)
        mp_test_emit_native_response(dialog, GTK_RESPONSE_ACCEPT.rawValue)
        XCTAssertEqual(results, [[url]])
        mp_test_emit_native_response(dialog, GTK_RESPONSE_ACCEPT.rawValue)
        XCTAssertEqual(results.count, 1)
    }

    func testNativeFolderChooserActuallyAcceptsFolderAndRetiresOldResponses() throws {
        let application = try GTKTestSupport.application()
        defer { GTKTestSupport.destroy(application) }
        let parent = try XCTUnwrap(gtk_application_window_new(application))
        let tools = try FakeLinuxTools()
        var dialogs: [OpaquePointer] = []
        let chooser = GTKImportChooser(showDialog: {
            g_object_ref(UnsafeMutableRawPointer($0))
            dialogs.append($0)
        })
        defer { dialogs.forEach { g_object_unref(UnsafeMutableRawPointer($0)) } }
        var results: [[URL]] = []
        chooser.choose(parent: parent, mode: .files) { results.append($0) }
        chooser.choose(parent: parent, mode: .folder) { results.append($0) }
        let dialog = try XCTUnwrap(dialogs.last)
        XCTAssertEqual(gtk_file_chooser_get_action(mp_file_chooser(dialog)), GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER)
        XCTAssertEqual(gtk_file_chooser_get_select_multiple(mp_file_chooser(dialog)), 0)
        XCTAssertEqual(gtk_file_chooser_get_create_folders(mp_file_chooser(dialog)), 0)
        try select(tools.directory, in: dialog)
        mp_test_emit_native_response(dialogs[0], GTK_RESPONSE_ACCEPT.rawValue)
        XCTAssertTrue(results.isEmpty)
        mp_test_emit_native_response(dialog, GTK_RESPONSE_ACCEPT.rawValue)
        XCTAssertEqual(results, [[tools.directory]])
        chooser.choose(parent: parent, mode: .files) { results.append($0) }
        mp_test_emit_native_response(try XCTUnwrap(dialogs.last), GTK_RESPONSE_CANCEL.rawValue)
        XCTAssertEqual(results.last, [])
    }

    private func select(_ url: URL, in dialog: OpaquePointer) throws {
        let file = try XCTUnwrap(g_file_new_for_path(url.path))
        defer { g_object_unref(UnsafeMutableRawPointer(file)) }
        var error: UnsafeMutablePointer<GError>?
        XCTAssertNotEqual(gtk_file_chooser_set_file(mp_file_chooser(dialog), file, &error), 0)
        if let error { g_error_free(error) }
        XCTAssertTrue(GTKTestSupport.spin {
            guard let selected = gtk_file_chooser_get_file(mp_file_chooser(dialog)) else { return false }
            defer { g_object_unref(UnsafeMutableRawPointer(selected)) }
            return g_file_equal(file, selected) != 0
        })
    }
}
#endif
