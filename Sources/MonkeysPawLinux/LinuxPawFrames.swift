#if os(Linux)
import CGtk
import Foundation
import MonkeysPawCore

/// Loads one complete set of @2x exposures on first use, on the GTK thread.
/// An incomplete installed set stays invisible rather than mixing takes.
final class LinuxPawFrames {
    let directories: [URL]
    private var loaded = false
    private var images: [OpaquePointer] = []

    init(environment: [String: String] = [:]) {
        let dataDirs = environment["XDG_DATA_DIRS"].flatMap { $0.isEmpty ? nil : $0 }
            ?? "/usr/local/share:/usr/share"
        directories = dataDirs.split(separator: ":").map {
            URL(fileURLWithPath: String($0), isDirectory: true)
                .appendingPathComponent("monkeyspaw/wish-paw", isDirectory: true)
        } + [URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MonkeysPaw/Resources/WishPaw", isDirectory: true)]
    }

    deinit {
        for image in images { cairo_surface_destroy(image) }
    }

    func image(_ index: Int) -> OpaquePointer? {
        guard (0..<PawTake.imageCount).contains(index) else { return nil }
        if !loaded {
            loaded = true
            load()
        }
        return images.indices.contains(index) ? images[index] : nil
    }

    private func load() {
        guard let directory = directories.first(where: {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }) else { return }

        for index in 0..<PawTake.imageCount {
            let path = directory.appendingPathComponent(PawTake.imageName(index) + "@2x.png").path
            guard let image = cairo_image_surface_create_from_png(path) else { discard(); return }
            guard cairo_surface_status(image) == CAIRO_STATUS_SUCCESS,
                  cairo_image_surface_get_width(image) == Int32(PawTake.imageSize.x * 2),
                  cairo_image_surface_get_height(image) == Int32(PawTake.imageSize.y * 2) else {
                cairo_surface_destroy(image)
                discard()
                return
            }
            images.append(image)
        }
    }

    private func discard() {
        for image in images { cairo_surface_destroy(image) }
        images.removeAll()
    }
}
#endif
