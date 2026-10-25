import Foundation

/// The shared stop-motion "wish granted" take (§24.7): a withered monkey's
/// paw lurches in from the top right, curls one finger into a hook while its
/// claw gouges the card, then carries the card away. Both front ends play the
/// same discrete frames at `frameInterval` (on twos, no interpolation) and
/// read all geometry and timing from this table, which matches the rendered
/// art in `MonkeysPaw/Resources/WishPaw/`.
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
        /// Drawn share of `gougePath`'s length, 0...1.
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

    /// Paw image size in points (x = width, y = height). The images are
    /// rendered at 2 px per point by `media-sources/paw/render-paw.c`.
    public static let imageSize = Point(x: 360, y: 410)
    /// The hooked claw's tip inside the image, points. The forearm runs off
    /// the image's top right, which stays above the panel at this depth.
    public static let anchor = Point(x: 140, y: 260)
    /// Grip x as a fraction of the card width.
    public static let gripFraction = 0.62
    /// Grip y below the card's top edge, points.
    public static let gripDepth = 150.0

    /// The claw's gouge across the paper as the finger curls, relative to the
    /// grip point: the rendered claw tip's path from frame 1 to the hook.
    public static let gougePath: [Point] = [
        Point(x: -102.3, y: 49.8), Point(x: -98.6, y: 37.6), Point(x: -95.3, y: 25.4),
        Point(x: -91.1, y: 13.1), Point(x: -84.6, y: 0.4), Point(x: -74.8, y: -14.6),
        Point(x: -62.6, y: -31.1), Point(x: -49.6, y: -45.6), Point(x: -37.4, y: -54.4),
        Point(x: -25.1, y: -55.8), Point(x: -12.2, y: -51.9), Point(x: -1.0, y: -45.2),
        Point(x: 6.3, y: -37.9), Point(x: 8.2, y: -29.9), Point(x: 6.3, y: -20.3),
        Point(x: 2.7, y: -10.0), Point(x: 0.0, y: 0.0),
    ]

    /// The drawn part of the gouge at `progress` (0...1 of its length), so
    /// its end always sits under the claw. Empty before the claw moves.
    public static func gouge(upTo progress: Double) -> [Point] {
        guard progress > 0, let first = gougePath.first else { return [] }
        // Summed segment lengths drift by ulps; a whole gouge is the path.
        guard progress < 1 else { return gougePath }

        var points = [first]
        var left = gougeLength * progress
        for (from, to) in zip(gougePath, gougePath.dropFirst()) {
            let length = distance(from, to)
            guard left < length else {
                points.append(to)
                left -= length
                continue
            }
            let t = length > 0 ? left / length : 0
            points.append(Point(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
            break
        }
        return points
    }

    private static let gougeLength = zip(gougePath, gougePath.dropFirst()).reduce(0) { $0 + distance($1.0, $1.1) }

    private static func distance(_ a: Point, _ b: Point) -> Double {
        let dx = b.x - a.x
        let dy = b.y - a.y
        return (dx * dx + dy * dy).squareRoot()
    }

    /// Reach in, curl over four cracks while gouging the paper, hold a beat,
    /// then carry the card off. Sub-point paw offsets are the animator's
    /// hand: a puppet never sits exactly still between exposures.
    public static let frames: [Frame] = [
        // Paw lurches in from the top right, claws above the paper.
        Frame(image: 0, paw: Point(x: 24, y: -70), cardLift: 0, cardTurn: 0,
              cardOpacity: 1, scratch: 0, cue: nil),
        // Claws touch the paper.
        Frame(image: 1, paw: Point(x: 0.5, y: -0.5), cardLift: 0, cardTurn: 0,
              cardOpacity: 1, scratch: 0, cue: nil),
        // The index finger curls; its claw gouges the card.
        Frame(image: 2, paw: Point(x: -0.5, y: 0.5), cardLift: 0, cardTurn: 0,
              cardOpacity: 1, scratch: 0.246, cue: .crack),
        Frame(image: 3, paw: Point(x: 0.5, y: 0), cardLift: 0, cardTurn: 0,
              cardOpacity: 1, scratch: 0.586, cue: .crack),
        Frame(image: 4, paw: Point(x: 0, y: -0.5), cardLift: 0, cardTurn: 0,
              cardOpacity: 1, scratch: 0.816, cue: .crack),
        // Hooked.
        Frame(image: 5, paw: Point(x: 0, y: 0), cardLift: 0, cardTurn: 0,
              cardOpacity: 1, scratch: 1, cue: .crack),
        // Held beat; the image still differs (fur boil, twitching fingers).
        Frame(image: 6, paw: Point(x: -0.5, y: 0.5), cardLift: 0, cardTurn: 0,
              cardOpacity: 1, scratch: 1, cue: nil),
        // The paw carries the card off the top.
        Frame(image: 7, paw: Point(x: 0, y: -46), cardLift: -46, cardTurn: 0,
              cardOpacity: 1, scratch: 1, cue: .lift),
        Frame(image: 8, paw: Point(x: -3, y: -175), cardLift: -170, cardTurn: -4,
              cardOpacity: 0.55, scratch: 1, cue: nil),
    ]

    /// Total take length: one interval per frame.
    public static var duration: Duration { frameInterval * frames.count }
}
