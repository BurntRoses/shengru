import AppKit
import ApplicationServices
import Carbon

// A private drawing surface can be the first responder without publishing its text.
// Bind it at key-down. Only inspect focus metadata, never AXValue, selected text,
// descendants, menu items or window titles in these applications.
final class ResponderPaste {
  enum Binding { case ready(ResponderPaste), protected, unavailable }
  private struct Anchor {
    let window: AXUIElement, focus: AXUIElement, caret: CFRange?
    func matches(_ other: Self) -> Bool {
      guard CFEqual(window, other.window), CFEqual(focus, other.focus) else { return false }
      guard let caret else { return other.caret.map { $0.length == 0 } ?? true }
      return other.caret.map { $0.location == caret.location && $0.length == caret.length } == true
    }
  }
  private enum Snapshot { case ready(Anchor), protected, unavailable }
  private let owner: pid_t, app: AXUIElement, initial: Anchor
  private var used = false, moved = false, observer: AXObserver?
  var window: AXUIElement { initial.window }
  private init(_ pid: pid_t, _ application: AXUIElement, _ anchor: Anchor) {
    owner = pid; app = application; initial = anchor
  }

  private static func element(_ node: AXUIElement, _ name: String) -> AXUIElement? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(node, name as CFString, &v) == .success,
          let v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
    return (v as! AXUIElement)
  }
  private static let keys = [kAXRoleAttribute, kAXSubroleAttribute,
    NSAccessibility.Attribute.containsProtectedContent.rawValue, "AXProtectedContent", kAXEnabledAttribute,
    "AXReadOnly", kAXModalAttribute, kAXParentAttribute] as CFArray
  private static let excludedRoles: Set<String> = [kAXMenuRole, kAXMenuBarRole, kAXMenuItemRole, kAXSheetRole,
    "AXToolbar", kAXPopUpButtonRole, kAXCheckBoxRole, kAXRadioButtonRole, "AXLink", "AXRow", "AXCell"]
  private static let textRoles: Set<String> = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField"]
  private static let nonEditors: Set<String> = [kAXListRole, kAXTableRole, kAXOutlineRole, kAXStaticTextRole,
    kAXImageRole, kAXWindowRole, kAXApplicationRole]
  private static let containerRoles: Set<String> = [kAXApplicationRole, kAXWindowRole, kAXGroupRole, kAXScrollAreaRole, "AXWebArea"]
  private static func attribute(_ node: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(node, name as CFString, &value) == .success else { return nil }
    return value
  }
  private static func focusedDescendant(_ node: AXUIElement) -> AXUIElement {
    var current = node
    for _ in 0..<12 {
      guard let role = attribute(current, kAXRoleAttribute) as? String, containerRoles.contains(role),
            let next = element(current, kAXFocusedUIElementAttribute), !CFEqual(next, current) else { break }
      current = next
    }
    return current
  }
  // Unsupported optional attributes are normal; a timed-out protection check is not.
  private static func usable(_ value: AnyObject) -> Bool {
    guard CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError else { return true }
    var error = AXError.success
    return AXValueGetValue(value as! AXValue, .axError, &error) && [.attributeUnsupported, .noValue, .notImplemented].contains(error)
  }
  // A custom surface can report AXButton or AXGroup while acting as a text editor.
  // A missing press action or a familiar app name is not evidence of editability.
  private static func bind(_ focus: AXUIElement, role: String, window: AXUIElement) -> Snapshot {
    guard !nonEditors.contains(role) else { return .unavailable }
    let attributes = [kAXSelectedTextRangeAttribute, kAXIsEditableAttribute, "AXEditable"] as CFArray
    var reply: CFArray?
    guard AXUIElementCopyMultipleAttributeValues(focus, attributes, [], &reply) == .success,
          let v = reply as? [AnyObject], v.count == 3, v.allSatisfy(usable) else { return .unavailable }
    let flags = v[1...2].compactMap { ($0 as? NSNumber)?.boolValue }
    guard !flags.contains(false) else { return .unavailable }
    var caret: CFRange?
    if CFGetTypeID(v[0]) == AXValueGetTypeID(), AXValueGetType(v[0] as! AXValue) != .axError {
      var r = CFRange()
      guard AXValueGetValue(v[0] as! AXValue, .cfRange, &r) else { return .unavailable }
      if r.location != kCFNotFound && r.location != NSNotFound {
        guard r.location >= 0, r.length >= 0, r.length < NSNotFound - r.location else { return .unavailable }
        caret = r
      } else if r.length != 0 { return .unavailable }
    }
    if !textRoles.contains(role) && !flags.contains(true) {
      var writable = DarwinBoolean(false)
      let replacesText = AXUIElementIsAttributeSettable(focus, kAXSelectedTextAttribute as CFString, &writable) == .success && writable.boolValue
      guard replacesText || caret != nil else { return .unavailable }
      if role == kAXButtonRole && !replacesText {
        var actions: CFArray?
        guard AXUIElementCopyActionNames(focus, &actions) == .success, let names = actions as? [String],
              !names.contains(kAXPressAction) else { return .unavailable }
      }
    }
    return .ready(Anchor(window: window, focus: focus, caret: caret))
  }
  private static func snapshot(_ app: AXUIElement, _ pid: pid_t) -> Snapshot {
    guard !IsSecureEventInputEnabled() else { return .protected }
    guard pid > 0, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
          let window = element(app, kAXFocusedWindowAttribute) else { return .unavailable }
    // The app can report its canvas as a window while the system reports the actual
    // focused control. Prefer specific focus, including password fields and buttons.
    let choices = [element(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute),
                   element(app, kAXFocusedUIElementAttribute), element(window, kAXFocusedUIElementAttribute)]
      .compactMap { $0 }.filter { var owner: pid_t = 0; return AXUIElementGetPid($0, &owner) == .success && owner == pid }
    let resolved = choices.map(focusedDescendant)
    let specific = resolved.first { item in
      var v: CFTypeRef?
      return AXUIElementCopyAttributeValue(item, kAXRoleAttribute as CFString, &v) == .success
        && (v as? String).map { !containerRoles.contains($0) } == true
    }
    guard let focus = specific ?? resolved.first(where: { !CFEqual($0, app) }) else { return .unavailable }
    var node = focus, focusRole = "", eligible = true
    for depth in 0..<40 {
      var reply: CFArray?
      guard AXUIElementCopyMultipleAttributeValues(node, keys, [], &reply) == .success,
            let v = reply as? [AnyObject], v.count == 8, let role = v[0] as? String,
            v[1...6].allSatisfy(usable) else { return .unavailable }
      let subrole = v[1] as? String ?? ""
      if [role, subrole].contains(where: { $0.localizedCaseInsensitiveContains("secure") || $0.localizedCaseInsensitiveContains("password") })
        || (v[2] as? NSNumber)?.boolValue == true || (v[3] as? NSNumber)?.boolValue == true { return .protected }
      if (v[4] as? NSNumber)?.boolValue == false || (v[5] as? NSNumber)?.boolValue == true
        || (v[6] as? NSNumber)?.boolValue == true || excludedRoles.contains(role) { eligible = false }
      if depth == 0 { focusRole = role }
      if CFEqual(node, window) {
        guard eligible, role == kAXWindowRole, subrole == kAXStandardWindowSubrole || subrole.isEmpty,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return .unavailable }
        return bind(focus, role: focusRole, window: window)
      }
      guard role != kAXWindowRole, CFGetTypeID(v[7]) == AXUIElementGetTypeID() else { return .unavailable }
      node = v[7] as! AXUIElement
    }
    return .unavailable
  }
  static func capture(pid: pid_t) -> Binding {
    guard pid > 0, Access.insertText.granted else { return .unavailable }
    let app = AXUIElementCreateApplication(pid); AXUIElementSetMessagingTimeout(app, 0.18)
    switch snapshot(app, pid) {
    case .ready(let anchor): return .ready(ResponderPaste(pid, app, anchor))
    case .protected: return .protected
    case .unavailable: return .unavailable
    }
  }
  func observe() {
    guard observer == nil else { return }
    var o: AXObserver?
    if AXObserverCreate(owner, { _, _, _, context in
      guard let context else { return }
      let selfRef = Unmanaged<ResponderPaste>.fromOpaque(context).takeUnretainedValue()
      if selfRef.check() != nil { selfRef.moved = true }
    }, &o) == .success, let o {
      observer = o
      for event in [kAXFocusedWindowChangedNotification, kAXFocusedUIElementChangedNotification] {
        _ = AXObserverAddNotification(o, app, event as CFString, Unmanaged.passUnretained(self).toOpaque())
      }
      CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), .commonModes)
    }
  }
  deinit { if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) } }
  private func check() -> InsertOutcome? {
    guard !moved else { return .moved }
    switch Self.snapshot(app, owner) {
    case .protected: return .secure
    case .ready(let now) where initial.matches(now): return nil
    default: return .moved
    }
  }
  func insert(_ text: String, while intact: () -> Bool) -> InsertOutcome {
    guard !used, !text.isEmpty else { return .unavailable }; used = true
    return PasteShortcut.send(text, to: owner) { intact() ? self.check() : .moved }
  }
}

// One ordinary key equivalent, addressed to one process. No global keyboard event,
// Return, menu traversal, or second attempt if the client ignores the paste.
struct PasteShortcut {
  let down: CGEvent, up: CGEvent
  init?() {
    // Command shortcuts follow the active command layout, not necessarily a US keyboard.
    guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
          let data = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData),
          let bytes = CFDataGetBytePtr(Unmanaged<CFData>.fromOpaque(data).takeUnretainedValue()) else { return nil }
    let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
    let key = withExtendedLifetime(source) { () -> CGKeyCode? in
      let type = UInt32(LMGetKbdType())
      func isV(_ code: UInt16) -> Bool {
        var dead: UInt32 = 0, length = 0, chars = [UniChar](repeating: 0, count: 4)
        return UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), UInt32(cmdKey >> 8), type,
                              OptionBits(kUCKeyTranslateNoDeadKeysMask), &dead, chars.count, &length, &chars) == noErr
          && length == 1 && (chars[0] == 118 || chars[0] == 86)
      }
      let ansi = UInt16(kVK_ANSI_V)
      return isV(ansi) ? ansi : (UInt16(0)..<UInt16(128)).first(where: isV)
    }
    guard let key, let events = CGEventSource(stateID: .combinedSessionState),
          let d = CGEvent(keyboardEventSource: events, virtualKey: key, keyDown: true),
          let u = CGEvent(keyboardEventSource: events, virtualKey: key, keyDown: false) else { return nil }
    down = d; up = u; down.flags = .maskCommand; up.flags = .maskCommand
  }
  func post(to pid: pid_t) { down.postToPid(pid); up.postToPid(pid) }

  static func send(_ text: String, to pid: pid_t, check: () -> InsertOutcome?) -> InsertOutcome {
    guard pid > 0, !text.isEmpty else { return .unavailable }
    guard Access.insertText.granted, CGPreflightPostEventAccess() else { return .permission }
    guard let shortcut = Self() else { return .unavailable }
    var rejected: InsertOutcome?
    let posted = PasteLease.shared.send(text, on: .general, stillHere: {
      rejected = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid ? check() : .moved
      if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid { rejected = .moved }
      return rejected == nil
    }) { shortcut.post(to: pid) }
    return posted ? .handedOff : (rejected ?? .clipboardBusy)
  }
}
