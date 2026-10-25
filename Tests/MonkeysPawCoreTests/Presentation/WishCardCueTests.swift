import Foundation
import XCTest
@testable import MonkeysPawCore

final class WishCardCueTests: XCTestCase {
    /// SHA-256 of each WAV captured from the LinuxFeedbackSounds synthesis at
    /// HEAD, before it moved to Core (built from the original file, not from
    /// WishCardCue). The move must not change a single sample.
    private static let preMoveDigests: [WishCardCue: String] = [
        .tick: "4d616b2d7bd18528cad0c5c553b885bdbf85ee49453f68f83917c201aa9bc1e9",
        .ready: "af92bf138b54db32e93933c48c5e1742d2f35c3bb3b5b1815594f38c773989b5",
        .take: "7b29de0ff5ddc685a6865d211fc84d9cfb94632ccb9602c1b86883bdfbcb4ef0",
        .nudge: "b4f47713bffbd1899dacc26eb6fa52a7a1f22ce94affd3f7777357934cb9c584",
    ]

    func testMovedCuesStayByteIdenticalToTheLinuxOriginals() {
        XCTAssertEqual(Self.preMoveDigests.count, 4)
        for (cue, digest) in Self.preMoveDigests {
            XCTAssertEqual(SHA256.hexDigest(Data(cue.wav)), digest, "\(cue)")
        }
    }

    func testAllCasesAndDeterminism() {
        XCTAssertEqual(WishCardCue.allCases, [.tick, .ready, .take, .nudge, .crack])
        for cue in WishCardCue.allCases {
            XCTAssertEqual(cue.wav, cue.wav, "\(cue)")
            XCTAssertEqual(cue.pcm, cue.pcm, "\(cue)")
        }
    }

    func testWavIsCanonicalMonoPCMRIFF() {
        for cue in WishCardCue.allCases {
            let wav = cue.wav
            let pcm = cue.pcm
            XCTAssertEqual(wav.count, 44 + pcm.count * 2, "\(cue)")
            XCTAssertEqual(String(decoding: wav[0..<4], as: UTF8.self), "RIFF", "\(cue)")
            XCTAssertEqual(u32(wav, 4), UInt32(36 + pcm.count * 2), "\(cue)")
            XCTAssertEqual(String(decoding: wav[8..<12], as: UTF8.self), "WAVE", "\(cue)")
            XCTAssertEqual(String(decoding: wav[12..<16], as: UTF8.self), "fmt ", "\(cue)")
            XCTAssertEqual(u32(wav, 16), 16, "\(cue)")
            XCTAssertEqual(u16(wav, 20), 1, "\(cue)")  // linear PCM
            XCTAssertEqual(u16(wav, 22), 1, "\(cue)")  // mono
            XCTAssertEqual(u32(wav, 24), 44_100, "\(cue)")
            XCTAssertEqual(u32(wav, 28), 88_200, "\(cue)") // byte rate
            XCTAssertEqual(u16(wav, 32), 2, "\(cue)")  // block align
            XCTAssertEqual(u16(wav, 34), 16, "\(cue)") // bits per sample
            XCTAssertEqual(String(decoding: wav[36..<40], as: UTF8.self), "data", "\(cue)")
            XCTAssertEqual(u32(wav, 40), UInt32(pcm.count * 2), "\(cue)")
        }
    }

    func testDurationAndPeakBounds() {
        let limits: [(cue: WishCardCue, min: Double, max: Double, decibels: Double)] = [
            (.tick, 0.004, 0.006, -24),
            (.ready, 0.655, 0.660, -22),
            (.take, 0.165, 0.175, -18),
            (.nudge, 0.065, 0.075, -22),
            (.crack, 0.010, 0.045, -18),
        ]
        for (cue, lower, upper, decibels) in limits {
            let seconds = Double(cue.pcm.count) / 44_100
            XCTAssertGreaterThanOrEqual(seconds, lower, "\(cue)")
            XCTAssertLessThanOrEqual(seconds, upper, "\(cue)")
            let peak = cue.pcm.map { abs(Int($0)) }.max() ?? 0
            XCTAssertEqual(Double(peak) / 32_767, pow(10, decibels / 20),
                           accuracy: 1 / 32_767, "\(cue)")
        }
    }

    /// The crack is a dry knuckle crack: a broadband transient, then creaking
    /// grains, no DC and a clean fade inside the 45 ms budget.
    func testCrackHasNoDCAndFadesOut() {
        let pcm = WishCardCue.crack.pcm
        XCTAssertLessThanOrEqual(pcm.count, Int(0.045 * 44_100))
        let mean = pcm.reduce(0.0) { $0 + Double($1) } / Double(pcm.count)
        XCTAssertEqual(mean, 0, accuracy: 1)
        let tail = pcm.suffix(Int(0.002 * 44_100))
        XCTAssertLessThanOrEqual(tail.map { abs(Int($0)) }.max() ?? 0, 512)
    }

    func testCrackCreakUsesSeparateClicksAt60Hz() {
        let samples = WishCardCue.crack.pcm
        func peak(_ from: Double, _ to: Double) -> Int {
            samples[Int(from * 44_100)..<Int(to * 44_100)].map { abs(Int($0)) }.max() ?? 0
        }
        XCTAssertGreaterThan(peak(0.002, 0.004), 300)
        XCTAssertLessThan(peak(0.006, 0.016), 100)
        XCTAssertGreaterThan(peak(0.018, 0.021), 200)
        XCTAssertLessThan(peak(0.023, 0.029), 100)
    }

    private func u16(_ wav: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(wav[offset]) | UInt16(wav[offset + 1]) << 8
    }

    private func u32(_ wav: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(wav[offset]) | UInt32(wav[offset + 1]) << 8
            | UInt32(wav[offset + 2]) << 16 | UInt32(wav[offset + 3]) << 24
    }
}
