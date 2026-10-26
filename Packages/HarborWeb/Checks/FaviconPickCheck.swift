// Compiled on its own: swiftc Sources/HarborWeb/FaviconPick.swift Checks/FaviconPickCheck.swift -o /tmp/x && /tmp/x
import Foundation

@main
struct FaviconPickCheck {
    static func candidate(_ path: String, sizes: String = "", type: String = "", media: String = "", rel: String = "icon") -> FaviconCandidate {
        FaviconCandidate(url: URL(string: "https://example.com\(path)")!, sizes: sizes, type: type, media: media, rel: rel)
    }

    static func main() {
        // getbb.app's own markup: light and dark icons at two sizes, and a touch icon.
        let page = [
            candidate("/favicon-32x32.png", sizes: "32x32", type: "image/png", media: "(prefers-color-scheme: light)"),
            candidate("/favicon-32x32-dark.png", sizes: "32x32", type: "image/png", media: "(prefers-color-scheme: dark)"),
            candidate("/favicon-16x16.png", sizes: "16x16", type: "image/png", media: "(prefers-color-scheme: light)"),
            candidate("/favicon-16x16-dark.png", sizes: "16x16", type: "image/png", media: "(prefers-color-scheme: dark)"),
            candidate("/apple-touch-icon.png", sizes: "180x180", rel: "apple-touch-icon"),
        ]
        let dark = FaviconPick.order(page, preferDark: true).map(\.url.path)
        precondition(dark.first == "/favicon-32x32-dark.png", "a dark sidebar takes the dark 32 pixel icon, got \(dark)")
        precondition(dark.last == "/favicon-16x16.png" || dark.last == "/favicon-32x32.png", "the light variants come last on dark, got \(dark)")
        let light = FaviconPick.order(page, preferDark: false).map(\.url.path)
        precondition(light.first == "/favicon-32x32.png", "a light sidebar takes the light 32 pixel icon, got \(light)")

        // A vector icon is good at any size, and beats a 16 pixel bitmap.
        let mixed = [candidate("/small.png", sizes: "16x16"), candidate("/icon.svg", type: "image/svg+xml")]
        precondition(FaviconPick.order(mixed, preferDark: false).first?.url.path == "/icon.svg")

        // An undeclared size reads as the old 32 pixel icon; the same URL is tried once.
        let repeated = [candidate("/a.ico"), candidate("/a.ico"), candidate("/b.png", sizes: "512x512")]
        let order = FaviconPick.order(repeated, preferDark: false).map(\.url.path)
        precondition(order == ["/a.ico", "/b.png"], "got \(order)")
        print("FaviconPickCheck passed")
    }
}
