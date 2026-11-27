import AppKit
import CoreServices

// Names may change. The installed bundle ID, storage domain and update key do not.
enum Installation {
  static let id = "cn.shengru.dictation"
  static let fm = FileManager.default
  static var directories:[URL] { [URL(fileURLWithPath:"/Applications",isDirectory:true),fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications",isDirectory:true)] }
  static func installed(_ url:URL)->Bool { directories.contains(url.standardizedFileURL.deletingLastPathComponent()) }
  static func register(_ url:URL) { LSRegisterURL(url as CFURL,true) }
  @MainActor static private(set) var handingOff=false
  private static let installArgument="--phraseflow-installed"
  private static func sameLocation(_ a:URL, _ b:URL)->Bool {
    a.standardizedFileURL.resolvingSymlinksInPath().path == b.standardizedFileURL.resolvingSymlinksInPath().path
  }

  // macOS can run an approved first launch from a temporary, read-only location.
  // Identify the installation by its Launch Services URL or our explicit handoff to the same build.
  // This hint only suppresses a second install prompt; it never authorizes a write or bypasses system approval.
  static func launchedFrom(_ target:URL, executableBundle:URL, registeredURL:URL?, arguments:[String])->Bool {
    if sameLocation(target,executableBundle) || registeredURL.map({ sameLocation(target,$0) }) == true { return true }
    guard let i=arguments.firstIndex(of:installArgument), arguments.indices.contains(i+1),
          sameLocation(target,URL(fileURLWithPath:arguments[i+1],isDirectory:true)),
          let a=Bundle(url:executableBundle)?.executableURL, let b=Bundle(url:target)?.executableURL else { return false }
    return fm.contentsEqual(atPath:a.path,andPath:b.path)
  }

  @MainActor static func prepare(_ source:URL, in locations:[URL] = directories, identifier:String = id)->Bool {
    let originals=locations.flatMap { dir in
      ((try? fm.contentsOfDirectory(at:dir,includingPropertiesForKeys:nil,options:.skipsHiddenFiles)) ?? [])
        .filter { $0.pathExtension == "app" && (try? $0.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink) != true && Bundle(url:$0)?.bundleIdentifier == identifier }
        .sorted { a,b in
          if a.lastPathComponent == "如流.app" {return b.lastPathComponent != "如流.app"}
          if b.lastPathComponent == "如流.app" {return false}
          return a.lastPathComponent < b.lastPathComponent
        }
    }
    if let first=originals.first, launchedFrom(first,executableBundle:source,registeredURL:NSRunningApplication.current.bundleURL,arguments:CommandLine.arguments) {
      register(first); return true
    }
    let a=NSAlert()
    if let existing=originals.first {
      a.messageText="如流已安装";a.addButton(withTitle:"打开如流");a.addButton(withTitle:"取消")
      NSApp.activate();if a.runModal() == .alertFirstButtonReturn { openInstalled(existing) };return false
    }
    a.messageText="安装如流"; a.informativeText="将如流放入“应用程序”，安装后自动打开。"
    a.addButton(withTitle:"安装并打开");a.addButton(withTitle:"取消");NSApp.activate();guard a.runModal() == .alertFirstButtonReturn else {return false}
    do {
      guard let dir=locations.first(where:{fm.isWritableFile(atPath:$0.path)}) ?? locations.last else {return false}
      try fm.createDirectory(at:dir,withIntermediateDirectories:true)
      let dest=dir.appendingPathComponent("如流.app"), stage=dir.appendingPathComponent(".phraseflow-\(UUID().uuidString)",isDirectory:true)
      try fm.createDirectory(at:stage,withIntermediateDirectories:false);defer{try? fm.removeItem(at:stage)}
      let copy=stage.appendingPathComponent("如流.app");try fm.copyItem(at:source,to:copy)
      try fm.moveItem(at:copy,to:dest);openInstalled(dest);return false
    } catch { NSAlert(error:error).runModal();return false }
  }

  @MainActor private static func openInstalled(_ target:URL) {
    register(target)
    // Reopen this exact installation if running, never substitute the installer on the disk image.
    let config=NSWorkspace.OpenConfiguration();config.activates=true;config.allowsRunningApplicationSubstitution=false
    config.arguments=[installArgument,target.path]
    handingOff=true
    // Keep the installer in the foreground until the installed copy can take over its window focus.
    if let id=Bundle(url:target)?.bundleIdentifier { NSApp.yieldActivation(toApplicationWithBundleIdentifier:id) }
    NSWorkspace.shared.openApplication(at:target,configuration:config) { app,error in Task { @MainActor in
      defer { NSApp.terminate(nil) }
      if let error {
        let a=NSAlert();a.messageText="如流已安装，未能打开";a.informativeText=error.localizedDescription
        a.addButton(withTitle:"在访达中显示");a.addButton(withTitle:"完成");NSApp.activate()
        if a.runModal() == .alertFirstButtonReturn {NSWorkspace.shared.activateFileViewerSelecting([target])}
        return
      }
      guard let app else {return}
      // Launch Services can return before the destination has a window. Yield the foreground once, when ready.
      let deadline=ContinuousClock.now.advanced(by:.seconds(10))
      while !app.isFinishedLaunching && !app.isTerminated && .now < deadline {try? await Task.sleep(for:.milliseconds(80))}
      guard app.isFinishedLaunching, !app.isTerminated, !app.isActive else {return}
      NSApp.yieldActivation(to:app);app.unhide();_=app.activate(options:[.activateAllWindows])
      let transfer=ContinuousClock.now.advanced(by:.seconds(1))
      while !app.isActive && !app.isTerminated && .now < transfer {try? await Task.sleep(for:.milliseconds(40))}
    } }
  }
  // Only the recent shelf belongs to this operation. A pinned tile and other Dock preferences are user choices.
  static func ownRecent(_ tile:[String:Any], at bundle:URL)->Bool {
    guard let data=tile["tile-data"] as? [String:Any] else {return false}
    if let identifier=data["bundle-identifier"] as? String, !identifier.isEmpty {return identifier == id}
    guard let file=data["file-data"] as? [String:Any],let raw=file["_CFURLString"] as? String,
          let url=URL(string:raw),url.isFileURL else {return false}
    return url.standardizedFileURL.path == bundle.standardizedFileURL.path
  }
  static func clearDockRecent(at bundle:URL) {
    let dock="com.apple.dock" as CFString, key="recent-apps" as CFString
    CFPreferencesAppSynchronize(dock)
    guard let items=CFPreferencesCopyAppValue(key,dock) as? [[String:Any]] else {return}
    let remaining=items.filter { !ownRecent($0,at:bundle) }
    guard remaining.count != items.count else {return}
    CFPreferencesSetAppValue(key,remaining as CFArray,dock)
    // The running Dock caches recent tiles even after synchronizing its domain. Refresh only
    // this login session, and only when this uninstall actually removed a recent tile.
    if CFPreferencesAppSynchronize(dock), let current=NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.dock").first,
       current.bundleURL?.path == "/System/Library/CoreServices/Dock.app" { _ = current.terminate() }
  }
  static func eraseData(library:URL,home:URL,domain:String,defaults:UserDefaults) throws {
    let libraryDir=home.appendingPathComponent("Library",isDirectory:true)
    let paths=[library]+["Caches/\(domain)","HTTPStorages/\(domain)","HTTPStorages/\(domain).binarycookies","WebKit/\(domain)","Saved Application State/\(domain).savedState"].map {libraryDir.appendingPathComponent($0)}
    for u in paths where fm.fileExists(atPath:u.path) { try fm.removeItem(at:u) }
    defaults.removePersistentDomain(forName:domain);defaults.synchronize()
  }
}
