import AppKit
import SwiftUI

struct PanelStudio: View {
  @ObservedObject var d: Desk
  @Environment(\.colorScheme) private var scheme
  @LocalState private var dimensions = false
  @LocalState private var effects = false
  private var look: CapsuleAppearance { d.options.appearance }
  var body: some View {
    GeometryReader { geo in
      if geo.size.height >= 402 {
        VStack(spacing:12) { preview(height:122); ScrollView { controls }.scrollIndicators(.automatic) }
      } else {
        ScrollView { VStack(spacing:12) { preview(height:104); controls } }
      }
    }
  }
  private func preview(height: CGFloat) -> some View {
    VStack(spacing:0) {
      HStack {
        PanelTitle(title:"实时预览"); Spacer()
        Button { d.previewing.toggle() } label: { Label(d.previewing ? "收起屏幕预览" : "在屏幕上预览", systemImage:d.previewing ? "rectangle.inset.filled" : "macwindow") }
          .deskAction().disabled(d.phase != .idle && !d.previewing)
      }.padding(.horizontal,Layout.inset).padding(.top,8)
      GeometryReader { g in
        // A fixed scale for the available viewport keeps all width changes visible, even in a narrow window.
        let scale = min(1,max(1,g.size.width-32)/640)
        let h = CapsuleMetrics.transcriptHeight("明天下午开会，请带上合同。", width:look.width, size:look.typeSize)
        CapsuleView(desk:d,sample:true).frame(width:look.width,height:h).shadow(color:.black.opacity(0.13),radius:5,y:2)
          .scaleEffect(scale).frame(width:g.size.width,height:g.size.height)
          .accessibilityElement(children:.ignore).accessibilityLabel("悬浮窗预览，\(look.palette.title)，\(look.wash.rawValue)，宽 \(Int(look.width)) 点")
      }
    }.frame(height:height + 26).background { PreviewPaper(dark:scheme == .dark) }.clipShape(RoundedRectangle(cornerRadius:Layout.card))
  }
  private var controls: some View {
    VStack(alignment:.leading,spacing:10) {
      Surface(inset:Layout.inset,spacing:8) {
        HStack { PanelTitle(title:"配色"); Spacer(); Button("恢复默认") { d.restorePanel() }.deskAction().disabled(look == CapsuleAppearance()).help("恢复悬浮窗的配色、位置、尺寸和动效") }
        HStack(spacing:4) {
          ForEach(CapsulePalette.allCases,id:\.self) { p in
            let paint = p.inks(scheme), selected = look.palette == p
            Button { d.options.appearance.palette = p } label: {
              VStack(spacing:5) {
                Capsule().fill(LinearGradient(colors:[paint.swatch,paint.edge],startPoint:.leading,endPoint:.trailing))
                  .frame(height:22).overlay { if selected { Image(systemName:"checkmark").font(.system(size:11,weight:.bold)).foregroundStyle(p == .midnight || scheme == .dark ? .white : .black.opacity(0.80)) } }
                Text(p.title).font(.system(size:12,weight:selected ? .semibold : .regular)).foregroundStyle(.primary).fixedSize()
              }.padding(.vertical,5).padding(.horizontal,5).frame(maxWidth:.infinity).contentShape(Rectangle())
            }.buttonStyle(RowSurface(selected:selected,radius:9)).keyCue(9).accessibilityLabel(p.title).accessibilityAddTraits(selected ? .isSelected : [])
          }
        }
        Divider(); segment("着色", $d.options.appearance.wash, CapsuleWash.allCases) { $0.rawValue }
        segment("材质", $d.options.appearance.material, materials) { $0 == .solid ? "不透明" : $0.rawValue }
        if look.material == .solid {
          slider("底色浓度", $d.options.appearance.opacity,0...1,0.01,"%")
        } else {
          slider("通透度", Binding(get:{1-d.options.appearance.opacity},set:{d.options.appearance.opacity=1-$0}),0...1,0.01,"%")
        }
      }
      fold("大小与位置", symbol:"arrow.up.left.and.arrow.down.right", summary:"\(Int(look.width)) pt · \(look.position.rawValue)", isOpen:$dimensions) {
        segment("位置", $d.options.appearance.position, Placement.allCases) { $0.rawValue }
        row("自定位置") {
          Button("拖动定位") { d.previewing = true }.deskAction().disabled(d.phase != .idle).help("拖动屏幕上悬浮窗顶部的横条，松开保存位置")
          Button("还原位置") { d.options.appearance.anchors.removeAll() }.deskAction().disabled(look.anchors.isEmpty)
        }
        slider("宽度", $d.options.appearance.width,340...640,2,"pt")
        slider("字号", $d.options.appearance.typeSize,13...24,1,"pt")
        slider("圆角", $d.options.appearance.radius,12...30,1,"pt")
      }
      fold("动效与停留", symbol:"waveform", summary:look.animate ? "动效已开" : "动效已关", isOpen:$effects) {
        toggle("听写动效",$d.options.appearance.animate); toggle("音量波形",$d.options.appearance.waveform)
        toggle("柔光",$d.options.appearance.light); toggle("边缘流光",$d.options.appearance.shimmer).disabled(!look.animate)
        toggle("显示删改痕迹",$d.options.appearance.review); slider("定稿停留",$d.options.appearance.hideDelay,0.5...3,0.25,"秒")
      }
    }.padding(.bottom,4)
  }
  private var materials: [MaterialChoice] { if #available(macOS 26,*) { return MaterialChoice.allCases }; return [.frost,.solid] }
  private func fold<Content:View>(_ title:String,symbol:String,summary:String,isOpen:Binding<Bool>,@ViewBuilder content:@escaping ()->Content) -> some View {
    Surface(inset:Layout.inset,spacing:0) {
      Button { isOpen.wrappedValue.toggle() } label:{
        HStack(spacing:9) { Image(systemName:symbol).foregroundStyle(Color.inkMint).frame(width:20); PanelTitle(title:title); Spacer(); Text(summary).font(.callout).foregroundStyle(.secondary); Image(systemName:isOpen.wrappedValue ? "chevron.up":"chevron.down").font(.caption.weight(.semibold)).frame(width:14) }
          .frame(minHeight:24).contentShape(Rectangle())
      }.buttonStyle(.plain).keyCue().accessibilityValue(isOpen.wrappedValue ? "已展开" : "已收起")
      if isOpen.wrappedValue { Divider().padding(.vertical,8); VStack(spacing:6) { content() } }
    }
  }
  private func segment<T:Hashable>(_ title:String,_ v:Binding<T>,_ items:[T],_ name:@escaping (T)->String) -> some View {
    let selection = Binding(get: { items.firstIndex(of:v.wrappedValue) ?? 0 }, set: { if items.indices.contains($0) { v.wrappedValue = items[$0] } })
    return row(title) {
      UniformSegments(title:title, names:items.map(name), selection:selection)
        .keyCue(9,segment:(selection.wrappedValue,items.count))
    }
  }
  private func row<Control:View>(_ title:String,@ViewBuilder control:()->Control) -> some View {
    HStack(spacing:12) {
      Text(title).frame(minWidth:Layout.formLabel,alignment:.leading)
      Spacer(minLength:0)
      HStack(spacing:8,content:control).frame(maxWidth:Layout.controlRail)
    }.frame(minHeight:Layout.optionRow)
  }
  private func toggle(_ title:String,_ v:Binding<Bool>) -> some View {
    Toggle(isOn:v) { Text(title).frame(maxWidth:.infinity,alignment:.leading) }.toggleStyle(.switch).keyCue().frame(minHeight:Layout.optionRow)
  }
  private func slider(_ name:String,_ v:Binding<Double>,_ r:ClosedRange<Double>,_ step:Double,_ unit:String) -> some View {
    let n=v.wrappedValue, display=unit == "%" ? "\(Int((n*100).rounded()))%" : n.formatted(.number.precision(.fractionLength(0...2))) + " " + unit
    return row(name) { Slider(value:Binding(get:{ v.wrappedValue },set:{ v.wrappedValue = min(r.upperBound,max(r.lowerBound,r.lowerBound + (($0-r.lowerBound)/step).rounded()*step)) }),in:r).labelsHidden().keyCue().accessibilityLabel(name).accessibilityValue(display); Text(display).font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width:57,alignment:.trailing) }
  }
}

// A quiet two-tone backdrop makes depth visible without relying on the user's wallpaper or files.
private struct PreviewPaper: View {
  let dark:Bool
  var body:some View {
    let a=CapsulePalette.porcelain.inks(dark ? .dark : .light), b=CapsulePalette.celadon.inks(dark ? .dark : .light)
    Canvas { ctx,size in
      let w=size.width,h=size.height,rect=CGRect(origin:.zero,size:size)
      ctx.fill(Path(rect),with:.linearGradient(Gradient(colors:[a.base,b.edge]),startPoint:.zero,endPoint:CGPoint(x:w,y:h)))
      for i in 0..<2 { let k=CGFloat(i)*0.28; var p=Path(); p.move(to:CGPoint(x:0,y:h*(0.80+k))); p.addCurve(to:CGPoint(x:w,y:h*(0.16+k)),control1:CGPoint(x:w*0.34,y:h*(0.1+k)),control2:CGPoint(x:w*0.67,y:h*(0.97+k))); p.addLine(to:CGPoint(x:w,y:h));p.addLine(to:CGPoint(x:0,y:h));p.closeSubpath();ctx.fill(p,with:.color(i == 0 ? CapsulePalette.apricot.inks(dark ? .dark:.light).swatch.opacity(0.81) : CapsulePalette.coast.inks(dark ? .dark:.light).swatch.opacity(0.87))) }
    }.accessibilityHidden(true)
  }
}
