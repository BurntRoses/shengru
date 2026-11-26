import Foundation
import Darwin

// Storage sees the original PCM, never the gain-adjusted decoder replay. A quiet run is held
// for at most four seconds. Once it qualifies, retain both edges, including all pre-roll.
struct QuietRun {
  let enabled: Bool
  private var prefix = [Float](), ring = [Float](repeating: 0, count: 8000), cursor = 0
  private var shortened = false, floor: Float = 0.00012
  init(_ enabled: Bool) { self.enabled = enabled }
  mutating func process(_ samples: [Float], write: ([Float]) throws -> Void) rethrows {
    guard enabled else { try write(samples); return }
    var output = [Float](); output.reserveCapacity(samples.count)
    for i in stride(from: 0, to: samples.count, by: 320) {
      let frame = samples[i..<min(i + 320, samples.count)]
      let rms = sqrt(frame.reduce(Float(0)) { $0 + $1*$1 } / Float(frame.count))
      let threshold = min(Float(0.0008), max(0.00016, floor * 1.65))
      if rms < threshold && frame.allSatisfy({ abs($0) < threshold * 3 }) {
        floor = 0.985 * floor + 0.015 * rms
        if shortened {
          for v in frame { ring[cursor] = v; cursor = (cursor+1) % ring.count }
        } else {
          prefix.append(contentsOf: frame)
          if prefix.count >= 64000 {
            output.append(contentsOf: prefix.prefix(12000)); ring = Array(prefix.suffix(ring.count)); cursor = 0
            shortened = true; prefix.removeAll(keepingCapacity: false)
          }
        }
      } else { drain(into: &output); output.append(contentsOf: frame) }
    }
    if !output.isEmpty { try write(output) }
  }
  private mutating func drain(into output: inout [Float]) {
    if shortened { output.append(contentsOf: ring[cursor...]); output.append(contentsOf: ring[..<cursor]); shortened = false; cursor = 0 }
    else if !prefix.isEmpty { output.append(contentsOf: prefix); prefix.removeAll(keepingCapacity:true) }
  }
  mutating func finish(_ write: ([Float]) throws -> Void) rethrows {
    var remaining = [Float](); drain(into:&remaining); if !remaining.isEmpty { try write(remaining) }
  }
}

// The lease stays with the audio until the review is accepted or discarded, not just while the file is open.
final class RecordingLease {
  private let fd: Int32
  init(_ url: URL) throws {
    fd = Darwin.open(url.appendingPathComponent(".active").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw VoiceFault.message("录音目录不可用。") }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(fd); throw VoiceFault.message("这段录音正在使用。") }
  }
  deinit { Darwin.close(fd) }
}

final class SectionRecorder {
  let url: URL
  let lease: RecordingLease
  private let limit: Int
  private var quiet: QuietRun, frames = 0, number = 0, writer: WaveWriter?
  init(_ url: URL, compact: Bool, recover: Bool, sectionFrames: Int = 5*60*16000) throws {
    self.url = url; quiet = QuietRun(compact); limit = max(1,sectionFrames)
    guard Darwin.mkdir(url.path, 0o700) == 0 else { throw VoiceFault.message("无法新建录音目录。") }
    do {
      lease = try RecordingLease(url)
      if recover { try Data().write(to:url.appendingPathComponent(".recover")) }
    } catch { try? FileManager.default.removeItem(at:url); throw error }
  }
  private func write(_ data: [Float]) throws {
    if writer == nil { number += 1; writer = try WaveWriter(url.appendingPathComponent(String(format:"%06d.partial",number))) }
    try writer?.append(data)
  }
  private func seal() throws {
    guard let w = writer else { return }; try w.close(); try FileManager.default.moveItem(at:w.url,to:w.url.deletingPathExtension().appendingPathExtension("wav")); writer=nil
  }
  func append(_ data:[Float]) throws {
    var i=0
    while i<data.count {
      let n=min(limit-frames,data.count-i)
      try quiet.process(n==data.count ? data : Array(data[i..<i+n]),write:write)
      i += n; frames += n
      if frames == limit { try quiet.finish(write); try seal(); frames=0 }
    }
  }
  func finish() throws { try quiet.finish(write); try seal() }
  static func tracks(_ folder:URL)->[URL] {
    ((try? FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil)) ?? []).filter { $0.lastPathComponent.range(of:#"^[0-9]{6,}\.wav$"#,options:.regularExpression) != nil }.sorted { $0.lastPathComponent < $1.lastPathComponent }
  }
}

// Disk writes and model evaluation have independent ordered queues. Completion is a barrier:
// the library only receives a closed package. An I/O failure preserves sealed sections.
final class RecordingLane {
  private let q = DispatchQueue(label:"dictation.sections",qos:.utility)
  private final class Session {
    var recorder: SectionRecorder?, broken = false
  }
  struct Closed {
    var url: URL?, failed = false, lease: RecordingLease?
  }
  private var sessions = [UUID: Session]()
  func start(_ id: UUID, url: URL?, compact: Bool, recover: Bool) {
    q.async {
      let s = Session(); self.sessions[id] = s
      if let url {
        do { s.recorder = try SectionRecorder(url, compact: compact, recover: recover) }
        catch { s.broken = true }
      }
    }
  }
  func append(_ data: [Float], id: UUID) {
    q.async {
      guard let s = self.sessions[id], !s.broken else { return }
      do { try s.recorder?.append(data) } catch { s.broken = true }
    }
  }
  func end(_ id: UUID, discard: Bool) -> Closed {
    q.sync {
      guard let s = sessions.removeValue(forKey:id) else { return Closed() }
      guard let r = s.recorder else { return Closed(failed:s.broken) }
      if !discard { do { try r.finish() } catch { s.broken = true } }
      if discard || SectionRecorder.tracks(r.url).isEmpty {
        try? FileManager.default.removeItem(at:r.url); return Closed(failed:s.broken)
      }
      return Closed(url:r.url, failed:s.broken, lease:r.lease)
    }
  }
}
