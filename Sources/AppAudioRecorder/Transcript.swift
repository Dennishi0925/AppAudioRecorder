import Foundation
import AVFoundation
import Accelerate

/// 逐字稿用檔案：錄音結束後，從 capture/ 的 CAF 決定要上傳哪個檔案。
/// - mix：App 與麥克風各自調到相近音量後混成單聲道 mix.m4a（戴耳機時）
/// - mic：直接用 microphone.m4a（用喇叭時，麥克風已同時收到雙方）
/// - none：不需要
/// 另外檢查麥克風是否收到 App 的聲音（喇叭回音），結果與所有參數寫入 session.json 的 transcript 區塊。
enum TranscriptMode: String {
    case auto, mix, mic, none

    var label: String {
        switch self {
        case .auto: return "自動"
        case .mix: return "混音（戴耳機）"
        case .mic: return "只用麥克風（用喇叭）"
        case .none: return "不需要"
        }
    }
}

struct TranscriptOutcome {
    let mode: String          // 實際採用：mix / mic / app / none
    let reason: String
    let file: String?         // 建議上傳的檔名（相對於 session 資料夾）
    let warnings: [String]
    let ok: Bool
}

/// 依序讀取音檔並轉成單聲道（各聲道相加，呼叫端自行縮放）。
/// AVAudioFile.read 不保證一次讀滿要求的長度，這裡會一直讀到湊滿為止；只有到檔案結尾才補零。
final class MonoReader {
    private let file: AVAudioFile
    private let channels: Int
    private let buffer: AVAudioPCMBuffer
    private(set) var reachedEnd = false

    init(_ file: AVAudioFile, chunk: AVAudioFrameCount = 65_536) throws {
        guard let b = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else {
            throw AudioError(description: "無法建立讀取緩衝區")
        }
        self.file = file
        self.channels = Int(file.processingFormat.channelCount)
        self.buffer = b
    }

    var channelCount: Int { channels }

    func seek(to frame: Int64) {
        file.framePosition = frame
        reachedEnd = false
    }

    /// 讀 n 個 frame 到 out（長度一定是 n）。回傳實際讀到的 frame 數；不足的部分（檔案結尾）為 0。
    @discardableResult
    func read(_ n: Int, into out: inout [Float]) throws -> Int {
        if out.count != n { out = [Float](repeating: 0, count: n) }
        var got = 0
        while got < n {
            let remaining = file.length - file.framePosition
            if remaining <= 0 { reachedEnd = true; break }
            let want = AVAudioFrameCount(min(Int64(n - got), Int64(buffer.frameCapacity), remaining))
            try file.read(into: buffer, frameCount: want)
            let len = Int(buffer.frameLength)
            if len == 0 { reachedEnd = true; break }   // 還沒到 length 卻讀不到：當作結尾，避免無窮迴圈
            guard let planes = buffer.floatChannelData else { break }
            for i in 0..<len {
                var s: Float = 0
                for c in 0..<channels { s += planes[c][i] }
                out[got + i] = s
            }
            got += len
        }
        if got < n { for i in got..<n { out[i] = 0 } }
        return got
    }
}

enum TranscriptMaker {
    // 音量
    static let targetDbfs = -20.0           // 有聲段落的目標音量（較大聲片段另受 loudCeilingDbfs 限制）
    static let maxBoostDb = 24.0
    static let maxCutDb = -12.0
    static let gateDbfs = -50.0             // 低於此值的 400 ms 區塊視為無聲，不納入音量計算
    static let limiterThreshold: Float = 0.891   // -1 dBFS
    static let bitrate = 64_000
    // 回音偵測（以 2026-10-30 本機 7 次錄音校準：喇叭峰值 0.32–0.39、延遲 100% 一致；耳機 ≤ 0.032）
    static let bleedLikelyPeak = 0.10
    static let bleedLikelyConsistency = 0.6
    static let bleedUnlikelyPeak = 0.06

    // MARK: 推薦模式

    /// 依輸出裝置推薦。內建喇叭、HDMI／DisplayPort、AirPlay 視為喇叭；耳機、USB、藍牙視為耳機。
    static func suggestedMode(outputUID: String?, transport: String?, name: String?) -> (TranscriptMode, String) {
        let uid = outputUID ?? ""
        let t = transport ?? ""
        let n = name ?? "未知裝置"
        if uid.contains("BuiltInSpeaker") || t == "HDMI／DisplayPort" || t == "AirPlay" {
            return (.mic, "輸出是喇叭：\(n)")
        }
        if uid.contains("Headphone") || t == "藍牙" {
            return (.mix, "輸出是耳機：\(n)")
        }
        if t == "USB" {
            return (.mix, "輸出是 USB 裝置，視為耳機：\(n)")
        }
        return (.mix, "無法判斷輸出裝置類型，預設混音：\(n)")
    }

    /// 目前輸出裝置的判斷（只用於說明；自動模式最後依回音偵測決定）。
    static func suggestionForCurrentOutput() -> (TranscriptMode, String) {
        guard let id = defaultDeviceID(kAudioHardwarePropertyDefaultOutputDevice), let d = makeDevice(id) else {
            return (.mix, "讀不到輸出裝置，預設混音")
        }
        return suggestedMode(outputUID: d.uid, transport: d.transport, name: d.name)
    }

    // MARK: 主流程

    @discardableResult
    /// appOffsetDb／micOffsetDb：使用者的音量微調，加在自動調整之上（只影響合成檔）。
    static func run(dir: URL, choice: TranscriptMode, appOffsetDb: Double = 0, micOffsetDb: Double = 0,
                    log: (String) -> Void) -> TranscriptOutcome {
        let jsonURL = dir.appendingPathComponent("session.json")
        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: jsonURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = obj
        }
        let fm = FileManager.default
        let appCAF = dir.appendingPathComponent("capture/app.caf")
        let micCAF = dir.appendingPathComponent("capture/microphone.caf")
        let hasMic = fm.fileExists(atPath: micCAF.path)
        var block: [String: Any] = ["choice": choice.rawValue, "createdAt": ISO8601DateFormatter().string(from: Date())]
        var warnings: [String] = []

        func finish(_ outcome: TranscriptOutcome, extra: [String: Any] = [:]) -> TranscriptOutcome {
            block["mode"] = outcome.mode
            block["reason"] = outcome.reason
            block["status"] = outcome.ok ? "done" : "failed"
            if let f = outcome.file { block["file"] = f }
            block["warnings"] = outcome.warnings
            for (k, v) in extra { block[k] = v }
            json["transcript"] = block
            if let data = try? JSONSerialization.data(withJSONObject: json,
                                                      options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
                try? data.write(to: jsonURL, options: .atomic)
            }
            return outcome
        }

        if choice == .none {
            return finish(TranscriptOutcome(mode: "none", reason: "使用者選擇不需要", file: nil, warnings: [], ok: true))
        }
        if !fm.fileExists(atPath: appCAF.path) && hasMic {
            // 這次選了「不錄 App」：只有麥克風軌，直接用 microphone.m4a
            return finish(TranscriptOutcome(mode: "mic", reason: "這次沒有錄 App，只有麥克風軌", file: "microphone.m4a",
                                            warnings: [], ok: fm.fileExists(atPath: dir.appendingPathComponent("microphone.m4a").path)))
        }
        guard fm.fileExists(atPath: appCAF.path) else {
            return finish(TranscriptOutcome(mode: "none", reason: "找不到 capture/app.caf", file: nil,
                                            warnings: ["找不到 App 軌，無法產生逐字稿用檔案"], ok: false))
        }
        if !hasMic {
            return finish(TranscriptOutcome(mode: "app", reason: "這次沒有錄麥克風，只有 App 軌", file: "app.m4a",
                                            warnings: [], ok: fm.fileExists(atPath: dir.appendingPathComponent("app.m4a").path)))
        }

        // 模式：手動選擇照用；自動則在回音偵測後決定（見下方）
        var mode = choice
        var reason = "使用者選擇\(choice.label)"
        let out = json["outputDevice"] as? [String: Any]
        let (deviceMode, deviceReason) = suggestedMode(outputUID: out?["uid"] as? String,
                                                       transport: out?["transport"] as? String,
                                                       name: out?["name"] as? String)

        // 分析：音量與回音
        let appA: Analysis, micA: Analysis
        do {
            appA = try analyze(appCAF)
            micA = try analyze(micCAF)
        } catch {
            return finish(TranscriptOutcome(mode: mode.rawValue, reason: reason, file: nil,
                                            warnings: ["分析音檔失敗：\(error)"], ok: false))
        }
        let bleed = detectBleed(app: appCAF, mic: micCAF, appEnvelope: appA.envelope, envelopeRate: appA.envelopeRate)
        // 錄音中途輸出裝置切換或麥克風斷開：回音偵測是整份一起判斷的，不能代表每一段。
        // 例如前半段喇叭、後半段耳機，後半段對方的聲音只在 App 軌。
        var midChanges: [String] = []
        let switches = (json["deviceSwitches"] as? [[String: Any]]) ?? []
        let resumed = switches.filter { ($0["result"] as? String) == "resumed" }
        if !resumed.isEmpty { midChanges.append("錄音中裝置切換 \(resumed.count) 次") }
        if let m = json["microphone"] as? [String: Any], let t = m["disconnectedAtSeconds"] as? Double {
            midChanges.append(String(format: "麥克風在 %.0f 秒時斷開", t))
        }
        let midChangeText = midChanges.joined(separator: "、")
        // 自動：只有「確定麥克風收到了對方的聲音」才只用麥克風；其他情況（沒收到、不確定、無法判定）
        // 一律混音。混音一定包含雙方，最壞是有回音；只用麥克風若判斷錯誤會整段漏掉對方。
        if choice == .auto {
            if !midChanges.isEmpty {
                mode = .mix
                reason = "自動：\(midChangeText)，部分時段對方的聲音可能只在 App 軌，一律混音以保留雙方"
            } else if bleed.assessment == "likely" {
                mode = .mic
                reason = "自動：麥克風確定收到了對方的聲音（\(deviceReason)），只用麥克風，避免混音產生回音"
            } else {
                mode = .mix
                let why = bleed.assessment == "unlikely" ? "麥克風沒有收到對方的聲音" : "無法確定麥克風是否收到對方的聲音"
                reason = deviceMode == .mic
                    ? "自動：\(deviceReason)，但\(why)，改用混音以保留雙方"
                    : "自動：\(deviceReason)；\(why)，用混音保留雙方"
            }
        }
        var extra: [String: Any] = [
            "autoRule": "錄音中有裝置切換或麥克風斷開一律混音；否則只有回音偵測為 likely 才只用麥克風，其餘混音",
            "outputDeviceSuggestion": deviceMode.rawValue,
            "levels": ["appDbfs": jsonValue(appA.activeDb), "micDbfs": jsonValue(micA.activeDb),
                       "appLoudDbfs": jsonValue(appA.loudDb), "micLoudDbfs": jsonValue(micA.loudDb),
                       "appActiveRatio": appA.activeRatio, "micActiveRatio": micA.activeRatio] as [String: Any],
            "bleed": bleed.json,
        ]
        if !midChanges.isEmpty { extra["midRecordingChanges"] = midChanges }

        switch mode {
        case .mic:
            // 只會在手動選擇時走到這裡（自動模式選麥克風時，偵測為 likely 且沒有中途變動）
            if !midChanges.isEmpty {
                warnings.append("你選了只用麥克風，但\(midChangeText)。變動前後的情況可能不同（例如喇叭換成耳機後，對方的聲音只在 App 軌），逐字稿可能缺少部分對方的話；建議改用混音（transcript 指令加 mix）。")
                extra["missingRemoteRisk"] = true
            } else if bleed.assessment != "likely" {
                let what = bleed.assessment == "unlikely" ? "似乎沒有收到" : "無法確定是否收到"
                warnings.append("你選了只用麥克風，但麥克風\(what)對方的聲音（回音偵測峰值 \(String(format: "%.3f", bleed.peak))）。逐字稿可能缺少對方的話；建議改用混音（transcript 指令加 mix）。")
                extra["missingRemoteRisk"] = true
            }
            let file = "microphone.m4a"
            if !fm.fileExists(atPath: dir.appendingPathComponent(file).path) {
                // 舊錄音或先前匯出失敗：直接從 CAF 補匯出麥克風軌
                log("  microphone.m4a 不存在，從 capture/microphone.caf 匯出…")
                let r = M4AExporter.exportTrack(name: "microphone", source: micCAF,
                                                dest: dir.appendingPathComponent(file), progress: { _ in })
                if let err = r.error {
                    warnings.append("microphone.m4a 不存在，從 CAF 補匯出也失敗：\(err)")
                    return finish(TranscriptOutcome(mode: "mic", reason: reason, file: file, warnings: warnings, ok: false), extra: extra)
                }
                extra["exportedMicrophoneM4A"] = true
            }
            log("  逐字稿請上傳 \(file)（\(reason)）")
            return finish(TranscriptOutcome(mode: "mic", reason: reason, file: file, warnings: warnings, ok: true), extra: extra)

        default:   // mix
            if bleed.assessment == "likely" {
                warnings.append("麥克風收到了喇叭播放的聲音（回音偵測峰值 \(String(format: "%.3f", bleed.peak))，延遲約 \(String(format: "%.0f", bleed.lagMs)) ms），混音裡對方的話可能有回音\(midChanges.isEmpty ? "；建議改用 microphone.m4a。" : "。因錄音中途有裝置變動，仍用混音以免漏掉對方的話。")")
            }
            let gApp = gain(for: appA) + appOffsetDb
            let gMic = gain(for: micA) + micOffsetDb
            if appOffsetDb != 0 || micOffsetDb != 0 {
                extra["userOffsetsDb"] = ["app": appOffsetDb, "mic": micOffsetDb] as [String: Any]
            }
            if appA.activeDb == nil { warnings.append("App 軌幾乎沒有聲音，未調整音量。") }
            if micA.activeDb == nil { warnings.append("麥克風軌幾乎沒有聲音，未調整音量。") }
            do {
                let r = try writeMix(app: appCAF, mic: micCAF, dest: dir.appendingPathComponent("mix.m4a"),
                                     gainAppDb: gApp, gainMicDb: gMic)
                if r.appFrames != r.micFrames {
                    let diff = abs(r.appFrames - r.micFrames)
                    warnings.append("兩軌長度不同（App \(r.appFrames)、麥克風 \(r.micFrames) frames，差 \(humanDuration(Double(diff) / max(r.rate, 1)))）。較短的一軌尾端以無聲補齊；這通常代表寫檔中途失敗，請檢查 session.json。")
                    extra["lengthMismatchFrames"] = diff
                }
                extra["gainsDb"] = ["app": gApp, "mic": gMic] as [String: Any]
                extra["targetDbfs"] = targetDbfs
                extra["limiterMaxReductionDb"] = r.maxReductionDb
                extra["limiterActiveRatio"] = r.limitedRatio   // 壓低超過 1 dB 的時間比例
                extra["frames"] = r.frames
                extra["bitrate"] = bitrate
                log("  ✅ mix.m4a（App \(String(format: "%+.1f", gApp)) dB、麥克風 \(String(format: "%+.1f", gMic)) dB，單聲道 \(bitrate / 1000) kbps）")
                log("  逐字稿請上傳 mix.m4a（\(reason)）")
                return finish(TranscriptOutcome(mode: "mix", reason: reason, file: "mix.m4a", warnings: warnings, ok: true), extra: extra)
            } catch {
                warnings.append("混音失敗：\(error)")
                return finish(TranscriptOutcome(mode: "mix", reason: reason, file: nil, warnings: warnings, ok: false), extra: extra)
            }
        }
    }

    private static func jsonValue(_ d: Double?) -> Any {
        if let d { return d }
        return NSNull()
    }

    // MARK: 音量分析

    struct Analysis {
        var envelope: [Float]        // 每 10 ms 的 RMS（單聲道）
        var envelopeRate: Double     // 每秒幾個 envelope 點
        var activeDb: Double?        // 有聲區塊的平均音量；整軌幾乎無聲時為 nil
        var activeRatio: Double
        var loudDb: Double?          // 10 ms 音量的第 99.9 百分位（較大聲片段）
    }

    static func analyze(_ url: URL) throws -> Analysis {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let ch = Int(file.processingFormat.channelCount)
        let rate = file.processingFormat.sampleRate
        let frame = max(1, Int(rate * 0.01))
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 65_536) else {
            throw AudioError(description: "無法建立分析緩衝區")
        }
        var env: [Float] = []
        env.reserveCapacity(Int(file.length) / frame + 1)
        var acc = 0.0
        var n = 0
        let invCh = 1 / Float(ch)
        while file.framePosition < file.length {
            try file.read(into: buf)
            let len = Int(buf.frameLength)
            if len == 0 { break }
            guard let planes = buf.floatChannelData else { break }
            for i in 0..<len {
                var s: Float = 0
                for c in 0..<ch { s += planes[c][i] }
                s *= invCh
                acc += Double(s * s)
                n += 1
                if n == frame {
                    env.append(Float((acc / Double(n)).squareRoot()))
                    acc = 0; n = 0
                }
            }
        }
        if n > 0 { env.append(Float((acc / Double(n)).squareRoot())) }

        // 400 ms 區塊，低於門檻的不計
        let blockLen = 40
        var activeSum = 0.0, active = 0, total = 0
        var i = 0
        while i + blockLen <= env.count {
            var ms = 0.0
            for j in i..<(i + blockLen) { ms += Double(env[j] * env[j]) }
            ms /= Double(blockLen)
            total += 1
            if 10 * log10(max(ms, 1e-20)) > gateDbfs { activeSum += ms; active += 1 }
            i += blockLen
        }
        let activeDb: Double? = active > 0 ? 10 * log10(activeSum / Double(active)) : nil
        var loudDb: Double? = nil
        if !env.isEmpty {
            let sortedEnv = env.sorted()
            let v = sortedEnv[min(sortedEnv.count - 1, Int(Double(sortedEnv.count) * 0.999))]
            if v > 0 { loudDb = 20 * log10(Double(v)) }
        }
        return Analysis(envelope: env, envelopeRate: rate / Double(frame), activeDb: activeDb,
                        activeRatio: total > 0 ? Double(active) / Double(total) : 0, loudDb: loudDb)
    }

    /// 較大聲片段（第 99.9 百分位）調整後不超過這個值，讓限制器只需處理偶發突波
    static let loudCeilingDbfs = -6.0

    static func gain(for a: Analysis) -> Double {
        guard let db = a.activeDb else { return 0 }
        var g = min(max(targetDbfs - db, maxCutDb), maxBoostDb)
        if let loud = a.loudDb { g = min(g, loudCeilingDbfs - loud) }
        return max(g, maxCutDb)
    }

    // MARK: 回音偵測

    struct Bleed {
        var assessment: String       // likely / unlikely / unclear / indeterminate
        var peak: Double
        var consistency: Double
        var lagMs: Double
        var windows: Int
        var diagnostics: [String: Any] = [:]
        var json: [String: Any] {
            ["assessment": assessment, "peakMedian": peak, "lagConsistency": consistency, "lagMs": lagMs,
             "windows": windows, "method": "4 kHz 波形互相關，4 秒視窗，延遲 0–250 ms",
             "calibration": "門檻依 2026-10-30 本機 7 次錄音校準（喇叭 2 次、耳機 5 次），屬經驗值",
             "diagnostics": diagnostics]
        }
    }

    /// 在平均分布的 4 秒視窗裡，比對 App 與麥克風的波形；麥克風若收到喇叭聲，會在固定延遲出現明顯峰值。
    static func detectBleed(app: URL, mic: URL, appEnvelope: [Float], envelopeRate: Double) -> Bleed {
        var diag: [String: Any] = [:]
        func none(_ why: String) -> Bleed {
            diag["stoppedAt"] = why
            return Bleed(assessment: "indeterminate", peak: 0, consistency: 0, lagMs: 0, windows: 0, diagnostics: diag)
        }
        let fa: AVAudioFile, fm: AVAudioFile
        do {
            fa = try AVAudioFile(forReading: app, commonFormat: .pcmFormatFloat32, interleaved: false)
            fm = try AVAudioFile(forReading: mic, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            return none("開檔失敗：\(error)")
        }
        guard fa.processingFormat.sampleRate == fm.processingFormat.sampleRate else {
            return none("兩軌取樣率不同")
        }
        let rate = fa.processingFormat.sampleRate
        let dec = max(1, Int((rate / 4000).rounded()))
        let drate = rate / Double(dec)
        let w = Int(4 * drate)                  // 視窗長度（降頻後）
        let maxLag = Int(0.25 * drate)
        let wFrames = Int64((w + maxLag) * dec) // 原始取樣率下要讀的長度
        let length = min(fa.length, fm.length)
        diag["lengthFrames"] = length
        diag["decimation"] = dec
        diag["envelopePoints"] = appEnvelope.count
        diag["envelopeRate"] = envelopeRate
        guard length > wFrames else { return none("錄音短於一個視窗") }

        var starts: [Int64] = []
        var s: Int64 = 0
        while s + wFrames < length { starts.append(s); s += Int64(w * dec) }
        if starts.count > 40 {
            let all = starts
            starts = (0..<40).map { all[Int(Double($0) * Double(all.count - 1) / 39)] }
        }

        var peaks: [Double] = []
        var lags: [Double] = []
        let quiet = Float(pow(10, -45.0 / 20))
        var skipEnvelope = 0, skipQuiet = 0, skipRead = 0, skipShort = 0, skipSilent = 0
        var firstReadError: String?
        diag["candidates"] = starts.count
        for start in starts {
            // App 那段太安靜就跳過（用 envelope 快速判斷）
            let e0 = Int(Double(start) / rate * envelopeRate)
            let e1 = min(appEnvelope.count, e0 + Int(4 * envelopeRate))
            if e0 >= e1 { skipEnvelope += 1; continue }
            var ms: Float = 0
            for j in e0..<e1 { ms += appEnvelope[j] * appEnvelope[j] }
            if (ms / Float(e1 - e0)).squareRoot() < quiet { skipQuiet += 1; continue }

            let ra = readDecimated(fa, start: start, frames: Int64(w * dec), dec: dec)
            let rb = readDecimated(fm, start: start, frames: wFrames, dec: dec)
            guard case .success(var a) = ra, case .success(var b) = rb else {
                skipRead += 1
                if firstReadError == nil {
                    if case .failure(let e) = ra { firstReadError = "App：\(e)" }
                    else if case .failure(let e) = rb { firstReadError = "麥克風：\(e)" }
                }
                continue
            }
            guard a.count >= w, b.count >= w + maxLag else {
                skipShort += 1
                if diag["firstShortCounts"] == nil { diag["firstShortCounts"] = "app \(a.count)/\(w)，mic \(b.count)/\(w + maxLag)" }
                continue
            }
            a = Array(a.prefix(w)); b = Array(b.prefix(w + maxLag))
            removeMean(&a); removeMean(&b)
            var na: Float = 0, nb: Float = 0
            vDSP_svesq(a, 1, &na, vDSP_Length(a.count))
            vDSP_svesq(b, 1, &nb, vDSP_Length(b.count))
            let denom = (na * nb).squareRoot()
            if denom < 1e-12 { skipSilent += 1; continue }
            var best: Float = 0
            var bestLag = 0
            b.withUnsafeBufferPointer { bp in
                for k in 0...maxLag {
                    var d: Float = 0
                    vDSP_dotpr(a, 1, bp.baseAddress! + k, 1, &d, vDSP_Length(w))
                    let v = abs(d) / denom
                    if v > best { best = v; bestLag = k }
                }
            }
            peaks.append(Double(best))
            lags.append(Double(bestLag) / drate * 1000)
            if peaks.count >= 20 { break }
        }
        diag["skipped"] = ["envelopeRange": skipEnvelope, "appQuiet": skipQuiet, "readFailed": skipRead,
                           "tooShort": skipShort, "silent": skipSilent] as [String: Any]
        if let firstReadError { diag["firstReadError"] = firstReadError }
        guard !peaks.isEmpty else { return none("沒有可用的視窗") }
        let sorted = peaks.sorted()
        let median = sorted.count % 2 == 1 ? sorted[sorted.count / 2]
            : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        var bestShare = 0.0, bestLagMs = 0.0
        for l in lags {
            let share = Double(lags.filter { abs($0 - l) <= 2 }.count) / Double(lags.count)
            if share > bestShare { bestShare = share; bestLagMs = l }
        }
        var assessment = "unclear"
        if peaks.count < 2 {
            assessment = "indeterminate"
        } else if median >= bleedLikelyPeak && bestShare >= bleedLikelyConsistency {
            assessment = "likely"
        } else if median < bleedUnlikelyPeak {
            assessment = "unlikely"
        }
        return Bleed(assessment: assessment, peak: median, consistency: bestShare, lagMs: bestLagMs,
                     windows: peaks.count, diagnostics: diag)
    }

    private static func readDecimated(_ file: AVAudioFile, start: Int64, frames: Int64, dec: Int) -> Result<[Float], AudioError> {
        do {
            let reader = try MonoReader(file)
            reader.seek(to: start)
            var mono: [Float] = []
            let got = try reader.read(Int(frames), into: &mono)
            let len = got / dec
            var out = [Float](repeating: 0, count: len)
            let scale = 1 / Float(reader.channelCount * dec)
            for i in 0..<len {
                var s: Float = 0
                for k in 0..<dec { s += mono[i * dec + k] }
                out[i] = s * scale
            }
            return .success(out)
        } catch {
            return .failure(AudioError(description: "從 \(start) 讀 \(frames) frames 失敗：\(error)"))
        }
    }

    private static func removeMean(_ x: inout [Float]) {
        let n = vDSP_Length(x.count)
        x.withUnsafeMutableBufferPointer { p in
            guard let base = p.baseAddress else { return }
            var mean: Float = 0
            vDSP_meanv(base, 1, &mean, n)
            var neg = -mean
            vDSP_vsadd(base, 1, &neg, base, 1, n)
        }
    }

    // MARK: 混音

    /// 兩軌各自套用增益後相加成單聲道，再經過峰值限制器（-1 dBFS、50 ms 釋放），寫成 AAC。
    /// 兩軌長度不同時以較長者為準，較短的一軌尾端補零，不會截掉任何一方的內容。
    static func writeMix(app: URL, mic: URL, dest: URL, gainAppDb: Double, gainMicDb: Double) throws
        -> (frames: Int64, maxReductionDb: Double, appFrames: Int64, micFrames: Int64, rate: Double, limitedRatio: Double) {
        let fa = try AVAudioFile(forReading: app, commonFormat: .pcmFormatFloat32, interleaved: false)
        let fm = try AVAudioFile(forReading: mic, commonFormat: .pcmFormatFloat32, interleaved: false)
        let rate = fa.processingFormat.sampleRate
        guard rate == fm.processingFormat.sampleRate else {
            throw AudioError(description: "兩軌取樣率不同(\(rate) / \(fm.processingFormat.sampleRate))")
        }
        let chA = Int(fa.processingFormat.channelCount), chM = Int(fm.processingFormat.channelCount)
        let lengthA = fa.length, lengthM = fm.length
        let length = max(lengthA, lengthM)
        let gA = Float(pow(10, gainAppDb / 20)) / Float(chA)
        let gM = Float(pow(10, gainMicDb / 20)) / Float(chM)
        let release = 1 / Float(0.05 * rate)

        let tmp = dest.deletingLastPathComponent()
            .appendingPathComponent(dest.deletingPathExtension().lastPathComponent + ".partial.m4a")
        try? FileManager.default.removeItem(at: tmp)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: bitrate,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        let chunk: AVAudioFrameCount = 65_536
        let readerA = try MonoReader(fa)
        let readerM = try MonoReader(fm)
        var monoA: [Float] = []
        var monoM: [Float] = []
        var envGain: Float = 1
        var minGain: Float = 1
        var limitedSamples: Int64 = 0
        let oneDb: Float = 0.891
        do {
            let out = try AVAudioFile(forWriting: tmp, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            guard let bufO = AVAudioPCMBuffer(pcmFormat: out.processingFormat, frameCapacity: chunk) else {
                throw AudioError(description: "無法建立混音輸出緩衝區")
            }
            var done: Int64 = 0
            while done < length {
                let n = Int(min(Int64(chunk), length - done))
                // 兩軌都讀滿 n 個 frame（只有超過該軌長度的部分補零），兩軌位置永遠一致
                let gotA = try readerA.read(n, into: &monoA)
                let gotM = try readerM.read(n, into: &monoM)
                if gotA == 0 && gotM == 0 { break }   // 兩邊都讀不到資料（不應發生），交給下方長度驗證
                guard let po = bufO.floatChannelData else { break }
                let o = po[0]
                for i in 0..<n {
                    let x = monoA[i] * gA + monoM[i] * gM
                    let ax = abs(x)
                    let needed: Float = ax > limiterThreshold ? limiterThreshold / ax : 1
                    envGain = needed < envGain ? needed : min(1, envGain + release)
                    if envGain < minGain { minGain = envGain }
                    if envGain < oneDb { limitedSamples += 1 }
                    o[i] = x * envGain
                }
                bufO.frameLength = AVAudioFrameCount(n)
                try out.write(from: bufO)
                done += Int64(n)
            }
        }
        let check = try AVAudioFile(forReading: tmp)
        if abs(check.length - length) > M4AExporter.lengthTolerance {
            try? FileManager.default.removeItem(at: tmp)
            throw AudioError(description: "混音長度不符(預期 \(length) frames，M4A \(check.length) frames)")
        }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        let reduction: Double = minGain < 1 ? Double(20 * log10(minGain)) : 0
        return (frames: check.length, maxReductionDb: reduction, appFrames: lengthA, micFrames: lengthM, rate: rate,
                limitedRatio: length > 0 ? Double(limitedSamples) / Double(length) : 0)
    }
}
