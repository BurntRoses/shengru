import Foundation

// Bounded look-back for the current utterance, including a quiet ending after a long recording.
// Re-decoding changes the alignment and lifts only the measured tail. Stored PCM is untouched.
struct TailEvidence {
  private var buffer=[Float](repeating:0,count:112000), cursor=0, size=0
  mutating func add(_ a:[Float]) {
    guard !a.isEmpty else { return }; let chunk=a.suffix(buffer.count); let first=min(buffer.count-cursor,chunk.count)
    buffer.replaceSubrange(cursor..<cursor+first,with:chunk.prefix(first)); let rest=chunk.count-first
    if rest>0 { buffer.replaceSubrange(0..<rest,with:chunk.suffix(rest)) }
    cursor=(cursor+chunk.count)%buffer.count; size=min(buffer.count,size+chunk.count)
  }
  mutating func reset() { size=0; cursor=0 }
  func samples()->[Float] {
    if size<buffer.count { return Array(buffer[..<size]) }; return Array(buffer[cursor...])+buffer[..<cursor]
  }
  struct End { let last:Int, weak:Bool }
  static func ending(_ a:[Float])->End? {
    guard a.count>=160 else { return nil }; var energy=[Float]()
    for i in stride(from:0,to:a.count,by:160) { let f=a[i..<min(i+160,a.count)]; energy.append(sqrt(f.reduce(Float(0)) { $0+$1*$1 }/Float(f.count))) }
    guard let peak=energy.max(), peak>0.0006,let e=energy.lastIndex(where:{$0>max(0.00045,peak*0.012)}) else { return nil }
    let last=min(a.count,(e+1)*160), near=energy[max(0,e-23)...e], prior=energy[max(0,e-95)...max(0,e-20)].max() ?? peak
    let soft=near.filter { $0 > 0.00045 && $0 < min(0.028,prior*0.24) }.count
    return End(last:last,weak:soft>=6 && (near.max() ?? 0)<max(prior*0.65,0.004))
  }
  static func normalize(_ s:String)->String { String(s.filter { $0.isLetter || $0.isNumber }).lowercased() }
  // Accept a missing syllable only when two acoustic reads contain it after the same actual
  // suffix. No sentence completion, metric substitution or language-only prediction.
  static func restored(_ raw:String, votes:[String])->String? {
    let base=Array(normalize(raw)); guard base.count>=2,votes.count==2 else { return nil }
    func extra(_ vote:String)->String? {
      let v=Array(normalize(vote)); for k in 1...2 where v.count>k {
        let suffix=v.suffix(k); guard suffix.allSatisfy(SoundShelf.han) else { continue }
        let overlap=min(base.count,v.count-k,12); guard overlap>=min(base.count,3), Array(base.suffix(overlap))==Array(v.dropLast(k).suffix(overlap)) else { continue }
        guard v.count>base.count || overlap>=4, !v.suffix(min(base.count,5)).elementsEqual(base.suffix(min(base.count,5))) else { continue }
        return String(suffix)
      }; return nil
    }
    guard let a=extra(votes[0]),a==extra(votes[1]) else { return nil }
    return appending(a, to: raw)
  }
  static func appending(_ suffix: String, to raw: String) -> String {
    let cut = raw.lastIndex { $0.isLetter || $0.isNumber }.map { raw.index(after: $0) } ?? raw.endIndex
    return String(raw[..<cut]) + suffix + raw[cut...]
  }
}
