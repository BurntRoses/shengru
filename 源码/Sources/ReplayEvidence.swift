import Foundation

// All edits are anchored to the visible transcript, never to a matching word elsewhere.
enum ReplayEvidence {
  struct Result { var text:String; var choices:[ReadingChoice] }
  private struct Line {
    let chars:[Character], keys:[Character], positions:[Int]
    init(_ text:String) { let c=Array(text); chars=c; positions=c.indices.filter{c[$0].isLetter || c[$0].isNumber}; keys=positions.map{c[$0].lowercased().first ?? c[$0]} }
    func surface(_ r:Range<Int>) -> Range<Int> {
      if r.isEmpty {let p=r.lowerBound>0 ? positions[r.lowerBound-1]+1 : positions.first ?? 0;return p..<p}
      return positions[r.lowerBound]..<(positions[r.upperBound-1]+1)
    }
  }
  private struct Edit:Hashable { let span:Range<Int>, word:String }
  private struct Alignment {
    var off:[Int?], changes=[Edit]()
    func covers(_ r:Range<Int>) -> Bool {off[r.lowerBound...r.upperBound].allSatisfy{$0 != nil}}
  }
  private static func align(_ a:Line,_ b:Line) -> Alignment {
    var r=Alignment(off:Array(repeating:nil,count:a.keys.count+1))
    func put(_ i:Int,_ n:Int,_ j:Int,_ m:Int) {
      let range=i..<n, new=j..<m
      r.changes.append(Edit(span:range,word:new.isEmpty ? "" : String(b.chars[b.surface(new)])))
    }
    func compare(_ ar:Range<Int>,_ br:Range<Int>) {
      var i=ar.lowerBound,j=br.lowerBound,n=ar.upperBound,m=br.upperBound
      while i<n && j<m && a.keys[i]==b.keys[j] {r.off[i]=j;i+=1;j+=1}
      while n>i && m>j && a.keys[n-1]==b.keys[m-1] {r.off[n]=m;n-=1;m-=1}
      r.off[i]=j;r.off[n]=m
      guard max(n-i,m-j)<=1200, i<n || j<m else {return}
      var rm=Set<Int>(),add=Set<Int>()
      for e in b.keys[j..<m].difference(from:a.keys[i..<n]) {switch e {case .remove(let k,_,_):rm.insert(i+k);case .insert(let k,_,_):add.insert(j+k)}}
      while i<n || j<m {
        let s=i,t=j;while i<n && rm.contains(i){i+=1};while j<m && add.contains(j){j+=1}
        if i != s || j != t {
          r.off[s]=t;r.off[i]=j
          if i-s==j-t, i>s {
            // Preserve existing punctuation between two substitutions; decoder punctuation is not a word.
            var u=s,v=t
            for k in s..<i {let l=t+k-s;r.off[k]=l
              if k>s && (a.positions[k]>a.positions[k-1]+1 || b.positions[l]>b.positions[l-1]+1) {put(u,k,v,l);u=k;v=l}
            };put(u,i,v,j)
          } else {put(s,i,t,j)}
        }
        if i<n && j<m {r.off[i]=j;i+=1;j+=1;r.off[i]=j} else if i==s && j==t {break}
      }
    }
    if max(a.keys.count,b.keys.count)<=1200 {compare(0..<a.keys.count,0..<b.keys.count)} else {
      let width=12;var anchors=[String:Int](),x=0,y=0,i=0
      if b.keys.count>=width {for j in 0...b.keys.count-width {let k=String(b.keys[j..<j+width]);anchors[k]=anchors[k]==nil ? j : -1}}
      while i+width<=a.keys.count {if let j=anchors[String(a.keys[i..<i+width])], j>=y {
        compare(x..<i,y..<j);for k in 0...width {r.off[i+k]=j+k};x=i+width;y=j+width;i=x
      }else{i+=1}};compare(x..<a.keys.count,y..<b.keys.count)
    };return r
  }
  private static let meaning=Set("不没未勿无非莫别否零〇一二两三四五六七八九十百千万亿半")
  private static let sensitive=meaning.union("点负克吨升米秒元伏瓦赫兹毫微纳厘千兆吉摄氏度寸斤磅美元角分")
  private static func touches(_ x:Range<Int>,_ y:Range<Int>) -> Bool {
    x.overlaps(y) || x==y || (x.isEmpty && y.lowerBound<x.lowerBound && x.lowerBound<y.upperBound) || (y.isEmpty && x.lowerBound<y.lowerBound && y.lowerBound<x.upperBound)
  }
  private static func comparable(_ a:String,_ b:String) -> Bool {
    let aa=Array(a),bb=Array(b);return !aa.isEmpty && aa.count==bb.count && zip(aa,bb).allSatisfy{x,y in x==y || (SoundShelf.han(x) && SoundShelf.han(y) && SoundShelf.sound(x).compare(SoundShelf.sound(y),options:.diacriticInsensitive) == .orderedSame)}
  }
  static func singleHearing(original:String,heard:String,terms:[Term],blocked:[String])->Result {
    if original.isEmpty { return Result(text:heard,choices:[]) }
    return reconcile(original:original,full:original,raw:"",witness:heard,offered:[],terms:terms,blocked:blocked)
  }
  static func reconcile(original:String,full:String,raw:String,witness:String,offered:[ReadingChoice],terms:[Term],blocked:[String],vocabulary:BuiltinVocabulary?=nil,interpreted:String?=nil) -> Result {
    guard !original.isEmpty else {return .init(text:full,choices:offered)}
    let base=Line(original), one=Line(raw), two=Line(witness), primary=align(base,Line(full)), secondary=align(base,two), acoustic=align(base,one)
    guard !base.keys.isEmpty else {return .init(text:original,choices:[])}
    let contextualRead=interpreted.map{align(base,Line($0))}, checked=Set(contextualRead?.changes ?? [])
    let first=primary.changes,second=secondary.changes,firstSet=Set(first),b=Dictionary(second.map{($0.span,$0.word)},uniquingKeysWith:{x,_ in x}),a=Dictionary(acoustic.changes.map{($0.span,$0.word)},uniquingKeysWith:{x,_ in x})
    let shield=WordBias(blocked), locked=Transcript.replayProtected(in:original,terms:terms)
    var frozen=[Range<Int>](), applied=[(Range<Int>,String)](), proposals=[(Range<Int>,String)](),seen=Set<Edit>()
    // A different edition cannot overrule two acoustic reads of a clearly different syllable.
    func heardAt(_ k:Int,_ l:Line,_ al:Alignment) -> Character? {
      guard let i=al.off[k],let j=al.off[k+1],j==i+1,l.keys.indices.contains(i) else{return nil};return l.keys[i]
    }
    if let vocab=vocabulary,let corpus=vocab.classics {
      let observed=corpus.recitedPairs(in:base.keys,enabled:vocab.enabled,bias:shield)
      if !observed.isEmpty {
        func matches(_ line:Line) -> [UInt64:[ClassicalCorpus.RecitedPair]] {Dictionary(grouping:corpus.recitedPairs(in:line.keys,enabled:vocab.enabled,bias:shield),by:{$0.key})}
        let p=matches(one), q=matches(two)
        func backed(_ h:ClassicalCorpus.RecitedPair,_ al:Alignment,_ dict:[UInt64:[ClassicalCorpus.RecitedPair]]) -> Bool {
          guard al.covers(h.start..<h.end),let x=al.off[h.start],let z=al.off[h.end] else {return false};return dict[h.key]?.contains{abs($0.start-x)<=1 && abs($0.end-z)<=1}==true
        }
        var votes=[Int:Set<Character>](), punctuation=[Int:Set<String>]()
        for h in observed where backed(h,acoustic,p) || backed(h,secondary,q) {
          let s=base.surface(h.start..<h.end),left=String(base.chars[..<s.lowerBound].suffix(42)),right=String(base.chars[s.upperBound...].prefix(18))
          guard !ClassicalCorpus.verbatim(left),!BuiltinVocabulary.identity(left,right),!locked.contains(where:{touches(s,$0)}) else {continue}
          let chars=Array(h.first+h.second)
          guard !chars.enumerated().contains(where:{let old=base.keys[h.start+$0.offset];return old != $0.element && (meaning.contains(old) || meaning.contains($0.element))}) else {continue}
          let contradicted=chars.enumerated().contains{j,c in let k=h.start+j,old=base.keys[k]
            guard old != c,!corpus.replayClose(old,c),let x=heardAt(k,one,acoustic),let y=heardAt(k,two,secondary) else{return false}
            return corpus.replayClose(x,old) && corpus.replayClose(y,old) && !corpus.replayClose(x,c) && !corpus.replayClose(y,c)
          }
          if contradicted {for k in h.start..<h.end {votes[k,default:[]].insert(base.keys[k])};continue}
          for (k,c) in chars.enumerated(){votes[h.start+k,default:[]].insert(c)}
          let changed = !base.keys[h.start..<h.end].elementsEqual(chars)
          if changed {for k in (h.start+1)..<h.end {punctuation[k,default:[]].insert(k==h.start+h.first.count ? h.separator : "")}}
        }
        for (k,v) in votes.sorted(by:{$0.key<$1.key}) where v.count==1 {
          let s=base.surface(k..<k+1);frozen.append(s);if let c=v.first,c != base.chars[s.lowerBound] {applied.append((s,String(c)))}
        }
        for (k,v) in punctuation where v.count==1 && votes[k]?.count==1 && votes[k-1]?.count==1 {
          let gap=(base.positions[k-1]+1)..<base.positions[k], old=String(base.chars[gap]), new=v.first!
          if old != new && old.allSatisfy({" ，,。；;、".contains($0)}) {applied.append((gap,new))}
        }
      }
    }
    var protectedSource=[Range<Int>]()
    for r in (locked+frozen).sorted(by:{$0.lowerBound<$1.lowerBound}) {if let last=protectedSource.last,last.upperBound>=r.lowerBound {protectedSource[protectedSource.count-1]=last.lowerBound..<max(last.upperBound,r.upperBound)}else{protectedSource.append(r)}}
    func isGuarded(_ span:Range<Int>)->Bool {var lo=0,hi=protectedSource.count;while lo<hi {let mid=(lo+hi)/2;if protectedSource[mid].upperBound<=span.lowerBound {lo=mid+1}else{hi=mid}};return lo<protectedSource.count && touches(protectedSource[lo],span)}
    func nearby(_ e:Edit,_ l:[Edit])->Bool {l.contains{$0.span != e.span && touches($0.span,e.span)}}
    for e in first+second where seen.insert(e).inserted {
      let r=base.surface(e.span),old=String(base.chars[r]),word=e.word
      guard max(e.span.count,word.count)<=16,old != word,!old.contains("\n"),!word.contains("\n"),!shield.discouragesChange(word,left:base.chars[..<r.lowerBound],right:base.chars[r.upperBound...]), !isGuarded(r) else {continue}
      let left=String(base.chars[..<r.lowerBound].suffix(42)),right=String(base.chars[r.upperBound...].prefix(24))
      guard !ClassicalCorpus.verbatim(left),!BuiltinVocabulary.identity(left,right) else {continue}
      let paired=firstSet.contains(e) && b[e.span]==word
      let contextual=firstSet.contains(e) && a[e.span] != word && comparable(old,word) && secondary.covers(e.span) && acoustic.covers(e.span) && !nearby(e,second) && !nearby(e,acoustic.changes) && comparable(b[e.span] ?? old,word) && comparable(a[e.span] ?? old,word)
      let contextCount=min(4,e.span.lowerBound)+min(4,base.keys.count-e.span.upperBound)
      let safe = !word.isEmpty && max(e.span.count,word.count)<=8 && old.allSatisfy(SoundShelf.han) && word.allSatisfy(SoundShelf.han) && sensitive.isDisjoint(with:old+word) && (contextCount>=2 || (!old.isEmpty && comparable(old,word))) && (!old.isEmpty || word.count<=2)
      let twice=firstSet.contains(e) && checked.contains(e) && secondary.covers(e.span) && acoustic.covers(e.span) && !word.isEmpty && !old.isEmpty && old.count==word.count && zip(old,word).allSatisfy { x,y in vocabulary?.classics?.replayClose(x,y) ?? comparable(String(x),String(y)) }
      if safe && (paired || contextual || twice) {applied.append((r,word))}
      else if proposals.count<40 {proposals.append((r,word))}
    }
    applied.sort{$0.0.lowerBound != $1.0.lowerBound ? $0.0.lowerBound<$1.0.lowerBound : $0.0.upperBound<$1.0.upperBound}
    var output=[Character](),end=0,done=[(Range<Int>,String)]()
    for (r,word) in applied where r.lowerBound>=end {output+=base.chars[end..<r.lowerBound];output+=word;end=r.upperBound;done.append((r,word))};output+=base.chars[end...];let text=String(output)
    var choices=[ReadingChoice]()
    func offer(_ c:ReadingChoice) {
      guard choices.count<12,!shield.discourages(c.word),!choices.contains(c),let at=c.range(in:text) else {return}
      let i=text.distance(from:text.startIndex,to:at.lowerBound), range=i..<(i+c.heard.count)
      if protectedOutput.contains(where:{touches(range,$0)}) || shield.discouragesChange(c.word,left:output[..<range.lowerBound],right:output[range.upperBound...]) {return};choices.append(c)
    }
    // Translate source protection into output coordinates before filtering both old and new candidates.
    var protectedOutput=[Range<Int>]()
    var delta=0,k=0
    for area in protectedSource {
      while k<done.count && done[k].0.upperBound<=area.lowerBound {delta+=done[k].1.count-done[k].0.count;k+=1}
      let lo=area.lowerBound+delta
      while k<done.count && done[k].0.lowerBound<area.upperBound {delta+=done[k].1.count-done[k].0.count;k+=1}
      protectedOutput.append(lo..<(area.upperBound+delta))
    }
    for c in offered {
      if c.range(in:text) != nil {offer(c);continue}
      // A word suggested by a fresh hearing may itself have been misheard differently in
      // the old transcript. Map both ends back to the same utterance, not a global search.
      for sample in [full,raw] {
        guard let whereHeard=c.range(in:sample) else{continue};let line=Line(sample), span=sample[..<whereHeard.lowerBound].filter{$0.isLetter || $0.isNumber}.count
        let n=sample[whereHeard].filter{$0.isLetter || $0.isNumber}.count, map=align(line,Line(text))
        guard n>0,let lo=map.off[span],let hi=map.off[span+n],hi>lo,abs(hi-lo-n)<=2 else{continue}
        let location=Line(text).surface(lo..<hi), heard=String(output[location]);guard heard.allSatisfy(SoundShelf.han), c.word.allSatisfy(SoundShelf.han) else{continue}
        let edited=ReadingChoice(heard:heard,word:c.word,left:String(output[..<location.lowerBound].suffix(5)),right:String(output[location.upperBound...].prefix(5)));offer(edited);break
      }
    }
    for (r,word) in proposals where choices.count<12 {
      if done.contains(where:{touches($0.0,r)}) {continue};let offset=done.filter{$0.0.upperBound<=r.lowerBound}.reduce(0){$0+$1.1.count-$1.0.count}
      var lo=r.lowerBound+offset,hi=r.upperBound+offset,replacement=word
      guard lo>=0,hi<=output.count,hi>=lo else{continue}
      if lo==hi || replacement.isEmpty {if lo>0 {lo-=1;replacement=String(output[lo])+replacement} else if hi<output.count {replacement.append(output[hi]);hi+=1}else{continue}}
      offer(.init(heard:String(output[lo..<hi]),word:replacement,left:String(output[..<lo].suffix(5)),right:String(output[hi...].prefix(5))))
    }
    return .init(text:text,choices:choices)
  }
}
// The two margins give the decoder the word before and after each boundary. Only centre
// tokens enter the transcript. Disk chapters do not reset the window or split a syllable.
struct WindowHearing {
  private var pcm=[Float](), left=0, pieces=[String]()
  private static let margin=12800, cap=16*16000
  mutating func feed(_ samples:[Float], recognizer:Recognizer) throws {
    pcm += samples
    while pcm.count-left>=Self.cap+Self.margin {
      var cut=left+Self.cap, best=Float.infinity
      for i in stride(from:left+9*16000,through:left+Self.cap,by:640) {
        let f=pcm[i-480..<i+480], energy=f.reduce(Float(0)){$0+$1*$1}
        if energy<=best { best=energy; cut=i }
      }
      pieces.append(try recognizer.witness(pcm[..<(cut+Self.margin)],keep:left..<cut,first:left==0,last:false))
      pcm.removeFirst(cut-Self.margin); left=Self.margin
    }
  }
  mutating func finish(_ recognizer:Recognizer) throws -> String {
    if pcm.count>left { pieces.append(try recognizer.witness(pcm[...],keep:left..<pcm.count,first:left==0,last:true)) }
    return pieces.reduce(""){ Transcript.join($0,$1) }
  }
}
