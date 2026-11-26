import Foundation
import CryptoKit
import Combine

enum SpeechModel: String, Codable, CaseIterable {
  case extended, standard, long, precision, mandarinXL
  static let bundled: Self = .extended
  var localProfile: String? { self == .standard ? "480" : self == .long ? "1920" : nil }
  var title: String { switch self { case .standard:return "快速听写"; case .extended:return "均衡听写"; case .long:return "长句听写"; case .precision:return "全精度中英听写"; case .mandarinXL:return "普通话大模型" } }
  var caption: String { switch self { case .standard:return "中英双语 · 480 毫秒 · 离线启用"; case .extended:return "中英双语 · 960 毫秒 · 内置默认"; case .long:return "中英双语 · 1.92 秒 · 离线启用"; case .precision:return "中英双语 · 全精度 · 下载 584 MB"; case .mandarinXL:return "普通话 · Zipformer XL · 下载 598 MB" } }
  var cost:String { switch self { case .standard:return "启用约占 169 MB，优先出字速度。"; case .extended:return ""; case .long:return "启用约占 169 MB，先听更长一段再出字。"; case .precision:return "安装约 615 MB；比快速听写更占内存。"; case .mandarinXL:return "安装约 771 MB；计算量更大，不适合中英混说。" } }
  var folder:String { switch self { case .extended:return "x-asr-960"; case .long:return "x-asr-1920"; case .precision:return "x-asr-960-fp32"; case .mandarinXL:return "zipformer-zh-xl"; case .standard:return "x-asr-480" } }
  var package:ModelPackage? {
    let stem="sherpa-onnx-x-asr-", mid="ms-streaming-zipformer-transducer-zh-en-punct-"
    switch self {
    case .extended:return nil
    case .standard:return .init(name:stem+"480"+mid+"int8-2026-06-05",bytes:133895136,digest:"fa5f63d618e5a01526e275a358bb7772e403f84808a4769fba52cffd8160bf74",model:self)
    case .long:return .init(name:stem+"1920"+mid+"int8-2026-06-05",bytes:133894723,digest:"fdae310438a22e4acba3ae8280320d25365e66da269fcac2a906c98c51e705e4",model:self)
    case .precision:return .init(name:stem+"960"+mid+"2026-06-05",bytes:584119349,digest:"96bd82b638a64068ea80913779cad0a196f60bf9d16aa94770ec894ad7d61753",model:self)
    case .mandarinXL:return .init(name:"sherpa-onnx-streaming-zipformer-zh-xlarge-int8-2025-06-30",bytes:597755927,digest:"30437d84dc4861740d40166212ab05f3728945443d53691620075c4031fb88e1",model:self)
    }
  }
}
struct ModelPackage {
  let name:String, bytes:Int64, digest:String, model:SpeechModel
  var url:URL { URL(string:"https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/"+name+".tar.bz2?download=1")! }
  var files:[String:String] {
    let q=model == .precision ? "" : ".int8"
    var f=["encoder"+q+".onnx":"encoder.onnx","decoder.onnx":"decoder.onnx","joiner"+q+".onnx":"joiner.onnx","tokens.txt":"tokens.txt"]
    if model != .mandarinXL { f["bpe.model"]="bpe.model" }; return f
  }
  static let contents = ["encoder.onnx":"017e3cf23097302dbc57ebd72cf4a209cf55c367920669e2d9ce9c0381a96ddd","decoder.onnx":"a1cbc9eac2d5e3fb6617a218c67ad6daaa7f4e0fd225f08b2c22ab0413c8c257","joiner.onnx":"aedb7fa697b2ab43f20499826fff7c997eea7d67db77be97769aeeeb726e63b3","tokens.txt":"b818a60878b9aae978cbb8ad594acbd403d76d1af2e31ef4197c84e2dbdba27c","bpe.model":"f87a38025a5fdd1e4e9591f6a44bb81295097ce0b80df6f4ab9f44e52c64ca5f"]
  private var pins:[String:String] { switch model {
    case .standard: return Self.contents.merging(["encoder.onnx":"908596dcc137a73b95be908ca55e88caa1b3dbbe8027c171615f4b0609c5eb1e"]) { _,new in new }
    case .long: return ["decoder.onnx":"a1cbc9eac2d5e3fb6617a218c67ad6daaa7f4e0fd225f08b2c22ab0413c8c257", "bpe.model":"f87a38025a5fdd1e4e9591f6a44bb81295097ce0b80df6f4ab9f44e52c64ca5f", "tokens.txt":"b818a60878b9aae978cbb8ad594acbd403d76d1af2e31ef4197c84e2dbdba27c", "joiner.onnx":"aedb7fa697b2ab43f20499826fff7c997eea7d67db77be97769aeeeb726e63b3", "encoder.onnx":"32b64cc521a975bf0af51e74531a55477fafd00a5381b2c3398ac4f87d898f90"]
    case .precision: return ["decoder.onnx":"a1cbc9eac2d5e3fb6617a218c67ad6daaa7f4e0fd225f08b2c22ab0413c8c257", "joiner.onnx":"c4e598c15343e5546ea8533b34512302dfbf4e11fc4a77b7cfcdb4c918f4f16a", "bpe.model":"f87a38025a5fdd1e4e9591f6a44bb81295097ce0b80df6f4ab9f44e52c64ca5f", "tokens.txt":"b818a60878b9aae978cbb8ad594acbd403d76d1af2e31ef4197c84e2dbdba27c", "encoder.onnx":"0215a92acf189a9da3b9d0f44a683ad8240e8d90b8bd3f7b7fa275bbd8322981"]
    case .mandarinXL: return ["decoder.onnx":"8f9c903da2818f207304a3f30b9eeb30028e30398f333c1e95e12c97704173e6", "tokens.txt":"6722bd1585f46f84456b29c3550a343a3cc375b971645773c02ed8e0b4e2405c", "joiner.onnx":"f76ffce14b6ef80098cfdbce8846896ff68133970abc314eafab632f910df0d7", "encoder.onnx":"f2c543a0330e1ed0bd09c82e4ae7d3f1cbee10a15feca638fcc4f88083a36b8a"]
    default:return Self.contents
  } }
  func validate(_ dir:URL) throws {
    let expected=pins
    guard Set(expected.keys)==Set(files.values) else { throw VoiceFault.message("模型文件不完整。") }
    for (name,want) in expected { guard try checksum(dir.appendingPathComponent(name)) == want else { throw VoiceFault.message("模型文件不完整，请切回内置模型后重新安装。") } }
  }
  private func checksum(_ file:URL) throws -> String {
    let handle = try FileHandle(forReadingFrom:file); defer { try? handle.close() }; var hash = SHA256()
    while let block = try handle.read(upToCount:1 << 20), !block.isEmpty { try Task.checkCancellation(); hash.update(data:block) }
    return hash.finalize().map { String(format:"%02x",$0) }.joined()
  }
  // Expand the official encoder difference outside the signed bundle, then verify every file
  // against the original release. Enabling a local profile must not create a network task.
  func expandLocal(_ profile:String, builtin:URL, into stage:URL) throws {
    let fm=FileManager.default
    try fm.createDirectory(at:stage,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
    for name in files.values where name != "encoder.onnx" { try fm.copyItem(at:builtin.appendingPathComponent(name),to:stage.appendingPathComponent(name)) }
    let patch=builtin.deletingLastPathComponent().appendingPathComponent("Profiles/"+profile+".bsdiff")
    let task=Process(); task.executableURL=URL(fileURLWithPath:"/usr/bin/bspatch")
    task.arguments=[builtin.appendingPathComponent("encoder.onnx").path,stage.appendingPathComponent("encoder.onnx").path,patch.path]
    try Task.checkCancellation();try task.run();task.waitUntilExit()
    guard task.terminationStatus==0 else {throw VoiceFault.message("无法启用本地模型，请重新安装应用。")}
    try validate(stage)
  }
  func unpack(_ archive: URL, into stage: URL) throws {
    let fm = FileManager.default
    guard (try fm.attributesOfItem(atPath:archive.path)[.size] as? NSNumber)?.int64Value == bytes else { throw VoiceFault.message("下载不完整，请重试。") }
    guard try checksum(archive) == digest else { throw VoiceFault.message("文件校验未通过，请重新安装。") }
    try fm.createDirectory(at: stage, withIntermediateDirectories:true, attributes:[.posixPermissions:0o700])
    let tar = Process(); tar.executableURL = URL(fileURLWithPath:"/usr/bin/tar")
    tar.arguments = ["-xjf",archive.path,"-C",stage.path,"--strip-components","1"] + files.keys.sorted().map { name + "/" + $0 }
    try tar.run(); tar.waitUntilExit()
    guard tar.terminationStatus == 0 else { throw VoiceFault.message("模型未能展开，请检查可用空间后重试。") }
    for (source, dest) in files where source != dest { try fm.moveItem(at:stage.appendingPathComponent(source), to:stage.appendingPathComponent(dest)) }
    try validate(stage)
  }
}
private final class ArchiveTransfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
  private let package:ModelPackage
  private let destination: URL, report: (Double)->Void, lock = NSLock()
  private var continuation: CheckedContinuation<Void, Error>?, task: URLSessionDownloadTask?, cancelled = false
  // Delegate callbacks are serialized by URLSession. Cancellation can arrive before task creation.
  private var result: Result<Void,Error>?, last = -1
  init(package:ModelPackage,destination:URL, report:@escaping (Double)->Void) { self.package=package; self.destination = destination; self.report = report }
  func fetch() async throws {
    try await withTaskCancellationHandler(operation:{
      try await withCheckedThrowingContinuation { (cont:CheckedContinuation<Void,Error>) in
        lock.lock(); guard !cancelled else { lock.unlock(); cont.resume(throwing:CancellationError()); return }
        let config = URLSessionConfiguration.ephemeral; config.urlCache = nil; config.httpCookieStorage = nil; config.timeoutIntervalForResource = 1800
        let net = URLSession(configuration:config,delegate:self,delegateQueue:nil)
        let t = net.downloadTask(with:package.url); continuation = cont; task = t; t.resume(); lock.unlock()
      }
    }, onCancel:{ self.cancelTransfer() })
  }
  private func cancelTransfer() { lock.lock(); cancelled = true; let t = task; lock.unlock(); t?.cancel() }
  func urlSession(_ session:URLSession,downloadTask:URLSessionDownloadTask,didFinishDownloadingTo location:URL) {
    result = Result { guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 else { throw VoiceFault.message("下载服务暂不可用，请重试。") }; try FileManager.default.moveItem(at:location,to:destination) }
  }
  func urlSession(_ session:URLSession,task:URLSessionTask,didCompleteWithError error:Error?) {
    lock.lock(); let cont = continuation; continuation = nil; self.task = nil; lock.unlock(); session.finishTasksAndInvalidate()
    cont?.resume(with:error.map { .failure($0) } ?? result ?? .failure(VoiceFault.message("下载未完成，请重试。")))
  }
  func urlSession(_ session:URLSession,downloadTask:URLSessionDownloadTask,didWriteData bytesWritten:Int64,totalBytesWritten:Int64,totalBytesExpectedToWrite:Int64) {
    let percent = min(99,Int(totalBytesWritten*100/package.bytes)); if percent != last { last = percent; report(Double(percent)/100) }
  }
}
// Mutations are delivered on the main queue; the transfer task owns only immutable paths.
final class ModelShelf: ObservableObject, @unchecked Sendable {
  @Published private(set) var installed: Set<SpeechModel> = [.bundled]
  @Published private(set) var installing:SpeechModel?
  @Published private(set) var progress: Double?
  @Published private(set) var verifying = false
  @Published private(set) var note = ""
  let builtin: URL, folder: URL

  private var job: Task<Void,Never>?, token: UUID?
  init(builtin: URL, root: URL) {
    self.builtin = builtin; folder = root.appendingPathComponent("Models", isDirectory:true)
    for model in SpeechModel.allCases { if let pack=model.package, pack.files.values.allSatisfy({ FileManager.default.isReadableFile(atPath:folder.appendingPathComponent(model.folder).appendingPathComponent($0).path) }) { installed.insert(model) } }

  }
  func url(_ model: SpeechModel) -> URL { model == .bundled ? builtin : folder.appendingPathComponent(model.folder) }
  func install(_ model:SpeechModel, onFailure: (() -> Void)? = nil, complete: @escaping () -> Void) {
    guard job == nil, !installed.contains(model), let pack=model.package else { return }
    let id = UUID(), folder = self.folder, dest = url(model), builtin = self.builtin
    installing=model; token = id; progress = model.localProfile == nil ? 0 : nil; verifying = false; note = ""
    job = Task.detached(priority:.utility) { [weak self] in
      let fm = FileManager.default, work = folder.appendingPathComponent(".install-" + id.uuidString)
      let stage = work.appendingPathComponent("Speech"), archive = work.appendingPathComponent("archive")
      defer { try? fm.removeItem(at:work) }
      do {
        try fm.createDirectory(at:work, withIntermediateDirectories:true, attributes:[.posixPermissions:0o700])
        let required:Int64 = model.localProfile != nil ? 185_000_000 : pack.bytes*3
        if let free = try? folder.resourceValues(forKeys:[.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage, free < required { throw VoiceFault.message("需要约 \(required/1_000_000) MB 可用空间。") }
        if let profile=model.localProfile {
          try pack.expandLocal(profile,builtin:builtin,into:stage)
        } else {
          let transfer = ArchiveTransfer(package:pack,destination:archive) { [weak self] value in DispatchQueue.main.async { [weak self] in if self?.token == id, self?.verifying == false { self?.progress = value } } }
          try await transfer.fetch()
          try Task.checkCancellation()
          await MainActor.run { [weak self] in if self?.token == id { self?.progress = 1; self?.verifying = true } }
          try pack.unpack(archive, into:stage)
        }
        // Never activate a partially extracted model. Cancellation and promotion share the main queue.
        try await MainActor.run { [weak self] in
          guard let self, self.token == id, !Task.isCancelled else { throw CancellationError() }
          let fm = FileManager.default
          if fm.fileExists(atPath: dest.path) { try fm.removeItem(at:dest) }
          try fm.moveItem(at:stage,to:dest); self.installed.insert(model); self.reset(); complete()
        }
      } catch {
        let cancelled = Task.isCancelled
        await MainActor.run { [weak self] in guard let self, self.token == id else { return }; self.reset(); self.note = cancelled ? "已取消下载。" : "安装未完成：" + error.localizedDescription; onFailure?() }
      }
    }
  }
  func cancel() { job?.cancel() }
  private func reset() { job = nil; token = nil; installing=nil; progress = nil; verifying = false }
  func remove(_ model:SpeechModel) {
    guard job == nil, model != .bundled else { return }
    do { try FileManager.default.removeItem(at:url(model)); installed.remove(model); note = "" }
    catch { note = "模型未能移除：" + error.localizedDescription }
  }
}
