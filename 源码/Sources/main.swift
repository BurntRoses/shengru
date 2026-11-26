import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
  private var statusItem: NSStatusItem!, desk: Desk!, capsule: CapsuleController!,
    window: NSWindow?, refreshTimer: Timer?, watches: [NSObjectProtocol] = []
  private let menu = NSMenu(), launcher = WindowShortcut()
  private var welcome: NSWindow?
  private var finishingForQuit = false
  private var nextShortcutAttempt = Date.distantPast
  func applicationDidFinishLaunching(_ notification: Notification) {
    let bundle=Bundle.main.bundleURL.standardizedFileURL
    // Grants bound to a translocated or mounted copy are lost when the user later installs it.
    if Self.needsInstall(bundle,readOnly:(try? bundle.resourceValues(forKeys:[.volumeIsReadOnlyKey]).volumeIsReadOnly)==true) {
      let alert=NSAlert();alert.messageText="先将语音输入拖入“应用程序”"
      alert.informativeText="从“应用程序”打开后，再允许麦克风和辅助功能。";alert.addButton(withTitle:"好")
      NSApp.activate();alert.runModal();NSApp.terminate(nil);return
    }
    do {
      let library = try Library(root: Library.home)
      guard let res = Bundle.main.resourceURL else { throw VoiceFault.message("找不到应用资源。") }
      desk = Desk(library, model: res.appendingPathComponent("Speech"))
    } catch {
      let alert = NSAlert()
      alert.messageText = "无法打开语音输入"
      alert.informativeText = error.localizedDescription
      alert.runModal()
      NSApp.terminate(nil)
      return
    }
    installMenu()
    capsule = CapsuleController(desk)
    desk.onChange = { [weak self] in self?.capsule.sync() }
    desk.onMenu = { [weak self] in self?.statusIcon() }
    desk.openPage = { [weak self] p in self?.open(p) }
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    desk.openGuide = { [weak self] in self?.onboard() }
    launcher.action = { [weak self] in self?.open(.dictate) }
    desk.openShortcut = launcher.install()
    statusItem.button?.toolTip = "语音输入 · 点按打开，右键查看菜单"
    statusItem.button?.target = self; statusItem.button?.action = #selector(statusPressed)
    statusItem.button?.sendAction(on:[.leftMouseUp,.rightMouseUp])
    menu.autoenablesItems = false
    menu.delegate = self
    statusIcon()
    desk.start()
    let nc = NSWorkspace.shared.notificationCenter
    watches.append(nc.addObserver(forName:NSWorkspace.didActivateApplicationNotification,object:nil,queue:.main) { [weak self] note in
      guard let d=self?.desk,d.options.autoInsert,let app=note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {return}; InputTarget.prepareEditor(app)
    })
    for n in [
      NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification,
      NSWorkspace.screensDidSleepNotification,
    ] {
      watches.append(
        nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in
          self?.desk.interruptCapture()
        })
    }
    watches.append(
      nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
        [weak self] _ in
        guard let d = self?.desk else { return }
        d.reconnectKeyboard()
      })
    refreshTimer = Timer.scheduledTimer(withTimeInterval:2, repeats:true) { [weak self] _ in
      guard let self else { return }; self.desk.refresh()
      if !self.desk.openShortcut && Date() >= self.nextShortcutAttempt {
        self.nextShortcutAttempt = Date().addingTimeInterval(15)
        if self.launcher.install() { self.desk.openShortcut = true }
      }
    }
    open(.dictate)
  }
  static func needsInstall(_ url:URL,readOnly:Bool)->Bool {
    let path=url.standardizedFileURL.path
    return (path.hasPrefix("/Volumes/") && readOnly) || ((path.hasPrefix("/private/var/folders/") || path.hasPrefix("/var/folders/")) && url.pathComponents.contains("AppTranslocation"))
  }
  private func installMenu() {
    let main=NSMenu(); let appItem=NSMenuItem(); main.addItem(appItem); let a=NSMenu(); appItem.submenu=a
    let pref=a.addItem(withTitle:"设置…",action:#selector(settings),keyEquivalent:","); pref.target=self
    a.addItem(.separator()); a.addItem(withTitle:"隐藏语音输入",action:#selector(NSApplication.hide(_:)),keyEquivalent:"h"); a.addItem(withTitle:"退出语音输入",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
    let editItem=NSMenuItem(); main.addItem(editItem); let e=NSMenu(title:"编辑"); editItem.submenu=e
    for (label,selector,key) in [("撤销","undo:","z"),("重做","redo:","Z"),("剪切","cut:","x"),("复制","copy:","c"),("粘贴","paste:","v"),("全选","selectAll:","a")] { e.addItem(withTitle:label,action:Selector(selector),keyEquivalent:key) }
    let win=NSMenuItem(); main.addItem(win); let w=NSMenu(title:"窗口"); win.submenu=w
    w.addItem(withTitle:"打开听写",action:#selector(home),keyEquivalent:"1").target=self
    w.addItem(withTitle:"最小化",action:#selector(NSWindow.performMiniaturize(_:)),keyEquivalent:"m"); w.addItem(withTitle:"关闭窗口",action:#selector(NSWindow.performClose(_:)),keyEquivalent:"w"); NSApp.windowsMenu=w; NSApp.mainMenu=main
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool { false }
  func applicationDidBecomeActive(_ notification: Notification) { desk?.refresh(retryKeyboard:true) }
  @objc private func statusPressed() {
    guard let button = statusItem.button else { return }
    let event = NSApp.currentEvent
    if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
      menu.popUp(positioning:nil,at:NSPoint(x:0,y:button.bounds.maxY+3),in:button)
    } else { open(.dictate) }
  }
  private func statusIcon() {
    let listening = desk?.phase == .listen
    let sym = listening ? "waveform.circle.fill" : "waveform"
    let icon = NSImage(systemSymbolName: sym, accessibilityDescription: listening ? "正在听写" : "语音输入")
    icon?.isTemplate = true
    statusItem?.button?.image = icon
    statusItem?.button?.contentTintColor = listening ? .systemGreen : nil
  }
  private func add(
    _ title: String, _ action: Selector?, _ symbol: String? = nil, _ key: String = ""
  ) -> NSMenuItem {
    let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
    i.target = self
    if let n = symbol { i.image = NSImage(systemSymbolName: n, accessibilityDescription: nil) }
    menu.addItem(i)
    return i
  }
  func menuNeedsUpdate(_ menu: NSMenu) {
    desk.refresh()
    menu.removeAllItems()
    let listening = desk.phase == .listen
    let toggle = add(
      listening ? "结束听写" : "开始持续听写", #selector(toggle), listening ? "stop.fill" : "mic")
    toggle.isEnabled = desk.ready && desk.phase != .finish
    if listening { _ = add("取消本次听写", #selector(cancel), "xmark") }
    menu.addItem(.separator())
    _ = add("打开听写", #selector(home), "waveform")
    let copy=add("复制上次听写",#selector(copyLast),"doc.on.doc");copy.isEnabled = !desk.last.isEmpty && !desk.recordingBusy && !desk.editing && !desk.awaitingReview && !desk.confirming
    let replay = add(desk.rehearing == nil ? "增强上次听写" : "查看增强识别", #selector(rehear), "waveform.badge.magnifyingglass")
    replay.isEnabled = desk.rehearing != nil || (desk.latestReplayID != nil && !desk.recordingBusy && !desk.confirming)
    _ = add("历史记录", #selector(history), "clock.arrow.circlepath")
    _ = add("打开词库", #selector(words), "character.book.closed")
    let item = add("整理方式", nil, "text.alignleft")
    let levels = NSMenu()
    for l in EditLevel.allCases {
      let i = NSMenuItem(title: l.title, action: #selector(mode(_:)), keyEquivalent: "")
      i.target = self
      i.representedObject = l.rawValue
      i.state = desk.options.level == l ? .on : .off
      levels.addItem(i)
    }
    item.submenu = levels
    menu.addItem(.separator())
    _ = add("设置…", #selector(settings), "gearshape", ",")
    menu.addItem(.separator())
    _ = add("退出语音输入", #selector(quit), nil, "q")
  }
  @objc func toggle() { desk.toggle() }
  @objc func cancel() { desk.end(cancel: true) }
  @objc func home() { open(.dictate) }
  @objc func rehear() {
    if let r=desk.rehearing { if r.inCapsule { capsule.sync() } else { open(r.origin) } }
    else { desk.rehear(inCapsule:true) }
  }
  @objc func copyLast() { if !desk.recordingBusy && !desk.editing && !desk.awaitingReview { _=desk.copyCurrent() } }
  @objc func history() { open(.history) }
  @objc func words() { open(.terms) }
  @objc func settings() { open(.settings) }
  @objc func mode(_ i: NSMenuItem) {
    if let s = i.representedObject as? String, let l = EditLevel(rawValue: s) {
      desk.options.level = l
    }
  }
  @objc func quit() { NSApp.terminate(nil) }
  // Called for an explicit open or reopen, never for the non-activating speech panel.
  static func present(_ window: NSWindow) {
    if NSApp.isHidden { NSApp.unhide(nil) }
    if window.isMiniaturized { window.deminiaturize(nil) }
    window.makeKeyAndOrderFront(nil)
    NSApp.activate()
  }
  func open(_ page: Page) {
    if let welcome, welcome.isVisible { Self.present(welcome); return }
    desk.page = page
    if page == .dictate, desk.panelEditing { desk.editLast(open:false) }
    if page == .dictate && desk.rehearing == nil && desk.awaitingReview && !desk.editing { desk.editLast(open: false) }
    desk.refresh()
    if window == nil {
      let w = NSWindow(
        contentRect: NSRect(origin: .zero, size: Layout.window),
        styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
        backing: .buffered, defer: false)
      w.title = "语音输入"
      w.titleVisibility = .hidden
      w.titlebarAppearsTransparent = true
      w.isReleasedWhenClosed = false
      w.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
      w.contentMinSize = Layout.minimum
      let root = NSHostingView(
        rootView: WorkspaceView(d: desk).ignoresSafeArea(.container, edges: .top))
      root.sizingOptions = []
      w.contentView = root
      w.setFrameAutosaveName("VoiceWorkspace")
      if !w.setFrameUsingName("VoiceWorkspace") { w.center() }
      w.delegate = self
      window = w
    }
    if let window { Self.present(window) }; if !desk.options.welcomed { onboard() }
  }
  private func onboard() {
    if let welcome, welcome.isVisible { Self.present(welcome); return }
    let w = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 460, height: 365), styleMask: [.titled, .closable],
      backing: .buffered, defer: false)
    w.title = "设置语音输入"
    w.collectionBehavior = [.moveToActiveSpace,.fullScreenAuxiliary]
    w.isReleasedWhenClosed = false
    let v = WelcomeView(d: desk) { [weak self] in
      guard let s = self else { return }
      s.desk.options.welcomed = true
      s.welcome?.orderOut(nil)
      s.open(.dictate)
    }
    let root = NSHostingView(rootView: v)
    w.contentView = root
    w.setContentSize(root.fittingSize)
    w.center()
    welcome = w
    Self.present(w)
  }
  func windowWillClose(_ notification: Notification) { desk?.stopAudio(); desk?.previewing = false }
  func applicationShouldTerminate(_ sender:NSApplication) -> NSApplication.TerminateReply {
    if finishingForQuit { return .terminateLater }
    if let d = desk, d.recordingBusy {
      if d.reviewBeforeStopping {
        d.interruptCapture { [weak self] in self?.open(.dictate) }; return .terminateCancel
      }
      finishingForQuit = true
      d.interruptCapture { DispatchQueue.main.async { sender.reply(toApplicationShouldTerminate:true) } }
      return .terminateLater
    }
    guard let d = desk, d.awaitingReview || (d.editing && d.draft != d.last) || (d.historyDraft.map{$0.original != $0.text} ?? false) || d.confirming else { return .terminateNow }
    if d.confirming { return .terminateCancel }
    let a = NSAlert(); a.messageText = "放弃未确认的修改并退出？"; a.informativeText = "尚未确认的内容不会保存或输入。"; a.addButton(withTitle:"继续审阅"); a.addButton(withTitle:"放弃并退出")
    if a.runModal() == .alertFirstButtonReturn { open(d.historyDraft != nil ? .history : .dictate); return .terminateCancel }; return .terminateNow
  }
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    if desk?.options.welcomed == false {
      if let welcome, welcome.isVisible { Self.present(welcome) } else { onboard() }
    } else {
      open(.dictate)
    }
    return true
  }
  func applicationWillTerminate(_ notification: Notification) {
    desk?.shutdown()
    refreshTimer?.invalidate()
    for t in watches { NSWorkspace.shared.notificationCenter.removeObserver(t) }
  }
}
struct WelcomeView: View {
  @ObservedObject var d: Desk
  var complete: () -> Void
  @LocalState private var step = 0
  var body: some View {
    VStack(alignment:.leading,spacing:16) {
      HStack(spacing:12) {
        Image(systemName:step == 0 ? "waveform" : "internaldrive").font(.title2).foregroundStyle(Color.inkMint).frame(width:46,height:46).navigationGlass(14)
        VStack(alignment:.leading,spacing:4) {
          Text(step == 0 ? "在这台 Mac 上听写" : "选择要留下的内容").font(.title2.bold()).accessibilityAddTraits(.isHeader)
          Text(step == 0 ? "语音在本机转成文字，断网也能用。" : "记录只保存在当前账户，可随时删除。").font(.callout).foregroundStyle(.secondary)
        }; Spacer(); Text("\(step+1) / 2").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
      }
      if step == 0 {
        Surface(inset:14) { PermissionRows(d:d) }
      } else {
        Surface(inset:14) {
          guideToggle("保存听写文字", $d.options.keepText); Divider(); guideToggle("保留听写录音", $d.options.keepAudio); Divider(); guideToggle("记住我确认的词语修改", $d.options.learning); Divider(); guideToggle("自动收录常用词", $d.options.collectFrequent).disabled(!d.options.keepText).help(FrequencyCopy.note); Divider(); guideToggle("关联连续听写", $d.options.linkContext).disabled(!d.options.keepText)
        }

      }
      Spacer(minLength:0)
      HStack {
        if step == 1 { Button("上一步") { step = 0 }.deskAction() }
        Spacer()
        Button(step == 0 ? "下一步：记录偏好" : "开始使用") {
          if step == 0 { step = 1 } else { complete() }
        }.deskAction(primary:true,large:true).keyboardShortcut(.defaultAction)
      }
    }.padding(22).frame(width:460,height:380).tint(.inkMint).workspaceKeyboard()
  }
  private func guideToggle(_ label:String,_ flag: Binding<Bool>) -> some View { Toggle(isOn:flag) { Text(label).frame(maxWidth:.infinity,alignment:.leading) }.toggleStyle(.switch).frame(minHeight:36).keyCue() }

}
let app = NSApplication.shared
let delegate = AppDelegate()
app.setActivationPolicy(.regular)
app.delegate = delegate
app.run()
