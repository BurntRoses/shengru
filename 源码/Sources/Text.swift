import Foundation

enum EditLevel: String, Codable, CaseIterable, Identifiable {
  case literal = "原样记录"
  case natural = "自然表达"
  case concise = "去繁就简"
  case outline = "分段整理"
  var id: Self { self }
  // Raw values are the on-disk names in both settings and saved dictations.
  var title: String {
    switch self {
    case .literal: return "原样记录"
    case .natural: return "轻度整理"
    case .concise: return "精简口语"
    case .outline: return "分点整理"
    }
  }
  var detail: String {
    switch self {
    case .literal: return "保留语气词、重复和改口。"
    case .natural: return "去掉卡顿和无意的重复。"
    case .concise: return "再去掉“我的意思就是说”这类套话。"
    case .outline: return "精简口语，按说出的步骤或要点分段。"
    }
  }
}
struct Term: Codable, Identifiable, Equatable {
  var id = UUID()
  var spelling: String
  var spoken: String
  var pack: String? = nil
  var scope: MemoryScope? = nil
  var imported: Bool? = nil
}
extension String {
  func replacing(_ pattern: String, _ template: String) -> String {
    (try? NSRegularExpression(pattern: pattern))?.stringByReplacingMatches(
      in: self, range: NSRange(startIndex..., in: self), withTemplate: template) ?? self
  }
  func mapping(_ pattern: String, _ body: ([String]) -> String) -> String {
    guard let re = try? NSRegularExpression(pattern: pattern) else { return self }
    let ns = self as NSString
    var text = self
    for m in re.matches(in: self, range: NSRange(location: 0, length: ns.length)).reversed() {
      let values = (0..<m.numberOfRanges).map {
        m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0))
      }
      text = (text as NSString).replacingCharacters(in: m.range, with: body(values))
    }
    return text
  }
  var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
enum Transcript {
  static func join(_ a: String, _ b: String) -> String {
    guard let end = a.last, let start = b.first else { return a + b }
    let gap =
      end.isASCII && start.isASCII && (end.isLetter || end.isNumber || ".!?".contains(end))
      && (start.isLetter || start.isNumber)
    return a + (gap ? " " : "") + b
  }

  private static let digits: [Character: Int] = [
    "零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9,
  ]
  private static let cn = "[零〇一二两三四五六七八九十百千万亿]{1,16}"
  private static func serial(_ text: String) -> String? {
    let chars = text.compactMap { digits[$0].map(String.init) }
    return !chars.isEmpty && chars.count == text.count ? chars.joined() : nil
  }
  // Interpret only unambiguous quantities. Keep 一百二、三五百、两三 intact.
  private static func quantity(_ text: String) -> String? {
    if text.range(of: #"^[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil { return text }
    let parts = text.components(separatedBy: "点")
    guard parts.count <= 2, let whole = integer(parts[0]) else { return nil }
    if parts.count == 2 {
      guard let fraction = serial(parts[1]) else { return nil }
      return "\(whole).\(fraction)"
    }
    return String(whole)
  }
  private static func integer(_ text: String) -> Int64? {
    guard !text.isEmpty else { return nil }
    if text.count > 1, text.hasPrefix("零") || text.hasPrefix("〇") {
      return integer(String(text.dropFirst()))
    }
    if let d = serial(text) { return d.count == 1 ? Int64(d) : nil }
    for (unit, factor): (Character, Int64) in [("亿", 100_000_000), ("万", 10_000)] {
      if let i = text.firstIndex(of: unit) {
        let after = String(text[text.index(after: i)...])
        guard !after.contains(unit), let high = integer(String(text[..<i])), high > 0,
          high <= (Int64.max - factor) / factor
        else { return nil }
        if after.isEmpty { return high * factor }
        if after.count == 1 { return nil }
        guard let low = integer(after), low < factor else { return nil }
        return high * factor + low
      }
    }
    var result: Int64 = 0
    var pending: Int64?
    var previous: Int64 = 10000
    var zero = false
    let units: [Character: Int64] = ["千": 1000, "百": 100, "十": 10]
    for ch in text {
      if let d = digits[ch] {
        if d == 0 {
          guard pending == nil else { return nil }
          zero = true
          continue
        }
        guard pending == nil else { return nil }
        pending = Int64(d)
      } else if let u = units[ch] {
        guard u < previous, pending != nil || (result == 0 && u == 10) else { return nil }
        result += (pending ?? 1) * u
        previous = u
        pending = nil
        zero = false
      } else {
        return nil
      }
    }
    if pending != nil && previous > 10 && !zero { return nil }
    return result + (pending ?? 0)
  }
  static func numbers(_ text: String) -> String {
    let n = "(?:\(cn)(?:点[零〇一二三四五六七八九]+)?|[0-9]+(?:\\.[0-9]+)?)"
    var s = text.mapping("(负?)百分之(负?)(\(n))") { m in
      guard let v = quantity(m[3]) else { return m[0] }
      return (m[1].isEmpty && m[2].isEmpty ? "" : "−") + v + "%"
    }
    s = s.mapping("([零〇一二三四五六七八九]{4})(?=年)") { serial($0[1]) ?? $0[0] }
    s = s.mapping("(\(cn))月(\(cn))([日号])") { m in
      guard let a = integer(m[1]), (1...12).contains(a), let b = integer(m[2]), (1...31).contains(b)
      else { return m[0] }
      return "\(a)月\(b)\(m[3])"
    }
    s = s.mapping("(凌晨|早上|上午|中午|下午|晚上)([一二两三四五六七八九十]{1,3})点(半|一刻|三刻|[零一二三四五六七八九十]{1,3}分)?") { m in
      guard let h = integer(m[2]), (0...23).contains(h) else { return m[0] }
      if m[3].isEmpty { return m[1] + String(h) + "点" }
      let minute =
        ["半": 30, "一刻": 15, "三刻": 45][m[3]] ?? integer(String(m[3].dropLast())).map(Int.init)
      guard let minute, (0...59).contains(minute) else { return m[0] }
      return m[1] + String(h) + String(format: ":%02d", minute)
    }
    s = s.mapping("(电话(?:号码)?|手机(?:号码)?|验证码)([：: ]*)([零〇一二三四五六七八九幺]{4,16})") { m in
      m[1] + m[2] + (serial(m[3].replacingOccurrences(of: "幺", with: "一")) ?? m[3])
    }
    let units = "毫秒|秒钟|分钟|小时|毫升|毫克|千克|公斤|公里|千米|厘米|毫米|摄氏度|字节|千瓦|美元|元钱|元整|元(?=[，。；！？\\s]|$)|米每秒"
    return s.mapping("(?<![第每零〇一二两三四五六七八九十百千万亿])([负]?)(\(cn)(?:点[零〇一二三四五六七八九]+)?)(?=\(units))") {
      m in
      guard let v = quantity(m[2]) else { return m[0] }
      return (m[1].isEmpty ? "" : "−") + v
    }
  }

  // Index the confirmed vocabulary by characters so a large import does not turn into a giant regex.
  struct WordIndex {
    struct Node {
      var edges: [String: Int] = [:]
      var value: String?
      var rules: [Term] = []
    }
    var nodes = [Node()]
    var exact = [String: String]()
    private(set) var hasPreferences = false
    let marked: [String]
    let graph: WordContext, prior: [String: Int], previousLine: String, hanAlphabet: Set<Character>?
    init(
      _ terms: [Term], learned: [Term] = [], graph: WordContext = BuiltinVocabulary.shared.graph,
      prior: [String: Int] = [:], previousLine: String = "", hanAlphabet: Set<Character>? = nil
    ) {
      self.graph = graph; self.hanAlphabet = hanAlphabet
      self.prior = prior; self.previousLine = String(previousLine.suffix(96))
      marked = terms.map(\.spelling).filter { $0.contains("\u{E000}") }
      // Only a manually entered alias is an exact rewrite. Old unscoped memories are never aliases.
      for term in terms where !term.spelling.trimmed.isEmpty {
        for raw in [term.spelling.trimmed, term.spoken.trimmed] where !raw.isEmpty {
          let name = raw.lowercased()
          guard exact[name] == nil else { continue }
          exact[name] = term.spelling.trimmed
          var node = 0
          for c in raw {
            let k = String(c).lowercased()
            if let i = nodes[node].edges[k] {
              node = i
            } else {
              let i = nodes.count
              nodes.append(Node())
              nodes[node].edges[k] = i
              node = i
            }
          }
          nodes[node].value = term.spelling.trimmed
        }
      }
      for term in learned
      where term.scope != nil && !term.spoken.isEmpty && exact[term.spoken.lowercased()] == nil && BuiltinVocabulary.shared.permitsLearnedPair(term) {
        var node = 0
        for c in term.spoken {
          let k = String(c).lowercased()
          if let n = nodes[node].edges[k] {
            node = n
          } else {
            let n = nodes.count
            nodes[node].edges[k] = n
            nodes.append(Node())
            node = n
          }
        }
        nodes[node].rules.append(term)
        hasPreferences = true
      }
    }
    func scan(_ text: String, verbatim: Bool = false, preferences: Bool = true, suggest: ((ReadingChoice)->Void)? = nil, emit: (String, Bool) -> Void) {
      let chars = Array(text)
      var i = 0
      var plain = 0, boundaries: SourceLexemes?
      func cutsWord(_ end:Int, _ replacement:String)->Bool {
        guard chars[i..<end].allSatisfy(SoundShelf.han) else {return false}
        if boundaries == nil { boundaries=SourceLexemes(text,chars:chars) }
        return boundaries!.risk(i..<end,replacingWith:replacement) == .fragment
      }
      func latin(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber || c == "_") }
      while i < chars.count {
        if i > 0 && latin(chars[i - 1]) && latin(chars[i]) {
          i += 1
          continue
        }
        var at = i
        var node = 0
        var match: (Int, String)?
        var offers = [ReadingChoice]()
        while at < chars.count, let next = nodes[node].edges[String(chars[at]).lowercased()] {
          at += 1
          node = next
          if !(at < chars.count && latin(chars[at - 1]) && latin(chars[at])) {
            if let v = nodes[node].value {
              match = (at, v)
            } else if preferences, !verbatim, !nodes[node].rules.isEmpty {
              let l = String(chars[max(0, i - 36)..<i])
              let r = String(chars[at..<min(chars.count, at + 36)])
              if !BuiltinVocabulary.identity(l, r) {
                let heard = String(chars[i..<at]), local = MemoryScope.make(left:l, right:r, graph:graph)
                let clipped = WordContext.clipped(l,r), alone = (clipped.0+clipped.1).trimmingCharacters(in:BuiltinVocabulary.spokenEdge).isEmpty
                var votes = [String:Int]()
                for rule in nodes[node].rules where graph.allowsMemory(rule, left: l, right: r) {
                  guard let support = rule.scope?.support(in:local, standalone:alone), support.offer, rule.spelling != heard, !cutsWord(at,rule.spelling) else {continue}
                  votes[rule.spelling] = max(votes[rule.spelling] ?? 0, support.takes)
                }
                // A known spelling, competing preference, or unrelated topic never loses to frequency.
                if votes.count == 1, let winner = votes.first, winner.value >= MemoryScope.minimumTakes,
                  PersonalCorrection.automatic(heard,winner.key) {
                  match = (at, winner.key)
                } else if suggest != nil, !votes.isEmpty {
                  offers = votes.keys.sorted().prefix(4).map { ReadingChoice(heard:heard,word:$0,left:String(l.suffix(5)),right:String(r.prefix(5))) }
                }
              }
            }
          }
        }
        if let (end, v) = match {
          emit(String(chars[plain..<i]), false)
          emit(verbatim ? String(chars[i..<end]) : v, true)
          i = end
          plain = end
        } else {
          if let suggest { offers.forEach(suggest) }
          i += 1
        }
      }
      emit(String(chars[plain...]), false)
    }
  }

  // Protect quoted speech and identifiers before touching prose. Anchoring a dictionary entry
  // to a complete token prevents a short alias from rewriting a URL, a path or a longer name.
  private struct Literals {
    var marker = "\u{E000}", values: [String] = []
    var titles = [String: String](), quotedChoices = [ReadingChoice](), personalChoices = [ReadingChoice]()
    fileprivate static let protected = try! NSRegularExpression(
      pattern:
        #"(```[\s\S]*?(?:```|$)|`[^`\n]*(?:`|$)|《[^》\n]*(?:》|$)|“[^”]*(?:”|$)|‘[^’]*(?:’|$)|「[^」]*(?:」|$)|『[^』]*(?:』|$)|\"[^\"\n]*(?:\"|$))|(?i:[a-z][a-z0-9+.\-]*://[^\s，。；！？、（）「」“”]+|[\w.%+\-]+@[a-z0-9.\-]+\.[a-z]{2,}|(?:~/|/|\./|\.\./)[\w.+@~/\-]+|[a-z_][a-z0-9_]*(?:[.:/_@\-][a-z0-9_]+)+(?:\+\+|#)?|[a-z][a-z0-9_]*(?:\+\+|#)|[0-9]+(?:[.:/\-][0-9]+)+)"#
    )
    mutating func mask(_ input: String, index trie: WordIndex, literary: BuiltinVocabulary? = nil,
      final: Bool = true, suggest: Bool = false, verbatim: Bool = false, suggestPersonal: Bool = false) -> String {
      while input.contains(marker) || trie.marked.contains(where: { $0.contains(marker) }) {
        marker += "\u{E000}"
      }
      let ns = input as NSString
      var end = 0
      var out = ""
      func appendLiteral(_ word: String) {
        out += marker + String(values.count) + "\u{E001}"
        values.append(word)
      }
      func plain(_ text: String) {
        guard trie.nodes.count > 1 else {
          out += text
          return
        }
        var offers = [ReadingChoice]()
        let collect: ((ReadingChoice)->Void)? = suggestPersonal ? { if offers.count < 8 { offers.append($0) } } : nil
        trie.scan(text, verbatim:verbatim, preferences:final, suggest:collect) { word, fixed in if fixed { appendLiteral(word) } else { out += word } }
        if suggestPersonal { personalChoices += offers.prefix(max(0,8-personalChoices.count)) }
      }
      for m in Self.protected.matches(in: input, range: NSRange(location: 0, length: ns.length)) {
        let gap = ns.substring(with: NSRange(location: end, length: m.range.location - end))
        plain(gap)
        let word = ns.substring(with: m.range)
        if gap.hasSuffix("百分之") || gap.hasSuffix("百分之负"),
          word.range(of: #"^[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil
        {
          out += word
        } else if let literary, let corpus = literary.classics, let open = word.first, let close = word.last,
          ["“": "”", "‘": "’", "「": "」", "『": "』"][String(open)] == String(close),
          let range = Range(m.range, in: input) {
          let lead = String(input[..<range.lowerBound].suffix(56))
          if ClassicalCorpus.verbatim(lead) || BuiltinVocabulary.identity(lead, "") { appendLiteral(word) }
          else {
            // Reopen just a witnessed Chinese citation for literary checking. Protected
            // words and code *inside* remain opaque; ordinary quoted speech stays verbatim.
            let body = String(word.dropFirst().dropLast()); var inner = Literals()
            let visible = inner.mask(body, index: trie, verbatim: true), chars = Array(visible)
            let found = corpus.assess(visible, enabled: literary.enabled, bias: literary.bias,
              final: final, suggest: suggest, hanAlphabet: trie.hanAlphabet, quoteLead: lead)
            quotedChoices += found.choices
            if found.pieces.contains(where: { p in p.start < p.end && p.text.contains(where: SoundShelf.han) && String(chars[p.start..<p.end]) != p.text }) {
              var at = 0, rendered = ""
              for p in found.pieces { rendered += String(chars[at..<p.start]) + p.text; at = p.end }
              appendLiteral(String(open) + inner.unmask(rendered + String(chars[at...])) + String(close))
            } else { appendLiteral(word) }
          }
        } else {
          if word.first == "《", word.last == "》", let corpus = literary?.classics {
            let name = String(word.dropFirst().dropLast())
            if corpus.knowsTitle(name) { titles[marker + String(values.count) + "\u{E001}"] = name }
          }
          appendLiteral(
            !verbatim && m.range(at: 1).location == NSNotFound ? trie.exact[word.lowercased()] ?? word : word)
        }
        end = NSMaxRange(m.range)
      }
      plain(ns.substring(from: end))
      return out
    }
    mutating func keep(_ s: String) -> String {
      let id = values.count; values.append(s); return marker + String(id) + "\u{E001}"
    }
    func unmask(_ s: String) -> String {
      guard !values.isEmpty, let exp = try? NSRegularExpression(pattern:marker+"([0-9]+)\u{E001}") else {return s}
      let ns=s as NSString; var end=0,out=""; out.reserveCapacity(s.utf8.count)
      exp.enumerateMatches(in:s,range:NSRange(location:0,length:ns.length)) { match,_,_ in
        guard let match, let i=Int(ns.substring(with:match.range(at:1))), values.indices.contains(i) else{return}
        out += ns.substring(with:NSRange(location:end,length:match.range.location-end));out += values[i];end=NSMaxRange(match.range)
      }; return out+ns.substring(from:end)
    }
  }
  static func personalChoices(in text:String,index:WordIndex)->[ReadingChoice] {
    guard index.hasPreferences else {return []}; var literals=Literals()
    _ = literals.mask(text,index:index,suggestPersonal:true)
    return literals.personalChoices.filter { $0.range(in:text) != nil }
  }
  static func proseForLearning(_ text:String)->String {
    Literals.protected.stringByReplacingMatches(in:text,range:NSRange(text.startIndex...,in:text),withTemplate:"\n")
  }
  // Swift Character offsets for opaque spans; no re-decoder may rewrite a literal or personal spelling.
  static func replayProtected(in text:String, terms:[Term]) -> [Range<Int>] {
    let ns = NSRange(text.startIndex...,in:text)
    var ranges=Literals.protected.matches(in:text,range:ns).compactMap { Range($0.range,in:text) }
    for term in terms where !term.spelling.isEmpty {
      var i=text.startIndex
      while i<text.endIndex, let r=text.range(of:term.spelling,options:.caseInsensitive,range:i..<text.endIndex) { ranges.append(r); i=r.upperBound }
    }
    let ends=Set(ranges.flatMap{[$0.lowerBound,$0.upperBound]}); var offsets=[String.Index:Int]()
    for (i,p) in text.indices.enumerated() where ends.contains(p) { offsets[p]=i }; offsets[text.endIndex]=text.count
    return ranges.compactMap { r in guard let i=offsets[r.lowerBound], let j=offsets[r.upperBound] else {return nil}; return i..<j }
  }
  static func permits(_ edit:ProofMark,in text:String,index:WordIndex)->Bool {
    var literals=Literals(); let masked=literals.mask(text,index:index)
    guard !BuiltinVocabulary.identity(edit.left,edit.right) else { return false }
    return ReadingChoice(heard:edit.heard,word:edit.word,left:edit.left,right:edit.right).applying(to:masked) != nil
  }
  static func literaryReview(_ raw: String, index: WordIndex, vocabulary: BuiltinVocabulary,
    previous: String, short: Bool, probeTail: Bool) -> ClassicalCorpus.Assessment {
    guard let corpus = vocabulary.classics else { return .init() }
    var literals = Literals()
    let visible = literals.mask(raw, index: index, literary: vocabulary)
    let window = short ? visible : String(visible.suffix(100))
    var evidence = corpus.assess(window, enabled: vocabulary.enabled, bias: vocabulary.bias,
      final: true, suggest: short, previous: window.count == visible.count ? previous : "", probeTail: probeTail, probePair: short, hanAlphabet: index.hanAlphabet, titleMarkers: literals.titles)
    evidence.choices = evidence.choices.filter { $0.applying(to: raw) != nil }
    return evidence
  }
  static func alternatives(
    in text: String, original: String, index: WordIndex, vocabulary: BuiltinVocabulary
  ) -> [ReadingChoice] {
    var literals=Literals(); let visible=literals.mask(text,index:index,literary:vocabulary,suggest:true), chars=Array(visible)
    var result = ((vocabulary.classics?.assess(visible, enabled: vocabulary.enabled, bias: vocabulary.bias, final: true, suggest: true, previous: index.previousLine, hanAlphabet: index.hanAlphabet, titleMarkers:literals.titles).choices ?? []) + literals.quotedChoices).filter { $0.applying(to:text) != nil }
    var cache=[Character:String]()
    func add(_ s:String,_ w:String,_ left:String,_ right:String) {
      guard result.count<8, !vocabulary.bias.discourages(w) else { return }
      let simple=ReadingChoice(heard:s,word:w)
      let choice = simple.applying(to:text) == nil ? ReadingChoice(heard:s,word:w,left:String(left.suffix(5)),right:String(right.prefix(5))) : simple
      if !result.contains(choice),choice.applying(to:text) != nil { result.append(choice) }
    }
    for rule in vocabulary.graph.review where original.contains(rule.heard) && result.count<8 {
      var pos=visible.startIndex
      while pos<visible.endIndex,let range=visible[pos...].range(of:rule.heard) {
        pos=range.upperBound; let left=String(visible[..<range.lowerBound].suffix(32)),right=String(visible[range.upperBound...].prefix(32)); let phrase=rule.context(left:left,right:right)
        guard !BuiltinVocabulary.identity(left,right),!rule.avoid.contains(where:phrase.contains),rule.require.isEmpty || rule.require.contains(where:phrase.contains) || (!rule.includeNeighbor && vocabulary.bias.discourages(rule.heard)) else { continue }
        for word in rule.alternatives where vocabulary.enabled.contains(word) { add(rule.heard,word,left,right) }
      }
    }
    for i in chars.indices where result.count<8 {
      for alias in vocabulary.aliasChoices(in:chars,at:i) {
        let heard=String(chars[i..<alias.end]); if original.contains(heard) { add(heard,alias.word,String(chars[..<i].suffix(5)),String(chars[alias.end...].prefix(5))) }
      }
      if let hit=vocabulary.soundshelf.hit(chars,i,minimum:i,enabled:vocabulary.enabled,bias:vocabulary.bias,cache:&cache), !hit.automatic,original.contains(hit.heard) {
        add(hit.heard,hit.word,String(chars[max(0,i-8)..<i]),String(chars[hit.end..<min(chars.count,hit.end+8)]))
      }
    }
    return result
  }
  static func render(_ original: String, level: EditLevel, terms: [Term] = []) -> String {
    render(original, level: level, index: WordIndex(terms), vocabulary: .shared, final: true)
  }
  static func render(
    _ original: String, level: EditLevel, index: WordIndex, vocabulary: BuiltinVocabulary,
    final: Bool, decoderLayout: Bool = false, lexical: ((String,String)->Void)? = nil
  ) -> String {
    let source = original.trimmed
    guard !source.isEmpty else { return "" }
    var literals = Literals()
    var s = literals.mask(source, index: index, literary: vocabulary, final: final)
    s = s.replacing(#"[\t ]+"#, " ").replacing(#"(?<=[，。！？；：、]) +(?=\p{Han})"#, "").replacing(
      #"(?<=\p{Han}) +(?=\p{Han})"#, "")
    if let classics = vocabulary.classics {
      let pieces = classics.assess(s, enabled: vocabulary.enabled, bias: vocabulary.bias, final: final, previous: index.previousLine, hanAlphabet: index.hanAlphabet, titleMarkers:literals.titles, decoderLayout:decoderLayout).pieces
      if !pieces.isEmpty {
        let a = Array(s); var pos = 0, protected = ""
        for piece in pieces {
          protected += String(a[pos..<piece.start]); protected += literals.keep(piece.text); pos = piece.end
        }
        s = protected + String(a[pos...])
      }
    }
    s = vocabulary.checked(s, final: final, prior: index.prior)
    if let lexical { let words=literals.unmask(s); if words != source { lexical(source,words) } }
    s = SpeechLayout.clauses(s, level: level)
    s = numbers(s)
    if level != .literal {
      // Isolated 呃 is hesitation; 嗯/啊 can be a complete answer and must survive there.
      s = s.replacing(#"(^|[，,。！？；、]\s*)(?:呃+|唔+)[，,、 ]+(?=\S)"#, "$1")
      s = s.replacing(#"(^|[，,。！？；、]\s*)嗯+[，,、 ]+(?=我(?:们|想|觉|准|打|要)|这(?:个|次)|先|请|明天|今天)"#, "$1")
      s = s.replacing(
        #"(^|[，,。；！？\s])((?:这个接口|具体来说|我觉得|我今天|这次|这个|那个|我们|我想|我|你|他))[，,、 ]+\2"#, "$1$2")
      s = s.replacing(#"(^|[，,。；！？\s])(我们|这个|那个|我|你|他)\2\2"#, "$1$2")
      s = s.replacing(#"(?i)(^|[.!?,;]\s+)(?:um+|uh+),\s+(?=[A-Za-z])"#, "$1")
      s = s.replacing(#"(?i)\b(I|we|the|this),\s+\1\b"#, "$1")
      s = s.replacing(#"(^|[，,。；！？\s])((?:我们|我想|这次|先把|请把))\2(?=[\p{Han}])"#, "$1$2")
      // An explicit self-correction must repeat the same kind of slot. Never infer a substitute for a name.
      let slots = [
        #"(?:星期|周)[一二三四五六日天]"#, #"(?:今天|明天|后天|昨天|前天)"#,
        #"(?:[0-9]+|[零一二两三四五六七八九十]+)(?:点(?:半|[零一二三四五六七八九十]+分)?)"#,
      ]
      let correction = #"[，,、 ]*(?:不对[，,、 ]*(?:是|改成|应该是)?|说错了[，,、 ]*(?:是|改成)?|更正为)[，,、 ]*"#
      for slot in slots { s = s.replacing("(\(slot))" + correction + "(\(slot))", "$2") }
    }
    if level == .concise || level == .outline {
      // Short-context decoders sometimes omit the comma after a spoken preamble. Without
      // one, require an independent clause; an actual question (“怎么说呢？”) stays intact.
      s = s.replacing(#"(^|[，,。；;！？!?：:\n][ \t]*)(?:我的意思就是说|我想说的就是说|我想表达的意思是说|简单来说就是说)(?:[，,、：:][ \t]*|[ \t]+|(?=我们|这次|不要|不能|请先|先把|先别))(?=\S)"#, "$1")
      s = s.replacing(#"(^|[，,。；;！？!?：:\n][ \t]*)(?:怎么说呢|这么说吧)[，,、：: ]+(?=\S)"#, "$1")
      s = s.replacing(
        #"(?i)(^|[.!?]\s+)(?:what I mean to say is|what I'm trying to say is),\s+(?=\S)"#, "$1")
      s = s.replacing(#"其实就是说[，,、 ]+"#, "其实，")
    }
    s =
      s.replacing(#"(?<=\p{Han}),(?=[\p{Han}\s])"#, "，").replacing(#"(?<=\p{Han});"#, "；")
      .replacing(#"(?<=\p{Han})\?(?=\s|$)"#, "？").replacing(#"(?<=\p{Han})!(?=\s|$)"#, "！")
      .replacing(#"(?<=\p{Han})\.(?=$)"#, "。").replacing(#"[ \t]+([，。；！？、])"#, "$1").replacing(
        #"[，、]+([。！？；])"#, "$1"
      ).trimmed
    if level == .outline { s = organize(s, final: final) }
    var result = literals.unmask(s)
    guard final else { return result }
    let han = result.range(of: #"\p{Han}"#, options: .regularExpression) != nil
    if han, level != .literal, result.count >= 7, let last = result.last, "，,".contains(last) {
      let body = String(result.dropLast()).trimmed
      if !["因为", "所以", "比如", "例如", "以及", "然后"].contains(where: body.hasSuffix) {
        result = body + (body.hasSuffix("吗") || body.hasSuffix("么") ? "？" : "。")
      }
    }
    if han, result.count >= 7, let last = result.last, !"。！？!?….,，:：；;”’）)」』".contains(last) {
      result += result.range(of: #"(?:吗|么|怎么办)$"#, options: .regularExpression) != nil ? "？" : "。"
    }
    if !han, result.range(of: #"^[A-Za-z][A-Za-z0-9 ,’'\-]+$"#, options: .regularExpression) != nil,
      result.split(separator: " ").count >= 4
    {
      result += "."
    }
    return result
  }
  private static func organize(_ input: String, final: Bool) -> String {
    // Number only an explicit sequence. Preserve the speaker's indices, even when numbers skip.
    let marks = #"(?:^|[，,。；;！!？?：:\n]\s*)(首先|其次|然后|最后|第([一二两三四五六七八九十]+)(?:点|步|项)?)[，,、：:\s]+"#
    let ns = input as NSString
    let matches =
      (try? NSRegularExpression(pattern: marks))?.matches(
        in: input, range: NSRange(location: 0, length: ns.length)) ?? []
    if matches.count >= 2, let first = matches.first {
      let explicit = matches.allSatisfy { $0.range(at: 2).location != NSNotFound }
      let inOrder =
        ns.substring(with: first.range(at: 1)) == "首先"
        && matches.dropFirst().allSatisfy { $0.range(at: 2).location == NSNotFound }
      let mixed =
        ns.substring(with: first.range(at: 1)).hasPrefix("第一")
        && matches.enumerated().allSatisfy { i, m in
          m.range(at: 2).location != NSNotFound
            ? integer(ns.substring(with: m.range(at: 2))) == Int64(i + 1)
            : (i == matches.count - 1 && ns.substring(with: m.range(at: 1)) == "最后")
        }
      if explicit || inOrder || mixed {
        // The marker includes its preceding delimiter. Carry a real question, full stop,
        // or exclamation into the previous sentence rather than turning it into a colon.
        func boundary(before m: NSTextCheckingResult) -> String? {
          let gap = NSRange(location: m.range.location, length: m.range(at: 1).location - m.range.location)
          return ns.substring(with: gap).first { "。！？!?：:；;".contains($0) }.map(String.init)
        }
        let intro = ns.substring(to: first.range.location).trimmed
        var rows: [String] = []
        for (i, m) in matches.enumerated() {
          let start = NSMaxRange(m.range)
          let end = i + 1 < matches.count ? matches[i + 1].range.location : ns.length
          let body = ns.substring(with: NSRange(location: start, length: end - start)).trimmed
          guard !body.isEmpty else { return input }
          let index =
            m.range(at: 2).location == NSNotFound
            ? Int64(i + 1) : integer(ns.substring(with: m.range(at: 2))) ?? Int64(i + 1)
          let complete = final || i < matches.count - 1
          let punctuation = i + 1 < matches.count ? boundary(before: matches[i + 1]) : nil
          let full = !complete || body.last.map { "。！？.!?；;」”".contains($0) } == true ? body : body + (punctuation ?? "。")
          rows.append("\(index). " + full)
        }
        let separator = intro.last.map { "。！？：:；;.!?".contains($0) } == true ? "" : (boundary(before: first) ?? "：")
        return (intro.isEmpty ? "" : intro + separator + "\n") + rows.joined(separator: "\n")
      }
    }
    if input.range(of: #"(?i)(?:^|[.!?]\s+)first(?:ly)?,\s"#, options: .regularExpression) != nil {
      return input.replacing(
        #"(?i)([.!?])\s+(?=(?:second(?:ly)?|third(?:ly)?|next|finally),\s)"#, "$1\n\n")
    }
    return input
  }
}
