import Foundation

enum MaterialChoice: String, CaseIterable, Codable {
  case glass = "液态玻璃"
  case frost = "磨砂"
  case solid = "纯色"
}
enum Placement: String, CaseIterable, Codable {
  case bottom = "底部居中"
  case top = "右上方"
}
enum Trigger: String, CaseIterable, Codable {
  case shortcut = "⌃ ⇧ 空格"
  case option = "右 ⌥ Option"
  case control = "右 ⌃ Control"
  case command = "右 ⌘ Command"
  case f6 = "F6"
  var registered: Bool { self == .shortcut || self == .f6 }
  var code: UInt16 {
    switch self {
    case .shortcut: return 49
    case .option: return 61
    case .control: return 62
    case .command: return 54
    case .f6: return 97
    }
  }
}
struct Options: Codable, Equatable {
  var level: EditLevel = .natural
  var trigger: Trigger = .command
  var shortToggle = true
  var autoInsert = true
  var keepText = true
  var proofWords = true
  var compactQuiet = true
  var keepAudio = true
  var limitText = 20
  var limitAudio = 20
  var appearance = CapsuleAppearance()
  var welcomed = false
  var reviewFirst = false
  var collectFrequent = true
  var learning = true
  var linkContext = true
  var model: SpeechModel = .bundled
  var followsModelDefault: Bool? = true
  init() {}
  init(from decoder: Decoder) throws {
    self.init()
    let c = try decoder.container(keyedBy: CodingKeys.self)
    appearance = try c.decodeIfPresent(CapsuleAppearance.self, forKey: .appearance) ?? CapsuleAppearance(from: decoder)
    level = try c.decodeIfPresent(EditLevel.self, forKey: .level) ?? level
    trigger = try c.decodeIfPresent(Trigger.self, forKey: .trigger) ?? trigger
    shortToggle = try c.decodeIfPresent(Bool.self, forKey: .shortToggle) ?? shortToggle
    autoInsert = try c.decodeIfPresent(Bool.self, forKey: .autoInsert) ?? autoInsert
    keepText = try c.decodeIfPresent(Bool.self, forKey: .keepText) ?? keepText
    proofWords = try c.decodeIfPresent(Bool.self,forKey:.proofWords) ?? true
    compactQuiet = try c.decodeIfPresent(Bool.self, forKey:.compactQuiet) ?? true
    keepAudio = try c.decodeIfPresent(Bool.self, forKey: .keepAudio) ?? keepAudio
    limitText = try c.decodeIfPresent(Int.self, forKey: .limitText) ?? limitText
    limitAudio = try c.decodeIfPresent(Int.self, forKey: .limitAudio) ?? limitAudio
    welcomed = try c.decodeIfPresent(Bool.self, forKey: .welcomed) ?? welcomed
    reviewFirst = try c.decodeIfPresent(Bool.self, forKey: .reviewFirst) ?? reviewFirst
    learning = try c.decodeIfPresent(Bool.self, forKey: .learning) ?? learning
    collectFrequent = try c.decodeIfPresent(Bool.self, forKey: .collectFrequent) ?? learning
    linkContext = try c.decodeIfPresent(Bool.self, forKey: .linkContext) ?? linkContext
    model = try c.decodeIfPresent(SpeechModel.self, forKey: .model) ?? model
    followsModelDefault = try c.decodeIfPresent(Bool.self,forKey:.followsModelDefault) ?? (c.contains(.model) ? nil : true)
  }

}
enum HistoryPart: String {
  case text = "文字"
  case audio = "录音"
  case both = "文字和录音"
}
struct Record: Identifiable, Codable, Equatable {
  var id: UUID
  var at: Date
  var text: String?
  var audio: String?
  var seconds: Double
  var mode: EditLevel
  var incompleteAudio: Bool? = nil
  var sectionCount: Int? = nil
  var conversation: UUID? = nil
  var choices: [ReadingChoice]? = nil
  mutating func keepChoices(_ pool: [ReadingChoice]) {
    let remaining = text.map { s in pool.prefix(8).filter { $0.applying(to:s) != nil } } ?? []
    choices = remaining.isEmpty ? nil : remaining
  }
}
final class Library {
  let root: URL
  let audioDir: URL
  let spool: URL
  private let fm = FileManager.default
  private(set) var records: [Record] = []
  private(set) var memories: [Term] = []
  private(set) var terms: [Term] = []
  private(set) var frequencies = FrequentWords()
  private(set) var policy = WordPolicy()
  private(set) var options = Options()
  init(root: URL) throws {
    self.root = root
    audioDir = root.appendingPathComponent("Recordings")
    spool = root.appendingPathComponent("Capture")
    for d in [root, audioDir, spool] {
      try fm.createDirectory(
        at: d, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    let savedOptions = try load("Settings", Options.self)
    options = savedOptions ?? Options()
    if savedOptions != nil {
      // Older versions serialized the bundled default when any unrelated switch changed.
      // A model shelf was only created on installation. Preserve an ambiguous prior choice.
      let follows=options.followsModelDefault ?? (options.model == .standard && !fm.fileExists(atPath:root.appendingPathComponent("Models").path))
      options.followsModelDefault=follows; if follows {options.model = .bundled}
      if options != savedOptions {try put(options,"Settings")}
    }
    policy = try load("VocabularySettings", WordPolicy.self) ?? (savedOptions != nil ? WordPolicy.priorDefault : WordPolicy())
    if !fm.fileExists(atPath: root.appendingPathComponent("VocabularySettings.json").path) { try put(policy, "VocabularySettings") }
    frequencies = try load("FrequentWords", FrequentWords.self) ?? FrequentWords()
    records = try load("History", [Record].self) ?? []
    memories = try load("Corrections", [Term].self) ?? []
    terms = try load("Terms", [Term].self) ?? []
    // A completed five-minute chapter survives an unexpected exit. Never touch another
    // capture, invent text, or publish recordings that were waiting for explicit review.
    for dir in (try? fm.contentsOfDirectory(at:spool,includingPropertiesForKeys:nil)) ?? [] where dir.pathExtension == "clips" {
      guard let id = UUID(uuidString:dir.deletingPathExtension().lastPathComponent) else { continue }
      let fd = Darwin.open(dir.appendingPathComponent(".active").path,O_RDWR); guard fd >= 0 else { continue }; defer { Darwin.close(fd) }
      guard flock(fd, LOCK_EX|LOCK_NB) == 0 else { continue }
      let tracks=SectionRecorder.tracks(dir)
      if options.keepAudio, fm.fileExists(atPath:dir.appendingPathComponent(".recover").path), !tracks.isEmpty, !records.contains(where:{$0.id==id}) {
        let saved = audioDir.appendingPathComponent(dir.lastPathComponent)
        // Only sealed chapters have valid headers; an interrupted tail is not playable.
        for partial in (try? fm.contentsOfDirectory(at:dir,includingPropertiesForKeys:nil)) ?? [] where partial.pathExtension=="partial" { try? fm.removeItem(at:partial) }
        let seconds = tracks.reduce(0.0) { t,u in t+Double(max(0,((try? u.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 44)-44))/32000 }
        try fm.moveItem(at:dir,to:saved)
        do { try trim([Record(id:id,at:(try? saved.resourceValues(forKeys:[.creationDateKey]).creationDate) ?? Date(),text:nil,audio:saved.lastPathComponent,seconds:seconds,mode:options.level,sectionCount:tracks.count)] + records) }
        catch { try? fm.moveItem(at:saved,to:dir); throw error }
      } else { try? fm.removeItem(at:dir) }
    }
  }
  static var home: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("语音输入", isDirectory: true)
  }
  private func load<T: Decodable>(_ name: String, _ type: T.Type) throws -> T? {
    let url = root.appendingPathComponent(name + ".json")
    guard fm.fileExists(atPath: url.path) else { return nil }
    return try JSONDecoder().decode(type, from: Data(contentsOf: url))
  }
  private func put<T: Encodable>(_ v: T, _ name: String) throws {
    let url = root.appendingPathComponent(name + ".json")
    try JSONEncoder().encode(v).write(to: url, options: .atomic)
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
  func save(_ v: Options) throws {
    try put(v, "Settings")
    options = v
    try trim(records)
  }
  func savePolicy(_ next: WordPolicy) throws {
    try put(next, "VocabularySettings")
    policy = next
  }
  func saveTerms(_ v: [Term]) throws {
    try put(v, "Terms")
    terms = v
  }
  func saveFrequencies(_ next: FrequentWords) throws {
    try put(next, "FrequentWords"); frequencies = next
  }
  func saveMemories(_ next: [Term]) throws {
    try put(next, "Corrections")
    memories = next
  }
  func revise(_ id: UUID, text: String, choices: [ReadingChoice]? = nil) throws {
    guard let index = records.firstIndex(where: { $0.id == id }), records[index].text != nil else {
      return
    }
    var next = records
    next[index].text = text
    next[index].keepChoices(choices ?? records[index].choices ?? [])
    try commit(next, previous: records)
  }
  func audioURL(_ name: String?) -> URL? {
    guard let n = name, !n.contains("/"), let dot=n.lastIndex(of:"."), [".wav",".clips"].contains(String(n[dot...])), UUID(uuidString:String(n[..<dot])) != nil else {
      return nil
    }
    return audioDir.appendingPathComponent(n)
  }
  func record(
    _ text: String, audio: URL?, seconds: Double, options o: Options, id: UUID = UUID(),
    conversation: UUID? = nil, incompleteAudio: Bool = false, choices: [ReadingChoice] = []
  ) throws {
    if !o.keepAudio, let u=audio { try? fm.removeItem(at:u) }
    guard !text.trimmed.isEmpty && (o.keepText || (o.keepAudio && audio != nil)) else {
      if let u=audio { try? fm.removeItem(at:u) }; return
    }
    let name = id.uuidString + (audio?.pathExtension == "clips" ? ".clips" : ".wav")
    let parts = audio.flatMap { $0.pathExtension == "clips" ? SectionRecorder.tracks($0).count : nil }
    var filename: String?
    if o.keepAudio, let src = audio, let dest = audioURL(name) {
      // This method is reached only after an explicit review or automatic acceptance.
      if src.pathExtension == "clips" { try Data().write(to:src.appendingPathComponent(".recover")) }
      try fm.moveItem(at: src, to: dest)
      filename = name
    }
    do {
      var record = Record(id: id, at: Date(), text: o.keepText ? text : nil, audio: filename, seconds: seconds,
        mode: o.level, incompleteAudio: incompleteAudio ? true : nil, sectionCount: parts, conversation: o.keepText ? conversation : nil)
      record.keepChoices(choices); try trim([record] + records)
    } catch {
      if !records.contains(where:{$0.id == id}), let u=audioURL(filename), let src=audio {
        if u.pathExtension == "clips" { try? fm.moveItem(at:u,to:src) }
        else { try? fm.removeItem(at:u) }
      }
      throw error
    }
  }
  private func trim(_ rows: [Record]) throws {
    var nt = 0
    var na = 0
    let next = rows.compactMap { record -> Record? in
      var r = record
      if r.text != nil {
        nt += 1
        if nt > max(0, options.limitText) {
          r.text = nil; r.choices = nil
          r.conversation = nil
        }
      }
      if r.audio != nil {
        na += 1
        if na > max(0, options.limitAudio) { r.audio = nil }
      }
      return r.text == nil && r.audio == nil ? nil : r
    }
    if next == records && rows == records { return }
    try commit(next, previous: rows)
  }
  private func commit(_ next: [Record], previous: [Record]) throws {
    try put(next, "History")
    records = next
    let keep = Set(next.compactMap(\.audio))
    for n in Set(previous.compactMap(\.audio)).subtracting(keep) {
      if let u = audioURL(n), fm.fileExists(atPath: u.path) { try fm.removeItem(at: u) }
    }
  }
  func delete(_ id: UUID?, part: HistoryPart = .both) throws {
    let previous = records
    let next = previous.compactMap { row -> Record? in
      guard id == nil || id == row.id else { return row }
      var r = row
      if part != .audio {
        r.text = nil; r.choices = nil
        r.conversation = nil
      }
      if part != .text { r.audio = nil }
      return r.text == nil && r.audio == nil ? nil : r
    }
    try commit(next, previous: previous)
  }
}
