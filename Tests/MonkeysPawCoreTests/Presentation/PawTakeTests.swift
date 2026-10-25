import Foundation
import XCTest
@testable import MonkeysPawCore

final class PawTakeTests: XCTestCase {
    /// Frames 1 to 6 hold the paw at the grip, where the art's hooked claw
    /// meets the gouge; only the lurch and the carry move it.
    func testPawRestsAtTheGripWhileTheFingerCurls() {
        for frame in PawTake.frames[1...6] {
            XCTAssertLessThanOrEqual(abs(frame.paw.x), 1)
            XCTAssertLessThanOrEqual(abs(frame.paw.y), 1)
            XCTAssertEqual(frame.cardLift, 0)
            XCTAssertEqual(frame.cardOpacity, 1)
        }
        XCTAssertLessThan(PawTake.frames[0].paw.y, -20, "the paw lurches in from above")
        XCTAssertEqual(PawTake.frames.map(\.cue), [nil, nil, .crack, .crack, .crack, .crack, nil, .lift, nil])
    }

    /// The carried card leaves with the paw, so their lifts match.
    func testCarryMovesPawAndCardTogether() {
        for frame in PawTake.frames[7...] {
            XCTAssertLessThan(frame.cardLift, 0)
            XCTAssertEqual(frame.paw.y, frame.cardLift, accuracy: 6)
        }
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
        XCTAssertTrue((0...PawTake.imageSize.x).contains(PawTake.anchor.x))
        XCTAssertTrue((0...PawTake.imageSize.y).contains(PawTake.anchor.y))
        XCTAssertTrue((0...1).contains(PawTake.gripFraction))
        XCTAssertGreaterThan(PawTake.gripDepth, 0)
    }

    /// The gouge ends under the hooked claw, at the grip point.
    func testGougeEndsAtTheGrip() {
        XCTAssertEqual(PawTake.gougePath.last, .init(x: 0, y: 0))
        XCTAssertEqual(PawTake.gouge(upTo: 1), PawTake.gougePath)
        XCTAssertEqual(PawTake.gouge(upTo: 2), PawTake.gougePath)
    }

    func testGougeIsEmptyBeforeTheClawMoves() {
        XCTAssertEqual(PawTake.gouge(upTo: 0), [])
        XCTAssertEqual(PawTake.gouge(upTo: -1), [])
    }

    /// A partial gouge follows the path and stops part-way along a segment.
    func testPartialGougeFollowsThePathByLength() {
        let path = PawTake.gougePath
        let segments = zip(path, path.dropFirst()).map { a, b in
            ((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y)).squareRoot()
        }
        let total = segments.reduce(0, +)
        let half = PawTake.gouge(upTo: 0.5)
        XCTAssertEqual(Array(half.dropLast()), Array(path.prefix(half.count - 1)))

        let drawn = zip(half, half.dropFirst()).map { a, b in
            ((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y)).squareRoot()
        }.reduce(0, +)
        XCTAssertEqual(drawn, total / 2, accuracy: 0.01)
    }
}
