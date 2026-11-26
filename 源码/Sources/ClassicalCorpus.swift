import Foundation

// Local witness index. An entry is one actually spoken clause, never the continuation of a
// quotation. A work contributes links only between consecutive clauses of that particular text.
final class ClassicalCorpus {
  enum Kind: String {
    case poem = "诗"
    case lyric = "词"
    case prose = "文"
    case idiom = "成"
    case saying = "歇"
    case credit = "题"
  }
  static let verseTopic = "诗词古文", idiomTopic = "成语歇后语"
  private struct Line {
    let text: String, chars: [Character], phones: [Int]
    var kind: Kind, tags: [String]
    var topic: String { kind == .idiom || kind == .saying ? idiomTopic : verseTopic }
  }
  private var lines = [Line](), byText = [String: Int](), seeds = [Int: [Int]](),
    links = [UInt64: String]()
  private var following = [Int: [Int]](), preceding = [Int: [Int]]()
  private struct Sequence: Hashable { let a: Int, b: Int, c: Int }
  private var sequences = Set<Sequence>(), workTitles = Set<String>()
  func knowsTitle(_ text: String) -> Bool { workTitles.contains(text) }
  private let sounds: Sounds
  private static func edge(_ a: Int, _ b: Int) -> UInt64 { UInt64(a) << 32 | UInt64(b) }
  private static func key(_ a: Int, _ b: Int) -> Int { (a >> 3) << 12 | (b >> 3) }

  // The small on-disk table is generated from macOS Mandarin transliteration. Tone is kept
  // separately from the syllable; near initials/finals alone cannot trigger an automatic edit.
  private struct Sounds {
    var code = [Character: Int](), base = [String: Int](), near = [Int: Int](), broad = [Int: Int]()
    static func plain(_ s: String) -> String {
      s.map { "üǖǘǚǜ".contains($0) ? "v" : String($0) }.joined().folding(
        options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
    }
    init(_ table: [[String]]) {
      var families = [String: Int](), acoustic = [String: Int]()
      for row in table where row.count == 2 {
        let p = row[0]
        let name = Self.plain(p)
        let id = base[name] ?? (base.count + 1)
        base[name] = id
        let marks = p.decomposedStringWithCanonicalMapping.unicodeScalars
        let tone =
          marks.contains("\u{0304}")
          ? 1
          : marks.contains("\u{0301}")
            ? 2 : marks.contains("\u{030C}") ? 3 : marks.contains("\u{0300}") ? 4 : 0
        for c in row[1] { code[c] = id * 8 + tone }
        var f = name
        for (a, b) in [("zh", "z"), ("ch", "c"), ("sh", "s")] where f.hasPrefix(a) {
          f = b + f.dropFirst(a.count)
        }
        if f.hasSuffix("ang") || f.hasSuffix("eng") || f.hasSuffix("ing") { f.removeLast() }
        let fam = families[f] ?? families.count + 1
        families[f] = fam
        near[id] = fam
        // A shared vowel with a neighbouring initial (ju/qu), or a rounded vowel
        // confused with its glide (du/duo). Only a witnessed passage may use this tier.
        var initial = "", rime = f[...]
        if let c = rime.first, "bpmfdtnlgkhjqxzcsryw".contains(c) {
          initial = ["bp", "dt", "gk", "jqx", "zcs"].first(where: { $0.contains(c) }) ?? String(c)
          rime = rime.dropFirst()
        }
        let k = initial + ":" + (rime == "uo" ? "u" : String(rime))
        let cluster = acoustic[k] ?? acoustic.count + 1; acoustic[k] = cluster; broad[id] = cluster
      }
    }
    static let digits: [Character: Character] = [
      "0": "零", "1": "一", "2": "二", "3": "三", "4": "四", "5": "五", "6": "六", "7": "七", "8": "八",
      "9": "九",
    ]
    // An alternative reading belongs to the *heard* character, not every occurrence in the
    // reference. In particular 乐 does not turn into 说 outside the 学而 passage.
    static let alternatives: [Character: [String]] = [
      "行": ["hang", "xing"], "重": ["chong", "zhong"], "还": ["huan", "hai"],
      "长": ["zhang", "chang"], "乐": ["yue", "le"], "说": ["yue", "shuo"], "数": ["shu", "shuo"],
      "觉": ["jue", "jiao"], "将": ["jiang", "qiang"], "间": ["jian"], "曾": ["zeng", "ceng"],
      "相": ["xiang"], "泊": ["bo", "po"], "见": ["jian", "xian"], "骑": ["qi", "ji"],
      "衰": ["shuai", "cui"], "斜": ["xie", "xia"], "亡": ["wang", "wu"], "属": ["shu", "zhu"],
      "传": ["chuan", "zhuan"], "露": ["lu", "lou"], "绿": ["lv", "lu"], "2": ["liang"],
    ]
    func reference(_ text: String, _ c: Character) -> Int {
      let reading: String?
      switch c {
      case "说" where text.contains("不亦说乎"): reading = "yue"
      case "行" where text.contains("一行白鹭"): reading = "hang"
      case "属" where text.contains("属予"): reading = "zhu"
      case "见" where text.contains("溪桥忽见") || text.contains("风吹草低见牛羊"): reading = "xian"
      case "还" where text.contains("一日还"): reading = "huan"
      case "重" where text.contains("万重山"): reading = "chong"
      case "为" where text.contains("为异客"): reading = "wei"
      default: reading = nil
      }
      if let reading, let id = base[reading] { return id * 8 }
      return code[c] ?? 0
    }
    func heard(_ c: Character) -> Int { code[Self.digits[c] ?? c] ?? 0 }
    // 0: same pronunciation including tone, 1: same syllable, 2: near, 3: different.
    func distance(_ c: Character, _ p: Int, _ q: Int) -> Int {
      guard p != 0, q != 0 else { return 3 }
      let x = p >> 3, y = q >> 3
      if x == y { return p == q ? 0 : 1 }
      if Self.alternatives[c]?.contains(where: { base[$0] == y }) == true { return 1 }
      return near[x] == near[y] ? 2 : 3
    }
  }
  init(rows: [[String]], sounds table: [[String]]) {
    sounds = Sounds(table)
    func entry(_ text: String, _ k: Kind, _ tags: [String]) -> Int? {
      guard (2...22).contains(text.count), text.allSatisfy(SoundShelf.han) else { return nil }
      if let id = byText[text] {
        if lines[id].kind == .credit || k == .idiom { lines[id].kind = k }
        for t in tags where !t.isEmpty && !lines[id].tags.contains(t) && lines[id].tags.count < 16 {
          lines[id].tags.append(t)
        }
        return id
      }
      let id = lines.count
      let a = Array(text)
      byText[text] = id
      lines.append(
        .init(
          text: text, chars: a, phones: a.map { sounds.reference(text, $0) }, kind: k,
          tags: tags.filter { !$0.isEmpty }))
      return id
    }
    for row in rows where row.count == 4 {
      guard let kind = Kind(rawValue: row[0]) else { continue }
      let tag: String
      switch kind {
      case .poem: tag = "古诗 古诗词"
      case .lyric: tag = "诗词 词曲"
      case .prose: tag = "古文 文言文"
      case .idiom: tag = "成语"
      case .saying: tag = "歇后语 俗语"
      case .credit: continue
      }
      let tags = [row[1], row[2], tag].filter { !$0.isEmpty }
      if [.poem, .prose, .lyric].contains(kind) { workTitles.insert(row[1]) }
      var last: Int?, older: Int?
      var separator = ""
      var buf = ""
      var first = true
      let title = entry(row[1], .credit, tags)
      let author = entry(row[2], .credit, tags)
      if let title, let author { links[Self.edge(title, author)] = "" }
      for c in row[3] + "|" {
        if SoundShelf.han(c) {
          buf.append(c)
          continue
        }
        if !buf.isEmpty {
          let id = entry(buf, kind, tags)
          buf = ""
          if let id {
            if let last { links[Self.edge(last, id)] = separator }
            if let last, let older { sequences.insert(.init(a: older, b: last, c: id)) }
            if first {
              for x in [title, author].compactMap({ $0 }) { links[Self.edge(x, id)] = "" }
            }
          }
          older = id == nil ? nil : last; last = id
          first = false
        }
        if c == "|" { last = nil; older = nil }
        separator = c == "—" ? "——" : String(c)
      }
    }
    for (key, separator) in links where !separator.isEmpty {
      let left = Int(key >> 32)
      let right = Int(key & 0xffff_ffff)
      following[left, default: []].append(right)
      preceding[right, default: []].append(left)
    }
    for (id, line) in lines.enumerated() {
      let n = line.chars.count
      for i in Set([0, max(0, n / 2 - 1), n - 2]) where line.phones[i] > 0 && line.phones[i + 1] > 0
      {
        seeds[Self.key(line.phones[i], line.phones[i + 1]), default: []].append(id << 5 | i)
      }
    }
  }
  func words() -> [BuiltinVocabulary.Word] {
    lines.map {
      .init(
        name: $0.text, group: .classical, variants: [], cues: [], flags: "v", tags: $0.tags,
        subject: .arts, section: $0.topic)
    }
  }
  private struct Hit {
    let id: Int, start: Int, end: Int, exact: Int, weak: Int, bad: Int, tones: Int, unchanged: Bool
    var internalGap = 0, far = 0
    var n: Int { end - start - internalGap }
    var anchor: Bool { n >= 4 && weak == 0 && bad == 0 && exact >= max(3, n - 2) }
  }
  struct Piece { let start: Int, end: Int, text: String }
  struct TailProbe: Hashable { let heard: String, line: String }
  struct AdjacentProbe: Hashable { let heard: String, word: String, anchor: String, before: Bool }
  struct Assessment {
    var pairs = Set<AdjacentProbe>()
    var pieces = [Piece](), choices = [ReadingChoice](), tails = Set<TailProbe>()
  }
  private struct Pick { let hit: Hit, score: Int, auto: Bool }
  private static let literalIntent = ["故意写", "故意改", "故意说", "我改编", "我改写", "改编成", "改写成", "恶搞", "特意说", "我说的是", "网名", "不要纠正", "不要改", "原样保留", "保留原字", "逐字记录"]
  static func verbatim(_ lead: String) -> Bool {
    literalIntent.contains(where: WordContext.fresh(String(lead.suffix(42))).contains)
  }
  func assess(
    _ text: String, enabled: Set<String>, bias: WordBias, final: Bool, suggest: Bool = false,
    previous: String = "", probeTail: Bool = false, probePair: Bool = false,
    hanAlphabet: Set<Character>? = nil, titleMarkers: [String: String] = [:], quoteLead: String? = nil,
    decoderLayout: Bool = false
  ) -> Assessment {
    var result = Assessment()
    guard !lines.isEmpty, !text.isEmpty else { return result }
    let a = Array(text)
    let count = a.count
    guard count >= 2 else { return result }
    let phones = a.map { sounds.heard($0) }
    var hits = [Hit](), starts = [Int: [Int]](), ends = [Int: [Int]]()
    func comma(_ c: Character) -> Bool { "，,、".contains(c) }
    func soft(_ c: Character) -> Bool { comma(c) || c == " " }
    // Work in spoken syllables, but retain the original character offsets for editing.
    // Only one soft separator can fall inside a clause; a paragraph, quotation, literal,
    // or multi-digit number always cuts the search. No character may be inserted or skipped.
    var slots = [Int](), seen = Set<UInt64>()
    func scan() {
      defer { slots.removeAll(keepingCapacity: true); seen.removeAll(keepingCapacity: true) }
      guard slots.count >= 2 else { return }
      for i in 0..<(slots.count - 1) {
        for pointer in seeds[Self.key(phones[slots[i]], phones[slots[i+1]])] ?? [] {
          let id = pointer >> 5, b = i - (pointer & 31), line = lines[id], n = line.chars.count
          guard b >= 0, b + n <= slots.count, seen.insert(Self.edge(b, id)).inserted else { continue }
          let s = slots[b], e = slots[b+n-1] + 1, gapSize = e-s-n
          var exact = 0, weak = 0, bad = 0, tones = 0, far = 0
          if gapSize > 0 {
            guard gapSize <= 3, n >= 4, line.kind != .credit,
              a[s..<e].filter({ comma($0) }).count <= 1 else { continue }
          }
          for j in 0..<n {
            let pos = slots[b+j], c = a[pos], target = line.chars[j]
            if c == target { exact += 1; continue }
            switch sounds.distance(c, phones[pos], line.phones[j]) {
            case 0: break
            case 1: tones += 1
            case 2: weak += 1
            default:
              bad += 1
              if sounds.broad[phones[pos] >> 3] != sounds.broad[line.phones[j] >> 3] { far += 1 }
            }
            if weak + bad > 2 { break }
          }
          guard weak + bad <= 2, bad <= (final ? 2 : 1), exact >= 1 || (bad + weak == 0 && n >= 4),
            enabled.contains(line.text), exact == n || !bias.discourages(line.text) else { continue }
          if n <= 3 && exact < n && (line.kind != .credit && line.kind != .saying || bad + weak > 0) { continue }
          let h = Hit(id: id, start: s, end: e, exact: exact, weak: weak, bad: bad, tones: tones,
            unchanged: exact == n, internalGap: gapSize, far: far)
          starts[s, default: []].append(hits.count); ends[e, default: []].append(hits.count); hits.append(h)
        }
      }
    }
    for i in a.indices {
      if soft(a[i]) { continue }
      let digit = Sounds.digits[a[i]] != nil
      func asciiWord(_ j: Int) -> Bool { a.indices.contains(j) && a[j].isASCII && (a[j].isLetter || a[j].isNumber) }
      if phones[i] != 0 && !(digit && (asciiWord(i-1) || asciiWord(i+1))) { slots.append(i) }
      else { scan() }
    }
    scan()
    guard !hits.isEmpty else { return result }
    func gap(_ c: Character) -> Bool { c.isWhitespace || "，。！？、；：,.!?;:—-".contains(c) }
    func before(_ s: Int) -> Int {
      var j = s
      while j > 0 && s - j < 5 && gap(a[j - 1]) { j -= 1 }
      return j
    }
    func after(_ e: Int) -> Int {
      var j = e
      while j < count && j - e < 5 && gap(a[j]) { j += 1 }
      return j
    }
    // Prior text is supplied only by the app's existing same-conversation preference.
    // It can corroborate the first spoken clause; it can never supply text to insert.
    let tail = previous.trimmingCharacters(
      in: .whitespacesAndNewlines.union(.punctuationCharacters))
    let priorIDs =
      tail.count >= 4
      ? (4...min(22, tail.count)).compactMap { byText[String(tail.suffix($0))] }.filter {
        enabled.contains(lines[$0].text)
      } : []
    func linked(_ h: Hit) -> Bool {
      if before(h.start) == 0 && priorIDs.contains(where: { links[Self.edge($0, h.id)] != nil }) {
        return true
      }
      func reliable(_ other: Hit) -> Bool {
        other.anchor
          || (h.weak + h.bad == 0 && other.n >= 4 && other.exact >= max(3, other.n - 1)
            && other.weak + other.bad <= 1)
          || (min(h.n, other.n) >= 6 && h.exact >= h.n-2 && other.exact >= other.n-2
            && h.bad + other.bad == 0 && max(h.weak, other.weak) <= 1)
      }
      if (ends[before(h.start)] ?? []).contains(where: {
        let t = hits[$0]
        return reliable(t) && links[Self.edge(t.id, h.id)] != nil
      }) {
        return true
      }
      return (starts[after(h.end)] ?? []).contains { ix in
        let t = hits[ix]
        guard links[Self.edge(h.id, t.id)] != nil else { return false }
        if reliable(t) { return true }
        // A short author's name can bridge a title and the actual opening line. A title
        // or a name alone cannot validate another name.
        return lines[h.id].kind == .credit && lines[t.id].kind == .credit && t.exact >= 2
          && t.bad + t.weak == 0
          && (starts[after(t.end)] ?? []).contains {
            let u = hits[$0]
            return u.anchor && links[Self.edge(t.id, u.id)] != nil
          }
      }
    }
    // Count distinct observations, not the fame of a poem. Two neighbours are evidence
    // only if their order occurs in a *single* source, including two on the same side.
    func witnessCount(_ h: Hit) -> Int {
      func genuine(_ i: Int) -> Bool {
        let x = hits[i]; return x.anchor && lines[x.id].kind != .credit && (x.unchanged || x.exact >= x.n-1)
      }
      func left(_ x: Hit) -> [Hit] { (ends[before(x.start)] ?? []).filter(genuine).map { hits[$0] } }
      func right(_ x: Hit) -> [Hit] { (starts[after(x.end)] ?? []).filter(genuine).map { hits[$0] } }
      let l = left(h).filter { links[Self.edge($0.id, h.id)] != nil }, r = right(h).filter { links[Self.edge(h.id, $0.id)] != nil }
      let prior = before(h.start) == 0 ? priorIDs.filter { lines[$0].kind != .credit } : []
      func triple(_ x: Int, _ y: Int, _ z: Int) -> Bool { sequences.contains(.init(a: x, b: y, c: z)) }
      for x in r {
        if l.contains(where: { triple($0.id, h.id, x.id) }) || prior.contains(where: { triple($0, h.id, x.id) })
          || right(x).contains(where: { triple(h.id, x.id, $0.id) }) { return 2 }
      }
      for x in l where left(x).contains(where: { triple($0.id, x.id, h.id) }) { return 2 }
      return l.isEmpty && r.isEmpty && !prior.contains(where: { links[Self.edge($0, h.id)] != nil }) ? 0 : 1
    }
    // Rare parallel prose may have no three-character literal anchor. Three different,
    // consecutive clauses in one edition can witness one another if all their syllables
    // are present in order. Never chain our own substitutions into a new observation.
    var concordant = Set<Int>()
    if final {
      func usable(_ h: Hit) -> Bool {
        (4...12).contains(h.n) && h.bad == 0 && h.weak <= 1
          && [.prose, .poem, .lyric].contains(lines[h.id].kind)
      }
      func joined(_ x: Hit, _ y: Hit) -> Bool {
        a[x.end..<y.start].allSatisfy { " ，,。.;；、".contains($0) || (decoderLayout && $0.isNewline) }
      }
      for (j, mid) in hits.enumerated() where usable(mid) {
        let l = ends[before(mid.start)] ?? [], r = starts[after(mid.end)] ?? []
        if l.isEmpty || r.isEmpty { continue }
        for i in l where usable(hits[i]) && joined(hits[i], mid) {
          let x = hits[i]
          guard links[Self.edge(x.id,mid.id)] != nil else { continue }
          for k in r where usable(hits[k]) && joined(mid, hits[k]) {
            let z = hits[k]
            guard x.id != mid.id, mid.id != z.id, x.id != z.id,
              sequences.contains(.init(a:x.id,b:mid.id,c:z.id)), x.weak+mid.weak+z.weak <= 1,
              x.exact+mid.exact+z.exact >= max(3,(x.n+mid.n+z.n)/4),
              [x,mid,z].filter({ $0.exact > 0 }).count >= 2,
              x.start == 0 || gap(a[x.start-1]) || z.end == count || gap(a[z.end]) else { continue }
            concordant.formUnion([i,j,k])
          }
        }
      }
    }
    // A familiar second half can locate a garbled first half (or vice versa). It may
    // request a second hearing, never a text-only replacement or an unsaid continuation.
    // Only a short utterance consisting of those two clauses is eligible for this pass.
    if probePair, count <= 50, a.allSatisfy({ SoundShelf.han($0) || gap($0) }),
      let first = a.firstIndex(where: SoundShelf.han), let last = a.lastIndex(where: SoundShelf.han) {
      let end = last + 1
      for h in hits where h.anchor && h.n >= 4 && h.exact >= h.n - 1 && h.start >= first && h.end <= end {
        let anchor = lines[h.id]
        for prefix in [true, false] where prefix ? h.end == end : h.start == first {
          let s = prefix ? first : after(h.end), e = prefix ? before(h.start) : end
          guard s < e, (3...16).contains(e - s), a[s..<e].allSatisfy(SoundShelf.han) else { continue }
          let heard = String(a[s..<e])
          guard byText[heard] == nil, !enabled.contains(heard),
            !BuiltinVocabulary.identity(String(a[..<s]), String(a[e...])) else { continue }
          for id in (prefix ? preceding[h.id] : following[h.id]) ?? [] {
            let target = lines[id], n = target.chars.count
            guard n >= 4, abs(n - (e - s)) <= (prefix ? 1 : 0), enabled.contains(target.text), !bias.discourages(target.text),
              a[s] == target.chars[0] || a[e - 1] == target.chars[n - 1] else { continue }
            result.pairs.insert(.init(heard: heard, word: target.text, anchor: anchor.text, before: prefix))
          }
        }
      }
    }
    let cues = [
      "诗句", "古诗", "背诗", "诗中", "诗云", "吟诵", "背诵", "朗诵", "文言文", "古文", "成语", "歇后语", "俗话说", "子曰", "诗曰",
    ]
    // The partial decoder can join the first words of the next clause onto a short one.
    // Use only syllables already on screen to keep an agreed spelling stable. Do not
    // output any part of the next clause from this evidence.
    func standaloneOrOpening(_ h: Hit) -> Bool {
      guard before(h.start) == 0 else { return false }
      let s = after(h.end)
      if s == count { return true }
      guard a[h.end..<s].allSatisfy({ comma($0) || $0 == " " }) else { return false }
      var e = s
      while e < count && e - s < 22 && SoundShelf.han(a[e]) { e += 1 }
      guard e > s, after(e) == count else { return false }
      return (following[h.id] ?? []).contains { id in
        let next = lines[id]
        guard e - s < next.chars.count, enabled.contains(next.text), !bias.discourages(next.text) else { return false }
        return (s..<e).allSatisfy { pos in
          a[pos] == next.chars[pos-s] || sounds.distance(a[pos], phones[pos], next.phones[pos-s]) == 0
        }
      }
    }
    var picks = [Int: [Pick]]()
    for (hitIndex,h) in hits.enumerated() {
      let line = lines[h.id]
      let n = h.n
      if h.unchanged {
        if h.internalGap > 0 && !linked(h) && n < 8 { continue }
        if (n < 4 || line.kind == .credit) && !linked(h) { continue }
        picks[h.start, default: []].append(.init(hit: h, score: 100 + 4 * n, auto: true))
        continue
      }
      let isolated = (h.start == 0 || gap(a[h.start - 1])) && (h.end == count || gap(a[h.end]))
      let left = WordContext.fresh(String((quoteLead ?? "").suffix(max(0, 48-h.start))) + String(a[max(0, h.start-48)..<h.start]))
      let right = String(a[h.end..<min(count, h.end + 12)])
      if BuiltinVocabulary.identity(left, right) || Self.verbatim(left)
        || ["是我的网名", "是我的笔名", "这几个字不改"].contains(where: { right.trimmingCharacters(in: .punctuationCharacters).hasPrefix($0) })
      {
        continue
      }
      let explicit =
        cues.contains(where: left.suffix(12).contains)
        || ["这句", "那一句", "这首诗"].contains(where: right.hasPrefix)
      let pair = linked(h)
      let heard = String(a[h.start..<h.end])
      // A different attested line/idiom is a reading, not a typo. Context may offer a
      // different reading to review but may not replace it, even when the poem is known.
      let plain = h.internalGap == 0 ? heard : heard.filter { !soft($0) }
      let attested = byText[plain] != nil || enabled.contains(plain)
      let close = h.weak + h.bad == 0
      let literary = [.poem, .lyric, .prose].contains(line.kind)
      let named = literary && line.tags.contains { t in
        workTitles.contains(t) && (left.contains("《" + t + "》")
          || left.hasSuffix(t) || (cues.contains(where: left.contains) && left.contains(t))
          || titleMarkers.contains(where: { $0.value == t && left.contains($0.key) }))
      }
      let witnesses = literary && pair ? witnessCount(h) : 0
      let backed = witnesses + (named ? 1 : 0)
      let boundary = isolated || named || explicit || pair
      // At least one *changed* syllable must agree or be acoustically close. An unrelated
      // word does not become the book's version simply because the next two lines match.
      let compatibleChange = n-h.exact > h.far
      let strongLine = literary && n >= 8 && boundary && h.exact >= (2*n+2)/3 && h.far <= 1
        && h.weak + h.bad <= 2 && compatibleChange
      if quoteLead != nil && !explicit && !named && witnesses == 0 && !strongLine && !concordant.contains(hitIndex) { continue }
      let inPassage = literary && final && n >= 4 && h.exact >= (n+1)/2 && compatibleChange &&
        ((backed >= 2 && h.far <= 1 && h.weak + h.bad <= 2) ||
         (backed >= 1 && h.far == 0 && h.weak + h.bad <= 1) ||
         (witnesses == 1 && n >= 5 && h.far == 1 && h.exact >= n-2 && h.bad == 1 && h.weak == 0))
      let independent: Bool
      var shortOOV = false
      switch line.kind {
      case .credit: independent = false
      case .saying, .idiom:
        independent = close && h.exact >= max(3, n - 1) && (isolated || explicit || n >= 6)
      case .poem, .lyric, .prose:
        // Isolated four-character prose usually stays a suggestion. The one exception is
        // a unique same-tone reading whose one changed glyph the active decoder
        // cannot emit. An arbitrary four-character substring of a conversation never qualifies.
        shortOOV = n == 4 && close && h.tones == 0 && h.exact == 3 && h.internalGap == 0
          && hanAlphabet.map { letters in
            line.chars.enumerated().contains { j, c in a[h.start+j] != c && !letters.contains(c) }
          } == true
          && (named || explicit || standaloneOrOpening(h) || (final && isolated && before(h.start) == 0 && h.end < count && comma(a[h.end])))
          && !(starts[h.start] ?? []).contains { ix in
            let rival = hits[ix]; return rival.id != h.id && rival.end == h.end && rival.exact >= 3
              && rival.bad + rival.weak + rival.tones == 0
          }
        independent = shortOOV || strongLine || inPassage || concordant.contains(hitIndex) || (n >= 5 && close && h.exact >= max(3, (2 * n + 2) / 3) && (isolated || explicit || named))
      }
      let confirmed =
        pair && h.bad == 0 && (close || (h.weak == 1 && h.exact >= max(1, n / 3)))
        && (n >= 4
          || (n >= 2 && (line.kind == .credit || line.kind == .saying) && h.exact >= n - 1))
      let automatic =
        !attested && (independent || confirmed)
        && (final || shortOOV || (n >= 5 && h.exact >= n - 1 && close && (h.end < count || pair))
          || (pair && n >= 4 && h.exact >= n - 1 && close) || (h.internalGap > 0 && confirmed))
      let idiomList =
        suggest && line.kind == .idiom && isolated
        && ((ends[before(h.start)] ?? []) + (starts[after(h.end)] ?? [])).contains {
          let other = hits[$0]
          return lines[other.id].kind == .idiom && (other.unchanged || (other.anchor && other.exact >= other.n - 1))
        }
      let originalSupported =
        attested
        && (starts[h.start] ?? []).contains {
          let exact = hits[$0]
          return exact.unchanged && exact.end == h.end && linked(exact)
        }
      let optional =
        suggest && final && !originalSupported && (!attested || (close && pair))
        && (pair && h.exact >= max(1, n / 3) && (h.bad + h.weak <= 1 || (backed >= 2 && h.far <= 1))
          || (isolated || explicit) && n >= 4 && close && h.exact >= max(2, n / 2)
          || idiomList && h.bad + h.weak <= 1 && h.exact >= 1)
      guard automatic || optional else { continue }
      let score =
        4 * n + 5 * h.exact + (concordant.contains(hitIndex) ? 16 : 0) + (pair ? 13 : 0) + (explicit ? 3 : 0) - 5 * h.weak - 12 * h.bad
        - h.tones - 6 * h.far + min(2, backed) * 5
      picks[h.start, default: []].append(.init(hit: h, score: score, auto: automatic))
    }
    func choice(_ h: Hit) {
      guard result.choices.count < 8 else { return }
      let heard = String(a[h.start..<h.end])
      let name = lines[h.id].text
      var c = ReadingChoice(heard: heard, word: name)
      if c.applying(to: text) == nil {
        c.left = String(a[max(0, h.start - 5)..<h.start])
        c.right = String(a[h.end..<min(count, h.end + 5)])
      }
      if c.applying(to: text) != nil && !result.choices.contains(c) { result.choices.append(c) }
    }
    var cursor = 0
    var prev: Hit?
    for s in picks.keys.sorted() where s >= cursor {
      guard var list = picks[s] else { continue }
      // Prefer the whole attested line over a shorter exact fragment nested in it. Never
      // displace a longer exact match just because a shorter line has an adjacent witness.
      list.sort { x, y in
        x.hit.n != y.hit.n
          ? x.hit.n > y.hit.n : x.score != y.score ? x.score > y.score : x.hit.id < y.hit.id
      }
      if suggest { for p in list where !p.auto { choice(p.hit) } }
      guard let winner = list.first(where: { $0.auto }) else { continue }
      let h = winner.hit
      if !h.unchanged,
        let other = list.first(where: {
          $0.hit.end == h.end && $0.hit.id != h.id && $0.score >= winner.score - 3
        })
      {
        if suggest {
          choice(h)
          choice(other.hit)
        }
        continue
      }
      if let p = prev, after(p.end) == h.start, let mark = links[Self.edge(p.id, h.id)], !mark.isEmpty,
        p.n >= 3 && h.n >= 3 || mark == "——"
      {
        let existing = String(a[p.end..<h.start])
        let recordedBreak = decoderLayout && final && [.poem,.lyric,.prose].contains(lines[h.id].kind)
          && [.poem,.lyric,.prose].contains(lines[p.id].kind) && min(h.n,p.n) >= 4
          && h.exact >= h.n-2 && p.exact >= p.n-2 && h.far+p.far <= 1
          && existing.allSatisfy { $0.isWhitespace || "，。.,；;".contains($0) }
        if recordedBreak && existing != mark || (p.anchor || h.anchor) && !existing.contains(where: \.isNewline) && (
          existing.trimmingCharacters(in: .whitespaces).isEmpty
          || ["，", ",", "、"].contains(existing.trimmed) && existing.trimmed != mark
          || (mark == "——" && existing.trimmed == "—"))
        {
          result.pieces.append(.init(start: p.end, end: h.start, text: mark))
        }
      }
      result.pieces.append(.init(start: h.start, end: h.end, text: lines[h.id].text))
      prev = h
      cursor = h.end
    }
    // A reciter can stop in the middle of a line. Only seek a fragment at the observed
    // edge of its real neighbour; fix at most one homophone in the words actually heard.
    // Never add the absent end. Conflicting witnesses and occupied spans are left alone.
    var occupied = Array(repeating: false, count: count)
    var fragments = [UInt64: Set<String>]()
    for piece in result.pieces { for j in piece.start..<piece.end { occupied[j] = true } }
    func edgeFragment(_ id: Int, at boundary: Int, forward: Bool) {
      let line = lines[id]
      let full = line.chars.count
      guard (5...18).contains(full), enabled.contains(line.text), !bias.discourages(line.text)
      else { return }
      for n in max(4, full - 2)..<full {
        let s = forward ? boundary : boundary - n
        let e = s + n
        guard s >= 0, e <= count, forward ? (e == count || gap(a[e])) : (s == 0 || gap(a[s - 1])),
          !occupied[s..<e].contains(true), a[s..<e].allSatisfy(SoundShelf.han)
        else { continue }
        let heard = String(a[s..<e])
        guard byText[heard] == nil, !enabled.contains(heard), !Self.verbatim(String(a[max(0, s-42)..<s])),
          !BuiltinVocabulary.identity(
            String(a[max(0, s - 18)..<s]), String(a[e..<min(count, e + 10)]))
        else { continue }
        for offset in [0, full - n] {
          let changes = (0..<n).filter { a[s + $0] != line.chars[offset + $0] }
          guard changes.count <= 1, changes.allSatisfy({ j in
            phones[s + j] >> 3 != 0 && phones[s + j] >> 3 == line.phones[offset + j] >> 3
          }) else { continue }
          let word = String(line.chars[offset..<offset + n])
          guard !bias.discourages(word) else { continue }
          if probeTail, forward, offset == 0, full == n + 1, after(e) == count {
            // Nominate for listening only. No lexical method may insert the missing syllable.
            result.tails.insert(.init(heard: heard, line: line.text))
          }
          if !changes.isEmpty { fragments[Self.edge(s, e), default: []].insert(word) }
        }
      }
    }
    for h in hits where h.anchor && h.n >= 4 {
      let before = before(h.start)
      let after = after(h.end)
      if before >= 4 {
        for id in preceding[h.id] ?? [] { edgeFragment(id, at: before, forward: false) }
      }
      if after + 4 <= count {
        for id in following[h.id] ?? [] { edgeFragment(id, at: after, forward: true) }
      }
    }
    if !fragments.isEmpty {
      for key in fragments.keys.sorted() {
        let s = Int(key >> 32)
        let e = Int(key & 0xffff_ffff)
        guard let words = fragments[key], words.count == 1, let word = words.first,
          !occupied[s..<e].contains(true)
        else { continue }
        result.pieces.append(.init(start: s, end: e, text: word))
        for j in s..<e { occupied[j] = true }
      }
      result.pieces.sort { $0.start != $1.start ? $0.start < $1.start : $0.end < $1.end }
    }
    // Two consecutive badly heard lines may have no exact sound pair to seed a search.
    // Walk back (or forward) from an actually read line; require a single edition's
    // triple, sufficient audible syllables on BOTH spans and a literal run. These are
    // review choices only, never new text or an automatic completion of the quotation.
    if final && suggest && result.choices.count < 8 {
      var proposals = [UInt64: [Int: (Hit, Int)]]()
      func observed(_ id: Int, from boundary: Int, forward: Bool) -> Hit? {
        let line = lines[id], n = line.chars.count
        guard (4...14).contains(n), enabled.contains(line.text), !bias.discourages(line.text) else { return nil }
        let s = forward ? after(boundary) : before(boundary)-n, e = s+n
        guard s >= 0, e <= count, a[s..<e].allSatisfy(SoundShelf.han) else { return nil }
        var lit = 0, far = 0, weak = 0, bad = 0, tones = 0
        for j in 0..<n {
          if a[s+j] == line.chars[j] { lit += 1; continue }
          switch sounds.distance(a[s+j], phones[s+j], line.phones[j]) {
          case 0: break
          case 1: tones += 1
          case 2: weak += 1
          default:
            bad += 1
            if sounds.broad[phones[s+j] >> 3] != sounds.broad[line.phones[j] >> 3] { far += 1 }
          }
        }
        guard lit >= max(1, n/4), far <= min(2, n/2), n-bad-weak >= min(2, n-2) else { return nil }
        return .init(id:id, start:s, end:e, exact:lit, weak:weak, bad:bad, tones:tones, unchanged:lit == n, far:far)
      }
      func propose(_ h: Hit, weight: Int) {
        guard !h.unchanged, !occupied[h.start..<h.end].contains(true) else { return }
        let surface = String(a[h.start..<h.end]), left = String(a[max(0,h.start-42)..<h.start])
        guard !enabled.contains(surface), byText[surface] == nil, !Self.verbatim(left),
          !BuiltinVocabulary.identity(left, String(a[h.end..<min(count,h.end+12)])) else { return }
        let key = Self.edge(h.start,h.end)
        if weight > (proposals[key]?[h.id]?.1 ?? Int.min) { proposals[key, default: [:]][h.id] = (h,weight) }
      }
      for anchor in hits where anchor.n >= 4 && anchor.unchanged && [.poem,.lyric,.prose].contains(lines[anchor.id].kind) {
        for forward in [false,true] {
          let adjacent = forward ? following : preceding
          for m in adjacent[anchor.id] ?? [] {
            guard let mid = observed(m, from:forward ? anchor.end : anchor.start, forward:forward) else { continue }
            for t in adjacent[m] ?? [] {
              let sequence = forward ? Sequence(a:anchor.id,b:m,c:t) : Sequence(a:t,b:m,c:anchor.id)
              guard sequences.contains(sequence), let tip = observed(t, from:forward ? mid.end : mid.start, forward:forward),
                mid.exact + tip.exact >= (mid.n+tip.n)*2/5, max(mid.exact,tip.exact) >= 3,
                5*(mid.far+tip.far) <= 2*(mid.n+tip.n) else { continue }
              let weight = 5*(mid.exact+tip.exact) - 4*(mid.far+tip.far) - mid.bad-tip.bad
              propose(mid, weight:weight); propose(tip, weight:weight)
            }
          }
        }
      }
      for k in proposals.keys.sorted() {
        let ranked = proposals[k]!.values.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.id < $1.0.id }
        if let first = ranked.first, ranked.count == 1 || first.1 >= ranked[1].1 + 3 { choice(first.0) }
      }
    }
    return result
  }
}

extension ClassicalCorpus {
  // The decoder can reset while a strong last syllable is still buffered. Both unprompted
  // reads must actually emit the missing character and align with the preceding syllables.
  // Refusing an absent/different last word is just as important as recovering a quiet one.
  func heardTail(_ original: String, probes: Set<TailProbe>, votes: [String]) -> String? {
    guard votes.count == 2, !probes.isEmpty else { return nil }
    let reads = votes.map { Array($0.filter { $0.isLetter || $0.isNumber }) }
    let body = original.trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
    var endings = Set<Character>()
    for probe in probes where body.hasSuffix(probe.heard) {
      guard let id = byText[probe.line], let end = probe.line.last else { continue }
      let line = lines[id], n = line.chars.count
      let costs = reads.compactMap { read -> Int? in
        guard read.count >= n, read.last == end else { return nil }
        let prefix = read.suffix(n).dropLast()
        var near = 0, exact = 0
        for (j, c) in prefix.enumerated() {
          let p = sounds.heard(c) >> 3, q = line.phones[j] >> 3
          guard p != 0, q != 0 else { return nil }
          if p != q {
            guard sounds.near[p] == sounds.near[q] else { return nil }
            near += 1
          }
          if c == line.chars[j] { exact += 1 }
        }
        return near <= 1 && exact >= max(2, prefix.count - 2) ? near : nil
      }
      if costs.count == 2, costs.min() == 0 { endings.insert(end) }
    }
    return endings.count == 1 ? endings.first.map(String.init) : nil
  }
  // Compare with two reads from the *same unprompted audio*, including the neighbour.
  // Equal syllable counts in both reads protect pauses and clipped/half-spoken sayings.
  // One read must support the whole pronunciation; the other must independently retain
  // its length, most characters, and the same surrounding clause. Competing readings veto.
  func confirmedPair(_ original: String, probes: Set<AdjacentProbe>, votes: [String]) -> String {
    guard votes.count == 2, !probes.isEmpty else { return original }
    let reads = votes.map { Array($0.filter { $0.isLetter || $0.isNumber }) }
    var accepted = Set<String>()
    for p in probes {
      guard let ti = byText[p.word], let ai = byText[p.anchor] else { continue }
      let t = lines[ti], a = lines[ai], n = t.chars.count, m = a.chars.count
      let scores = reads.compactMap { r -> (phonetic: Int, literal: Int)? in
        guard r.count == n + m else { return nil }
        let other = p.before ? r.suffix(m) : r.prefix(m)
        guard zip(other, a.phones).allSatisfy({ c, q in q >> 3 != 0 && sounds.heard(c) >> 3 == q >> 3 }),
          zip(other, a.chars).filter(==).count >= m - 1 else { return nil }
        let reading = p.before ? r.prefix(n) : r.suffix(n)
        return (zip(reading, t.phones).filter { c, q in q >> 3 != 0 && sounds.heard(c) >> 3 == q >> 3 }.count,
                zip(reading, t.chars).filter(==).count)
      }
      guard scores.count == 2,
        scores.contains(where: { $0.phonetic == n && $0.literal >= n - 1 }),
        scores.allSatisfy({ $0.phonetic == n || (n >= 5 && $0.literal >= max(3, n - 2)) }),
        let revised = ReadingChoice(heard: p.heard, word: p.word).applying(to: original) else { continue }
      accepted.insert(revised)
    }
    return accepted.count == 1 ? accepted.first! : original
  }
  // For uncertain short clauses consult two *unprompted* readings of the same waveform.
  // Compare the aligned syllables, not exact spelling: some rare target characters do not
  // exist in the recognizer's output alphabet. Outside the nominated span nothing changes.
  func confirmed(_ original: String, choices: [ReadingChoice], votes: [String]) -> String {
    guard votes.count == 2 else { return original }
    func chars(_ s: String) -> [Character] { Array(s.filter { $0.isLetter || $0.isNumber }) }
    let raw = chars(original)
    let reads = votes.map(chars)
    guard !raw.isEmpty, reads.allSatisfy({ $0.count == raw.count }) else { return original }
    var accepted = [ReadingChoice]()
    for c in choices.prefix(6) {
      guard let id = byText[c.word], let revised = c.applying(to: original) else { continue }
      let candidate = chars(revised)
      let target = lines[id]
      guard candidate.count == raw.count,
        let first = candidate.indices.first(where: { candidate[$0] != raw[$0] })
      else { continue }
      let heard = Array(c.heard)
      guard heard.count == target.chars.count,
        let offset = heard.indices.first(where: { heard[$0] != target.chars[$0] })
      else { continue }
      let s = first - offset
      let e = s + target.chars.count
      guard s >= 0, e <= raw.count else { continue }
      func supports(_ read: [Character]) -> Bool {
        // Both adjacent boundaries must align. A shifted reading never attests a particular span.
        for i in [s - 1, e] where raw.indices.contains(i) && raw[i] != read[i] {
          if sounds.heard(raw[i]) >> 3 != sounds.heard(read[i]) >> 3 { return false }
        }
        var improved = false
        for j in target.chars.indices {
          let t = target.chars[j]
          let q = target.phones[j] >> 3
          let b = raw[s + j]
          let r = read[s + j]
          if r == t {
            if b != t { improved = true }
            continue
          }
          guard q != 0, sounds.heard(r) >> 3 == q else { return false }
          if b != t && r != b && sounds.heard(b) >> 3 != q { improved = true }
        }
        return improved
      }
      if reads.allSatisfy(supports) { accepted.append(c) }
    }
    var out = original
    for c in accepted where !accepted.contains(where: { $0.heard == c.heard && $0.word != c.word })
    { if let next = c.applying(to: out) { out = next } }
    return out
  }
}

extension ClassicalCorpus {
  // On explicit replay, an adjacent pair from the same work can identify sounds which an
  // unprompted decoder cannot spell. Its position and sounds must also match the recording.
  // Never infer a missing line: each candidate consumes exactly one observed syllable per glyph.
  struct RecitedPair {
    let key: UInt64, start: Int, first: String, second: String, score: Int, separator: String
    var end: Int { start + first.count + second.count }
  }
  func recitedPairs(in chars: [Character], enabled: Set<String>, bias: WordBias) -> [RecitedPair] {
    guard chars.count >= 7 else { return [] }
    let phones = chars.map(sounds.heard)
    struct Fit { let score: Int, exact: Int, far: Int, near: Int, count: Int }
    func fit(_ id:Int, _ start:Int) -> Fit? {
      let line=lines[id], n=line.chars.count
      guard (3...16).contains(n), start>=0, start+n<=chars.count, [.poem,.lyric,.prose,.saying].contains(line.kind),
        enabled.contains(line.text), !bias.discourages(line.text) else { return nil }
      var exact=0, near=0, far=0, score=0
      for j in 0..<n {
        let c=chars[start+j]; guard SoundShelf.han(c) else {return nil}
        if c==line.chars[j] { exact+=1; score+=6; continue }
        switch sounds.distance(c,phones[start+j],line.phones[j]) {case 0:score+=4;case 1:score+=3;case 2:near+=1;score+=1;default:if replayClose(c,line.chars[j]) {near+=1;score+=1} else {far+=1;score-=3}}
        if far>1 || near+far>max(1,n/3) {return nil}
      }
      return Fit(score:score,exact:exact,far:far,near:near,count:n)
    }
    var found=[RecitedPair](), seen=Set<UInt64>()
    for i in 0..<(chars.count-1) where phones[i]>0 && phones[i+1]>0 {
      for seed in seeds[Self.key(phones[i],phones[i+1])] ?? [] {
        let id=seed>>5, start=i-(seed&31); guard start>=0, seen.insert(Self.edge(start,id)).inserted,
          let anchor=fit(id,start), anchor.far==0, anchor.exact >= max(2,anchor.count/2) else {continue}
        for forward in [true,false] {
          for neighbour in (forward ? following[id] : preceding[id]) ?? [] {
            let otherStart=forward ? start+anchor.count : start-lines[neighbour].chars.count
            guard let other=fit(neighbour,otherStart), other.score>=other.count*2, other.far==0 || anchor.exact>=3 && other.exact>=1,
              anchor.exact+other.exact>=max(3,(anchor.count+other.count)/3) else {continue}
            let a=forward ? id:neighbour, b=forward ? neighbour:id, edge=Self.edge(a,b)
            found.append(.init(key:edge,start:min(start,otherStart),first:lines[a].text,second:lines[b].text,
              score:anchor.score+other.score,separator:links[edge] ?? ""))
          }
        }
      }
    }
    // Two equally good editions at the same location are not an automatic correction.
    return Dictionary(grouping:found){ Self.edge($0.start,$0.end) }.values.compactMap { group in
      let best=group.max{$0.score<$1.score}!
      return group.contains{$0.key != best.key && $0.score>=best.score-3} ? nil : best
    }.sorted{$0.start != $1.start ? $0.start<$1.start : $0.score>$1.score}
  }
}

extension ClassicalCorpus {
  // The pronunciation table also indexes ordinary vocabulary; it does not enable the literary shelf.
  func syllable(_ c:Character) -> Int { sounds.heard(c)>>3 }
  func replayClose(_ heard:Character,_ target:Character)->Bool {
    if heard==target{return true};let a=sounds.heard(heard),b=sounds.heard(target)
    return a>0 && b>0 && (sounds.distance(heard,a,b)<=2 || sounds.broad[a>>3]==sounds.broad[b>>3])
  }
}
