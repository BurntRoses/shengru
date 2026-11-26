import Foundation

// Only consulted on explicit replay. An unheard dictionary word is not an acoustic vote: an
// automatic proposal still has to survive both independent position-aligned hearings.
enum ReplayVocabulary {
  private struct PhoneIndex {
    let sounds:ClassicalCorpus
    var rows=[[Int]:[BuiltinVocabulary.Word]](), lengths=[Int]()
    init?(_ source:BuiltinVocabulary) {
      guard let s=source.classics else{return nil};sounds=s;var widths=Set<Int>()
      for w in source.words where (2...9).contains(w.name.count) && !w.cues.isEmpty && w.name.allSatisfy(SoundShelf.han) {
        let key=w.name.map(s.syllable);guard !key.contains(0) else{continue};rows[key,default:[]].append(w);widths.insert(key.count)
      };lengths=widths.sorted(by:>)
    }
  }
  private static let index=PhoneIndex(BuiltinVocabulary.shared)
  static func review(_ text:String, vocabulary v:BuiltinVocabulary,terms:[Term],previous:[String]) -> (text:String,choices:[ReadingChoice]) {
    guard let index else{return(text,[])};let a=Array(text),p=a.map(index.sounds.syllable),locked=Transcript.replayProtected(in:text,terms:terms),recent=String(previous.suffix(2).joined(separator:"。").suffix(220));var out="",choices=[ReadingChoice](),i=0
    while i<a.count {
      var winning:(BuiltinVocabulary.Word,Int,Bool)?
      for n in index.lengths where i+n<=a.count && p[i] != 0 {
        let span=i..<(i+n);guard !p[span].contains(0), let words=index.rows[Array(p[span])], !locked.contains(where:{$0.overlaps(span)}) else {continue}
        let old=String(a[span]),left=String(a[max(0,i-56)..<i]),right=String(a[i+n..<min(a.count,i+n+52)])
        guard !BuiltinVocabulary.identity(left,right),!ClassicalCorpus.verbatim(left) else{continue}
        let (l,r)=WordContext.clipped(left,right), near=l+" "+r
        var ranked=[(BuiltinVocabulary.Word,Int,Bool)]()
        for w in words where w.name != old && v.enabled.contains(w.name) && !v.bias.discourages(w.name) {
          let local=Set(w.cues.filter{$0.count>=2 && near.contains($0)}),mentioned=near.contains(w.name),remembered=recent.contains(w.name)
          guard !local.isEmpty || mentioned else {continue};let shared=zip(old,w.name).filter{$0==$1}.count
          guard shared>0 || (n==2 && local.count>=2) || mentioned else {continue}
          let strong=(local.count>=2 && n>=3 && shared>=n-2) || (mentioned && (!local.isEmpty || n>=3)) || (remembered && !local.isEmpty && n>=3 && shared>=n-1)
          let score=2*local.count+(mentioned ? 6:0)+(remembered ? 2:0)+shared
          // A competing valid term needs a user choice, even if this domain is prominent.
          ranked.append((w,score,strong && !v.enabled.contains(old)))
        }
        ranked.sort{$0.1 != $1.1 ? $0.1>$1.1 : $0.0.name<$1.0.name}
        if let top=ranked.first, ranked.count==1 || top.1>=ranked[1].1+2 {winning=(top.0,n,top.2);break}
      }
      if let (w,n,automatic)=winning {let e=i+n,old=String(a[i..<e]);out += automatic ? w.name : old
        if !automatic && choices.count<16 {choices.append(.init(heard:old,word:w.name,left:String(a[max(0,i-4)..<i]),right:String(a[e..<min(e+4,a.count)])))};i=e
      }else{out.append(a[i]);i+=1}
    };return(out,choices)
  }
}
