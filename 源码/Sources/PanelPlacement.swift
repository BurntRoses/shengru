import AppKit

// Quartz uses the primary display's top-left origin; AppKit uses its bottom-left.
// Read bounds and layers only. No screen capture, window titles or extra permission.
final class PanelSpace {
  private var sampled = -Double.infinity, covers: [CGRect] = []
  func invalidate() { sampled = -.infinity }
  func area(on screen:NSScreen) -> CGRect {
    let now = ProcessInfo.processInfo.systemUptime
    if now - sampled > 0.7 {
      sampled=now
      let info=CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements], kCGNullWindowID) as? [[String:Any]] ?? []
      covers=info.compactMap { item in
        guard item[kCGWindowLayer as String] as? Int == 0,
              (item[kCGWindowAlpha as String] as? Double ?? 1)>0,
              let b=item[kCGWindowBounds as String] as? [String:CGFloat],
              let x=b["X"],let y=b["Y"],let w=b["Width"],let h=b["Height"] else {return nil}
        return CGRect(x:x,y:y,width:w,height:h)
      }
    }
    let f=screen.frame, top=NSScreen.screens.first?.frame.maxY ?? f.maxY
    let bounds=CGRect(x:f.minX,y:top-f.maxY,width:f.width,height:f.height)
    // A native fullscreen window on a notched Mac can start *below* its camera/menu strip.
    // visibleFrame can still reserve the desktop Dock in another app’s fullscreen Space.
    let strip=max(screen.safeAreaInsets.top,f.maxY-screen.visibleFrame.maxY)
    let covering=covers.contains { w in
      abs(w.minX-bounds.minX)<=2 && abs(w.maxX-bounds.maxX)<=2 && abs(w.maxY-bounds.maxY)<=2
        && w.minY >= bounds.minY-2 && w.minY <= bounds.minY+strip+2
    }
    let full=covering || (NSScreen.screens.count == 1 && NSApp.currentSystemPresentationOptions.contains(.fullScreen))
    guard full else { return screen.visibleFrame }
    let i=screen.safeAreaInsets
    return CGRect(x:f.minX+i.left,y:f.minY+i.bottom,width:f.width-i.left-i.right,height:f.height-i.top-i.bottom)
  }
  static func key(_ screen:NSScreen,_ placement:Placement) -> String {
    let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    let display = CGDisplayCreateUUIDFromDisplayID(id).map { CFUUIDCreateString(nil,$0.takeRetainedValue()) as String } ?? String(id)
    return display + (placement == .top ? ".top" : ".bottom")
  }
}

enum PanelPlacement {
  static func usable(_ area:CGRect)->CGRect { area.insetBy(dx:min(6,area.width/4),dy:min(6,area.height/4)) }
  static func fitted(_ origin:CGPoint,size:CGSize,in area:CGRect)->CGRect {
    let box=usable(area), w=min(size.width,box.width), h=min(size.height,box.height)
    return CGRect(x:min(max(origin.x.rounded(),box.minX),box.maxX-w),y:min(max(origin.y.rounded(),box.minY),box.maxY-h),width:w,height:h)
  }
  static func anchor(_ rect:CGRect,in area:CGRect)->CapsuleAppearance.Anchor {
    let b=usable(area)
    func unit(_ v:CGFloat,_ room:CGFloat)->Double { room>0 ? min(1,max(0,v/room)) : 0.5 }
    return .init(x:unit(rect.minX-b.minX,b.width-rect.width),y:unit(rect.minY-b.minY,b.height-rect.height))
  }
  static func frame(_ size:CGSize,in area:CGRect,placement:Placement,anchor:CapsuleAppearance.Anchor?)->CGRect {
    let b=usable(area); let o:CGPoint
    if let a=anchor { o=CGPoint(x:b.minX+a.x*max(0,b.width-size.width),y:b.minY+a.y*max(0,b.height-size.height)) }
    else if placement == .top { o=CGPoint(x:area.maxX-size.width-22,y:area.maxY-size.height-22) }
    else { o=CGPoint(x:area.midX-size.width/2,y:area.minY+18) }
    return fitted(o,size:size,in:area)
  }
}
