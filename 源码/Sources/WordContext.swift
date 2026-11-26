import Foundation
import NaturalLanguage

struct ReadingChoice: Hashable, Identifiable, Codable {
  let heard: String, word: String
  var left:String = "", right:String = ""
  var id: Self { self }
  func range(in text: String) -> Range<String.Index>? {
    guard !heard.isEmpty, heard != word else { return nil }; var matches=[Range<String.Index>](), pos=text.startIndex
    while pos<text.endIndex, let r=text[pos...].range(of:heard) {
      if (left.isEmpty || text[..<r.lowerBound].hasSuffix(left)) && (right.isEmpty || text[r.upperBound...].hasPrefix(right)) { matches.append(r); if matches.count>1 { return nil } }; pos=r.upperBound
    }
    return matches.first
  }
  func applying(to text:String) -> String? {
    range(in:text).map {text.replacingCharacters(in:$0,with:word)}
  }

}

// A token is evidence for keeping the decoder's spelling, not a dictionary verdict.
// Build the boundary map only when a candidate would actually change some Han characters.
struct SourceLexemes {
  enum Risk { case fragment, word, none }
  private let chars: [Character]
  private var tokens: [Int:Range<Int>] = [:]
  private var standalone = [String:Bool]()
  init(_ text:String, chars:[Character]) {
    self.chars=chars
    let tokenizer=NLTokenizer(unit:.word); tokenizer.string=text; tokenizer.setLanguage(.simplifiedChinese)
    var last=text.startIndex, offset=0
    tokenizer.enumerateTokens(in:text.startIndex..<text.endIndex) { range,_ in
      offset += text.distance(from:last,to:range.lowerBound)
      let n=text.distance(from:range.lowerBound,to:range.upperBound), band=offset..<(offset+n)
      if n>=2, text[range].allSatisfy(SoundShelf.han) { for k in band { tokens[k]=band } }
      offset += n; last=range.upperBound; return true
    }
  }
  mutating func risk(_ span:Range<Int>, replacingWith spelling:String)->Risk {
    let new=Array(spelling), sameLength=new.count==span.count
    var intact=false
    for k in span where !sameLength || chars[k] != new[k-span.lowerBound] {
      guard let token=tokens[k] else { continue }
      if token.lowerBound<span.lowerBound || token.upperBound>span.upperBound { return .fragment }
      // Segmentation can group a new name after a verb by position alone. Count it as
      // an existing word only if it also forms a single token in isolation.
      let word=String(chars[token]); if standalone[word] == nil {
        let t=NLTokenizer(unit:.word); t.string=word; t.setLanguage(.simplifiedChinese)
        standalone[word] = t.tokenRange(at:word.startIndex) == word.startIndex..<word.endIndex
      }; if standalone[word] == true { intact=true }
    }
    return intact ? .word : .none
  }
}

// A sparse, local association graph. It ranks spellings of an observed sound, never invents a word.
struct WordContext {
  struct Sense {
    let family: String, word: String, topic: String, left: [String], right: [String],
      clues: [String]
  }
  var topics = [String: [String]](), families = [String: [Sense]](), forms = [String: String]()
  private var lengths = [Character: [Int]]()
  struct Review {
    let heard: String, alternatives: [String], require: [String], avoid: [String], includeNeighbor: Bool
    // Only an explicitly scoped review suggestion may consult one clause across a comma.
    // Do not carry evidence through a quotation, topic change, or sentence boundary.
    func context(left: String, right: String) -> String {
      let (l, r) = WordContext.clipped(left, right)
      guard includeNeighbor else { return l + heard + r }
      let comma = CharacterSet(charactersIn: "，,"), stop = WordContext.stops.subtracting(comma)
        .union(CharacterSet(charactersIn: ".…：:《》“”「」"))
      let before = WordContext.fresh(left).components(separatedBy: stop).last ?? ""
      var after = right.components(separatedBy: stop).first ?? ""
      if let end = WordContext.shifts.compactMap({ after.range(of: $0)?.lowerBound }).min() { after = String(after[..<end]) }
      return before.components(separatedBy: comma).suffix(2).joined(separator: "，") + heard
        + after.components(separatedBy: comma).prefix(2).joined(separator: "，")
    }
  }
  private(set) var review = [Review]()
  private var byReading = [String:[Review]]()
  init(topics rows: [[String]], senses: [[String]], review candidates: [[String]] = []) {
    func parts(_ s: String) -> [String] { s.split(separator: "|").map(String.init) }
    for r in candidates where r.count == 4 || (r.count == 5 && r[4] == "邻句") {
      review.append(
        Review(heard: r[0], alternatives: parts(r[1]), require: parts(r[2]), avoid: parts(r[3]), includeNeighbor: r.count == 5))
    }
    byReading = Dictionary(grouping:review,by: \.heard)
    for r in rows where r.count == 2 { topics[r[0]] = parts(r[1]) }
    for r in senses where r.count == 7 {
      families[r[0], default: []].append(
        Sense(
          family: r[0], word: r[1], topic: r[2], left: parts(r[4]), right: parts(r[5]),
          clues: parts(r[6])))
      for s in [r[1]] + parts(r[3]) where !s.isEmpty {
        forms[s] = r[0]
        if !lengths[s.first!, default: []].contains(s.count) {
          lengths[s.first!, default: []].append(s.count)
        }
      }
    }
    for k in Array(lengths.keys) { lengths[k]?.sort(by: >) }
  }
  static let stops = CharacterSet(charactersIn: "，。！？；,!?;.：:《》“”「」\n\u{e000}\u{e001}")
  static let shifts = [
    "换个话题", "换一个话题", "换个问题", "说回", "说到另一件事", "不说这个了", "另一个话题", "另外一件事", "另外说", "题外话", "接下来说", "转到", "再说说", "话说回来",
  ]
  static func fresh(_ s: String) -> String {
    let bounds = shifts.compactMap { s.range(of: $0, options: .backwards)?.upperBound }
    return bounds.max().map { String(s[$0...]) } ?? s
  }
  static func clipped(_ left: String, _ right: String) -> (String, String) {
    let l = fresh(left).components(separatedBy: stops).last ?? ""
    let r = right.components(separatedBy: stops).first ?? ""
    let end = shifts.compactMap { r.range(of: $0)?.lowerBound }.min() ?? r.endIndex
    return (String(l.suffix(28)), String(r[..<end].prefix(28)))
  }
  // Look across exactly one pause in each direction. Never traverse a paragraph, a
  // quoted/literal token or a spoken change of subject to vote on a spelling.
  private static func neighbours(_ left: String, _ right: String) -> (String, String) {
    let wall = CharacterSet(charactersIn: "\n\r\u{e000}\u{e001}《》“”‘’「」『』：:；;")
    let pause = CharacterSet(charactersIn: "，,。.!！?？、")
    let l = fresh(left).components(separatedBy: wall).last ?? ""
    var r = right.components(separatedBy: wall).first ?? ""
    if let end = shifts.compactMap({ r.range(of: $0)?.lowerBound }).min() { r = String(r[..<end]) }
    return (l.components(separatedBy: pause).dropLast().last ?? "", r.components(separatedBy: pause).dropFirst().first ?? "")
  }
  func weights(_ text: String) -> [String: Int] {
    guard !text.isEmpty else { return [:] }
    var out = [String: Int]()
    for (name, cues) in topics {
      let n = cues.reduce(0) { $0 + (text.contains($1) ? 1 : 0) }
      if n > 0 { out[name] = min(3, n) }
    }
    return out
  }
  func preceding(_ turns: [String]) -> [String: Int] {
    // Only the last topical turn may carry forward. A topic change cannot resurrect older evidence.
    guard let newest = turns.first else { return [:] }
    let clause = Self.fresh(String(newest.suffix(180))).components(separatedBy: Self.stops).filter {
      !$0.trimmed.isEmpty
    }
    return clause.last.map(weights) ?? [:]
  }
  func conflicts(_ heard:String, proposed:String, left:String, right:String)->Bool {
    (byReading[heard] ?? []).contains { rule in
      guard rule.alternatives.contains(proposed), !rule.avoid.isEmpty else {return false}
      let context=rule.context(left:left,right:right)
      return rule.avoid.contains(where:context.contains)
    }
  }
  func allowsMemory(_ term: Term, left: String, right: String) -> Bool {
    let (l, r) = Self.clipped(left, right)
    if conflicts(term.spoken,proposed:term.spelling,left:left,right:right) { return false }
    guard let family = forms[term.spoken], let group = families[family] else { return true }
    if let first = term.spoken.first,
      (lengths[first] ?? []).contains(where: { width in
        width > term.spoken.count
          && forms[term.spoken + String(r.prefix(width - term.spoken.count))].map({ $0 != family })
            == true
      })
    {
      return false
    }
    return !group.contains { s in
      s.word != term.spelling
        && (s.left.contains(where: l.hasSuffix) || s.right.contains(where: r.hasPrefix))
    }
  }
  func resolve(
    _ a: [Character], at i: Int, minimum: Int, enabled: Set<String>, prior: [String: Int],
    final: Bool, bias: WordBias = WordBias([])
  ) -> (Int, String)? {
    guard let widths = lengths[a[i]] else { return nil }
    for n in widths where i + n <= a.count && i + n >= minimum {
      let end = i + n
      let raw = String(a[i..<end])
      guard let f = forms[raw], let senses = families[f] else { continue }
      let before = String(a[max(0, i - 96)..<i])
      let after = String(a[end..<min(a.count, end + 40)])
      let (l, r) = Self.clipped(before, after)
      if senses.contains(where: { $0.word == raw && !enabled.contains(raw) })
        || BuiltinVocabulary.identity(before, after) {
        return (end, raw)
      }
      let local = weights(l + " " + r)
      let changed = Self.shifts.contains(where: before.contains)
      // A nearby previous clause outranks another dictation. Cross-turn clues only break a tie
      // for a deictic follow-up or a nonword; they cannot overrule an ordinary standalone word.
      let canonical = senses.contains { $0.word == raw }
      let continuation =
        ["这次", "刚才", "刚说的", "这一个", "那次", "这个", "那个", "这粒", "那粒", "这项", "那项", "它", "那颗"].contains(
          where: l.contains) || ["呢", "怎么样", "怎么说"].contains(where: r.hasPrefix)
      let neighbours = final ? Self.neighbours(before, after) : ("", "")
      let earlier = weights(neighbours.0), later = weights(neighbours.1)
      let canInherit = !changed && neighbours.0.isEmpty && before.rangeOfCharacter(from: Self.stops) == nil
      let inherited = !neighbours.0.isEmpty ? earlier : (canInherit ? prior : [:])
      let relevant = Set(senses.map(\.topic))
      func unique(_ t: String, in scores: [String:Int]) -> Bool {
        let value = scores[t] ?? 0
        return value > 0 && !relevant.contains(where: { $0 != t && (scores[$0] ?? 0) >= value })
      }
      var ranked = [(String, Int)]()
      for s in senses where enabled.contains(s.word) && !conflicts(raw,proposed:s.word,left:before,right:after) {
        let direct = s.left.contains(where: { l.hasSuffix($0) || l.hasSuffix($0 + "了") }) || s.right.contains(where: r.hasPrefix)
        let nearby = s.clues.filter { l.contains($0) || r.contains($0) }.count
        if canonical, s.word != raw, !direct, nearby < 2 { continue }
        var score = (direct ? 8 : 0) + min(5, nearby * 3) + min(4, (local[s.topic] ?? 0) * 2)
        if final, local.isEmpty,
          continuation || (!neighbours.0.isEmpty && !canonical && l.trimmed.isEmpty && r.trimmed.isEmpty),
          let weight = inherited[s.topic],
          !relevant.contains(where: { $0 != s.topic && (later[$0] ?? 0) > 0 }),
          !inherited.keys.contains(where: { $0 != s.topic && (inherited[$0] ?? 0) >= weight })
        {
          score += weight >= 2 ? 5 : 3
        }
        if final, !canonical || continuation, !relevant.contains(where: { $0 != s.topic && (local[$0] ?? 0) > 0 }),
          !relevant.contains(where: { $0 != s.topic && ((earlier[$0] ?? 0) > 0 || (later[$0] ?? 0) > 0) }),
          unique(s.topic, in: earlier) || unique(s.topic, in: later) {
          let support = min(3, (earlier[s.topic] ?? 0) + (later[s.topic] ?? 0))
          // Two local clues can resolve even a plausible ordinary word, but only in an
          // explicit follow-up. One mention in a different sentence cannot do that.
          let neighbouring = support >= 2 ? (canonical ? 6 : 5) : 2
          let lexical = (direct ? 8 : 0) + min(5, nearby * 3) + min(4, (local[s.topic] ?? 0) * 2)
          score = max(score, lexical + neighbouring)
        }
        if raw == s.word { score += 2 }
        // A direct collocation can still outweigh the preference; a list entry alone is never evidence.
        if bias.discourages(s.word) { score -= direct && raw == s.word ? 2 : 8 }; ranked.append((s.word, score))
      }
      ranked.sort { $0.1 > $1.1 }
      guard let top = ranked.first, top.0 != raw, top.1 >= 5,
        top.1 - (ranked.dropFirst().first?.1 ?? 0) >= 3
      else { return (end, raw) }
      return (end, top.0)
    }
    return nil
  }
}

// Keep a handful of local word cues per distinct, manually edited take. A legacy
// confirmation count cannot establish whether two edits came from different recordings.
struct MemoryScope: Codable, Equatable {
  struct Observation: Codable, Equatable { let record: UUID, topics: [String], anchors: [String] }
  var topics: [String], anchors: [String], observations: [Observation]? = nil
  static let minimumTakes = 2
  static let weak: Set<String> = [
    "一个", "这个", "那个", "我们", "你们", "他们", "这里", "那里", "刚才", "今天", "现在", "说的", "已经", "可以", "的是", "就是",
    "还是", "因为", "所以", "然后", "的是", "what", "that", "the", "and", "with", "this", "有了", "这次", "需要",
    "应该", "可能",
  ]
  static func make(left: String, right: String, graph: WordContext) -> Self {
    let (l, r) = WordContext.clipped(left, right)
    let s = String(l.suffix(15)) + " " + String(r.prefix(15))
    let scores = graph.weights(s)
    let tokenizer = NLTokenizer(unit: .word)
    tokenizer.string = s
    tokenizer.setLanguage(.simplifiedChinese)
    var anchors = [String]()
    tokenizer.enumerateTokens(in: s.startIndex..<s.endIndex) { range, _ in
      let t = s[range].lowercased()
      if (2...18).contains(t.count), t.allSatisfy(\.isLetter), !weak.contains(t), !WordCapture.isCommon(t),
        !anchors.contains(t)
      {
        anchors.append(t)
      }
      return true
    }
    return Self(
      topics: scores.keys.filter { scores[$0] == scores.values.max() }.sorted(),
      anchors: Array(anchors.prefix(6)))
  }
  func support(in local: Self, standalone: Bool) -> (takes: Int, offer: Bool) {
    let cues = Set(local.anchors), areas = Set(local.topics)
    func matches(_ topics: [String], _ anchors: [String]) -> Bool {
      !cues.isDisjoint(with: anchors) && (topics.isEmpty || areas.isEmpty || !areas.isDisjoint(with: topics))
    }
    let hits = (observations ?? []).filter { matches($0.topics, $0.anchors) }
    let count = Set(hits.map(\.record)).count
    return (count, count > 0 || standalone || (observations == nil && matches(topics, anchors)))
  }
  var label: String {
    let tags = topics.isEmpty ? Array(anchors.prefix(3)) : topics
    guard !tags.isEmpty, (observations?.count ?? 0) >= Self.minimumTakes else { return "仅作备选" }
    return tags.joined(separator: "、")
  }
}
