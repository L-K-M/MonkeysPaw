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
            let samples = LinuxFeedbackSounds.pcmSamples(for: sound)
            XCTAssertEqual(data.count, 44 + 2 * samples.count)
            XCTAssertEqual(Double(samples.count) / 44_100, duration, accuracy: 0.0001)
            let peak = samples.map { abs(Int($0)) }.max() ?? 0
            XCTAssertEqual(Double(peak) / 32_767, pow(10, decibels / 20), accuracy: 1 / 32_767)
        }
    }
}
#endif
