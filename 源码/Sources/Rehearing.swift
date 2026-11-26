import AVFoundation
import SwiftUI

// A recording is one acoustic timeline, including when a word straddles two saved files.
// Never seed the decoder with the disputed transcript: it is only used for comparison.
struct ReplayRequest {
  let url: URL, expectedSections: Int?
  var model: SpeechModel, directory: URL
  let level: EditLevel
  let terms: [Term], learned: [Term], previous: [String], hints: [String], policy: WordPolicy, proof: Bool

  var alternateDirectory: URL? = nil

  static func model(for chosen: SpeechModel, installed: Set<SpeechModel>) -> SpeechModel {
    if chosen == .mandarinXL, installed.contains(chosen) { return chosen }
    return [.precision, .long, .extended, .standard].first(where: installed.contains) ?? .bundled
  }

  private func tracks() throws -> [URL] {
    let fm = FileManager.default
    guard fm.fileExists(atPath: url.path) else { throw VoiceFault.message("找不到这段录音，原稿未变。") }
    guard url.pathExtension == "clips" else { return [url] }
    let files = SectionRecorder.tracks(url)
    guard !files.isEmpty, expectedSections.map({ $0 == files.count }) ?? true,
      files.enumerated().allSatisfy({ Int($0.element.deletingPathExtension().lastPathComponent) == $0.offset + 1 })
    else { throw VoiceFault.message("录音分节不完整，无法核对整段原稿。") }
    return files
  }

  func run(original: String = "", report: (Int) -> Void) throws -> ReplayEvidence.Result {
    try Task.checkCancellation()
    let files = try tracks()
    let lengths = try files.map { url -> Int64 in
      let f=try AVAudioFile(forReading:url)
      guard f.processingFormat.sampleRate==16000, f.processingFormat.channelCount==1, f.length>0 else { throw VoiceFault.message("无法读取这段录音。") }; return f.length
    }
    let total=Double(lengths.reduce(0,+)); var lastProgress = -1
    func read(_ begin:Int, _ end:Int, _ consume:([Float]) throws->Void) throws {
      var done:Int64=0
      for (i,url) in files.enumerated() {
        let f=try AVAudioFile(forReading:url,commonFormat:.pcmFormatFloat32,interleaved:false)
        guard f.length==lengths[i],let buf=AVAudioPCMBuffer(pcmFormat:f.processingFormat,frameCapacity:4096) else { throw VoiceFault.message("录音分节已变化。") }
        while f.framePosition<lengths[i] {
          try Task.checkCancellation(); try f.read(into:buf,frameCount:4096)
          guard buf.frameLength>0,let p=buf.floatChannelData?[0] else { throw VoiceFault.message("录音提前中断。") }
          try consume(Array(UnsafeBufferPointer(start:p,count:Int(buf.frameLength)))); done+=Int64(buf.frameLength)
          let pct=begin+Int(Double(done)/total*Double(end-begin)); if pct != lastProgress { lastProgress=pct; report(pct) }
        }
      }
    }
    try model.package?.validate(directory); try Task.checkCancellation()
    var decoder=try Recognizer(directory,profile:model,deepSearch:true)
    var vocab=SessionVocabulary()
    func whole(_ r:Recognizer) throws -> (raw:String,final:String,choices:[ReadingChoice]) {
      let stream=try vocab.open(r,level:level,terms:terms,policy:policy,learned:learned,previous:previous,proof:proof,replayHints:hints)
      try read(0,48){ _=stream.feed($0,preview:false) }; try Task.checkCancellation(); return stream.end()
    }
    let reading=try whole(decoder); try Task.checkCancellation()
    if let alternateDirectory, model != .bundled { decoder=try Recognizer(alternateDirectory,profile:.bundled,deepSearch:true) }
    var windows=WindowHearing(); try read(49,95){ try windows.feed($0,recognizer:decoder) }
    let independently=try windows.finish(decoder); try Task.checkCancellation(); report(98)
    let full=reading.final.trimmed
    let active = proof ? vocab.words(for:policy) : BuiltinVocabulary.plain
    if !Desk.hasWords(full) {
      // Soft speech sometimes survives only in the gain-adjusted windows. One reading can
      // supply alternatives or an unsaved preview, but must not outvote an existing draft.
      guard Desk.hasWords(independently) else {throw VoiceFault.message("没有听清可核对的语音。")}
      let only=Transcript.render(independently,level:level,index:Transcript.WordIndex(terms),vocabulary:active,final:true,decoderLayout:true)
      return ReplayEvidence.singleHearing(original:original,heard:only,terms:terms,blocked:policy.blocked)
    }
    let lex = proof ? ReplayVocabulary.review(full,vocabulary:active,terms:terms,previous:previous) : (text:full,choices:[])
    let result=ReplayEvidence.reconcile(original:original,full:lex.text,raw:reading.raw,witness:Transcript.numbers(independently),
      offered:reading.choices+lex.choices,terms:terms,blocked:policy.blocked,vocabulary:active)
    try Task.checkCancellation(); return result
  }
}

// Completion is delivered on the main thread and bound to one text revision and record.
final class Rehearing: ObservableObject, Identifiable {
  enum Stage: Equatable { case working, done(String), unavailable(String) }
  let id=UUID(), recordID:UUID, original:String, origin:Page, forDraft:Bool, inCapsule:Bool
  @Published private(set) var stage=Stage.working
  @Published private(set) var percent:Int?
  @Published var preview: String?
  @Published var previewChoices=[ReadingChoice]()
  @Published private(set) var previousPreviews=[String]()
  func pickPreview(_ choice:ReadingChoice) {guard let before=preview,let after=choice.applying(to:before) else {return};previousPreviews.append(before);preview=after}
  func undoPreview() {if let old=previousPreviews.popLast() {preview=old}}
  private var job:Task<Void,Never>?, ticket:UUID?
  init(id:UUID,original:String,origin:Page,draft:Bool,inCapsule:Bool=false) {
    recordID=id; self.original=original; self.origin=origin; forDraft=draft; self.inCapsule=inCapsule
  }
  func start(_ request:ReplayRequest, complete:@escaping(ReplayEvidence.Result)->Void) {
    cancel(); let token=UUID(), base=original; ticket=token
    job=Task.detached(priority:.userInitiated){ [weak self] in
      do {
        let result=try request.run(original:base){ n in DispatchQueue.main.async { [weak self] in if self?.ticket==token { self?.percent=n } } }
        try Task.checkCancellation(); DispatchQueue.main.async { [weak self] in guard self?.ticket==token else { return }; complete(result) }
      } catch is CancellationError {} catch {
        let why=(error as? VoiceFault)?.localizedDescription ?? "无法读取这段录音。"
        DispatchQueue.main.async { [weak self] in if self?.ticket==token { self?.fail(why) } }
      }
    }
  }
  func done(_ text:String) { cancel(); stage = .done(text) }
  func fail(_ text:String) { cancel(); stage = .unavailable(text) }
  func cancel() { ticket=nil; job?.cancel(); job=nil }
  deinit { job?.cancel() }
}

struct RehearingInline: View {
  @ObservedObject var d:Desk
  @ObservedObject var review:Rehearing
  var body:some View {
    VStack(alignment:.leading,spacing:7) {
      HStack(spacing:8) {
        Image(systemName:"waveform.badge.magnifyingglass").foregroundStyle(Color.inkMint).accessibilityHidden(true)
        switch review.stage {
        case .working:
          Text((review.percent ?? 0)<49 ? "正在重听整段…" : "正在逐句核对…")
          Spacer(); if let n=review.percent { Text("\(n)%").monospacedDigit().foregroundStyle(.secondary) }
          Button("取消") { d.rehearing=nil }.deskAction().accessibilityLabel("取消增强识别")
        case .done(let message), .unavailable(let message):
          Text(message).fixedSize(horizontal:false,vertical:true); Spacer(minLength:2)
          IconAction(symbol:"xmark",title:"收起复听结果",size:24){d.rehearing=nil}
        }
      }.font(.callout)
      if review.stage == .working { ProgressView(value:Double(review.percent ?? 0),total:100).controlSize(.small) }
      if let preview=review.preview {
        Text(preview).textSelection(.enabled)
        ReadingPicker(text:preview,choices:review.previewChoices,choose:review.pickPreview,undo:review.previousPreviews.isEmpty ? nil : review.undoPreview)
        Button("复制文字") { _=InputTarget.copy(preview) }.deskAction()
      }
    }.padding(.horizontal,10).padding(.vertical,6).background(Color.inkMint.opacity(0.065),in:RoundedRectangle(cornerRadius:10))
  }
}
