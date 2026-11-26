import AppKit
import SwiftUI

typealias LocalState<Value> = SwiftUI.State<Value>

// 阅读层用安静的实色表面，只有导航、悬浮层及操作按钮使用系统玻璃。
enum Layout {
  static let canvas = Color(
    nsColor: NSColor(name: nil) { appearance in
      appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(srgbRed: 0.115, green: 0.121, blue: 0.122, alpha: 1)
        : NSColor(srgbRed: 0.955, green: 0.96, blue: 0.958, alpha: 1)
    })
  static let gutter: CGFloat = 26
  static let inset: CGFloat = 20
  static let sectionGap: CGFloat = 18
  static let card: CGFloat = 16
  static let row: CGFloat = 38
  static let formLabel: CGFloat = 88
  static let controlRail: CGFloat = 244
  static let tabWidth: CGFloat = 82
  static let optionRow: CGFloat = 32
  static let navRow: CGFloat = 36
  static let sideRow: CGFloat = 32
  static let maxColumn: CGFloat = 800
  static let window = NSSize(width: 864, height: 584)
  static let minimum = NSSize(width: 550, height: 410)
}

private struct PanelPaint: ViewModifier {
  @Environment(\.colorScheme) private var scheme
  var radius: CGFloat
  func body(content: Content) -> some View {
    content.background {
      RoundedRectangle(cornerRadius: radius, style: .continuous)
        .fill(scheme == .dark ? Color.white.opacity(0.054) : Color.white.opacity(0.90))
    }
  }
}

private struct NavigationGlass: ViewModifier {
  @Environment(\.accessibilityReduceTransparency) private var opaque
  let radius: CGFloat
  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
    content.background {
      if opaque {
        shape.fill(Color(nsColor: .controlBackgroundColor))
      } else if #available(macOS 26, *) {
        Color.clear.glassEffect(.regular, in: shape)
      } else {
        shape.fill(.regularMaterial)
      }
    }
  }
}

// Keep an explicit readable label and a backing color even in an inactive menu-bar window.
// The system renders the actual refractive material and handles pointer response on macOS 26.
private struct ActionStyle: ButtonStyle {
  let primary: Bool, large: Bool
  @Environment(\.isEnabled) private var enabled
  @Environment(\.accessibilityReduceTransparency) private var opaque
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorScheme) private var scheme
  func makeBody(configuration: Configuration) -> some View {
    let ink: Color =
      !enabled
      ? .secondary
      : configuration.role == .destructive
        ? .red : primary ? (scheme == .dark ? .black.opacity(0.87) : .white) : .primary
    return configuration.label.font(.system(size: 13, weight: primary ? .semibold : .medium))
      .foregroundStyle(ink).padding(.horizontal, large ? 17 : 13)
      .frame(minHeight: large ? 36 : 32).contentShape(Capsule())
      .background {
        // Keep the fill outside the glass compositor: the action must remain legible
        // when the system suspends its material (inactive windows and static rendering).
        ZStack {
          Capsule().fill(primary && enabled ? Color.inkMint : Color.primary.opacity(0.07))
          if #available(macOS 26, *), !opaque {
            if primary && enabled {
              Color.clear.glassEffect(.regular.tint(.inkMint).interactive(enabled && !reduceMotion), in: Capsule())
            } else {
              Color.clear.glassEffect(.regular.interactive(enabled && !reduceMotion), in: Capsule())
            }
          }
        }
      }
      .overlay {
        if configuration.isPressed {
          Capsule().fill(.primary.opacity(0.085)).allowsHitTesting(false)
        }
      }
      .opacity(enabled ? 1 : 0.7)
  }
}

// Monitor navigation only in the window that owns this view. A sheet or a newly opened
// window starts without a cue; the non-activating dictation panel never installs a reader.
private struct KeyboardReader: NSViewRepresentable {
  @Binding var visible: Bool

  final class Anchor: NSView {
    var report: (Bool) -> Void = { _ in }
    private var monitor: Any?, resignation: NSObjectProtocol?

    func listen() {
      monitor = NSEvent.addLocalMonitorForEvents(matching: [
        .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown,
      ]) { [weak self] event in
        guard let self, let window = self.window, event.window === window else { return event }
        if event.type != .keyDown {
          self.report(false)
        } else if event.keyCode == 48 || (123...126).contains(event.keyCode) {
          self.report(true)
        }
        return event
      }
      resignation = NotificationCenter.default.addObserver(
        forName: NSWindow.didResignKeyNotification, object: nil, queue: .main
      ) { [weak self] notification in
        guard let self, let window = self.window, (notification.object as? NSWindow) === window
        else { return }
        self.report(false)
      }
    }
    deinit {
      if let monitor { NSEvent.removeMonitor(monitor) }
      if let resignation { NotificationCenter.default.removeObserver(resignation) }
    }
  }

  func makeNSView(context: Context) -> Anchor {
    let anchor = Anchor()
    anchor.listen()
    return anchor
  }
  func updateNSView(_ view: Anchor, context: Context) {
    view.report = { value in if visible != value { visible = value } }
  }
}
private struct ShowsKeyCue: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
  fileprivate var showsDeskKeyCue: Bool {
    get { self[ShowsKeyCue.self] }
    set { self[ShowsKeyCue.self] = newValue }
  }
}
private struct WorkspaceKeyboard: ViewModifier {
  @LocalState private var visible = false
  func body(content: Content) -> some View {
    content.environment(\.showsDeskKeyCue, visible).focusEffectDisabled()
      .background {
        KeyboardReader(visible: $visible).frame(width: 0, height: 0)
          .allowsHitTesting(false).accessibilityHidden(true)
      }
  }
}
// 焦点不改变控件尺寸，也不与选中态共用一个标记。系统继续处理 Tab、空格和辅助操作。
private struct KeyCue: ViewModifier {
  @FocusState private var focused: Bool
  @Environment(\.showsDeskKeyCue) private var show
  @Environment(\.colorScheme) private var scheme
  let radius: CGFloat
  var prominent = false
  var segment: (index: Int, count: Int)?
  func body(content: Content) -> some View {
    let ink: Color = prominent ? (scheme == .dark ? .black : .white) : .inkMint
    let marker = Image(systemName: "diamond.fill").font(.system(size: 6, weight: .bold))
      .foregroundStyle(ink)
    return content.focused($focused).focusEffectDisabled()
      .overlay {
        if focused && show {
          RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(ink.opacity(0.13))
            .overlay(alignment: .topTrailing) {
              if let segment {
                HStack(spacing: 0) {
                  ForEach(0..<segment.count, id: \.self) { i in
                    Color.clear.overlay(alignment: .leading) {
                      if i == segment.index { marker.padding(.leading, 3) }
                    }
                  }
                }
              } else {
                marker.padding(.top, 3).padding(.trailing, 6)
              }
            }.allowsHitTesting(false).accessibilityHidden(true)
        }
      }
  }
}

// Size the native bezel itself, not just a SwiftUI frame around a text-sized picker.
struct UniformSegments: NSViewRepresentable {
  let title:String, names:[String]
  @Binding var selection:Int
  @Environment(\.isEnabled) private var enabled
  final class Handler: NSObject {
    var change: ((Int)->Void)?
    @objc func selectSegment(_ sender:NSSegmentedControl) { change?(sender.selectedSegment) }
  }
  func makeCoordinator()->Handler { Handler() }
  func makeNSView(context:Context)->NSSegmentedControl {
    let control = NSSegmentedControl(labels:names, trackingMode:.selectOne, target:context.coordinator, action:#selector(Handler.selectSegment(_:)))
    control.segmentDistribution = .fillEqually; control.controlSize = .regular; control.focusRingType = .none
    control.setContentHuggingPriority(.defaultLow, for:.horizontal)
    control.setAccessibilityLabel(title)
    return control
  }
  func updateNSView(_ control:NSSegmentedControl,context:Context) {
    context.coordinator.change = { [binding = $selection] in binding.wrappedValue = $0 }
    if control.segmentCount != names.count { control.segmentCount = names.count }
    for i in names.indices where control.label(forSegment:i) != names[i] { control.setLabel(names[i],forSegment:i) }
    control.selectedSegment = selection; control.isEnabled = enabled
  }
  func sizeThatFits(_ proposal:ProposedViewSize,nsView:NSSegmentedControl,context:Context)->CGSize? {
    let natural = nsView.intrinsicContentSize
    return CGSize(width:proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? natural.width,height:natural.height)
  }
}

// Tabs share both the visible bezel and the width of each choice. A compact header
// turns into a menu before it would truncate a label.
struct SectionTabs<T: Hashable & RawRepresentable>: View where T.RawValue == String {
  let title: String, items: [T]
  @Binding var selected: T
  @Environment(\.layoutDirection) private var direction
  var body: some View {
    let index = Binding(get: { items.firstIndex(of:selected) ?? 0 }, set: { if items.indices.contains($0) { selected = items[$0] } })
    ViewThatFits(in:.horizontal) {
      UniformSegments(title:title,names:items.map(\.rawValue),selection:index)
        .frame(width:Layout.tabWidth * CGFloat(items.count))
        .keyCue(9,segment:(index.wrappedValue,items.count))
        .onKeyPress(keys:[.leftArrow,.rightArrow]) { press in
          guard !items.isEmpty, press.modifiers.intersection([.command,.control,.option,.shift]).isEmpty else { return .ignored }
          let forward = (press.key == .rightArrow) == (direction == .leftToRight)
          index.wrappedValue = (index.wrappedValue + items.count + (forward ? 1 : -1)) % items.count
          return .handled
        }
      Picker(title,selection:$selected) { ForEach(items,id:\.self) { Text($0.rawValue).tag($0) } }
        .labelsHidden().pickerStyle(.menu).fixedSize().keyCue().accessibilityLabel(title)
    }.frame(minHeight:Layout.optionRow)
  }
}

extension View {
  func panelPaint(_ radius: CGFloat = Layout.card) -> some View {
    modifier(PanelPaint(radius: radius))
  }
  func navigationGlass(_ radius: CGFloat) -> some View { modifier(NavigationGlass(radius: radius)) }
  func workspaceKeyboard() -> some View { modifier(WorkspaceKeyboard()) }
  func keyCue(
    _ radius: CGFloat = 9, prominent: Bool = false, segment: (index: Int, count: Int)? = nil
  ) -> some View {
    modifier(KeyCue(radius: radius, prominent: prominent, segment: segment))
  }
  func deskAction(primary: Bool = false, large: Bool = false) -> some View {
    self.buttonStyle(ActionStyle(primary: primary, large: large)).keyCue(18, prominent: primary)
  }
}

struct RowSurface: ButtonStyle {
  var selected: Bool = false
  var radius: CGFloat = 10
  func makeBody(configuration: Configuration) -> some View {
    LabelSurface(configuration: configuration, selected: selected, radius: radius)
  }
  private struct LabelSurface: View {
    let configuration: ButtonStyleConfiguration
    let selected: Bool
    let radius: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @LocalState private var hovered = false
    var body: some View {
      let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
      configuration.label.contentShape(shape).background {
        shape.fill(
          selected
            ? Color.inkMint.opacity(configuration.isPressed ? 0.26 : (hovered ? 0.20 : 0.15))
            : Color.primary.opacity(configuration.isPressed ? 0.12 : (hovered ? 0.065 : 0)))
      }.onHover { hovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: configuration.isPressed)
    }
  }
}

struct IconAction: View {
  let symbol: String, title: String
  var size: CGFloat = 30
  let action: () -> Void
  var body: some View {
    Button(action: action) {
      Image(systemName: symbol).font(.system(size: 13, weight: .medium))
        .frame(width: size, height: size).contentShape(Rectangle())
    }.buttonStyle(RowSurface(radius: size / 2)).keyCue(size / 2).accessibilityLabel(title).help(
      title)
  }
}

struct Surface<Inside: View>: View {
  var inset: CGFloat = Layout.inset
  var spacing: CGFloat = 0
  @ViewBuilder var inside: () -> Inside
  var body: some View {
    VStack(alignment: .leading, spacing: spacing) { inside() }
      .frame(maxWidth: .infinity, alignment: .leading).padding(inset).panelPaint()
  }
}

struct PanelTitle: View {
  let title: String
  var body: some View {
    Text(title).font(.system(size: 14, weight: .semibold)).accessibilityAddTraits(.isHeader)
  }
}

struct FieldSurface: View {
  let title: String, prompt: String
  var search = false
  @Binding var text: String
  @FocusState private var editing: Bool
  var body: some View {
    HStack(spacing: 7) {
      if search {
        Image(systemName: "magnifyingglass").foregroundStyle(editing ? Color.inkMint : .secondary)
          .accessibilityHidden(true)
      }
      TextField(title, text: $text, prompt: Text(prompt)).labelsHidden().textFieldStyle(.plain)
        .font(.system(size: 13)).focused($editing).focusEffectDisabled().accessibilityLabel(title)
      if search && !text.isEmpty {
        IconAction(symbol: "xmark.circle.fill", title: "清除搜索", size: 24) {
          text = ""
          editing = true
        }
        .foregroundStyle(.secondary)
      }
    }.padding(.leading, 12).padding(.trailing, search ? 6 : 12).frame(height: 34)
      .background(
        editing ? Color.inkMint.opacity(0.14) : Color.primary.opacity(0.065),
        in: RoundedRectangle(cornerRadius: search ? 17 : 9)
      )
      .contentShape(Rectangle()).onTapGesture { editing = true }
  }
}

struct PermissionLine: View {
  @ObservedObject var d: Desk
  let access: Access
  var symbol: String {
    switch access {
    case .microphone: return "mic"
    case .keyboard: return "keyboard"
    case .insertText: return "cursorarrow.rays"
    }
  }
  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: symbol).font(.system(size: 15, weight: .medium)).foregroundStyle(
        Color.inkMint
      )
      .frame(width: 30, height: 30).background(
        Color.inkMint.opacity(0.09), in: RoundedRectangle(cornerRadius: 9)
      )
      .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 3) {
        Text(access.title).font(.system(size: 13, weight: .medium))
        Text(access.purpose).font(.caption).foregroundStyle(.secondary).fixedSize(
          horizontal: false, vertical: true)
      }
      Spacer(minLength: 8)
      Group {
        let step = d.permissionStep(access)
        switch step {
        case .allowed:
          Label("已允许", systemImage: "checkmark").font(.callout.weight(.medium)).foregroundStyle(Color.inkMint)
        case .restricted: Text("受系统限制").font(.callout).foregroundStyle(.secondary)
        case .waiting: Text("等待允许").font(.callout).foregroundStyle(.secondary)
        case .ask, .settings:
          Button(step == .ask ? "允许…" : "打开设置") { d.perform(step, for: access) }
            .deskAction().accessibilityLabel(step == .ask ? "允许" + access.title : "打开" + access.title + "设置")
        }
      }.frame(minWidth: 80, alignment: .trailing)
    }.frame(minHeight: 46)
  }
}

struct PermissionRows: View {
  @ObservedObject var d: Desk
  var body: some View {
    PermissionLine(d:d, access:.microphone); Divider()
    PermissionLine(d:d, access:.insertText); Divider()
    if d.options.trigger.registered {
      HStack(spacing:12) {
        Image(systemName:"keyboard").foregroundStyle(Color.inkMint).frame(width:30,height:30).background(Color.inkMint.opacity(0.09),in:RoundedRectangle(cornerRadius:9))
        VStack(alignment:.leading,spacing:3) { Text("全局快捷键").font(.system(size:13,weight:.medium)); Text(d.options.trigger.rawValue).font(.caption).foregroundStyle(.secondary) }
        Spacer(); if d.keyConnected {Label("已连接",systemImage:"checkmark").font(.callout).foregroundStyle(Color.inkMint)} else {
          Button("换一个键"){d.options.trigger = d.options.trigger == .shortcut ? .f6 : .shortcut}.deskAction().help("快捷键被占用，改用另一个组合")
        }
      }.frame(minHeight:46)
    } else {
      PermissionLine(d:d, access:.keyboard)
      if d.usingBackupKey {Label("暂用 " + d.activeTrigger.rawValue,systemImage:"keyboard").font(.callout).foregroundStyle(.secondary).help("允许输入监控后，自动恢复你选的快捷键。")}
    }
  }
}
