import SwiftUI
import Sparkle

// No scheduler or network session is started until the user presses Check. Sparkle handles
// signature verification, atomic installation and relaunch; the settings pane owns the interaction.
@MainActor final class AppUpdates: NSObject, ObservableObject, SPUUserDriver, SPUUpdaterDelegate {
  enum Stage: Equatable { case idle, checking, current, found(String), fetching, preparing, ready, restarting, message(String) }
  @Published private(set) var stage: Stage = .idle
  @Published private(set) var fraction: Double?
  weak var desk: Desk?
  private var engine: SPUUpdater?, authentic = false, expected: UInt64 = 0, received: UInt64 = 0
  private var cancelAction: (() -> Void)?, decision: ((SPUUserUpdateChoice) -> Void)?, resumeInstall: ((SPUUserUpdateChoice) -> Void)?, retryQuit: (() -> Void)?
  init(_ desk: Desk) { self.desk=desk }
  var canRestart: Bool { desk?.allowsUpdateRestart == true }
  func check() {
    guard stage == .idle || stage == .current || { if case .message = stage { return true }; return false }() else { return }
    if engine == nil {
      let e=SPUUpdater(hostBundle:.main,applicationBundle:.main,userDriver:self,delegate:self)
      do { try e.start() } catch { stage = .message(error.localizedDescription); return }; engine=e
    }
    guard let engine, engine.canCheckForUpdates else { return }
    authentic=false; stage = .checking; engine.checkForUpdates()
  }
  func install() {
    guard case .found = stage, canRestart, let f=decision else { return }
    decision=nil; fraction=nil; stage = .fetching; f(.install)
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
  private func clear() { decision=nil;cancelAction=nil;resumeInstall=nil;retryQuit=nil;fraction=nil;desk?.restartingForUpdate=false }
  nonisolated static func trustedAsset(_ u:URL?) -> Bool {
    guard let u, u.scheme == "https",u.host == "github.com",u.user == nil,u.password == nil,u.port == nil,u.query == nil,u.fragment == nil else {return false}
    let parts=u.pathComponents
    return parts.count == 7 && parts[1...4].map{$0.lowercased()} == ["burntroses","shengru","releases","download"] && !parts[5].isEmpty && parts[5] != ".." && ["Shengru.dmg","Shengru.zip"].contains(parts[6])
  }
  func updater(_ updater:SPUUpdater,didFinishLoading appcast:SUAppcast) { authentic=appcast.signingValidationStatus == .succeeded }
  func updaterShouldPromptForPermissionToCheck(forUpdates updater:SPUUpdater) -> Bool { false }
  func updater(_ updater:SPUUpdater, shouldDownloadReleaseNotesForUpdate item:SUAppcastItem) -> Bool { false }
  func show(_ request:SPUUpdatePermissionRequest,reply:@escaping(SUUpdatePermissionResponse)->Void) { reply(SUUpdatePermissionResponse(automaticUpdateChecks:false,sendSystemProfile:false)) }
  func showUserInitiatedUpdateCheck(cancellation:@escaping()->Void) { cancelAction=cancellation; stage = .checking }
  func showUpdateFound(with item:SUAppcastItem,state:SPUUserUpdateState,reply:@escaping(SPUUserUpdateChoice)->Void) {
    cancelAction=nil
    guard item.signingValidationStatus == .succeeded, Self.trustedAsset(item.fileURL), item.installationType == "application" else { stage = .message("更新来源未通过验证，未安装。"); reply(.dismiss); return }
    decision=reply; stage = .found(item.displayVersionString)
  }
  func showUpdateReleaseNotes(with data:SPUDownloadData) {}
  func showUpdateReleaseNotesFailedToDownloadWithError(_ error:Error) {}
  func showUpdateNotFoundWithError(_ error:Error,acknowledgement:@escaping()->Void) {
    clear(); let why=(error as NSError).userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber
    switch (authentic,why?.intValue) {
    case (false,_): stage = .message("未能验证更新列表，请稍后再试。")
    case (true,1),(true,2): stage = .current
    case (true,3),(true,4),(true,5): stage = .message("新版不适用于这台 Mac，当前版本可继续使用。")
    default: stage = .message("目前没有适用于这台 Mac 的更新。")
    }; acknowledgement()
  }
  func showUpdaterError(_ error:Error,acknowledgement:@escaping()->Void) { clear(); stage = .message(error.localizedDescription); acknowledgement() }
  func showDownloadInitiated(cancellation:@escaping()->Void) { cancelAction=cancellation; stage = .fetching; fraction=nil;expected=0;received=0 }
  func showDownloadDidReceiveExpectedContentLength(_ n:UInt64) { expected=n }
  func showDownloadDidReceiveData(ofLength n:UInt64) { received += n; if expected>0 { fraction=min(1,Double(received)/Double(expected)) } }
  func showDownloadDidStartExtractingUpdate() { cancelAction=nil; fraction=nil; stage = .preparing }
  func showExtractionReceivedProgress(_ v:Double) { fraction=min(1,max(0,v)) }
  func showReady(toInstallAndRelaunch reply:@escaping(SPUUserUpdateChoice)->Void) { resumeInstall=reply;stage = .ready; if canRestart { restart() } }
  func showInstallingUpdate(withApplicationTerminated terminated:Bool,retryTerminatingApplication retry:@escaping()->Void) {
    if !terminated { desk?.restartingForUpdate=false; retryQuit=retry;stage = .ready }
  }
  func showUpdateInstalledAndRelaunched(_ relaunched:Bool,acknowledgement:@escaping()->Void) { clear();stage = .current; acknowledgement() }
  func dismissUpdateInstallation() { /* Terminal feedback stays visible after Sparkle releases its session. */ }
}

struct UpdatePane: View {
  @ObservedObject var d:Desk
  @ObservedObject var updates:AppUpdates
  @ObservedObject private var models:ModelShelf
  init(d:Desk,updates:AppUpdates) { self.d=d;self.updates=updates;self.models=d.models }
  private var version:String { (Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String) ?? "—" }
  var body:some View {
    Surface(inset:Layout.inset,spacing:13) {
      HStack(spacing:12) {
        Image(nsImage:NSApp.applicationIconImage).resizable().frame(width:48,height:48).accessibilityHidden(true)
        VStack(alignment:.leading,spacing:4) { PanelTitle(title:"语音输入");Text("版本 \(version)").font(.callout).foregroundStyle(.secondary) }
        Spacer()
        switch updates.stage {
        case .idle,.current,.message: Button("检查更新") { updates.check() }.deskAction(primary:true)
        case .checking,.fetching: Button("取消") { updates.cancel() }.deskAction()
        case .found: Button("稍后") { updates.cancel() }.deskAction(); Button("更新并重启") { updates.install() }.deskAction(primary:true).disabled(!updates.canRestart)
        case .ready: Button("重启并更新") { updates.restart() }.deskAction(primary:true).disabled(!updates.canRestart)
        case .preparing,.restarting: EmptyView()
        }
      }
      if let message { Divider(); Text(message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true) }
      if updates.stage == .fetching || updates.stage == .preparing { ProgressView(value:updates.fraction).progressViewStyle(.linear) }
    }
  }
  private var message:String? {
    switch updates.stage {
    case .idle:return nil; case .checking:return "正在检查更新…"; case .current:return "已是最新版本。"
    case .found(let v):return updates.canRestart ? "有新版本：\(v)。" : "有新版本：\(v)。请先完成当前听写、审阅或模型安装。"
    case .fetching:return "正在下载更新…"; case .preparing:return "正在准备安装…"
    case .ready:return updates.canRestart ? "更新已准备好。" : "更新已准备好，请先完成当前操作。";case .restarting:return "正在重启…";case .message(let s):return s
    }
  }
}
