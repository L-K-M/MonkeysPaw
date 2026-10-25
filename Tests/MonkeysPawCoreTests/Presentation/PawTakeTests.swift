import Foundation
import XCTest
@testable import MonkeysPawCore

final class PawTakeTests: XCTestCase {
    /// The provisional 9-frame table from §24.7: front ends read geometry and
    /// timing only from here, so the test pins every value.
    func testTimelineMatchesTheProvisionalTable() {
        let frames = PawTake.frames
        XCTAssertEqual(frames, [
            PawTake.Frame(image: 0, paw: .init(x: 18, y: -92), cardLift: 0, cardTurn: 0,
                          cardOpacity: 1, scratch: 0, cue: nil),
            PawTake.Frame(image: 1, paw: .init(x: 4, y: -10), cardLift: 0, cardTurn: 0,
                          cardOpacity: 1, scratch: 0, cue: nil),
            PawTake.Frame(image: 2, paw: .init(x: 0, y: -2), cardLift: 0, cardTurn: 0,
                          cardOpacity: 1, scratch: 0.2, cue: .crack),
            PawTake.Frame(image: 3, paw: .init(x: 0, y: -1), cardLift: 0, cardTurn: 0,
                          cardOpacity: 1, scratch: 0.5, cue: .crack),
            PawTake.Frame(image: 4, paw: .init(x: 0, y: 0), cardLift: 0, cardTurn: 0,
                          cardOpacity: 1, scratch: 0.8, cue: .crack),
            PawTake.Frame(image: 5, paw: .init(x: 0, y: 0), cardLift: 0, cardTurn: 0,
                          cardOpacity: 1, scratch: 1, cue: .crack),
            PawTake.Frame(image: 6, paw: .init(x: 0, y: 0), cardLift: 0, cardTurn: 0,
                          cardOpacity: 1, scratch: 1, cue: nil),
            PawTake.Frame(image: 7, paw: .init(x: 6, y: -58), cardLift: -58, cardTurn: -2.5,
                          cardOpacity: 1, scratch: 1, cue: .lift),
            PawTake.Frame(image: 8, paw: .init(x: 14, y: -190), cardLift: -190, cardTurn: -6,
                          cardOpacity: 0.6, scratch: 1, cue: nil),
        ])
    }

    func testFrameCountIntervalDurationAndImageRange() {
        XCTAssertEqual(PawTake.imageCount, 9)
        XCTAssertEqual(PawTake.frames.count, PawTake.imageCount)
        XCTAssertEqual(PawTake.frameInterval, .milliseconds(83))
        XCTAssertEqual(PawTake.duration, PawTake.frameInterval * PawTake.frames.count)
        XCTAssertEqual(PawTake.duration, .milliseconds(9 * 83))
        for frame in PawTake.frames {
            XCTAssertTrue((0..<PawTake.imageCount).contains(frame.image))
        }
    }

    func testScratchProgressIsMonotonic() {
        var previous = 0.0
        for frame in PawTake.frames {
            XCTAssertGreaterThanOrEqual(frame.scratch, previous)
            previous = frame.scratch
        }
        XCTAssertEqual(previous, 1)
    }

    func testImageNamesAndGeometry() {
        XCTAssertEqual((0..<PawTake.imageCount).map(PawTake.imageName),
                       (0..<9).map { String(format: "wish-paw-%02ld", $0) })
        XCTAssertEqual(PawTake.imageName(0), "wish-paw-00")
        XCTAssertEqual(PawTake.imageName(8), "wish-paw-08")
        XCTAssertEqual(PawTake.imageSize, .init(x: 220, y: 300))
        XCTAssertEqual(PawTake.anchor, .init(x: 96, y: 262))
        XCTAssertEqual(PawTake.gripFraction, 0.68)
        XCTAssertEqual(PawTake.gripDepth, 30)
        XCTAssertEqual(PawTake.scratches.count, 2)
        XCTAssertEqual(PawTake.scratches[0].from, .init(x: -4, y: 34))
        XCTAssertEqual(PawTake.scratches[0].to, .init(x: -4, y: 4))
        XCTAssertEqual(PawTake.scratches[1].from, .init(x: 4, y: 30))
        XCTAssertEqual(PawTake.scratches[1].to, .init(x: 4, y: 8))
    }
}
