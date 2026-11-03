import SwiftUI
import AppKit
import AVFoundation
import CoreAudio

// MARK: - 清單項目

/// 下拉選單裡的一個 App。音訊行程依 bundle ID 歸類（主程式＋以 bundle ID 開頭的輔助行程），共用元件不納入。
struct AudioAppEntry: Identifiable, Equatable {
    let id: String              // bundle ID
    let name: String
    let icon: NSImage?
    let audioProcessCount: Int
    let isOutputting: Bool

    static func == (a: AudioAppEntry, b: AudioAppEntry) -> Bool {
        a.id == b.id && a.name == b.name && a.audioProcessCount == b.audioProcessCount && a.isOutputting == b.isOutputting
    }

    var menuLabel: String {
        if isOutputting { return "\(name)  ▶" }
        if audioProcessCount == 0 { return "\(name)（尚未出聲）" }
        return name
    }
}

struct MicEntry: Identifiable, Equatable {
    let id: String              // 裝置 UID
    let name: String
    let channels: Int
    let rate: Double
    let transport: String
    let isBluetooth: Bool
    let isDefault: Bool

    var menuLabel: String {
        var s = name
        if isDefault { s += "（系統預設）" }
        s += " — \(channels) 聲道，\(transport)"
        return s
    }
}

func loadAudioApps() -> [AudioAppEntry] {
    let processes = listAudioProcesses()
    let own = Bundle.main.bundleIdentifier ?? "local.appaudiorecorder"
    var seen = Set<String>()
    var result: [AudioAppEntry] = []
    for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
        guard let bid = app.bundleIdentifier, bid != own, bid != "local.appaudiorecorder", !seen.contains(bid) else { continue }
        seen.insert(bid)
        let mine = processesForBundle(bid, in: processes)
        let icon = app.icon?.copy() as? NSImage
        icon?.size = NSSize(width: 16, height: 16)
        result.append(AudioAppEntry(id: bid, name: app.localizedName ?? bid, icon: icon,
                                    audioProcessCount: mine.count,
                                    isOutputting: mine.contains { $0.isOutputting }))
    }
    return result.sorted { a, b in
        let ra = a.isOutputting ? 0 : (a.audioProcessCount > 0 ? 1 : 2)
        let rb = b.isOutputting ? 0 : (b.audioProcessCount > 0 ? 1 : 2)
        if ra != rb { return ra < rb }
        return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }
}

func loadMics() -> [MicEntry] {
    let defaultID = defaultDeviceID(kAudioHardwarePropertyDefaultInputDevice)
    return listDevices().filter { $0.inputChannels > 0 }.map {
        MicEntry(id: $0.uid, name: $0.name, channels: $0.inputChannels, rate: $0.nominalRate,
                 transport: $0.transport, isBluetooth: $0.isBluetooth, isDefault: $0.id == defaultID)
    }
}

func dbfs(_ linear: Float) -> Float {
    linear > 0.000_001 ? 20 * log10(linear) : -120
}

func formatElapsed(_ t: TimeInterval) -> String {
    let s = Int(t)
    return String(format: "%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
}

func statusDescription(_ status: String) -> String {
    switch status {
    case "completed": return "完成"
    case "completed_with_gaps": return "完成，但錄音中有缺口（已補成無聲）"
    case "no_data": return "沒有收到音訊資料"
    case "write_error": return "寫檔失敗"
    case "timeline_error": return "時間線無法保證"
    case "stopped_on_device_change": return "裝置變動後無法接續，已停止（之前的內容已保存）"
    case "failed_to_start": return "無法開始錄音"
    default: return status
    }
}

// MARK: - 狀態

struct SessionResult {
    let dir: URL
    let status: String
    let exportStatus: String?     // nil = 尚未匯出或不匯出
    let lines: [String]
    var transcript: TranscriptOutcome? = nil
}

@MainActor
final class RecorderModel: ObservableObject {
    enum Phase { case idle, starting, recording, stopping, exporting, finished }

    @Published var apps: [AudioAppEntry] = []
    @Published var mics: [MicEntry] = []
    /// 「App」選單裡代表「不錄 App（只錄麥克風）」的值
    static let noAppID = "__none__"
    @Published var selectedAppID: String = UserDefaults.standard.string(forKey: "selectedAppID") ?? "" {
        didSet { UserDefaults.standard.set(selectedAppID, forKey: "selectedAppID") }
    }
    /// 空字串 = 不錄麥克風
    @Published var selectedMicUID: String = UserDefaults.standard.string(forKey: "selectedMicUID") ?? "__default__" {
        didSet { UserDefaults.standard.set(selectedMicUID, forKey: "selectedMicUID") }
    }
    @Published var outputPath: String = UserDefaults.standard.string(forKey: "outputPath")
        ?? (NSHomeDirectory() as NSString).appendingPathComponent("Music/AppAudioRecorder") {
        didSet { UserDefaults.standard.set(outputPath, forKey: "outputPath") }
    }
    /// 逐字稿用檔案：auto / mix / mic / none
    @Published var transcriptChoice: String = (UserDefaults.standard.string(forKey: "transcriptChoice") == "mic" ? "mic" : "mix") {
        didSet { UserDefaults.standard.set(transcriptChoice, forKey: "transcriptChoice") }
    }
    /// 「自動」目前會選什麼（依現在的輸出裝置）
    @Published var outputSuggestion: String = ""
    @Published var phase: Phase = .idle
    @Published var elapsed: TimeInterval = 0
    @Published var appLevel: Float = -120
    @Published var micLevel: Float = -120
    @Published var appPeakHold: Float = -120
    @Published var micPeakHold: Float = -120
    @Published var notices: [String] = []
    @Published var errorMessage: String?
    @Published var result: SessionResult?

    private var recorder: SessionRecorder?
    private var timer: Timer?
    private var tickCount = 0

    /// 合成檔的音量微調（dB，加在自動調整之上），下次開啟沿用
    @Published var appOffsetDb: Double = UserDefaults.standard.double(forKey: "mixAppOffsetDb") {
        didSet { UserDefaults.standard.set(appOffsetDb, forKey: "mixAppOffsetDb") }
    }
    @Published var micOffsetDb: Double = UserDefaults.standard.double(forKey: "mixMicOffsetDb") {
        didSet { UserDefaults.standard.set(micOffsetDb, forKey: "mixMicOffsetDb") }
    }
    @Published var remixing = false

    /// 用目前的音量微調，重新產生這次錄音的合成檔（原始檔不動）。
    func remix() {
        guard let r = result, !remixing else { return }
        remixing = true
        let dir = r.dir, a = appOffsetDb, m = micOffsetDb
        Task {
            let t = await Task.detached(priority: .userInitiated) {
                TranscriptMaker.run(dir: dir, choice: .mix, appOffsetDb: a, micOffsetDb: m, log: { _ in })
            }.value
            var updated = r
            updated.transcript = t
            self.result = updated
            self.remixing = false
        }
    }

    var isBusy: Bool { phase == .starting || phase == .recording || phase == .stopping || phase == .exporting }
    var selectedApp: AudioAppEntry? { apps.first { $0.id == selectedAppID } }
    var selectedMic: MicEntry? { mics.first { $0.id == selectedMicUID } }
    var recordsMic: Bool { !selectedMicUID.isEmpty }
    var recordsApp: Bool { selectedAppID != Self.noAppID }
    /// 兩個都選「不錄」時不能開始
    var hasSource: Bool { recordsApp || recordsMic }
    var canStart: Bool { hasSource && (!recordsApp || selectedApp != nil) }
    /// 結果畫面用：這次會匯出哪些 m4a
    var exportedFileNames: String {
        var names: [String] = []
        if recordsApp { names.append("app.m4a") }
        if recordsMic { names.append("microphone.m4a") }
        return names.joined(separator: "、")
    }

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    // MARK: 清單

    func refresh() {
        let newApps = loadAudioApps()
        if newApps != apps { apps = newApps }
        if recordsApp && selectedApp == nil {
            selectedAppID = apps.first(where: { $0.isOutputting })?.id ?? apps.first?.id ?? ""
        }
        let newMics = loadMics()
        if newMics != mics { mics = newMics }
        let (_, why) = TranscriptMaker.suggestionForCurrentOutput()
        let suggestion = "錄完依回音偵測決定（目前\(why)）"
        if suggestion != outputSuggestion { outputSuggestion = suggestion }
        if !selectedMicUID.isEmpty && selectedMic == nil {
            // 第一次開啟，或之前選的麥克風已不存在：改用系統預設輸入
            selectedMicUID = mics.first(where: { $0.isDefault })?.id ?? ""
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "選擇"
        panel.directoryURL = URL(fileURLWithPath: (outputPath as NSString).expandingTildeInPath)
        if panel.runModal() == .OK, let url = panel.url {
            outputPath = url.path
        }
    }

    // MARK: 錄音

    func start() {
        guard !isBusy else { return }
        errorMessage = nil
        result = nil
        guard hasSource else {
            errorMessage = "「App」和「麥克風」不能都選「不錄」，至少要錄一個。"
            return
        }
        var app: AudioAppEntry? = nil
        var processes: [AudioProcess] = []
        if recordsApp {
            guard let selected = selectedApp else {
                errorMessage = "請先選擇要錄音的 App。"
                return
            }
            processes = processesForBundle(selected.id, in: listAudioProcesses())
            guard !processes.isEmpty else {
                errorMessage = "「\(selected.name)」目前沒有向系統註冊音訊。請先讓它播放一次聲音，再按「重新整理」。"
                return
            }
            app = selected
        }
        let chosenApp = app, chosenProcesses = processes
        var mic: AudioDevice? = nil
        if recordsMic {
            guard let device = listDevices().first(where: { $0.uid == selectedMicUID && $0.inputChannels > 0 }) else {
                errorMessage = "找不到選擇的麥克風，請按「重新整理」後重新選擇。"
                return
            }
            mic = device
        }
        phase = .starting
        Task {
            if mic != nil {
                let granted = await Self.microphoneAccess()
                if !granted {
                    self.errorMessage = self.recordsApp
                        ? "沒有麥克風權限。請到「系統設定 → 隱私權與安全性 → 麥克風」允許 AppAudioRecorder，或改選「不錄麥克風」。"
                        : "沒有麥克風權限。請到「系統設定 → 隱私權與安全性 → 麥克風」允許 AppAudioRecorder。"
                    self.phase = .idle
                    return
                }
            }
            self.begin(app: chosenApp, processes: chosenProcesses, mic: mic)
        }
    }

    private static func microphoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    private func begin(app: AudioAppEntry?, processes: [AudioProcess], mic: AudioDevice?) {
        let root = URL(fileURLWithPath: (outputPath as NSString).expandingTildeInPath)
        let options = RecordOptions(selector: app.map { "bundle:\($0.id)" } ?? "", processes: processes, mic: mic,
                                    clock: .output, tapAutoStart: false, outputRoot: root,
                                    recordApp: app != nil)
        let r = SessionRecorder(options: options)
        do {
            try r.start()
        } catch {
            r.stop()
            errorMessage = "無法開始錄音：\(error)"
            phase = .idle
            return
        }
        recorder = r
        elapsed = 0
        notices = []
        appLevel = -120; micLevel = -120; appPeakHold = -120; micPeakHold = -120
        phase = .recording
    }

    func stop(reason: String? = nil) {
        guard phase == .recording, let r = recorder else { return }
        phase = .stopping
        let summary = r.stop(reason: reason)
        recorder = nil
        appLevel = -120; micLevel = -120
        let status = summary["status"] as? String ?? "?"
        var lines = summarize(summary)
        if let reason { lines.insert("停止原因：\(reason)", at: 0) }
        guard let dir = r.sessionDir else {
            phase = .idle
            return
        }
        if ["failed_to_start", "no_data"].contains(status) {
            result = SessionResult(dir: dir, status: status, exportStatus: nil, lines: lines)
            phase = .finished
            return
        }
        result = SessionResult(dir: dir, status: status, exportStatus: nil, lines: lines)
        phase = .exporting
        // 只錄一軌時不用合成：逐字稿直接用那一軌（由 TranscriptMaker 依實際檔案判斷）
        let choice = (transcriptChoice == "mic" || !recordsApp ? TranscriptMode.mic : .mix)
        let appOff = appOffsetDb, micOff = micOffsetDb
        Task {
            let (exportStatus, transcript) = await Task.detached(priority: .userInitiated) {
                let e = M4AExporter.exportSession(dir, log: { _ in })
                let t: TranscriptOutcome? = choice == .none ? nil : TranscriptMaker.run(dir: dir, choice: choice, appOffsetDb: appOff, micOffsetDb: micOff, log: { _ in })
                return (e, t)
            }.value
            self.result = SessionResult(dir: dir, status: status, exportStatus: exportStatus, lines: lines,
                                        transcript: transcript)
            self.phase = .finished
            self.refresh()
        }
    }

    /// App 結束時：停止並保存 CAF（不匯出；之後可用 export 指令匯出）。
    func stopForQuit() {
        guard phase == .recording, let r = recorder else { return }
        _ = r.stop(reason: "App 結束")
        recorder = nil
    }

    private func summarize(_ s: [String: Any]) -> [String] {
        var lines: [String] = []
        if let t = s["timeline"] as? [String: Any], let sec = t["seconds"] as? Double {
            lines.append("長度 \(formatElapsed(sec))（\(String(format: "%.1f", sec)) 秒）")
        }
        if let g = s["gaps"] as? [String: Any] {
            if let st = g["startup"] as? [String: Any], let ev = (st["events"] as? NSNumber)?.intValue, ev > 0 {
                lines.append("開頭有 \(ev) 次極短的啟動暫態（已補成無聲，不影響結果）")
            }
            if let mid = g["midRecording"] as? [String: Any], let ev = (mid["events"] as? NSNumber)?.intValue, ev > 0 {
                let fr = (mid["frames"] as? NSNumber)?.doubleValue ?? 0
                let rate = (s["sampleRate"] as? NSNumber)?.doubleValue ?? 48_000
                lines.append("錄音中有 \(ev) 個缺口，共 \(humanDuration(fr / rate))（已補成無聲）")
            }
        }
        if let err = s["writeError"] as? String { lines.append(err) }
        if let switches = s["deviceSwitches"] as? [[String: Any]], !switches.isEmpty {
            let resumed = switches.filter { ($0["result"] as? String) == "resumed" }
            if !resumed.isEmpty {
                var text = "裝置切換 \(resumed.count) 次，已自動接續"
                if let g = s["gaps"] as? [String: Any], let d = g["device"] as? [String: Any],
                   let fr = (d["frames"] as? NSNumber)?.doubleValue,
                   let rate = (s["sampleRate"] as? NSNumber)?.doubleValue, rate > 0 {
                    text += "（切換期間共 \(humanDuration(fr / rate))補成無聲）"
                }
                lines.append(text)
            }
        }
        if let reason = s["deviceStopReason"] as? String { lines.append(reason) }
        if let lc = s["lengthCheck"] as? [String: Any], (lc["ok"] as? Bool) == false,
           let f = (lc["fileSeconds"] as? NSNumber)?.doubleValue, let w = (lc["wallSeconds"] as? NSNumber)?.doubleValue {
            lines.insert("⚠️ 檔案長度與實際時間不符：檔案 \(humanDuration(f))，實際經過 \(humanDuration(w))（\(f > w ? "多了" : "少了") \(humanDuration(f - w))）。可能有不正確的空白或缺漏，請重聽確認。", at: 0)
        }
        if let mic = s["microphone"] as? [String: Any], let t = (mic["disconnectedAtSeconds"] as? NSNumber)?.doubleValue {
            lines.append("麥克風在 \(formatElapsed(t)) 斷開，之後的麥克風軌為無聲")
        }
        return lines
    }

    // MARK: 定時更新

    private func tick() {
        tickCount += 1
        switch phase {
        case .recording:
            guard let r = recorder else { return }
            if r.needsRebuild, let failure = r.handleDeviceChange() {
                stop(reason: failure)
                return
            }
            if let problem = r.fatalProblem() {
                stop(reason: problem)
                return
            }
            let levels = r.takeLevels()
            appLevel = smooth(appLevel, dbfs(levels.app))
            micLevel = smooth(micLevel, dbfs(levels.mic))
            appPeakHold = max(appPeakHold - 0.3, appLevel)
            micPeakHold = max(micPeakHold - 0.3, micLevel)
            if let s = r.startedAt { elapsed = Date().timeIntervalSince(s) }
            if tickCount % 10 == 0 {
                r.checkFormatChange()
                r.pollProcesses()
                r.sampleClock()
                var n = r.layoutWarnings
                if !r.hasCallbacks() && elapsed > 6 {
                    n.append("開始後仍未收到任何音訊資料。若一直如此，結果會是「沒有收到音訊資料」。")
                }
                let mid = r.midGapEventCount()
                if mid > 0 { n.append("錄音中出現 \(mid) 個缺口（已補成無聲）。") }
                n += r.eventMessages()
                if n != notices { notices = n }
            }
        case .idle, .finished:
            if tickCount % 30 == 0 { refresh() }   // 閒置時每 3 秒更新清單
        default:
            break
        }
    }

    /// 音量表：上升立即反應，下降每 0.1 秒最多 2 dB，看起來比較穩定。
    private func smooth(_ current: Float, _ target: Float) -> Float {
        target >= current ? target : max(target, current - 2)
    }
}

// MARK: - 介面

struct LevelMeter: View {
    let level: Float        // dBFS
    let peak: Float         // dBFS
    let active: Bool

    private func fraction(_ db: Float) -> CGFloat {
        CGFloat(min(max((db + 60) / 60, 0), 1))
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.15))
                RoundedRectangle(cornerRadius: 3)
                    .fill(level >= -3 ? Color.red : (level >= -12 ? Color.yellow : Color.green))
                    .frame(width: geo.size.width * fraction(level))
                if active && peak > -60 {
                    Rectangle()
                        .fill(peak >= -1 ? Color.red : Color.primary.opacity(0.6))
                        .frame(width: 2)
                        .offset(x: max(0, geo.size.width * fraction(peak) - 2))
                }
            }
        }
        .frame(height: 10)
        .opacity(active ? 1 : 0.4)
    }
}

struct ContentView: View {
    @ObservedObject var model: RecorderModel
    @AppStorage(FontScale.key) private var fontScale = FontScale.standard

    /// 依字體大小設定換算的字型（macOS 預設：內文 13、說明 10、callout 12、標題 17 pt）
    private var s: CGFloat { CGFloat(FontScale.clamp(fontScale)) }
    private var bodyFont: Font { .system(size: 13 * s) }
    private var captionFont: Font { .system(size: 10 * s) }
    private var calloutFont: Font { .system(size: 12 * s) }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("來源") {
                    Picker("App", selection: $model.selectedAppID) {
                        Text("不錄 App（只錄麥克風）").tag(RecorderModel.noAppID)
                        Divider()
                        if model.apps.isEmpty { Text("沒有可錄的 App").tag("") }
                        ForEach(model.apps) { app in
                            HStack {
                                if let icon = app.icon { Image(nsImage: icon) }
                                Text(app.menuLabel)
                            }
                            .tag(app.id)
                        }
                    }
                    Picker("麥克風", selection: $model.selectedMicUID) {
                        Text("不錄麥克風（只錄 App）").tag("")
                        Divider()
                        ForEach(model.mics) { mic in
                            Text(mic.menuLabel).tag(mic.id)
                        }
                    }
                    if let mic = model.selectedMic, mic.isBluetooth {
                        Label("藍牙麥克風可能讓耳機切到通話模式、播放音質下降；建議改用內建、有線或 USB 麥克風。",
                              systemImage: "exclamationmark.triangle")
                            .font(captionFont).foregroundStyle(.orange)
                    }
                    if !model.hasSource {
                        Label("App 和麥克風都選了「不錄」，至少要錄一個才能開始。", systemImage: "exclamationmark.triangle")
                            .font(captionFont).foregroundStyle(.orange)
                    }
                    HStack {
                        Text("▶ = 正在出聲。App 沒出現或顯示「尚未出聲」時，先讓它播放一次聲音。")
                            .font(captionFont).foregroundStyle(.secondary)
                        Spacer()
                        Button("重新整理") { model.refresh() }
                    }
                }
                .disabled(model.isBusy)

                Section("轉逐字稿用的音檔") {
                    if model.recordsMic && !model.recordsApp {
                        Text("沒有錄 App，轉逐字稿直接用 microphone.m4a。")
                            .font(captionFont).foregroundStyle(.secondary)
                    } else if model.recordsMic {
                        Picker("錄完後", selection: $model.transcriptChoice) {
                            Text("合成雙方（戴耳機時）").tag("mix")
                            Text("不合成（開喇叭時）").tag("mic")
                        }
                        .pickerStyle(.radioGroup)
                        Text(transcriptExplanation)
                            .font(captionFont).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if model.transcriptChoice != "mic" {
                            offsetRow("對方（App）", value: $model.appOffsetDb)
                            offsetRow("你（麥克風）", value: $model.micOffsetDb)
                            HStack {
                                Text("合成時會先自動把雙方調到相近音量，滑桿是在這之上再加減；0 = 只用自動調整。原始檔不受影響。")
                                    .font(captionFont).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer()
                                Button("歸零") { model.appOffsetDb = 0; model.micOffsetDb = 0 }
                                    .disabled(model.appOffsetDb == 0 && model.micOffsetDb == 0)
                            }
                        }
                    } else {
                        Text("沒有錄麥克風，轉逐字稿直接用 app.m4a。")
                            .font(captionFont).foregroundStyle(.secondary)
                    }
                }
                .disabled(model.isBusy)

                Section("儲存位置") {
                    HStack {
                        Text((model.outputPath as NSString).abbreviatingWithTildeInPath)   // 顯示成 ~/…，不露出帳號名稱
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("選擇…") { model.chooseFolder() }
                    }
                }
                .disabled(model.isBusy)

                Section("音量") {
                    meterRow("App", level: model.appLevel, peak: model.appPeakHold,
                             active: model.phase == .recording && model.recordsApp)
                    meterRow("麥克風", level: model.micLevel, peak: model.micPeakHold,
                             active: model.phase == .recording && model.recordsMic)
                }
            }
            .formStyle(.grouped)
            .controlSize(s >= 1.3 ? .large : .regular)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { fontScale = FontScale.step(fontScale, -1) } label: { Image(systemName: "textformat.size.smaller") }
                        .help("縮小字體（⌘−）")
                        .disabled(fontScale <= FontScale.minimum + 0.001)
                    Button { fontScale = FontScale.standard } label: {
                        Text("\(Int((FontScale.clamp(fontScale) * 100).rounded()))%").monospacedDigit()
                    }
                    .help("字體大小；按一下回到預設 \(Int(FontScale.standard * 100))%（⌘0）")
                    Button { fontScale = FontScale.step(fontScale, 1) } label: { Image(systemName: "textformat.size.larger") }
                        .help("放大字體（⌘＝）")
                        .disabled(fontScale >= FontScale.maximum - 0.001)
                }
            }

            Divider()
            controlBar
                .padding(16)
        }
        .font(bodyFont)
        .frame(minWidth: 520 * max(1, s), minHeight: 480)
    }

    /// 逐字稿選項的白話說明（依目前選擇）
    private var transcriptExplanation: String {
        let base = "兩個原始檔（App、麥克風）一定會保留。"
        if model.transcriptChoice == "mic" {
            return base + "開喇叭時麥克風已錄到雙方，直接上傳 microphone.m4a；合成反而會有回音。若錄完發現麥克風沒錄到對方，會提醒你。"
        }
        return base + "戴耳機時麥克風錄不到對方，把雙方調到相近音量、合成一個 mix.m4a 上傳。"
    }

    private func offsetRow(_ title: String, value: Binding<Double>) -> some View {
        HStack(spacing: 12) {
            Text(title).frame(width: 96 * s, alignment: .leading)
            Text("小").font(captionFont).foregroundStyle(.secondary)
            Slider(value: value, in: -12...12, step: 1)
            Text("大").font(captionFont).foregroundStyle(.secondary)
            Text(value.wrappedValue == 0 ? "自動" : String(format: "%+.0f dB", value.wrappedValue))
                .font(.system(size: 12 * s, design: .monospaced))
                .frame(width: 64 * s, alignment: .trailing)
        }
    }

    private func meterRow(_ title: String, level: Float, peak: Float, active: Bool) -> some View {
        HStack(spacing: 12) {
            Text(title).frame(width: 52 * s, alignment: .leading)
            LevelMeter(level: level, peak: peak, active: active)
            Text(active && level > -60 ? String(format: "%5.1f dB", level) : "  — dB")
                .font(.system(size: 10 * s, design: .monospaced))
                .foregroundStyle(peak >= -1 && active ? Color.red : Color.secondary)
                .frame(width: 72 * s, alignment: .trailing)
        }
    }

    @ViewBuilder
    private var controlBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                Button {
                    if model.phase == .recording { model.stop() } else { model.start() }
                } label: {
                    Label(model.phase == .recording ? "停止錄音" : "開始錄音",
                          systemImage: model.phase == .recording ? "stop.fill" : "record.circle")
                        .frame(minWidth: 120 * s)
                }
                .buttonStyle(.borderedProminent)
                .tint(model.phase == .recording ? .red : .accentColor)
                .controlSize(.large)
                .disabled(model.phase == .starting || model.phase == .stopping || model.phase == .exporting
                          || (model.phase != .recording && !model.canStart))

                Text(formatElapsed(model.elapsed))
                    .font(.system(size: 17 * s, design: .monospaced))
                    .foregroundStyle(model.phase == .recording ? Color.primary : Color.secondary)

                Spacer()

                switch model.phase {
                case .starting: ProgressView().controlSize(.small); Text("準備中…").foregroundStyle(.secondary)
                case .recording: Circle().fill(.red).frame(width: 10, height: 10); Text("錄音中").foregroundStyle(.red)
                case .stopping: ProgressView().controlSize(.small); Text("停止中…").foregroundStyle(.secondary)
                case .exporting: ProgressView().controlSize(.small); Text("匯出 M4A 與逐字稿檔…").foregroundStyle(.secondary)
                default: EmptyView()
                }
            }

            if let error = model.errorMessage {
                Label(error, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red).font(calloutFont)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.phase == .recording {
                ForEach(model.notices, id: \.self) { n in
                    Label(n, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange).font(captionFont)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let r = model.result, model.phase == .exporting || model.phase == .finished {
                resultView(r)
            }
        }
    }

    @ViewBuilder
    private func resultView(_ r: SessionResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(statusDescription(r.status),
                  systemImage: r.status == "completed" ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(r.status == "completed" ? Color.green : Color.orange)
                .font(.system(size: 13 * s, weight: .bold))
            ForEach(r.lines, id: \.self) { line in
                Text(line).font(captionFont).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let e = r.exportStatus {
                Text(e == "done" ? "已匯出 \(model.exportedFileNames)"
                                 : "M4A 匯出失敗；原始 CAF 已保留，可在終端機用 export 指令重試。")
                    .font(captionFont)
                    .foregroundStyle(e == "done" ? Color.secondary : Color.red)
            }
            if let t = r.transcript {
                if let file = t.file, t.ok {
                    Label("逐字稿請上傳：\(file)", systemImage: "text.bubble")
                        .font(calloutFont.weight(.semibold))
                } else {
                    Label("逐字稿用檔案沒有產生", systemImage: "text.bubble")
                        .font(calloutFont.weight(.semibold)).foregroundStyle(.red)
                }
                Text(t.reason).font(captionFont).foregroundStyle(.secondary)
                ForEach(t.warnings, id: \.self) { w in
                    Label(w, systemImage: "exclamationmark.triangle")
                        .font(captionFont).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let t = r.transcript, t.ok, t.file == "mix.m4a" {
                HStack {
                    Button(model.remixing ? "重新合成中…" : "用目前的音量重新合成") { model.remix() }
                        .disabled(model.remixing || model.phase != .finished)
                    Text("覺得哪一方太小聲：調整上方滑桿，再按這裡（原始檔不動）")
                        .font(captionFont).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("在 Finder 中顯示") {
                    NSWorkspace.shared.activateFileViewerSelecting([r.dir])
                }
                if let t = r.transcript, t.ok, let file = t.file {
                    Button("顯示逐字稿檔") {
                        NSWorkspace.shared.activateFileViewerSelecting([r.dir.appendingPathComponent(file)])
                    }
                }
                if let t = r.transcript, t.ok, t.file == "mix.m4a" {
                    Button("播放合成檔") {
                        NSWorkspace.shared.open(r.dir.appendingPathComponent("mix.m4a"))
                    }
                }
                if r.exportStatus == "done" {
                    if model.recordsApp {
                        Button("播放 App 軌") {
                            NSWorkspace.shared.open(r.dir.appendingPathComponent("app.m4a"))
                        }
                    } else {
                        Button("播放麥克風軌") {
                            NSWorkspace.shared.open(r.dir.appendingPathComponent("microphone.m4a"))
                        }
                    }
                }
            }
            .padding(.top, 2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }
}

// MARK: - App

final class GUIAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: RecorderModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 從終端機用 `gui` 啟動時沒有 .app 外殼，要手動設成一般 App 才會出現在 Dock 並取得焦點
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { self.model?.stopForQuit() }
    }
}

/// 字體大小設定（存在使用者偏好設定，下次開啟沿用）
enum FontScale {
    static let key = "fontScale.v2"     // v2：預設改為 120%
    static let standard = 1.2
    static let minimum = 0.8
    static let maximum = 2.0
    static func clamp(_ v: Double) -> Double { min(max(v, minimum), maximum) }
    static func step(_ v: Double, _ dir: Int) -> Double { clamp(((clamp(v) + 0.1 * Double(dir)) * 10).rounded() / 10) }
}

struct RecorderGUIApp: App {
    @NSApplicationDelegateAdaptor(GUIAppDelegate.self) private var appDelegate
    @StateObject private var model = RecorderModel()
    @AppStorage(FontScale.key) private var fontScale = FontScale.standard

    /// 預設視窗：寬 720、高 920，但不超過螢幕可用範圍（不必捲動就能看到全部設定與按鈕）
    static var defaultWindowSize: CGSize {
        let visible = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        return CGSize(width: min(720, visible.width - 40), height: min(920, visible.height - 20))
    }

    var body: some Scene {
        Window("AppAudioRecorder", id: "main-v2") {   // 換 id：不沿用舊版記住的小視窗尺寸
            ContentView(model: model)
                .onAppear { appDelegate.model = model }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(RecorderGUIApp.defaultWindowSize)
        .commands {
            CommandMenu("顯示") {
                Button("放大字體") { fontScale = FontScale.step(fontScale, 1) }
                    .keyboardShortcut("=", modifiers: .command)
                Button("縮小字體") { fontScale = FontScale.step(fontScale, -1) }
                    .keyboardShortcut("-", modifiers: .command)
                Button("預設大小（120%）") { fontScale = FontScale.standard }
                    .keyboardShortcut("0", modifiers: .command)
            }
        }
    }
}
