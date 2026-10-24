// Repaints the version line in the installer window's background.
//
//   swiftc scripts/dmg/make-background.swift -o /tmp/make-background
//   /tmp/make-background <base.tiff> <version> <out.tiff>
//
// base.tiff is the 600x440 artwork with its two representations (1x and 2x). The footer line sits on
// a plain gradient with grain, so the old text is covered with rows copied from just below it, and
// the new line is drawn in the old line's colour.
import AppKit

let args = CommandLine.arguments
guard args.count == 4, let data = try? Data(contentsOf: URL(fileURLWithPath: args[1])),
      let reps = NSBitmapImageRep.imageReps(with: data) as? [NSBitmapImageRep], reps.count == 2
else { FileHandle.standardError.write(Data("usage: make-background <base.tiff> <version> <out.tiff>\n".utf8)); exit(2) }
let version = args[2]
let line = "Harbor \(version)  ·  for Macs with Apple silicon"

// The band, in 1x points from the top: the old line spans about 322 to 344.
let bandTop = 320, bandHeight = 28, centerY = 333.0

var canvases: [NSBitmapImageRep] = []
for rep in reps.sorted(by: { $0.pixelsWide < $1.pixelsWide }) {
    let s = rep.pixelsWide / 600
    let w = rep.pixelsWide, h = rep.pixelsHigh
    guard let canvas = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                        samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32)
    else { exit(1) }
    // Copy the picture, then the old line's colour: the brightest pixel in the band.
    var best = (r: 0.0, g: 0.0, b: 0.0), bestLum = -1.0
    for y in (bandTop * s)..<((bandTop + bandHeight) * s) {
        for x in 0..<w {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            let lum = Double(c.redComponent + c.greenComponent + c.blueComponent)
            if lum > bestLum { bestLum = lum; best = (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent)) }
        }
    }
    for y in 0..<h {
        // Rows inside the band come from the same number of rows below it.
        let inBand = y >= bandTop * s && y < (bandTop + bandHeight) * s
        let from = inBand ? y + bandHeight * s : y
        for x in 0..<w {
            canvas.setColor(rep.colorAt(x: x, y: from) ?? .black, atX: x, y: y)
        }
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvas)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: CGFloat(s), y: CGFloat(s))
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 11),
        .foregroundColor: NSColor(deviceRed: best.r, green: best.g, blue: best.b, alpha: 1),
        .kern: 0.2,
    ]
    let text = NSAttributedString(string: line, attributes: attrs)
    let size = text.size()
    // Drawing space is bottom-up; centerY is measured from the top.
    text.draw(at: NSPoint(x: (600 - size.width) / 2, y: 440 - centerY - size.height / 2))
    NSGraphicsContext.restoreGraphicsState()
    canvas.size = NSSize(width: 600, height: 440)  // 144 dpi for the 2x picture, so Finder shows it at 600x440
    canvases.append(canvas)
}

// One TIFF holding both pictures; Finder picks the one that fits the display.
let image = NSImage(size: NSSize(width: 600, height: 440))
canvases.forEach { image.addRepresentation($0) }
guard let out = image.tiffRepresentation(using: .lzw, factor: 1) else { exit(1) }
try out.write(to: URL(fileURLWithPath: args[3]))
