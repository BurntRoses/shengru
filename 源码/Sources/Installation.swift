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
  @MainActor static func prepare(_ source:URL)->Bool {
    let originals=directories.flatMap { dir in
      ((try? fm.contentsOfDirectory(at:dir,includingPropertiesForKeys:nil,options:.skipsHiddenFiles)) ?? [])
        .filter { $0.pathExtension == "app" && Bundle(url:$0)?.bundleIdentifier == id }
        .sorted { a,b in
          if a.lastPathComponent == "如流.app" {return b.lastPathComponent != "如流.app"}
          if b.lastPathComponent == "如流.app" {return false}
          return a.lastPathComponent < b.lastPathComponent
        }
    }
    if installed(source), originals.first?.standardizedFileURL.path == source.standardizedFileURL.path {
      register(source); return true
    }
    let a=NSAlert();a.messageText="将如流安装到“应用程序”"; a.informativeText="安装后再开启听写权限。"
    if let existing=originals.first {
      a.messageText="如流已安装"; a.informativeText="请使用“应用程序”中的这一份。";a.addButton(withTitle:"在访达中显示");a.addButton(withTitle:"退出")
      NSApp.activate();if a.runModal() == .alertFirstButtonReturn {NSWorkspace.shared.activateFileViewerSelecting([existing])};return false
    }
    a.addButton(withTitle:"安装并打开");a.addButton(withTitle:"取消");NSApp.activate();guard a.runModal() == .alertFirstButtonReturn else {return false}
    do {
      let dir=directories.first(where:{fm.isWritableFile(atPath:$0.path)}) ?? directories[1]
      try fm.createDirectory(at:dir,withIntermediateDirectories:true)
      let dest=dir.appendingPathComponent("如流.app"), stage=dir.appendingPathComponent(".phraseflow-\(UUID().uuidString)",isDirectory:true)
      try fm.createDirectory(at:stage,withIntermediateDirectories:false);defer{try? fm.removeItem(at:stage)}
      let copy=stage.appendingPathComponent("如流.app");try fm.copyItem(at:source,to:copy)
      try fm.moveItem(at:copy,to:dest);register(dest)
      let config=NSWorkspace.OpenConfiguration();config.createsNewApplicationInstance=true
      handingOff=true
      NSWorkspace.shared.openApplication(at:dest,configuration:config) { _,error in DispatchQueue.main.async {if let error {NSAlert(error:error).runModal()}; NSApp.terminate(nil)} };return false
    } catch { NSAlert(error:error).runModal();return false }
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
