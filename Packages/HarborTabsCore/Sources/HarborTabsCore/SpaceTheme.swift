// Licensed under GPL-3.0. See LICENSE.
import Foundation

/// How a space dresses the window: a few color dots placed on a canvas that blend into the
/// sidebar and the frame around the page, with a grain and an intensity. A space without one
/// keeps the plain accent fade, so every file written before themes existed reads the same.
public struct SpaceTheme: Codable, Hashable, Sendable {
    /// Which scheme the window takes while this space is showing; `auto` follows the app's setting.
    public enum Mode: String, Codable, Sendable, CaseIterable {
        case auto, light, dark
    }

    public struct Dot: Codable, Hashable, Sendable, Identifiable {
        public var id: UUID
        public var hex: String
        /// Position on the canvas, 0...1 from the top left.
        public var x: Double
        public var y: Double
        static let startingID = UUID(uuidString: "00000000-0000-0000-0000-00000000A001")!

        public init(id: UUID = UUID(), hex: String, x: Double, y: Double) {
            self.id = id
            self.hex = hex
            self.x = min(max(x, 0), 1)
            self.y = min(max(y, 0), 1)
        }
    }

    public static let maxDots = 3

    /// Where each dot after the first sits relative to the first, as a turn and a fraction of its
    /// distance from the middle. Dragging any dot moves the first and the rest follow by these,
    /// which is why they stay together even when folded onto the middle.
    public struct Offset: Codable, Hashable, Sendable {
        public var angle: Double
        public var ratio: Double

        public init(angle: Double, ratio: Double) {
            self.angle = angle
            self.ratio = ratio
        }
    }

    public var dots: [Dot]
    public var offsets: [Offset]
    public var mode: Mode
    /// Film grain over the chrome, 0...1.
    public var grain: Double
    /// How strongly the dots show over the base, 0...1.
    public var intensity: Double

    public init(dots: [Dot], offsets: [Offset]? = nil, mode: Mode = .auto, grain: Double = 0.5, intensity: Double = 0.8) {
        self.dots = dots.isEmpty ? [Dot(hex: "#7C7C7C", x: 0.5, y: 0.2)] : Array(dots.prefix(Self.maxDots))
        if let offsets, offsets.count == self.dots.count - 1 {
            self.offsets = offsets
        } else {
            self.offsets = Self.defaultOffsets(count: self.dots.count - 1)
        }
        self.mode = mode
        self.grain = min(max(grain, 0), 1)
        self.intensity = min(max(intensity, 0), 1)
    }

    private enum CodingKeys: String, CodingKey { case dots, offsets, mode, grain, intensity }

    /// `offsets` is optional on disk: a theme saved before it existed gets the default formation.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            dots: try container.decode([Dot].self, forKey: .dots),
            offsets: try container.decodeIfPresent([Offset].self, forKey: .offsets),
            mode: try container.decode(Mode.self, forKey: .mode),
            grain: try container.decode(Double.self, forKey: .grain),
            intensity: try container.decode(Double.self, forKey: .intensity)
        )
    }

    // MARK: - Color wheel

    /// The canvas is a color wheel around its center: the angle (degrees, clockwise from the
    /// right) is the hue, and the distance (1 at the middle of an edge) fades it toward white.
    /// Out at the rim the color gives way to a gray ramp, white at the top left corner and black
    /// at the bottom right, so the neutrals have a place on the map too. A dot's color is read
    /// off where it sits, so moving a dot is choosing a color.
    public static func hex(angle degrees: Double, radius: Double) -> String {
        let r = min(max(radius, 0), 1)
        let hue = (degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let saturation = 1 - 0.95 * pow(r, 1.4)
        let value = 0.9 + 0.1 * r
        let chroma = value * saturation
        let x = chroma * (1 - abs(hue.truncatingRemainder(dividingBy: 2) - 1))
        let (r1, g1, b1): (Double, Double, Double)
        switch Int(hue) {
        case 0: (r1, g1, b1) = (chroma, x, 0)
        case 1: (r1, g1, b1) = (x, chroma, 0)
        case 2: (r1, g1, b1) = (0, chroma, x)
        case 3: (r1, g1, b1) = (0, x, chroma)
        case 4: (r1, g1, b1) = (x, 0, chroma)
        default: (r1, g1, b1) = (chroma, 0, x)
        }
        let m = value - chroma
        // Over the last stretch to the rim the hue is replaced by the gray for this angle.
        let rim = smoothStep(radius, from: rimStart, to: rimStart + 0.1)
        let neutral = grayLevel(angle: degrees)
        func byte(_ v: Double) -> Int { Int((((v + m) * (1 - rim) + neutral * rim) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(r1), byte(g1), byte(b1))
    }

    /// Where the rim starts to turn gray, as a distance from the middle.
    static let rimStart = 0.78

    private static func smoothStep(_ value: Double, from low: Double, to high: Double) -> Double {
        let t = min(max((value - low) / (high - low), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// The gray the rim shows at an angle: 1 (white) at the top left corner, 0 at the bottom right.
    public static func grayLevel(angle degrees: Double) -> Double {
        0.5 + 0.5 * cos((degrees - 225) * .pi / 180)
    }

    /// Where on the rim a gray sits, on the side of the map nearest `angle`, just inside the border.
    public static func position(forGray level: Double, near angle: Double) -> (x: Double, y: Double) {
        let spread = acos(min(max(2 * level - 1, -1), 1)) * 180 / .pi
        func apart(_ a: Double, _ b: Double) -> Double {
            let d = abs((a - b).truncatingRemainder(dividingBy: 360))
            return min(d, 360 - d)
        }
        let chosen = [225 + spread, 225 - spread].min { apart($0, angle) < apart($1, angle) } ?? 225
        let radians = chosen * .pi / 180
        // Out along that direction to the border of the canvas, then a little back in.
        let toSide = canvasWidth / 2 / max(abs(cos(radians)), 1e-6)
        let toTop = canvasHeight / 2 / max(abs(sin(radians)), 1e-6)
        return unit(angle: chosen, radius: min(toSide, toTop) / (canvasWidth / 2) * 0.96)
    }

    public static func grayHex(_ level: Double) -> String {
        let byte = Int((min(max(level, 0), 1) * 255).rounded())
        return String(format: "#%02X%02X%02X", byte, byte, byte)
    }

    /// Where on the wheel a color sits: its hue as the angle and its softness as the distance.
    /// Unit coordinates, for a canvas as wide as it is tall.
    static func wheelPosition(of hex: String) -> (x: Double, y: Double) {
        var value: UInt64 = 0
        Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&value)
        let red = Double((value >> 16) & 0xFF) / 255, green = Double((value >> 8) & 0xFF) / 255, blue = Double(value & 0xFF) / 255
        let top = max(red, green, blue), bottom = min(red, green, blue), delta = top - bottom
        var hue = 0.0
        if delta > 0 {
            if top == red { hue = 60 * ((green - blue) / delta).truncatingRemainder(dividingBy: 6) }
            else if top == green { hue = 60 * ((blue - red) / delta + 2) }
            else { hue = 60 * ((red - green) / delta + 4) }
        }
        let saturation = top == 0 ? 0 : delta / top
        // A gray has no hue: it sits on the rim where that gray is.
        if saturation < 0.06 { return position(forGray: top, near: 225) }
        let radius = min(max(pow(max(1 - saturation, 0) / 0.95, 1 / 1.4), 0.25), 1)
        let angle = hue * .pi / 180
        return (0.5 + 0.5 * radius * cos(angle), 0.5 + 0.5 * radius * sin(angle))
    }

    /// What editing starts from: the space's accent as one dot, where its color sits on the wheel.
    public static func starting(from accentHex: String) -> SpaceTheme {
        let place = wheelPosition(of: accentHex)
        // A fixed id: this is rebuilt on every read until the first edit saves a theme, and an
        // editor holding a dot by id would never find it again.
        return SpaceTheme(dots: [Dot(id: Dot.startingID, hex: accentHex, x: place.x, y: place.y)])
    }

    /// The color the rest of the chrome tints with.
    public var primaryHex: String { dots[0].hex }
}


// MARK: - Formation

extension SpaceTheme {
    /// The canvas the dots sit on, in points. Angles and distances are read on this shape, so the
    /// editor and the stored positions agree on what a turn is.
    public static let canvasWidth = 256.0
    public static let canvasHeight = 240.0

    /// The other dots sit opposite the first, spread evenly and a little nearer the middle.
    static func defaultOffsets(count: Int) -> [Offset] {
        (0..<max(count, 0)).map { index in
            Offset(angle: 193 + (Double(index) - Double(count - 1) / 2) * 62, ratio: 0.85)
        }
    }

    /// Hue angle in degrees and distance from the middle, 1 at the middle of the left or right edge.
    public static func polar(x: Double, y: Double) -> (angle: Double, radius: Double) {
        let dx = (x - 0.5) * canvasWidth, dy = (y - 0.5) * canvasHeight
        return (atan2(dy, dx) * 180 / .pi, hypot(dx, dy) / (canvasWidth / 2))
    }

    public static func unit(angle: Double, radius: Double) -> (x: Double, y: Double) {
        let radians = angle * .pi / 180
        let distance = radius * canvasWidth / 2
        return (0.5 + distance * cos(radians) / canvasWidth, 0.5 + distance * sin(radians) / canvasHeight)
    }

    /// Lays every dot out from the first one's place on the wheel, nearer the middle if the whole
    /// formation would not fit, and reads each dot's color off where it landed.
    public mutating func arrange(angle: Double, radius: Double) {
        func places(_ radius: Double) -> [(x: Double, y: Double)] {
            var places = [Self.unit(angle: angle, radius: radius)]
            for offset in offsets {
                places.append(Self.unit(angle: angle + offset.angle, radius: radius * offset.ratio))
            }
            return places
        }
        func fits(_ places: [(x: Double, y: Double)]) -> Bool {
            places.allSatisfy { (0...1).contains($0.x) && (0...1).contains($0.y) }
        }
        var reach = max(radius, 0)
        if !fits(places(reach)) {
            var low = 0.0, high = reach
            for _ in 0..<24 {
                let middle = (low + high) / 2
                if fits(places(middle)) { low = middle } else { high = middle }
            }
            reach = low
        }
        for (index, place) in places(reach).enumerated() where dots.indices.contains(index) {
            let spot = Self.polar(x: place.x, y: place.y)
            dots[index].x = place.x
            dots[index].y = place.y
            dots[index].hex = Self.hex(angle: spot.angle, radius: spot.radius)
        }
    }

    /// Moves one dot toward a point; the first dot, and so all the others, follow from it.
    /// Works from the middle too: the offsets are kept, so a folded formation unfolds.
    public mutating func drag(dotAt index: Int, toX x: Double, y: Double) {
        guard dots.indices.contains(index) else { return }
        let target = Self.polar(x: x, y: y)
        if index == 0 {
            arrange(angle: target.angle, radius: target.radius)
        } else {
            let offset = offsets[index - 1]
            arrange(angle: target.angle - offset.angle, radius: target.radius / offset.ratio)
        }
    }

    public mutating func addDot() {
        guard dots.count < Self.maxDots else { return }
        let lead = Self.polar(x: dots[0].x, y: dots[0].y)
        dots.append(Dot(hex: dots[0].hex, x: dots[0].x, y: dots[0].y))
        offsets = Self.defaultOffsets(count: dots.count - 1)
        arrange(angle: lead.angle, radius: max(lead.radius, 0.2))
    }

    /// Takes a dot away, never the last one. Removing the first hands the lead to the next.
    public mutating func removeDot(at index: Int) {
        guard dots.count > 1, dots.indices.contains(index) else { return }
        dots.remove(at: index)
        offsets = Self.defaultOffsets(count: dots.count - 1)
        let lead = Self.polar(x: dots[0].x, y: dots[0].y)
        arrange(angle: lead.angle, radius: lead.radius)
    }
}
