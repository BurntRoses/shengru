import AppKit
import SwiftUI

extension Color {
  static let inkMint = Color(
    nsColor: NSColor(
      name: nil,
      dynamicProvider: { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
          ? NSColor(srgbRed: 0.43, green: 0.87, blue: 0.73, alpha: 1)
          : NSColor(srgbRed: 0.045, green: 0.42, blue: 0.335, alpha: 1)
      }))
  static let deskSurface = Color(nsColor: .controlBackgroundColor)
}
struct WaveMark: View {
  var power: Double
  var active: Bool
  var color: Color = .inkMint
  var history: [Double] = []
  @Environment(\.accessibilityReduceMotion) var reduced
  var body: some View {
    HStack(alignment:.center,spacing:0) {
      GeometryReader { g in
        let count = 9, step = g.size.width / CGFloat(count)
        let silhouette = [0.21,0.32,0.61,0.82,1.0,0.76,0.53,0.36,0.21]
        HStack(alignment:.center, spacing:step*0.35) {
          ForEach(0..<count,id:\.self) { i in
            let loud = history.count == count ? history[i] : power
            let amp = active ? (0.09 + 0.91 * min(1,loud*1.4)) : 0.78
            Capsule().fill(color).frame(width:step*0.65, height:max(2,g.size.height*silhouette[i]*amp))
          }
        }.frame(maxWidth:.infinity,maxHeight:.infinity).animation(active && !reduced ? .easeOut(duration:0.13) : nil,value:history)
      }
    }.accessibilityHidden(true)
  }
}
struct ReviewRuns {
  struct Piece {
    var s: String
    var type: Int
  }
  static func diff(_ old: String, _ new: String, tail: Bool = true) -> [Piece] {
    let left = Array(tail ? String(old.suffix(320)) : old)
    let right = Array(tail ? String(new.suffix(320)) : new)
    var start = 0, endA = left.count, endB = right.count
    while start < min(endA,endB) && left[start] == right[start] { start += 1 }
    while endA > start, endB > start, left[endA-1] == right[endB-1] { endA -= 1; endB -= 1 }
    let prefix = String(left[..<start]), suffix = String(left[endA...]); let a = Array(left[start..<endA]), b = Array(right[start..<endB])
    if max(a.count,b.count) > 1800 { return [Piece(s:prefix,type:0),Piece(s:String(a),type:-1),Piece(s:String(b),type:1),Piece(s:suffix,type:0)].filter { !$0.s.isEmpty } }
    let diff = b.difference(from: a)
    let rm = Set(
      diff.removals.compactMap {
        if case .remove(let o, _, _) = $0 { return o }
        return nil
      })
    let add = Set(
      diff.insertions.compactMap {
        if case .insert(let o, _, _) = $0 { return o }
        return nil
      })
    var x = 0
    var y = 0
    var output: [Piece] = prefix.isEmpty ? [] : [Piece(s:prefix,type:0)]
    func append(_ c: Character, _ t: Int) {
      if output.last?.type == t {
        output[output.count - 1].s.append(c)
      } else {
        output.append(Piece(s: String(c), type: t))
      }
    }
    while x < a.count || y < b.count {
      if x < a.count && rm.contains(x) {
        append(a[x], -1)
        x += 1
      } else if y < b.count && add.contains(y) {
        append(b[y], 1)
        y += 1
      } else if x < a.count && y < b.count {
        append(b[y], 0)
        x += 1
        y += 1
      } else if x < a.count {
        append(a[x], -1)
        x += 1
      } else {
        append(b[y], 1)
        y += 1
      }
    }
    if !suffix.isEmpty { output.append(Piece(s:suffix,type:0)) }
    return output
  }
  // Recover unchanged clauses between distant edits without a quadratic whole-record diff.
  // Every hunk consumes original slices, so both columns reconstruct their own text exactly.
  static func transcriptDiff(_ old: String, _ new: String) -> [Piece] {
    guard max(old.utf16.count, new.utf16.count) > 1800 else { return diff(old,new,tail:false) }
    func clauses(_ text: String) -> [String] {
      var out = [String](), start = text.startIndex
      for i in text.indices where "，。！？；、,.!?;\n".contains(text[i]) {
        let end = text.index(after:i); out.append(String(text[start..<end])); start=end
      }
      if start < text.endIndex { out.append(String(text[start...])) }; return out
    }
    let a=clauses(old), b=clauses(new)
    var locations = [String:Int](), result = [Piece](), left=0, right=0
    for (i, clause) in b.enumerated() { locations[clause] = locations[clause] == nil ? i : -1 }
    func append(_ x: Int, _ y: Int) {
      guard left<x || right<y else { return }
      result += diff(a[left..<x].joined(), b[right..<y].joined(), tail:false)
    }
    for i in a.indices {
      guard let j=locations[a[i]], j >= right else { continue }
      append(i,j); result.append(Piece(s:a[i],type:0)); left=i+1; right=j+1
    }
    append(a.count,b.count); return result
  }
  static func styled(_ a: String, _ b: String, tail: Bool = true) -> AttributedString {
    styled(diff(a, b, tail: tail))
  }
  static func styled(_ pieces: [Piece]) -> AttributedString {
    var result = AttributedString("")
    for part in pieces {
      var r = AttributedString(part.s)
      if part.type < 0 {
        r.foregroundColor = .red
        r.strikethroughStyle = .single
      } else if part.type > 0 {
        r.foregroundColor = .inkMint
        r.underlineStyle = .single
      }
      result.append(r)
    }
    return result
  }
}
private struct Frost: NSViewRepresentable {
  func makeNSView(context: Context) -> NSVisualEffectView {
    let n = NSVisualEffectView()
    n.material = .popover
    n.blendingMode = .behindWindow
    n.state = .active
    return n
  }
  func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}
private struct HandleArea: NSViewRepresentable {
  final class Handle: NSView {
    private var grip = NSPoint.zero
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds,cursor:.openHand) }
    override func mouseDown(with event: NSEvent) {
      guard let window else { return }; let p = NSEvent.mouseLocation; grip = NSPoint(x:p.x-window.frame.minX,y:p.y-window.frame.minY)
    }
    override func mouseDragged(with event: NSEvent) { let p = NSEvent.mouseLocation; (window as? FloatPanel)?.moveByHand?(NSPoint(x:p.x-grip.x,y:p.y-grip.y),p) }
  }
  func makeNSView(context: Context) -> Handle { Handle() }
  func updateNSView(_ v: Handle, context: Context) {}
}
private typealias InkState<Value> = SwiftUI.State<Value>
struct CapsuleView: View {
  @ObservedObject var desk: Desk
  var sample = false
  @InkState private var inkOpacity = 1.0
  @Environment(\.accessibilityReduceMotion) var reduceMotion
  @Environment(\.accessibilityReduceTransparency) var opaque
  var preview: Bool { sample || (desk.previewing && desk.phase == .idle) }
  var active: Bool { preview || desk.phase == .listen }
  var headline: String {
    if preview { return "悬浮窗预览" }; if desk.panelEditing { return "修改定稿" }
    switch desk.phase {
    case .listen: return desk.handsFree ? "持续听写" : "正在听写"
    case .finish: return "正在校对"
    case .notice, .result: return desk.status
    case .idle: return "正在听写"
    }
  }
  var stable: String { preview ? "明天下午开会，" : desk.stable }
  var tail: String { preview ? "请带上合同。" : desk.tail }
  var hasWords: Bool { !stable.isEmpty || !tail.isEmpty }
  @Environment(\.colorScheme) private var ambient
  @Environment(\.colorSchemeContrast) private var contrast
  var p: CapsuleAppearance { desk.options.appearance }
  private var scheme: ColorScheme { p.palette == .midnight ? .dark : ambient }
  private var inks: CapsulePalette.Inks { p.palette.inks(scheme) }
  @ViewBuilder func surface(_ rr: RoundedRectangle) -> some View {
    let solid = opaque || contrast == .increased || p.material == .solid
    ZStack {
      if solid { rr.fill(scheme == .dark ? Color(white:0.14) : Color(white:0.97)) }
      else if #available(macOS 26, *), p.material == .glass {
        Color.clear.glassEffect(.regular.tint(inks.base.opacity(0.23)), in:rr)
      } else { Frost().clipShape(rr) }
      CapsulePaint(inks:inks,wash:p.wash).opacity(solid ? p.opacity : 0.38 + 0.49 * p.opacity).clipShape(rr)
    }.accessibilityHidden(true)
  }
  var body: some View {
    let rr = RoundedRectangle(cornerRadius: p.radius, style: .continuous)
    VStack(alignment: .leading, spacing: CapsuleMetrics.gap) {
      if !preview, let replay=desk.capsuleReplay {
        CapsuleReplayView(desk:desk,review:replay)
      } else {
      HStack(spacing: 8) {
        if active {
          if p.waveform && p.animate && !reduceMotion {
            Group {
              if preview { TimelineView(.periodic(from:.now, by:0.14)) { tick in
                let t = tick.date.timeIntervalSinceReferenceDate * 4
                WaveMark(power:0.5,active:true,color:inks.accent,history:(0..<9).map { 0.38 + 0.24 * sin(t + Double($0)*0.72) })
              } } else { WaveMark(power:desk.level,active:true,color:inks.accent,history:desk.meterHistory) }
            }.frame(width:24,height:17)
          } else { Image(systemName:"mic.fill").foregroundStyle(inks.accent).frame(width:24,height:17) }
        } else if desk.phase == .finish {
          ProgressView().controlSize(.small).frame(width: 24, height: 18)
        } else {
          Image(systemName: desk.panelEditing ? "pencil.line" : desk.icon).foregroundStyle(
            desk.phase == .notice ? Color.orange : Color.inkMint
          ).frame(width: 24, height: 18)
        }
        Text(headline).font(.system(size: 12, weight: .semibold)).lineLimit(2).fixedSize(
          horizontal: false, vertical: true
        ).layoutPriority(2)
        if !preview, let hint=desk.deliveryHint { Text(hint).font(.system(size:11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail).help(hint) }
        if !sample {
          Spacer(minLength: 0).frame(height: CapsuleMetrics.header).overlay { HandleArea() }.help(
            "拖动悬浮窗")
        } else {
          Spacer()
        }
        if active {
          Text(clockText(preview ? 4 : desk.seconds)).font(
            .system(size: 11, weight: .medium, design: .monospaced)
          ).foregroundStyle(.secondary).fixedSize(horizontal: true, vertical: false)
            .monospacedDigit()
          if preview && !sample { capsuleButton("xmark", "关闭预览") { desk.previewing = false } }
          if !preview && hasWords { copyButton }
          if desk.handsFree && !preview {
            capsuleButton("stop.fill", "结束听写") { desk.end(cancel: false) }
          }
        } else if desk.phase == .result && desk.panelEditing {
          PanelEditActions(d:desk)
        } else if desk.phase == .result {
          Button { desk.rehear(inCapsule:true) } label: {
            Text("增强识别").font(.system(size: 11, weight: .semibold)).fixedSize().padding(.horizontal, 8)
              .frame(height: CapsuleMetrics.header).background(Color.inkMint.opacity(0.12), in: Capsule())
          }.buttonStyle(.plain).foregroundStyle(Color.inkMint).keyCue().help("在这里重听并校正用词")
          if desk.awaitingReview { Button(desk.canSendReviewed ? "确认并输入" : "确认定稿") {desk.confirmReview()}.deskAction(primary:true) }
          copyButton
          if !desk.awaitingReview { capsuleButton("xmark", "收起") { desk.dismiss() } }
        } else if desk.phase == .notice {
          capsuleButton("xmark", "收起") { desk.dismiss() }
        }
      }.frame(minHeight: CapsuleMetrics.header)
      if !preview, desk.phase == .result, let id=desk.lastID {
        PanelWords(d:desk,id:id,original:desk.showEdits ? desk.raw : nil)
      } else if hasWords {
        ScrollViewReader { proxy in
          ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
              Group {
                if desk.showEdits && !sample {
                  Text(ReviewRuns.styled(desk.raw, desk.last))
                } else if !sample, let before=desk.inkBefore(stable+tail) {
                  Text(ReviewRuns.styled(before,stable+tail))
                } else {
                  Text("\(Text(stable).foregroundColor(.primary))\(Text(tail).foregroundColor(.secondary))")
                }
              }.opacity(inkOpacity).onChange(of: desk.showEdits) { _, _ in
                guard p.animate && !reduceMotion else { return }
                inkOpacity = 0.76
                withAnimation(.easeOut(duration: 0.16)) { inkOpacity = 1 }
              }
              Color.clear.frame(height: 1).id("bottom")
            }.frame(maxWidth: .infinity, alignment: .leading)
          }.scrollIndicators(.hidden).onChange(of: stable + tail, initial: true) { _, _ in
            proxy.scrollTo("bottom", anchor: .bottom)
          }
        }.font(.system(size: p.typeSize, weight: .medium)).lineSpacing(CapsuleMetrics.leading)
          .accessibilityLabel(
            stable + tail)
      }
      }
    }.padding(.horizontal, CapsuleMetrics.insetX).padding(.vertical, CapsuleMetrics.insetY)
      .frame(maxWidth: .infinity, maxHeight: hasWords || desk.capsuleReplay != nil ? .infinity : nil, alignment: .leading)
      .background { surface(rr) }
      .overlay {
        if active && p.light && !opaque { rr.fill(LinearGradient(colors:[inks.accent.opacity(preview ? 0.10 : (p.animate && !reduceMotion ? 0.045 + 0.13*desk.level : 0.07)),.clear],startPoint:.leading,endPoint:.trailing)).allowsHitTesting(false) }
        if active && p.shimmer && p.animate && !reduceMotion && !opaque {
          TimelineView(.animation(minimumInterval:1/20)) { time in
            let pos = time.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy:3.8)/3.8
            rr.strokeBorder(LinearGradient(colors:[.clear,inks.accent.opacity(0.32),.white.opacity(0.62),.clear],startPoint:UnitPoint(x:pos*1.7-0.7,y:0),endPoint:UnitPoint(x:pos*1.7,y:1)),lineWidth:1)
          }.allowsHitTesting(false).accessibilityHidden(true)
        }
      }.environment(\.colorScheme,scheme).padding(CapsuleMetrics.outer).focusEffectDisabled()
      .accessibilityElement(children: .contain)
      .onHover { inside in if !sample { desk.hoverResult(inside) } }
  }
  private var copyButton: some View {
    Button { desk.copyCurrent() } label: {
      Label(desk.copied ? "已复制" : "复制", systemImage:desk.copied ? "checkmark" : "doc.on.doc")
        .font(.system(size:11,weight:.medium)).fixedSize().padding(.horizontal,8).frame(height:CapsuleMetrics.header)
        .background(Color.inkMint.opacity(0.10), in:Capsule())
    }.buttonStyle(.plain).foregroundStyle(Color.inkMint).keyCue().disabled(desk.copyText.isEmpty || desk.confirming)
      .accessibilityLabel(desk.copyLabel).help(desk.copyLabel)
  }
  func capsuleButton(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View
  {
    IconAction(symbol: symbol, title: label, size: CapsuleMetrics.header, action: action)
      .background(.primary.opacity(0.065), in: Circle())
  }
}
private struct PanelWords: View {
  @ObservedObject var d: Desk
  let id: UUID, original: String?
  var available=true
  var body: some View {
    PassageEditor(id:id,value:d.reviewText,label:"悬浮窗正文，可编辑",size:d.options.appearance.typeSize,
      editable:available && !d.confirming && d.historyDraft == nil,editing:d.panelEditing,compare:original,
      begin:{d.editLast(open:false,inPanel:true);return d.panelEditing},change:{if d.panelEditing {d.draft=$0}},save:d.confirmReview,cancel:d.cancelEdit)
      .frame(maxWidth:.infinity,maxHeight:.infinity).help("点按文字修改")
  }
}
private struct PanelEditActions: View {
  @ObservedObject var d:Desk
  var body:some View {
    HStack(spacing:6) {
      Button("取消",action:d.cancelEdit).deskAction()
      Button(d.canSendReviewed ? "确认并输入" : "保存",action:d.confirmReview).deskAction(primary:true).disabled(d.draft.trimmed.isEmpty || d.confirming)
    }.fixedSize()
  }
}
// Reading and candidate buttons do not acquire keyboard focus. Only a deliberate text edit does.
private struct CapsuleReplayView: View {
  @ObservedObject var desk: Desk
  @ObservedObject var review: Rehearing
  private var working: Bool { review.stage == .working }
  private var heading: String {
    switch review.stage {
    case .working: return (review.percent ?? 0)<49 ? "正在重听整段" : "正在逐句核对"
    case .done(let note): return Self.detail(review) == nil ? note : "复听结果"
    case .unavailable: return "无法复听"
    }
  }
  static func detail(_ r: Rehearing) -> String? {
    switch r.stage { case .unavailable(let s):return s; case .done(let s) where s.count>10:return s; default:return nil }
  }
  static func choices(_ desk:Desk, _ r:Rehearing) -> [ReadingChoice] {
    guard case .done=r.stage else {return []};let text=desk.reviewText
    return desk.readingChoices.filter{$0.range(in:text) != nil}
  }
  static func choicesHeight(_ n:Int) -> CGFloat { CGFloat(min(3,n)) * 30 }
  var body: some View {
    let choices=Self.choices(desk,review)
    HStack(spacing:6) {
      Image(systemName:working ? "waveform.badge.magnifyingglass" : Self.isFailure(review) ? "exclamationmark.circle" : "checkmark.circle")
        .foregroundStyle(Self.isFailure(review) ? Color.orange : Color.inkMint).frame(width:20).accessibilityHidden(true)
      Text(desk.panelEditing ? "修改复听结果" : heading).font(.system(size:12,weight:.semibold)).lineLimit(1).fixedSize()
      if working, let n=review.percent { Text("\(n)%").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
      Spacer(minLength:4).frame(height:CapsuleMetrics.header).overlay { HandleArea() }.help("拖动悬浮窗")
      if desk.panelEditing { PanelEditActions(d:desk) }
      else if working {
        CapsuleCancel(action:desk.closeCapsuleReplay).frame(width:46,height:CapsuleMetrics.header)
      } else {
        if desk.canUndoReading { action("撤销","撤销替换",system:"arrow.uturn.backward",run:desk.undoReading) }
        if desk.awaitingReview { action(desk.canSendReviewed ? "输入" : "定稿",desk.canSendReviewed ? "确认并输入" : "确认定稿",system:nil){desk.confirmReview()} }
        IconAction(symbol:desk.copied ? "checkmark" : "doc.on.doc",title:desk.copyLabel,size:CapsuleMetrics.header){desk.copyCurrent()}
        IconAction(symbol:"xmark",title:"收起复听结果",size:CapsuleMetrics.header){desk.closeCapsuleReplay()}
      }
    }.frame(height:CapsuleMetrics.header)
    if working {
      ProgressView(value:Double(review.percent ?? 0),total:100).progressViewStyle(.linear).tint(.inkMint).frame(height:4)
    } else if !desk.panelEditing, let note=Self.detail(review) {
      Text(note).font(.system(size:12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
    }
    PanelWords(d:desk,id:review.recordID,original:desk.options.appearance.review && !working ? review.original : nil,available:!working)
    if !choices.isEmpty && !desk.panelEditing {
      ScrollView(.vertical) {
        VStack(alignment:.leading,spacing:0) {
          ForEach(choices) { c in
            Button { desk.chooseReading(c) } label: {
              HStack(spacing:7) {
                Text(c.heard).foregroundStyle(.secondary); Image(systemName:"arrow.right").font(.caption2).foregroundStyle(.secondary)
                Text(c.word).fontWeight(.semibold).foregroundStyle(Color.inkMint)
              }.lineLimit(1).truncationMode(.middle).font(.system(size:12)).padding(.horizontal,10)
                .frame(height:26).background(Color.inkMint.opacity(0.10),in:Capsule()).contentShape(Capsule())
            }.buttonStyle(.plain).keyCue().frame(height:30)
              .accessibilityLabel("把“\(c.heard)”替换为“\(c.word)”").help(c.left+c.heard+c.right+" → "+c.word)
          }
        }.frame(maxWidth:.infinity,alignment:.leading)
      }.frame(height:Self.choicesHeight(choices.count)).accessibilityLabel("可选写法")
    }
  }
  private static func isFailure(_ r:Rehearing)->Bool { if case .unavailable=r.stage{return true};return false }
  private func action(_ title:String,_ label:String,system:String?,run:@escaping()->Void)->some View {
    Button(action:run){ HStack(spacing:4){ if let system { Image(systemName:system) };Text(title) }
      .font(.system(size:11,weight:.medium)).fixedSize().padding(.horizontal,8).frame(height:CapsuleMetrics.header)
      .background(Color.inkMint.opacity(0.10),in:Capsule())
    }.buttonStyle(.plain).foregroundStyle(Color.inkMint).keyCue().accessibilityLabel(label).help(label)
  }
}

// Keep AppKit's mouse tracking alive while progress changes redraw the title. The first
// click after ordering a non-key panel back onto the screen must cancel the running job.
private struct CapsuleCancel: NSViewRepresentable {
  let action:()->Void
  final class Control:NSButton {
    override func acceptsFirstMouse(for event:NSEvent?)->Bool { true }
    override var needsPanelToBecomeKey:Bool { false }
  }
  final class Target:NSObject { var act:()->Void = {}; @objc func cancel(){act()} }
  func makeCoordinator()->Target { Target() }
  func makeNSView(context:Context)->Control {
    let b=Control(title:"取消",target:context.coordinator,action:#selector(Target.cancel));b.bezelStyle = .accessoryBarAction
    b.controlSize = .small;b.refusesFirstResponder=true;b.focusRingType = .none;b.toolTip="取消增强识别";b.setAccessibilityLabel("取消增强识别");return b
  }
  func updateNSView(_ b:Control,context:Context){context.coordinator.act=action}
}

// One set of insets drives both the fitted panel and its SwiftUI content.
enum CapsuleMetrics {
  static let insetX: CGFloat = 16, insetY: CGFloat = 9, outer: CGFloat = 3
  static let header: CGFloat = 26, gap: CGFloat = 6, leading: CGFloat = 3
  static let shell = 2 * (insetY + outer) + header
  static func transcriptHeight(_ text:String, width:CGFloat, size:CGFloat) -> CGFloat {
    min(172,max(83,inkHeight(text,width:width,font:.systemFont(ofSize:size,weight:.medium)) + shell + gap + 2))
  }
  static func inkHeight(_ text: String, width: CGFloat, font: NSFont) -> CGFloat {
    let p = NSMutableParagraphStyle()
    p.lineSpacing = leading
    return ceil(
      (text as NSString).boundingRect(
        with: NSSize(width: max(1, width - 2 * (insetX + outer)), height: 1200),
        options: [.usesLineFragmentOrigin, .usesFontLeading],
        attributes: [.font: font, .paragraphStyle: p]
      ).height)
  }
}
final class FloatPanel: NSPanel {
  var moveByHand: ((NSPoint,NSPoint)->Void)?
  var acceptsEditor = false
  override var canBecomeKey: Bool { acceptsEditor }
  override var canBecomeMain: Bool { false }
}
private final class PanelHost: NSHostingView<CapsuleView> {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
final class CapsuleController {
  let panel: FloatPanel
  private let desk: Desk
  private var previousPosition: Placement?
  private var visibleToken = 0
  private var manual: (display: NSNumber?, relative: NSPoint, placement:Placement)?
  private var displayWatch: NSObjectProtocol?
  static func fitted(_ origin:NSPoint, size:NSSize, in area:NSRect) -> NSRect {
    let safe = area.insetBy(dx:min(8,area.width/4),dy:min(8,area.height/4))
    let w = min(size.width,safe.width), h = min(size.height,safe.height)
    return NSRect(x:min(max(origin.x,safe.minX),safe.maxX-w).rounded(), y:min(max(origin.y,safe.minY),safe.maxY-h).rounded(),width:w,height:h)
  }
  private func display(_ screen:NSScreen) -> NSNumber? { screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber }
  private func dragged(_ origin:NSPoint, pointer:NSPoint) {
    guard let s = NSScreen.screens.first(where:{$0.frame.contains(pointer)}) ?? panel.screen ?? NSScreen.main else { return }
    let area = s.visibleFrame, rect = Self.fitted(origin,size:panel.frame.size,in:area)
    manual = (display(s),NSPoint(x:(rect.midX-area.minX)/area.width,y:(rect.midY-area.minY)/area.height), desk.options.appearance.position)
    desk.panelMoved = true; desk.screen = area; panel.setFrame(rect,display:true)
  }
  deinit { if let displayWatch { NotificationCenter.default.removeObserver(displayWatch) } }
  init(_ d: Desk) {
    desk = d
    panel = FloatPanel(
      contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
      defer: false)
    panel.title = "听写悬浮窗"; panel.becomesKeyOnlyIfNeeded = true
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = true
    panel.hidesOnDeactivate = false
    panel.level = .statusBar
    panel.collectionBehavior = [
      .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle,
    ]
    panel.isMovableByWindowBackground = false
    panel.isReleasedWhenClosed = false
    let view = PanelHost(rootView: CapsuleView(desk: d))
    view.sizingOptions = []
    panel.contentView = view
    d.resetPanelPosition = { [weak self] in self?.manual = nil; self?.sync() }
    panel.setAccessibilityLabel("听写悬浮窗")
    panel.moveByHand = { [weak self] o,p in self?.dragged(o,pointer:p) }
    displayWatch = NotificationCenter.default.addObserver(forName:NSApplication.didChangeScreenParametersNotification,object:nil,queue:.main) { [weak self] _ in self?.sync() }
  }
  func sync() {
    if panel.acceptsEditor && !desk.panelEditing && panel.isKeyWindow {
      // Ordering out releases the nonactivating panel’s keyboard claim without activating a different app.
      panel.makeFirstResponder(nil); panel.orderOut(nil)
    }
    panel.acceptsEditor=desk.panelEditing
    visibleToken += 1
    let token = visibleToken
    let motion = desk.options.appearance.animate && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    if (desk.phase == .idle && !desk.previewing) || (desk.phase == .result && desk.rehearing != nil && desk.capsuleReplay == nil) {
      if panel.isVisible {
        NSAnimationContext.runAnimationGroup { ctx in
          ctx.duration = motion ? 0.15 : 0
          panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
          if self?.visibleToken == token { self?.panel.orderOut(nil) }
        }
      }
      return
    }
    let chosen = NSScreen.screens.first { $0.visibleFrame == desk.screen } ?? (panel.isVisible ? panel.screen : nil) ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
    guard let chosen else { return }
    let area = chosen.visibleFrame
    let preview = desk.previewing && desk.phase == .idle
    let replay=desk.capsuleReplay
    let text = preview ? "明天下午开会，请带上合同。" : desk.phase == .result ? desk.reviewText : desk.stable + desk.tail
    let width = max(1,min(area.width - 16,desk.options.appearance.width))
    let font = NSFont.systemFont(ofSize: desk.options.appearance.typeSize, weight: .medium)
    let display =
      desk.showEdits
      ? ReviewRuns.diff(desk.raw, desk.last).map(\.s).joined() : String(text.suffix(1200))
    let ink = CapsuleMetrics.inkHeight(display, width: width, font: font)
    // Long permission or device messages may wrap to two lines in a compact panel.
    let titleSpace = max(1, width - 2 * (CapsuleMetrics.insetX + CapsuleMetrics.outer) - 70)
    let noticeHeight = (desk.status as NSString).boundingRect(
      with: NSSize(width: titleSpace, height: 80),
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold)]
    ).height
    var height =
      text.isEmpty
      ? CapsuleMetrics.shell
        + (desk.phase == .notice ? max(0, min(34, ceil(noticeHeight)) - CapsuleMetrics.header) : 0)
      : CapsuleMetrics.transcriptHeight(display,width:width,size:desk.options.appearance.typeSize)
    if let replay, !desk.panelEditing {
      height=CapsuleMetrics.shell + CapsuleMetrics.gap + min(116,max(32,ink+6))
      if replay.stage == .working {height+=CapsuleMetrics.gap+4}
      else if let note=CapsuleReplayView.detail(replay) {
        height+=CapsuleMetrics.gap+CapsuleMetrics.inkHeight(note,width:width,font:.systemFont(ofSize:12))+2
      }
      let count=CapsuleReplayView.choices(desk,replay).count
      if count>0 {height+=CapsuleMetrics.gap+CapsuleReplayView.choicesHeight(count)}
    }
    if desk.panelEditing { height=max(94,height) }; let size = NSSize(width:width,height:min(height,max(1,area.height-16)))
    var x = area.midX - width / 2
    var y = area.minY + 46
    if desk.options.appearance.position == .top {
      x = area.maxX - width - 22
      y = area.maxY - height - 22
    }
    if previousPosition != nil && previousPosition != desk.options.appearance.position { manual = nil }
    if let m = manual, m.display == self.display(chosen), m.placement == desk.options.appearance.position {
      x = area.minX + m.relative.x * area.width - width / 2; y = area.minY + m.relative.y * area.height - height / 2
    }
    let rect = Self.fitted(NSPoint(x:x,y:y),size:size,in:area)
    let was = panel.isVisible
    previousPosition = desk.options.appearance.position
    let changed = panel.frame != rect
    if changed {
      // Apply geometry synchronously; a queued resize animation must never undo a drag.
      panel.setFrame(rect, display:true)
    }
    if !was {
      panel.alphaValue = motion ? 0 : 1
      panel.orderFrontRegardless()
    }
    if panel.alphaValue < 1 {
      NSAnimationContext.runAnimationGroup { ctx in
        ctx.duration = motion ? 0.15 : 0
        panel.animator().alphaValue = 1
      }
    }
  }
}
