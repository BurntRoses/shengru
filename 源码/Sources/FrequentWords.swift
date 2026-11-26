import Foundation
import NaturalLanguage
import CryptoKit

// Record IDs make a review replace the evidence for that take, never increment it again.
// No sentence, time, app identity, microphone data or outside document is stored here.
struct FrequentWords: Codable, Equatable {
  struct Entry: Codable, Equatable, Identifiable {
    let id: UUID
    var spelling: String, count: Int, retired: Int
  }
  private struct Take: Codable, Equatable { let id: UUID; var words: [String] }
  private var takes: [Take] = [], entries: [String: Entry] = [:], excluded = Set<String>()
  static let threshold = 3, window = 80, capacity = 600
  var ordered: [Entry] { entries.values.sorted { $0.count == $1.count ? $0.spelling.localizedStandardCompare($1.spelling) == .orderedAscending : $0.count > $1.count } }
  var hasEvidence: Bool { !entries.isEmpty || takes.contains { !$0.words.isEmpty } }
  private static func exclusionKey(_ key: String) -> String { Data(SHA256.hash(data: Data(key.utf8))).base64EncodedString() }
  mutating func observe(_ names: [String], id: UUID, supported: Set<String>? = nil) {
    let carried = Set(takes.first(where: { $0.id == id })?.words ?? [])
    var keys = Set<String>(), spelling = [String: String]()
    let unique = names.compactMap { name -> String? in
      let key = name.lowercased()
      guard supported?.contains(key) != false || carried.contains(key),
        excluded.isEmpty || !excluded.contains(Self.exclusionKey(key)), keys.insert(key).inserted else { return nil }
      spelling[key] = name; return key
    }.prefix(96)
    let next = Array(unique), old = takes.firstIndex { $0.id == id }
    if let old {
      if takes[old].words == next { return }
      keys.formUnion(takes[old].words); takes[old].words = next
    } else if !next.isEmpty { takes.append(Take(id: id, words: next)) } else { return }
    if takes.count > Self.window {
      for key in takes.removeFirst().words where entries[key] != nil { entries[key]?.retired += 1 }
    }
    // Bound the ledger; do not evict an established word just because it has not been used lately.
    var counts = [String: Int]()
    for take in takes { for key in take.words where keys.contains(key) { counts[key, default: 0] += 1 } }
    for key in keys.sorted() {
      let n = (counts[key] ?? 0) + (entries[key]?.retired ?? 0)
      if n < Self.threshold { entries.removeValue(forKey: key) }
      else if entries[key] != nil { entries[key]?.count = n }
      else if entries.count < Self.capacity, let name = spelling[key] {
        entries[key] = Entry(id: UUID(), spelling: name, count: n, retired: 0)
      }
    }
  }
  mutating func forget(_ name: String) {
    let key = name.lowercased(); excluded.insert(Self.exclusionKey(key)); entries.removeValue(forKey: key)
    for i in takes.indices { takes[i].words.removeAll { $0 == key } }
  }
  mutating func clear() { takes.removeAll(); entries.removeAll() }
  func hints(previous: [String], allows: (String) -> Bool) -> [String] {
    let recent = WordContext.fresh(previous.first ?? "").lowercased()
    guard !recent.isEmpty else { return [] }
    // Frequency is not evidence for an unrelated take, even for a distinctive identifier.
    return Array(ordered.lazy.filter {
      let w = $0.spelling
      return w.count >= 3 && recent.contains(w.lowercased())
    }.map(\.spelling).filter(allows).prefix(4))
  }
}

enum WordCapture {
  static func isCommon(_ word: String) -> Bool { stop.contains(word) }
  private static let stop = Set("这个 那个 这些 那些 一个 一种 有些 一点 一下 一些 一次 一样 一直 一起 一边 一会 一会儿 我们 你们 他们 她们 大家 自己 人家 有人 谁的 什么 为什么 怎么 怎么样 哪个 哪里 这样 那样 现在 刚才 刚刚 之前 之后 然后 接着 最后 首先 其次 第一 第二 今天 明天 昨天 最近 时候 时间 事情 东西 内容 问题 方法 工作 情况 方面 意思 原因 关系 感觉 结果 需要 可以 可能 应该 已经 就是 因为 所以 如果 但是 不过 其实 还有 没有 不是 不要 不能 不用 实在 特别 比较 非常 好像 还是 正在 确实 应当 主要 基本 一般 你好 谢谢 好的 好了 知道 觉得 认为 表示 开始 结束 看看 大概 基本上 实际上 也就是说 来说 对于 来看 确认 用词 名称 名字 项目 代号 版本 小组 系统 应用 测试 产品 我想 我说 好吧 对吧 是的 是吧 的话 来着 地方 公司 人员 方式 办法 部分 过程 时候 用户 个人 边上 对方 中间 重点 信息 记录 讨论 进行 使用 喜欢 经常 介绍 相关 词库 文本 文字 分享 一个是 另一个 另外 之前的 之后的 这次 那次 希望 同意 沟通 重新 更多 时候的 的时候 今天的 他们的 自己的 and the that this with from into have about would should could your our they them then also really hello thanks thank please there here today tomorrow something anything just some want like okay because actually don't again team project update use using next before after need said called".components(separatedBy: " "))
  private static let secret = try! NSRegularExpression(pattern: #"(?i)(密码|验证码|口令|密钥|私钥|身份证|银行卡|手机号|电话号码|住址|邮箱|电子邮件|账号|账户名|password|passcode|api[ _-]?key|access[ _-]?token|secret|https?://|www\.|[\w.+-]+@[\w.-]+|(?:[0-9][ -]?){6,}|[A-Za-z0-9_-]{28,}|(?:^|\s|[:：])[/~][\w./-]+)"#)
  private static let names = try! NSRegularExpression(pattern: #"[「『“《]([\p{Han}A-Za-z][\p{Han}A-Za-z0-9 ·-]{1,19})[」』”》]|(?:项目代号|项目名|产品名|小组名|名字|代号)(?:叫作|叫做|叫|是|为|：|:)([\p{Han}A-Za-z][\p{Han}A-Za-z0-9·-]{1,11})(?=$|[，。！？；、,!?;\s])"#)
  private static let latin = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9_./@-])[A-Za-z][A-Za-z0-9-]{2,23}(?![A-Za-z0-9_./@-])"#)
  static func candidates(in text: String, vocabulary: BuiltinVocabulary) -> [String] {
    // Avoid tokenizing identifiers from sensitive clauses, including after punctuation inside an email or URL.
    guard secret.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) == nil else { return [] }
    let text = text.utf8.count <= 32000 ? text : String(text.prefix(4800)) + "。" + String(text.suffix(4800))
    let tokenizer = NLTokenizer(unit: .word); tokenizer.setLanguage(.simplifiedChinese)
    let tagger = NLTagger(tagSchemes: [.lexicalClass])
    var result: [String] = [], seen = Set<String>()
    func add(_ w: String) {
      let key = w.lowercased()
      guard result.count < 96, (2...32).contains(w.count), !stop.contains(key), w.contains(where: \.isLetter),
        !w.allSatisfy(\.isNumber), seen.insert(key).inserted else { return }
      result.append(w)
    }
    for slice in text.components(separatedBy: CharacterSet(charactersIn: "。！？；!?;\n")) where !slice.isEmpty && result.count < 96 {
      let range = NSRange(slice.startIndex..., in: slice)
      let ns = slice as NSString
      var named: [String] = []
      for m in names.matches(in: slice, range: range) {
        let r = m.range(at: 1).location == NSNotFound ? m.range(at: 2) : m.range(at: 1)
        let w = ns.substring(with: r).trimmed
        if !w.contains(where: { "的了着吗呢啊我你".contains($0) }) { add(w); named.append(w) }
      }
      let exact = vocabulary.exactWords(in: slice)
      for w in exact { add(w.name) }
      for m in latin.matches(in: slice, range: range) {
        let w = ns.substring(with: m.range)
        if w.dropFirst().contains(where: \.isUppercase) || w.first?.isUppercase == true || w.contains(where: \.isNumber) || (w.count >= 4 && slice.contains(where: SoundShelf.han)) { add(w) }
      }
      tokenizer.string = slice; tagger.string = slice
      tagger.setLanguage(.simplifiedChinese, range: slice.startIndex..<slice.endIndex)
      tokenizer.enumerateTokens(in: slice.startIndex..<slice.endIndex) { r, _ in
        let w = String(slice[r]); guard (2...10).contains(w.count), w.allSatisfy(SoundShelf.han),
          !named.contains(where: { $0 != w && $0.contains(w) }), !exact.contains(where: { $0.name != w && $0.name.contains(w) }), !stop.contains(w) else { return true }
        let tag = tagger.tag(at: r.lowerBound, unit: .word, scheme: .lexicalClass).0
        if tag == .noun || (w.count >= 3 && (tag == nil || tag == .otherWord)) { add(w) }
        return result.count < 96
      }
    }
    return result
  }
}
