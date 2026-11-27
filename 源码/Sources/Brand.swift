import AppKit
import SwiftUI

// Paired quotation marks: a spoken phrase becoming type. The same silhouettes resolve
// at menu-bar size and on the glazed application tile; no separate miniature bitmap.
enum BrandArtwork {
  private static func mark(_ c: CGContext) {
    for (x,y) in [(CGFloat(22),CGFloat(33)),(CGFloat(52),CGFloat(28))] {
      c.saveGState(); c.translateBy(x:x,y:y)
      c.beginPath(); c.move(to:CGPoint(x:12,y:0))
      c.addCurve(to:CGPoint(x:24,y:13),control1:CGPoint(x:20,y:0),control2:CGPoint(x:24,y:5))
      c.addCurve(to:CGPoint(x:4,y:41),control1:CGPoint(x:24,y:25),control2:CGPoint(x:15,y:36))
      c.addQuadCurve(to:CGPoint(x:1,y:37),control:CGPoint(x:-1,y:42))
      c.addQuadCurve(to:CGPoint(x:10,y:23),control:CGPoint(x:8,y:29))
      c.addCurve(to:CGPoint(x:0,y:12),control1:CGPoint(x:4,y:23),control2:CGPoint(x:0,y:18))
      c.addQuadCurve(to:CGPoint(x:12,y:0),control:CGPoint(x:0,y:0)); c.closePath(); c.fillPath(); c.restoreGState()
    }
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
    let glaze=CGGradient(colorsSpace:space,colors:[ink(0.28,0.65,0.55),ink(0.055,0.39,0.36),ink(0.03,0.18,0.24)] as CFArray,locations:[0,0.52,1])!
    c.drawLinearGradient(glaze,start:.init(x:22,y:5),end:.init(x:76,y:94),options:[.drawsBeforeStartLocation,.drawsAfterEndLocation])
    let sheen=CGGradient(colorsSpace:space,colors:[ink(0.88,1,0.91,0.19),ink(0.75,0.98,0.89,0)] as CFArray,locations:nil)!
    c.drawRadialGradient(sheen,startCenter:.init(x:22,y:9),startRadius:0,endCenter:.init(x:22,y:9),endRadius:65,options:[])
    c.addPath(face); c.setStrokeColor(ink(0.90,1,0.94,0.22)); c.setLineWidth(0.85); c.strokePath()
    c.translateBy(x:0,y:1); c.setFillColor(ink(0.02,0.19,0.17,0.38)); mark(c)
    c.translateBy(x:0,y:-1); c.setFillColor(ink(0.98,1,0.92)); mark(c)
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
      let s:CGFloat = recording ? 0.225 : 0.275
      c.translateBy(x:rect.midX-50.5*s,y:rect.midY-48.5*s); c.scaleBy(x:s,y:s)
      c.setFillColor(NSColor.black.cgColor); mark(c); return true
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
