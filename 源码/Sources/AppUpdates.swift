import SwiftUI
import Sparkle

// Startup checks never activate another window or download an update. Sparkle owns verification, installation and relaunch.
@MainActor final class AppUpdates: NSObject, ObservableObject, SPUUserDriver, SPUUpdaterDelegate {
  enum Stage: Equatable { case idle, checking, current, found, fetching, preparing, ready, restarting, message(String) }
  @Published private(set) var stage: Stage = .idle
  @Published private(set) var fraction: Double?
  struct Release: Equatable {
    let version: String, build: String, bytes: UInt64, notes: String
    var label: String { "\(version) · 修订 \(build)" }
  }
  @Published private(set) var offer: Release?
  @Published var announceOffer = false
  @Published private(set) var downloaded: UInt64 = 0
  private(set) var quiet = false
  private weak var desk: Desk?
  private var engine: SPUUpdater?, authentic = false, expected: UInt64 = 0, received: UInt64 = 0
  private var cancelAction: (() -> Void)?, decision: ((SPUUserUpdateChoice) -> Void)?, resumeInstall: ((SPUUserUpdateChoice) -> Void)?, retryQuit: (() -> Void)?
  private let defaults: UserDefaults
  init(_ desk: Desk, defaults: UserDefaults = .standard) { self.desk=desk; self.defaults=defaults }
  var canRestart: Bool { desk?.allowsUpdateRestart == true }
  static var installed: Release {
    let b=Bundle.main
    return Release(version:b.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "1.0.0",build:b.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "",bytes:0,notes:b.object(forInfoDictionaryKey:"PhraseFlowReleaseNotes") as? String ?? "")
  }
  func needsHighlights(firstUse:Bool) -> Bool {
    let build=Self.installed.build
    guard !build.isEmpty else { return false }
    if firstUse { defaults.set(build,forKey:"release.lastOpened"); return false }
    return defaults.string(forKey:"release.lastOpened") != build
  }
  func sawHighlights() { defaults.set(Self.installed.build,forKey:"release.lastOpened") }
  var hasBadge: Bool { offer != nil }
  var busy:Bool { [.fetching,.preparing,.ready,.restarting].contains(stage) }
  func check(quiet:Bool = false) {
    guard stage == .idle || stage == .current || { if case .message = stage { return true }; return false }() else { return }
    self.quiet=quiet
    if engine == nil {
      let e=SPUUpdater(hostBundle:.main,applicationBundle:.main,userDriver:self,delegate:self)
      do { try e.start() } catch { stage = quiet ? .idle : .message(error.localizedDescription); return }; engine=e
    }
    guard let engine, engine.canCheckForUpdates else { return }
    authentic=false; stage = .checking; engine.checkForUpdates()
  }
  func install() {
    guard stage == .found, canRestart, let f=decision else { return }
    quiet=false; decision=nil; expected=offer?.bytes ?? 0; received=0; downloaded=0; fraction=expected > 0 ? 0:nil
    stage = .fetching; f(.install)
  }
  func ignore() {
    guard stage == .found,let offer,let f=decision else {return}
    defaults.set(offer.build,forKey:"release.ignored"); clear(); stage = .idle; f(.skip)
  }
  func restart() {
    guard stage == .ready, canRestart else { return }
    guard resumeInstall != nil || retryQuit != nil else {return}
    desk?.restartingForUpdate=true; stage = .restarting
    if let f=resumeInstall { resumeInstall=nil; f(.install) }
    else if let f=retryQuit { retryQuit=nil; f() }
  }
  func cancel() {
    if let f=decision { clear(); stage = .idle; f(.dismiss) }
    else if let f=cancelAction { clear(); stage = .idle; f() }
  }
  private func clear() { offer=nil;announceOffer=false;decision=nil;cancelAction=nil;resumeInstall=nil;retryQuit=nil;fraction=nil;desk?.restartingForUpdate=false }
  nonisolated static func trustedAsset(_ u:URL?) -> Bool {
    guard let u, u.scheme == "https",u.host == "github.com",u.user == nil,u.password == nil,u.port == nil,u.query == nil,u.fragment == nil else {return false}
    let parts=u.pathComponents
    return parts.count == 7 && parts[1...4].map{$0.lowercased()} == ["burntroses","shengru","releases","download"] && !parts[5].isEmpty && parts[5] != ".." && ["PhraseFlow.dmg","Shengru.dmg","Shengru.zip"].contains(parts[6])
  }
  func updater(_ updater:SPUUpdater,didFinishLoading appcast:SUAppcast) { authentic=appcast.signingValidationStatus == .succeeded }
  func updaterShouldPromptForPermissionToCheck(forUpdates updater:SPUUpdater) -> Bool { false }
  func updater(_ updater:SPUUpdater, shouldDownloadReleaseNotesForUpdate item:SUAppcastItem) -> Bool { false }
  func show(_ request:SPUUpdatePermissionRequest,reply:@escaping(SUUpdatePermissionResponse)->Void) { reply(SUUpdatePermissionResponse(automaticUpdateChecks:false,sendSystemProfile:false)) }
  func showUserInitiatedUpdateCheck(cancellation:@escaping()->Void) { cancelAction=cancellation; stage = .checking }
  func showUpdateFound(with item:SUAppcastItem,state:SPUUserUpdateState,reply:@escaping(SPUUserUpdateChoice)->Void) {
    cancelAction=nil
    guard authentic, item.signingValidationStatus == .succeeded, Self.trustedAsset(item.fileURL), item.installationType == "application" else { stage = .message("更新来源未通过验证，未安装。"); reply(.dismiss); return }
    if quiet && defaults.string(forKey:"release.ignored") == item.versionString { clear();stage = .idle;reply(.dismiss);return }
    offer=Release(version:item.displayVersionString,build:item.versionString,bytes:item.contentLength,notes:item.itemDescription?.trimmingCharacters(in:.whitespacesAndNewlines) ?? "")
    decision=reply; stage = .found; announceOffer=quiet
  }
  func showUpdateReleaseNotes(with data:SPUDownloadData) {}
  func showUpdateReleaseNotesFailedToDownloadWithError(_ error:Error) {}
  func showUpdateNotFoundWithError(_ error:Error,acknowledgement:@escaping()->Void) {
    clear(); if quiet {stage = .idle;acknowledgement();return}; let why=(error as NSError).userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber
    switch (authentic,why?.intValue) {
    case (false,_): stage = .message("未能验证更新列表，请稍后再试。")
    case (true,1),(true,2): stage = .current
    case (true,3),(true,4),(true,5): stage = .message("新版不适用于这台 Mac，当前版本可继续使用。")
    default: stage = .message("目前没有适用于这台 Mac 的更新。")
    }; acknowledgement()
  }
  func showUpdaterError(_ error:Error,acknowledgement:@escaping()->Void) { clear(); stage = quiet ? .idle : .message(error.localizedDescription); acknowledgement() }
  func showDownloadInitiated(cancellation:@escaping()->Void) {
    cancelAction=cancellation;stage = .fetching;received=0;downloaded=0;expected=offer?.bytes ?? 0;fraction=expected == 0 ? nil:0
  }
  func showDownloadDidReceiveExpectedContentLength(_ n:UInt64) { if n > 0 {expected=n} }
  func showDownloadDidReceiveData(ofLength n:UInt64) {
    received += n
    if received-downloaded >= 128*1024 || received >= expected || downloaded == 0 {
      downloaded=received
      if expected>0 {fraction=max(fraction ?? 0,min(1,Double(received)/Double(expected)))}
    }
  }
  func showDownloadDidStartExtractingUpdate() { cancelAction=nil;downloaded=received;fraction=0;stage = .preparing }
  func showExtractionReceivedProgress(_ v:Double) { if v.isFinite {fraction=max(fraction ?? 0,min(1,max(0,v)))} }
  func showReady(toInstallAndRelaunch reply:@escaping(SPUUserUpdateChoice)->Void) { resumeInstall=reply;stage = .ready; if canRestart { restart() } }
  func showInstallingUpdate(withApplicationTerminated terminated:Bool,retryTerminatingApplication retry:@escaping()->Void) {
    if !terminated { desk?.restartingForUpdate=false; retryQuit=retry;stage = .ready }
  }
  func showUpdateInstalledAndRelaunched(_ relaunched:Bool,acknowledgement:@escaping()->Void) { clear();stage = .current; acknowledgement() }
  func dismissUpdateInstallation() { /* Terminal feedback stays visible after Sparkle releases its session. */ }
}

struct UpdateDot: View {
  @ObservedObject var updates: AppUpdates
  var body:some View {
    if updates.hasBadge { Circle().fill(.orange).frame(width:7,height:7).allowsHitTesting(false).accessibilityLabel("有新版可用") }
  }
}

// The same live driver backs Settings and the non-interrupting update sheet.
struct UpdatePane: View {
  @ObservedObject var d:Desk
  @ObservedObject var updates:AppUpdates
  @ObservedObject private var models:ModelShelf
  init(d:Desk,updates:AppUpdates) { self.d=d;self.updates=updates;self.models=d.models }
  private func size(_ n:UInt64)->String { ByteCountFormatter.string(fromByteCount:Int64(clamping:n),countStyle:.file) }
  var body:some View {
    Surface(inset:Layout.inset,spacing:12) {
      HStack(spacing:12) {
        BrandBadge(size:48).overlay(alignment:.topTrailing){UpdateDot(updates:updates)}
        VStack(alignment:.leading,spacing:4) { PanelTitle(title:"如流 · PhraseFlow"); Text("已安装 \(AppUpdates.installed.label)").font(.callout).foregroundStyle(.secondary) }
        Spacer()
      }
      if let offer=updates.offer {
        Divider()
        HStack { Text("新版 \(offer.label)").font(.headline); Spacer(); if offer.bytes>0 {Text(size(offer.bytes)).monospacedDigit().foregroundStyle(.secondary)} }
        if !offer.notes.isEmpty {Text(offer.notes).font(.callout).fixedSize(horizontal:false,vertical:true)}
      }
      if updates.stage == .fetching || updates.stage == .preparing {
        HStack { Text(updates.stage == .fetching ? "正在下载 · \(size(updates.downloaded))" : "正在准备安装"); Spacer(); if let f=updates.fraction {Text(f.formatted(.percent.precision(.fractionLength(0))))} }.font(.callout.monospacedDigit())
        ProgressView(value:updates.fraction).progressViewStyle(.linear)
      }
      if let message { Text(message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true) }
      HStack {
        if updates.stage == .found { Button("忽略此版本"){updates.ignore()}.deskAction() }
        Spacer()
        switch updates.stage {
        case .idle,.current,.message: Button("检查更新"){updates.check()}.deskAction(primary:true)
        case .checking,.fetching: Button("取消"){updates.cancel()}.deskAction()
        case .found: Button("下载并更新"){updates.install()}.deskAction(primary:true).disabled(!updates.canRestart)
        case .ready: Button("重启并更新"){updates.restart()}.deskAction(primary:true).disabled(!updates.canRestart)
        case .preparing,.restarting: EmptyView()
        }
      }
    }
  }
  private var message:String? {
    switch updates.stage {
    case .checking:return "正在检查更新…"; case .current:return "已是最新版本。"
    case .found:return updates.canRestart ? nil:"完成当前听写、修改或模型安装后即可更新。"
    case .ready:return updates.canRestart ? "已准备好重启。":"更新已准备好，请先完成当前操作。"
    case .restarting:return "正在重启…";case .message(let s):return s;default:return nil
    }
  }
}
