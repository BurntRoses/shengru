import Foundation

struct SpeechPart {
  var raw: String
  let pause: Double
  var heard: String? = nil
  var recoveredTail = 0

  // Only compare syllables that an extra acoustic pass *inserted*, never the first
  // decoder's own words. A deliberate repetition across a pause must survive intact.
  func overlap(with next: String, partial: Bool = false) -> Int {
    guard recoveredTail > 0, let last = raw.lastIndex(where: { $0.isLetter || $0.isNumber }) else { return 0 }
    let tail = raw[...last].suffix(recoveredTail)
    let head = next.drop(while: { $0.isPunctuation || $0.isWhitespace })
    guard !head.isEmpty else { return 0 }
    for n in (1...tail.count).reversed() where head.hasPrefix(tail.suffix(n)) { return n }
    // Do not momentarily display “李白李” while the next hypothesis still says only “李”.
    return partial && head.count < tail.count && tail.hasPrefix(head) ? tail.count : 0
  }
  static func withdrawing(_ n: Int, from text: String) -> String {
    guard n > 0, let last = text.lastIndex(where: { $0.isLetter || $0.isNumber }) else { return text }
    let end = text.index(after: last)
    return String(text[..<end].dropLast(n)) + text[end...]
  }
}

enum SpeechLayout {
  private static let terminal = "。！？.!?…：:；;", commas = "，,、"
  private static let topic = [
    "另外，", "另外,", "另一方面", "最后补充", "还有一件事", "再说一个", "接下来说", "换个话题", "再说一下", "至于", "除此之外",
  ]
  static func clauses(_ input: String, level: EditLevel) -> String {
    guard level != .literal else { return input }
    // Use explicit discourse markers, not character counts. A string such as “另外一个” stays intact.
    var s = input
    let turn = #"(?:另外[，,：:]|另一方面[，,：:]|还有一件事[，,：:]|最后补充[，,：:]|接下来[，,：:]|除此之外[，,：:])"#
    if ["另外", "另一方面", "还有一件事", "最后补充", "接下来", "除此之外"].contains(where: s.contains) {
      s = s.replacing(#"([\p{Han}\uE001]{6})(?="# + turn + ")", "$1。")
      s = s.replacing(#"(?<=[\p{Han}\uE001])[，,；;][ \t]*(?="# + turn + ")", "。")
      s = s.replacing(#"([。！？])[ \t]*(?="# + turn + ")", "$1\n\n")
    }
    // A comma before an independent subject can end a long run-on clause, not a noun list.
    if s.contains("，") {
      s = s.replacing(
        #"([\p{Han}\uE001]{12})，(?=我们(?:还要|已经|决定|计划)|我(?:还要|准备|打算)|大家(?:可以|需要)|这次(?:将|主要)|不过[，,])"#,
        "$1。")
    }
    if level == .outline && s.contains("第") {
      let label = #"第[一二三四五六七八九十]+(?:步|点|项)"#
      let instructions =
        #"(?=先|再|请|将|把|查|检|确|核|保|打|记|修|设|测|运|填|提|整|收|发|完|安|选|准|建|读|导|复|点|比|加|上|下|关)"#
      let marked = s.replacing("(" + label + ")" + instructions, "$1，")
      if marked.range(of: "第一(?:步|点|项)[，、：: ]", options: .regularExpression) != nil
        && marked.range(of: "第[二三四五六七八九十]+(?:步|点|项)[，、：: ]", options: .regularExpression) != nil
      {
        s = marked.replacing("([\\p{Han}\\uE001])(?=" + label + "[，、：: ])", "$1。")
      }
    }
    return s
  }
  private static func openLiteral(_ t: String) -> Bool {
    for (a, b): (Character, Character) in [("“", "”"), ("「", "」"), ("『", "』"), ("‘", "’"), ("《", "》")] {
      if let i = t.lastIndex(of: a), t.lastIndex(of: b).map({ $0 < i }) ?? true { return true }
    }
    return t.filter { $0 == "`" }.count % 2 != 0 || t.filter { $0 == "\"" }.count % 2 != 0
  }
  // Find a known term which starts before the decoder boundary and ends after it. Search only
  // the bounded edges, including an optional real space in multiword names.
  static func spans(
    _ left: String, _ right: String, space: String, limit: Int, minLength: Int,
    next: (Int, Character) -> Int?, isTerm: (Int) -> Bool
  ) -> Bool {
    let a = Array(left.suffix(limit).lowercased())
    let b = Array(right.prefix(limit).lowercased())
    guard !a.isEmpty && !b.isEmpty else { return false }
    let chars = a + Array(space) + b
    let pivot = a.count + space.count
    func latin(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber || c == "_") }
    for start in a.indices.reversed() {
      if start > 0 && latin(a[start]) && latin(a[start - 1]) { continue }
      var n = 0
      var i = start
      while i < min(chars.count, start + limit), let node = next(n, chars[i]) {
        i += 1
        n = node
        if i > pivot, i - start >= minLength, isTerm(n),
          !(i < chars.count && latin(chars[i - 1]) && latin(chars[i]))
        {
          return true
        }
      }
    }
    return false
  }
  static func append(
    _ a: String, _ part: SpeechPart, level: EditLevel, wordGap: ((String, String) -> String?)? = nil
  ) -> String {
    let b = part.raw.trimmed
    guard !b.isEmpty, let first = b.first else { return a }
    guard let last = a.last else { return b }
    if (terminal + commas).contains(first) {
      return a + (first == last ? String(b.dropFirst()) : b)
    }
    if part.pause >= 0.7 || last.isASCII && first.isASCII, let gap = wordGap?(a, b) {
      return a + gap + b
    }
    let head = String(b.prefix(20))
    let tail = String(a.suffix(112))
    let chinese =
      (String(tail.suffix(16)) + String(head.prefix(16))).range(
        of: #"\p{Han}"#, options: .regularExpression) != nil
    let newTopic = level != .literal && topic.contains(where: head.hasPrefix)
    guard part.pause >= 0.7 || newTopic else { return Transcript.join(a, b) }
    let hanging = [
      "因为", "如果", "为了", "比如", "以及", "然后把", "我们在", "前往", "百分之", "也就是", "一共是", "分别是", "我想说", "我的",
      "我们要", "分为", "叫作", "叫做",
    ].contains(where: tail.hasSuffix)
    let dependent = ["的", "和", "以及", "或者", "而且", "毫秒", "千克", "公里", "分钟", "个百分点"].contains(
      where: head.hasPrefix)
    let quantity =
      "0123456789一二三四五六七八九十百千万两零".contains(last)
      && (first.isNumber || "个点分秒年月日元米克人次章".contains(first))
    if hanging || dependent || quantity || openLiteral(tail) { return Transcript.join(a, b) }
    let strong = part.pause >= 1.75 || newTopic
    let closed = terminal.contains(last)
    let breaks = newTopic || (strong && tail.count >= (chinese ? 7 : 22))
    let lastClause = tail.reversed().prefix { !(terminal + commas).contains($0) }.count
    let sentence = strong || lastClause >= (chinese ? 8 : 28)
    let period = chinese ? (["吗", "么", "怎么办"].contains(where: tail.hasSuffix) ? "？" : "。") : "."
    var previous = a
    if !closed {
      if commas.contains(last) {
        if strong {
          previous.removeLast()
          previous += period
        }
      } else {
        previous += sentence ? period : (chinese ? "，" : ",")
      }
    }
    return previous + (breaks ? "\n\n" : chinese ? "" : " ") + b
  }
}

// The first hearing stays immutable; only a replay-added tail is provisional at a boundary.
// Final proofreading starts from the parts, never from the painted preview.
final class LiveComposition {
  let level: EditLevel, index: Transcript.WordIndex, vocabulary: BuiltinVocabulary
  let shield: WordBias
  private(set) var liveEdit:ProofMark?
  private(set) var parts: [SpeechPart] = []
  private var ink = "", working = "", lastRaw: SpeechPart?, lastPaint = ""
  init(
    level: EditLevel, terms: [Term], vocabulary: BuiltinVocabulary, learned: [Term] = [],
    previous: [String] = [], shield: WordBias = WordBias([]), hanAlphabet: Set<Character>? = nil
  ) {
    self.shield = shield
    self.level = level
    index = Transcript.WordIndex(
      terms.map { t in shield.discourages(t.spelling) ? Term(spelling:t.spelling, spoken:t.spelling) : t }, learned: learned.filter { !shield.discourages($0.spelling) }, graph: vocabulary.graph, prior: vocabulary.graph.preceding(previous), previousLine: previous.first ?? "", hanAlphabet: hanAlphabet)
    self.vocabulary = vocabulary
  }
  private var committedContext = ""
  var priorClause: String { committedContext.isEmpty ? index.previousLine : committedContext }
  private func wordGap(_ left: String, _ right: String) -> String? {
    let choices = left.last?.isASCII == true && right.first?.isASCII == true ? [" ", ""] : [""]
    for gap in choices {
      if !index.exact.isEmpty
        && SpeechLayout.spans(
          left, right, space: gap, limit: 96, minLength: 2,
          next: { index.nodes[$0].edges[String($1)] }, isTerm: { index.nodes[$0].value != nil })
      {
        return gap
      }
      if vocabulary.crosses(left, right, space: gap) {
        return gap
      }
    }
    return nil
  }
  func push(_ raw: String, pause: Double, commit: Bool, heard: String? = nil, recoveredTail: Int = 0) -> (String, String) {
    let p = SpeechPart(raw: raw, pause: pause, heard: heard, recoveredTail: recoveredTail)
    if !commit, let lastRaw, lastRaw.raw == raw, lastRaw.pause == pause {
      return (ink + lastPaint, "")
    }
    let overlap = parts.last?.overlap(with: heard ?? raw, partial: !commit) ?? 0
    let next = SpeechLayout.append(SpeechPart.withdrawing(overlap, from: working), p, level: level, wordGap: wordGap)
    liveEdit=nil
    let painted = Transcript.render(
      next, level: level, index: index, vocabulary: vocabulary, final: false) { before,after in self.liveEdit=ProofMark.latest(before,after) }
    if let heard,liveEdit==nil { liveEdit=ProofMark.change(heard,raw) }
    if commit {
      if !raw.isEmpty {
        if overlap > 0 { parts[parts.count - 1].raw = SpeechPart.withdrawing(overlap, from: parts[parts.count - 1].raw) }
        parts.append(p)
        working = next
        committedContext = String(painted.suffix(96))
      }
      lastRaw = nil
      lastPaint = painted
      // Seal complete text at existing paragraph/sentence boundaries; never invent a paragraph to fit a window.
      let kept = (parts.last?.recoveredTail ?? 0) > 0 ? parts.last?.raw.count ?? 0 : 0
      let sealable = working.dropLast(kept)
      if working.count > 700, let split = sealable.range(of: "\n\n", options: .backwards) {
        ink +=
          Transcript.render(
            String(working[..<split.lowerBound]), level: level, index: index,
            vocabulary: vocabulary, final: false) + "\n\n"
        working = String(working[split.upperBound...])
        lastPaint = Transcript.render(
          working, level: level, index: index, vocabulary: vocabulary, final: false)
      } else if working.count > 1000 && level != .outline,
        let end = sealable.lastIndex(where: { "。！？".contains($0) }),
        working.distance(from: working.startIndex, to: end) > 500
      {
        let bound = working.index(after: end)
        ink += Transcript.render(
          String(working[..<bound]), level: level, index: index,
          vocabulary: vocabulary,
          final: false)
        working = String(working[bound...])
        lastPaint = Transcript.render(
          working, level: level, index: index, vocabulary: vocabulary, final: false)
      }
      return (ink + lastPaint, "")
    }
    var settled = painted.commonPrefix(with: lastPaint, options: .literal)
    if painted.dropFirst(settled.count).first.map({ $0.isASCII && $0.isLetter }) == true {
      while settled.last.map({ $0.isASCII && $0.isLetter }) == true { settled.removeLast() }
    }
    lastPaint = painted
    lastRaw = p
    return (ink + settled, String(painted.dropFirst(settled.count)))
  }
  func finish(_ raw: String, pause: Double, heard:String?=nil, reread: (() -> [String])? = nil) -> (
    raw: String, final: String, choices: [ReadingChoice]
  ) {
    var complete = parts
    if !raw.trimmed.isEmpty {
      if let last = complete.last {
        let n = last.overlap(with: heard ?? raw)
        if n > 0 { complete[complete.count - 1].raw = SpeechPart.withdrawing(n, from: last.raw) }
      }
      complete.append(SpeechPart(raw: raw, pause: pause, heard: heard))
    }
    var original=""
    for part in complete { let phrase=part.heard ?? part.raw; if let c=original.last { let edge=String(c); original += Transcript.join(edge,phrase).dropFirst() } else { original += phrase } }
    let laidOut = complete.reduce("") {
      SpeechLayout.append($0, $1, level: level, wordGap: wordGap)
    }
    var source = laidOut
    var choices = [ReadingChoice]()
    let edge = BuiltinVocabulary.spokenEdge
    let bare = original.trimmingCharacters(in: edge)
    if let reread, let peers = vocabulary.readingPeers(bare), index.exact[bare] == nil {
      let votes = reread().map { $0.trimmingCharacters(in: edge) }
      if votes.count == 2, let v = votes.first, v != bare, votes.last == v, peers.contains(v), !shield.discourages(v),
        let r = source.range(of: bare)
      {
        source.replaceSubrange(r, with: v)
      } else {
        choices = peers.subtracting([bare]).sorted {
          (votes.contains($0) ? 0 : 1, $0) < (votes.contains($1) ? 0 : 1, $1)
        }.map { ReadingChoice(heard: bare, word: $0) }
      }
    }
    var final = Transcript.render(source, level: level, index: index, vocabulary: vocabulary, final: true, decoderLayout: true)
    if choices.isEmpty, vocabulary.readingPeers(bare) == nil {
      choices = Transcript.alternatives(
        in: final, original: original, index: index, vocabulary: vocabulary)
      // Neutral replays may change this one span only; both must agree on the full phrase.
      // Otherwise keep the first reading and offer the word, not a rewritten sentence.
      if let reread, !choices.isEmpty {
        func normalized(_ s: String) -> String {
          s.components(separatedBy: BuiltinVocabulary.spokenEdge).joined()
        }
        let votes = reread().map(normalized)
        if votes.count == 2, votes[0] == votes[1],
          let edit = choices.first(where: { !shield.discourages($0.word) && $0.applying(to: original).map(normalized) == votes[0] }
          ), let fresh = edit.applying(to: final)
        {
          final = fresh
          choices.removeAll { $0.applying(to: fresh) == nil }
        }
      }
    }
    return (
      original, final,
      choices.filter { !shield.discourages($0.word) }
    )
  }
}
