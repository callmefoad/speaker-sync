// Speaker Sync — play Mac audio on a Bluetooth speaker and a wired speaker at once,
// with a delay on the wired side so both line up.
//
// Audio path:  Mac apps -> BlackHole 2ch (virtual cable)
//              -> sox #1 -> wired speaker (delayed)
//              -> sox #2 -> Bluetooth speaker

import SwiftUI
import CoreAudio
import AppKit
import AVFoundation
import ServiceManagement

let soxPath = "/opt/homebrew/bin/sox"

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

    static func setDefaultOutput(_ id: AudioDeviceID) {
        var dev = id
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var a = addr(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectSetPropertyData(system, &a, 0, nil, size, &dev)
        var s = addr(kAudioHardwarePropertyDefaultSystemOutputDevice)
        AudioObjectSetPropertyData(system, &s, 0, nil, size, &dev)
    }
}

// MARK: - Engine

struct Route {
    let key: String       // "wired" or "bt"
    let device: String    // concrete device name for sox
    let vol: Double
    let delay: Double     // seconds
    var signature: String { "\(device)|\(vol)|\(delay)" }
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

    @Published var wiredOn: Bool     { didSet { d.set(wiredOn, forKey: "wiredOn"); restartSoon() } }
    @Published var btOn: Bool        { didSet { d.set(btOn, forKey: "btOn"); restartSoon() } }
    @Published var wiredName: String { didSet { d.set(wiredName, forKey: "wiredName"); restartSoon() } }
    @Published var btName: String    { didSet { d.set(btName, forKey: "btName"); restartSoon() } }
    @Published var wiredVol: Double  { didSet { d.set(wiredVol, forKey: "wiredVol"); restartSoon() } }
    @Published var btVol: Double     { didSet { d.set(btVol, forKey: "btVol"); restartSoon() } }
    @Published var delayMs: Double   { didSet { d.set(delayMs, forKey: "delayMs"); restartSoon() } }
    @Published var autoStart: Bool   { didSet { d.set(autoStart, forKey: "autoStart") } }

    var soxInstalled: Bool { FileManager.default.isExecutableFile(atPath: soxPath) }

    private var procs: [String: (Process, String)] = [:]   // key -> (process, route signature)
    private var previousDefault: AudioDeviceID?
    private var pending: DispatchWorkItem?
    private var tickTimer: Timer?
    private var pollTimer: Timer?

    private init() {
        d.register(defaults: [
            "wiredOn": true, "btOn": true,
            "wiredName": Engine.automatic, "btName": Engine.automatic,
            "wiredVol": 1.0, "btVol": 1.0, "delayMs": 180.0, "autoStart": true,
        ])
        wiredOn = d.bool(forKey: "wiredOn")
        btOn = d.bool(forKey: "btOn")
        wiredName = d.string(forKey: "wiredName") ?? Engine.automatic
        btName = d.string(forKey: "btName") ?? Engine.automatic
        wiredVol = d.double(forKey: "wiredVol")
        btVol = d.double(forKey: "btVol")
        delayMs = d.double(forKey: "delayMs")
        autoStart = d.bool(forKey: "autoStart")
        refresh()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in Engine.shared.refresh() }
        }
        if autoStart {
            DispatchQueue.main.async { Task { @MainActor in
                let e = Engine.shared
                if e.blackHole != nil && e.soxInstalled { e.start() }
            } }
        }
    }

    // MARK: Devices

    func refresh() {
        let all = CA.outputs()
        blackHole = all.first { $0.name.localizedCaseInsensitiveContains("BlackHole") }
        // Hide the BlackHole cable itself plus aggregate/virtual devices (Multi-Output, Zoom, etc.)
        devices = all.filter {
            !$0.name.localizedCaseInsensitiveContains("BlackHole") && !$0.isVirtual
        }
        guard running else { return }
        guardDefaultOutput()
        syncRoutes()
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
        guard cur != bh.id, let dev = devices.first(where: { $0.id == cur }) else { return }
        let ours = dev.name == resolvedWired || dev.name == resolvedBT
            || dev.name.localizedCaseInsensitiveContains("Headphones")
        if ours { CA.setDefaultOutput(bh.id) }
    }

    // MARK: Routes

    var desiredRoutes: [Route] {
        var r: [Route] = []
        if wiredOn { r.append(Route(key: "wired", device: resolvedWired, vol: wiredVol, delay: delayMs / 1000)) }
        if btOn { r.append(Route(key: "bt", device: resolvedBT, vol: btVol, delay: 0)) }
        return r
    }

    var waitingFor: [String] {
        desiredRoutes.filter { !live.contains($0.key) }.map(\.device)
    }

    func setRunning(_ on: Bool) { on ? start() : stop() }

    func start() {
        error = nil
        refresh()
        guard soxInstalled else { error = "sox isn't installed."; return }
        guard let bh = blackHole else { error = "BlackHole isn't installed yet."; return }
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        let current = CA.defaultOutput()
        if current != bh.id { previousDefault = current }
        CA.setDefaultOutput(bh.id)
        running = true
        syncRoutes()
    }

    func stop() {
        pending?.cancel()
        killAll()
        if let prev = previousDefault, CA.outputs().contains(where: { $0.id == prev }) {
            CA.setDefaultOutput(prev)
        } else if let fallback = devices.first(where: { $0.uid == "BuiltInSpeakerDevice" }) {
            CA.setDefaultOutput(fallback.id)
        }
        previousDefault = nil
        running = false
        ticking = false
    }

    private func restartSoon() {
        guard running else { return }
        pending?.cancel()
        let work = DispatchWorkItem { Task { @MainActor in Engine.shared.syncRoutes() } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func killAll() {
        let old = procs
        procs = [:]
        live = []
        old.values.forEach { $0.0.terminate() }
    }

    private func kill(_ key: String) {
        guard let (p, _) = procs.removeValue(forKey: key) else { return }
        live.remove(key)
        p.terminate()
    }

    /// Make running sox processes match what the settings ask for. Safe to call often:
    /// it starts missing routes, restarts changed ones, and stops unwanted ones.
    func syncRoutes() {
        guard running, let bh = blackHole else { return }
        let want = desiredRoutes
        for key in procs.keys where !want.contains(where: { $0.key == key }) { kill(key) }
        for r in want {
            if let (_, sig) = procs[r.key], sig != r.signature { kill(r.key) }
            guard procs[r.key] == nil, isPresent(r.device) else { continue }
            launch(r, from: bh.name)
        }
        if waitingFor.isEmpty { error = nil }
    }

    private func launch(_ r: Route, from input: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: soxPath)
        let dl = String(format: "%.3f", r.delay)
        p.arguments = ["-q", "--buffer", "2048",
                       "-t", "coreaudio", input,
                       "-t", "coreaudio", r.device,
                       "vol", String(format: "%.3f", max(r.vol, 0.001)),
                       "delay", dl, dl]
        let errPipe = Pipe()
        p.standardError = errPipe
        p.standardOutput = FileHandle.nullDevice
        let key = r.key, device = r.device
        p.terminationHandler = { proc in
            let msg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            Task { @MainActor in
                let e = Engine.shared
                guard let (cur, _) = e.procs[key], cur === proc else { return } // stopped on purpose
                e.procs.removeValue(forKey: key)
                e.live.remove(key)
                // Speaker probably dropped. The 2s poll relaunches it when it's back.
                let detail = msg.trimmingCharacters(in: .whitespacesAndNewlines)
                if e.isPresent(device) && !detail.isEmpty { e.error = "\(device): \(detail)" }
            }
        }
        do {
            try p.run()
            procs[r.key] = (p, r.signature)
            live.insert(r.key)
        } catch {
            self.error = "Couldn't start audio for \(r.device)."
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
        return "Playing on \(live.count) speaker\(live.count == 1 ? "" : "s")"
    }
}

// MARK: - UI

struct IconTile: View {
    let symbol: String
    let colors: [Color]
    var size: CGFloat = 26

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
    }
}

struct SpeakerSection: View {
    @ObservedObject var e: Engine
    let key: String
    let title: String
    let symbol: String
    let colors: [Color]
    let allowAutomatic: Bool
    @Binding var on: Bool
    @Binding var name: String
    @Binding var vol: Double

    var device: String { key == "wired" ? e.resolvedWired : e.resolvedBT }

    var names: [String] {
        var n = e.devices.map(\.name)
        if !name.isEmpty && name != Engine.automatic && !n.contains(name) { n.append(name) }
        return n
    }

    var connected: Bool { e.isPresent(device) }

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
        Section {
            HStack(spacing: 12) {
                IconTile(symbol: symbol, colors: colors, size: 32)
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
            .padding(.vertical, 2)

            Picker("Output", selection: $name) {
                if allowAutomatic {
                    Text("Automatic").tag(Engine.automatic)
                    Divider()
                }
                ForEach(names, id: \.self) { Text($0).tag($0) }
            }
            .disabled(!on)

            HStack(spacing: 10) {
                Text("Volume")
                Spacer(minLength: 24)
                Image(systemName: "speaker.fill").font(.caption).foregroundStyle(.secondary)
                Slider(value: $vol, in: 0...1).frame(maxWidth: 220)
                Image(systemName: "speaker.wave.3.fill").font(.caption).foregroundStyle(.secondary)
            }
            .disabled(!on)
        }
    }
}

struct ContentView: View {
    @ObservedObject var e = Engine.shared

    var body: some View {
        Form {
            // Header
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable().interpolation(.high)
                        .frame(width: 60, height: 60)
                        .padding(-4)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Speaker Sync").font(.title3.weight(.semibold))
                        HStack(spacing: 5) {
                            Circle().fill(e.running ? (e.waitingFor.isEmpty ? Color.green : Color.orange) : Color.secondary.opacity(0.5))
                                .frame(width: 7, height: 7)
                            Text(e.statusText).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Toggle("", isOn: Binding(get: { e.running }, set: { e.setRunning($0) }))
                        .toggleStyle(.switch).labelsHidden().controlSize(.large)
                        .disabled(e.blackHole == nil || !e.soxInstalled)
                }
                .padding(.vertical, 6)

                if let err = e.error {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            }

            if e.blackHole == nil {
                SetupSection()
            }

            SpeakerSection(e: e, key: "wired", title: "Wired", symbol: "cable.connector",
                           colors: [Color(red: 1.0, green: 0.62, blue: 0.2), Color(red: 0.98, green: 0.42, blue: 0.1)],
                           allowAutomatic: true,
                           on: $e.wiredOn, name: $e.wiredName, vol: $e.wiredVol)

            SpeakerSection(e: e, key: "bt", title: "Bluetooth", symbol: "wave.3.right",
                           colors: [Color(red: 0.3, green: 0.55, blue: 1.0), Color(red: 0.1, green: 0.35, blue: 0.95)],
                           allowAutomatic: true,
                           on: $e.btOn, name: $e.btName, vol: $e.btVol)

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Wired delay")
                        Spacer()
                        Text("\(Int(e.delayMs)) ms")
                            .monospacedDigit().foregroundStyle(.secondary)
                        Stepper("", value: $e.delayMs, in: 0...600, step: 5).labelsHidden()
                    }
                    Slider(value: $e.delayMs, in: 0...600, step: 5) {
                        EmptyView()
                    } minimumValueLabel: {
                        Text("0").font(.caption).foregroundStyle(.secondary)
                    } maximumValueLabel: {
                        Text("600").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)

                Toggle(isOn: $e.ticking) {
                    HStack(spacing: 12) {
                        IconTile(symbol: "metronome.fill", colors: [Color(red: 0.62, green: 0.4, blue: 1.0), Color(red: 0.45, green: 0.22, blue: 0.9)])
                        Text("Sync test tick")
                    }
                }
                .disabled(!e.running)
            } header: {
                Text("Timing")
            } footer: {
                Text("Bluetooth runs a little behind the cable. Turn on the test tick, then drag the delay until both speakers click at the same time.")
                    .foregroundStyle(.secondary)
            }

            Section("General") {
                Toggle(isOn: Binding(get: { e.openAtLogin }, set: { e.setOpenAtLogin($0) })) {
                    HStack(spacing: 12) {
                        IconTile(symbol: "power", colors: [Color(white: 0.55), Color(white: 0.4)])
                        Text("Open at login")
                    }
                }
                Toggle(isOn: $e.autoStart) {
                    HStack(spacing: 12) {
                        IconTile(symbol: "play.fill", colors: [Color(red: 0.3, green: 0.8, blue: 0.4), Color(red: 0.15, green: 0.65, blue: 0.3)])
                        Text("Start syncing when opened")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct SetupSection: View {
    let cmd = "brew install --cask blackhole-2ch"
    @State private var copied = false

    var body: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                IconTile(symbol: "arrow.down.circle.fill", colors: [Color(red: 1.0, green: 0.75, blue: 0.2), Color(red: 1.0, green: 0.55, blue: 0.0)], size: 32)
                VStack(alignment: .leading, spacing: 6) {
                    Text("One-time setup").font(.body.weight(.medium))
                    Text("Speaker Sync needs BlackHole, a free virtual audio cable. Paste this into Terminal, enter your password, then come back.")
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
            .padding(.vertical, 4)
        }
    }
}

struct MenuContent: View {
    @ObservedObject var e = Engine.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(e.statusText)
        Toggle("Sync Speakers", isOn: Binding(get: { e.running }, set: { e.setRunning($0) }))
            .disabled(e.blackHole == nil)
        Divider()
        Button("Open Speaker Sync…") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { _ = Engine.shared }
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
            ContentView()
        }
        .windowResizability(.contentSize)

        MenuBarExtra("Speaker Sync", systemImage: "hifispeaker.2.fill") {
            MenuContent()
        }
    }
}
