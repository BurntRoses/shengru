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
  var review = [Review]()
  init(topics rows: [[String]], senses: [[String]], review candidates: [[String]] = []) {
    func parts(_ s: String) -> [String] { s.split(separator: "|").map(String.init) }
    for r in candidates where r.count == 4 || (r.count == 5 && r[4] == "邻句") {
      review.append(
        Review(heard: r[0], alternatives: parts(r[1]), require: parts(r[2]), avoid: parts(r[3]), includeNeighbor: r.count == 5))
    }
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
  static let stops = CharacterSet(charactersIn: "，。！？；,!?;\n\u{e000}\u{e001}")
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
  func allowsMemory(_ term: Term, left: String, right: String) -> Bool {
    let (l, r) = Self.clipped(left, right)
    // A confirmed change to 晶球 is not permission to change 水晶球, even in the same room.
    for rule in review where rule.heard == term.spoken && rule.alternatives.contains(term.spelling)
    {
      let phrase = rule.context(left:left,right:right)
      if rule.avoid.contains(where: phrase.contains) { return false }
    }
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
        || BuiltinVocabulary.identity(before, after)
        || (raw == "进球奖"
          && ["最佳", "最好", "漂亮", "精彩", "年度最佳", "最多", "最快", "最美"].contains(where: l.hasSuffix))
        || (f == "秋与球"
          && (r.hasPrefix("奖") || r.hasPrefix("陵")
            || ["走", "闯", "开", "驶", "迈", "挺"].contains(where: l.hasSuffix)))
      {
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
      for s in senses where enabled.contains(s.word) {
        let direct = s.left.contains(where: { l.hasSuffix($0) || l.hasSuffix($0 + "了") }) || s.right.contains(where: r.hasPrefix)
        let nearby = s.clues.filter { l.contains($0) || r.contains($0) }.count
        var score = (direct ? 8 : 0) + min(5, nearby * 3) + min(4, (local[s.topic] ?? 0) * 2)
        if final, local.isEmpty,
          continuation || (!canonical && l.trimmed.isEmpty && r.trimmed.isEmpty),
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

// Only compact topic labels and neighbouring vocabulary are persisted, not sentences or app content.
struct MemoryScope: Codable, Equatable {
  var topics: [String], anchors: [String], confirmations: Int
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
      if (2...18).contains(t.count), t.allSatisfy(\.isLetter), !weak.contains(t),
        !anchors.contains(t)
      {
        anchors.append(t)
      }
      return true
    }
    return Self(
      topics: scores.keys.filter { scores[$0] == scores.values.max() }.sorted(),
      anchors: Array(anchors.prefix(6)), confirmations: 1)
  }
  func score(left: String, right: String, graph: WordContext, prior: [String: Int]) -> Int {
    let (l, r) = WordContext.clipped(left, right)
    let text = (l + " " + r).lowercased()
    let scores = graph.weights(text)
    let hit = topics.compactMap { scores[$0] }.max() ?? 0
    let local = anchors.filter { text.contains($0) }.count
    if !topics.isEmpty, !scores.isEmpty, hit == 0 { return 0 }
    if hit > 0 || local > 0 {
      return 5 + min(6, hit * 2 + local * 2) + min(2, max(0, confirmations - 1))
    }
    if scores.isEmpty, !WordContext.shifts.contains(where: left.contains),
      ["刚才", "这次", "那个", "这个"].contains(where: l.contains),
      topics.contains(where: { (prior[$0] ?? 0) >= 2 })
    {
      return 5
    }
    return topics.isEmpty && anchors.isEmpty && text.trimmed.isEmpty ? 5 : 0
  }
  var label: String {
    let tags = topics.isEmpty ? Array(anchors.prefix(3)) : topics
    return tags.isEmpty ? "单独说出时" : tags.joined(separator: "、")
  }
}
