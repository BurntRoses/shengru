import AVFoundation
import AppKit
import ApplicationServices
import Carbon
import CryptoKit

enum Access: String, CaseIterable {
  case microphone = "Microphone", keyboard = "ListenEvent", insertText = "Accessibility"
  var title: String {
    switch self {
    case .microphone: return "麦克风"
    case .keyboard: return "输入监控"
    case .insertText: return "辅助功能"
    }
  }
  var purpose: String {
    switch self {
    case .microphone: return "听写时使用麦克风"
    case .keyboard: return "用右侧修饰键开始听写"
    case .insertText: return "在光标处输入文字"
    }
  }
  var granted: Bool {
    switch self {
    case .microphone: return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    case .keyboard: return CGPreflightListenEventAccess()
    case .insertText:
      // The trust status belongs to this executable. Being able to inspect our own UI, or
      // enumerate the frontmost process, does not grant permission to insert elsewhere.
      return AXIsProcessTrustedWithOptions(nil)
    }
  }
  enum Step { case allowed, restricted, waiting, ask, settings }
  // AX and ListenEvent expose trust, not a separate “never asked” status. Remember only
  // whether the native prompt was requested; a stored value is never evidence of consent.
  func step(granted: Bool, mic: AVAuthorizationStatus, asked: Bool, pending: Bool) -> Step {
    if self == .microphone {
      switch mic {
      case .authorized: return .allowed
      case .restricted: return .restricted
      case .notDetermined: return pending ? .waiting : .ask
      default: return .settings
      }
    }
    return granted ? .allowed : asked ? .settings : .ask
  }
  func askSystem(_ changed: @escaping () -> Void) {
    switch self {
    case .microphone:
      AVCaptureDevice.requestAccess(for: .audio) { _ in DispatchQueue.main.async(execute: changed) }
    case .insertText:
      let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
      _ = AXIsProcessTrustedWithOptions(opts)
    case .keyboard:
      _ = CGRequestListenEventAccess()
    }
    // The native alert owns navigation. Its return value is not the user's final decision.
  }
  func openSettings() {
    let pane: String
    switch self {
    case .microphone: pane = "Privacy_Microphone"
    case .insertText: pane = "Privacy_Accessibility"
    case .keyboard: pane = "Privacy_ListenEvent"
    }
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + pane) {
      NSWorkspace.shared.open(url)
    }
  }
}
// Listen only. A passive tap handles other apps without swallowing their keystrokes.
// Before system permission is granted the local monitor still permits trying the shortcut here.
final class Hotkey {
  private var tap: CFMachPort?, source: CFRunLoopSource?, local: Any?
  private var held = false, key: Trigger = .shortcut
  private let registered = RegisteredKey(0x5352444B), escape = RegisteredKey(0x53524553)
  func duringDictation(_ active:Bool) {
    if active && key.registered { _=escape.install(code:53,modifiers:0){[weak self] pressed,_ in if pressed { self?.cancel?() }} }
    else { escape.stop() }
  }
  var down: ((TimeInterval) -> Void)?, up: ((TimeInterval) -> Void)?, cancel: (() -> Void)?, chord: (() -> Void)?
  var connected: Bool { registered.connected || (tap.map { CFMachPortIsValid($0) && CGEvent.tapIsEnabled(tap:$0) } ?? false) }
  func install(_ next: Trigger) {
    stop()
    key = next
    // A registered chord receives just its press and release, even while another app has
    // focus. It does not need to observe the user's keyboard or request Input Monitoring.
    if next.registered {
      let mods=next == .shortcut ? UInt32(controlKey | shiftKey) : 0
      if registered.install(code:UInt32(next.code),modifiers:mods,action:{[weak self] isDown,time in
        guard let self,self.held != isDown else { return }; self.held=isDown
        if isDown { self.down?(time) } else { self.up?(time) }
      }) { return }
      // Do not advertise a busy chord as connected. The in-app microphone stays available.
      return
    }
    let mask = [CGEventType.flagsChanged, .keyDown, .keyUp].reduce(CGEventMask(0)) {
      $0 | (CGEventMask(1) << $1.rawValue)
    }
    if Access.keyboard.granted,
      let port = CGEvent.tapCreate(
        tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
        eventsOfInterest: mask,
        callback: { _, type, event, ctx in
          if let ctx {
            let h = Unmanaged<Hotkey>.fromOpaque(ctx).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
              if h.held {
                h.held = false
                h.cancel?()
              }
              if let port = h.tap { CGEvent.tapEnable(tap: port, enable: true) }
            } else if (h.held || [Int64(h.key.code), 53].contains(event.getIntegerValueField(.keyboardEventKeycode))), let n = NSEvent(cgEvent: event) {
              DispatchQueue.main.async { [weak h] in h?.handle(n) }
            }
          }
          return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
    {
      tap = port
      let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
      source = src
      CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
      CGEvent.tapEnable(tap: port, enable: true)
    } else {
      local = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .keyUp]) {
        [weak self] e in
        self?.handle(e)
        return e
      }
    }
  }
  func handle(_ e: NSEvent) {
    let code = e.keyCode
    if e.type == .keyDown && e.isARepeat { return }
    if code == 53 && e.type == .keyDown {
      cancel?()
      return
    }
    guard code == key.code else {
      if held && (e.type == .keyDown || e.type == .flagsChanged) { chord?() }
      return
    }
    let pressed: Bool
    if key == .f6 {
      guard e.type == .keyDown || e.type == .keyUp else { return }
      pressed = e.type == .keyDown
    } else {
      guard e.type == .flagsChanged else { return }
      let bit: UInt = key == .option ? 0x40 : (key == .control ? 0x2000 : 0x10)
      pressed = (e.modifierFlags.rawValue & bit) != 0
    }
    guard pressed != held else { return }
    if pressed {
      var conflicts: NSEvent.ModifierFlags = [.shift, .control, .command, .option]
      switch key {
      case .control: conflicts.remove(.control)
      case .command: conflicts.remove(.command)
      case .option: conflicts.remove(.option)
      case .f6, .shortcut: break
      }
      guard e.modifierFlags.intersection(conflicts).isEmpty else { return }
    }
    held = pressed
    if pressed { down?(e.timestamp) } else { up?(e.timestamp) }
  }
  func stop() {
    registered.stop(); escape.stop()
    if let m = local { NSEvent.removeMonitor(m) }
    local = nil
    if let src = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
    source = nil
    if let tap { CFMachPortInvalidate(tap) }
    tap = nil
    if held {
      held = false
      cancel?()
    }
  }
  deinit { stop() }
}
// One distinct event signature per command. A busy chord never becomes an invisible local fallback.
final class RegisteredKey {
  private let signature: OSType
  private var reference:EventHotKeyRef?, handler:EventHandlerRef?, action:((Bool,TimeInterval)->Void)?
  var connected:Bool { reference != nil }
  init(_ signature:OSType) { self.signature=signature }
  func install(code:UInt32,modifiers:UInt32,action:@escaping(Bool,TimeInterval)->Void)->Bool {
    if connected {return true}; self.action=action
    let events=[kEventHotKeyPressed,kEventHotKeyReleased].map{EventTypeSpec(eventClass:OSType(kEventClassKeyboard),eventKind:UInt32($0))}
    let status=InstallEventHandler(GetApplicationEventTarget(),{ _,event,ctx in
      guard let event, let ctx else {return OSStatus(eventNotHandledErr)}
      let key=Unmanaged<RegisteredKey>.fromOpaque(ctx).takeUnretainedValue(); var id=EventHotKeyID(signature:0,id:0)
      guard GetEventParameter(event,EventParamName(kEventParamDirectObject),EventParamType(typeEventHotKeyID),nil,MemoryLayout<EventHotKeyID>.size,nil,&id)==noErr,
        id.signature==key.signature, id.id==1 else {return OSStatus(eventNotHandledErr)}
      key.action?(GetEventKind(event)==UInt32(kEventHotKeyPressed),GetEventTime(event)); return noErr
    },events.count,events,Unmanaged.passUnretained(self).toOpaque(),&handler)
    guard status == noErr, RegisterEventHotKey(code,modifiers,EventHotKeyID(signature:signature,id:1),GetApplicationEventTarget(),UInt32(kEventHotKeyExclusive),&reference)==noErr else { stop(); return false }; return true
  }
  func stop() { if let reference {UnregisterEventHotKey(reference)}; reference=nil; if let handler {RemoveEventHandler(handler)}; handler=nil; action=nil }
  deinit { stop() }
}
final class WindowShortcut {
  private let key=RegisteredKey(0x53525657)
  var action:(()->Void)?
  func install()->Bool { key.install(code:UInt32(kVK_Space),modifiers:UInt32(controlKey|optionKey)){[weak self] down,_ in if down {self?.action?()} } }
}
struct InsertOutcome {
  var title: String
  var keep: Bool
  var symbol: String
  var passage: InputTarget.Passage? = nil
  // A paste shortcut being posted is not an acknowledgement from the editor. Retry only
  // the read, never the write: delayed editors must not receive the transcript twice.
  var readBack: (() -> InsertOutcome?)? = nil
  func resolved(_ completion:@escaping(InsertOutcome)->Void) {
    guard let readBack else {completion(self);return}
    let waits=[0.08,0.18,0.32]
    func check(_ i:Int) {
      if let result=readBack() {completion(result)}
      else if i==waits.count {completion(.unconfirmed)}
      else {DispatchQueue.main.asyncAfter(deadline:.now()+waits[i]) {check(i+1)}}
    };check(0)
  }
  static let permission = Self(title: "需允许辅助功能，可复制", keep: true, symbol: "hand.raised")
  static let available = Self(title: "可复制", keep: true, symbol: "doc.on.doc")
  static let noCaret = Self(title: "无法确认输入位置，可复制", keep: true, symbol: "cursorarrow")
  static let unconfirmed = Self(title: "原应用未确认输入，请核对原处", keep: true, symbol: "text.magnifyingglass")
  static let moved = Self(title: "光标已移动", keep: true, symbol: "cursorarrow")
  static let secure = Self(title: "受保护的输入框", keep: true, symbol: "lock")
  static let inserted = Self(title: "已输入", keep: false, symbol: "checkmark")
  static let sent = Self(title: "已发送粘贴，请核对原处", keep: true, symbol: "arrow.turn.down.left")
}
// Temporary clipboard transfer is one transaction. A later copy by the user always wins.
final class PasteLease {
  static let shared = PasteLease()
  private var restore: (() -> Void)?
  func finish() {
    let work = restore
    restore = nil
    work?()
  }
  func send(_ text: String, on board: NSPasteboard, stillHere: () -> Bool, post: () -> Void) -> Bool
  {
    finish()
    let version = board.changeCount
    var saved: [NSPasteboardItem] = []
    var size = 0
    for item in board.pasteboardItems ?? [] {
      let copy = NSPasteboardItem()
      for type in item.types {
        guard let data = item.data(forType: type) else { return false }
        size += data.count
        guard size <= 8 * 1024 * 1024, copy.setData(data, forType: type) else { return false }
      }
      saved.append(copy)
    }
    guard version == board.changeCount, stillHere() else { return false }
    board.clearContents()
    guard board.setString(text, forType: .string) else {
      if !saved.isEmpty { board.writeObjects(saved) }
      return false
    }
    let revision = board.changeCount
    let undo: () -> Void = {
      if board.changeCount == revision {
        board.clearContents()
        if !saved.isEmpty { board.writeObjects(saved) }
      }
    }
    restore = undo
    post()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { [weak self] in
      if board.changeCount == revision { self?.finish() }
    }
    return true
  }
}
protocol ReviewRecipient {
  var editable: Bool { get }
  func insert(_ text: String) -> InsertOutcome
  func insertReviewed(_ text: String, complete: @escaping (InsertOutcome) -> Void)
}
struct InputTarget: ReviewRecipient {
  let pid: pid_t
  let element: AXUIElement?
  let window: AXUIElement?
  let range: CFRange?
  enum Field { case unknown, nonText, editor, secure }
  private let field: Field
  // Returning after an explicit review needs a known selection. An uninterrupted live
  // take can also go to an identified editor that keeps its insertion point private.
  var editable: Bool {
    canInsertLive && (!inWebEditor || document != nil) && (range != nil || selectionMarker != nil)
  }
  var canInsertLive: Bool {
    guard field == .editor, element != nil, window != nil else { return false }
    if let r=range {return r.length == 0 || selectionProof != nil}
    return selectionMarker != nil || fieldOnly
  }
  var protected: Bool { field == .secure }
  var recordingNotice: String? {
    switch field {
    case .secure: return "密码或受保护的输入框不支持听写"
    case .unknown where IsSecureEventInputEnabled(): return "无法确认输入位置，请在听写窗口开始"
    default: return nil
    }
  }
  private var selectionMarker: CFTypeRef? = nil
  // An editor with no caret API may still receive one live paste. Use interaction
  // counts, never a keyboard listener: global NSEvent monitors can miss keys in apps
  // using Secure Event Input. Counts add no input-monitoring permission requirement.
  fileprivate struct KeyBudget {
    let initial:UInt32, start:TimeInterval?, startAlreadyCounted:Bool
    private(set) var settled:UInt32?, expectsStop=false
    init(count:UInt32, lastKey:TimeInterval, start:TimeInterval?) {
      initial=count; self.start=start
      startAlreadyCounted=start.map{abs(lastKey-$0)<0.025} ?? false
      settled=start==nil ? count : nil
    }
    mutating func settle(count:UInt32,lastKey:TimeInterval) {
      guard let start,settled==nil else {return}
      // The Carbon press can arrive on either side of its Quartz counter update.
      if count==initial || (!startAlreadyCounted && count==initial &+ 1 && abs(lastKey-start)<0.025) {settled=count}
    }
    mutating func stopKey() {expectsStop=true}
    func permits(_ count:UInt32)->Bool {settled.map{count == $0 &+ (expectsStop ? 1 : 0)} ?? false}
  }
  private final class Activity {
    private static func count(_ type:CGEventType)->UInt32 {CGEventSource.counterForEventType(.combinedSessionState,eventType:type)}
    private static var lastKey:TimeInterval {ProcessInfo.processInfo.systemUptime-CGEventSource.secondsSinceLastEventType(.combinedSessionState,eventType:.keyDown)}
    private static var buttons:[UInt32] {[CGEventType.leftMouseDown,.rightMouseDown,.otherMouseDown].map(count)}
    private let clicks=buttons
    private var valid=true, activation:NSObjectProtocol?, keys:KeyBudget
    var intact:Bool {valid && Self.buttons==clicks && keys.permits(Self.count(.keyDown))}
    init(owner:pid_t,start:TimeInterval?) {
      keys=KeyBudget(count:Self.count(.keyDown),lastKey:Self.lastKey,start:start)
      activation=NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.didActivateApplicationNotification,object:nil,queue:.main) { [weak self] note in
        if let app=note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,app.processIdentifier != owner {self?.valid=false}
      }
      if NSWorkspace.shared.frontmostApplication?.processIdentifier != owner {valid=false}
      if start != nil {DispatchQueue.main.asyncAfter(deadline:.now()+0.06) { [weak self] in
        self?.keys.settle(count:Self.count(.keyDown),lastKey:Self.lastKey)
      }}
    }
    func stopKey() {keys.stopKey()}
    func stop() {valid=false;if let activation {NSWorkspace.shared.notificationCenter.removeObserver(activation);self.activation=nil}}
    deinit {stop()}
  }
  private var fieldOnly=false, unresolved=false, activity:Activity?, focusContainer:AXUIElement?
  var waitingForEditor:Bool {unresolved}
  func resolveEditor()->Self? {
    guard unresolved, activity?.intact == true, let window,
          NSWorkspace.shared.frontmostApplication?.processIdentifier==pid, Access.insertText.granted else {return nil}
    var now=Self.focused(in:pid)
    guard let w=now.window, CFEqual(w,window), activity?.intact == true else {return nil}
    if now.fieldOnly {now.activity=activity}
    if now.protected {return now}
    guard now.canInsertLive, let editor=now.element else {return nil}
    if let container=focusContainer, !CFEqual(container,window) {
      var node:AXUIElement?=editor
      for _ in 0..<64 {
        guard let n=node else {return nil}; if CFEqual(n,container) {return now}
        node=Self.elementAttr(n,kAXParentAttribute)
      }
      return nil
    }
    return now
  }
  mutating func guardLiveField(start:TimeInterval?) {
    if fieldOnly || unresolved {activity=Activity(owner:pid,start:start)}
  }
  func noteStopKey() {activity?.stopKey()}
  func stopObserving() {activity?.stop()}
  fileprivate enum Document: Equatable {
    case file(Data), window(Data), web(AXUIElement,Data)
    static func ==(lhs:Self,rhs:Self)->Bool {
      switch (lhs,rhs) {case let (.file(a),.file(b)), let (.window(a),.window(b)):return a==b
      case let (.web(a,x),.web(b,y)):return CFEqual(a,b) && x==y; default:return false}
    }
  }
  fileprivate var document:Document? = nil
  private var webArea:AXUIElement?, selectionProof:Data?, originalLength:Int?
  private var inWebEditor:Bool {webArea != nil}
  private static func stamp(_ text:String)->Data {Data(SHA256.hash(data:Data(text.utf8)))}
  // AX screen coordinates start at the top left of the primary display; AppKit starts at the bottom left.
  var displayArea:NSRect? {
    guard let window,let p=Self.attr(window,kAXPositionAttribute),let s=Self.attr(window,kAXSizeAttribute),
      CFGetTypeID(p)==AXValueGetTypeID(),CFGetTypeID(s)==AXValueGetTypeID(),let primary=NSScreen.screens.first else {return nil}
    var origin=CGPoint.zero,size=CGSize.zero
    guard AXValueGetValue(p as! AXValue,.cgPoint,&origin),AXValueGetValue(s as! AXValue,.cgSize,&size) else {return nil}
    let rect=CGRect(x:origin.x,y:primary.frame.maxY-origin.y-size.height,width:size.width,height:size.height)
    return NSScreen.screens.compactMap { screen -> (NSScreen,CGFloat)? in
      let overlap=rect.intersection(screen.frame); return overlap.isEmpty ? nil : (screen,overlap.width*overlap.height)
    }.max(by:{$0.1<$1.1})?.0.visibleFrame
  }
  var appName:String? { NSRunningApplication(processIdentifier:pid)?.localizedName }
  private static func attr(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, name as CFString, &value) == .success else { return nil }
    return value
  }
  private static func elementAttr(_ e: AXUIElement, _ n: String) -> AXUIElement? {
    guard let v = attr(e, n), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
    return (v as! AXUIElement)
  }
  private static func canSet(_ e: AXUIElement, _ n: String) -> Bool {
    var b = DarwinBoolean(false)
    return AXUIElementIsAttributeSettable(e, n as CFString, &b) == .success && b.boolValue
  }
  private static func selection(_ e: AXUIElement) -> (range:CFRange?, unreported:Bool) {
    var value:CFTypeRef?
    let status=AXUIElementCopyAttributeValue(e,kAXSelectedTextRangeAttribute as CFString,&value)
    guard status == .success, let v=value, CFGetTypeID(v)==AXValueGetTypeID() else {
      return (nil,[.attributeUnsupported,.noValue,.notImplemented].contains(status))
    }
    var r = CFRange()
    guard AXValueGetValue(v as! AXValue,.cfRange,&r) else {return (nil,false)}
    if (r.location == kCFNotFound || r.location == NSNotFound) && r.length==0 {return (nil,true)}
    guard r.location>=0, r.location<NSNotFound, r.length>=0, r.length<NSNotFound-r.location else {return (nil,false)}
    return (r,false)
  }
  private static var primed:(pid:pid_t,at:TimeInterval)?
  static func prepareEditor(_ app:NSRunningApplication) {
    guard app.processIdentifier != getpid(),Access.insertText.granted else {return}
    let pid=app.processIdentifier,now=ProcessInfo.processInfo.systemUptime
    if let p=primed,p.pid==pid,now-p.at<10 {return}
    primed=(pid,now)
    let id=app.bundleIdentifier ?? ""
    let chromium=["com.google.Chrome","org.chromium.Chromium","com.microsoft.edgemac","com.brave.Browser","company.thebrowser.Browser","com.vivaldi.Vivaldi","com.operasoftware.Opera"].contains {id==$0 || id.hasPrefix($0+".")}
    let electron=app.bundleURL.map{FileManager.default.fileExists(atPath:$0.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path)} ?? false
    guard chromium || electron else {return}
    // Chromium may need two seconds to publish its tree. Prime on activation, before a
    // hotkey, without querying the tab, selection or document. Electron uses a separate opt-in.
    let ax=AXUIElementCreateApplication(pid);AXUIElementSetMessagingTimeout(ax,0.18)
    _=attr(ax,kAXRoleAttribute)
    _=AXUIElementSetAttributeValue(ax,(electron ? "AXManualAccessibility" : "AXEnhancedUserInterface") as CFString,kCFBooleanTrue)
  }
  static func capture() -> Self? {
    guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid()
    else { return nil }
    prepareEditor(app);return focused(in: app.processIdentifier)
  }
  fileprivate static func focused(in pid: pid_t) -> Self {
    let ax = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(ax, 0.22)
    let granted=Access.insertText.granted
    func systemFocus() -> AXUIElement? {
      guard let e=elementAttr(AXUIElementCreateSystemWide(),kAXFocusedUIElementAttribute) else {return nil}
      var owner:pid_t=0; return AXUIElementGetPid(e,&owner) == .success && owner==pid ? e : nil
    }
    let focusedWindow=granted ? elementAttr(ax,kAXFocusedWindowAttribute) : nil
    func generic(_ e:AXUIElement?)->Bool {
      guard let e,let role=attr(e,kAXRoleAttribute) as? String else {return true}
      return [kAXWindowRole,kAXApplicationRole,"AXWebArea",kAXGroupRole,kAXScrollAreaRole].contains(role)
    }
    func focusedElement()->AXUIElement? {
      let appFocus=elementAttr(ax,kAXFocusedUIElementAttribute)
      if let appFocus,!generic(appFocus) {return appFocus}
      // Some apps report a container here but name its actual field on the window or
      // system focus channel. Never guess a descendant from a list of text fields.
      let windowFocus=focusedWindow.flatMap{elementAttr($0,kAXFocusedUIElementAttribute)}
      if let windowFocus,!generic(windowFocus) {return windowFocus}
      return systemFocus() ?? appFocus ?? windowFocus
    }
    var el=granted ? focusedElement() : nil
    if granted, generic(el) {
      // Some browser-based editors expose their accessibility tree only on first demand.
      if canSet(ax,"AXManualAccessibility") { _=AXUIElementSetAttributeValue(ax,"AXManualAccessibility" as CFString,kCFBooleanTrue); el=focusedElement() ?? el }
    }
    // Secure Event Input applies to the entire login session, not the focused field.
    // Inspect only metadata along the focus path before reading a caret, selection or text.
    // AppKit's canonical flag and the alternate spelling used by some editors are distinct.
    let keys = [kAXRoleAttribute, kAXSubroleAttribute, NSAccessibility.Attribute.containsProtectedContent.rawValue,
                "AXProtectedContent", kAXParentAttribute] as CFArray
    var node = el, editor: AXUIElement?, webRoot: AXUIElement?, ownerWindow:AXUIElement?, secure = false, complete = false, nonText = false, textEntry=false
    for depth in 0..<64 {
      guard let e = node else { break }
      var reply: CFArray?
      guard AXUIElementCopyMultipleAttributeValues(e, keys, [], &reply) == .success,
            let values = reply as? [AnyObject], values.count == 5, let role = values[0] as? String else { break }
      let subrole = values[1] as? String ?? ""
      if [role, subrole].contains(where: { $0.localizedCaseInsensitiveContains("secure") || $0.localizedCaseInsensitiveContains("password") })
        || (values[2] as? NSNumber)?.boolValue == true || (values[3] as? NSNumber)?.boolValue == true {
        secure = true; break
      }
      // Unsupported optional attributes are normal. An unreachable/stale element is not
      // evidence of an ordinary field; never read selected text from an incomplete path.
      guard values[1...3].allSatisfy({ v in
        guard CFGetTypeID(v) == AXValueGetTypeID(), AXValueGetType(v as! AXValue) == .axError else { return true }
        var err = AXError.success
        return AXValueGetValue(v as! AXValue, .axError, &err) && [.attributeUnsupported, .noValue, .notImplemented].contains(err)
      }) else { break }
      if depth == 0 { nonText = [kAXButtonRole, "AXLink", kAXCheckBoxRole, kAXRadioButtonRole, kAXMenuItemRole, kAXPopUpButtonRole].contains(role) }
      if role == kAXWindowRole {ownerWindow=e;complete=true;break}
      if role == kAXApplicationRole {complete=true;break}
      if role == "AXWebArea", webRoot == nil { webRoot = e }
      let textRole = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField"].contains(role)
      if !nonText, editor == nil, depth == 0 || textRole {
        let editableFlag=(attr(e,"AXEditable") as? Bool) ?? (attr(e,kAXIsEditableAttribute) as? Bool)
        if (attr(e,kAXEnabledAttribute) as? Bool)==false || (attr(e,"AXReadOnly") as? Bool)==true || (textRole && editableFlag==false) {nonText=true}
        else if editableFlag==true || canSet(e,kAXSelectedTextAttribute) || (textRole && canSet(e,kAXValueAttribute)) {
          editor=e; textEntry=textRole || editableFlag==true
        }
      }
      node = CFGetTypeID(values[4]) == AXUIElementGetTypeID() ? (values[4] as! AXUIElement) : nil
    }
    let field: Field
    if secure { field = .secure }
    else if complete, editor != nil { field = .editor }
    else if complete, nonText { field = .nonText }
    else { field = .unknown }
    let input = field == .editor ? editor : nil
    let win = granted ? (ownerWindow ?? (input ?? el).flatMap { elementAttr($0,kAXWindowAttribute) } ?? focusedWindow) : nil
    let position=input.map(selection), r=position?.range
    var target = Self(pid: pid, element: input, window: win, range: r, field: field)
    if field == .unknown, granted, win != nil, generic(el), !IsSecureEventInputEnabled() {
      target.unresolved=true; target.focusContainer=el
    }
    if let el = input {
      target.webArea = webRoot
      if let webRoot {
        let raw=attr(webRoot,kAXURLAttribute); let u=(raw as? URL) ?? (raw as? String).flatMap(URL.init(string:))
        // The URL is an identity token, never opened. Desktop web editors also use private schemes.
        if let u, u.scheme != nil { target.document = .web(webRoot, stamp(u.absoluteString)) }
      } else if let win {
        if let path=attr(win,kAXDocumentAttribute) as? String, URL(string:path)?.isFileURL==true {target.document = .file(stamp(path))}
        else if NSRunningApplication(processIdentifier:pid)?.bundleIdentifier=="com.apple.TextEdit", let title=attr(win,kAXTitleAttribute) as? String,!title.isEmpty {target.document = .window(stamp(title))}
      }
      target.originalLength=length(el)
      if let r, r.location>=0, r.length>0, r.length<=65_536,
        let text=verifiedSelection(length:r.length,direct:attr(el,kAXSelectedTextAttribute) as? String,ranged:{slice(el,r)}) { target.selectionProof=stamp(text) }
      if r == nil, position?.unreported == true {
        if let marker=attr(el,"AXSelectedTextMarkerRange"),CFGetTypeID(marker)==AXTextMarkerRangeGetTypeID() {target.selectionMarker=marker}
        else if textEntry {
          var selected:CFTypeRef?
          let status=AXUIElementCopyAttributeValue(el,kAXSelectedTextAttribute as CFString,&selected)
          if [.attributeUnsupported,.noValue,.notImplemented].contains(status) || (status == .success && (selected as? String)?.isEmpty == true) {target.fieldOnly=true}
        }
      }
    }
    return target
  }
  // Web editors may return an empty AXSelectedText for a nonempty selection. Confirm
  // using just the nominated UTF-16 range. Conflicting evidence must never permit a write.
  static func verifiedSelection(length:Int,direct:String?,ranged:()->String?) -> String? {
    guard length>0, length<=65_536 else {return nil}
    let a=direct.flatMap { $0.utf16.count==length ? $0 : nil }
    if let b=ranged() {
      guard b.utf16.count==length, a.map({$0.utf16.elementsEqual(b.utf16)}) ?? true else {return nil}
      return b
    }
    return a
  }
  static func copy(_ text: String, to p: NSPasteboard = .general) -> Bool {
    guard !text.isEmpty else { return false }
    p.clearContents()
    return p.setString(text, forType: .string)
  }
  private func sameEditor(as now:Self)->Bool {
    guard field == .editor, now.field == .editor, pid==now.pid, let a=element, let b=now.element, CFEqual(a,b),
          let w=window, let v=now.window, CFEqual(w,v),document==now.document else {return false}
    switch (webArea,now.webArea) {case (nil,nil):return true;case let (a?,b?):return CFEqual(a,b);default:return false}
  }
  private func sameCursor(as now: Self, live:Bool) -> Bool {
    guard sameEditor(as:now), originalLength == nil || originalLength==now.originalLength else {return false}
    if let r=range {return now.range.map{r.location==$0.location && r.length==$0.length && (r.length==0 || (selectionProof != nil && selectionProof==now.selectionProof))} ?? false}
    if let a=selectionMarker {return now.selectionMarker.map{CFEqual(a,$0)} ?? false}
    // No downgrade if a previously reported caret, marker or selected passage disappears.
    // For an editor with no caret API, a live paste follows its own insertion point only
    // if the same field stayed untouched. Never use this after opening a review window.
    return live && fieldOnly && activity?.intact == true && (now.fieldOnly || now.range?.length==0)
  }
  // A reviewed draft may return to its original app only on an explicit click. Recheck the same
  // window, editable element and selection after activation; a changed target always falls back to copy.
  func insertReviewed(_ text: String, complete: @escaping (InsertOutcome) -> Void) {
    guard Access.insertText.granted else {complete(.permission);return};guard editable else { complete(.available); return }
    let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
    if front == pid { complete(write(text,live:false)); return }
    guard front == getpid(), let app = NSRunningApplication(processIdentifier:pid) else { complete(.moved); return }
    NSApp.yieldActivation(to: app)
    guard app.activate(options:[]) else { complete(.moved); return }
    func attempt(_ left: Int) {
      let current = NSWorkspace.shared.frontmostApplication?.processIdentifier
      if current == pid { complete(write(text,live:false)) }
      else if left == 0 || (current != nil && current != getpid()) { complete(.moved) }
      else { DispatchQueue.main.asyncAfter(deadline:.now()+0.04) { attempt(left-1) } }
    }; attempt(15)
  }
  func insert(_ text: String) -> InsertOutcome { defer {stopObserving()}; return write(text,live:true) }
  private func write(_ text:String,live:Bool)->InsertOutcome {
    guard !text.isEmpty else { return .available }
    if protected { return .secure }
    guard Access.insertText.granted else {return .permission};guard live ? canInsertLive : editable, let old = element else { return .noCaret }
    guard let now = Self.capture() else { return .moved }
    if now.protected { return .secure }
    guard sameCursor(as:now,live:live) else { return .moved }
    // Paste invokes the normal editing transaction in web fields (including input events
    // and undo). Never send Return, replace AXValue or paste blindly into a terminal.
    func awaitingReceipt(_ fallback:InsertOutcome)->InsertOutcome {
      guard let prior=now.originalLength, let r=now.range ?? (prior==0 ? CFRange(location:0,length:0) : nil),r.location<=prior,r.length<=prior-r.location else {return fallback}
      let n=text.utf16.count,expected=prior-r.length+n
      var out=fallback
      out.readBack={
        guard let active=Self.capture(), now.sameEditor(as:active), let e=active.element,active.originalLength==expected,
          active.range.map({ ($0.location==r.location+n && $0.length==0) || ($0.location==r.location && $0.length==n) }) ?? (prior==0),
          let run=Self.slice(e,CFRange(location:r.location,length:n)),run.utf16.elementsEqual(text.utf16) else {return nil}
        var confirmed=InsertOutcome.inserted
        if let doc=now.document {confirmed.passage=Passage.verified(target:now,document:doc,start:r.location,text:text,count:expected)}
        return confirmed
      };return out
    }
    if !now.inWebEditor, !fieldOnly, Self.canSet(old, kAXSelectedTextAttribute) {
      let write=AXUIElementSetAttributeValue(old,kAXSelectedTextAttribute as CFString,text as CFString)
      if write == .success {return awaitingReceipt(.inserted)}
      // Some apps advertise a setter that they explicitly don't implement. Try paste only
      // for those replies; a timed-out write might already have inserted the whole text.
      guard write == .attributeUnsupported || write == .notImplemented else {return Access.insertText.granted ? .unconfirmed : .permission}
    }
    let sent=paste(text) { Self.capture().map { self.sameCursor(as:$0,live:live) } ?? false }
    return sent ? awaitingReceipt(.sent) : .available
  }
  private func paste(_ text:String, stillHere:()->Bool)->Bool {
    guard let src=CGEventSource(stateID:.combinedSessionState),
      let down=CGEvent(keyboardEventSource:src,virtualKey:9,keyDown:true),let up=CGEvent(keyboardEventSource:src,virtualKey:9,keyDown:false) else {return false}
    down.flags = .maskCommand;up.flags = .maskCommand
    return PasteLease.shared.send(text,on:.general,stillHere:stillHere) {down.postToPid(pid);up.postToPid(pid)}
  }
}

// Only an acknowledged insertion can mint a receipt. Web pages must expose both the same
// accessibility document and URL fingerprint. Nothing about the target is persisted.
extension InputTarget {
  private static func length(_ e: AXUIElement) -> Int? { (attr(e, kAXNumberOfCharactersAttribute) as? NSNumber)?.intValue }
  private static func slice(_ e: AXUIElement, _ r: CFRange) -> String? {
    var r = r, v: CFTypeRef?
    guard let value = AXValueCreate(.cfRange, &r),
      AXUIElementCopyParameterizedAttributeValue(e, kAXStringForRangeParameterizedAttribute as CFString, value, &v) == .success
    else { return nil }
    return v as? String
  }
  private static func select(_ r: CFRange, in e: AXUIElement) -> Bool {
    var r = r
    guard let v = AXValueCreate(.cfRange, &r) else { return false }
    return AXUIElementSetAttributeValue(e, kAXSelectedTextRangeAttribute as CFString, v) == .success
  }
  struct Passage {
    enum Write { case replaced, changed, unconfirmed }
    fileprivate let target: InputTarget, document: Document, start: Int
    fileprivate var text: String, count: Int
    func covers(_ original: String) -> Bool { text.utf16.elementsEqual(original.utf16) }
    var appName: String { NSRunningApplication(processIdentifier: target.pid)?.localizedName ?? "原应用" }
    private var range: CFRange { CFRange(location: start, length: text.utf16.count) }
    private var caret: CFRange { CFRange(location: start + range.length, length: 0) }
    fileprivate static func verified(target: InputTarget, document: Document, start: Int, text: String, count: Int) -> Self? {
      let receipt = Self(target: target, document: document, start: start, text: text, count: count)
      guard let e = target.element, InputTarget.canSet(e, kAXSelectedTextRangeAttribute),
        receipt.acknowledged() else { return nil }
      return receipt
    }
    private func acknowledged()->Bool {
      if matches(selection:caret) {return true}
      // Some native editors select the newly inserted run. Collapse only that verified run.
      guard matches(selection:range), let e=target.element, InputTarget.select(caret,in:e) else {return false}
      return matches(selection:caret)
    }
    private func matches(selection: CFRange) -> Bool {
      guard Access.insertText.granted, let e = target.element, let w = target.window,
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier, front == target.pid || front == getpid() else { return false }
      let now = InputTarget.focused(in: target.pid)
      guard now.editable, !now.protected, let el = now.element, CFEqual(el,e), let win = now.window, CFEqual(win,w),
        now.document == document, let selected = now.range, selected.location == selection.location, selected.length == selection.length,
        InputTarget.length(e) == count, let actual = InputTarget.slice(e, range), actual.utf16.elementsEqual(text.utf16)
      else { return false }
      return true
    }
    func replace(with value:String, complete:@escaping(Write,Self?)->Void) {
      guard target.inWebEditor else {
        var updated=self;let result=updated.replaceNative(with:value);complete(result,result == .replaced ? updated : nil);return
      }
      // Use a real paste for web-based editors so their draft state and undo history receive
      // the change. Never reactivate a background tab or send a second paste if a read lags.
      func atFront()->Bool { NSWorkspace.shared.frontmostApplication?.processIdentifier==target.pid }
      guard !value.isEmpty,atFront(),matches(selection:caret),let e=target.element,InputTarget.select(range,in:e) else {complete(.changed,nil);return}
      guard target.paste(value,stillHere:{atFront() && self.matches(selection:self.range)}) else {
        if atFront(),matches(selection:range) {_=InputTarget.select(caret,in:e)}; complete(.changed,nil);return
      }
      let updated=Self(target:target,document:document,start:start,text:value,count:count-range.length+value.utf16.count)
      var pending=InsertOutcome.sent
      pending.readBack={
        guard atFront(),updated.acknowledged() else {return nil}; var out=InsertOutcome.inserted;out.passage=updated;return out
      };pending.resolved { answer in complete(answer.passage == nil ? .unconfirmed : .replaced,answer.passage) }
    }
    private mutating func replaceNative(with value: String) -> Write {
      guard !value.isEmpty, matches(selection: caret), let e = target.element,
        InputTarget.canSet(e, kAXSelectedTextAttribute), InputTarget.select(range, in: e) else { return .changed }
      // Read back the selection, text and owner after selecting. Never set the whole document,
      // search for an occurrence, send keystrokes, or write into an arbitrary current selection.
      guard matches(selection: range), let selected = InputTarget.attr(e, kAXSelectedTextAttribute) as? String,
        selected.utf16.elementsEqual(text.utf16) else {
        if matches(selection: range) { _ = InputTarget.select(caret, in: e) }; return .changed
      }
      let status = AXUIElementSetAttributeValue(e, kAXSelectedTextAttribute as CFString, value as CFString)
      let updated = Self(target: target, document: document, start: start, text: value, count: count-range.length+value.utf16.count)
      guard status == .success, updated.acknowledged() else { return .unconfirmed }
      text = value; count = updated.count
      return .replaced
    }
  }
}
