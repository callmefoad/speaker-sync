// Speaker Sync. Plays your Mac's audio on a Bluetooth speaker and a wired speaker at once,
// and holds the wired one back so they both land at the same time.
//
// Audio path:  Mac apps -> Speaker Sync cable -> one private aggregate device (cable + both
//              speakers, clocks kept in line by Core Audio) -> delay + EQ -> each speaker

import SwiftUI
import CoreAudio
import AppKit
import AVFoundation
import ServiceManagement
import Accelerate
import Carbon.HIToolbox


// MARK: - CoreAudio helpers

struct OutputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let transport: UInt32

    var isBluetooth: Bool {
        transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }
    var isVirtual: Bool {
        transport == kAudioDeviceTransportTypeAggregate || transport == kAudioDeviceTransportTypeVirtual
            || transport == kAudioDeviceTransportTypeAutoAggregate
    }
}

enum CA {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func addr(_ sel: AudioObjectPropertySelector,
                     _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func deviceIDs() -> [AudioDeviceID] {
        var a = addr(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func string(_ id: AudioDeviceID, _ sel: AudioObjectPropertySelector) -> String {
        var a = addr(sel)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value) == noErr,
              let s = value?.takeRetainedValue() else { return "" }
        return s as String
    }

    static func transport(_ id: AudioDeviceID) -> UInt32 {
        var a = addr(kAudioDevicePropertyTransportType)
        var t: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &a, 0, nil, &size, &t)
        return t
    }

    static func hasOutput(_ id: AudioDeviceID) -> Bool {
        var a = addr(kAudioDevicePropertyStreams, kAudioDevicePropertyScopeOutput)
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size)
        return size > 0
    }

    static func outputs() -> [OutputDevice] {
        deviceIDs().filter(hasOutput).map {
            OutputDevice(id: $0,
                         uid: string($0, kAudioDevicePropertyDeviceUID),
                         name: string($0, kAudioObjectPropertyName),
                         transport: transport($0))
        }
    }

    static func defaultOutput() -> AudioDeviceID {
        var a = addr(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(system, &a, 0, nil, &size, &id)
        return id
    }

    /// Real microphones (built-in, USB, AirPods, an iPhone nearby), skipping virtual cables.
    static func micNames() -> [String] {
        deviceIDs().filter { id in
            var a = addr(kAudioDevicePropertyStreams, kAudioDevicePropertyScopeInput)
            var size: UInt32 = 0
            AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size)
            guard size > 0 else { return false }
            let t = transport(id)
            return t != kAudioDeviceTransportTypeVirtual && t != kAudioDeviceTransportTypeAggregate
                && !string(id, kAudioObjectPropertyName).localizedCaseInsensitiveContains("BlackHole")
                && !string(id, kAudioDevicePropertyDeviceUID).hasPrefix("SpeakerSync")
        }.map { string($0, kAudioObjectPropertyName) }
    }

    /// The mic used for Calibrate and Speaker check. The picked one if it's around,
    /// else the Mac's default input, else the first real mic.
    static func micName(preferred: String = "Automatic") -> String? {
        let mics = micNames()
        if preferred != "Automatic", mics.contains(preferred) { return preferred }
        var a = addr(kAudioHardwarePropertyDefaultInputDevice)
        var def = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(system, &a, 0, nil, &size, &def)
        let defName = string(def, kAudioObjectPropertyName)
        if mics.contains(defName) { return defName }
        return mics.first
    }

    private static func volAddr(_ el: UInt32) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                   mScope: kAudioDevicePropertyScopeOutput, mElement: el)
    }

    /// Output volume 0...1, from the main element or channel 1.
    static func volume(_ id: AudioDeviceID) -> Float? {
        for el in [kAudioObjectPropertyElementMain, 1] {
            var a = volAddr(el)
            guard AudioObjectHasProperty(id, &a) else { continue }
            var v: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr { return v }
        }
        return nil
    }

    static func setVolume(_ id: AudioDeviceID, _ v: Float) {
        for el in [kAudioObjectPropertyElementMain, 1, 2] {
            var a = volAddr(el)
            var settable: DarwinBoolean = false
            guard AudioObjectHasProperty(id, &a),
                  AudioObjectIsPropertySettable(id, &a, &settable) == noErr, settable.boolValue else { continue }
            var val = Float32(v)
            AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &val)
        }
    }

    static func uid(_ id: AudioDeviceID) -> String { string(id, kAudioDevicePropertyDeviceUID) }

    /// Finds a device by its name, optionally only ones that can record.
    static func device(named name: String, input: Bool = false) -> AudioDeviceID? {
        deviceIDs().first { id in
            guard string(id, kAudioObjectPropertyName) == name else { return false }
            return !input || !channels(id, input: true).isEmpty
        }
    }

    /// Channel count of each stream (buffer) a device hands an IOProc, in order.
    static func channels(_ id: AudioDeviceID, input: Bool) -> [Int] {
        var a = addr(kAudioDevicePropertyStreamConfiguration,
                     input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, raw) == noErr else { return [] }
        let abl = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return abl.map { Int($0.mNumberChannels) }.filter { $0 > 0 }
    }

    static func rate(_ id: AudioDeviceID) -> Double {
        var a = addr(kAudioDevicePropertyNominalSampleRate)
        var r: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        AudioObjectGetPropertyData(id, &a, 0, nil, &size, &r)
        return r
    }

    /// Asks a device to switch sample rate and waits up to a second for it to happen.
    static func setRate(_ id: AudioDeviceID, _ r: Double) {
        guard rate(id) != r else { return }
        var a = addr(kAudioDevicePropertyNominalSampleRate)
        var v = Float64(r)
        AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<Float64>.size), &v)
        let deadline = Date().addingTimeInterval(1)
        while rate(id) != r && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
    }

    static func setDefaultOutput(_ id: AudioDeviceID) {
        var dev = id
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var a = addr(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectSetPropertyData(system, &a, 0, nil, size, &dev)
        var s = addr(kAudioHardwarePropertyDefaultSystemOutputDevice)
        AudioObjectSetPropertyData(system, &s, 0, nil, size, &dev)
    }
}

// MARK: - Audio engine

/// Bass and treble shelves, same corners sox used (100 Hz and 3 kHz).
struct Biquad {
    var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0

    static func shelf(high: Bool, db: Double, rate: Double) -> Biquad {
        guard db != 0 else { return Biquad() }
        let f0 = high ? 3_000.0 : 100.0, slope = 0.5
        let A = pow(10, db / 40), w = 2 * Double.pi * f0 / rate, c = cos(w)
        let alpha = sin(w) / 2 * sqrt((A + 1 / A) * (1 / slope - 1) + 2)
        let k = 2 * sqrt(A) * alpha
        let b0, b1, b2, a0, a1, a2: Double
        if high {
            b0 = A * ((A + 1) + (A - 1) * c + k); b1 = -2 * A * ((A - 1) + (A + 1) * c)
            b2 = A * ((A + 1) + (A - 1) * c - k); a0 = (A + 1) - (A - 1) * c + k
            a1 = 2 * ((A - 1) - (A + 1) * c);     a2 = (A + 1) - (A - 1) * c - k
        } else {
            b0 = A * ((A + 1) - (A - 1) * c + k); b1 = 2 * A * ((A - 1) - (A + 1) * c)
            b2 = A * ((A + 1) - (A - 1) * c - k); a0 = (A + 1) + (A - 1) * c + k
            a1 = -2 * ((A - 1) + (A + 1) * c);    a2 = (A + 1) + (A - 1) * c - k
        }
        return Biquad(b0: Float(b0 / a0), b1: Float(b1 / a0), b2: Float(b2 / a0),
                      a1: Float(a1 / a0), a2: Float(a2 / a0))
    }

    /// Runs one sample through. `z` holds this filter's two state values.
    @inline(__always) func run(_ x: Float, _ z: UnsafeMutablePointer<Float>) -> Float {
        let y = b0 * x + z[0]
        z[0] = b1 * x - a1 * y + z[1]
        z[1] = b2 * x - a2 * y
        return y
    }
}

struct SpeakerEQ {
    var gain: Float = 1   // headroom so boosts don't clip
    var low = Biquad(), high = Biquad()

    init() {}
    init(bass: Double, treble: Double, rate: Double) {
        gain = Float(pow(10, -max(bass, treble, 0) / 20))
        low = .shelf(high: false, db: bass, rate: rate)
        high = .shelf(high: true, db: treble, rate: rate)
    }
}

/// Everything the audio callback needs. Lives in plain memory so the callback never allocates.
struct SyncState {
    struct Params {
        var wiredVol: Float = 1, btVol: Float = 1
        var delayFrames = 0
        var calibrate = false   // left channel to wired only, right to Bluetooth only, no delay
        var awake = false
        var wiredEQ = SpeakerEQ(), btEQ = SpeakerEQ()
    }
    var slots = (Params(), Params())
    var active = 0
    var ring: UnsafeMutablePointer<Float>
    var ringFrames: Int
    var write = 0
    var z: UnsafeMutablePointer<Float>   // 8 filters x 2 state values
    var inBuf = 0, inCh = 2
    var wiredBuf = -1, wiredCh = 2
    var btBuf = -1, btCh = 2
    var rate = 48_000.0
    var phase = 0.0
    var gW: Float = 0, gB: Float = 0
    var level: Float = 0
}

/// The sync itself. A private aggregate device holds the Speaker Sync cable plus both speakers,
/// so Core Audio keeps all their clocks lined up (no drift on long sessions). One callback reads
/// the cable and writes each speaker, with the delay, EQ, volume, and keep-awake tone done right there.
final class SyncEngine: @unchecked Sendable {
    private let s: UnsafeMutablePointer<SyncState>
    private var agg = AudioDeviceID(0)
    private var proc: AudioDeviceIOProcID?
    let rate: Double

    init(cable: OutputDevice, wired: OutputDevice?, bt: OutputDevice?) throws {
        // Everyone runs at one rate. Bluetooth is the pickiest, so it sets it.
        let r = CA.rate(bt?.id ?? wired?.id ?? cable.id)
        for d in [cable, wired].compactMap({ $0 }) { CA.setRate(d.id, r) }
        rate = r > 0 ? r : 48_000

        var subs: [[String: Any]] = [["uid": cable.uid]]
        for d in [wired, bt].compactMap({ $0 }) { subs.append(["uid": d.uid, "drift": 1]) }
        let desc: [String: Any] = [
            "name": "Speaker Sync Engine",
            "uid": "io.github.callmefoad.speakersync.engine.\(UUID().uuidString)",
            "private": 1, "stacked": 0,
            "master": cable.uid,   // the cable's clock leads, the speakers follow it
            "subdevices": subs,
        ]
        var id = AudioDeviceID(0)
        guard AudioHardwareCreateAggregateDevice(desc as CFDictionary, &id) == noErr, id != 0 else {
            throw NSError(domain: "SpeakerSync", code: 1)
        }
        agg = id
        Thread.sleep(forTimeInterval: 0.15)   // let Core Audio finish putting it together

        var frames: UInt32 = 512
        var fa = CA.addr(kAudioDevicePropertyBufferFrameSize)
        AudioObjectSetPropertyData(id, &fa, 0, nil, UInt32(MemoryLayout<UInt32>.size), &frames)

        let ringFrames = Int(rate * 1.2)
        s = .allocate(capacity: 1)
        let ring = UnsafeMutablePointer<Float>.allocate(capacity: ringFrames * 2)
        ring.initialize(repeating: 0, count: ringFrames * 2)
        let z = UnsafeMutablePointer<Float>.allocate(capacity: 16)
        z.initialize(repeating: 0, count: 16)
        s.initialize(to: SyncState(ring: ring, ringFrames: ringFrames, z: z))
        s.pointee.rate = rate

        // Output buffers come in sub-device order: cable, then wired, then Bluetooth.
        var next = CA.channels(cable.id, input: false).count
        if let w = wired {
            let ch = CA.channels(w.id, input: false)
            s.pointee.wiredBuf = ch.isEmpty ? -1 : next
            s.pointee.wiredCh = ch.first ?? 2
            next += ch.count
        }
        if let b = bt {
            let ch = CA.channels(b.id, input: false)
            s.pointee.btBuf = ch.isEmpty ? -1 : next
            s.pointee.btCh = ch.first ?? 2
        }
        s.pointee.inCh = CA.channels(cable.id, input: true).first ?? 2

        let st = s
        let err = AudioDeviceCreateIOProcIDWithBlock(&proc, id, nil) { _, inData, _, outData, _ in
            SyncEngine.render(st, inData, outData)
        }
        guard err == noErr, let proc, AudioDeviceStart(id, proc) == noErr else {
            stop()
            throw NSError(domain: "SpeakerSync", code: 2)
        }
    }

    deinit { stop() }

    func stop() {
        if let proc {
            AudioDeviceStop(agg, proc)
            AudioDeviceDestroyIOProcID(agg, proc)
            self.proc = nil
        }
        if agg != 0 { AudioHardwareDestroyAggregateDevice(agg); agg = 0 }
    }

    /// New settings go in the spare slot, then the callback flips over to it.
    func update(_ p: SyncState.Params) {
        if s.pointee.active == 0 { s.pointee.slots.1 = p; s.pointee.active = 1 }
        else { s.pointee.slots.0 = p; s.pointee.active = 0 }
    }

    /// Roughly how loud the cable is right now (RMS, decays in about 50 ms).
    var level: Float { s.pointee.level }

    private static func render(_ s: UnsafeMutablePointer<SyncState>,
                               _ inData: UnsafePointer<AudioBufferList>,
                               _ outData: UnsafeMutablePointer<AudioBufferList>) {
        let outs = UnsafeMutableAudioBufferListPointer(outData)
        for b in outs { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
        let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
        let st = s.pointee
        guard st.inBuf < ins.count, let inPtr = ins[st.inBuf].mData?.assumingMemoryBound(to: Float.self) else { return }
        let inCh = max(st.inCh, 1)
        let n = Int(ins[st.inBuf].mDataByteSize) / (4 * inCh)
        let p = st.active == 0 ? st.slots.0 : st.slots.1

        func out(_ buf: Int, _ ch: Int) -> (UnsafeMutablePointer<Float>, Int, Int)? {
            guard buf >= 0, buf < outs.count, let d = outs[buf].mData else { return nil }
            let c = max(ch, 1)
            return (d.assumingMemoryBound(to: Float.self), c, min(n, Int(outs[buf].mDataByteSize) / (4 * c)))
        }
        let wo = out(st.wiredBuf, st.wiredCh), bo = out(st.btBuf, st.btCh)

        let ring = st.ring, rf = st.ringFrames, z = st.z
        var w = st.write, phase = st.phase, gW = st.gW, gB = st.gB
        let delay = p.calibrate ? 0 : min(max(p.delayFrames, 0), rf - 1)
        let tW: Float = p.calibrate ? 1 : p.wiredVol, tB: Float = p.calibrate ? 1 : p.btVol
        let step = 18.0 / st.rate
        var sum: Float = 0

        for i in 0..<n {
            let l = inPtr[i * inCh], r = inCh > 1 ? inPtr[i * inCh + 1] : l
            sum += l * l + r * r
            ring[2 * w] = l; ring[2 * w + 1] = r
            let rd = (w - delay + rf) % rf
            w = (w + 1) % rf
            gW += (tW - gW) * 0.002
            gB += (tB - gB) * 0.002

            if let (d, c, m) = wo, i < m {
                var a: Float, b: Float
                if p.calibrate { a = l; b = l } else {
                    let e = p.wiredEQ
                    a = e.high.run(e.low.run(ring[2 * rd] * e.gain, z), z + 2)
                    b = e.high.run(e.low.run(ring[2 * rd + 1] * e.gain, z + 4), z + 6)
                }
                a *= gW; b *= gW
                if c == 1 { d[i] = (a + b) / 2 } else { d[i * c] = a; d[i * c + 1] = b }
            }
            if let (d, c, m) = bo, i < m {
                var a: Float, b: Float
                if p.calibrate { a = r; b = r } else {
                    let e = p.btEQ
                    a = e.high.run(e.low.run(l * e.gain, z + 8), z + 10)
                    b = e.high.run(e.low.run(r * e.gain, z + 12), z + 14)
                }
                a *= gB; b *= gB
                if p.awake && !p.calibrate {
                    // An 18 Hz tone at -40 dB: too low for the speaker to play, but enough
                    // signal that it doesn't think it's idle and go to sleep.
                    let t = Float(sin(2 * Double.pi * phase)) * 0.01
                    a += t; b += t
                }
                if c == 1 { d[i] = (a + b) / 2 } else { d[i * c] = a; d[i * c + 1] = b }
            }
            phase += step
            if phase >= 1 { phase -= 1 }
        }
        let rms = n > 0 ? (sum / Float(2 * n)).squareRoot() : 0
        s.pointee.write = w
        s.pointee.phase = phase
        s.pointee.gW = gW
        s.pointee.gB = gB
        s.pointee.level = max(rms, st.level * 0.6)
    }
}

/// Records one mic for Calibrate and Speaker check. Keeps the first channel, saves 48 kHz WAV.
final class MicRecorder: @unchecked Sendable {
    private let dev: AudioDeviceID
    private var proc: AudioDeviceIOProcID?
    private let buf: UnsafeMutablePointer<Float>
    private let cap: Int
    private let count: UnsafeMutablePointer<Int>
    let rate: Double

    init?(name: String, seconds: Double) {
        guard let id = CA.device(named: name, input: true) else { return nil }
        dev = id
        rate = CA.rate(id) > 0 ? CA.rate(id) : 48_000
        cap = Int(seconds * rate)
        buf = .allocate(capacity: cap)
        count = .allocate(capacity: 1)
        count.initialize(to: 0)
    }

    deinit { stopDevice(); buf.deallocate(); count.deallocate() }

    /// Frames recorded so far.
    var frames: Int { count.pointee }

    func start() -> Bool {
        let b = buf, c = count, cap = cap
        let err = AudioDeviceCreateIOProcIDWithBlock(&proc, dev, nil) { _, inData, _, _, _ in
            let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
            guard let first = ins.first, let d = first.mData else { return }
            let ch = max(Int(first.mNumberChannels), 1)
            let n = Int(first.mDataByteSize) / (4 * ch)
            let src = d.assumingMemoryBound(to: Float.self)
            var k = c.pointee
            for i in 0..<n where k < cap { b[k] = src[i * ch]; k += 1 }
            c.pointee = k
        }
        guard err == noErr, let proc else { return false }
        return AudioDeviceStart(dev, proc) == noErr
    }

    private func stopDevice() {
        guard let proc else { return }
        AudioDeviceStop(dev, proc)
        AudioDeviceDestroyIOProcID(dev, proc)
        self.proc = nil
    }

    /// Stops recording and writes what it got. Returns false if there was nothing.
    func stop(saveTo url: URL) -> Bool {
        stopDevice()
        let n = frames
        guard n > 0, let src = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let dst = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1),
              let inBuf = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: AVAudioFrameCount(n)) else { return false }
        inBuf.frameLength = AVAudioFrameCount(n)
        inBuf.floatChannelData![0].update(from: buf, count: n)
        var outBuf = inBuf
        if rate != 48_000 {
            guard let conv = AVAudioConverter(from: src, to: dst),
                  let o = AVAudioPCMBuffer(pcmFormat: dst, frameCapacity: AVAudioFrameCount(Double(n) * 48_000 / rate) + 1024)
            else { return false }
            var fed = false
            _ = conv.convert(to: o, error: nil) { _, status in
                if fed { status.pointee = .endOfStream; return nil }
                fed = true
                status.pointee = .haveData
                return inBuf
            }
            outBuf = o
        }
        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000.0,
                                       AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                                       AVLinearPCMIsFloatKey: false]
        guard let f = try? AVAudioFile(forWriting: url, settings: settings) else { return false }
        return (try? f.write(from: outBuf)) != nil
    }
}

/// Plays a sound file on one specific device and waits for it to finish.
enum Player {
    static func play(_ url: URL, uid: String, upTo seconds: Double) {
        guard let p = try? AVAudioPlayer(contentsOf: url) else { return }
        p.currentDevice = uid
        p.prepareToPlay()
        guard p.play() else { return }
        let deadline = Date().addingTimeInterval(seconds)
        Thread.sleep(forTimeInterval: 0.05)
        while p.isPlaying && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        p.stop()
    }
}

struct CalibrationBusy: Error {}
struct MicFailed: Error {}

// MARK: - Engine

// MARK: - Calibration

/// Pause / resume whatever app is playing (Music, Spotify, browsers) through macOS's
/// Now Playing system. Pause and play are separate commands, so nothing toggles by accident.
enum Media {
    private typealias Send = @convention(c) (UInt32, CFDictionary?) -> Bool
    private static let send: Send? = {
        guard let h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW),
              let f = dlsym(h, "MRMediaRemoteSendCommand") else { return nil }
        return unsafeBitCast(f, to: Send.self)
    }()
    static func play() { _ = send?(0, nil) }

    static func pause() { _ = send?(1, nil) }

    /// How loud the cable is, checked over half a second so a quiet moment in a song still counts.
    static func level(_ engine: SyncEngine?) -> Double {
        guard let engine else { return 0 }
        var peak: Float = 0
        for _ in 0..<10 { peak = max(peak, engine.level); Thread.sleep(forTimeInterval: 0.05) }
        return Double(peak)
    }
}

/// Plays chirps on the wired speaker (left channel) and the Bluetooth speaker (right channel),
/// records them with the mic, and measures how far behind Bluetooth lands.
enum Calibrator {
    static let rate = 48_000.0
    static let wiredAt: [Double] = [1.0, 3.0, 5.0]   // right channel plays 1.0 s after each
    static let gap = 1.0
    static let length = 7.0

    static func chirp() -> [Float] {
        let n = Int(0.12 * rate)
        let f0 = 1_000.0, f1 = 8_000.0, dur = Double(n) / rate
        return (0..<n).map { i in
            let t = Double(i) / rate
            let phase = 2 * Double.pi * (f0 * t + (f1 - f0) / (2 * dur) * t * t)
            let win = 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(n - 1))
            return Float(sin(phase) * win)
        }
    }

    static func writeSignal(to url: URL) throws {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let frames = AVAudioFrameCount(length * rate)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        let c = chirp()
        let l = buf.floatChannelData![0], r = buf.floatChannelData![1]
        // Faint hiss the whole time so the soundbar stays awake and doesn't gate the chirps.
        for i in 0..<Int(frames) { l[i] = .random(in: -0.008...0.008); r[i] = .random(in: -0.008...0.008) }
        for t in wiredAt {
            let a = Int(t * rate), b = Int((t + gap) * rate)
            for (i, s) in c.enumerated() { l[a + i] += 0.9 * s; r[b + i] += 0.9 * s }
        }
        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate,
                                       AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16,
                                       AVLinearPCMIsFloatKey: false]
        let f = try AVAudioFile(forWriting: url, settings: settings)
        try f.write(from: buf)
    }

    enum Outcome { case ok(ms: Double), quiet, noisy, busy, noMic }

    static func analyze(_ url: URL) -> Outcome {
        guard let f = try? AVAudioFile(forReading: url),
              let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)),
              (try? f.read(into: buf)) != nil, let ch = buf.floatChannelData?[0] else { return .quiet }
        let sr = f.processingFormat.sampleRate
        let x = Array(UnsafeBufferPointer(start: ch, count: Int(buf.frameLength)))
        let h = chirp()
        guard x.count > h.count * 2 else { return .quiet }
        let n = x.count - h.count + 1
        var y = [Float](repeating: 0, count: n)
        vDSP_conv(x, 1, h, 1, &y, 1, vDSP_Length(n), vDSP_Length(h.count))
        var env = y.map { abs($0) }
        let floor = env.sorted()[env.count / 2] + 1e-9   // background level, before peaks are blanked

        // Greedy peak picking with 0.4 s suppression around each pick.
        let guardN = Int(0.4 * sr)
        var peaks: [(Int, Float)] = []
        for _ in 0..<6 {
            var mx: Float = 0; var idx: vDSP_Length = 0
            vDSP_maxvi(env, 1, &mx, &idx, vDSP_Length(env.count))
            guard mx > 0 else { break }
            peaks.append((Int(idx), mx))
            for j in max(0, Int(idx) - guardN)..<min(env.count, Int(idx) + guardN) { env[j] = 0 }
        }
        guard peaks.count == 6 else { return .quiet }
        // Every chirp should stand well above the background.
        if peaks.contains(where: { $0.1 < floor * 20 }) { return .quiet }

        let p = peaks.map { Double($0.0) / sr }.sorted()
        let d = (0..<3).map { (p[2 * $0 + 1] - p[2 * $0]) - gap }.sorted()
        if d.last! - d.first! > 0.03 { return .noisy }
        return .ok(ms: d[1] * 1000)
    }
}

/// Short two-note beeps for the speaker check, and a check for whether the mic heard them.
enum Beeper {
    static let rate = 48_000.0

    static func write(to url: URL, left: Bool, right: Bool, pitch: Double, lead: Double) throws {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let frames = AVAudioFrameCount((lead + 0.5) * rate)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        let l = buf.floatChannelData![0], r = buf.floatChannelData![1]
        let leadN = Int(lead * rate)
        for i in 0..<Int(frames) {
            let hiss: Float = i < leadN ? .random(in: -0.004...0.004) : 0
            l[i] = left ? hiss : 0
            r[i] = right ? hiss : 0
        }
        for (start, f) in [(lead, pitch), (lead + 0.2, pitch * 1.25)] {
            let a = Int(start * rate), n = Int(0.12 * rate)
            for i in 0..<n {
                let env = sin(Double.pi * Double(i) / Double(n))
                let v = Float(0.35 * env * sin(2 * Double.pi * f * Double(i) / rate))
                if left { l[a + i] += v }
                if right { r[a + i] += v }
            }
        }
        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate,
                                       AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16,
                                       AVLinearPCMIsFloatKey: false]
        try AVAudioFile(forWriting: url, settings: settings).write(from: buf)
    }

    /// Strength of one frequency in a block of samples (Goertzel). Listening for the beep's exact
    /// pitch ignores most room noise.
    static func tone(_ p: UnsafePointer<Float>, _ n: Int, _ f: Double, _ sr: Double) -> Double {
        let c = 2 * cos(2 * Double.pi * f / sr)
        var s1 = 0.0, s2 = 0.0
        for i in 0..<n { let s0 = Double(p[i]) + c * s1 - s2; s2 = s1; s1 = s0 }
        return sqrt(max(0, s1 * s1 + s2 * s2 - c * s1 * s2)) / Double(n)
    }

    /// windows: key -> (start s, end s, pitch Hz) in the recording's timeline.
    static func heard(_ url: URL, windows: [String: (Double, Double, Double)]) -> [String: Bool] {
        guard let f = try? AVAudioFile(forReading: url),
              let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)),
              (try? f.read(into: buf)) != nil, let ch = buf.floatChannelData?[0] else { return [:] }
        let sr = f.processingFormat.sampleRate
        let count = Int(buf.frameLength), hop = Int(0.02 * sr)
        func levels(_ a: Double, _ b: Double, _ pitch: Double) -> [Double] {
            stride(from: max(0, Int(a * sr)), to: min(count - hop, Int(b * sr)), by: hop).map { tone(ch + $0, hop, pitch, sr) }
        }
        var out: [String: Bool] = [:]
        for (key, w) in windows {
            let room = levels(0.05, 0.45, w.2).sorted()
            let floor = room.isEmpty ? 0 : room[room.count / 2]
            let peak = levels(w.0, w.1, w.2).max() ?? 0
            out[key] = peak > max(floor * 5, 0.0003)
        }
        return out
    }
}

@MainActor
final class Engine: ObservableObject {
    static let shared = Engine()
    static let automatic = "Automatic"
    private let d = UserDefaults.standard

    @Published var devices: [OutputDevice] = []
    @Published var blackHole: OutputDevice?
    @Published var running = false
    @Published var live: Set<String> = []
    @Published var error: String?
    @Published var ticking = false { didSet { updateTicker() } }
    @Published var openAtLogin = SMAppService.mainApp.status == .enabled
    @Published var calibrating = false
    @Published var calibrationNote: String?

    @Published var wiredOn: Bool     { didSet { d.set(wiredOn, forKey: "wiredOn"); restartSoon() } }
    @Published var btOn: Bool        { didSet { d.set(btOn, forKey: "btOn"); restartSoon() } }
    @Published var wiredName: String { didSet { d.set(wiredName, forKey: "wiredName"); restartSoon() } }
    @Published var btName: String    { didSet { d.set(btName, forKey: "btName"); restartSoon() } }
    @Published var wiredVol: Double  { didSet { d.set(wiredVol, forKey: "wiredVol"); restartSoon() } }
    @Published var btVol: Double     { didSet { d.set(btVol, forKey: "btVol"); restartSoon() } }
    @Published var delayMs: Double   { didSet { d.set(delayMs, forKey: "delayMs"); rememberDelay(); restartSoon() } }
    @Published var autoStart: Bool   { didSet { d.set(autoStart, forKey: "autoStart") } }
    @Published var keepAwake: Bool   { didSet { d.set(keepAwake, forKey: "keepAwake"); restartSoon() } }
    @Published var autoSwitch: Bool  { didSet { d.set(autoSwitch, forKey: "autoSwitch") } }
    @Published var micChoice: String { didSet { d.set(micChoice, forKey: "micChoice") } }
    @Published var wiredBass: Double   { didSet { d.set(wiredBass, forKey: "wiredBass"); restartSoon() } }
    @Published var wiredTreble: Double { didSet { d.set(wiredTreble, forKey: "wiredTreble"); restartSoon() } }
    @Published var btBass: Double      { didSet { d.set(btBass, forKey: "btBass"); restartSoon() } }
    @Published var btTreble: Double    { didSet { d.set(btTreble, forKey: "btTreble"); restartSoon() } }
    /// Which speaker pair the current delay belongs to (shown under the slider).
    @Published var pairLabel: String?
    /// The cable's own volume. Mac volume keys move it, and it scales both speakers together.
    @Published var masterVol: Double = 1
    /// Speaker check: which beep is playing right now ("left", "right", "bt"), and what the mic heard.
    @Published var checking: String?
    @Published var checkHeard: [String: Bool] = [:]
    @Published var checkDone: Set<String> = []
    @Published var checkNote: String?

    private(set) var sync: SyncEngine?
    private var syncSig = ""
    private var building: String?
    private var previousDefault: AudioDeviceID?
    private var pending: DispatchWorkItem?
    private var tickTimer: Timer?
    private var pollTimer: Timer?
    private var savedVolumes: [AudioDeviceID: Float] = [:]
    private var calLevel: Float = 0.5
    private var speakerVolumes: [AudioDeviceID: Float] = [:]
    private var pairKey: String?
    private var cableID: AudioDeviceID?
    private var btSeen: Bool?
    private var btMissing = 0

    /// Older versions ran sox. If one got left behind by a crash it keeps playing and the wired
    /// speaker doubles up, so clear any out on launch.
    static func killStrays() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        p.arguments = ["-9", "-f", "sox -q (--buffer 2048 -t coreaudio|-n -t coreaudio)"]
        try? p.run()
        p.waitUntilExit()
    }

    // MARK: Driver

    @Published var installingDriver = false

    /// The renamed BlackHole driver bundled inside the app (build/SpeakerSync.driver at build time).
    var bundledDriver: URL? { Bundle.main.url(forResource: "SpeakerSync", withExtension: "driver") }
    var driverInstalled: Bool { blackHole?.uid.hasPrefix("SpeakerSync") == true }

    /// Copies the driver into /Library/Audio/Plug-Ins/HAL and restarts Core Audio.
    /// macOS shows its own password prompt.
    func installDriver() {
        guard let src = bundledDriver, !installingDriver else { return }
        installingDriver = true
        let hal = "/Library/Audio/Plug-Ins/HAL"
        let source = """
        do shell script "rm -rf \(hal)/SpeakerSync.driver && cp -R " & quoted form of "\(src.path)" & " \(hal)/ && killall coreaudiod" with administrator privileges
        """
        DispatchQueue.main.async {
            var err: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&err)
            MainActor.assumeIsolated {
                let e = Engine.shared
                e.installingDriver = false
                if let err, (err[NSAppleScript.errorNumber] as? Int) != -128 {
                    e.error = "Driver install failed: \(err[NSAppleScript.errorMessage] as? String ?? "unknown error")"
                }
            }
            // Core Audio takes a moment to come back. The 2 s poll picks up the new device.
        }
    }

    // MARK: Per-speaker delay

    /// Each wired + Bluetooth pair remembers its own delay.
    private var currentPair: String? {
        guard isPresent(resolvedBT) else { return nil }
        return "\(resolvedWired)|\(resolvedBT)"
    }

    private func rememberDelay() {
        guard let key = currentPair, !calibrating else { return }
        var all = d.dictionary(forKey: "pairDelays") as? [String: Double] ?? [:]
        all[key] = delayMs
        d.set(all, forKey: "pairDelays")
    }

    private func loadPairDelay() {
        let key = currentPair
        guard key != pairKey else { return }
        pairKey = key
        pairLabel = key == nil ? nil : resolvedBT
        guard let key, let saved = (d.dictionary(forKey: "pairDelays") as? [String: Double])?[key] else {
            rememberDelay()   // first time with this pair: start from the current delay
            return
        }
        if saved != delayMs { delayMs = saved }
    }

    private init() {
        d.register(defaults: [
            "wiredOn": true, "btOn": true,
            "wiredName": Engine.automatic, "btName": Engine.automatic,
            "wiredVol": 1.0, "btVol": 1.0, "delayMs": 180.0, "autoStart": true, "keepAwake": true,
            "autoSwitch": true, "micChoice": Engine.automatic,
        ])
        wiredOn = d.bool(forKey: "wiredOn")
        btOn = d.bool(forKey: "btOn")
        wiredName = d.string(forKey: "wiredName") ?? Engine.automatic
        btName = d.string(forKey: "btName") ?? Engine.automatic
        wiredVol = d.double(forKey: "wiredVol")
        btVol = d.double(forKey: "btVol")
        delayMs = d.double(forKey: "delayMs")
        autoStart = d.bool(forKey: "autoStart")
        keepAwake = d.bool(forKey: "keepAwake")
        autoSwitch = d.bool(forKey: "autoSwitch")
        micChoice = d.string(forKey: "micChoice") ?? Engine.automatic
        wiredBass = d.double(forKey: "wiredBass")
        wiredTreble = d.double(forKey: "wiredTreble")
        btBass = d.double(forKey: "btBass")
        btTreble = d.double(forKey: "btTreble")
        Engine.killStrays()
        refresh()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in Engine.shared.refresh() }
        }
        if autoStart {
            DispatchQueue.main.async { Task { @MainActor in
                let e = Engine.shared
                if e.blackHole != nil { e.start() }
            } }
        }
    }

    // MARK: Devices

    func refresh() {
        let all = CA.outputs()
        // The virtual cable: our renamed "Speaker Sync" driver if installed, else stock BlackHole.
        blackHole = all.first { $0.uid.hasPrefix("SpeakerSync") }
            ?? all.first { $0.name.localizedCaseInsensitiveContains("BlackHole") }
        // Hide the cable itself plus aggregate/virtual devices (Multi-Output, Zoom, etc.)
        devices = all.filter {
            !$0.name.localizedCaseInsensitiveContains("BlackHole") && !$0.uid.hasPrefix("SpeakerSync") && !$0.isVirtual
        }
        loadPairDelay()
        if let bh = blackHole, let v = CA.volume(bh.id), !calibrating, checking == nil { masterVol = Double(v) }
        autoSwitchCheck()
        guard running else { return }
        if let bh = blackHole, cableID != bh.id {
            // The cable changed (e.g. the Speaker Sync driver was just installed). Move over to it.
            if cableID != nil { killAll(); CA.setDefaultOutput(bh.id) }
            cableID = bh.id
        }
        guardDefaultOutput()
        syncRoutes()
    }

    /// Turn sync on when the Bluetooth speaker connects, and off once it's been gone for 10 seconds.
    /// Only reacts to changes, so turning sync off by hand sticks until the speaker reconnects.
    private func autoSwitchCheck() {
        let btNow = devices.contains(where: \.isBluetooth) && isPresent(resolvedBT)
        let was = btSeen
        btSeen = btNow
        guard autoSwitch, let was, btOn else { return }
        if btNow {
            btMissing = 0
            if !was && !running && blackHole != nil { start() }
        } else if running && !calibrating && checking == nil {
            btMissing += 1
            if btMissing == 5 { stop() }
        }
    }

    func setMaster(_ v: Double) {
        masterVol = v
        if let bh = blackHole { CA.setVolume(bh.id, Float(v)) }
    }

    /// "Automatic" = headphone jack if something's plugged in, else built-in speakers.
    var resolvedWired: String {
        guard wiredName == Engine.automatic else { return wiredName }
        if let h = devices.first(where: { $0.name.localizedCaseInsensitiveContains("Headphones") }) { return h.name }
        return devices.first(where: { $0.uid == "BuiltInSpeakerDevice" })?.name ?? "MacBook Pro Speakers"
    }

    /// "Automatic" = the first connected Bluetooth speaker.
    var resolvedBT: String {
        guard btName == Engine.automatic else { return btName }
        return devices.first(where: \.isBluetooth)?.name ?? "Bluetooth speaker"
    }

    func isPresent(_ name: String) -> Bool { devices.contains { $0.name == name } }

    /// macOS jumps to headphones or a newly connected speaker on its own. While syncing,
    /// pull the default back to BlackHole when it moved to one of our speakers.
    private func guardDefaultOutput() {
        guard let bh = blackHole else { return }
        let cur = CA.defaultOutput()
        guard cur != bh.id else { return }
        if CA.string(cur, kAudioObjectPropertyName).localizedCaseInsensitiveContains("BlackHole") {
            CA.setDefaultOutput(bh.id); return
        }
        guard let dev = devices.first(where: { $0.id == cur }) else { return }
        let ours = dev.name == resolvedWired || dev.name == resolvedBT
            || dev.name.localizedCaseInsensitiveContains("Headphones")
        if ours { CA.setDefaultOutput(bh.id) }
    }

    // MARK: Routes

    /// The speakers sync should be playing on right now, if they're connected.
    private var targets: (wired: OutputDevice?, bt: OutputDevice?) {
        let w = (wiredOn || calibrating) ? devices.first { $0.name == resolvedWired } : nil
        var b = (btOn || calibrating) ? devices.first { $0.name == resolvedBT } : nil
        if b?.id == w?.id { b = nil }
        return (w, b)
    }

    private var params: SyncState.Params {
        let rate = sync?.rate ?? 48_000
        var p = SyncState.Params()
        p.wiredVol = Float(wiredVol)
        p.btVol = Float(btVol)
        p.delayFrames = Int(delayMs / 1000 * rate)
        p.calibrate = calibrating
        p.awake = keepAwake
        p.wiredEQ = SpeakerEQ(bass: wiredBass, treble: wiredTreble, rate: rate)
        p.btEQ = SpeakerEQ(bass: btBass, treble: btTreble, rate: rate)
        return p
    }

    var waitingFor: [String] {
        var names: [String] = []
        if wiredOn && !live.contains("wired") { names.append(resolvedWired) }
        if btOn && !live.contains("bt") { names.append(resolvedBT) }
        return names
    }

    func setRunning(_ on: Bool) { on ? start() : stop() }

    func start() {
        error = nil
        refresh()
        guard let bh = blackHole else { error = "The Speaker Sync driver isn't installed yet. Hit Install Driver first."; return }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .denied {
            error = "Speaker Sync needs mic access to hear your Mac's audio. Turn it on in System Settings > Privacy & Security > Microphone. Settings > Privacy explains why."
            return
        }
        // Ask about the mic before touching any audio. Starting the engine while macOS's mic
        // prompt is up would freeze the app until someone answers it.
        if askForMic(then: { Engine.shared.start() }) { return }
        let current = CA.defaultOutput()
        if current != bh.id { previousDefault = current }
        CA.setDefaultOutput(bh.id)
        running = true
        syncRoutes()
    }

    func stop() {
        pending?.cancel()
        killAll()
        for (id, v) in savedVolumes { CA.setVolume(id, v) }   // quit mid-calibration
        savedVolumes = [:]
        for (id, v) in speakerVolumes { CA.setVolume(id, v) }
        speakerVolumes = [:]
        if let prev = previousDefault, CA.outputs().contains(where: { $0.id == prev }) {
            CA.setDefaultOutput(prev)
        } else if let fallback = devices.first(where: { $0.uid == "BuiltInSpeakerDevice" }) {
            CA.setDefaultOutput(fallback.id)
        }
        previousDefault = nil
        running = false
        ticking = false
    }

    /// Settings changed. Volume, delay and EQ apply instantly. A speaker change rebuilds the engine.
    private func restartSoon() {
        guard running else { return }
        syncRoutes()
    }

    private func killAll() {
        building = nil
        sync?.stop()
        sync = nil
        syncSig = ""
        live = []
    }

    /// Make the engine match what the settings ask for. Safe to call often: it only rebuilds
    /// when the set of speakers changes, otherwise it just passes the new settings along.
    /// Building happens off the main thread so the window never freezes while Core Audio works.
    func syncRoutes() {
        guard running, let bh = blackHole else { return }
        let (wired, bt) = targets
        let sig = [bh, wired, bt].map { $0.map { "\($0.uid)#\($0.id)" } ?? "-" }.joined(separator: "|")
        if sig != syncSig && sig != building {
            killAll()
            guard wired != nil || bt != nil else { return }
            building = sig
            DispatchQueue.global(qos: .userInitiated).async {
                let eng = try? SyncEngine(cable: bh, wired: wired, bt: bt)
                DispatchQueue.main.async { MainActor.assumeIsolated {
                    Engine.shared.engineReady(eng, sig: sig, speakers: [wired, bt].compactMap { $0 })
                } }
            }
            return
        }
        guard let sync else { return }
        sync.update(params)
        var l: Set<String> = []
        if wired != nil { l.insert("wired") }
        if bt != nil { l.insert("bt"); if keepAwake { l.insert("awake") } }
        if live != l { live = l }
        if waitingFor.isEmpty { error = nil }
    }

    private func engineReady(_ eng: SyncEngine?, sig: String, speakers: [OutputDevice]) {
        guard building == sig else { eng?.stop(); return }   // settings moved on while it was building
        building = nil
        guard running, let eng else {
            eng?.stop()
            if running { error = "Couldn't start the audio engine. Try turning it off and on again." }
            return
        }
        sync = eng
        syncSig = sig
        // The app's sliders and the Mac's volume keys are the controls. Run the speakers
        // themselves at full so a low Bluetooth level doesn't quietly cap it. Restored on stop.
        for dev in speakers {
            guard let v = CA.volume(dev.id) else { continue }
            if speakerVolumes[dev.id] == nil { speakerVolumes[dev.id] = v }
            CA.setVolume(dev.id, 1)
        }
        syncRoutes()
    }

    // MARK: Calibration

    /// Speakers play the chirps at 50%. If the mic can't hear them, one retry at 75%.
    func calibrate(level: Float = 0.5) {
        guard !calibrating, checking == nil else { return }
        if askForMic(then: { Engine.shared.calibrate(level: level) }) { return }
        calLevel = level
        if !running { start() }
        guard running, let bh = blackHole else { return }
        guard isPresent(resolvedWired), isPresent(resolvedBT) else {
            calibrationNote = "Connect both speakers first."; return
        }
        guard let mic = CA.micName(preferred: micChoice) else { calibrationNote = "No microphone found."; return }
        ticking = false
        calibrating = true
        calibrationNote = "Listening… keep the room quiet."
        // Turn both speakers up so the mic can hear them. Put them back afterwards.
        savedVolumes = [:]
        syncRoutes()
        let speakers = [resolvedWired, resolvedBT].compactMap { n in devices.first(where: { $0.name == n })?.id }
        for id in speakers + [bh.id] {
            guard let v = CA.volume(id) else { continue }
            savedVolumes[id] = v
            CA.setVolume(id, id == bh.id ? 1 : level)   // cable at full, speakers at the test level
        }

        let dir = FileManager.default.temporaryDirectory
        let cal = dir.appendingPathComponent("speakersync-cal.wav")
        let rec = dir.appendingPathComponent("speakersync-rec.wav")
        let cable = bh.uid
        let meter = sync
        Task.detached {
            var outcome: Calibrator.Outcome = .quiet
            var paused = false
            do {
                // Pause any music so it doesn't drown out the chirps.
                if Media.level(meter) > 0.0005 {
                    Media.pause()
                    paused = true
                    try await Task.sleep(nanoseconds: 800_000_000)
                    if Media.level(meter) > 0.0005 { throw CalibrationBusy() }
                }
                try Calibrator.writeSignal(to: cal)
                try? FileManager.default.removeItem(at: rec)
                try await Task.sleep(nanoseconds: 300_000_000)
                guard let recorder = MicRecorder(name: mic, seconds: Calibrator.length + 3),
                      recorder.start() else { throw MicFailed() }
                try await Task.sleep(nanoseconds: 500_000_000)
                Player.play(cal, uid: cable, upTo: Calibrator.length + 2)
                try await Task.sleep(nanoseconds: 600_000_000)   // Bluetooth lands a bit late
                guard recorder.stop(saveTo: rec) else { throw MicFailed() }
                outcome = Calibrator.analyze(rec)
                try? FileManager.default.removeItem(at: rec)
            } catch is CalibrationBusy {
                outcome = .busy
            } catch is MicFailed {
                outcome = .noMic
            } catch {}
            if paused { Media.play() }
            let result = outcome
            await MainActor.run { Engine.shared.finishCalibration(result) }
        }
    }

    private func finishCalibration(_ o: Calibrator.Outcome) {
        calibrating = false
        for (id, v) in savedVolumes { CA.setVolume(id, v) }
        savedVolumes = [:]
        if case .quiet = o, calLevel < 0.75 {
            calibrationNote = "Couldn't hear it. Trying again a bit louder…"
            syncRoutes()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated { Engine.shared.calibrate(level: 0.75) }
            }
            return
        }
        switch o {
        case .ok(let ms) where ms >= 0 && ms <= 600:
            let v = (ms / 5).rounded() * 5
            delayMs = v
            calibrationNote = "Measured \(Int(ms.rounded())) ms. Delay set to \(Int(v)) ms."
            d.set(ms, forKey: "lastCalibration")
        case .ok(let ms):
            calibrationNote = "Got \(Int(ms)) ms, which looks wrong. Try again closer to the speakers."
        case .quiet:
            calibrationNote = "Couldn't hear both speakers. Turn them up and try again."
        case .noisy:
            calibrationNote = "Too noisy to measure. Try again when it's quieter."
        case .busy:
            calibrationNote = "Something's still playing. Pause it and try again."
        case .noMic:
            calibrationNote = "Couldn't record from the mic. Pick a different one in Settings > General and try again."
        }
        syncRoutes()
    }

    // MARK: Speaker check

    static let checkOrder = ["left", "right", "bt"]

    /// If macOS hasn't asked about the mic yet, ask now and run `then` once answered.
    /// Returns true when it had to ask.
    private func askForMic(then: @escaping @MainActor () -> Void) -> Bool {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return false }
        AVCaptureDevice.requestAccess(for: .audio) { _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { then() } }
        }
        return true
    }

    /// Beeps the left wired speaker, then the right one, then Bluetooth. Each gets its own pitch.
    /// If mic access is on, the mic listens for each beep so you get a check mark or a warning.
    func checkSpeakers() {
        guard checking == nil, !calibrating else { return }
        if askForMic(then: { Engine.shared.checkSpeakers() }) { return }
        typealias Step = (key: String, uid: String, left: Bool, right: Bool, pitch: Double, lead: Double)
        var steps: [Step] = []
        let wiredDev = devices.first { $0.name == resolvedWired }, btDev = devices.first { $0.name == resolvedBT }
        if let w = wiredDev {
            steps.append(("left", w.uid, true, false, 660, 0))
            steps.append(("right", w.uid, false, true, 880, 0))
        }
        // A little hiss first so a sleepy Bluetooth speaker wakes up before the beep.
        if let b = btDev, b.id != wiredDev?.id { steps.append(("bt", b.uid, true, true, 1100, 0.7)) }
        checkHeard = [:]
        checkDone = []
        guard !steps.isEmpty else { checkNote = "Nothing's connected yet. Plug in the wired speaker and connect the Bluetooth one."; return }
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        let mic = status == .denied || status == .restricted ? nil : CA.micName(preferred: micChoice)
        ticking = false
        checkNote = nil
        checking = steps[0].key
        // Same as calibration: speakers at 50% so the beeps are easy to hear but not loud.
        var saved: [AudioDeviceID: Float] = [:]
        for uid in Set(steps.map(\.uid)) {
            guard let id = devices.first(where: { $0.uid == uid })?.id, let v = CA.volume(id) else { continue }
            saved[id] = v
            CA.setVolume(id, 0.5)
        }
        let savedVolumes = saved
        let meter = running ? sync : nil
        let dir = FileManager.default.temporaryDirectory
        let rec = dir.appendingPathComponent("speakersync-check.wav")
        let plan = steps
        Task.detached {
            var paused = false
            if Media.level(meter) > 0.0005 {
                Media.pause()
                paused = true
                try? await Task.sleep(nanoseconds: 600_000_000)
            }
            try? FileManager.default.removeItem(at: rec)
            var recorder: MicRecorder?
            var recStart = Date()
            if let mic, let r = MicRecorder(name: mic, seconds: 15), r.start() {
                // The mic can take a moment to start. Wait until half a second is in (that quiet
                // stretch also tells us how loud the room is).
                let deadline = Date().addingTimeInterval(5)
                while Date() < deadline {
                    if Double(r.frames) > r.rate * 0.5 {
                        recorder = r
                        recStart = Date().addingTimeInterval(-Double(r.frames) / r.rate)
                        break
                    }
                    try? await Task.sleep(nanoseconds: 20_000_000)
                }
            }
            var windows: [String: (Double, Double, Double)] = [:]
            for step in plan {
                await MainActor.run { Engine.shared.checking = step.key }
                let url = dir.appendingPathComponent("speakersync-beep-\(step.key).wav")
                try? Beeper.write(to: url, left: step.left, right: step.right, pitch: step.pitch, lead: step.lead)
                let at = Date().timeIntervalSince(recStart) + step.lead
                windows[step.key] = (at - 0.3, at + 1.0, step.pitch)
                Player.play(url, uid: step.uid, upTo: step.lead + 3)
                await MainActor.run { _ = Engine.shared.checkDone.insert(step.key) }
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
            var heard: [String: Bool] = [:]
            if let recorder {
                try? await Task.sleep(nanoseconds: 400_000_000)   // Bluetooth lands a bit late
                if recorder.stop(saveTo: rec) { heard = Beeper.heard(rec, windows: windows) }
                try? FileManager.default.removeItem(at: rec)
            }
            if paused { Media.play() }
            let result = heard, usedMic = mic
            await MainActor.run { Engine.shared.finishCheck(result, mic: usedMic, restore: savedVolumes) }
        }
    }

    private func finishCheck(_ heard: [String: Bool], mic: String?, restore: [AudioDeviceID: Float]) {
        for (id, v) in restore { CA.setVolume(id, v) }
        checking = nil
        checkHeard = heard
        guard let mic else {
            checkNote = "Did each one beep? Left, then right, then Bluetooth. Turn on mic access and it'll check for you."
            return
        }
        guard !heard.isEmpty else {
            checkNote = "Did each one beep? Left, then right, then Bluetooth. Couldn't get a recording from \(mic) to check. You can pick a different mic in Settings."
            return
        }
        let names = ["left": "left wired speaker", "right": "right wired speaker", "bt": "Bluetooth speaker"]
        let missed = Engine.checkOrder.filter { checkDone.contains($0) && heard[$0] != true }.compactMap { names[$0] }
        if missed.isEmpty {
            checkNote = "All good. Every speaker beeped and the mic heard it. If left and right sound backwards, swap the two speakers."
        } else {
            let list = missed.count == 1 ? missed[0] : missed.dropLast().joined(separator: ", ") + " or the " + missed.last!
            let it = missed.count == 1 ? "it's" : "they're"
            checkNote = "Didn't hear the \(list). Make sure \(it) on, plugged in, and turned up. The mic can miss a quiet one, so run it again if you heard the beep."
        }
    }

    // MARK: Extras

    func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            self.error = "Open at login: \(error.localizedDescription)"
        }
        openAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func updateTicker() {
        tickTimer?.invalidate()
        tickTimer = nil
        guard ticking else { return }
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { _ in
            NSSound(contentsOfFile: "/System/Library/Sounds/Tink.aiff", byReference: true)?.play()
        }
    }

    var statusText: String {
        guard running else { return "Off" }
        if let w = waitingFor.first { return "Waiting for \(w)…" }
        let n = live.subtracting(["awake"]).count
        return "Playing on \(n) speaker\(n == 1 ? "" : "s")"
    }
}

// MARK: - Themes

extension Color {
    init(hex: UInt32, _ a: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: a)
    }
    /// One color in light mode, another in dark.
    static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }
}

private func hx(_ a: UInt32, _ b: UInt32) -> [Color] { [Color(hex: a), Color(hex: b)] }

struct Accent: Identifiable {
    let id: String
    let name: String
    let color: Color
}

/// A look for the main window: colors, fonts, corner shapes.
struct Theme: Identifiable {
    let id: String
    let name: String
    let blurb: String
    var scheme: ColorScheme? = nil          // nil follows the Mac's light/dark setting
    var background: [Color]
    var card: Color
    var stroke: Color
    var text: Color = .primary
    var accent: Color
    var wired: [Color]
    var bt: [Color]
    var tiles: [[Color]]? = nil              // nil keeps each icon's own colors
    var titleFont: String? = nil
    var design: Font.Design = .default
    var radius: CGFloat = 12
    var caps = false
    var glow: Color? = nil

    func title(_ size: CGFloat) -> Font {
        // A concrete font, so the window-wide fontDesign can't swap it back to the system font.
        if let titleFont, let f = NSFont(name: titleFont, size: size) { return Font(f as CTFont) }
        return .system(size: size, weight: .semibold)
    }

    func label(_ s: String) -> String { caps ? s.uppercased() : s }

    func tile(_ symbol: String, _ own: [Color]) -> [Color] {
        guard let tiles, !tiles.isEmpty else { return own }
        let h = symbol.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return tiles[h % tiles.count]
    }

    static let accents: [Accent] = [
        Accent(id: "blue", name: "Blue", color: Color(hex: 0x0A84FF)),
        Accent(id: "purple", name: "Purple", color: Color(hex: 0xBF5AF2)),
        Accent(id: "pink", name: "Pink", color: Color(hex: 0xFF375F)),
        Accent(id: "red", name: "Red", color: Color(hex: 0xFF453A)),
        Accent(id: "orange", name: "Orange", color: Color(hex: 0xFF9F0A)),
        Accent(id: "yellow", name: "Yellow", color: Color(hex: 0xFFCC00)),
        Accent(id: "green", name: "Green", color: Color(hex: 0x30D158)),
        Accent(id: "teal", name: "Teal", color: Color(hex: 0x40C8E0)),
        Accent(id: "graphite", name: "Graphite", color: Color(hex: 0x8E8E93)),
    ]

    static let all: [Theme] = [
        Theme(id: "classic", name: "Classic", blurb: "Clean Mac look. Pick any accent color.",
              background: [Color(nsColor: .windowBackgroundColor), Color(nsColor: .windowBackgroundColor)],
              card: .dynamic(light: .white, dark: NSColor.white.withAlphaComponent(0.06)),
              stroke: .dynamic(light: NSColor.black.withAlphaComponent(0.07), dark: NSColor.white.withAlphaComponent(0.08)),
              accent: Color(hex: 0x0A84FF),
              wired: hx(0xFF9E33, 0xFA6B1A), bt: hx(0x4D8CFF, 0x1A59F2)),
        Theme(id: "groove", name: "70s Groove", blurb: "Burnt orange, mustard, and shag carpet brown.", scheme: .dark,
              background: hx(0x6B3A1E, 0x2E1A0E), card: Color(hex: 0x4A2A16, 0.9), stroke: Color(hex: 0xF5B83D, 0.35),
              text: Color(hex: 0xFFE9C7), accent: Color(hex: 0xF08A24),
              wired: hx(0xF5B83D, 0xE2711D), bt: hx(0xB5C64A, 0x6B8A23),
              tiles: [hx(0xF5B83D, 0xE2711D), hx(0xE0603A, 0xA8321C), hx(0xB5C64A, 0x6B8A23), hx(0xD98F4E, 0x8A4A1C)],
              titleFont: "Phosphate-Solid", design: .rounded, radius: 20),
        Theme(id: "rock", name: "80s Rock", blurb: "Neon pink, laser blue, big hair energy.", scheme: .dark,
              background: hx(0x3D0A5C, 0x0D0221), card: Color(hex: 0x1A0633, 0.85), stroke: Color(hex: 0xFF2E97, 0.55),
              text: .white, accent: Color(hex: 0xFF2E97),
              wired: hx(0xFF6AC1, 0xFF2E97), bt: hx(0x3DF5FF, 0x00A6FF),
              tiles: [hx(0xFF6AC1, 0xFF2E97), hx(0x3DF5FF, 0x00A6FF), hx(0xFFE53D, 0xFF9F1C), hx(0xB967FF, 0x7B2CFF)],
              titleFont: "Futura-CondensedExtraBold", radius: 6, caps: true, glow: Color(hex: 0xFF2E97)),
        Theme(id: "metal", name: "90s Metal", blurb: "Black, steel, and blood red. Turn it up.", scheme: .dark,
              background: hx(0x1E1E1E, 0x050505), card: Color(hex: 0x141414), stroke: Color(hex: 0x6B6B6B, 0.6),
              text: Color(hex: 0xE8E8E8), accent: Color(hex: 0xC1121F),
              wired: hx(0xE5383B, 0x8B0000), bt: hx(0xB0B0B0, 0x4A4A4A),
              tiles: [hx(0xE5383B, 0x8B0000), hx(0x9A9A9A, 0x3A3A3A)],
              titleFont: "Herculanum", radius: 2, caps: true),
        Theme(id: "y2k", name: "Y2K", blurb: "Frosted plastic, bubble letters, see-through blue.", scheme: .light,
              background: hx(0xE6F4FF, 0xB8D8F5), card: Color.white.opacity(0.7), stroke: Color(hex: 0x7FB3E6, 0.7),
              text: Color(hex: 0x0B2A4A), accent: Color(hex: 0x00A3E0),
              wired: hx(0xFFB3E6, 0xFF4FC3), bt: hx(0x8BE8FF, 0x0096D6),
              tiles: [hx(0x8BE8FF, 0x0096D6), hx(0xFFB3E6, 0xFF4FC3), hx(0xC6FF7F, 0x5FC400), hx(0xE6E8F0, 0x9AA0B4)],
              titleFont: "ArialRoundedMTBold", design: .rounded, radius: 24),
        Theme(id: "diner", name: "50s Diner", blurb: "Cherry red, mint green, and a milkshake.", scheme: .light,
              background: hx(0xFFF8EC, 0xFBE3C4), card: Color(hex: 0xFFFDF8), stroke: Color(hex: 0xD62828, 0.3),
              text: Color(hex: 0x3A1F1F), accent: Color(hex: 0xD62828),
              wired: hx(0xFF6B6B, 0xD62828), bt: hx(0x8EE3D1, 0x2A9D8F),
              tiles: [hx(0xFF6B6B, 0xD62828), hx(0x8EE3D1, 0x2A9D8F)],
              titleFont: "SnellRoundhand-Black", design: .serif, radius: 14),
    ]

    static func find(_ id: String, accent: String) -> Theme {
        var t = all.first { $0.id == id } ?? all[0]
        if t.id == "classic", let a = accents.first(where: { $0.id == accent }) { t.accent = a.color }
        return t
    }
}

private struct ThemeKey: EnvironmentKey { static let defaultValue = Theme.all[0] }
extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

struct Themed: ViewModifier {
    @AppStorage("theme") private var themeID = "classic"
    @AppStorage("accent") private var accentID = "blue"

    func body(content: Content) -> some View {
        let t = Theme.find(themeID, accent: accentID)
        content
            .environment(\.theme, t)
            .tint(t.accent)
            .foregroundStyle(t.text)
            .background(WindowStyler(scheme: t.scheme))
    }
}

/// Lets the theme's background run under the title bar, and forces light/dark per theme.
struct WindowStyler: NSViewRepresentable {
    let scheme: ColorScheme?

    final class Hook: NSView {
        var scheme: ColorScheme?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); apply() }
        func apply() {
            guard let w = window else { return }
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.styleMask.insert(.fullSizeContentView)
            w.titlebarSeparatorStyle = .none
            w.appearance = scheme == .dark ? NSAppearance(named: .darkAqua)
                : scheme == .light ? NSAppearance(named: .aqua) : nil
        }
    }

    func makeNSView(context: Context) -> Hook { let h = Hook(); h.scheme = scheme; return h }
    func updateNSView(_ h: Hook, context: Context) { h.scheme = scheme; h.apply() }
}

// MARK: - Building blocks

struct IconTile: View {
    @Environment(\.theme) private var t
    let symbol: String
    let colors: [Color]
    var size: CGFloat = 26
    var themed = true

    var body: some View {
        RoundedRectangle(cornerRadius: t.radius <= 6 ? size * 0.12 : size * 0.24, style: .continuous)
            .fill(LinearGradient(colors: themed ? t.tile(symbol, colors) : colors, startPoint: .top, endPoint: .bottom))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
    }
}

struct Card<Content: View>: View {
    @Environment(\.theme) private var t
    var title: String?
    var footer: String?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(t.label(title))
                    .font(t.titleFont == nil ? .subheadline.weight(.semibold) : t.title(15))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
            VStack(alignment: .leading, spacing: 10) { content }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(t.card, in: RoundedRectangle(cornerRadius: t.radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: t.radius, style: .continuous).strokeBorder(t.stroke, lineWidth: 1))
            if let footer {
                Text(footer).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

/// Icon, title, optional detail line, and whatever goes on the right.
struct Row<Trailing: View>: View {
    let symbol: String
    let colors: [Color]
    let title: String
    var detail: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: symbol, colors: colors)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
    }
}

let gray = [Color(white: 0.55), Color(white: 0.4)]

// MARK: - Main window

struct SpeakerRow: View {
    @ObservedObject var e: Engine
    let key: String
    let title: String
    let symbol: String
    let colors: [Color]
    @Binding var on: Bool
    @Binding var name: String
    @Binding var vol: Double

    var device: String { key == "wired" ? e.resolvedWired : e.resolvedBT }
    var connected: Bool { e.isPresent(device) }

    var names: [String] {
        var n = e.devices.map(\.name)
        if !name.isEmpty && name != Engine.automatic && !n.contains(name) { n.append(name) }
        return n
    }

    var subtitle: String {
        if !connected { return "Not connected" }
        if e.running && on { return e.live.contains(key) ? "Playing · \(device)" : "Starting…" }
        return device
    }

    var dotColor: Color {
        if !connected { return .secondary.opacity(0.5) }
        if e.running && on && e.live.contains(key) { return .green }
        return .green.opacity(0.6)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                IconTile(symbol: symbol, colors: colors, size: 32, themed: false)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.medium))
                    HStack(spacing: 5) {
                        Circle().fill(dotColor).frame(width: 6, height: 6)
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                Toggle("", isOn: $on).toggleStyle(.switch).labelsHidden()
            }
            HStack(spacing: 10) {
                Picker("", selection: $name) {
                    Text("Automatic").tag(Engine.automatic)
                    Divider()
                    ForEach(names, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(width: 200)
                Spacer(minLength: 12)
                Image(systemName: "speaker.fill").font(.caption).foregroundStyle(.secondary)
                Slider(value: $vol, in: 0...1)
                Image(systemName: "speaker.wave.3.fill").font(.caption).foregroundStyle(.secondary)
            }
            .disabled(!on)
        }
    }
}

struct CheckChip: View {
    @ObservedObject var e: Engine
    let key: String

    var label: String { ["left": "Left", "right": "Right", "bt": "Bluetooth"][key] ?? key }
    var connected: Bool { e.isPresent(key == "bt" ? e.resolvedBT : e.resolvedWired) }

    var body: some View {
        HStack(spacing: 4) {
            icon.font(.callout)
            Text(label).font(.callout)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Color.primary.opacity(e.checking == key ? 0.14 : 0.06), in: Capsule())
        .opacity(connected ? 1 : 0.45)
        .help(connected ? label : "\(label) isn't connected")
    }

    @ViewBuilder var icon: some View {
        if e.checking == key {
            Image(systemName: "speaker.wave.3.fill").foregroundStyle(.tint)
                .symbolEffect(.variableColor.iterative, options: .repeating)
        } else if !connected {
            Image(systemName: "xmark.circle").foregroundStyle(.secondary)
        } else if !e.checkHeard.isEmpty {
            if e.checkHeard[key] == true {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            }
        } else if e.checkDone.contains(key) {
            Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
        } else {
            Image(systemName: "circle.dashed").foregroundStyle(.secondary)
        }
    }
}

struct ContentView: View {
    @ObservedObject var e = Engine.shared
    @Environment(\.theme) private var t

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if e.blackHole == nil { SetupSection() }
            Card("Speakers") {
                SpeakerRow(e: e, key: "wired", title: "Wired", symbol: "cable.connector", colors: t.wired,
                           on: $e.wiredOn, name: $e.wiredName, vol: $e.wiredVol)
                Divider()
                SpeakerRow(e: e, key: "bt", title: "Bluetooth", symbol: "wave.3.right", colors: t.bt,
                           on: $e.btOn, name: $e.btName, vol: $e.btVol)
            }
            check
            timing
        }
        .padding(.horizontal, 18)
        .padding(.top, 4)
        .padding(.bottom, 18)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .background(LinearGradient(colors: t.background, startPoint: .top, endPoint: .bottom).ignoresSafeArea())
    }

    var header: some View {
        Card {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().interpolation(.high)
                    .frame(width: 56, height: 56)
                    .padding(-4)
                VStack(alignment: .leading, spacing: 3) {
                    Text(t.label("Speaker Sync")).font(t.title(22))
                        .shadow(color: t.glow ?? .clear, radius: 6)
                    HStack(spacing: 5) {
                        Circle().fill(e.running ? (e.waitingFor.isEmpty ? Color.green : Color.orange) : Color.secondary.opacity(0.5))
                            .frame(width: 7, height: 7)
                        Text(e.statusText).font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                SettingsLink {
                    Image(systemName: "gearshape.fill").font(.title3).foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Settings: themes, EQ, mic, and what each permission is for")
                Toggle("", isOn: Binding(get: { e.running }, set: { e.setRunning($0) }))
                    .toggleStyle(.switch).labelsHidden().controlSize(.large)
                    .disabled(e.blackHole == nil)
            }

            if e.running && e.blackHole != nil {
                HStack(spacing: 10) {
                    Text("Master").font(.callout)
                    Image(systemName: "speaker.fill").font(.caption).foregroundStyle(.secondary)
                    Slider(value: Binding(get: { e.masterVol }, set: { e.setMaster($0) }), in: 0...1)
                    Image(systemName: "speaker.wave.3.fill").font(.caption).foregroundStyle(.secondary)
                }
                Text("Your volume keys move this too. Both speakers go up and down together.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if !e.running && AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                Text("Turning this on asks for mic access. That's how the app hears your Mac's audio. Your real mic stays off. The gear explains it.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let err = e.error {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    var check: some View {
        Card("Speaker check",
             footer: "Beeps the left wired speaker, then the right one, then Bluetooth, each on its own note. If mic access is on, the mic listens and checks each one off.") {
            HStack(spacing: 8) {
                ForEach(Engine.checkOrder, id: \.self) { CheckChip(e: e, key: $0) }
                Spacer()
                if e.checking != nil {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Check") { e.checkSpeakers() }
                        .disabled(e.calibrating)
                }
            }
            if let note = e.checkNote {
                Text(note).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    var timing: some View {
        Card("Timing",
             footer: "Bluetooth always runs a little behind the cable. Hit Calibrate, keep the room quiet for about 10 seconds, and the mic figures out the delay. Or turn on the test tick and tune it by ear.") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Wired delay")
                    Spacer()
                    Text("\(Int(e.delayMs)) ms").monospacedDigit().foregroundStyle(.secondary)
                    Stepper("", value: $e.delayMs, in: 0...600, step: 5).labelsHidden()
                }
                Slider(value: $e.delayMs, in: 0...600, step: 5) {
                    EmptyView()
                } minimumValueLabel: {
                    Text("0").font(.caption).foregroundStyle(.secondary)
                } maximumValueLabel: {
                    Text("600").font(.caption).foregroundStyle(.secondary)
                }
                if let pair = e.pairLabel {
                    Text("Saved for \(pair). Each speaker remembers its own delay.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            Row(symbol: "metronome.fill", colors: [Color(hex: 0x9E66FF), Color(hex: 0x7338E6)], title: "Sync test tick") {
                Toggle("", isOn: $e.ticking).toggleStyle(.switch).labelsHidden()
                    .disabled(!e.running || e.calibrating)
            }
            Divider()
            Row(symbol: "waveform", colors: [Color(hex: 0xFF598C), Color(hex: 0xE63366)], title: "Auto-calibrate",
                detail: e.calibrationNote) {
                if e.calibrating {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Calibrate") { e.calibrate() }
                        .disabled(e.blackHole == nil || e.checking != nil)
                }
            }
        }
    }
}

struct SetupSection: View {
    @ObservedObject var e = Engine.shared
    let cmd = "brew install --cask blackhole-2ch"
    @State private var copied = false

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 12) {
                IconTile(symbol: "arrow.down.circle.fill", colors: [Color(hex: 0xFFBF33), Color(hex: 0xFF8C00)], size: 32)
                VStack(alignment: .leading, spacing: 6) {
                    Text("One-time setup").font(.body.weight(.medium))
                    if e.bundledDriver != nil {
                        Text("Speaker Sync needs its audio driver. It's a virtual cable that shows up as \u{201C}Speaker Sync\u{201D} in your Sound menu, and it's how your Mac's audio gets to both speakers. macOS asks for your password once to install it. The app never sees it.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(e.installingDriver ? "Installing…" : "Install Driver") { e.installDriver() }
                            .buttonStyle(.borderedProminent)
                            .disabled(e.installingDriver)
                    } else {
                        Text("Speaker Sync needs a virtual audio cable to work. BlackHole is free and does the job. Paste this into Terminal, type your password when it asks, then come back here.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Text(cmd).font(.system(.callout, design: .monospaced))
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .textSelection(.enabled)
                            Button(copied ? "Copied" : "Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(cmd, forType: .string)
                                copied = true
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Settings window

struct SettingsView: View {
    var body: some View {
        TabView {
            LookTab().tabItem { Label("Look", systemImage: "paintpalette") }
            SoundTab().tabItem { Label("Sound", systemImage: "slider.vertical.3") }
            GeneralTab().tabItem { Label("General", systemImage: "gearshape") }
            PrivacyTab().tabItem { Label("Privacy", systemImage: "hand.raised") }
        }
        .frame(width: 560)
    }
}

struct ThemeSwatch: View {
    let theme: Theme
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 7) {
                Text(theme.label("Speaker Sync")).font(theme.title(16)).foregroundStyle(theme.text)
                    .shadow(color: theme.glow ?? .clear, radius: 5)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    ForEach(0..<2, id: \.self) { i in
                        let c = i == 0 ? theme.wired : theme.bt
                        RoundedRectangle(cornerRadius: theme.radius <= 6 ? 2 : 5, style: .continuous)
                            .fill(LinearGradient(colors: c, startPoint: .top, endPoint: .bottom))
                            .frame(width: 18, height: 18)
                    }
                    Capsule().fill(theme.accent).frame(width: 38, height: 8)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.card, in: RoundedRectangle(cornerRadius: min(theme.radius, 10), style: .continuous))
            .padding(8)
            .background(LinearGradient(colors: theme.background, startPoint: .top, endPoint: .bottom),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: selected ? 3 : 1))
            Text(theme.name).font(.callout.weight(.medium))
            Text(theme.blurb).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .contentShape(Rectangle())
    }
}

struct LookTab: View {
    @AppStorage("theme") private var themeID = "classic"
    @AppStorage("accent") private var accentID = "blue"

    var body: some View {
        Form {
            Section("Theme") {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14), GridItem(.flexible())],
                          alignment: .leading, spacing: 14) {
                    ForEach(Theme.all) { th in
                        ThemeSwatch(theme: Theme.find(th.id, accent: accentID), selected: th.id == themeID)
                            .onTapGesture { themeID = th.id }
                    }
                }
                .padding(.vertical, 6)
            }
            Section {
                HStack(spacing: 10) {
                    ForEach(Theme.accents) { a in
                        Circle().fill(a.color).frame(width: 22, height: 22)
                            .overlay(Circle().strokeBorder(.white, lineWidth: accentID == a.id ? 3 : 0))
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.2), lineWidth: 1))
                            .onTapGesture { accentID = a.id; themeID = "classic" }
                            .help(a.name)
                    }
                }
                .padding(.vertical, 2)
            } header: {
                Text("Accent color")
            } footer: {
                Text("For the Classic theme. The other themes bring their own colors.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct EQSlider: View {
    let label: String
    @Binding var value: Double

    var body: some View {
        HStack(spacing: 10) {
            Text(label).frame(width: 52, alignment: .leading)
            Slider(value: $value, in: -12...12, step: 1)
            Text(value == 0 ? "Flat" : String(format: "%+.0f dB", value))
                .monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 54, alignment: .trailing)
        }
    }
}

struct SoundTab: View {
    @ObservedObject var e = Engine.shared

    var body: some View {
        Form {
            Section("Wired speaker") {
                EQSlider(label: "Bass", value: $e.wiredBass)
                EQSlider(label: "Treble", value: $e.wiredTreble)
            }
            Section {
                EQSlider(label: "Bass", value: $e.btBass)
                EQSlider(label: "Treble", value: $e.btTreble)
            } header: {
                Text("Bluetooth speaker")
            } footer: {
                Text("Every speaker sounds a little different. Use these to get them closer to each other. A few dB goes a long way. Boosting turns that speaker down a touch so it doesn't distort, and each change takes a second to kick in.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("Reset to flat") {
                    e.wiredBass = 0; e.wiredTreble = 0; e.btBass = 0; e.btTreble = 0
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct GeneralTab: View {
    @ObservedObject var e = Engine.shared

    var mics: [String] {
        var m = CA.micNames()
        if e.micChoice != Engine.automatic && !m.contains(e.micChoice) { m.append(e.micChoice) }
        return m
    }

    var body: some View {
        Form {
            Section("Turning on and off") {
                Row(symbol: "antenna.radiowaves.left.and.right", colors: [Color(hex: 0x4D8CFF), Color(hex: 0x1A59F2)],
                    title: "Follow the Bluetooth speaker",
                    detail: "Turns sync on when your Bluetooth speaker connects, and off once it's been gone for 10 seconds.") {
                    Toggle("", isOn: $e.autoSwitch).toggleStyle(.switch).labelsHidden()
                }
                Row(symbol: "play.fill", colors: [Color(hex: 0x4DCC66), Color(hex: 0x26A64D)], title: "Start syncing when opened") {
                    Toggle("", isOn: $e.autoStart).toggleStyle(.switch).labelsHidden()
                }
                Row(symbol: "power", colors: gray, title: "Open at login") {
                    Toggle("", isOn: Binding(get: { e.openAtLogin }, set: { e.setOpenAtLogin($0) }))
                        .toggleStyle(.switch).labelsHidden()
                }
                Row(symbol: "keyboard", colors: gray, title: "Turn sync on or off from anywhere") {
                    Text("\u{2303}\u{2325}\u{2318}S").font(.system(.body, design: .rounded)).foregroundStyle(.secondary)
                }
            }
            Section("Speakers") {
                Row(symbol: "moon.zzz.fill", colors: [Color(hex: 0x6673FF), Color(hex: 0x4040D9)],
                    title: "Keep Bluetooth speaker awake",
                    detail: "Sends a tone too low to hear so the speaker doesn't fall asleep between songs.") {
                    Toggle("", isOn: $e.keepAwake).toggleStyle(.switch).labelsHidden()
                }
                if !e.driverInstalled && e.blackHole != nil && e.bundledDriver != nil {
                    Row(symbol: "speaker.badge.exclamationmark.fill", colors: [Color(hex: 0x33BFD9), Color(hex: 0x1A8CBF)],
                        title: "Show as \u{201C}Speaker Sync\u{201D} in the Sound menu",
                        detail: "Swaps stock BlackHole for the app's own driver. macOS asks for your password.") {
                        if e.installingDriver { ProgressView().controlSize(.small) }
                        else { Button("Install") { e.installDriver() } }
                    }
                }
            }
            Section {
                Picker("Calibration mic", selection: $e.micChoice) {
                    Text("Automatic").tag(Engine.automatic)
                    Divider()
                    ForEach(mics, id: \.self) { Text($0).tag($0) }
                }
            } header: {
                Text("Microphone")
            } footer: {
                Text("Used for Calibrate and Speaker check. Your iPhone shows up here when it's nearby and unlocked. Holding it about halfway between the speakers gives the best reading.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct PrivacyTab: View {
    @State private var mic = AVCaptureDevice.authorizationStatus(for: .audio)

    var micStatus: (String, Color) {
        switch mic {
        case .authorized: return ("Allowed", .green)
        case .denied, .restricted: return ("Not allowed", .orange)
        default: return ("Not asked yet", .secondary)
        }
    }

    var body: some View {
        Form {
            Section {
                Row(symbol: "mic.fill", colors: [Color(hex: 0xFF6259), Color(hex: 0xE0382E)], title: "Microphone") {
                    Text(micStatus.0).foregroundStyle(micStatus.1)
                }
                Text("macOS treats the Speaker Sync cable like a microphone. All your Mac's audio goes into that cable, and the app has to listen to it to send the sound to your speakers. No mic access, no sound.")
                    .fixedSize(horizontal: false, vertical: true)
                Text("Your real mic only turns on when you hit Calibrate or Speaker check. It records about 10 seconds, measures it, and deletes the recording right away. It never listens in the background and nothing gets saved or sent anywhere.")
                    .fixedSize(horizontal: false, vertical: true)
                if mic == .denied || mic == .restricted {
                    Button("Open Microphone Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                    }
                } else if mic == .notDetermined {
                    Button("Allow Microphone") {
                        AVCaptureDevice.requestAccess(for: .audio) { _ in
                            Task { @MainActor in mic = AVCaptureDevice.authorizationStatus(for: .audio) }
                        }
                    }
                }
            }
            Section {
                Row(symbol: "lock.fill", colors: gray, title: "Your password") { EmptyView() }
                Text("Only asked once, when you install the driver. macOS asks for it, not Speaker Sync, so the app never sees it or stores it. It's used to copy the driver into /Library/Audio/Plug-Ins/HAL, where every Mac audio driver lives, then restart the Mac's audio so the new device shows up.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Row(symbol: "pause.fill", colors: [Color(hex: 0xFF9E33), Color(hex: 0xFA6B1A)], title: "Pausing your music") { EmptyView() }
                Text("Calibrate and Speaker check pause whatever's playing and start it back up after, the same way the play/pause key on your keyboard does. No permission needed. The app can tell something's playing, but not what.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Row(symbol: "network.slash", colors: [Color(hex: 0x4DCC66), Color(hex: 0x26A64D)], title: "Internet") { EmptyView() }
                Text("Speaker Sync never goes online. No account, no tracking, no analytics. Everything stays on your Mac.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Row(symbol: "keyboard", colors: gray, title: "Keyboard shortcut") { EmptyView() }
                Text("\u{2303}\u{2325}\u{2318}S works without Accessibility access. It only watches for that one key combo, nothing else you type.")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(height: 560)
        .onAppear { mic = AVCaptureDevice.authorizationStatus(for: .audio) }
    }
}

// MARK: - Menu bar

struct MenuContent: View {
    @ObservedObject var e = Engine.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(e.statusText)
        Toggle("Sync Speakers", isOn: Binding(get: { e.running }, set: { e.setRunning($0) }))
            .disabled(e.blackHole == nil)
            .keyboardShortcut("s", modifiers: [.control, .option, .command])
        Text("Wired delay: \(Int(e.delayMs)) ms")
        Button(e.calibrating ? "Calibrating…" : "Auto-Calibrate") { e.calibrate() }
            .disabled(e.calibrating || e.checking != nil || e.blackHole == nil)
        if let note = e.calibrationNote, !e.calibrating { Text(note) }
        Button(e.checking != nil ? "Checking…" : "Speaker Check") { e.checkSpeakers() }
            .disabled(e.calibrating || e.checking != nil)
        Divider()
        Button("Open Speaker Sync…") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")
        Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

/// Control-Option-Command-S toggles sync from anywhere. Carbon hot keys need no
/// Accessibility permission.
enum HotKey {
    nonisolated(unsafe) static var ref: EventHotKeyRef?

    static func register() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let e = Engine.shared
                    if e.blackHole != nil { e.setRunning(!e.running) }
                    NSSound(named: e.running ? "Pop" : "Bottle")?.play()
                }
            }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x5353_594E), id: 1)   // 'SSYN'
        RegisterEventHotKey(UInt32(kVK_ANSI_S), UInt32(controlKey | optionKey | cmdKey), id,
                            GetApplicationEventTarget(), 0, &ref)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { _ = Engine.shared }
        HotKey.register()
        let args = CommandLine.arguments
        if args.contains("--calibrate") || args.contains("--check") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                MainActor.assumeIsolated {
                    args.contains("--check") ? Engine.shared.checkSpeakers() : Engine.shared.calibrate()
                }
            }
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { Engine.shared.stop() }
    }
}

@main
struct SpeakerSyncApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Window("Speaker Sync", id: "main") {
            ContentView().modifier(Themed())
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)

        Settings {
            SettingsView()
        }

        MenuBarExtra("Speaker Sync", systemImage: "hifispeaker.2.fill") {
            MenuContent()
        }
    }
}
