// SPDX-License-Identifier: GPL-2.0-or-later
// Draws the app icon: `xcrun swift scripts/make_icon.swift ios/Sources/Assets.xcassets/AppIcon.appiconset/icon.png`
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!

ctx.setFillColor(CGColor(colorSpace: space, components: [0.055, 0.059, 0.063, 1])!)
ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))

// Five segments on a shallow arc, tail to head, dark to light.
let radius: CGFloat = 112
let greens: [[CGFloat]] = [
    [0.22, 0.36, 0.22], [0.30, 0.47, 0.28], [0.40, 0.59, 0.35], [0.52, 0.71, 0.43], [0.66, 0.82, 0.55],
]
for (i, rgb) in greens.enumerated() {
    let t = CGFloat(i) / CGFloat(greens.count - 1)
    let x = 232 + t * 560
    let y = 512 - 92 + sin(t * .pi) * 184
    ctx.setFillColor(CGColor(colorSpace: space, components: [rgb[0], rgb[1], rgb[2], 1])!)
    ctx.fillEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
}

let url = URL(fileURLWithPath: out)
let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(out)") }
