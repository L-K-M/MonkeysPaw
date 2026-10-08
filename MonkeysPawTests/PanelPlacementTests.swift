import Foundation
import MonkeysPawCore
import XCTest
@testable import MonkeysPaw

final class PanelPlacementTests: XCTestCase {
    func testSelectsScreenUnderCursorAcrossDisplayOrigins() {
        let screens = [
            CGRect(x: 0, y: 0, width: 1440, height: 900),
            CGRect(x: -1920, y: 0, width: 1920, height: 1080),
            CGRect(x: 0, y: 900, width: 1200, height: 800),
        ]

        XCTAssertEqual(PanelPlacement.screenIndex(at: CGPoint(x: 800, y: 500), frames: screens), 0)
        XCTAssertEqual(PanelPlacement.screenIndex(at: CGPoint(x: -100, y: 500), frames: screens), 1)
        XCTAssertEqual(PanelPlacement.screenIndex(at: CGPoint(x: 500, y: 1200), frames: screens), 2)
        XCTAssertNil(PanelPlacement.screenIndex(at: CGPoint(x: -500, y: 1200), frames: screens))
        XCTAssertNil(PanelPlacement.screenIndex(at: .zero, frames: []))
    }

    func testPlacesTopLeftAtCursorWhenThereIsRoom() {
        let visibleFrame = CGRect(x: 0, y: 25, width: 1440, height: 875)
        let frame = PanelPlacement.frame(at: CGPoint(x: 400, y: 700), in: visibleFrame)

        XCTAssertEqual(frame, CGRect(x: 400, y: 280,
                                    width: Limits.panelSize.width,
                                    height: Limits.panelSize.height))
    }

    func testClampsAtEveryEdgeOfEachVisibleFrame() {
        // Left, above and right-hand displays have nonzero or negative origins.
        let visibleFrames = [
            CGRect(x: 0, y: 25, width: 1440, height: 875),
            CGRect(x: -1920, y: 60, width: 1920, height: 1020),
            CGRect(x: 0, y: 1100, width: 1200, height: 780),
            CGRect(x: 1440, y: -200, width: 1280, height: 720),
        ]

        for visibleFrame in visibleFrames {
            let cursors = [
                CGPoint(x: visibleFrame.minX - 100, y: visibleFrame.minY - 100),
                CGPoint(x: visibleFrame.maxX + 100, y: visibleFrame.maxY + 100),
                CGPoint(x: visibleFrame.maxX - 1, y: visibleFrame.minY + 1),
                CGPoint(x: visibleFrame.minX + 1, y: visibleFrame.maxY - 1),
            ]

            for cursor in cursors {
                let frame = PanelPlacement.frame(at: cursor, in: visibleFrame)

                XCTAssertEqual(frame.width, CGFloat(Limits.panelSize.width))
                XCTAssertEqual(frame.height, CGFloat(Limits.panelSize.height))
                XCTAssertGreaterThanOrEqual(frame.minX, visibleFrame.minX)
                XCTAssertGreaterThanOrEqual(frame.minY, visibleFrame.minY)
                XCTAssertLessThanOrEqual(frame.maxX, visibleFrame.maxX)
                XCTAssertLessThanOrEqual(frame.maxY, visibleFrame.maxY)
            }
        }
    }

    func testClampsToBottomRightOfNegativeOriginDisplay() {
        let visibleFrame = CGRect(x: -1920, y: -300, width: 1920, height: 1080)
        let frame = PanelPlacement.frame(at: CGPoint(x: -10, y: -290), in: visibleFrame)

        XCTAssertEqual(frame, CGRect(x: visibleFrame.maxX - CGFloat(Limits.panelSize.width),
                                    y: visibleFrame.minY,
                                    width: Limits.panelSize.width,
                                    height: Limits.panelSize.height))
    }

    func testShrinksPanelToFitSmallVisibleFrame() {
        let visibleFrame = CGRect(x: -320, y: 200, width: 320, height: 240)

        XCTAssertEqual(PanelPlacement.frame(at: CGPoint(x: -10, y: 210), in: visibleFrame),
                       visibleFrame)
    }

    func testZeroSizeVisibleFrameDoesNotCreateNegativeDimensions() {
        let visibleFrame = CGRect(x: 100, y: 200, width: 0, height: 0)

        XCTAssertEqual(PanelPlacement.frame(at: .zero, in: visibleFrame), visibleFrame)
    }
}
