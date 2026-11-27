import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
  private var statusItem: NSStatusItem!, desk: Desk!, capsule: CapsuleController!,
    window: NSWindow?, refreshTimer: Timer?, watches: [NSObjectProtocol] = []
  private let menu = NSMenu()
  private var welcome: NSWindow?
  private var finishingForQuit = false, removingApp = false, showHighlights = false
  private var releaseWindow:NSWindow?
  func applicationDidFinishLaunching(_ notification: Notification) {
    let bundle=Bundle.main.bundleURL.standardizedFileURL
    guard Installation.prepare(bundle) else {
      // The installer may be launching the installed copy asynchronously.
      if !Installation.handingOff { NSApp.terminate(nil) };return
    }
    do {
      let library = try Library(root: Library.home)
      guard let res = Bundle.main.resourceURL else { throw VoiceFault.message("找不到应用资源。") }
      desk = Desk(library, model: res.appendingPathComponent("Speech"))
    } catch {
      let alert = NSAlert()
      alert.messageText = "无法打开如流"
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
    desk.uninstall = { [weak self] in self?.removeInstallation() }
    menu.autoenablesItems = false
    menu.delegate = self
    statusItem.menu = menu
    statusItem.button?.toolTip = "如流 · 听写菜单"
    statusItem.button?.setAccessibilityIdentifier("PhraseFlowStatusItem")
    statusIcon()
    desk.start()
    let nc = NSWorkspace.shared.notificationCenter
    watches.append(nc.addObserver(forName:NSWorkspace.didActivateApplicationNotification,object:nil,queue:.main) { [weak self] note in
      MainActor.assumeIsolated {guard let d=self?.desk,d.options.autoInsert,let app=note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {return}; InputTarget.prepareEditor(app)}
    })
    for n in [
      NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification,
      NSWorkspace.screensDidSleepNotification,
    ] {
      watches.append(
        nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated {self?.desk.interruptCapture()}
        })
    }
    watches.append(
      nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
        [weak self] _ in
        MainActor.assumeIsolated {self?.desk.reconnectKeyboard()}
      })
    refreshTimer = Timer.scheduledTimer(withTimeInterval:2, repeats:true) { [weak self] _ in
      MainActor.assumeIsolated {
      guard let self else { return }; self.desk.refresh(); self.presentReleaseIfNeeded()
      }
    }
    showHighlights=desk.updates.needsHighlights(firstUse:!desk.options.welcomed)
    if !desk.options.welcomed { onboard() } else if showHighlights { open(.dictate) }
    desk.updates.check(quiet:true)
  }
  private func installMenu() {
    let main=NSMenu(); let appItem=NSMenuItem(); main.addItem(appItem); let a=NSMenu(); appItem.submenu=a
    let pref=a.addItem(withTitle:"设置…",action:#selector(settings),keyEquivalent:","); pref.target=self
    a.addItem(.separator()); a.addItem(withTitle:"隐藏如流",action:#selector(NSApplication.hide(_:)),keyEquivalent:"h"); a.addItem(withTitle:"退出如流",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
    let editItem=NSMenuItem(); main.addItem(editItem); let e=NSMenu(title:"编辑"); editItem.submenu=e
    for (label,selector,key) in [("撤销","undo:","z"),("重做","redo:","Z"),("剪切","cut:","x"),("复制","copy:","c"),("粘贴","paste:","v"),("全选","selectAll:","a")] { e.addItem(withTitle:label,action:Selector(selector),keyEquivalent:key) }
    let win=NSMenuItem(); main.addItem(win); let w=NSMenu(title:"窗口"); win.submenu=w
    w.addItem(withTitle:"打开听写",action:#selector(home),keyEquivalent:"").target=self
    w.addItem(withTitle:"最小化",action:#selector(NSWindow.performMiniaturize(_:)),keyEquivalent:"m"); w.addItem(withTitle:"关闭窗口",action:#selector(NSWindow.performClose(_:)),keyEquivalent:"w"); NSApp.windowsMenu=w; NSApp.mainMenu=main
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool { false }
  func applicationDidBecomeActive(_ notification: Notification) { desk?.refresh(retryKeyboard:true) }
  private func statusIcon() {
    let listening = desk?.phase == .listen
    guard let button = statusItem?.button else { return }
    button.image = listening ? BrandArtwork.menuRecording : BrandArtwork.menuIdle
    button.contentTintColor = listening ? .systemGreen : nil
    button.setAccessibilityLabel(listening ? "如流，正在听写" : "如流")
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
    if desk.updates.hasBadge { _ = add("有新版本…",#selector(updatesPage),"bell.badge") }
    _ = add("设置…", #selector(settings), "gearshape", ",")
    menu.addItem(.separator())
    _ = add("退出如流", #selector(quit), nil, "q")
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
  @objc func updatesPage() { desk.settingsSection = .updates; open(.settings) }
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
    guard desk.options.welcomed else { onboard(); return }
    desk.page = page
    if page == .dictate, desk.panelEditing { desk.editLast(open:false) }
    if page == .dictate && desk.rehearing == nil && desk.awaitingReview && !desk.editing { desk.editLast(open: false) }
    desk.refresh()
    if window == nil {
      let w = NSWindow(
        contentRect: NSRect(origin: .zero, size: Layout.window),
        styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
        backing: .buffered, defer: false)
      w.title = "如流"
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
    if let window { Self.present(window) }
  }
  private func onboard() {
    if let welcome, welcome.isVisible { Self.present(welcome); return }
    let w = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 460, height: 365), styleMask: [.titled, .closable],
      backing: .buffered, defer: false)
    w.title = "如流使用引导"
    w.titleVisibility = .hidden
    w.titlebarAppearsTransparent = true
    w.collectionBehavior = [.moveToActiveSpace,.fullScreenAuxiliary]
    w.isReleasedWhenClosed = false
    let v = WelcomeView(d: desk) { [weak self] in
      guard let s = self else { return }
      s.desk.options.welcomed = true
      s.welcome?.orderOut(nil)
      if let w=s.window, w.isVisible { Self.present(w) } else { NSApp.hide(nil) }
    }
    let root = NSHostingView(rootView: v)
    w.contentView = root
    w.setContentSize(root.fittingSize)
    w.center()
    welcome = w
    Self.present(w)
  }
  private func presentReleaseIfNeeded() {
    guard let w=window, NSApp.isActive,w.isKeyWindow,w.isVisible,w.attachedSheet == nil,
          welcome?.isVisible != true,desk.options.welcomed,desk.allowsUpdateRestart,desk.phase == .idle,
          showHighlights || (desk.updates.announceOffer && desk.updates.hasBadge) else {return}
    let highlights=showHighlights
    let sheet=NSWindow(contentRect:NSRect(x:0,y:0,width:445,height:240),styleMask:[.titled],backing:.buffered,defer:false)
    sheet.title=highlights ? "新版特性" : "如流更新"; sheet.isReleasedWhenClosed=false
    let view=ReleaseSheet(d:desk,updates:desk.updates,highlights:highlights) { [weak w,weak sheet] in if let sheet { w?.endSheet(sheet) } }
    let host=NSHostingView(rootView:view);sheet.contentView=host; sheet.setContentSize(host.fittingSize);releaseWindow=sheet
    if highlights {showHighlights=false;desk.updates.sawHighlights()} else {desk.updates.announceOffer=false}
    w.beginSheet(sheet){[weak self] _ in self?.releaseWindow=nil}
  }
  private func removeInstallation() {
    guard desk.allowsUpdateRestart,!desk.updates.busy else { return }
    let a=NSAlert();a.messageText="卸载如流？";a.informativeText="仅移除应用会保留记录和设置。卸载后，程序坞可能短暂刷新。"
    a.addButton(withTitle:"取消");a.addButton(withTitle:"仅移除应用");a.addButton(withTitle:"连同本机资料删除…")
    let choice=a.runModal(); guard choice == .alertSecondButtonReturn || choice == .alertThirdButtonReturn else {return}
    let erase=choice == .alertThirdButtonReturn
    if erase {
      let b=NSAlert();b.alertStyle = .warning;b.messageText="永久删除本机资料并卸载？";b.informativeText="所有听写文字、录音、自建词库、修改记忆、已装模型和设置都将删除，无法恢复。";b.addButton(withTitle:"取消");b.addButton(withTitle:"删除资料并卸载");guard b.runModal() == .alertSecondButtonReturn else {return}
    }
    let bundle=Bundle.main.bundleURL
    guard Installation.installed(bundle), Bundle.main.bundleIdentifier == Installation.id else {return}
    do {try FileManager.default.trashItem(at:bundle,resultingItemURL:nil)} catch {NSAlert(error:error).runModal();return}
    removingApp=true;refreshTimer?.invalidate();desk.shutdown()
    NSApp.setActivationPolicy(.accessory)
    if erase { do {try Installation.eraseData(library:desk.lib.root,home:FileManager.default.homeDirectoryForCurrentUser,domain:Installation.id,defaults:.standard)} catch {NSAlert(error:error).runModal()} }
    DispatchQueue.main.async { Installation.clearDockRecent(at:bundle); NSApp.terminate(nil) }
  }
  func windowWillClose(_ notification: Notification) { desk?.stopAudio(); desk?.previewing = false }
  func applicationShouldTerminate(_ sender:NSApplication) -> NSApplication.TerminateReply {
    if removingApp { return .terminateNow }
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
    guard desk != nil else { return false } // The installer has no dictation workspace.
    if desk?.options.welcomed == false {
      if let welcome, welcome.isVisible { Self.present(welcome) } else { onboard() }
    } else {
      open(.dictate)
    }
    return true
  }
  func applicationWillTerminate(_ notification: Notification) {
    if !removingApp {desk?.shutdown()}
    refreshTimer?.invalidate()
    for t in watches { NSWorkspace.shared.notificationCenter.removeObserver(t) }
  }
}
let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
