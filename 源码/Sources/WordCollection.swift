import Foundation

// These are the only three destinations exposed by the library. The six subject IDs below
// are kept intact: they still own the user's earlier switches and imported entries.
enum WordCollection: String, CaseIterable, Identifiable {
  case life = "生活与出行", science = "科学与技术", humanities = "人文与社会"
  var id: Self { self }
  var title: String { rawValue }
  var symbol: String { switch self { case .life: return "basket"; case .science: return "atom"; case .humanities: return "books.vertical" } }
  var subjects: [WordSubject] { WordSubject.allCases.filter { $0.collection == self } }
}
enum WordSubject: String, CaseIterable {
  case daily = "日常生活", places = "地点名称", nature = "自然科学", technology = "技术工程", arts = "人文艺术", civic = "社会事务"
  var collection: WordCollection {
    switch self { case .daily, .places: return .life; case .nature, .technology: return .science; case .arts, .civic: return .humanities }
  }
}

extension BuiltinVocabulary.Group {
  var subject: WordSubject {
    switch self {
    case .nature, .science, .earth, .medical, .farming, .names: return .nature
    case .technology, .tech, .vibe, .code, .design, .civil, .factory, .power: return .technology
    case .classical, .literature, .media, .culture: return .arts
    case .society, .publicLife, .finance, .law, .education, .logistics: return .civic
    case .style, .food, .travel, .sport, .phrases, .dailyLife: return .daily
    case .place, .landmarks: return .places
    }
  }
  // A 1.5 destination might have held several subject areas. Resolve known spellings
  // within that former destination, never reclassify arbitrary user entries by a suffix.
  static let previousShelves: [Self: [Self]] = [
    .nature: [.science, .earth, .medical, .farming, .names],
    .technology: [.tech, .vibe, .code, .design, .civil, .factory, .power],
    .society: [.publicLife, .phrases, .culture, .sport, .literature, .finance, .law, .education, .media],
    .style: [], .food: [], .travel: [.place, .landmarks, .logistics],
  ]
}

extension Term {
  var originalSubject: WordSubject? {
    guard let pack else { return nil }
    if let subject = WordSubject(rawValue: pack) { return subject }
    guard let old = BuiltinVocabulary.Group(rawValue: pack) else { return nil }
    if let w = WordCatalog.shared.byName[spelling.lowercased()], old == w.group || BuiltinVocabulary.Group.previousShelves[old]?.contains(w.group) == true { return w.originalSubject }
    return old.subject
  }
  var collection: WordCollection? { pack.flatMap(WordCollection.init(rawValue:)) ?? originalSubject?.collection }
}

extension BuiltinVocabulary.Word {
  var classicalTopic: String? {
    if group == .classical { return section }
    return tags.first { $0 == ClassicalCorpus.verseTopic || $0 == ClassicalCorpus.idiomTopic }
  }
  var originalSubject: WordSubject { subject ?? group.subject }
  var collection: WordCollection { originalSubject.collection }
  var topic: String { section ?? tags.first ?? (group == .vibe ? "编程工具" : group.rawValue) }
  func matchesTopic(_ filter: String?) -> Bool {
    guard let filter else { return true }
    return topic == filter || ([ClassicalCorpus.verseTopic, ClassicalCorpus.idiomTopic].contains(filter) && tags.contains(filter))
  }
  func searchLabel(_ query: String, spelling: String? = nil) -> String {
    let display = spelling ?? name
    let tokens = CatalogSearch.tokens(query)
    guard !tokens.isEmpty, !tokens.contains(CatalogSearch.key(name)),
      let matched = aliases.first(where: { alias in tokens.contains(where: CatalogSearch.key(alias).contains) }) else { return display }
    return matched + "（" + display + "）"
  }
}

enum CatalogSearch {
  static func key(_ s: String) -> String {
    s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
  }
  static func tokens(_ query: String) -> [String] { key(query).split(whereSeparator: \.isWhitespace).map(String.init) }
}

// Sections, counts and search all index the same entries that the recognizer actually loads.
final class WordCatalog {
  typealias Word = BuiltinVocabulary.Word
  static let shared = WordCatalog(.shared)
  let byName: [String: Word], groups: [WordCollection: [Word]]
  let sources: [WordSubject: Set<BuiltinVocabulary.Group>]
  let subjectTopics: [WordSubject: [String]]
  private let ordered: [Word], searchText: [String], spellings: [String]
  init(_ vocabulary: BuiltinVocabulary) {
    let rows = vocabulary.words
    byName = Dictionary(uniqueKeysWithValues: rows.map { ($0.name.lowercased(), $0) })
    let shelves = Dictionary(grouping: rows, by: \.collection); groups = shelves
    let subjects = Dictionary(grouping: rows, by: \.originalSubject)
    sources = subjects.mapValues { Set($0.map(\.group)) }
    subjectTopics = subjects.mapValues { rows in var seen = Set<String>(); return rows.compactMap { seen.insert($0.topic).inserted ? $0.topic : nil } }
    ordered = rows
    spellings = rows.map { CatalogSearch.key($0.name) }
    searchText = rows.map(Self.indexedText)
  }
  private static func indexedText(_ w: Word) -> String {
    let specialty = w.group.industry ? w.group.rawValue : (w.originalSubject == .places ? "地名" : "")
    return CatalogSearch.key(([w.name, w.collection.title, w.originalSubject.rawValue, w.topic, specialty] + w.tags + w.aliases + w.variants).joined(separator: " "))
  }
  static let customTopic = "自定义词条"
  func matches(_ term: Term, keys: [String], in group: WordCollection?, topic: String?) -> Bool {
    guard let shelf = term.collection, group == nil || group == shelf else { return false }
    let original = byName[term.spelling.lowercased()]
    let sameShelf = original?.collection == shelf
    // An imported spelling can shadow a bundled entry; keep its original topic and
    // search aliases without assigning that topic to an entry explicitly moved elsewhere.
    guard topic == nil || topic == Self.customTopic || (sameShelf && original?.matchesTopic(topic) == true) else { return false }
    if keys.isEmpty { return true }
    var fields = CatalogSearch.key([term.spelling, term.spoken, shelf.title].joined(separator: " "))
    if let original {
      fields += " " + (sameShelf ? Self.indexedText(original) : CatalogSearch.key(original.aliases.joined(separator: " ")))
    }
    return keys.allSatisfy(fields.contains)
  }
  func counts(policy: WordPolicy, additions: [Term]) -> [WordCollection: Int] {
    var result = groups.mapValues(\.count), shadowed = policy.hidden
    for term in additions {
      guard let shelf = term.collection else { continue }
      shadowed.insert(term.spelling.lowercased()); result[shelf, default: 0] += 1
    }
    for key in shadowed { if let w = byName[key] { result[w.collection, default: 0] -= 1 } }
    return result
  }
  func count(_ group: WordCollection, policy: WordPolicy, additions: [Term]) -> Int { counts(policy: policy, additions: additions)[group] ?? 0 }
  func find(_ text: String, in group: WordCollection?, topic: String? = nil, removed: Bool, policy: WordPolicy, overriding: Set<String>) -> [Word] {
    let keys = CatalogSearch.tokens(text), q = CatalogSearch.key(text.trimmed)
    func admitted(_ w: Word) -> Bool {
      let k = w.name.lowercased()
      return w.matchesTopic(topic) && policy.hidden.contains(k) == removed && (removed || !overriding.contains(k))
    }
    if keys.isEmpty { return (group.flatMap { groups[$0] } ?? ordered).filter(admitted) }
    var exact = [Word](), aliases = [Word](), prefix = [Word](), contains = [Word](), topics = [Word]()
    for i in ordered.indices {
      let w = ordered[i]
      guard group == nil || group == w.collection, keys.allSatisfy(searchText[i].contains), admitted(w) else { continue }
      if spellings[i] == q { exact.append(w) } else if w.aliases.contains(where: { CatalogSearch.key($0) == q }) { aliases.append(w) } else if spellings[i].hasPrefix(q) { prefix.append(w) }
      else if spellings[i].contains(q) { contains.append(w) } else { topics.append(w) }
    }
    return exact + aliases + prefix + contains + topics
  }
}
