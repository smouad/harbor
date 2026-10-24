import XCTest
@testable import HarborTabsCore

final class SpaceThemeTests: XCTestCase {
    func testSpaceWrittenBeforeThemesDecodesWithoutOne() throws {
        let old = """
        {"id":"\(UUID().uuidString)","name":"Work","icon":"house","accentHex":"#3A8FA3","order":"a0","modifiedAt":0}
        """
        let space = try JSONDecoder().decode(SpaceRecord.self, from: Data(old.utf8))
        XCTAssertNil(space.theme)
        XCTAssertEqual(space.accentHex, "#3A8FA3")
    }

    func testThemeRoundTripsAndKeepsItsDots() throws {
        var theme = SpaceTheme.starting(from: "#3A8FA3")
        theme.addDot()
        theme.mode = .dark
        let space = SpaceRecord(name: "Work", icon: "house", accentHex: theme.primaryHex, theme: theme, order: OrderKey("a0"))
        let back = try JSONDecoder().decode(SpaceRecord.self, from: JSONEncoder().encode(space))
        XCTAssertEqual(back.theme, theme)
    }

    func testUpdateSpaceSetsAndClearsTheme() throws {
        var tree = TabTree()
        let created = tree.createSpace(name: "Work", icon: "house", accentHex: "#3A8FA3", after: nil)
        _ = created
        let id = try XCTUnwrap(tree.orderedSpaces.first?.id)
        try tree.updateSpace(id, theme: .starting(from: "#D6603A"))
        XCTAssertEqual(tree.space(id)?.theme?.primaryHex, "#D6603A")
        try tree.updateSpace(id, clearTheme: true)
        XCTAssertNil(tree.space(id)?.theme)
    }

    func testDotsStayOnTheCanvasAndWithinTheLimit() {
        let dot = SpaceTheme.Dot(hex: "#fff", x: 2, y: -1)
        XCTAssertEqual(dot.x, 1)
        XCTAssertEqual(dot.y, 0)
        let many = (0..<9).map { _ in SpaceTheme.Dot(hex: "#fff", x: 0.5, y: 0.5) }
        XCTAssertEqual(SpaceTheme(dots: many).dots.count, SpaceTheme.maxDots)
    }
}

final class SpaceThemeWheelTests: XCTestCase {
    func testWheelReadsHueFromAngleAndFadesTowardTheRim() {
        // Clockwise from the right: red, then green a third of the way round, then blue.
        XCTAssertEqual(SpaceTheme.hex(angle: 0, radius: 0), "#E60000")
        XCTAssertEqual(SpaceTheme.hex(angle: 120, radius: 0), "#00E600")
        XCTAssertEqual(SpaceTheme.hex(angle: 240, radius: 0), "#0000E6")
        // At the rim the hue gives way to the gray ramp: white at the top left, black at the bottom right.
        XCTAssertEqual(SpaceTheme.hex(angle: 225, radius: 1), "#FFFFFF")
        XCTAssertEqual(SpaceTheme.hex(angle: 45, radius: 1), "#000000")
    }

    func testStartingFromAColorPutsItWhereTheWheelWouldRead() {
        let theme = SpaceTheme.starting(from: SpaceTheme.hex(angle: 200, radius: 0.5))
        let dot = theme.dots[0]
        let angle = atan2(dot.y - 0.5, dot.x - 0.5) * 180 / .pi
        XCTAssertEqual(angle < 0 ? angle + 360 : angle, 200, accuracy: 2)
    }
}

final class SpaceThemeStartingTests: XCTestCase {
    func testStartingThemeKeepsTheSameDotIDAcrossReads() {
        // The editor reads a space with no theme repeatedly and holds its dot by id.
        XCTAssertEqual(SpaceTheme.starting(from: "#3A8FA3").dots[0].id, SpaceTheme.starting(from: "#3A8FA3").dots[0].id)
    }
}

final class SpaceThemeFormationTests: XCTestCase {
    private func theme(_ count: Int) -> SpaceTheme {
        var theme = SpaceTheme.starting(from: "#3A8FA3")
        for _ in 1..<count { theme.addDot() }
        return theme
    }

    func testAddingFillsUpToTheLimitAndRemovingLeavesOne() {
        var theme = theme(1)
        for _ in 0..<5 { theme.addDot() }
        XCTAssertEqual(theme.dots.count, SpaceTheme.maxDots)
        XCTAssertEqual(theme.offsets.count, theme.dots.count - 1)
        for _ in 0..<5 { theme.removeDot(at: theme.dots.count - 1) }
        XCTAssertEqual(theme.dots.count, 1, "the last dot stays")
        theme.removeDot(at: 0)
        XCTAssertEqual(theme.dots.count, 1)
    }

    func testRemovingTheFirstDotHandsTheLeadToTheNext() {
        var theme = theme(3)
        let second = theme.dots[1].id
        theme.removeDot(at: 0)
        XCTAssertEqual(theme.dots.count, 2)
        XCTAssertEqual(theme.dots[0].id, second)
    }

    func testDraggingADotCarriesTheOthersWithIt() {
        var theme = theme(3)
        let before = theme.dots.map { [$0.x, $0.y] }
        theme.drag(dotAt: 2, toX: 0.2, y: 0.3)
        XCTAssertEqual(theme.dots[2].x, 0.2, accuracy: 0.02)
        XCTAssertEqual(theme.dots[2].y, 0.3, accuracy: 0.02)
        XCTAssertNotEqual(before[0], [theme.dots[0].x, theme.dots[0].y], "the first dot follows")
        XCTAssertNotEqual(before[1], [theme.dots[1].x, theme.dots[1].y], "so does the other")
    }

    func testDotsFoldedOntoTheMiddleStillMoveTogether() {
        var theme = theme(3)
        theme.arrange(angle: 40, radius: 0)
        for dot in theme.dots {
            XCTAssertEqual(dot.x, 0.5, accuracy: 0.0001)
            XCTAssertEqual(dot.y, 0.5, accuracy: 0.0001)
        }
        theme.drag(dotAt: 1, toX: 0.8, y: 0.5)
        let places = Set(theme.dots.map { "\(($0.x * 100).rounded())/\(($0.y * 100).rounded())" })
        XCTAssertEqual(places.count, 3, "they unfold instead of one leaving the rest behind")
    }

    func testEveryDotStaysOnTheCanvas() {
        var theme = theme(3)
        theme.drag(dotAt: 0, toX: 1.0, y: 0.0)
        for dot in theme.dots {
            XCTAssertTrue((0...1).contains(dot.x) && (0...1).contains(dot.y))
        }
    }

    func testAThemeSavedBeforeOffsetsExistedStillDecodes() throws {
        let old = """
        {"dots":[{"id":"\(UUID().uuidString)","hex":"#3A8FA3","x":0.5,"y":0.5},{"id":"\(UUID().uuidString)","hex":"#E5779F","x":0.7,"y":0.4}],"mode":"auto","grain":0.5,"intensity":0.8}
        """
        let theme = try JSONDecoder().decode(SpaceTheme.self, from: Data(old.utf8))
        XCTAssertEqual(theme.dots.count, 2)
        XCTAssertEqual(theme.offsets.count, 1)
    }
}

final class SpaceThemeNeutralTests: XCTestCase {
    func testEveryGrayHasAPlaceOnTheMapThatReadsBackAsThatGray() {
        for level in stride(from: 0.0, through: 1.0, by: 0.125) {
            for near in [0.0, 90, 180, 270] {
                let place = SpaceTheme.position(forGray: level, near: near)
                XCTAssertTrue((0...1).contains(place.x) && (0...1).contains(place.y), "inside the canvas")
                let spot = SpaceTheme.polar(x: place.x, y: place.y)
                let read = SpaceTheme.hex(angle: spot.angle, radius: spot.radius)
                // Within a step or two of the gray: the place is found by float math.
                let got = Int(read.dropFirst(1).prefix(2), radix: 16)!
                let want = Int(SpaceTheme.grayHex(level).dropFirst(1).prefix(2), radix: 16)!
                XCTAssertEqual(got, want, accuracy: 2, "gray \(level) near \(near)")
                XCTAssertEqual(read.dropFirst(1).prefix(2), read.dropFirst(3).prefix(2), "no tint left")
            }
        }
    }

    func testAGrayAccentStartsOnTheRim() {
        let dot = SpaceTheme.starting(from: "#7C7C7C").dots[0]
        let spot = SpaceTheme.polar(x: dot.x, y: dot.y)
        XCTAssertGreaterThan(spot.radius, 0.85)
    }

    func testGrayHex() {
        XCTAssertEqual(SpaceTheme.grayHex(0), "#000000")
        XCTAssertEqual(SpaceTheme.grayHex(1), "#FFFFFF")
    }
}
