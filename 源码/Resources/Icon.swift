import AppKit

// Draw the icon at each target scale without raster upsampling.
let dir = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let sizes = [
  (16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"), (128, "128x128"),
  (256, "128x128@2x"), (256, "256x256"), (512, "256x256@2x"), (512, "512x512"),
  (1024, "512x512@2x"),
]
func col(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
  NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
}
for (px, name) in sizes {
  let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  let ns = NSGraphicsContext(bitmapImageRep: rep)!
  NSGraphicsContext.current = ns
  let c = ns.cgContext
  c.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)
  let base = NSBezierPath(
    roundedRect: NSRect(x: 66, y: 66, width: 892, height: 892), xRadius: 207, yRadius: 207)
  c.saveGState()
  c.setShadow(
    offset: CGSize(width: 0, height: -12), blur: 22,
    color: NSColor.black.withAlphaComponent(0.27).cgColor)
  col(0.06, 0.2, 0.2).setFill()
  base.fill()
  c.restoreGState()
  NSGradient(colors: [col(0.055, 0.185, 0.205), col(0.09, 0.35, 0.34), col(0.17, 0.5, 0.43)])!.draw(
    in: base, angle: 60)
  NSColor.white.withAlphaComponent(0.2).setStroke()
  base.lineWidth = 3
  base.stroke()
  let hs: [CGFloat] = [118, 240, 381, 503, 364, 223, 112]
  for i in hs.indices {
    let h = hs[i]
    let x: CGFloat = 234 + CGFloat(i) * 84
    let dy = CGFloat([0, -12, -9, 0, 18, 12, 0][i])
    let bar = NSBezierPath(
      roundedRect: NSRect(x: x, y: 512 - h / 2 + dy, width: 52, height: h), xRadius: 26, yRadius: 26
    )
    NSGradient(colors: [col(0.49, 0.85, 0.72), col(0.93, 1, 0.92)])!.draw(in: bar, angle: 90)
  }
  NSGraphicsContext.restoreGraphicsState()
  try rep.representation(using: .png, properties: [:])!.write(
    to: dir.appendingPathComponent("icon_" + name + ".png"))
}
