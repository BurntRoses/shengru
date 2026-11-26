import CoreFoundation
import Foundation
import NaturalLanguage

struct ConversationWindow {
  private var latest: (id: UUID, destination: String, at: Date)?
  mutating func reset() { latest = nil }
  mutating func next(for destination: String, rows: [Record], at: Date = Date()) -> UUID {
    guard let t = latest, t.destination == destination,
      (0...180).contains(at.timeIntervalSince(t.at)),
      rows.first(where: { $0.text != nil })?.conversation == t.id
    else {
      latest = nil
      return UUID()
    }
    return t.id
  }
  mutating func accept(_ id: UUID, destination: String, at: Date = Date()) {
    latest = (id, destination, at)
  }
  static func recent(_ id: UUID?, rows: [Record]) -> [String] {
    guard let id else { return [] }
    return rows.prefix(8).filter { $0.conversation == id }.compactMap(\.text).prefix(3).map {
      String($0.suffix(700))
    }
  }
  static func hints(_ id: UUID?, rows: [Record], terms: [Term]) -> [String] {
    hints(previous: recent(id, rows: rows), terms: terms)
  }
  static func hints(
    previous: [String], terms: [Term], graph: WordContext = BuiltinVocabulary.shared.graph
  ) -> [String] {
    guard let latest = previous.first else { return [] }
    var relevant = [WordContext.fresh(latest)]
    let topics = Set(graph.preceding([latest]).keys)
    if !topics.isEmpty && !WordContext.shifts.contains(where: latest.contains) {
      for older in previous.dropFirst().prefix(2) {
        guard !topics.isDisjoint(with: graph.preceding([older]).keys) else { break }
        relevant.append(WordContext.fresh(older))
        if WordContext.shifts.contains(where: older.contains) { break }
      }
    }
    let recent = relevant.joined(separator: " ")
    guard !recent.isEmpty else { return [] }
    // Bias the acoustic search for familiar names, never paste a previous sentence into a new one.
    let folded = recent.lowercased()
    let chars = Array(folded)
    let starts = Set(chars.indices.map { String(chars[$0..<min($0 + 2, chars.count)]) })
    var candidates = Array(
      terms.lazy.map(\.spelling).filter {
        let key = $0.lowercased()
        return key.count >= 2 && starts.contains(String(key.prefix(2))) && folded.contains(key)
      }.prefix(12))
    let re = try! NSRegularExpression(
      pattern: #"(?<![A-Za-z0-9_])[A-Za-z][A-Za-z0-9]{1,23}(?![A-Za-z0-9_])"#)
    let text = recent as NSString
    for m in re.matches(in: recent, range: NSRange(location: 0, length: text.length)) {
      let value = text.substring(with: m.range)
      if value.dropFirst().contains(where: \.isUppercase) { candidates.append(value) }
    }
    var seen = Set<String>()
    return Array(
      candidates.filter {
        (2...32).contains($0.count) && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == " " }
          && seen.insert($0.lowercased()).inserted
      }.prefix(16))
  }
}

struct CorrectionKey: Hashable {
  let spoken: String, spelling: String
}
extension Term {
  var correctionKey: CorrectionKey { CorrectionKey(spoken: spoken, spelling: spelling) }
}

enum PersonalCorrection {
  // Compare corresponding clauses, not unrelated text on either side of a sentence edit.
  // Conflicting proposed spellings of the same word are left to the user's dictionary.
  static func candidates(
    from before: String, to after: String, graph: WordContext = BuiltinVocabulary.shared.graph
  ) -> [Term] {
    guard before != after, before.count <= 12000, after.count <= 12000 else { return [] }
    let delimiters = CharacterSet(charactersIn: "，,。；;、！？!?：:\n\r")
    func clauses(_ s: String) -> [String] {
      s.components(separatedBy: delimiters).map(\.trimmed).filter { !$0.isEmpty }
    }
    let lhs = clauses(Transcript.proseForLearning(before))
    let rhs = clauses(Transcript.proseForLearning(after))
    guard lhs.count == rhs.count else { return [] }
    var seen = Set<CorrectionKey>()
    var spellings = [String: String]()
    var conflicts = Set<String>()
    var pairs = [Term]()
    for (a, b) in zip(lhs, rhs) where a != b {
      guard var pair = candidate(from: a, to: b), BuiltinVocabulary.shared.permitsLearnedPair(pair), let ar = a.range(of: pair.spoken),
        let br = b.range(of: pair.spelling)
      else { continue }
      // Prefer the complete ambiguous word (e.g. 金秋奖 → 金球奖), not a shared suffix of it.
      for heard in graph.forms.keys.sorted(by: { $0.count > $1.count })
      where heard.contains(pair.spoken) {
        guard let family = graph.forms[heard], let old = a.range(of: heard), old.overlaps(ar),
          let winner = graph.families[family]?.first(where: {
            $0.word != heard && $0.word.contains(pair.spelling)
              && b.range(of: $0.word)?.overlaps(br) == true
          }), a.replacingCharacters(in: old, with: winner.word) == b
        else { continue }
        pair.spoken = heard
        pair.spelling = winner.word
        break
      }
      guard let hit = b.range(of: pair.spelling) else { continue }
      let left = String(b[..<hit.lowerBound]), right = String(b[hit.upperBound...])
      guard !BuiltinVocabulary.identity(left,right), !ClassicalCorpus.verbatim(left) else { continue }
      pair.scope = MemoryScope.make(left:left, right:right, graph:graph)
      let word = pair.spoken.lowercased()
      if let prior = spellings[word], prior != pair.spelling { conflicts.insert(word) }
      spellings[word] = pair.spelling
      if seen.insert(pair.correctionKey).inserted { pairs.append(pair) }
    }
    return Array(pairs.filter { !conflicts.contains($0.spoken.lowercased()) }.prefix(8))
  }
  // Saving confirms the passage, not a global rewrite: learn only a short spelling or sound-alike.
  static func learnable(_ t:Term) -> Bool {
    let old=t.spoken, new=t.spelling
    if WordCatalog.shared.byName[new.lowercased()]?.variants.contains(where:{$0.caseInsensitiveCompare(old) == .orderedSame}) == true {return true}
    if old.allSatisfy(\.isASCII) && new.allSatisfy(\.isASCII) {
      func key(_ s:String)->String {s.lowercased().filter{$0.isLetter || $0.isNumber}}
      let a=key(old),b=key(new); if a==b {return !a.isEmpty}
      return min(a.count,b.count)>=4 && b.difference(from:a).count<=2
    }
    guard old.count==new.count, old.count<=10 else {return false}
    let differences=zip(old,new).filter{$0 != $1};guard !differences.isEmpty, differences.count<=4 else {return false}
    func sound(_ c:Character)->String? {
      guard c.unicodeScalars.allSatisfy({$0.properties.isIdeographic}) else {return nil}
      return String(c).applyingTransform(.mandarinToLatin,reverse:false)?.folding(options:.diacriticInsensitive,locale:Locale(identifier:"zh_CN")).lowercased()
    }
    return differences.allSatisfy {a,b in guard let l=sound(a),let r=sound(b) else{return false};return l==r}
  }
  // Keep an edit between two different Latin words available for review. Case, spacing
  // and a transposed pair of letters are narrower evidence of an actual spelling habit.
  static func automatic(_ heard:String,_ word:String)->Bool {
    if let known = WordCatalog.shared.byName[heard.lowercased()], known.name != word { return false }
    guard heard.allSatisfy(\.isASCII) || word.allSatisfy(\.isASCII) else { return true }
    let a=Array(heard.lowercased().filter { !$0.isWhitespace }), b=Array(word.lowercased().filter { !$0.isWhitespace })
    if a==b {return true}; guard a.count==b.count,
      WordCatalog.shared.byName[word.lowercased()]?.name == word || (word.contains(where:\.isLowercase) && word.dropFirst().contains(where:\.isUppercase)) else {return false}
    let diff=a.indices.filter{a[$0] != b[$0]}
    return diff.count==2 && diff[0]+1==diff[1] && a[diff[0]]==b[diff[1]] && a[diff[1]]==b[diff[0]]
  }
  static func merging(_ chosen: [Term], into old: [Term], record: UUID, before: String, after: String) -> [Term] {
    var out = old
    var undone = Set<CorrectionKey>()
    // Revising the same passage can withdraw its vote, not create an inverse preference.
    for i in out.indices.reversed() {
      let saved = out[i]
      guard var scope = saved.scope, var votes = scope.observations,
        votes.contains(where: { $0.record == record }), before.contains(saved.spelling), !after.contains(saved.spelling) else { continue }
      votes.removeAll { $0.record == record }; scope.observations = votes
      undone.insert(.init(spoken:saved.spelling, spelling:saved.spoken))
      if let last = votes.last { scope.topics = last.topics; scope.anchors = last.anchors; out[i].scope = scope }
      else { out.remove(at:i) }
    }
    for var t in chosen {
      guard var scope = t.scope, !undone.contains(t.correctionKey) else { continue }
      let i = out.firstIndex { $0.correctionKey == t.correctionKey }
      var votes = i.flatMap { out[$0].scope?.observations } ?? []
      votes.removeAll { $0.record == record }
      votes.append(.init(record:record, topics:scope.topics, anchors:scope.anchors))
      scope.observations = Array(votes.suffix(12)); t.scope = scope
      if let i { t.id = out[i].id; out[i] = t } else { out.append(t) }
    }
    return out
  }
  static func candidate(from before: String, to after: String) -> Term? {
    let a = Array(before.trimmed)
    let b = Array(after.trimmed)
    guard a != b, a.count <= 12000, b.count <= 12000 else { return nil }
    var lo = 0
    var ar = a.count
    var br = b.count
    while lo < min(ar, br), a[lo] == b[lo] { lo += 1 }
    while ar > lo, br > lo, a[ar - 1] == b[br - 1] {
      ar -= 1
      br -= 1
    }
    func asciiWord(_ c: Character) -> Bool {
      c.isASCII && (c.isLetter || c.isNumber || "_+#./-".contains(c))
    }
    if (lo < a.count && asciiWord(a[lo])) || (lo < b.count && asciiWord(b[lo]))
      || (lo > 0 && asciiWord(a[lo - 1]))
    {
      while lo > 0 && asciiWord(a[lo - 1]) { lo -= 1 }
      while ar < a.count, br < b.count, asciiWord(a[ar]) {
        ar += 1
        br += 1
      }
    }
    // A one-character Han diff belongs to a word, not to an arbitrary character plus
    // the following particle. Use the corrected word's boundaries or do not learn it.
    if ar-lo==1, br-lo==1, SoundShelf.han(a[lo]), SoundShelf.han(b[lo]) {
      let text=String(b), tokenizer=NLTokenizer(unit:.word); tokenizer.string=text; tokenizer.setLanguage(.simplifiedChinese)
      let range=tokenizer.tokenRange(at:text.index(text.startIndex,offsetBy:lo)), token=text[range]
      guard (2...10).contains(token.count), token.allSatisfy(SoundShelf.han) else {return nil}
      lo=text.distance(from:text.startIndex,to:range.lowerBound); br=lo+token.count; ar=br
    }
    // A space between Chinese and a Latin name is typography, not part of the alias.
    let edge = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "."))
    let old = String(a[lo..<ar]).trimmingCharacters(in: edge)
    let new = String(b[lo..<br]).trimmingCharacters(in: edge)
    func safe(_ s: String) -> Bool {
      guard (2...30).contains(s.count), s.first?.isLetter == true,
        s.split(separator: " ").count <= 3,
        s.allSatisfy({ $0.isLetter || $0.isNumber || " +#._-/".contains($0) }),
        s.range(
          of: #"不|没|别|无|否|非|未|勿|禁止|必须|(?:^| )(?:no|not|never)(?: |$)|[零〇一二三四五六七八九十百千万亿]"#,
          options: [.regularExpression, .caseInsensitive]) == nil
      else { return false }
      return !s.contains(where: \.isNumber) || s.allSatisfy(\.isASCII)
    }
    guard safe(old), safe(new), old != new else { return nil }
    // Version and quantity changes belong to this draft, never to a general replacement rule.
    if old.contains(where: \.isNumber)
      || (old.allSatisfy(\.isASCII) && new.contains(where: \.isNumber))
    {
      guard old.filter(\.isNumber) == new.filter(\.isNumber) else { return nil }
    }
    return Term(spelling: new, spoken: old)
  }
}

enum TextImportMode: String, CaseIterable {
  case automatic = "自动识别"
  case list = "按分隔符"
  case lines = "每行一词"
  case table = "写作与读作"
}
struct ImportPreview: Identifiable {
  let id = UUID()
  var name: String
  var terms: [Term]
  var duplicates: Int
  var skipped: Int
  var group: WordCollection? = nil
  var forBlock = false
  var source: URL? = nil
  var issue: String? = nil
}
enum LexiconImport {
  enum ParseIssue: LocalizedError {
    case unclosedQuote
    var errorDescription: String? { "有一处引号未闭合。可补全引号，或选择“每行一词”。" }
  }
  static func read(
    _ url: URL, existing: [Term], known: Set<String> = [], plainOnly: Bool = false,
    mode: TextImportMode = .automatic
  ) throws -> ImportPreview {
    let ext = url.pathExtension.lowercased()
    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard size <= 8_000_000 else { throw VoiceFault.message("请选择小于 8 MB 的词库文件。") }
    let data = try Data(contentsOf: url)
    var terms = [Term]()
    var duplicates = 0
    var skipped = 0
    var spellings = Set(existing.map { $0.spelling.lowercased() })
    var aliases = Set(existing.flatMap { [$0.spelling.lowercased(), $0.spoken.lowercased()] })
    func add(_ spelling: String, _ spoken: String = "") throws {
      let s = spelling.trimmed
      let r = plainOnly ? "" : spoken.trimmed
      guard !s.isEmpty, s.count <= 96, r.count <= 96,
        !(s + r).unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
      else {
        skipped += 1
        return
      }
      guard !(r.isEmpty && known.contains(s.lowercased())), !spellings.contains(s.lowercased()),
        !aliases.contains(s.lowercased()), r.isEmpty || !aliases.contains(r.lowercased())
      else {
        duplicates += 1
        return
      }
      spellings.insert(s.lowercased())
      aliases.insert(s.lowercased())
      if !r.isEmpty { aliases.insert(r.lowercased()) }
      guard terms.count < 20000, terms.count + existing.count < 40000 else {
        throw VoiceFault.message("单次最多导入两万条，词表最多四万条。")
      }
      terms.append(Term(spelling: s, spoken: r == s || r.allSatisfy(\.isNumber) ? "" : r))
    }
    if ext == "plist" || ext == "json" {
      let root: Any =
        ext == "plist"
        ? try PropertyListSerialization.propertyList(from: data, format: nil)
        : try JSONSerialization.jsonObject(with: data)
      let list: [Any]?
      if let items = root as? [Any] {
        list = items
      } else if let dict = root as? [String: Any] {
        list = dict["terms"] as? [Any] ?? dict["entries"] as? [Any]
      } else {
        list = nil
      }
      guard let list else { throw VoiceFault.message("文件里没有词条列表。") }
      for row in list {
        if let word = row as? String {
          try add(word)
        } else if let item = row as? [String: Any],
          let word = (item["phrase"] ?? item["spelling"] ?? item["word"]) as? String
        {
          try add(word, (item["shortcut"] ?? item["spoken"] ?? item["alias"]) as? String ?? "")
        } else {
          skipped += 1
        }
      }
    } else {
      let isUTF16 = data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff])
      let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(0x0632))
      guard
        let text = isUTF16
          ? String(data: data, encoding: .utf16)
          : (String(data: data, encoding: .utf8) ?? String(data: data, encoding: gb)),
        !text.contains("\0")
      else { throw VoiceFault.message("无法读取文本编码。请从原应用导出文本词库。") }
      let lines = text.trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}")).components(
        separatedBy: .newlines)
      let rime = ["yaml", "yml"].contains(ext)
      var body = !rime
      var wordIndex = 0
      var aliasIndex: Int? = nil
      var hasHeader = false
      if rime && !lines.contains(where: { $0.trimmed == "..." }) {
        throw VoiceFault.message("请选择带有词条正文的 Rime 词典。")
      }
      let first =
        lines.map(\.trimmed).first(where: {
          !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("//")
        }) ?? ""
      let headers = ["写作", "词条", "词语", "word", "phrase", "spelling"]
      let readings = ["读作", "别名", "快捷短语", "shortcut", "alias", "spoken"]
      func columns(_ row: String) -> [String] {
        if row.contains("\t") { return row.components(separatedBy: "\t") }
        return csv(row, separators: [",", "，"])
      }
      let header = columns(first).map { $0.trimmed.lowercased() }
      let headedTXT =
        header.count >= 2 && header.contains(where: headers.contains)
        && (first.contains("\t") || header.contains(where: readings.contains))
      let isTXT = ["txt", "text", "list"].contains(ext)
      // Without a header, only whole-file evidence of an input-method export selects columns.
      // Ambiguous two-column lists remain lists; the preview can explicitly select a table.
      let samples = lines.lazy.map(\.trimmed).filter {
        !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("//")
      }.prefix(30)
      let codedTXT =
        isTXT && first.contains("\t") && !samples.isEmpty
        && samples.allSatisfy { line in
          let c = line.components(separatedBy: "\t")
          guard (2...3).contains(c.count) else { return false }
          let han: (String) -> Bool = {
            $0.range(of: #"\p{Han}"#, options: .regularExpression) != nil
          }
          let code: (String) -> Bool = {
            $0.range(of: #"^[a-z]+(?:[ '0-9:]+[a-z0-9']*)*$"#, options: .regularExpression) != nil
          }
          return (han(c[0]) && code(c[1]) || code(c[0]) && han(c[1]))
            && (c.count < 3 || c[2].allSatisfy(\.isNumber))
        }
      let selected =
        mode == .automatic ? (headedTXT || codedTXT ? TextImportMode.table : .list) : mode
      let explicitPair = isTXT && mode == .table
      var firstDataRow = true
      for line in lines {
        let l = line.trimmed
        if !body {
          if l == "..." { body = true }
          continue
        }
        if l.isEmpty || l.hasPrefix("#") || l.hasPrefix("//") { continue }
        if isTXT && selected == .lines {
          try add(l)
          continue
        }
        if isTXT && selected == .list {
          for w in try splitWords(line) { try add(w) }
          continue
        }
        let cols =
          (isTXT ? columns(line) : ext == "csv" ? csv(line) : line.components(separatedBy: "\t"))
          .map(\.trimmed)
        let mayBeHeader = firstDataRow && !rime
        firstDataRow = false
        if mayBeHeader, cols.count >= 2,
          let i = cols.firstIndex(where: {
            headers.contains($0.lowercased())
          })
        {
          hasHeader = true
          wordIndex = i
          aliasIndex = cols.firstIndex(where: {
            readings.contains($0.lowercased())
          })
          continue
        }
        guard cols.indices.contains(wordIndex) else {
          skipped += 1
          continue
        }
        // Rime columns after the word are input codes/weights, not spoken aliases.
        let han: (String) -> Bool = {
          $0.range(of: #"\p{Han}"#, options: .regularExpression) != nil
        }
        if !explicitPair && !hasHeader && !rime && cols.count >= 2, !han(cols[0]), han(cols[1]),
          cols[0].range(of: #"^[a-z' :0-9]+$"#, options: .regularExpression) != nil
        {
          try add(cols[1])
          continue
        }
        let idx = hasHeader ? aliasIndex : (rime || (cols.count > 2 && !explicitPair) ? nil : 1)
        let alias = idx.flatMap { cols.indices.contains($0) ? cols[$0] : nil } ?? ""
        let looksLikeCode =
          !explicitPair && !hasHeader && han(cols[wordIndex])
          && alias.range(of: #"^[a-z' 0-9]+$"#, options: .regularExpression) != nil
        try add(cols[wordIndex], looksLikeCode ? "" : alias)
      }
    }
    return ImportPreview(
      name: url.lastPathComponent, terms: terms, duplicates: duplicates, skipped: skipped,
      source: url)
  }
  // In list mode, paired quotes preserve internal spaces and separators.
  static func splitWords(_ line: String) throws -> [String] {
    var result = [String]()
    var cell = ""
    var close: Character?
    var i = line.startIndex
    func flush() {
      if !cell.trimmed.isEmpty { result.append(cell.trimmed) }
      cell = ""
    }
    while i < line.endIndex {
      let ch = line[i]
      i = line.index(after: i)
      if let q = close {
        if ch == q {
          if i < line.endIndex && line[i] == q {
            cell.append(q)
            i = line.index(after: i)
          } else {
            close = nil
          }
        } else {
          cell.append(ch)
        }
      } else if cell.isEmpty,
        let q: Character = ["\"": "\"", "“": "”", "「": "」", "'": "'", "‘": "’"][ch]
      {
        close = q
      } else if ch.isWhitespace || ",，、;；".contains(ch) {
        flush()
      } else {
        cell.append(ch)
      }
    }
    guard close == nil else { throw ParseIssue.unclosedQuote }
    flush()
    return result
  }
  private static func csv(_ line: String, separators: Set<Character> = [","]) -> [String] {
    var cells = [String]()
    var field = ""
    var quoted = false
    var i = line.startIndex
    while i != line.endIndex {
      let c = line[i]
      i = line.index(after: i)
      if c == "\"" {
        if quoted, i != line.endIndex, line[i] == "\"" {
          field.append(c)
          i = line.index(after: i)
        } else {
          quoted.toggle()
        }
      } else if separators.contains(c) && !quoted {
        cells.append(field)
        field = ""
      } else {
        field.append(c)
      }
    }
    return cells + [field]
  }
}
