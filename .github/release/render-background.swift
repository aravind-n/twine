// Maintenance only: swift .github/release/render-background.swift
// AppKit renders the SVG into a multi-resolution TIFF for Finder.
import AppKit

let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let source = folder.appendingPathComponent("installer-background.svg")
let destination = folder.appendingPathComponent("installer-background.tiff")
guard let image = NSImage(contentsOf: source) else {
  fatalError("Cannot read installer-background.svg")
}
let size = image.size
var representations: [NSBitmapImageRep] = []
for scale in [1, 2] {
  guard
    let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: Int(size.width) * scale,
      pixelsHigh: Int(size.height) * scale,
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap)
  else {
    fatalError("Cannot create background bitmap")
  }
  bitmap.size = size
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = context
  context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
  image.draw(
    in: CGRect(origin: .zero, size: size), from: .zero,
    operation: .copy, fraction: 1)
  NSGraphicsContext.restoreGraphicsState()
  representations.append(bitmap)
}
guard
  let data = NSBitmapImageRep.tiffRepresentationOfImageReps(
    in: representations, using: .lzw, factor: 1)
else {
  fatalError("Cannot encode Finder background")
}
try data.write(to: destination)
print("Wrote \(destination.lastPathComponent) with 1× and 2× representations")
