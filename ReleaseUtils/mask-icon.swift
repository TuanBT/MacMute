#!/usr/bin/env swift
// Turns a flat source render (a full-bleed square JPEG/PNG sitting on an opaque, usually
// white, background) into a proper macOS icon master: background knocked out, artwork
// trimmed, scaled onto Apple's 824-in-1024 grid and clipped to a rounded tile.
//
//   swift ReleaseUtils/mask-icon.swift <source> <destination.png>
//
// The knockout matters: the render's own rounded corners rarely match the mask exactly,
// so without it a sliver of the white background survives along the corner arcs.

import AppKit

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write("usage: mask-icon.swift <source> <destination.png>\n".data(using: .utf8)!)
    exit(2)
}

let canvas = 1024           // final icon size
let content = 824           // Apple's artwork box inside that canvas
let radius = CGFloat(content) * 0.2237
let bleed: CGFloat = 1.02   // draw the tile slightly oversized so the mask cuts inside it
let tolerance = 46          // how far a pixel may drift from the background colour
let halo = 3                // extra passes that eat the anti-aliased background fringe

guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    FileHandle.standardError.write("cannot read \(args[1])\n".data(using: .utf8)!)
    exit(1)
}

// MARK: - Read the render into a buffer

let w = image.width, h = image.height
// Owned storage: a CGContext built from an inout Swift array only borrows that buffer
// for the duration of the call, so edits made afterwards would be lost.
let pixels = UnsafeMutablePointer<UInt8>.allocate(capacity: w * h * 4)
pixels.initialize(repeating: 0, count: w * h * 4)
defer { pixels.deallocate() }

guard let readCtx = CGContext(data: pixels, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    FileHandle.standardError.write("cannot create read context\n".data(using: .utf8)!)
    exit(1)
}
readCtx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

@inline(__always) func offset(_ x: Int, _ y: Int) -> Int { (y * w + x) * 4 }

let bg = (Int(pixels[0]), Int(pixels[1]), Int(pixels[2]))
@inline(__always) func distanceToBackground(_ i: Int) -> Int {
    max(abs(Int(pixels[i]) - bg.0), abs(Int(pixels[i + 1]) - bg.1), abs(Int(pixels[i + 2]) - bg.2))
}

// MARK: - Knock the background out, starting from the border

var cleared = [Bool](repeating: false, count: w * h)
var stack: [Int] = []
for x in 0..<w { stack.append(x); stack.append((h - 1) * w + x) }
for y in 0..<h { stack.append(y * w); stack.append(y * w + w - 1) }

while let index = stack.popLast() {
    if cleared[index] { continue }
    let i = index * 4
    guard pixels[i + 3] < 8 || distanceToBackground(i) <= tolerance else { continue }
    cleared[index] = true
    // Premultiplied buffer: leaving white behind a zero alpha lets the scaler smear it
    // back out as a pale fringe, so wipe the colour too.
    pixels[i] = 0; pixels[i + 1] = 0; pixels[i + 2] = 0; pixels[i + 3] = 0
    let x = index % w, y = index / w
    if x > 0 { stack.append(index - 1) }
    if x < w - 1 { stack.append(index + 1) }
    if y > 0 { stack.append(index - w) }
    if y < h - 1 { stack.append(index + w) }
}

// The flood fill stops at the anti-aliased ring where the background fades into the
// artwork. Peel that ring off too, otherwise it survives as a pale outline.
for _ in 0..<halo {
    var fringe: [Int] = []
    for index in 0..<(w * h) where !cleared[index] {
        let x = index % w, y = index / w
        let touchesCleared = (x > 0 && cleared[index - 1]) || (x < w - 1 && cleared[index + 1])
            || (y > 0 && cleared[index - w]) || (y < h - 1 && cleared[index + w])
        if touchesCleared && distanceToBackground(index * 4) <= tolerance * 3 { fringe.append(index) }
    }
    if fringe.isEmpty { break }
    for index in fringe {
        cleared[index] = true
        let i = index * 4
        pixels[i] = 0; pixels[i + 1] = 0; pixels[i + 2] = 0; pixels[i + 3] = 0
    }
}

// MARK: - Trim to what is left

var minX = w, minY = h, maxX = -1, maxY = -1
for index in 0..<(w * h) where pixels[index * 4 + 3] > 8 {
    let x = index % w, y = index / w
    if x < minX { minX = x }
    if x > maxX { maxX = x }
    if y < minY { minY = y }
    if y > maxY { maxY = y }
}
guard maxX >= minX, maxY >= minY else {
    FileHandle.standardError.write("nothing left after removing the background\n".data(using: .utf8)!)
    exit(1)
}
// Keep it square so nothing is stretched.
let side = max(maxX - minX, maxY - minY) + 1
let cx = (minX + maxX) / 2, cy = (minY + maxY) / 2
let bounds = CGRect(x: CGFloat(cx) - CGFloat(side) / 2, y: CGFloat(cy) - CGFloat(side) / 2,
                    width: CGFloat(side), height: CGFloat(side))
    .intersection(CGRect(x: 0, y: 0, width: w, height: h))

guard let knockedOut = readCtx.makeImage(), let cropped = knockedOut.cropping(to: bounds) else {
    FileHandle.standardError.write("cannot crop the artwork\n".data(using: .utf8)!)
    exit(1)
}

// MARK: - Compose the icon

guard let out = CGContext(data: nil, width: canvas, height: canvas, bitsPerComponent: 8,
                          bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    FileHandle.standardError.write("cannot create output context\n".data(using: .utf8)!)
    exit(1)
}
out.interpolationQuality = .high

let inset = CGFloat(canvas - content) / 2
let tile = CGRect(x: inset, y: inset, width: CGFloat(content), height: CGFloat(content))
out.addPath(CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil))
out.clip()
out.draw(cropped, in: tile.insetBy(dx: -tile.width * (bleed - 1) / 2,
                                   dy: -tile.height * (bleed - 1) / 2))

guard let result = out.makeImage(),
      let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL,
                                                 "public.png" as CFString, 1, nil) else {
    FileHandle.standardError.write("cannot write \(args[2])\n".data(using: .utf8)!)
    exit(1)
}
CGImageDestinationAddImage(dest, result, nil)
guard CGImageDestinationFinalize(dest) else { exit(1) }
let removed = cleared.filter { $0 }.count
print("==> \(args[2]) (background removed \(removed * 100 / (w * h))%, artwork \(Int(bounds.width))px, tile \(content)/\(canvas))")
