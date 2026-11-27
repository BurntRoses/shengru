import Combine
import Observation
import AVFoundation
import AppKit
import OSLog
import SwiftUI

enum Phase: Equatable { case idle, listen, finish, result, notice }
enum Page: String, CaseIterable {
  case dictate = "听写"
  case history = "历史"
  case terms = "词库"
  case settings = "设置"
  var icon: String {
    switch self {
    case .dictate: return "waveform"
    case .history: return "clock.arrow.circlepath"
    case .terms: return "character.book.closed"
    case .settings: return "slider.horizontal.3"
    }
  }
}
// High-frequency microphone samples belong to their own observation scope. Only the
// waveform, elapsed clock and transcript subscribe; the workspace and editor do not.
@Observable final class LiveCapture {
  var stable = ""
  var tail = ""
  var mark: ProofMark?
  var meterHistory = [Double](repeating: 0, count: 9)
  var level = 0.0
  var seconds = 0.0
}
@Observable final class DraftBuffer { var text = "" }
final class Desk: ObservableObject {
  @Published var settingsSection: SettingsSection = .dictate
  @Published var page: Page = .dictate { didSet {
    if oldValue != page { finishUnchangedEdit(leaving:oldValue) }
    if let r=rehearing, !r.inCapsule, r.origin != page { rehearing=nil }
  } }
  @Published var phase: Phase = .idle { didSet { if (oldValue == .listen) != (phase == .listen) { key.duringDictation(phase == .listen) } } }
  let live = LiveCapture()
  var stable: String { get { live.stable } set { live.stable = newValue } }
  var tail: String { get { live.tail } set { live.tail = newValue } }
  @Published var last = ""
  private var liveMark:ProofMark? { get { live.mark } set { live.mark = newValue } }
  private var lastMark:ProofMark?, fadeMark:DispatchWorkItem?
  func inkBefore(_ text:String)->String? { guard phase == .listen, options.appearance.review, options.appearance.animate, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return nil }; return liveMark?.before(in:text) }
  private func paint(_ mark:ProofMark?) {
    guard let mark else { lastMark=nil; return }; guard mark != lastMark else { return }; lastMark=mark; fadeMark?.cancel(); liveMark=mark
    let work=DispatchWorkItem { [weak self] in self?.liveMark=nil }; fadeMark=work; DispatchQueue.main.asyncAfter(deadline:.now()+1.15,execute:work)
  }
  @Published var raw = ""
  @Published var status = ""
  @Published var icon = "checkmark"
  @MainActor lazy var updates = AppUpdates(self)
  var restartingForUpdate = false
  var allowsUpdateRestart: Bool { !recordingBusy && !awaitingReview && !editing && historyDraft == nil && !confirming && rehearing?.stage != .working && models.installing == nil }
  @Published var panelMoved = false
  var resetPanelPosition: (() -> Void)?
  func restorePanel() {
    options.appearance = CapsuleAppearance(); panelMoved = false; resetPanelPosition?()
  }
  @Published var previewing = false {
    didSet {
      if previewing != oldValue {
        if previewing {
          screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }?.visibleFrame
        }
        onChange?()
      }
    }
  }
  var meterHistory: [Double] { get { live.meterHistory } set { live.meterHistory = newValue } }
  var level: Double { get { live.level } set { live.level = newValue } }
  var seconds: Double { get { live.seconds } set { live.seconds = newValue } }
  @Published var handsFree = false
  @Published var showEdits = false
  @Published private var copiedText: String?
  var copied: Bool { copiedText == copyText }
  private var copyReset: DispatchWorkItem?
  @Published var needsCopy = false
  @Published var ready = false
  @Published var preparing = true
  @Published private(set) var activeModel: SpeechModel?
  @Published private(set) var loadingModel: SpeechModel?
  @Published private(set) var microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
  @Published var allowMic = false
  @Published var allowKey = false
  @Published var allowInsert = false
  @Published private var prompted = Set<Access>()
  @Published private var requestingMic = false
  private var lastPrompt: (Access, TimeInterval)?
  @Published var rows: [Record]
  private var manualWordKeys = Set<String>(), blockedWordKeys = Set<String>()
  @Published private(set) var frequencies: FrequentWords
  private let wordWorker = DispatchQueue(label: "cn.shengru.word-capture", qos: .utility)
  private var wordEpoch = UUID()
  @Published var terms: [Term]
  @Published private(set) var policy: WordPolicy
  @Published var memories: [Term]
  struct HistoryDraft { let id:UUID, original:String; var text:String }
  @Published var historyDraft: HistoryDraft?
  @Published var panelEditing = false
  @Published var editing = false
  @Published var awaitingReview = false
  @Published var confirming = false
  private var learningBase=""
  private let draftBuffer = DraftBuffer()
  var draft: String { get { draftBuffer.text } set { draftBuffer.text=newValue } }
  @Published private(set) var readingChoices: [ReadingChoice] = []
  private struct ReadingEdit {
    let id: UUID, from: String, to: String, inDraft: Bool, choices: [ReadingChoice]
  }
  @Published private var readingTrail=[ReadingEdit]()
  private var readingEdit:ReadingEdit? {
    get {readingTrail.last}
    set {guard let e=newValue else {readingTrail.removeAll();return};if let old=readingTrail.last, old.id != e.id || old.inDraft != e.inDraft || old.to != e.from {readingTrail.removeAll()};if readingTrail.count>=12 {readingTrail.removeFirst()};readingTrail.append(e)}
  }
  var reviewText: String { editing || awaitingReview ? draft : last }
  var canUndoReading: Bool {
    guard let e = readingEdit else { return false }
    return !recordingBusy && !confirming && e.id == lastID && e.inDraft == (editing || awaitingReview) && reviewText == e.to
  }
  @Published var insertedEarlier = false
  @Published var openShortcut = false
  @Published var keyConnected = false
  @Published private(set) var activeTrigger:Trigger = .command
  var usingBackupKey:Bool { keyConnected && activeTrigger != options.trigger }
  let models: ModelShelf
  private struct PendingReview {
    let id: UUID, heard: Heard, options: Options, target: ReviewRecipient?, conversation: UUID?,
      destination: String
  }
  private var replayStageWatch:AnyCancellable?
  @Published var rehearing: Rehearing? {
    didSet {
      if oldValue !== rehearing {
        replayStageWatch=nil; oldValue?.cancel()
        if let r=rehearing { replayStageWatch=r.$stage.dropFirst().sink{ [weak self, weak r] _ in
          self?.objectWillChange.send()
          // @Published sends before assignment. Fit the nonactivating panel to the new result, not the working state.
          DispatchQueue.main.async { [weak self, weak r] in guard let self, let r, self.rehearing === r else { return }; self.onChange?(); self.onMenu?() }
        } }
        if let oldValue, playing == oldValue.recordID { stopAudio() }
        onChange?(); onMenu?()
      }
    }
  }
  private var delivered: (id: UUID, passage: InputTarget.Passage)?
  private(set) var lastID: UUID?
  private var heldReview: PendingReview?, conversation = ConversationWindow()
  private var runConversation: UUID?, destination = "", retryAfter = Date.distantPast
  @Published var options: Options {
    didSet {
      guard oldValue != options else { return }
      do {
        try lib.save(options)
        rows = lib.records
      } catch { message = "设置未能保存：" + error.localizedDescription }
      if (oldValue.collectFrequent && !options.collectFrequent) || (oldValue.keepText && !options.keepText) { wordEpoch = UUID() }
      if oldValue.appearance.position != options.appearance.position { panelMoved=false; resetPanelPosition?() }
      if oldValue.trigger != options.trigger { wasKey=nil; refresh(retryKeyboard:true) }
      if !options.keepText || !options.linkContext {
        conversation.reset()
        runConversation = nil
      }
      onChange?()
    }
  }
  @Published var message = ""
  @Published var playing: UUID?
  var onChange: (() -> Void)?, openPage: ((Page) -> Void)?, onMenu: (() -> Void)?
  var openGuide: (() -> Void)?, uninstall: (() -> Void)?
  private var noSpeechTimer:DispatchWorkItem?, tailTimer:DispatchWorkItem?
  private var skipDelivery = false, afterStop: (() -> Void)?
  var reviewBeforeStopping: Bool { runOptions.reviewFirst }
  private var lastSoundAt = -Double.infinity, firstWordsAt: TimeInterval?
  static func hasWords(_ text:String)->Bool { text.contains { $0.isLetter || $0.isNumber } }
  private func armNoSpeech(_ id:UUID, grace:Bool=false) {
    let task=DispatchWorkItem { [weak self] in
      guard let self,self.session==id,self.phase == .listen else { return }
      let now = ProcessInfo.processInfo.systemUptime
      if let since = self.firstWordsAt, now-since >= 0.35, Self.hasWords(self.stable+self.tail) { return }
      if !grace, ProcessInfo.processInfo.systemUptime-self.lastSoundAt < 1.8 { self.armNoSpeech(id,grace:true) }
      else { self.end(cancel:false) } // Flush even a quiet first word before deciding to dismiss.
    }; noSpeechTimer=task; DispatchQueue.main.asyncAfter(deadline:.now()+(grace ? 3 : 6),execute:task)
  }
  var screen: NSRect?
  let lib: Library
  let audio: SessionAudio
  let mic: CaptureDevice
  let key = Hotkey()
  private enum Press { case start(TimeInterval), stop }
  private var target: InputTarget?, session: UUID?, press: Press?, tag = UUID(),
    runOptions = Options(), runTerms: [Term] = []
  private var sound: AVAudioPlayer?, playTimer: Timer?, wasKey: Bool?
  private var pending: DispatchWorkItem?
  init(_ lib: Library, model: URL, microphone: CaptureDevice = Microphone()) {
    mic = microphone
    self.lib = lib
    models = ModelShelf(builtin: model, root: lib.root)
    frequencies = lib.frequencies
    policy = lib.policy
    memories = lib.memories
    options = lib.options
    rows = lib.records
    terms = lib.terms
    manualWordKeys = Set(lib.terms.flatMap { [$0.spelling.lowercased(), $0.spoken.lowercased()] })
    blockedWordKeys = Set(lib.policy.blocked.map { $0.lowercased() })
    audio = SessionAudio(model: model)
    key.down = { [weak self] in self?.pressed(at:$0) }
    key.up = { [weak self] in self?.released(at:$0) }
    key.cancel = { [weak self] in
      if self?.phase == .listen || self?.phase == .finish {
        self?.end(cancel: true)
      } else if self?.phase == .result || self?.phase == .notice {
        self?.dismiss()
      }
    }
    key.chord = { [weak self] in
      guard let self, let gesture=self.press, self.phase == .listen else {return}
      self.press=nil
      // Using a right modifier as part of another shortcut is not a stop tap.
      if case .start = gesture {self.end(cancel:true)}
    }
    mic.onInterruption = { [weak self] in self?.end(cancel: false) }
  }
  func start() {
    refresh()
    warm()
  }
  var recordingBusy: Bool { phase == .listen || phase == .finish }
  func warm() {
    let choice=options.model
    if models.installed.contains(choice) { selectModel(choice);return }
    if choice.localProfile != nil {
      // Existing 480 ms preferences predate model downloads. Keep them, including offline.
      loadingModel=choice; preparing=true; ready=false
      models.install(choice,onFailure:{ [weak self] in self?.message="原模型未能启用，已改用均衡听写。"; self?.selectModel(.bundled) }) { [weak self] in self?.selectModel(choice) }
    } else { message="找不到所选模型，已改用均衡听写。";selectModel(.bundled) }
  }
  func selectModel(_ choice: SpeechModel, remember: Bool = false) {
    guard !recordingBusy, models.installed.contains(choice) else { return }
    loadingModel = choice
    preparing = true
    ready = false
    audio.warm(using: models.url(choice), package: choice.package) { [weak self] result in
      guard let self else { return }
      self.loadingModel = nil
      self.preparing = false
      switch result {
      case .success:
        self.activeModel = choice
        if remember {var next=self.options;next.model=choice;next.followsModelDefault=choice == .bundled; self.options=next}
        self.ready = true
      case .failure(let e):
        if choice != .bundled {
          self.message = "所选模型无法打开，已返回均衡听写。"
          self.selectModel(.bundled)
        } else {
          self.notice(e.localizedDescription)
        }
      }
      self.onMenu?()
    }
  }
  // Log only changes in system decisions. Never include speech, clipboard contents or app names.
  private static let accessLog = Logger(subsystem: "cn.shengru.dictation", category: "Permissions")
  private var lastAccessState: [Bool]?
  func refresh(retryKeyboard: Bool = false) {
    let state = mic.authorization
    if microphoneStatus != state { microphoneStatus = state }
    if retryKeyboard { retryAfter = .distantPast }
    let m = state == .authorized
    let k = Access.keyboard.granted
    let i = Access.insertText.granted
    if allowMic != m { allowMic = m }
    if allowKey != k { allowKey = k }
    if allowInsert != i { allowInsert = i }
    // A right-hand modifier needs a keyboard tap. Keep the user's preference, but provide
    // a registered chord immediately while that tap is unavailable. Restore it on grant.
    let wanted = options.trigger, preferred = (!wanted.registered && !k) ? Trigger.shortcut : wanted
    if !recordingBusy, wasKey == nil || wasKey != k || ((!key.connected || activeTrigger != preferred) && Date() >= retryAfter) {
      retryAfter = Date().addingTimeInterval(12);wasKey=k;key.install(preferred)
      var actual=preferred
      if !preferred.registered && !key.connected {actual = .shortcut;key.install(actual)}
      if activeTrigger != actual { activeTrigger=actual }
    }
    if keyConnected != key.connected { keyConnected = key.connected }
    let snapshot = [m, k, i, keyConnected]
    if snapshot != lastAccessState {
      lastAccessState = snapshot
      Self.accessLog.notice("microphone=\(m, privacy: .public) microphoneStatus=\(state.rawValue, privacy: .public) inputMonitoring=\(k, privacy: .public) accessibility=\(i, privacy: .public) shortcutConnected=\(self.keyConnected, privacy: .public)")
    }
  }
  func reconnectKeyboard() { wasKey=nil;refresh(retryKeyboard:true) }
  var globalStatus: String {
    if !allowMic { return microphoneStatus == .restricted ? "麦克风受系统限制" : "听写需要麦克风权限" }
    if !keyConnected { return "快捷键不可用，请换一个" }
    if usingBackupKey { return "暂用 " + activeTrigger.rawValue }
    if options.autoInsert && !allowInsert { return "在其他应用中输入需要辅助功能权限" }
    return options.autoInsert ? "可在光标处听写" : "自动输入已关闭"
  }
  func permissionStep(_ access: Access) -> Access.Step {
    access.step(granted: access == .insertText ? allowInsert : allowKey, mic: microphoneStatus,
                asked: prompted.contains(access), pending: requestingMic)
  }
  func perform(_ step: Access.Step, for access: Access) {
    refresh()
    // Honor the button that was tapped, not a different action if the OS state just changed.
    guard step == permissionStep(access) else { return }
    switch step {
    case .ask:
      lastPrompt = (access, ProcessInfo.processInfo.systemUptime)
      if access == .microphone { requestingMic = true }
      else { prompted.insert(access) }
      access.askSystem { [weak self] in self?.requestingMic = false; self?.refresh(retryKeyboard: true) }
    case .settings:
      if let (a,t) = lastPrompt, a == access, ProcessInfo.processInfo.systemUptime - t <= NSEvent.doubleClickInterval { return }
      access.openSettings()
    default: break
    }
  }
  func pressed(at time:TimeInterval = ProcessInfo.processInfo.systemUptime) {
    if phase == .listen && handsFree {
      press = .stop
      if activeTrigger.registered {target?.noteStopKey()}
      return
    }
    guard phase != .finish && phase != .listen else { return }
    press = .start(time)
    begin(held: true)
  }
  func released(at time:TimeInterval = ProcessInfo.processInfo.systemUptime) {
    let gesture=press; press = nil
    guard phase == .listen else { return }
    if case .stop = gesture { end(cancel:false); return }
    guard case let .start(t) = gesture else { return }
    // Focus discovery and first-draw layout may outlast a real tap. Measure the key,
    // not the time the main thread took to deliver its release.
    let short = time-t < 0.23
    if short && runOptions.shortToggle {
      handsFree = true
      onChange?()
    } else {
      end(cancel: short)
    }
  }
  func toggle() {
    if phase == .listen { end(cancel: false) } else if phase != .finish { begin(held: false) }
  }
  var deliveryHint:String? {
    guard phase == .listen, let target else { return nil }
    if runOptions.reviewFirst {return "先审阅"}
    guard runOptions.autoInsert, allowInsert, target.canInsertLive, let name=target.appName else {return "定稿可复制"}
    return "→ " + name
  }
  // A click merely to read/select must not make the next dictation wait for an empty save.
  private func finishUnchangedEdit(leaving surface:Page?=nil) {
    if (NSApp?.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() == true {return}
    if surface != .dictate, let h=historyDraft,h.text==h.original {historyDraft=nil}
    if surface != .history, editing,!awaitingReview,draft==last,(!panelEditing || surface==nil) {
      editing=false;panelEditing=false;onChange?();if phase == .result {hide(in:resultDwell)}
    }
  }
  func begin(held: Bool) {
    guard !restartingForUpdate, session == nil, phase != .finish, !confirming else { return }
    if !options.welcomed, let openGuide {
      openGuide()
      return
    }
    finishUnchangedEdit()
    if historyDraft != nil { openPage?(.history);return }
    if awaitingReview || editing {
      openPage?(.dictate)
      return
    }
    pending?.cancel()
    stopAudio()
    refresh()
    guard ready else {
      notice(preparing ? "正在准备，请稍后再试" : "语音资源不可用")
      if !preparing { warm() }
      return
    }
    target = InputTarget.capture()
    if let reason = target?.recordingNotice {
      target = nil
      notice(reason)
      return
    }
    guard allowMic else {
      if mic.authorization == .notDetermined {
        perform(.ask, for: .microphone)
      }
      notice("需要麦克风权限")
      return
    }
    if options.autoInsert && !options.reviewFirst {
      let start:TimeInterval?
      if activeTrigger.registered, case let .start(t)=press {start=t} else {start=nil}
      target?.guardLiveField(start:start)
    }
    rehearing = nil
    previewing = false
    screen = target?.displayArea ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }?.visibleFrame
    let id = UUID()
    session = id
    skipDelivery = false
    tag = id
    clearCopyFeedback()
    fadeMark?.cancel(); lastMark=nil; liveMark=nil
    runOptions = options
    runTerms = terms.filter(policy.uses)
    destination = target.map { String($0.pid) } ?? "workspace"
    runConversation =
      options.keepText && options.linkContext
      ? conversation.next(for: destination, rows: rows) : nil
    let previous = ConversationWindow.recent(runConversation, rows: rows)
    let learned = options.learning ? memories : []
    stable = ""
    tail = ""
    level = 0
    meterHistory = Array(repeating: 0, count: 9)
    seconds = 0
    handsFree = !held
    needsCopy = false
    showEdits = false
    phase = .listen
    if options.autoInsert && !options.reviewFirst, target?.waitingForEditor==true {bindOpeningEditor(id,attempt:0)}
    firstWordsAt = nil; lastSoundAt = -.infinity; armNoSpeech(id)
    status = ""
    let saved =
      runOptions.keepAudio ? lib.spool.appendingPathComponent(id.uuidString + ".clips") : nil
    audio.begin(
      id, url: saved, level: runOptions.level, terms: runTerms, policy: policy,
      learned: learned, previous: previous, compact:runOptions.compactQuiet, recover:!runOptions.reviewFirst, proof:runOptions.proofWords
    ) { [weak self] e in
      guard let s = self, s.session == id else { return }
      s.mic.stop()
      s.session = nil; s.target = nil
      s.notice(e.localizedDescription)
      s.didStop()
    }
    onChange?()
    onMenu?()
    do {
      try mic.start { [weak self] data in
        guard let s = self else { return }
        s.audio.append(data, id: id) { [weak s] a, b, v, d, mark in
          guard let s = s, s.session == id, s.phase == .listen else { return }
          s.paint(mark)
          let changed = s.stable != a || s.tail != b
          if changed {
            s.stable = a
            s.tail = b
          }
          let now = ProcessInfo.processInfo.systemUptime
          if Self.hasWords(a+b) { if s.firstWordsAt == nil { s.firstWordsAt = now } }
          else { s.firstWordsAt = nil }
          if v > 0.016 { s.lastSoundAt=now }
          s.level += (v - s.level) * (v > s.level ? 0.84 : 0.42)
          s.meterHistory = Array(s.meterHistory.dropFirst()) + [s.level]
          s.seconds = d
          if changed { s.onChange?() }
        }
      }
    } catch {
      mic.stop()
      audio.end(id, cancel: true) { _ in }
      session = nil; target = nil
      notice(error.localizedDescription)
    }
  }
  // A newly activated web editor can publish its focused field just after key-down.
  // Bind only during this opening interval, never by looking for a new target at delivery.
  private func bindOpeningEditor(_ id:UUID,attempt:Int) {
    let delays=[0.12,0.32,0.65]
    DispatchQueue.main.asyncAfter(deadline:.now()+delays[attempt]) { [weak self] in
      guard let self,self.session==id,self.phase == .listen,let initial=self.target,initial.waitingForEditor else {return}
      if let field=initial.resolveEditor() {
        if let reason=field.recordingNotice {self.end(cancel:true);self.notice(reason);return}
        self.target=field;self.onChange?()
      } else if attempt+1<delays.count {self.bindOpeningEditor(id,attempt:attempt+1)}
    }
  }
  private func didStop() {
    let work = afterStop; afterStop = nil; work?()
  }
  // Lock, sleep and quit never paste into a different app. Seal the current chapter,
  // keep normal history preferences, and leave a review-first take uncommitted.
  func interruptCapture(then complete: (() -> Void)? = nil) {
    guard recordingBusy, let id = session else { complete?(); return }
    skipDelivery = true
    if let complete { afterStop = complete }
    if phase == .listen { end(cancel:false) }
    else if tailTimer != nil { tailTimer?.cancel(); finishCapture(id) }
  }
  func end(cancel: Bool) {
    guard recordingBusy, let id = session else { return }
    noSpeechTimer?.cancel(); noSpeechTimer = nil
    press = nil; handsFree = false; level = 0
    if cancel {
      tailTimer?.cancel(); tailTimer = nil; mic.stop()
      session = nil; target = nil; tag = UUID(); phase = .idle
      audio.end(id, cancel:true) { _ in }
      onChange?(); onMenu?(); didStop(); return
    }
    guard phase == .listen else { return }; phase = .finish
    onChange?(); onMenu?()
    if skipDelivery { finishCapture(id); return }
    let work = DispatchWorkItem { [weak self] in self?.finishCapture(id) }
    tailTimer = work
    let recent = ProcessInfo.processInfo.systemUptime - lastSoundAt < 0.55
    DispatchQueue.main.asyncAfter(deadline:.now() + (recent ? 0.34 : 0.12), execute:work)
  }
  private func finishCapture(_ id: UUID) {
    guard phase == .finish, session == id else { return }
    tailTimer = nil; mic.stop()
    let opts = runOptions, recipient = target, context = runConversation, location = destination
    target = nil
    audio.end(id,cancel:false) { [weak self] heard in
      guard let self, self.session == id else {
        if let u = heard.audio { try? FileManager.default.removeItem(at:u) }; return
      }
      self.session = nil
      self.receive(heard,text:heard.final,id:id,options:opts,target:self.skipDelivery ? nil : recipient,
                   conversation:context,destination:location)
      self.didStop()
    }
  }
  // The decoder hands the finished text to the same review path for live and recorded audio.
  func receive(
    _ heard: Heard, text final: String, id: UUID, options opts: Options,
    target to: ReviewRecipient?, conversation context: UUID?, destination: String
  ) {
    guard Self.hasWords(final) else {
      if let u = heard.audio { try? FileManager.default.removeItem(at: u) }
      previewing=false; phase = .idle; status=""; stable=""; tail=""; needsCopy=false; showEdits=false; onChange?(); onMenu?()
      return
    }
    let entry = PendingReview(
      id: id, heard: heard, options: opts, target: to, conversation: context,
      destination: destination)
    self.tag = id
    self.lastID = id
    self.delivered = nil
    self.raw = heard.raw
    self.last = final
    self.stable = final
    self.tail = ""
    self.seconds = heard.seconds
    self.readingChoices = heard.choices; self.readingEdit = nil
    self.learningBase=final; self.draft = final
    self.insertedEarlier = false
    self.phase = .result
    if opts.reviewFirst {
      self.heldReview = entry
      self.awaitingReview = true
      self.editing = false
      self.status = "待审阅"
      self.icon = "pencil.line"
      self.needsCopy = false
      self.flashReview(id)
      self.onChange?()
      self.onMenu?()
    } else {
      self.store(entry, text: final)
      let out =
        opts.autoInsert && self.options.autoInsert ? (to?.insert(final) ?? .available) : .available
      self.presentResult(out, id: id)
    }
  }
  @discardableResult private func store(_ entry: PendingReview, text: String) -> Bool {
    var keep = entry.options
    keep.keepText = keep.keepText && options.keepText
    keep.keepAudio = keep.keepAudio && options.keepAudio
    let group = keep.keepText && options.linkContext ? entry.conversation : nil
    do {
      try lib.record(
        text, audio: entry.heard.audio, seconds: entry.heard.seconds, options: keep, id: entry.id,
        conversation: group, incompleteAudio: entry.heard.audioError, choices: readingChoices)
      rows = lib.records
      if keep.keepText && entry.options.collectFrequent {
        collect(text,id:entry.id,heard:entry.heard.raw,editedFrom:awaitingReview ? learningBase : nil)
      }
      if let group {
        conversation.accept(group, destination: entry.destination)
      } else {
        conversation.reset()
      }
      if entry.heard.audioError { message = entry.heard.audio == nil ? "本次录音未能保存。" : "部分录音未能保存，已保留完成的分节。" }
      return true
    } catch { message = "这条记录未能保存，请复制定稿。"; return false }
  }
  private func presentResult(_ out: InsertOutcome, id: UUID) {
    tag = id
    phase = .result
    if out.readBack != nil {
      let revision=lastID,text=last
      status="正在核对原处";icon="cursorarrow";needsCopy=false;onChange?()
      out.resolved { [weak self] receipt in
        guard let self,self.tag==id,self.lastID==revision,self.last==text else {return}
        if self.editing || self.phase != .result { self.delivered=receipt.passage.map{(revision ?? id,$0)};self.insertedEarlier = !receipt.keep;return }; self.presentResult(receipt,id:id)
      };return
    }
    status = out.title
    icon = out.symbol
    needsCopy = out.keep
    insertedEarlier = !out.keep
    delivered = out.passage.flatMap { passage in lastID.map { ($0, passage) } }
    flashReview(id)
    onChange?(); onMenu?()
    hide(in: resultDwell)
  }
  var resultDwell:Double { needsCopy && !copied ? max(10,options.appearance.hideDelay) : options.appearance.hideDelay }
  private func flashReview(_ id:UUID) {
    showEdits = options.appearance.review && options.appearance.animate && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && raw != last
    if showEdits {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
        guard let self, self.tag == id, self.phase == .result else { return }
        self.showEdits = false
        self.onChange?()
      }
    }
  }
  var canSendReviewed: Bool {
    awaitingReview && options.autoInsert && heldReview?.options.autoInsert == true
      && heldReview?.target?.editable == true && allowInsert
  }
  func editLast(open: Bool = true, inPanel:Bool = false) {
    guard !recordingBusy, !confirming, !last.isEmpty else { return }
    if historyDraft != nil { if open {openPage?(.history)};return }
    if inPanel, phase != .result {return}
    if let r=rehearing,r.origin == .dictate, !(inPanel && r.inCapsule && r.stage != .working) {rehearing=nil}
    panelEditing=inPanel; pending?.cancel()
    if !editing && !awaitingReview { learningBase=last; draft = last; readingEdit = nil }
    showEdits = false
    editing = true
    if open { openPage?(.dictate) }; onChange?()
  }
  func cancelEdit() {
    guard !confirming else { return }
    readingEdit = nil
    draft = awaitingReview ? learningBase : last
    if awaitingReview {stable=draft}
    panelEditing=false; editing = false
    onChange?(); if !awaitingReview, phase == .result { hide(in:resultDwell) }
  }
  func discardReview() {
    guard awaitingReview, !confirming else { return }
    if rehearing?.origin == .dictate { rehearing=nil }
    if let u = heldReview?.heard.audio { try? FileManager.default.removeItem(at: u) }
    heldReview = nil
    awaitingReview = false
    panelEditing=false; editing = false
    readingEdit = nil; readingChoices = []
    lastID = nil
    draft = ""
    raw = ""
    last = ""
    stable = ""
    tail = ""
    dismiss()
  }
  func confirmReview() {
    guard !confirming,!recordingBusy,editing || awaitingReview,!draft.trimmed.isEmpty,let id=lastID else {return}
    let before=last, text=draft.trimmed, wasPanel=panelEditing
    if rehearing?.origin == .dictate {rehearing=nil}
    if let entry=heldReview {
      let to=canSendReviewed ? entry.target : nil
      guard store(entry,text:text) else {return}
      rememberChange(learningBase,text,record:id); heldReview=nil; awaitingReview=false; editing=false;panelEditing=false
      readingChoices=readingChoices.filter{$0.applying(to:text) != nil};readingEdit=nil;draft=text;last=text;stable=text;tail="";showEdits=false
      onChange?()
      if let to { confirming=true; to.insertReviewed(text) { [weak self] out in self?.confirming=false;self?.presentResult(out,id:UUID()) } }
      else {presentResult(.available,id:UUID())}
    } else {
      // Release the panel's keyboard focus before attempting the original editor. Only a verified
      // insertion receipt may replace text; changing an older history entry never writes outside the app.
      if wasPanel {panelEditing=false;onChange?()}
      if before != text, !setReading(text,id:id,inDraft:false,pool:readingChoices,from:.dictate,manual:true) {panelEditing=wasPanel;onChange?();return}
      rememberChange(learningBase,text,record:id); editing=false;panelEditing=false;readingEdit=nil;draft=text
      if before == text {status="定稿未改动"}; onChange?();if phase == .result && !confirming {hide(in:resultDwell)}
    }
  }
  @discardableResult func startHistory(_ row:Record) -> Bool {
    guard !recordingBusy,!confirming,!editing,!awaitingReview,let text=row.text,!restartingForUpdate else {return false}
    if let h=historyDraft {return h.id==row.id}
    if rehearing?.recordID == row.id {rehearing=nil}; historyDraft=HistoryDraft(id:row.id,original:text,text:text);return true
  }
  @discardableResult func saveHistoryEdit() -> Bool {
    guard let h=historyDraft,!recordingBusy,!confirming else {return false}
    let text=h.text.trimmed
    guard !text.isEmpty, let row=rows.first(where:{$0.id==h.id}),row.text == h.original else {message="原记录已变化或正文为空，请核对后保存。";return false}
    if text != h.original {
      guard setReading(text,id:h.id,inDraft:false,pool:row.choices ?? [],from:.history,manual:true) else {return false}
      rememberChange(h.original,text,record:h.id)
    }
    historyDraft=nil;return true
  }
  private func rememberChange(_ before:String,_ after:String,record:UUID) {
    guard options.learning,before != after else {return}
    let pairs=PersonalCorrection.candidates(from:before,to:after).filter { pair in
      PersonalCorrection.learnable(pair) && !terms.contains { $0.spoken.caseInsensitiveCompare(pair.spoken) == .orderedSame || $0.spelling.caseInsensitiveCompare(pair.spoken) == .orderedSame }
    }
    let next=PersonalCorrection.merging(pairs,into:memories,record:record,before:before,after:after)
    if next != memories {saveMemories(next)}
  }
  private func clearReplayNotice(_ id:UUID, capsuleMessage:String? = nil) {
    guard let r=rehearing,r.recordID==id,r.stage != .working else {return}
    if r.inCapsule, let note=capsuleMessage {
      if confirming {r.done("正在核对原处");return}
      r.done(insertedEarlier && !r.forDraft ? (needsCopy ? note + "，请核对原处文字" : note + "，已同步原处") : note)
    } else { rehearing=nil }
  }
  func chooseReading(_ choice: ReadingChoice) {
    guard !recordingBusy, !confirming, let id = lastID, readingChoices.contains(choice),
      let edited = choice.applying(to: reviewText) else { return }
    let e = ReadingEdit(id: id, from: reviewText, to: edited, inDraft: editing || awaitingReview, choices: readingChoices)
    if setReading(edited, id: id, inDraft: e.inDraft, pool: e.choices, from: .dictate) { readingEdit = e; clearReplayNotice(id,capsuleMessage:"已替换写法") }
  }
  func undoReading() {
    guard canUndoReading, let e = readingEdit, setReading(e.from, id: e.id, inDraft: e.inDraft, pool: e.choices, from: .dictate) else { return }
    readingChoices = e.choices; _=readingTrail.popLast(); clearReplayNotice(e.id,capsuleMessage:"已撤销上次替换")
  }
  func canPickHistory(_ id: UUID) -> Bool {
    !recordingBusy && !confirming && historyDraft == nil && !(id == lastID && (editing || awaitingReview))
  }
  func canUndoHistory(_ row: Record) -> Bool {
    guard let e = readingEdit else { return false }
    return canPickHistory(row.id) && e.id == row.id && !e.inDraft && row.text == e.to
  }
  func chooseHistory(_ c: ReadingChoice, id: UUID) {
    guard canPickHistory(id), let row = rows.first(where: { $0.id == id }), let pool = row.choices,
      pool.contains(c), let text = row.text, let revised = c.applying(to: text) else { return }
    if setReading(revised, id: id, inDraft: false, pool: pool, from: .history) {
      readingEdit = ReadingEdit(id: id, from: text, to: revised, inDraft: false, choices: pool); clearReplayNotice(id)
    }
  }
  func undoHistory(_ id: UUID) {
    guard let e = readingEdit, let row = rows.first(where: { $0.id == id }), canUndoHistory(row),
      setReading(e.from, id: id, inDraft: false, pool: e.choices, from: .history) else { return }
    _=readingTrail.popLast(); clearReplayNotice(id)
  }
  // Only a current dictation can revise its verified original passage; history and drafts stay local.
  private func setReading(_ text: String, id: UUID, inDraft: Bool, pool: [ReadingChoice], from origin: Page, manual:Bool = false) -> Bool {
    if inDraft {
      draft = text
      if awaitingReview { stable = text }
      readingChoices = pool.filter { $0.applying(to:text) != nil }
    } else {
      if let prior = rows.first(where: { $0.id == id })?.text {
        do { try lib.revise(id, text: text, choices: pool); rows = lib.records }
        catch { message = "历史文字未能保存，定稿未变。"; return false }
        if options.collectFrequent { collect(text,id:id,editedFrom:manual ? prior : nil) }
      }
      guard id == lastID else { return true }
      let receipt=delivered,original=last
      delivered=nil;last=text;draft=text;stable=text;tail="";needsCopy=true
      status=insertedEarlier ? "已更新定稿，原处文字未变" : "已更新定稿"
      if origin == .dictate, manual || page == .dictate || capsuleReplay?.recordID == id,options.autoInsert,allowInsert,
        let sent=receipt,sent.id==id,sent.passage.covers(original) {
        confirming=true;status="正在核对原处"
        sent.passage.replace(with:text) { [weak self] result,next in
          guard let self else {return};self.confirming=false
          guard self.lastID==id,self.last==text else {return}
          switch result {
          case .replaced:self.delivered=next.map{(id,$0)};self.needsCopy=false;self.status="已替换原处文字"
          case .changed:self.status="已更新定稿，原输入位置已变化"
          case .unconfirmed:self.status="已更新定稿，请核对原处文字"
          }
          if let r=self.rehearing,r.recordID==id,r.stage != .working,r.origin == .dictate {r.done(self.status)}
          self.onChange?();self.onMenu?();if self.phase == .result && !self.editing {self.hide(in:self.resultDwell)}
        }
      }
      readingChoices = pool.filter { $0.applying(to: text) != nil }
    }
    showEdits = false; onChange?(); onMenu?(); return true
  }
  func saveMemories(_ next: [Term]) {
    do {
      try lib.saveMemories(next)
      memories = next
    } catch { message = "修改记忆未能保存。" }
  }
  func notice(_ text: String) {
    pending?.cancel()
    tag = UUID()
    status = text
    phase = .notice
    stable = ""
    tail = ""
    needsCopy = false
    showEdits = false
    icon = "exclamationmark.circle"
    onChange?()
    onMenu?()
    hide(in: 3.5)
  }
  private func hide(in time: Double) {
    let t = tag
    pending?.cancel()
    let item = DispatchWorkItem { [weak self] in if self?.tag == t && self?.editing == false && self?.awaitingReview == false && self?.confirming == false && self?.capsuleReplay == nil { self?.dismiss() } }
    pending = item
    DispatchQueue.main.asyncAfter(deadline: .now() + time, execute: item)
  }
  func hoverResult(_ inside: Bool) {
    guard phase == .result, capsuleReplay == nil, !editing, !awaitingReview, !confirming else { return }
    pending?.cancel()
    if !inside { hide(in: resultDwell) }
  }
  func dismiss() {
    guard phase != .listen && phase != .finish, !editing, !awaitingReview, !confirming else { return }
    pending?.cancel()
    phase = .idle
    if rehearing?.inCapsule == true { rehearing=nil }
    onChange?()
    onMenu?()
  }
  var copyText: String { recordingBusy ? stable + tail : reviewText }
  var copyLabel: String { recordingBusy ? "复制当前转写" : editing ? "复制修改稿" : "复制定稿" }
  @discardableResult func copyCurrent(to board: NSPasteboard = .general) -> Bool {
    let text = copyText
    guard !confirming, !text.trimmed.isEmpty, InputTarget.copy(text, to: board) else {
      return false
    }
    clearCopyFeedback()
    copiedText = text
    // Copying is orthogonal to recording and review: never commit a draft, insert it or dismiss the review.
    let reset = DispatchWorkItem { [weak self] in self?.copiedText = nil }
    copyReset = reset
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: reset)
    return true
  }
  private func clearCopyFeedback() {
    copyReset?.cancel()
    copyReset = nil
    copiedText = nil
  }
  @discardableResult func changePolicy(_ edit: (inout WordPolicy) -> Void) -> Bool {
    var next = policy
    edit(&next)
    guard next != policy else { return true }
    do {
      try lib.savePolicy(next)
      policy = next
      blockedWordKeys = Set(next.blocked.map { $0.lowercased() })
      onChange?()
      return true
    } catch {
      message = "词库设置未能保存。"
      return false
    }
  }
  private func admitsFrequent(_ name: String) -> Bool {
    let k = name.lowercased()
    guard !policy.hidden.contains(k), !blockedWordKeys.contains(k), !manualWordKeys.contains(k) else { return false }
    return WordCatalog.shared.byName[k].map { policy.uses($0) } ?? true
  }
  private func collect(_ text: String, id: UUID, heard: String? = nil, editedFrom: String? = nil) {
    guard options.collectFrequent, options.keepText else { return }
    let epoch = wordEpoch
    wordWorker.async { [weak self] in
      let names = WordCapture.candidates(in: text, vocabulary: .shared)
      // A spelling introduced by our own proofreader is not evidence of the user's habits.
      // On revision retain supported words still present and add only what the user changed.
      func keys(_ value:String)->Set<String> {
        Set((value == text ? names : WordCapture.candidates(in:value,vocabulary:.shared)).map { $0.lowercased() })
      }
      var supported = heard.map(keys) ?? []
      if let before=editedFrom, before != text { supported.formUnion(keys(text).subtracting(keys(before))) }
      let evidence = supported
      DispatchQueue.main.async {
        guard let self, self.wordEpoch == epoch, self.options.collectFrequent, self.options.keepText else { return }
        let filtered = names.filter { self.admitsFrequent($0) }
        _ = self.changeFrequencies { $0.observe(filtered, id: id, supported:evidence) }
      }
    }
  }
  @discardableResult private func changeFrequencies(_ edit: (inout FrequentWords) -> Void) -> Bool {
    var next = frequencies; edit(&next)
    guard next != frequencies else { return true }
    do { try lib.saveFrequencies(next); frequencies = next; return true }
    catch { message = "常用词未能保存。"; return false }
  }
  @discardableResult func forgetFrequent(_ name: String) -> Bool { changeFrequencies { $0.forget(name) } }
  func clearFrequent() { wordEpoch = UUID(); _ = changeFrequencies { $0.clear() } }
  func persistTerms(_ next: [Term]) {
    do {
      let retained = Set(next.map { $0.spelling.lowercased() })
      let removed = terms.map(\.spelling).filter { !retained.contains($0.lowercased()) }
      try lib.saveTerms(next)
      terms = lib.terms
      manualWordKeys = Set(next.flatMap { [$0.spelling.lowercased(), $0.spoken.lowercased()] })
      if !removed.isEmpty { _ = changeFrequencies { shelf in for name in removed { shelf.forget(name) } } }
    } catch { message = "词库未能保存。" }
  }
  func erase(_ id: UUID?, part: HistoryPart = .both) {
    if part != .audio, ((historyDraft != nil && (id == nil || id == historyDraft?.id)) || (editing && (id == nil || id == lastID))) { message="请先保存或取消正在修改的文字。"; return }
    stopAudio()
    do {
      let removedLast = id != nil && lastID == id
      try lib.delete(id, part: part)
      rows = lib.records
      if let r = rehearing, id == nil || r.recordID == id { rehearing = nil }
      if id == nil || delivered?.id == id { delivered = nil }
      if part != .audio && !awaitingReview && (id == nil || removedLast) {
        editing = false
        draft = ""
        lastID = nil
        stable = ""
        tail = ""
        last = ""
        raw = ""
        if phase == .result { dismiss() }
      }
    } catch { message = "未能删除记录。" }
  }
  func play(_ r: Record) {
    guard let url = lib.audioURL(r.audio) else { return }; play(id: r.id, url: url)
  }
  private func play(id: UUID, url: URL) {
    if playing == id {
      stopAudio()
      return
    }
    stopAudio()
    let tracks = url.pathExtension == "clips" ? SectionRecorder.tracks(url) : [url]
    guard !tracks.isEmpty else { message="这段录音不可用。"; return }
    playing = id
    func next(_ n:Int) {
      guard self.playing == id, n < tracks.count else { self.stopAudio(); return }
      do { let p=try AVAudioPlayer(contentsOf:tracks[n]); self.sound=p; p.delegate=self.playback
        self.playback.ended = { [weak self,weak p] success in guard let self, let p, self.sound === p else { return }; if success { next(n+1) } else { self.stopAudio(); self.message="录音播放中断。" } }
        guard p.play() else { throw VoiceFault.message("无法播放录音。") }
      } catch { self.stopAudio(); self.message="无法播放这段录音。" }
    }
    next(0)
  }
  private let playback = PlaybackDelegate()
  func stopAudio() {
    playback.ended=nil
    playTimer?.invalidate()
    playTimer = nil
    sound?.stop()
    sound = nil
    playing = nil
  }
  func shutdown() {
    rehearing = nil; delivered = nil
    noSpeechTimer?.cancel(); tailTimer?.cancel()
    pending?.cancel()
    copyReset?.cancel()
    mic.stop()
    session = nil
    key.stop()
    models.cancel()
    if let u = heldReview?.heard.audio { try? FileManager.default.removeItem(at: u) }
    heldReview = nil
    audio.shutdown()
    PasteLease.shared.finish()
    stopAudio()
  }
}

extension Desk {
  var latestReplayID: UUID? { lastID ?? rows.first?.id }
  var capsuleReplay: Rehearing? {
    guard phase == .result, let r=rehearing,r.inCapsule,r.recordID==lastID else {return nil};return r
  }
  func closeCapsuleReplay() {
    guard let r=capsuleReplay else { return }
    if !awaitingReview && r.stage != .working { dismiss(); return }
    rehearing=nil
    if !awaitingReview && !editing { hide(in:options.appearance.hideDelay) }
  }
  func rehear(_ selected: UUID? = nil, inCapsule requested: Bool = false) {
    guard !recordingBusy, !confirming, !panelEditing, (!editing || draft==learningBase), historyDraft == nil, let id=selected ?? latestReplayID else { return }
    let origin: Page = selected != nil || lastID == nil ? .history : .dictate
    let inCapsule=requested && origin == .dictate
    if origin == .history && !canPickHistory(id) { return }
    if let previous=rehearing, previous.recordID==id, previous.origin==origin, previous.stage == .working {
      if previous.inCapsule { onChange?() } else { openPage?(origin) }; return
    }
    let row=rows.first{$0.id==id}, entry=heldReview.flatMap{$0.id==id ? $0 : nil}
    let isDraft=origin == .dictate && (editing || awaitingReview)
    let base=origin == .history ? row?.text ?? "" : reviewText
    let job=Rehearing(id:id,original:base,origin:origin,draft:isDraft,inCapsule:inCapsule)
    let model=ReplayRequest.model(for: activeModel ?? options.model, installed:models.installed)
    stopAudio(); pending?.cancel(); showEdits=false
    if inCapsule {
      if phase != .result {screen=NSScreen.screens.first{$0.frame.contains(NSEvent.mouseLocation)}?.visibleFrame ?? screen}
      previewing=false; phase = .result
    }
    else if phase == .result && !awaitingReview { dismiss() }
    rehearing=job; if !inCapsule { openPage?(origin) }
    guard let url=entry?.heard.audio ?? lib.audioURL(row?.audio) else { job.fail("未保留这段录音，无法复听。"); return }
    guard entry?.heard.audioError != true, row?.incompleteAudio != true else { job.fail("录音不完整，原稿未改。"); return }
    let group=entry?.conversation ?? row?.conversation
    let older=row.flatMap{r in rows.firstIndex{$0.id==r.id}}.map{Array(rows.dropFirst($0+1).prefix(8))} ?? Array(rows.prefix(8))
    let context=options.keepText && options.linkContext ? ConversationWindow.recent(group,rows:older) : []
    let active=terms.filter(policy.uses)
    let familiar=options.collectFrequent ? frequencies.hints(previous:context){self.admitsFrequent($0)} : []
    let hints=ConversationWindow.hints(previous:context,terms:active)+familiar
    let request=ReplayRequest(url:url,expectedSections:row?.sectionCount,model:model,directory:models.url(model),
      level:entry?.options.level ?? row?.mode ?? runOptions.level,terms:active,learned:options.learning ? memories : [],previous:context,hints:hints,
      policy:policy,proof:options.proofWords,alternateDirectory:model == .bundled ? nil : models.url(.bundled))
    job.start(request){ [weak self,weak job] result in guard let job else {return}; self?.finishReplay(job,result) }
  }
  func finishReplay(_ r:Rehearing,_ result:ReplayEvidence.Result) {
    guard rehearing === r,r.stage == .working, (r.inCapsule ? capsuleReplay === r : page==r.origin), !recordingBusy, !confirming else { return }
    let id=r.recordID, row=rows.first{$0.id==id}, current=lastID==id
    let base:String?, before:[ReadingChoice]
    if r.origin == .history {
      guard let row, canPickHistory(id) else { r.fail("这条记录已改变，未替换。"); return }
      base=row.text ?? ""; before=row.choices ?? []
    } else { base=current && r.forDraft==(editing || awaitingReview) ? reviewText : nil; before=readingChoices }
    guard base==r.original else { r.fail("复听期间原稿已修改，已保留你的修改。"); return }
    let changed=result.text != r.original
    var pool=[ReadingChoice](); for c in result.choices where !pool.contains(c) && c.applying(to:result.text) != nil {pool.append(c)}
    if r.origin == .history && row?.text == nil { r.preview=result.text; r.previewChoices=pool; r.done("本次识别结果未保存"); return }
    if changed {
      guard setReading(result.text,id:id,inDraft:r.forDraft,pool:pool,from:r.origin) else {r.fail("修订未保存，原稿未改。"); return}
      if r.forDraft {learningBase=result.text}
      readingEdit=ReadingEdit(id:id,from:r.original,to:result.text,inDraft:r.forDraft,choices:before)
      r.done(r.forDraft ? "已校正审阅稿，尚未输入" : r.origin == .history ? "已校正这条记录" : (insertedEarlier ? status : "已校正本次定稿"))
    } else {
      if !r.forDraft, row?.text != nil, pool != (row?.choices ?? []) {
        do { try lib.revise(id,text:r.original,choices:pool); rows=lib.records } catch { r.fail("可选写法未能保存。"); return }
      }
      if current { readingChoices=pool }
      r.done(pool.isEmpty ? "已复听，未找到更可靠的写法" : "有不同听法，点选即可替换")
    }
  }

}

func clockText(_ s: Double) -> String {
  let t = max(0, Int(s))
  return String(format: "%d:%02d", t / 60, t % 60)
}

private final class PlaybackDelegate:NSObject, AVAudioPlayerDelegate {
  var ended:((Bool)->Void)?
  func audioPlayerDidFinishPlaying(_ player:AVAudioPlayer,successfully flag:Bool) { ended?(flag) }
  func audioPlayerDecodeErrorDidOccur(_ player:AVAudioPlayer,error:Error?) { ended?(false) }
}
