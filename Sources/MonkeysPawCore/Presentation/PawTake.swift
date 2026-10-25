import Foundation

/// The shared stop-motion "wish granted" take (§24.7): a monkey's paw lurches
/// in from the top right, curls a finger around the card, then carries it
/// away. Both front ends play the same discrete frames at `frameInterval`;
/// on twos, no interpolation, reading all geometry and timing from this
/// table. The values are provisional; the art pass retunes them here, so no
/// front end hard-codes frame behaviour.
public enum PawTake {
    /// A sound a frame asks the player to fire as it appears.
    public enum Cue: Equatable, Sendable {
        /// The finger curls one notch; plays `WishCardCue.crack`.
        case crack
        /// The paw lifts the card away; plays `WishCardCue.take`.
        case lift
    }

    /// A point in points, y down.
    public struct Point: Equatable, Sendable {
        public let x: Double
        public let y: Double
    }

    /// One drawn instant of the take.
    public struct Frame: Equatable, Sendable {
        /// Paw image index, 0..<imageCount.
        public let image: Int
        /// Image anchor position relative to the grip point, points, y down.
        public let paw: Point
        /// Card vertical offset, points; negative is up.
        public let cardLift: Double
        /// Card rotation, degrees; positive is clockwise.
        public let cardTurn: Double
        /// Card opacity, 0...1.
        public let cardOpacity: Double
        /// Claw scratch progress, 0...1.
        public let scratch: Double
        /// The cue fired as this frame appears, if any.
        public let cue: Cue?
    }

    /// 83 ms per frame: 12 fps stop-motion, "on twos".
    public static let frameInterval: Duration = .milliseconds(83)
    /// Nine paw images, `wish-paw-00` ... `wish-paw-08`.
    public static let imageCount = 9

    /// Resource name of a paw image, e.g. `wish-paw-03`.
    public static func imageName(_ index: Int) -> String {
        String(format: "wish-paw-%02ld", index)
    }

    /// Paw image size in points (x = width, y = height).
    public static let imageSize = Point(x: 220, y: 300)
    /// Claw contact point inside the image, points.
    public static let anchor = Point(x: 96, y: 262)
    /// Grip x as a fraction of the card width.
    public static let gripFraction = 0.68
    /// Grip y below the card's top edge, points.
    public static let gripDepth = 30.0
    /// Claw scratch segments relative to the grip point.
    public static let scratches: [(from: Point, to: Point)] = [
        (from: Point(x: -4, y: 34), to: Point(x: -4, y: 4)),
        (from: Point(x: 4, y: 30), to: Point(x: 4, y: 8)),
    ]

    /// The provisional frames: reach in, curl over four cracks, hold a beat,
    /// then lift the card away as it fades.
    public static let frames: [Frame] = [
        // Paw lurches in from the top right.
        Frame(image: 0, paw: Point(x: 18, y: -92), cardLift: 0, cardTurn: 0,
              cardOpacity: 1, scratch: 0, cue: nil),
        // Claws touch the paper.
        Frame(image: 1, paw: Point(x: 4, y: -10), cardLift: 0, cardTurn: 0,
              cardOpacity: 1, scratch: 0, cue: nil),
        // The finger starts to curl, scratching down the card.
        Frame(image: 2, paw: Point(x: 0, y: -2), cardLift: 0, cardTurn: 0,
              cardOpacity: 1, scratch: 0.2, cue: .crack),
        Frame(image: 3, paw: Point(x: 0, y: -1), cardLift: 0, cardTurn: 0,
              cardOpacity: 1, scratch: 0.5, cue: .crack),
        Frame(image: 4, paw: Point(x: 0, y: 0), cardLift: 0, cardTurn: 0,
              cardOpacity: 1, scratch: 0.8, cue: .crack),
        // Hooked.
        Frame(image: 5, paw: Point(x: 0, y: 0), cardLift: 0, cardTurn: 0,
              cardOpacity: 1, scratch: 1, cue: .crack),
        // Held beat; the image still differs (fur boil).
        Frame(image: 6, paw: Point(x: 0, y: 0), cardLift: 0, cardTurn: 0,
              cardOpacity: 1, scratch: 1, cue: nil),
        Frame(image: 7, paw: Point(x: 6, y: -58), cardLift: -58, cardTurn: -2.5,
              cardOpacity: 1, scratch: 1, cue: .lift),
        Frame(image: 8, paw: Point(x: 14, y: -190), cardLift: -190, cardTurn: -6,
              cardOpacity: 0.6, scratch: 1, cue: nil),
    ]

    /// Total take length: one interval per frame.
    public static var duration: Duration { frameInterval * frames.count }
}
