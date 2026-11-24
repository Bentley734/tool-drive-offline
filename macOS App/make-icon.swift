import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let files = FileManager.default
let themes = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: Int, alpha: CGFloat = 1) -> CGColor {
    let channels = [16, 8, 0].map { CGFloat(hex >> $0 & 255) / 255 }
    return CGColor(colorSpace: space, components: channels + [alpha])!
}

func gradient(_ colors: [CGColor], stops: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: space, colors: colors as CFArray, locations: stops)!
}

func logoMask(alternate: Bool) throws -> CGImage {
    let file = themes.appendingPathComponent(alternate ? "tool-logo-2006.png" : "tool-logo.svg")
    var data = try Data(contentsOf: file)
    if !alternate {
        // Give the scalable mark explicit raster dimensions while preserving its original viewBox.
        let svg = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "<svg ", with: "<svg width=\"1424\" height=\"568\" ")
        data = Data(svg.utf8)
    }
    guard let image = NSImage(data: data),
          let mask = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        throw CocoaError(.fileReadCorruptFile)
    }
    return mask
}

func render(_ size: Int, mask: CGImage, alternate: Bool) -> CGImage {
    let c = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                      bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let scale = CGFloat(size) / 1024
    c.scaleBy(x: scale, y: scale)
    c.interpolationQuality = .high
    let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: plate, cornerWidth: 184, cornerHeight: 184, transform: nil)
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -9 * scale), blur: 16 * scale, color: rgb(0, alpha: 0.4))
    c.addPath(shape)
    c.setFillColor(rgb(0x131518))
    c.fillPath()
    c.restoreGState()
    c.addPath(shape)
    c.clip()

    let plateColors = alternate ? [0x39434d, 0x202730, 0x11151b] : [0x48423b, 0x242420, 0x161817]
    c.drawLinearGradient(gradient(plateColors.map { rgb($0) }), start: CGPoint(x: 250, y: 924),
                         end: CGPoint(x: 640, y: 90), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

    // Offset grooves skim the face of the plate like the runout of a record.
    let grooveCenter = CGPoint(x: 340, y: 628)
    if size >= 32 {
        c.setLineWidth(size < 64 ? 7 : 2.6)
        let radii = size < 64 ? [265, 355, 445, 535] : [248, 257, 266, 341, 350, 359, 434, 443, 452, 527, 536, 545, 620, 629, 638]
        for radius in radii {
            let r = CGFloat(radius)
            let ring = CGRect(x: grooveCenter.x - r, y: grooveCenter.y - r, width: 2*r, height: 2*r)
            c.setStrokeColor(rgb(alternate ? 0xafe1f9 : 0xffdeac, alpha: 0.10))
            c.strokeEllipse(in: ring)
        }
    }
    let halo = gradient([rgb(0x060707, alpha: 0.68), rgb(0x060707, alpha: 0)])
    c.drawRadialGradient(halo, startCenter: CGPoint(x: 512, y: 480), startRadius: 58,
                         endCenter: CGPoint(x: 512, y: 480), endRadius: 430, options: [])

    let width: CGFloat = size <= 32 ? 745 : 694
    let height = width * CGFloat(mask.height) / CGFloat(mask.width)
    let mark = CGRect(x: (1024-width)/2, y: (1024-height)/2 + (alternate ? 0 : 8),
                      width: width, height: height)
    c.saveGState()
    c.clip(to: mark.offsetBy(dx: 0, dy: -6), mask: mask)
    c.setFillColor(rgb(0x07090a))
    c.fill(mark.insetBy(dx: -10, dy: -10))
    c.restoreGState()
    c.saveGState()
    c.clip(to: mark, mask: mask)
    let metal = alternate ? [0xfafcfd, 0xe5edef, 0xbecbd4, 0x95acba] : [0xfff8e3, 0xf4e6cd, 0xe0cba9, 0xbda67d]
    c.drawLinearGradient(gradient(metal.map { rgb($0) }, stops: [0, 0.44, 0.72, 1]),
                         start: CGPoint(x: mark.midX, y: mark.maxY), end: CGPoint(x: mark.midX, y: mark.minY),
                         options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    c.restoreGState()

    c.setLineWidth(size >= 128 ? 6 : 12)
    c.addPath(shape)
    c.setStrokeColor(rgb(0xffffff, alpha: 0.18))
    c.strokePath()
    return c.makeImage()!
}

let names = [16: ["icon_16x16"], 32: ["icon_16x16@2x", "icon_32x32"],
             64: ["icon_32x32@2x"], 128: ["icon_128x128"],
             256: ["icon_128x128@2x", "icon_256x256"], 512: ["icon_256x256@2x", "icon_512x512"],
             1024: ["icon_512x512@2x"]]

for alternate in [false, true] {
    let mask = try logoMask(alternate: alternate)
    let directory = output.appendingPathComponent(alternate ? "AppIcon2006.iconset" : "AppIcon.iconset")
    try files.createDirectory(at: directory, withIntermediateDirectories: true)
    for (size, filenames) in names {
        let image = render(size, mask: mask, alternate: alternate)
        for name in filenames {
            let url = directory.appendingPathComponent(name + ".png") as CFURL
            guard let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            CGImageDestinationAddImage(dest, image, nil)
            guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
        }
    }
}
