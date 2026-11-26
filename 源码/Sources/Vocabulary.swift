import Foundation

// Only the packaged spelling tables are used at runtime. Recognition variants are not synonyms.
final class BuiltinVocabulary {
  enum Group: String, CaseIterable {
    case place = "地名"
    case publicLife = "就业与公共事务"
    case names = "科学与专名"
    case tech = "技术与缩写"
    case phrases = "常用词组"
    case landmarks = "地标与目的地"
    case culture = "机构与文化专名"
    case sport = "体育与赛事"
    case vibe = "AI / Vibe Coding"
    case code = "程序开发"
    case science = "科研写作"
    case literature = "汉语言文学"
    case classical = "诗文熟语"
    case design = "设计与交互"
    case earth = "地学与环境"
    case finance = "财会与金融"
    case law = "法律实务"
    case medical = "医疗与健康"
    case civil = "建筑与土木"
    case factory = "机械与制造"
    case power = "电气与能源"
    case logistics = "物流与供应链"
    case education = "教育与教学"
    case media = "影视与音频"
    case farming = "农业与园艺"
    var industry: Bool { [.vibe, .code, .science, .literature, .design, .earth, .finance, .law, .medical, .civil, .factory, .power, .logistics, .education, .media, .farming].contains(self) }
    case dailyLife = "居家与休闲"
    case nature, technology, society, style, food, travel
  }
  struct Word: Identifiable {
    let name: String, group: Group, variants: [String], cues: [String], flags: String
    var tags: [String] = [], aliases: [String] = []
    var subject: WordSubject? = nil
    var section: String? = nil
    var id: String { name }
  }
  private struct Node {
    var children: [Character: Int] = [:]
    var word: Int?
  }
  static let shared = BuiltinVocabulary(
    directory: Bundle.main.resourceURL?.appendingPathComponent("Vocabulary"))
  let words: [Word]
  private struct Pattern { let index: Int, letters: [Character] }
  private var patterns = [Character: [Pattern]]()
  private let readings: [String: Set<String>]
  private var nodes = [Node()], geoForms = Set<String>(), nearPlaces: [String: Set<String>] = [:]
  let graph: WordContext, enabled: Set<String>
  let classics: ClassicalCorpus?
  let soundshelf:SoundShelf
  static let plain = BuiltinVocabulary([],graph:WordContext(topics:[],senses:[]),readings:[:])
  private let aliasOwners: [String: Set<String>]
  let bias: WordBias
  convenience init(directory: URL?) {
    func lines(_ filename: String) -> [[String]] {
      guard let file = directory?.appendingPathComponent(filename),
        let s = try? String(contentsOf: file, encoding: .utf8)
      else { return [] }
      return s.split(separator: "\n").map { $0.components(separatedBy: "\t") }
    }
    var entries: [Word] = []
    for r in lines("places.tsv") where !r[0].isEmpty {
      entries.append(
        Word(name: r[0], group: .place, variants: Array(r.dropFirst()), cues: [], flags: "", section: "行政地名"))
    }
    for r in lines("words.tsv") + lines("collections.tsv") where (5...8).contains(r.count) {
      guard let g = Group(rawValue: r[0]) else { continue }
      entries.append(
        Word(
          name: r[1], group: g, variants: r[2].split(separator: "|").map(String.init),
          cues: r[3].split(separator: "|").map(String.init), flags: r[4], aliases: r.count == 8 ? r[7].components(separatedBy: "|") : [], subject: r.count >= 6 ? WordSubject(rawValue: r[5]) : nil, section: r.count >= 7 ? r[6] : nil))
    }
    // Display aliases stay in search. Only the separate, context-qualified table can change a spelling.
    var corrections: [String: ([String], [String])] = [:]
    for r in lines("catalog-readings.tsv") where r.count == 3 {
      corrections[r[0]] = (r[1].components(separatedBy: "|"), r[2].components(separatedBy: "|"))
    }
    for r in lines("catalog.tsv") where (4...6).contains(r.count) {
      guard let g = Group(rawValue: r[0]) else { continue }
      let topics = r[1].components(separatedBy: "|")
      let cues = r[2].components(separatedBy: "|")
      for item in r[3].split(separator: "|") {
        let forms = item.components(separatedBy: "~")
        let name = forms[0], correction = corrections[name]
        entries.append(Word(name: name, group: g, variants: correction?.0 ?? [], cues: correction?.1 ?? cues, flags: "k", tags: topics, aliases: Array(forms.dropFirst()), subject: r.count >= 5 ? WordSubject(rawValue: r[4]) : nil, section: r.count >= 6 ? r[5] : nil))
      }
    }
    var peerSets = [String: Set<String>]()
    for set in lines("readings.tsv").map(Set.init) where set.count >= 2 {
      for word in set { peerSets[word] = set }
    }
    let witnesses = lines("classics.tsv"), pronunciation = lines("classical-sounds.tsv")
    let classics = witnesses.isEmpty || pronunciation.isEmpty ? nil : ClassicalCorpus(rows: witnesses, sounds: pronunciation)
    var known = Dictionary(uniqueKeysWithValues: entries.indices.map { (entries[$0].name.lowercased(), $0) })
    for w in classics?.words() ?? [] {
      let key = w.name.lowercased()
      if let i = known[key] { entries[i].tags += w.tags + [w.topic] }
      else { known[key] = entries.count; entries.append(w) }
    }
    self.init(
      entries,
      graph: WordContext(
        topics: lines("topics.tsv"), senses: lines("senses.tsv"), review: lines("review.tsv")),
      readings: peerSets, classics: classics)
  }
  func selecting(_ policy: WordPolicy) -> BuiltinVocabulary {
    if !policy.hasDisabledWords && policy.hidden.isEmpty && policy.blocked.isEmpty { return self }
    let selected = words.compactMap { w -> Word? in
      if policy.usesPrimarySource(w) { return w }
      // A spelling can have both a professional dictionary entry and a witness in a book.
      // Enabling the latter must not turn the former's substitutions or hotwords back on.
      guard policy.usesClassicalSource(w), let topic = w.classicalTopic else { return nil }
      return Word(name: w.name, group: .classical, variants: [], cues: [], flags: "v", tags: w.tags, subject: .arts, section: topic)
    }
    return BuiltinVocabulary(selected, graph: graph, readings: readings, classics: policy.usesClassics ? classics : nil, bias: WordBias(policy.blocked))
  }
  private init(_ entries: [Word], graph: WordContext, readings: [String: Set<String>], classics: ClassicalCorpus? = nil, bias: WordBias = WordBias([])) {
    self.classics = classics; self.bias = bias; soundshelf=SoundShelf(entries)
    self.readings = readings
    self.graph = graph
    enabled = Set(entries.map(\.name))
    words = entries
    var owners = [String: Set<String>]()
    for w in entries where !w.aliases.isEmpty {
      for form in [w.name] + w.aliases { owners[CatalogSearch.key(form), default: []].insert(w.name) }
    }
    aliasOwners = owners
    // Literary witnesses use a separate index; they are not ordinary hotwords or automatic learning seeds.
    for (idx, w) in entries.enumerated() where !w.flags.contains("v") {
      if w.flags.contains("p") {
        let p = Pattern(index: idx, letters: Array(w.name))
        for first in Set(([w.name] + w.variants).compactMap(\.first)) where Self.han(first) {
          patterns[first, default: []].append(p)
        }
      }
      for form in [w.name] + w.variants {
        var node = 0
        for c in form.lowercased() {
          if let n = nodes[node].children[c] {
            node = n
          } else {
            let n = nodes.count
            nodes.append(Node())
            nodes[node].children[c] = n
            node = n
          }
        }
        if nodes[node].word == nil || form == w.name { nodes[node].word = idx }
        if w.group == .place, geoForms.insert(form).inserted, (2...8).contains(form.count) {
          let chars = Array(form)
          for i in chars.indices { nearPlaces[Self.signature(chars, i), default: []].insert(form) }
        }
      }
    }
  }
  // Foreign names and their local names can lead to the same search result. They are
  // not dictation corrections, even when an older editing memory paired the two.
  func preservesSpelling(_ heard: String, insteadOf proposed: String) -> Bool {
    guard !heard.isEmpty, heard != proposed else { return false }
    if proposed.contains(where: Self.han), heard.contains(where: { $0.isLetter }), !heard.contains(where: Self.han) { return true }
    guard let a = aliasOwners[CatalogSearch.key(heard)], let b = aliasOwners[CatalogSearch.key(proposed)] else { return false }
    return !a.isDisjoint(with: b)
  }
  func permitsLearnedPair(_ term: Term) -> Bool {
    if preservesSpelling(term.spoken, insteadOf: term.spelling) { return false }
    // An older entry may include a shared phrase around the name, e.g. “Loewe 的包”.
    var heard = term.spoken[...], written = term.spelling[...]
    while let a = heard.first, a == written.first { heard = heard.dropFirst(); written = written.dropFirst() }
    while let a = heard.last, a == written.last { heard = heard.dropLast(); written = written.dropLast() }
    return !preservesSpelling(String(heard).trimmed, insteadOf: String(written).trimmed)
  }
  private static func signature(_ a: [Character], _ i: Int) -> String {
    String(a[..<i]) + "·" + String(a[(i + 1)...])
  }
  private static func han(_ c: Character) -> Bool {
    c.unicodeScalars.count == 1
      && c.unicodeScalars.first.map {
        (0x3400...0x9fff).contains($0.value) || (0x20000...0x323af).contains($0.value)
      } == true
  }
  private static func latin(_ c: Character) -> Bool {
    c.isASCII && (c.isNumber || c.isLetter || c == "_")
  }
  static func identity(_ left: String, _ right: String) -> Bool {
    let labels = [
      "我叫", "他叫", "她叫", "名叫", "叫作", "叫做", "名字是", "名为", "姓名", "人名", "原名", "笔名", "网名", "署名", "变量名",
      "文件名", "地名叫", "联系人", "姓氏", "写作", "读作", "保留原字", "误写", "写成", "改成", "听成", "识别成", "识别为", "原文是",
      "原话是", "拼作", "拼成", "而不是", "不是", "不要把",
    ]
    let nearby = String(left.reversed().prefix { !"。！？；!?;\n".contains($0) }.prefix(9).reversed())
    return labels.contains(where: nearby.contains)
      || [
        "先生", "女士", "老师", "同学", "博士", "工程师", "这个名字", "这个字", "这个词", "改成", "写成", "误写", "村", "镇", "街",
        "路口", "陵", "脑", "壑",
      ].contains(where: right.hasPrefix)
  }
  // Longest canonical matches, in utterance order. Do not derive learned spellings from a mishearing.
  func exactWords(in text: String, limit: Int = 96) -> [Word] {
    let a = Array(text.lowercased())
    var result: [Word] = [], seen = Set<String>(), i = 0
    while i < a.count && result.count < limit {
      if i > 0 && Self.latin(a[i-1]) && Self.latin(a[i]) { i += 1; continue }
      var node = 0, j = i, best: (Int, Word)?
      while j < a.count, let next = nodes[node].children[a[j]] {
        node = next; j += 1
        guard let index = nodes[node].word, !(j < a.count && Self.latin(a[j-1]) && Self.latin(a[j])) else { continue }
        let w = words[index]
        if w.name.count == j - i && w.name.lowercased().elementsEqual(a[i..<j]) { best = (j, w) }
      }
      if let (end, word) = best {
        if seen.insert(word.name).inserted { result.append(word) }
        i = end
      } else { i += 1 }
    }
    return result
  }
  func hints(recent: [String], personal: [Term], previous: [String] = []) -> [String] {
    var seen = Set<String>()
    let own = personal.prefix(12).map(\.spelling)
    // A first dictation also benefits; never submit the entire place-name table to the decoder.
    let previousText = String(WordContext.fresh(previous.first ?? "").suffix(240)).lowercased()
    var familiar = [String]()
    if !previousText.isEmpty {
      familiar = Array(exactWords(in: previousText, limit: 8).filter { $0.name.count >= 3 }.map(\.name))
      let topical = words.lazy.filter {
        $0.group.industry && $0.name.count >= 4 && !$0.variants.isEmpty
          && $0.cues.contains(where: previousText.contains)
      }.prefix(3).map(\.name)
      familiar += topical
    }
    return Array(
      (own + recent + familiar).filter {
        (2...32).contains($0.count) && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == " " }
          && seen.insert($0.lowercased()).inserted
      }.prefix(32))
  }
  static let spokenEdge = CharacterSet.whitespacesAndNewlines.union(
    CharacterSet(charactersIn: "，。！？、,.!?…"))
  func readingPeers(_ word: String) -> Set<String>? {
    guard enabled.contains(word), let peers = readings[word] else { return nil }
    let active = peers.intersection(enabled)
    return active.count > 1 ? active : nil
  }
  func crosses(_ left: String, _ right: String, space: String) -> Bool {
    SpeechLayout.spans(
      left, right, space: space, limit: 24, minLength: 3, next: { nodes[$0].children[$1] },
      isTerm: { nodes[$0].word != nil })
  }
  func checked(_ text: String, final: Bool, prior: [String: Int] = [:]) -> String {
    let paragraphs = text.components(separatedBy: "\n\n")
    return paragraphs.enumerated().map {
      checkParagraph($0.element, final: final, prior: $0.offset == 0 ? prior : [:])
    }.joined(separator: "\n\n")
  }
  private func checkParagraph(_ text: String, final: Bool, prior: [String: Int]) -> String {
    guard !nodes[0].children.isEmpty, !text.isEmpty else { return text }
    let chars = Array(text)
    let count = chars.count
    let fold = chars.map { $0.isASCII ? Character(String($0).lowercased()) : $0 }
    func sides(_ i: Int, _ end: Int) -> (String, String) {
      (String(chars[max(0, i - 28)..<i]), String(chars[end..<min(count, end + 28)]))
    }
    func safeWord(_ w: Word, _ raw: String, _ i: Int, _ end: Int) -> String {
      if w.group == .place || w.name == raw || preservesSpelling(raw, insteadOf: w.name) || bias.discourages(w.name) { return raw }
      let (left, right) = sides(i, end)
      if Self.identity(left, right) { return raw }
      let (localLeft, localRight) = WordContext.clipped(left, right)
      if w.flags.contains("k") {
        // 压低 is usually a verb. Only accept the brand before a vehicle + a characteristic predicate.
        if raw == "压低" {
          guard localLeft.trimmed.isEmpty || ["那辆", "这辆", "这台", "一辆", "我的", "买的", "我骑的"].contains(where: localLeft.hasSuffix),
            let vehicle = ["电动自行车", "电动车", "电瓶车", "电单车"].first(where: localRight.hasPrefix) else { return raw }
          let after = String(localRight.dropFirst(vehicle.count))
          guard ["需要充电", "没电了", "要充电", "续航", "充满电", "开不动", "骑起来", "能换电"].contains(where: after.hasPrefix) else { return raw }
        }
        if raw == "艾玛", !["电动车", "电单车", "电瓶车", "电动自行车"].contains(where: localRight.hasPrefix) { return raw }
        guard w.variants.contains(raw), !enabled.contains(raw),
          w.cues.contains(where: { localLeft.contains($0) || localRight.contains($0) }) else { return raw }
        return w.name
      }
      // Award-recipient homophones need the award immediately before and a noun boundary after.
      // A nearby award alone cannot turn 主办方、主题 or 主要 into a different expression.
      if w.flags.contains("r") {
        let next = String(right.drop(while: { $0.isWhitespace }))
        let boundary =
          next.isEmpty || next.first?.isPunctuation == true
          || ["是", "有", "将", "接受", "发表", "获邀", "出席", "表示", "名单", "之一", "们"].contains(
            where: next.hasPrefix)
        return boundary && w.cues.contains(where: localLeft.hasSuffix) ? w.name : raw
      }
      if w.name.hasPrefix("金秋"), raw.hasPrefix("进球") || raw.hasPrefix("金球"),
        ["比赛", "足球", "射门", "球队", "裁判", "球员", "点球", "球赛", "颁奖"].contains(where: {
          localLeft.contains($0) || localRight.contains($0)
        })
      {
        return raw
      }
      if raw.hasPrefix("今秋"), w.name.hasPrefix("金秋"),
        !["飘香", "桂花", "丰收", "硕果", "收获", "丹桂", "送爽"].contains(where: {
          localLeft.contains($0) || localRight.contains($0)
        })
      {
        return raw
      }
      if w.group == .code, raw == "携程",
        ["订票", "订房", "旅行", "平台", "公司", "酒店", "机票"].contains(where: {
          localLeft.contains($0) || localRight.contains($0)
        })
      {
        return raw
      }
      if w.group == .tech || w.group.industry, w.flags.contains("c"),
        w.name.caseInsensitiveCompare(raw) == .orderedSame
          || (raw.allSatisfy(\.isASCII)
            && raw.replacingOccurrences(of: " ", with: "").caseInsensitiveCompare(
              w.name.replacingOccurrences(of: " ", with: "")) == .orderedSame)
      {
        return w.name
      }
      if w.name.hasPrefix("金秋"),
        ["走", "闯", "迈", "扎", "开", "挺", "驶", "推进", "改"].contains(where: left.hasSuffix)
          || right.hasPrefix("陵")
      {
        return raw
      }
      let edge = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
      let solo =
        localLeft.trimmingCharacters(in: edge).isEmpty
        && localRight.trimmingCharacters(in: edge).isEmpty
      // Ordinary words need adjacent evidence. A recruiting discussion is not permission to change what somebody bought or wore.
      if raw.contains("衣服") {
        let cl = localLeft.trimmingCharacters(in: edge)
        let cr = localRight.trimmingCharacters(in: edge)
        guard
          ["报考", "报名", "参加", "备考", "招募", "了解", "报了", "报的是"].contains(where: cl.hasSuffix)
            || ["岗位", "招募", "考试", "报名", "计划", "项目"].contains(where: cr.hasPrefix)
        else { return raw }
        if ["买", "穿", "洗", "叠", "带了", "拿了", "挑", "件", "换"].contains(where: cl.suffix(5).contains) {
          return raw
        }
      }
      if w.cues.isEmpty
        || w.cues.contains(where: { localLeft.contains($0) || localRight.contains($0) })
      {
        return w.name
      }
      if final && w.group != .tech && !w.group.industry {
        if solo && w.flags.contains("s") { return w.name }
        if !raw.contains("衣服") {
          // Refer back to the immediately preceding clause only for an otherwise unrecognised form.
          let prev =
            WordContext.fresh(left).components(separatedBy: WordContext.stops).dropLast().last ?? ""
          if localLeft.trimmed.isEmpty, !enabled.contains(raw),
            w.cues.filter({ prev.contains($0) }).count >= 2
          {
            return w.name
          }
        }
      }
      return raw
    }
    // Only look up phonetic neighbours in a location slot. Require one changed character, equal
    // Mandarin syllable AND tone, the same administrative suffix, and a unique usable spelling.
    var sounds = [Character: String]()
    func sound(_ c: Character) -> String {
      if let result = sounds[c] { return result }
      let result = String(c).applyingTransform(.mandarinToLatin, reverse: false) ?? String(c)
      sounds[c] = result
      return result
    }
    // For distinctive names, allow unseen spellings with the same syllables only in the
    // right field. An exact entry, an identifier or an ordinary clothing phrase wins.
    func fromSound(at i: Int, longerThan exact: Int) -> (Int, String)? {
      guard final, let options = patterns[chars[i]] else { return nil }
      var candidates = Set<String>()
      var longest = 0
      for p in options {
        let n = p.letters.count
        let end = i + n
        guard n >= 4, end <= count, end > exact, n >= longest else { continue }
        let piece = chars[i..<end]
        let raw = String(piece)
        guard !geoForms.contains(raw), piece.allSatisfy(Self.han) else { continue }
        let delta = (0..<n).filter { p.letters[$0] != chars[i + $0] }
        guard !delta.isEmpty, delta.count <= n / 2 else { continue }
        let w = words[p.index]
        let (left, right) = sides(i, end)
        guard w.cues.contains(where: { left.contains($0) || right.contains($0) }),
          safeWord(w, raw, i, end) == w.name
        else { continue }
        let eq = delta.allSatisfy { j in
          sound(p.letters[j]).compare(sound(chars[i + j]), options: .diacriticInsensitive)
            == .orderedSame
        }
        guard eq else { continue }
        if n > longest {
          candidates.removeAll()
          longest = n
        }
        candidates.insert(w.name)
      }
      if candidates.count == 1, let name = candidates.first { return (i + longest, name) }
      return nil
    }
    let strong = [
      "前往", "飞往", "抵达", "来自", "住在", "迁往", "开往", "到达", "返回", "目的地是", "出发地是", "坐车到", "搬到", "位于",
    ]
    let rightCues = [
      "出差", "开会", "旅行", "旅游", "高铁站", "火车站", "机场", "市政府", "考察", "市区", "参会", "调研", "出发", "坐车", "的车票",
    ]
    func place(at i: Int) -> (Int, String)? {
      guard final, i > 0, Self.han(chars[i]), "去从到赴往达自在是至回于".contains(chars[i - 1]) else {
        return nil
      }
      let left = String(chars[max(0, i - 12)..<i])
      let guided = strong.contains(where: left.hasSuffix)
      guard guided || ["去", "从", "到", "赴", "在", "至", "回"].contains(where: left.hasSuffix) else {
        return nil
      }
      let len = chars[i..<min(count, i + 8)].prefix(while: Self.han).count
      guard len >= 2 else { return nil }
      for n in stride(from: len, through: 2, by: -1) {
        let end = i + n
        let fragment = Array(chars[i..<end])
        let raw = String(fragment)
        let right = String(chars[end..<min(count, end + 10)])
        let admin = "市县区省旗盟州".contains(fragment.last!)
        let qualified = rightCues.contains(where: right.hasPrefix)
        let closed =
          right.isEmpty
          || right.first.map { $0.isWhitespace || $0.isPunctuation || "的和到再".contains($0) } == true
        guard qualified || (admin || guided) && closed, !Self.identity(left, right) else {
          continue
        }
        if geoForms.contains(raw) { return (end, raw) }
        var matches = Set<String>()
        for j in fragment.indices where !admin || j < n - 1 {
          for candidate in nearPlaces[Self.signature(fragment, j)] ?? [] {
            let other = Array(candidate)[j]
            if other != fragment[j], sound(other) == sound(fragment[j]) {
              matches.insert(candidate)
            }
          }
        }
        if matches.count == 1, let match = matches.first, !bias.discourages(match) { return (end, match) }
      }
      return nil
    }
    var i = 0
    var result = ""
    while i < count {
      if let (end, replacement) = place(at: i) {
        result += replacement
        i = end
        continue
      }
      var at = i
      var node = 0
      var best: (Int, Int)?
      if !(i > 0 && Self.latin(chars[i]) && Self.latin(chars[i - 1])) {
        while at < count, let n = nodes[node].children[fold[at]] {
          at += 1
          node = n
          if let word = nodes[node].word,
            !(at < count && Self.latin(chars[at - 1]) && Self.latin(chars[at]))
          {
            best = (at, word)
          }
        }
      }
      if let (end, name) = graph.resolve(
        chars, at: i, minimum: best?.0 ?? i, enabled: enabled, prior: prior, final: final, bias: bias)
      {
        result += name
        i = end
        continue
      }
      if let (end, name) = fromSound(at: i, longerThan: best?.0 ?? i) {
        result += name
        i = end
        continue
      }
      if let hit=soundshelf.hit(chars,i,minimum:best?.0 ?? i,enabled:enabled,bias:bias,cache:&sounds, review:false), hit.automatic {
        result += hit.word; i=hit.end; continue
      }
      if let (end, idx) = best {
        result += safeWord(words[idx], String(chars[i..<end]), i, end)
        i = end
      } else {
        result.append(chars[i])
        i += 1
      }
    }
    return result
  }
}
