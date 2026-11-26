import AVFoundation
import Foundation

enum VoiceFault: LocalizedError {
  case message(String)
  var errorDescription: String? {
    if case .message(let s) = self { return s }
    return nil
  }
}
final class Recognizer {
  private let handle: UnsafeMutableRawPointer
  private let pieces: Set<String>
  private let hanAlphabet: Set<Character>?
  fileprivate let flushSamples: Int32
  init(_ model: URL, profile: SpeechModel = .bundled, deepSearch: Bool = false) throws {
    // Leave room for two decoder steps in the 1.92 s model even when key-up falls
    // just before a step. No real-time delay: these frames are fed in memory.
    flushSamples = profile == .long ? 65_280 : 32_000
    let vocab = try String(contentsOf: model.appendingPathComponent("tokens.txt"), encoding: .utf8)
    pieces = Set(
      vocab.split(separator: "\n").compactMap { $0.split(separator: " ").first.map(String.init) })
    // A character missing from this particular model cannot win an acoustic spelling vote.
    // With byte fallback that inference is invalid, so do not use absence as evidence.
    let han = Set(pieces.lazy.flatMap { $0.filter(SoundShelf.han) })
    hanAlphabet = han.isEmpty || pieces.contains("<0xE4>") ? nil : han
    guard let h = deepSearch ? voice_engine_deep(model.path) : voice_engine(model.path) else {
      throw VoiceFault.message("无法打开这个模型，请在设置中切换模型。")
    }
    handle = h
  }
  // Only submit pieces present in this model. Unknown names simply receive no acoustic bias.
  private func encodeHint(_ value: String) -> String? {
    var tokens = [String]()
    var latin = ""
    func flush() -> Bool {
      guard !latin.isEmpty else { return true }
      var rest = "▁" + latin
      latin = ""
      while !rest.isEmpty {
        var part = rest
        while !part.isEmpty, !pieces.contains(part) { part.removeLast() }
        guard !part.isEmpty else { return false }
        tokens.append(part)
        rest.removeFirst(part.count)
      }
      return true
    }
    for c in value {
      if c.isASCII && (c.isLetter || c.isNumber) {
        latin.append(c)
      } else {
        guard flush() else { return nil }
        if c == " " { continue }
        let piece = "▁" + String(c)
        guard pieces.contains(piece) else { return nil }
        tokens.append(piece)
      }
    }
    guard flush(), tokens.first?.hasPrefix("▁") == true else { return nil }
    return tokens.joined(separator: " ")
  }
  deinit { voice_engine_release(handle) }

  // An unprompted hearing, with different frame alignment and modest gain on soft speech.
  func witness(_ audio: ArraySlice<Float>, keep: Range<Int>, first: Bool, last: Bool) throws -> String {
    guard !audio.isEmpty, let stream=voice_stream(handle) else { return "" }; defer { voice_stream_release(stream) }
    let pad=[Float](repeating:0,count:4160); pad.withUnsafeBufferPointer{voice_feed(handle,stream,$0.baseAddress,Int32($0.count))}
    var gain:Float=1
    for i in stride(from:audio.startIndex,to:audio.endIndex,by:640) {
      try Task.checkCancellation(); let frame=audio[i..<min(i+640,audio.endIndex)]
      let rms=sqrt(frame.reduce(Float(0)){$0+$1*$1}/Float(frame.count))
      let wanted=rms<0.0006 ? Float(1) : min(3.6,max(0.85,0.07/max(rms,0.001)))
      let before=gain; gain += (wanted-gain)*(wanted<gain ? 0.8 : 0.3)
      let samples=frame.enumerated().map{ min(1,max(-1,$0.element*(before+(gain-before)*Float($0.offset+1)/Float(frame.count)))) }
      samples.withUnsafeBufferPointer{voice_feed(handle,stream,$0.baseAddress,Int32($0.count))}
    }
    voice_end(handle,stream,flushSamples)
    guard let p=voice_text_window(handle,stream,first ? 0 : Float(pad.count+keep.lowerBound)/16000,
      last ? Float.greatestFiniteMagnitude : Float(pad.count+keep.upperBound)/16000) else { return "" }
    defer { voice_text_release(p) }; return String(cString:p).replacingOccurrences(of:"▁",with:" ")
      .replacingOccurrences(of:#"(?<=\p{Han}) +(?=\p{Han})"#,with:"",options:.regularExpression).trimmed
  }
  func open(
    hints: [String] = [], level: EditLevel = .natural, terms: [Term] = [],
    vocabulary: BuiltinVocabulary = .shared, learned: [Term] = [], previous: [String] = [],
    shield: WordBias = WordBias([]), proof: Bool = true
  ) throws -> SpeechStream {
    guard let s = voice_context_stream(handle, hints.compactMap(encodeHint).joined(separator: "/"))
    else { throw VoiceFault.message("无法开始听写，请再试一次。") }
    return SpeechStream(
      self, handle, s, proof,
      LiveComposition(
        level: level, terms: terms, vocabulary: vocabulary, learned: learned, previous: previous,
        shield: shield, hanAlphabet: hanAlphabet))
  }
}
final class SpeechStream {
  private let owner: Recognizer
  private let engine: UnsafeMutableRawPointer, stream: UnsafeMutableRawPointer
  private let proof: Bool
  private let composition: LiveComposition
  private var lastQuery = 0, total = 0, quiet = 0, lastEndpoint = 0
  private var excerpt: [Float]? = [], rolling=TailEvidence(), audibleFrames=0
  private var gap = 0.0, awaitingOnset = true, noiseFloor: Float = 0.000006
  init(
    _ owner: Recognizer, _ engine: UnsafeMutableRawPointer, _ stream: UnsafeMutableRawPointer,
    _ proof: Bool, _ composition: LiveComposition
  ) {
    self.proof = proof
    self.owner = owner
    self.engine = engine
    self.stream = stream
    self.composition = composition
  }
  var liveEdit:ProofMark? { composition.liveEdit }
  deinit { voice_stream_release(stream) }
  private func text() -> String {
    guard let p = voice_text(engine, stream) else { return "" }
    defer { voice_text_release(p) }
    return String(cString: p).trimmed
  }
  private func trackPause(_ samples: [Float]) {
    // Measure real inter-phrase silence across decoder resets (including empty endpoints).
    // This does not trim audio. A forced maximum-length endpoint is not a sentence break.
    for pos in stride(from: 0, to: samples.count, by: 320) {
      let end = min(pos + 320, samples.count)
      let energy = samples[pos..<end].reduce(Float(0)) { $0 + $1 * $1 } / Float(end - pos)
      let threshold = max(Float(0.000009), min(0.00035, noiseFloor * 5))
      if energy > 0.0000004 { audibleFrames += end-pos }
      if energy > threshold {
        if awaitingOnset {
          gap = Double(quiet) / 16000
          awaitingOnset = false
        }
        quiet = 0
      } else {
        quiet += end - pos
        noiseFloor = noiseFloor * 0.98 + energy * 0.02
      }
    }
  }
  func feed(_ samples: [Float], preview: Bool = true) -> (String, String)? {
    guard !samples.isEmpty else { return nil }
    rolling.add(samples)
    trackPause(samples)
    total += samples.count
    // Keep at most four seconds of the current utterance in memory for short ambiguous readings.
    // Nothing is written to disk for this check, including when recording history is off.
    if total <= 64000 {
      excerpt?.append(contentsOf: samples)
    } else if excerpt != nil {
      excerpt = nil
    }
    samples.withUnsafeBufferPointer { voice_feed(engine, stream, $0.baseAddress, Int32($0.count)) }
    guard total - lastQuery >= 2560 else { return nil }
    lastQuery = total
    // Also honor the decoder’s own maximum-length endpoint in uninterrupted speech.
    let endpoint = (quiet >= 4800 || total - lastEndpoint >= 24 * 16000) && voice_endpoint(engine, stream) != 0
    // A file has no live preview. Commit real utterance endpoints, not disk chunk boundaries.
    guard endpoint || preview else { return nil }
    let current = text()
    let chosen = endpoint ? reviewedEnding(current) : Ending(text: current)
    let display = composition.push(chosen.text, pause: gap, commit: endpoint,
      heard: chosen.text == current ? nil : current, recoveredTail: chosen.added)
    if endpoint {
      lastEndpoint = total
      rolling.reset(); voice_reset(engine, stream)
      awaitingOnset = true
      gap = 0
    }
    return display
  }
  private func replay(_ samples:[Float], soft:TailEvidence.End? = nil)->[String] {
    guard !samples.isEmpty else { return [] }
    return [3200,9600].compactMap { lead in
      guard let replay=voice_stream(engine) else { return nil }; defer { voice_stream_release(replay) }
      let blank=[Float](repeating:0,count:lead); blank.withUnsafeBufferPointer { voice_feed(engine,replay,$0.baseAddress,Int32($0.count)) }
      var clip=samples
      if let soft { let lo=max(0,soft.last-7200), hi=min(clip.count,soft.last+800)
        for i in lo..<hi { let gain=1+min(1,Float(i-lo)/960)*(lead==3200 ? 2.2 : 3.0); clip[i]=min(1,max(-1,clip[i]*gain)) }
      }
      clip.withUnsafeBufferPointer { voice_feed(engine,replay,$0.baseAddress,Int32($0.count)) }; voice_end(engine,replay,owner.flushSamples)
      guard let p=voice_text(engine,replay) else { return nil }; defer { voice_text_release(p) }; return String(cString:p).trimmed
    }
  }
  private func replayShortWord()->[String] {
    guard let a=excerpt,let first=a.firstIndex(where:{abs($0)>0.001}), let last=a.lastIndex(where:{abs($0)>0.001}) else { return [] }
    return replay(Array(a[max(0,first-800)..<min(a.count,last+1601)]))
  }
  private struct Ending {
    var text: String
    // Only a weak-tail acoustic replay may append syllables ahead of the next endpoint.
    var added = 0
  }
  private func reviewedEnding(_ raw: String) -> Ending {
    var base = checkedEnding(raw)
    guard proof, base.text.count >= 4, let corpus = composition.vocabulary.classics else { return base }
    let evidence = Transcript.literaryReview(base.text, index: composition.index, vocabulary: composition.vocabulary,
      previous: composition.priorClause, short: total - lastEndpoint <= 112000, probeTail: base.added == 0)
    guard !evidence.choices.isEmpty || !evidence.tails.isEmpty || !evidence.pairs.isEmpty else { return base }
    let votes = replay(rolling.samples())
    let extra = corpus.heardTail(base.text, probes: evidence.tails, votes: votes)
    if !evidence.choices.isEmpty { base.text = corpus.confirmed(base.text, choices: evidence.choices, votes: votes) }
    if !evidence.pairs.isEmpty { base.text = corpus.confirmedPair(base.text, probes: evidence.pairs, votes: votes) }
    if let extra { base.text = TailEvidence.appending(extra, to: base.text); base.added = extra.count }
    return base
  }
  private func checkedEnding(_ raw: String) -> Ending {
    guard proof, !raw.isEmpty else { return Ending(text: raw) }; let a=rolling.samples(); guard let end=TailEvidence.ending(a) else { return Ending(text: raw) }
    let negative=composition.shield.discourages(raw)
    guard negative || end.weak else { return Ending(text: raw) }
    let votes=replay(a,soft:end.weak ? end : nil)
    if negative, votes.count==2 {
      let clean=raw.trimmingCharacters(in:BuiltinVocabulary.spokenEdge), one=votes[0].trimmingCharacters(in:BuiltinVocabulary.spokenEdge)
      if one==votes[1].trimmingCharacters(in:BuiltinVocabulary.spokenEdge), !composition.shield.discourages(one), let mark=ProofMark.change(clean,one), mark.heard.count==mark.word.count, mark.heard.count<=4,
         zip(mark.heard,mark.word).allSatisfy({ SoundShelf.han($0) && SoundShelf.han($1) && SoundShelf.sound($0).compare(SoundShelf.sound($1),options:.diacriticInsensitive) == .orderedSame }),
         Transcript.permits(mark,in:clean,index:composition.index),let range=raw.range(of:clean) {
        return Ending(text: raw.replacingCharacters(in:range,with:one))
      }
    }
    if end.weak,let restored=TailEvidence.restored(raw,votes:votes) { return Ending(text: restored, added: restored.count - raw.count) }; return Ending(text: raw)
  }
  func end() -> (raw: String, final: String, choices: [ReadingChoice]) {
    guard total>0, audibleFrames>=480 else { return ("","",[]) }; voice_end(engine,stream,owner.flushSamples)
    let first=text(), last=reviewedEnding(first)
    return composition.finish(last.text, pause: gap, heard: last.text == first ? nil : first, reread: replayShortWord)
  }
}
final class WaveWriter {
  let url: URL
  private var handle: FileHandle?
  private var bytes: UInt32 = 0
  init(_ url: URL) throws {
    self.url = url
    guard
      FileManager.default.createFile(
        atPath: url.path, contents: Data(repeating: 0, count: 44),
        attributes: [.posixPermissions: 0o600])
    else { throw VoiceFault.message("无法保存本次录音。") }
    handle = try FileHandle(forWritingTo: url)
    try handle?.seekToEnd()
  }
  func append(_ samples: [Float]) throws {
    let pcm = samples.map { Int16((min(1, max(-1, $0)) * 32767).rounded()).littleEndian }
    let d = pcm.withUnsafeBytes { Data($0) }
    guard UInt64(bytes) + UInt64(d.count) < UInt64(UInt32.max) - 36 else {
      throw VoiceFault.message("录音过长，请分段听写。")
    }
    try handle?.write(contentsOf: d)
    bytes += UInt32(d.count)
  }
  func close() throws {
    guard let f = handle else { return }
    defer {
      try? f.close()
      handle = nil
    }
    var data = Data()
    func tag(_ s: String) { data.append(contentsOf: s.utf8) }
    func put<T: FixedWidthInteger>(_ n: T) {
      var v = n.littleEndian
      withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }
    tag("RIFF")
    put(bytes + 36)
    tag("WAVE")
    tag("fmt ")
    put(UInt32(16))
    put(UInt16(1))
    put(UInt16(1))
    put(UInt32(16000))
    put(UInt32(32000))
    put(UInt16(2))
    put(UInt16(16))
    tag("data")
    put(bytes)
    try f.seek(toOffset: 0)
    try f.write(contentsOf: data)
  }
  deinit { try? close() }
}
// Microphone conversion is owned by one tap. No decoding, disk I/O or UI work runs on the audio thread.
protocol CaptureDevice: AnyObject {
  var authorization: AVAuthorizationStatus { get }
  var onInterruption: (() -> Void)? { get set }
  func start(_ emit: @escaping ([Float]) -> Void) throws
  func stop()
}
final class Microphone: CaptureDevice {
  var authorization: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for:.audio) }
  private var engine: AVAudioEngine?
  private var interrupted: NSObjectProtocol?
  var onInterruption: (() -> Void)?
  func start(_ emit: @escaping ([Float]) -> Void) throws {
    let e = AVAudioEngine()
    let node = e.inputNode
    let source = node.outputFormat(forBus: 0)
    guard source.sampleRate > 0, source.channelCount > 0,
      let target = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
      let cv = AVAudioConverter(from: source, to: target)
    else { throw VoiceFault.message("没有可用的麦克风。请检查声音输入设备。") }
    cv.primeMethod = .none
    node.installTap(onBus: 0, bufferSize: 1024, format: source) { b, _ in
      let cap = AVAudioFrameCount(ceil(Double(b.frameLength) * 16000 / source.sampleRate)) + 32
      guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return }
      var supplied = false
      var error: NSError?
      let st = cv.convert(to: out, error: &error) { _, status in
        if supplied {
          status.pointee = .noDataNow
          return nil
        }
        supplied = true
        status.pointee = .haveData
        return b
      }
      if st != .error, let p = out.floatChannelData?[0], out.frameLength > 0 {
        emit(Array(UnsafeBufferPointer(start: p, count: Int(out.frameLength))))
      }
    }
    e.prepare()
    do { try e.start() } catch {
      node.removeTap(onBus: 0)
      throw VoiceFault.message("麦克风启动失败，请检查权限或输入设备。")
    }
    engine = e
    interrupted = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange, object: e, queue: .main
    ) { [weak self] _ in self?.onInterruption?() }
  }
  func stop() {
    if let obs = interrupted {
      NotificationCenter.default.removeObserver(obs)
      interrupted = nil
    }
    guard let e = engine else { return }
    e.stop()
    e.inputNode.removeTap(onBus: 0)
    engine = nil
  }
  deinit { stop() }
}
struct Heard {
  var raw: String
  var seconds: Double
  var audio: URL?
  var audioError: Bool
  var final: String = ""
  var choices: [ReadingChoice] = []
  var lease: RecordingLease?
}
// One immutable vocabulary per selection, shared by successive recordings on the decode queue.
struct SessionVocabulary {
  private var cached: (policy: WordPolicy, words: BuiltinVocabulary)?
  mutating func words(for policy: WordPolicy) -> BuiltinVocabulary {
    if let cached, cached.policy == policy { return cached.words }
    let words = BuiltinVocabulary.shared.selecting(policy); cached = (policy, words); return words
  }
  // The first hearing is always the model's own. Only an explicitly requested second
  // hearing can try word hints; its independent witness still receives none.
  mutating func open(_ r: Recognizer, level: EditLevel, terms: [Term], policy: WordPolicy,
                     learned: [Term], previous: [String], proof: Bool, replayHints: [String]? = nil) throws -> SpeechStream {
    let vocab = proof ? words(for: policy) : BuiltinVocabulary.plain
    let shield = WordBias(proof ? policy.blocked : [])
    var allowed = [String]()
    if proof, let replayHints {
      let admitted = replayHints.filter { h in
        !BuiltinVocabulary.shared.enabled.contains(h) || vocab.enabled.contains(h) || terms.contains { $0.spelling == h }
      }
      allowed = vocab.hints(recent:admitted, personal:terms, previous:previous).filter { !shield.discourages($0) }
    }
    return try r.open(
      hints: allowed, level: level, terms: proof ? terms : [], vocabulary: vocab, learned: proof ? learned : [],
      previous: previous, shield: shield, proof: proof)
  }
}

final class SessionAudio {
  private let queue = DispatchQueue(label: "cn.shengru.voice.decode", qos: .userInitiated)
  private var model: URL
  private var recognizer: Recognizer?, stream: SpeechStream?, count = 0
  private let storage = RecordingLane()
  private var vocabulary = SessionVocabulary()
  private var key: UUID?
  init(model: URL) { self.model = model }
  func warm(
    using next: URL? = nil, package: ModelPackage? = nil,
    _ complete: @escaping (Result<Void, Error>) -> Void
  ) {
    queue.async {
      do {
        _ = BuiltinVocabulary.shared
        let destination = next ?? self.model
        if self.recognizer == nil || destination != self.model {
          try package?.validate(destination)
          let replacement = try Recognizer(destination,profile:package?.model ?? .bundled)
          self.recognizer = replacement
          self.model = destination
        }
        DispatchQueue.main.async { complete(.success(())) }
      } catch { DispatchQueue.main.async { complete(.failure(error)) } }
    }
  }
  func begin(
    _ id: UUID, url: URL?, level: EditLevel, terms: [Term],
    policy: WordPolicy = WordPolicy(), learned: [Term] = [], previous: [String] = [], compact: Bool = true, recover: Bool = true, proof:Bool = true,
    failure: @escaping (Error) -> Void
  ) {
    storage.start(id,url:url,compact:compact,recover:recover)
    queue.async {
      do {
        guard let r = self.recognizer else { throw VoiceFault.message("语音资源尚未就绪。") }
        self.stream = try self.vocabulary.open(r, level: level, terms: terms,
          policy: policy, learned: learned, previous: previous, proof: proof)
        self.key = id
        self.count = 0
      } catch { _ = self.storage.end(id,discard:true); DispatchQueue.main.async { failure(error) } }
    }
  }
  func append(_ data: [Float], id: UUID, update: @escaping (String, String, Double, Double, ProofMark?) -> Void)
  {
    storage.append(data,id:id)
    queue.async {
      guard self.key == id, let s = self.stream else { return }
      self.count += data.count
      let rms = sqrt(data.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(1, data.count)))
      if let (stable, tail) = s.feed(data) {
        let duration = Double(self.count) / 16000
        let mark=s.liveEdit
        DispatchQueue.main.async { update(stable, tail, min(1, rms * 9), duration, mark) }
      }
    }
  }
  func end(_ id: UUID, cancel: Bool, done: @escaping (Heard) -> Void) {
    queue.async {
      guard self.key == id else {
        _ = self.storage.end(id, discard:true)
        DispatchQueue.main.async { done(.init(raw: "", seconds: 0, audio: nil, audioError: false)) }
        return
      }
      let transcript =
        cancel
        ? (raw: "", final: "", choices: [ReadingChoice]())
        : self.stream?.end() ?? (raw: "", final: "", choices: [ReadingChoice]())
      let raw = transcript.raw
      let closed = self.storage.end(id, discard:cancel || !Desk.hasWords(transcript.final))
      let result = Heard(raw:raw, seconds:Double(self.count)/16000, audio:closed.url, audioError:closed.failed, final:transcript.final, choices:transcript.choices, lease:closed.lease)
      self.stream = nil
      self.key = nil
      DispatchQueue.main.async { done(result) }
    }
  }
  func shutdown() {
    queue.sync {
      if let key { _ = storage.end(key,discard:true) }
      stream = nil
      key = nil
    }
  }
}
