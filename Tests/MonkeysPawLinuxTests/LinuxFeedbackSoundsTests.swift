#if os(Linux)
import Foundation
import XCTest
@testable import MonkeysPawLinux

final class LinuxFeedbackSoundsTests: XCTestCase {
    func testWAVsAreDeterministicMonoPCMAtTheSpecifiedPeak() {
        let limits: [(LinuxFeedbackSounds.Sound, Double, Double)] = [
            (.tick, 0.005, -24), (.ready, 0.658, -22), (.take, 0.170, -18), (.nudge, 0.070, -22)
        ]
        for (sound, duration, decibels) in limits {
            let data = LinuxFeedbackSounds.wavData(for: sound)
            XCTAssertEqual(data, LinuxFeedbackSounds.wavData(for: sound))
            XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "RIFF")
            XCTAssertEqual(String(decoding: data[8..<12], as: UTF8.self), "WAVE")
            XCTAssertEqual(data[20], 1) // PCM
            XCTAssertEqual(data[22], 1) // Mono
            XCTAssertEqual(Array(data[24..<28]), [0x44, 0xAC, 0, 0]) // 44,100 Hz
            XCTAssertEqual(data[34], 16)
            let samples = stride(from: 44, to: data.count, by: 2).map {
                Int16(bitPattern: UInt16(data[$0]) | (UInt16(data[$0 + 1]) << 8))
            }
            XCTAssertEqual(data.count, 44 + 2 * samples.count)
            XCTAssertEqual(Double(samples.count) / 44_100, duration, accuracy: 0.0001)
            let peak = samples.map { abs(Int($0)) }.max() ?? 0
            XCTAssertEqual(Double(peak) / 32_767, pow(10, decibels / 20), accuracy: 1 / 32_767)
        }
    }

    /// GTK's GStreamer backend aborts on stream-backed media, so playback
    /// reads cue files written once into a private directory.
    func testCuesAreWrittenAsPrivateFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("sounds", isDirectory: true)
        let files = LinuxFeedbackSounds.writeCues(to: directory)
        XCTAssertEqual(Set(files.keys), Set(LinuxFeedbackSounds.Sound.allCases))
        for (sound, path) in files {
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), LinuxFeedbackSounds.wavData(for: sound))
        }
        let mode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o700)
    }

    func testUnwritableDirectoryKeepsPlaybackSilent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        // A file where the directory should be: root-proof, unlike chmod.
        try Data("x".utf8).write(to: root)
        XCTAssertTrue(LinuxFeedbackSounds.writeCues(to: root.appendingPathComponent("sounds")).isEmpty)
    }
}
#endif
