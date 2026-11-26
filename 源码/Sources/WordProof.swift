import Foundation

// Index by two unchanged characters before checking a pronunciation. The expanded catalogue is
// not a global replacement list. Only enabled packs participate; ordinary standalone words,
// quoted text, identifiers and declared names never lose to a merely similar spelling.
struct SoundShelf {
  struct Item { let name:String, chars:[Character], cues:[String], reviewOnly: Bool }
  struct Hit { let end:Int, heard:String, word:String, automatic:Bool }
  private var items=[Item](), buckets=[String:[Int]](), liveBuckets=[String:[Int]](), widths=[Int]()
  init(_ words:[BuiltinVocabulary.Word]) {
    for w in words where (w.group.industry || w.flags.contains("k")) && (3...10).contains(w.name.count) && !w.cues.isEmpty && w.name.allSatisfy(Self.han) {
      let a=Array(w.name), id=items.count; items.append(.init(name:w.name,chars:a,cues:w.cues,reviewOnly:w.flags.contains("k"))); if !widths.contains(a.count) { widths.append(a.count) }
      for key in Self.keys(a[0],a[1],a[a.count-2],a[a.count-1],a.count) { buckets[key,default:[]].append(id); if w.group.industry {liveBuckets[key,default:[]].append(id)} }
    }; widths.sort(by:>)
  }
  static func han(_ c:Character)->Bool { c.unicodeScalars.count==1 && (0x3400...0x9fff).contains(c.unicodeScalars.first!.value) }
  static func sound(_ c:Character)->String { (String(c).applyingTransform(.mandarinToLatin,reverse:false) ?? String(c)).lowercased() }
  private static func keys(_ a:Character,_ b:Character,_ c:Character,_ d:Character,_ width:Int)->[String] {
    ["\(width)p\(a)\(b)","\(width)s\(c)\(d)","\(width)e\(a)\(d)"]
  }
  func hit(_ a:[Character],_ i:Int, minimum:Int, enabled:Set<String>,bias:WordBias,cache:inout [Character:String], review:Bool = true)->Hit? {
    guard !items.isEmpty,Self.han(a[i]) else { return nil }
    func phon(_ c:Character)->String { if let s=cache[c] { return s }; let s=Self.sound(c); cache[c]=s; return s }
    for n in widths where i+n<=a.count && i+n>=minimum {
      let e=i+n; guard Self.han(a[e-1]) else { continue }; var ids=Set<Int>()
      for key in Self.keys(a[i],a[i+1],a[e-2],a[e-1],n) { if let list=(review ? buckets : liveBuckets)[key] { ids.formUnion(list) } }
      guard !ids.isEmpty else { continue }; let span=a[i..<e]; guard span.allSatisfy(Self.han) else { continue }
      let heard=String(span); if enabled.contains(heard) { continue }
      let before=String(a[max(0,i-28)..<i]), after=String(a[e..<min(e+28,a.count)]); guard !BuiltinVocabulary.identity(before,after) else { continue }
      let (l,r)=WordContext.clipped(before,after); var ranked=[(String,Int,Bool)]()
      for id in ids { let it=items[id]; if !review && it.reviewOnly { continue }; let edits=it.chars.indices.filter { it.chars[$0] != a[i+$0] }
        guard edits.count==1, let at=edits.first, !bias.discourages(it.name) else { continue }
        let cues=it.cues.filter { !$0.isEmpty && (l.contains($0) || r.contains($0)) }; guard !cues.isEmpty else { continue }
        let x=phon(it.chars[at]), y=phon(a[i+at]); guard x.compare(y,options:.diacriticInsensitive) == .orderedSame else { continue }
        let adjacent=cues.contains { l.hasSuffix($0) || r.hasPrefix($0) }; let score=(x==y ? 2 : 0)+min(cues.count,3)*2+(adjacent ? 2:0)+(bias.discourages(heard) ? 3:0)
        ranked.append((it.name,score,it.reviewOnly))
      }
      ranked.sort { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }; guard let first=ranked.first, first.1>(ranked.dropFirst().first?.1 ?? -1) else { continue }
      return Hit(end:e,heard:heard,word:first.0,automatic:!first.2 && first.1>=6)
    }; return nil
  }
}

// Only lexical changes are highlighted during speech, not ordinary growth or added punctuation.
struct ProofMark: Equatable {
  let heard:String, word:String, left:String, right:String
  static func change(_ before:String,_ after:String)->Self? {
    guard before != after else { return nil }; let a=Array(before),b=Array(after); var i=0,j=a.count,k=b.count
    while i<min(j,k),a[i]==b[i] { i+=1 }; while j>i,k>i,a[j-1]==b[k-1] { j-=1; k-=1 }
    guard (1...20).contains(j-i),(1...20).contains(k-i) else { return nil }
    let original=String(a[i..<j]), new=String(b[i..<k]); guard original.contains(where:{$0.isLetter}),new.contains(where:{$0.isLetter}) else { return nil }
    return .init(heard:original,word:new,left:String(b[max(0,i-4)..<i]),right:String(b[k..<min(k+4,b.count)]))
  }
  // Display the most recent lexical edit, even when an earlier, distant word was corrected
  // in the same decoder update. Keep the stricter single-change test for acoustic decisions.
  static func latest(_ before: String, _ after: String) -> Self? {
    guard before != after else { return nil }
    if let one = change(before,after), one.heard.count <= 8, one.word.count <= 8 { return one }
    let runs = ReviewRuns.diff(before, after)
    var left = "", latest: Self?, i = 0
    while i < runs.count {
      if runs[i].type == 0 { left += runs[i].s; i += 1; continue }
      var old = "", new = ""
      while i < runs.count, runs[i].type != 0 {
        if runs[i].type < 0 { old += runs[i].s } else { new += runs[i].s }; i += 1
      }
      if (1...20).contains(old.count), (1...20).contains(new.count), old.contains(where: \.isLetter), new.contains(where: \.isLetter) {
        latest = .init(heard:old, word:new, left:String(left.suffix(4)), right:i < runs.count ? String(runs[i].s.prefix(4)) : "")
      }
      left += new
    }
    return latest
  }
  func before(in text:String)->String? { ReadingChoice(heard:word,word:heard,left:left,right:right).applying(to:text) }
}
