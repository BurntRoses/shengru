import AppKit
import SwiftUI

// Five pulses, one silhouette. At menu and Finder sizes each edge is fitted to the pixel grid.
enum BrandArtwork {
  private static let pulses: [(CGFloat,CGFloat)] = [(0.43,0.65),(0.20,0.75),(0,1),(0.33,0.86),(0.42,0.66)]
  private static func mark(_ c: CGContext, in box: CGRect, weight: CGFloat, pixel:CGFloat) {
    func snap(_ n:CGFloat)->CGFloat { (n/pixel).rounded()*pixel }
    let stroke=max(pixel,snap(weight)), step=(box.width-stroke)/4
    for (i,p) in pulses.enumerated() {
      let top=snap(box.minY+box.height*p.0), bottom=snap(box.minY+box.height*p.1)
      let r=CGRect(x:snap(box.minX+CGFloat(i)*step),y:top,width:stroke,height:max(stroke,bottom-top))
      c.addPath(CGPath(roundedRect:r,cornerWidth:stroke/2,cornerHeight:stroke/2,transform:nil));c.fillPath()
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
    let box=CGRect(x:21,y:23,width:58,height:54), pixel=100/max(extent,1)
    c.setFillColor(ink(0.98,1,0.94)); mark(c,in:box,weight:7.3,pixel:pixel)
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
      let box=recording ? CGRect(x:3,y:2.5,width:15,height:13) : CGRect(x:1,y:1,width:19,height:16)
      let pixel=1/max(1,abs(c.ctm.a)); c.setFillColor(NSColor.black.cgColor)
      mark(c,in:box,weight:recording ? 1.8 : 2.15,pixel:pixel); return true
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
