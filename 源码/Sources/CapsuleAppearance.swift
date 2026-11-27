import SwiftUI

// Paint and geometry are saved as one preference so resetting the panel cannot touch dictation or history.
enum CapsulePalette: String, CaseIterable, Codable {
  case porcelain, celadon, coast, wisteria, apricot, midnight
  var title: String { switch self {
  case .porcelain: return "云白"; case .celadon: return "青瓷"; case .coast: return "潮蓝"
  case .wisteria: return "藤紫"; case .apricot: return "杏茶"; case .midnight: return "墨夜" } }
  struct Inks {
    let base, edge, bloom, accent, swatch: Color
    init(_ a: Int, _ b: Int, _ c: Int, _ d: Int, _ e: Int) {
      func color(_ n: Int) -> Color { Color(.sRGB, red: Double(n >> 16)/255, green: Double((n >> 8) & 255)/255, blue: Double(n & 255)/255, opacity: 1) }
      (base,edge,bloom,accent,swatch) = (color(a),color(b),color(c),color(d),color(e))
    }
  }
  func inks(_ scheme: ColorScheme) -> Inks {
    switch (self,scheme == .dark) {
    case (.porcelain,false): return Inks(0xEFF1EC,0xD9E3E0,0xFFF9EA,0x405B53,0xCAD2CC)
    case (.porcelain,true): return Inks(0x272E30,0x34403E,0x464337,0xC9E0D5,0xA5B1AC)
    case (.celadon,false): return Inks(0xE1F1E9,0xAED8CA,0xFFF2CF,0x165F50,0x7BBCA7)
    case (.celadon,true): return Inks(0x183930,0x22534C,0x4D5133,0xA3ECCF,0x78BCA3)
    case (.coast,false): return Inks(0xE2F0F9,0xA8C8E6,0xC2EFEB,0x245674,0x81ACD3)
    case (.coast,true): return Inks(0x1D3049,0x2C4863,0x204E53,0xACDFFF,0x83ACD1)
    case (.wisteria,false): return Inks(0xEFE7F5,0xC9B8DF,0xF4DDD9,0x654681,0xB092CA)
    case (.wisteria,true): return Inks(0x322740,0x4C3A5D,0x534049,0xE5C8FF,0xAF95C8)
    case (.apricot,false): return Inks(0xFAECDC,0xE7BEAD,0xFAE4B6,0x88492A,0xD79C7B)
    case (.apricot,true): return Inks(0x3D2D28,0x594034,0x53492E,0xFFD0A9,0xD8A086)
    case (.midnight,_): return Inks(0x1E2939,0x304255,0x354447,0xC2DDF4,0x34475B)
    }
  }
}
enum CapsuleWash: String, CaseIterable, Codable {
  case flat = "单色", slant = "斜渐变", halo = "晕染"
}
struct CapsuleAppearance: Codable, Equatable {
  var palette: CapsulePalette = .celadon
  var wash: CapsuleWash = .halo
  var material: MaterialChoice = .frost
  var position: Placement = .bottom
  // A fraction of the available travel, not the screen centre: a bottom-aligned panel grows upwards.
  struct Anchor: Codable, Equatable { let x,y:Double }
  var anchors: [String:Anchor] = [:]
  var width = 472.0, typeSize = 17.0, radius = 25.0, opacity = 0.62, hideDelay = 1.25
  var review = true, animate = true, waveform = true, light = true, shimmer = true
  init() {}
  init(from decoder: Decoder) throws {
    self.init(); let c = try decoder.container(keyedBy: CodingKeys.self)
    func read<T: Decodable>(_ k: CodingKeys, _ fallback: T) -> T { (try? c.decode(T.self, forKey:k)) ?? fallback }
    func number(_ k: CodingKeys, _ fallback: Double, _ range: ClosedRange<Double>) -> Double { min(range.upperBound,max(range.lowerBound,read(k,fallback))) }
    palette=read(.palette,palette); wash=read(.wash,wash); material=read(.material,material); position=read(.position,position)
    anchors=read(.anchors,anchors).filter { (0...1).contains($0.value.x) && (0...1).contains($0.value.y) }
    if #unavailable(macOS 26), material == .glass { material = .frost }
    width=number(.width,width,340...640); typeSize=number(.typeSize,typeSize,13...24); radius=number(.radius,radius,12...30)
    opacity=number(.opacity,opacity,0...1); hideDelay=number(.hideDelay,hideDelay,0.5...3)
    review=read(.review,review); animate=read(.animate,animate); waveform=read(.waveform,waveform); light=read(.light,light); shimmer=read(.shimmer,shimmer)
  }
}
struct CapsulePaint: View {
  let inks: CapsulePalette.Inks, wash: CapsuleWash
  let moves: Bool
  var body: some View {
    switch wash {
    case .flat: inks.base
    case .slant: LinearGradient(colors:[inks.edge,inks.base,inks.bloom],startPoint:.topLeading,endPoint:.bottomTrailing)
    case .halo:
      if moves {
        TimelineView(.animation(minimumInterval:1/12)) { frame in
          halo(frame.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy:24) * (.pi/12))
        }
      } else { halo(0) }
    }
  }
  private func halo(_ t: Double) -> some View {
    ZStack {
      inks.base
      EllipticalGradient(colors:[inks.swatch,inks.edge.opacity(0.82),.clear],center:UnitPoint(x:0.34+0.23*sin(t),y:0.98+0.08*cos(t)),startRadiusFraction:0.02,endRadiusFraction:0.82)
      EllipticalGradient(colors:[inks.bloom,.clear],center:UnitPoint(x:0.70+0.21*cos(t),y:1.02-0.08*sin(t)),startRadiusFraction:0.05,endRadiusFraction:0.67)
    }
  }
}
