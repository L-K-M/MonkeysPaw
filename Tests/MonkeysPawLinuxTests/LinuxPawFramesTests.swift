#if os(Linux)
import CGtk
import Foundation
import MonkeysPawCore
import XCTest
@testable import MonkeysPawLinux

final class LinuxPawFramesTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    func testXDGDirectoriesPrecedeSourceAndLoadLazilyOnce() throws {
        let first = directory.appendingPathComponent("first")
        let second = directory.appendingPathComponent("second")
        let frames = LinuxPawFrames(environment: ["XDG_DATA_DIRS": first.path + ":" + second.path])
        // The resource directories arrive after construction, before first use.
        try writeFrames(in: first, red: 1)
        try writeFrames(in: second, red: 0)
        let image = try XCTUnwrap(frames.image(0))
        let pixels = try XCTUnwrap(cairo_image_surface_get_data(image))
        XCTAssertEqual(UnsafeRawPointer(pixels).load(as: UInt32.self), 0xFFFF0000)
        try FileManager.default.removeItem(at: first)
        XCTAssertEqual(frames.image(0), image)
        XCTAssertNotNil(frames.image(PawTake.imageCount - 1))
        XCTAssertNil(frames.image(-1))
        XCTAssertNil(frames.image(PawTake.imageCount))
    }

    func testUnsetAndEmptyXDGDirectoriesUseStandardDefaults() {
        for environment in [[:], ["XDG_DATA_DIRS": ""]] {
            let frames = LinuxPawFrames(environment: environment)
            XCTAssertEqual(frames.directories.prefix(2).map(\.path), [
                "/usr/local/share/monkeyspaw/wish-paw",
                "/usr/share/monkeyspaw/wish-paw",
            ])
        }
    }

    func testSearchContinuesToNextXDGDirectory() throws {
        let absent = directory.appendingPathComponent("absent")
        let present = directory.appendingPathComponent("present")
        try writeFrames(in: present, red: 1)
        let frames = LinuxPawFrames(environment: ["XDG_DATA_DIRS": absent.path + ":" + present.path])
        let image = try XCTUnwrap(frames.image(0))
        let pixels = try XCTUnwrap(cairo_image_surface_get_data(image))
        XCTAssertEqual(UnsafeRawPointer(pixels).load(as: UInt32.self), 0xFFFF0000)
    }

    func testSourceTreeContainsAllRealFrames() throws {
        let frames = LinuxPawFrames(environment: ["XDG_DATA_DIRS": directory.path])
        for index in 0..<PawTake.imageCount {
            let image = try XCTUnwrap(frames.image(index))
            XCTAssertEqual(cairo_surface_status(image), CAIRO_STATUS_SUCCESS)
            XCTAssertEqual(cairo_image_surface_get_width(image), Int32(PawTake.imageSize.x * 2))
            XCTAssertEqual(cairo_image_surface_get_height(image), Int32(PawTake.imageSize.y * 2))
        }
    }

    func testMissingCorruptOrWrongSizeFrameDisablesWholeSet() throws {
        for defect in ["missing", "corrupt", "width", "height"] {
            let data = directory.appendingPathComponent(defect)
            try writeFrames(in: data, red: 1)
            let url = frameURL(in: data, index: PawTake.imageCount - 1)
            switch defect {
            case "missing": try FileManager.default.removeItem(at: url)
            case "corrupt": try Data("not a PNG".utf8).write(to: url)
            case "width": try writeImage(to: url, width: 1, height: 820, red: 1)
            default: try writeImage(to: url, width: 720, height: 1, red: 1)
            }
            let frames = LinuxPawFrames(environment: ["XDG_DATA_DIRS": data.path])
            for index in 0..<PawTake.imageCount { XCTAssertNil(frames.image(index), defect) }
        }
    }

    func testDeinitReleasesSurfaces() throws {
        var frames: LinuxPawFrames? = LinuxPawFrames(environment: ["XDG_DATA_DIRS": directory.path])
        let image = try XCTUnwrap(frames?.image(0))
        cairo_surface_reference(image)
        defer { cairo_surface_destroy(image) }
        XCTAssertEqual(cairo_surface_get_reference_count(image), 2)
        frames = nil
        XCTAssertEqual(cairo_surface_get_reference_count(image), 1)
    }

    private func frameURL(in data: URL, index: Int) -> URL {
        data.appendingPathComponent("monkeyspaw/wish-paw/" + PawTake.imageName(index) + "@2x.png")
    }

    private func writeFrames(in data: URL, red: Double) throws {
        try FileManager.default.createDirectory(at: data.appendingPathComponent("monkeyspaw/wish-paw"),
                                                withIntermediateDirectories: true)
        for index in 0..<PawTake.imageCount {
            try writeImage(to: frameURL(in: data, index: index), width: 720, height: 820, red: red)
        }
    }

    private func writeImage(to url: URL, width: Int32, height: Int32, red: Double) throws {
        let image = try XCTUnwrap(cairo_image_surface_create(CAIRO_FORMAT_ARGB32, width, height))
        defer { cairo_surface_destroy(image) }
        let context = try XCTUnwrap(cairo_create(image))
        defer { cairo_destroy(context) }
        cairo_set_source_rgb(context, red, 0, 0)
        cairo_paint(context)
        XCTAssertEqual(cairo_surface_write_to_png(image, url.path), CAIRO_STATUS_SUCCESS)
    }
}
#endif
