#if os(Linux)
import CGtk
import Foundation
import XCTest
@testable import MonkeysPawLinux

final class GTKFolderChooserTests: XCTestCase {
    func testNativeChooserConfiguresFolderModeAndForwardsGTKResponseWithoutShowingDialog() throws {
        let application = try GTKTestSupport.application()
        defer { GTKTestSupport.destroy(application) }
        let parent = try XCTUnwrap(gtk_application_window_new(application))
        let tools = try FakeLinuxTools()
        var native: OpaquePointer?
        let chooser = GTKFolderChooser(showDialog: { native = $0 })
        var paths: [String?] = []
        chooser.chooseFolder(parent: parent, currentPath: tools.directory.path) { paths.append($0) }
        let dialog = try XCTUnwrap(native)
        // Hold a test ref so the old signal can be emitted after driver teardown.
        g_object_ref(UnsafeMutableRawPointer(dialog))
        defer { g_object_unref(UnsafeMutableRawPointer(dialog)) }
        XCTAssertEqual(gtk_native_dialog_get_visible(mp_native_dialog(dialog)), 0)
        XCTAssertEqual(gtk_native_dialog_get_transient_for(mp_native_dialog(dialog)), mp_window(parent))
        XCTAssertEqual(gtk_native_dialog_get_modal(mp_native_dialog(dialog)), 1)
        XCTAssertEqual(gtk_file_chooser_get_action(mp_file_chooser(dialog)), GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER)
        XCTAssertEqual(gtk_file_chooser_get_select_multiple(mp_file_chooser(dialog)), 0)
        // An unshown native chooser has not applied its pending initial-folder
        // request. Check the response bridge against GTK's actual current file.
        XCTAssertTrue(GTKTestSupport.spin {
            guard let file = gtk_file_chooser_get_file(mp_file_chooser(dialog)) else { return false }
            g_object_unref(UnsafeMutableRawPointer(file))
            return true
        })
        let file = try XCTUnwrap(gtk_file_chooser_get_file(mp_file_chooser(dialog)))
        defer { g_object_unref(UnsafeMutableRawPointer(file)) }
        let path = try XCTUnwrap(g_file_get_path(file))
        defer { g_free(path) }
        mp_test_emit_native_response(dialog, GTK_RESPONSE_ACCEPT.rawValue)
        XCTAssertEqual(paths.count, 1)
        XCTAssertEqual(paths.first, .some(String(cString: path)))
        mp_test_emit_native_response(dialog, GTK_RESPONSE_ACCEPT.rawValue)
        XCTAssertEqual(paths.count, 1)
    }

    func testNativeChooserCancelRejectsOldResponsesAfterASecondRequest() throws {
        let application = try GTKTestSupport.application()
        defer { GTKTestSupport.destroy(application) }
        let parent = try XCTUnwrap(gtk_application_window_new(application))
        let tools = try FakeLinuxTools()
        var dialogs: [OpaquePointer] = []
        let chooser = GTKFolderChooser(showDialog: { dialog in
            g_object_ref(UnsafeMutableRawPointer(dialog))
            dialogs.append(dialog)
        })
        defer { dialogs.forEach { g_object_unref(UnsafeMutableRawPointer($0)) } }
        var firstCompletions = 0
        chooser.chooseFolder(parent: parent, currentPath: tools.directory.path) { _ in firstCompletions += 1 }
        chooser.cancel()
        var responses: [String?] = []
        chooser.chooseFolder(parent: parent, currentPath: tools.directory.path) { responses.append($0) }
        XCTAssertEqual(dialogs.count, 2)
        mp_test_emit_native_response(dialogs[0], GTK_RESPONSE_ACCEPT.rawValue)
        XCTAssertEqual(firstCompletions, 0)
        XCTAssertTrue(responses.isEmpty)
        mp_test_emit_native_response(dialogs[1], GTK_RESPONSE_CANCEL.rawValue)
        XCTAssertEqual(responses.count, 1)
        XCTAssertNil(responses[0])
        chooser.cancel()
    }
}
#endif
