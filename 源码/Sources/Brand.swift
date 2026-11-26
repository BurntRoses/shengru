import AppKit
import SwiftUI

// One master stroke for the application icon, the in-app badge and the menu-bar template.
// Coordinates below are in a 100-unit, top-left canvas; the nib ends on the writing line.
enum BrandArtwork {
  private static func stroke(_ c: CGContext, width: CGFloat) {
    c.setLineWidth(width); c.setLineCap(.round); c.setLineJoin(.round)
    c.beginPath(); c.move(to: CGPoint(x:20, y:56))
    c.addCurve(to: .init(x:40, y:24), control1: .init(x:29, y:56), control2: .init(x:32, y:24))
    c.addCurve(to: .init(x:49, y:73), control1: .init(x:48, y:24), control2: .init(x:41, y:73))
    c.addCurve(to: .init(x:64, y:47), control1: .init(x:56, y:73), control2: .init(x:58, y:47))
    c.addCurve(to: .init(x:74, y:59), control1: .init(x:69, y:47), control2: .init(x:66, y:59))
    c.addLine(to: .init(x:81, y:59)); c.strokePath()
  }
  private static let space = CGColorSpace(name:CGColorSpace.sRGB)!
  private static func ink(_ r:CGFloat,_ g:CGFloat,_ b:CGFloat,_ alpha:CGFloat = 1)->CGColor {
    CGColor(colorSpace:space,components:[r,g,b,alpha])!
  }
  static func tile(_ c: CGContext, extent: CGFloat) {
    c.saveGState(); defer { c.restoreGState() }
    c.translateBy(x:0,y:extent); c.scaleBy(x:extent/100,y:-extent/100)
    let face = CGPath(roundedRect:CGRect(x:6.5,y:6.5,width:87,height:87),cornerWidth:20,cornerHeight:20,transform:nil)
    c.saveGState(); c.setShadow(offset:CGSize(width:0,height:-extent*0.012),blur:extent*0.024,color:ink(0.01,0.12,0.11,0.27)); c.setFillColor(ink(0.06,0.26,0.25)); c.addPath(face); c.fillPath(); c.restoreGState()
    c.addPath(face); c.clip()
    let glaze=CGGradient(colorsSpace:space,colors:[ink(0.28,0.64,0.53),ink(0.075,0.40,0.35),ink(0.035,0.22,0.24)] as CFArray,locations:[0,0.52,1])!
    c.drawLinearGradient(glaze,start:.init(x:22,y:5),end:.init(x:76,y:94),options:[.drawsBeforeStartLocation,.drawsAfterEndLocation])
    let sheen=CGGradient(colorsSpace:space,colors:[ink(0.88,1,0.91,0.19),ink(0.75,0.98,0.89,0)] as CFArray,locations:nil)!
    c.drawRadialGradient(sheen,startCenter:.init(x:22,y:9),startRadius:0,endCenter:.init(x:22,y:9),endRadius:65,options:[])
    c.addPath(face); c.setStrokeColor(ink(0.90,1,0.94,0.22)); c.setLineWidth(0.85); c.strokePath()
    c.translateBy(x:0,y:1); c.setStrokeColor(ink(0.02,0.19,0.17,0.38)); stroke(c,width:7)
    c.translateBy(x:0,y:-1); c.setStrokeColor(ink(0.97,1,0.91)); stroke(c,width:6.7)
  }
  static let badge = NSImage(size:.init(width:64,height:64),flipped:false) { rect in
    guard let c=NSGraphicsContext.current?.cgContext else {return false}; tile(c,extent:rect.width); return true
  }
  static let menuIdle = template(false), menuRecording = template(true)
  private static func template(_ recording:Bool)->NSImage {
    let image=NSImage(size:.init(width:21,height:18),flipped:true) { rect in
      guard let c=NSGraphicsContext.current?.cgContext else {return false}
      c.saveGState(); defer {c.restoreGState()}
      if recording {
        c.setFillColor(NSColor.black.cgColor); c.addPath(CGPath(roundedRect:rect.insetBy(dx:0.5,dy:0.6),cornerWidth:5,cornerHeight:5,transform:nil)); c.fillPath(); c.setBlendMode(.clear)
      }
      let s:CGFloat = recording ? 0.225 : 0.284
      c.translateBy(x:rect.midX-50.5*s,y:rect.midY-48.5*s); c.scaleBy(x:s,y:s)
      c.setStrokeColor(NSColor.black.cgColor); stroke(c,width:recording ? 8 : 7.6); return true
    }; image.isTemplate=true; return image
  }
}

struct BrandBadge: View {
  let size: CGFloat
  var body: some View {
    Image(nsImage: BrandArtwork.badge)
      .resizable().interpolation(.high).frame(width: size, height: size)
      .accessibilityHidden(true)
  }
}
