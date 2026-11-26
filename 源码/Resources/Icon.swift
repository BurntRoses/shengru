import AppKit

// Built alongside Sources/Brand.swift so Finder and the menu bar never use separate artwork.
@main enum IconExport {
  static func main() throws {
    let dir=URL(fileURLWithPath:CommandLine.arguments[1]); try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
    for points in [16,32,128,256,512] { for scale in [1,2] {
      let px=points*scale
      let rep=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:px,pixelsHigh:px,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
      let context=NSGraphicsContext(bitmapImageRep:rep)!; BrandArtwork.tile(context.cgContext,extent:CGFloat(px)); context.flushGraphics()
      let name="icon_\(points)x\(points)"+(scale == 1 ? "" : "@2x")+".png"
      try rep.representation(using:.png,properties:[:])!.write(to:dir.appendingPathComponent(name))
    } }
  }
}
