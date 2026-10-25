// Checks that an Arc space's background (gradient or single color) is read into hex colors.
//   swiftc -parse-as-library Harbor/Managers/ImportManager/Arc.swift scripts/tests/ArcBackgroundCheck.swift -o /tmp/x && /tmp/x
import Foundation

@main
struct ArcBackgroundCheck {
    static func theme(_ color: [String: Any]) -> [String: Any] {
        ["background": ["single": ["_0": ["style": ["color": ["_0": color]]]]]]
    }

    static func main() {
        // A gradient: two base colors, one of them out of range as extended sRGB can be.
        let gradient: [String: Any] = ["blendedGradient": ["_0": [
            "baseColors": [
                ["red": -0.278, "green": 0.876, "blue": 0.388, "alpha": 1, "colorSpace": "extendedSRGB"],
                ["red": 0.934, "green": 0.256, "blue": 0.749, "alpha": 1, "colorSpace": "extendedSRGB"],
            ],
            "modifiers": ["noiseFactor": 0.85, "intensityFactor": 0.79],
        ]]]
        let one = background(fromTheme: theme(gradient))!
        precondition(one.colors == ["#00DF63", "#EE41BF"], "\(one.colors)")
        precondition(one.grain == 0.85 && one.intensity == 0.79)

        let solid: [String: Any] = ["blendedSingleColor": ["_0": [
            "color": ["red": 0.949, "green": 0.369, "blue": 0.42, "alpha": 1],
            "modifiers": ["noiseFactor": 0.95, "intensityFactor": 0.265],
        ]]]
        let two = background(fromTheme: theme(solid))!
        precondition(two.colors == ["#F25E6B"], "\(two.colors)")
        precondition(two.grain == 0.95)

        // A space with no theme, or a shape this does not know, gives nothing instead of a wrong color.
        precondition(background(fromTheme: [:]) == nil)
        precondition(background(fromTheme: nil) == nil)
        precondition(background(fromTheme: theme(["somethingNew": ["_0": [:]]])) == nil)

        // The real file on this Mac, when there is one: every themed space must come out with colors.
        let sidebar = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Arc/StorableSidebar.json")
        if let result = try? parseArcSidebarData(from: sidebar) {
            for space in result.spaces {
                print("  \(space.title): \(space.background.map { "\($0.colors) grain \($0.grain ?? -1) strength \($0.intensity ?? -1)" } ?? "no theme (Arc default)")")
            }
        }
        print("arc background ok")
    }
}
