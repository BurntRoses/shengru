import Foundation

// Shelf switches take precedence over surviving source-pack preferences. This permits
// splitting one old pack between art and public affairs without turning on its neighbours.
struct WordPolicy: Codable, Equatable {
  private typealias G = BuiltinVocabulary.Group
  private static let industry = Set(G.allCases.filter(\.industry).map(\.rawValue))
  var disabled = Set<String>(), hidden = Set<String>(), blocked = [String]()
  private var shelves: [String: Bool] = [:]
  private var knownPacks = Set(G.allCases.map(\.rawValue))
  init() {}
  private static func inherited(known: Set<String>, off: Set<String>) -> Set<String> {
    var result = off.union(industry.subtracting(known))
    for (pack, parents) in G.previousShelves where !known.contains(pack.rawValue) && parents.allSatisfy({ result.contains($0.rawValue) }) { result.insert(pack.rawValue) }
    if !known.contains(G.dailyLife.rawValue), [G.style, .food, .travel, .sport, .phrases].allSatisfy({ result.contains($0.rawValue) }) { result.insert(G.dailyLife.rawValue) }
    // Old installs left all industry packs off by default. That was not a request to
    // disable general recitation. Preserve a genuinely disabled older arts shelf instead.
    if !known.contains(G.classical.rawValue), [G.culture, .media, .literature].allSatisfy({ result.contains($0.rawValue) }) { result.insert(G.classical.rawValue) }
    return result
  }
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let first = Set([G.vibe, .code, .science, .literature, .design, .earth].map(\.rawValue))
    disabled = Self.inherited(known: try c.decodeIfPresent(Set<String>.self, forKey:.knownPacks) ?? first, off: try c.decodeIfPresent(Set<String>.self, forKey:.disabled) ?? first)
    shelves = try c.decodeIfPresent([String: Bool].self, forKey:.shelves) ?? [:]
    hidden = try c.decodeIfPresent(Set<String>.self, forKey:.hidden) ?? []
    blocked = try c.decodeIfPresent([String].self, forKey:.blocked) ?? []
  }
  static var priorDefault: Self {
    var p = Self(); p.shelves = [:]; p.disabled = inherited(known: industry, off: industry); return p
  }
  enum State { case off, mixed, on }
  var hasDisabledWords: Bool { !disabled.isEmpty || shelves.values.contains(false) }
  func subjectState(_ subject: WordSubject) -> State {
    if let v = shelves[subject.collection.rawValue] { return v ? .on : .off }
    if let v = shelves[subject.rawValue] { return v ? .on : .off }
    let source = WordCatalog.shared.sources[subject] ?? [], off = source.filter { disabled.contains($0.rawValue) }.count
    return off == 0 ? .on : off == source.count ? .off : .mixed
  }
  func state(_ shelf: WordCollection) -> State {
    if let v = shelves[shelf.rawValue] { return v ? .on : .off }
    let values = shelf.subjects.map(subjectState)
    return values.allSatisfy { $0 == .on } ? .on : values.allSatisfy { $0 == .off } ? .off : .mixed
  }
  mutating func set(_ shelf: WordCollection, enabled: Bool) { shelves[shelf.rawValue] = enabled }
  mutating func setSubject(_ subject: WordSubject, enabled: Bool) {
    if let parent = shelves.removeValue(forKey: subject.collection.rawValue) {
      for part in subject.collection.subjects { shelves[part.rawValue] = parent }
    }
    shelves[subject.rawValue] = enabled
  }
  mutating func enableAll() { disabled.removeAll(); shelves.removeAll() }
  func uses(_ term: Term) -> Bool {
    guard let pack = term.pack, let shelf = term.collection else { return true }
    if let v = shelves[shelf.rawValue] { return v }
    guard let sub = term.originalSubject else { return state(shelf) != .off }
    if let v = shelves[sub.rawValue] { return v }
    return WordSubject(rawValue: pack) != nil ? subjectState(sub) != .off : !disabled.contains(pack)
  }
  // Old `汉语言文学` was an optional professional hotword pack, usually off by default.
  // Classical proofreading is a separate local witness index, on unless its actual shelf is off.
  var usesClassics: Bool { shelves[WordCollection.humanities.rawValue] ?? shelves[WordSubject.arts.rawValue] ?? !disabled.contains(G.classical.rawValue) }
  func usesPrimarySource(_ word: BuiltinVocabulary.Word) -> Bool {
    (shelves[word.collection.rawValue] ?? shelves[word.originalSubject.rawValue] ?? !disabled.contains(word.group.rawValue)) && !hidden.contains(word.name.lowercased())
  }
  func usesClassicalSource(_ word: BuiltinVocabulary.Word) -> Bool {
    usesClassics && word.classicalTopic != nil && !hidden.contains(word.name.lowercased())
      && (shelves[word.collection.rawValue] ?? shelves[word.originalSubject.rawValue]) != false
  }
  func uses(_ word: BuiltinVocabulary.Word) -> Bool { usesPrimarySource(word) || usesClassicalSource(word) }
}

// This is a preference in candidate ranking, not a display or storage filter.
struct WordBias {
  private struct Node { var edges = [Character: Int](), terminal = false }
  private var nodes = [Node()]
  private var longest=0
  init(_ words: [String]) {
    for w in words where !w.trimmed.isEmpty {
      longest=max(longest,w.trimmed.count); var n = 0
      for c in w.trimmed.lowercased() {
        if let next = nodes[n].edges[c] { n = next } else {
          let next = nodes.count; nodes[n].edges[c] = next; nodes.append(Node()); n = next
        }
      }
      nodes[n].terminal = true
    }
  }
  var isEmpty: Bool { nodes.count == 1 }
  func discourages(_ text: String) -> Bool {
    let a=Array(text.lowercased());return match(a, touching:0..<a.count)
  }
  // Diffs often contain only the changed character of a multi-character word. Test the
  // newly formed word spanning that edit; an unrelated blocked word is still left intact.
  func discouragesChange(_ word:String, left:ArraySlice<Character>, right:ArraySlice<Character>)->Bool {
    guard !isEmpty else{return false};let l=Array(String(left.suffix(longest)).lowercased()),w=Array(word.lowercased()),r=Array(String(right.prefix(longest)).lowercased());return match(l+w+r,touching:l.count..<(l.count+w.count))
  }
  private func match(_ a:[Character],touching span:Range<Int>)->Bool {
    guard !isEmpty else { return false }
    func latin(_ c:Character)->Bool { c.isASCII && (c.isLetter || c.isNumber || c == "_") }
    for i in a.indices where i == 0 || !latin(a[i-1]) || !latin(a[i]) {
      var j = i, n = 0
      while j < a.count, let next = nodes[n].edges[a[j]] {
        n = next; j += 1
        if nodes[n].terminal && i<span.upperBound && j>span.lowerBound && (j == a.count || !latin(a[j-1]) || !latin(a[j])) { return true }
      }
    }
    return false
  }
}
