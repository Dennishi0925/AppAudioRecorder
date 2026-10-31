import Foundation
import AVFoundation

/// 錄音停止後，把 capture/ 裡的 CAF 分軌轉成 M4A（AAC）。
/// - 先寫到暫存檔，寫完重新讀取確認長度，通過才改成正式檔名；失敗時不留下半成品。
/// - 原始 CAF 一律保留，匯出失敗可以用 `export` 指令從 CAF 重試。
/// - 匯出結果另外記在 session.json 的 export 區塊，不改動錄音本身的 status。
enum M4AExporter {
    /// AAC 編碼器的前置／尾端填補會讓長度有少量差異；超過這個 frame 數才視為匯出不完整。
    static let lengthTolerance: Int64 = 4096

    struct TrackResult {
        let name: String
        let file: String
        let sourceFrames: Int64
        let frames: Int64
        let bitrate: Int
        let error: String?
        var ok: Bool { error == nil }
    }

    static func exportTrack(name: String, source: URL, dest: URL,
                            progress: (Double) -> Void) -> TrackResult {
        var sourceFrames: Int64 = 0
        var bitrate = 0
        // AVAudioFile 依副檔名決定容器，暫存檔也要以 .m4a 結尾
        let tmp = dest.deletingLastPathComponent()
            .appendingPathComponent(dest.deletingPathExtension().lastPathComponent + ".partial.m4a")
        do {
            try? FileManager.default.removeItem(at: tmp)
            let input = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
            let format = input.processingFormat
            let channels = Int(format.channelCount)
            sourceFrames = input.length
            guard channels >= 1 && channels <= 2 else {
                throw AudioError(description: "\(channels) 聲道無法直接轉成 AAC，請使用原始 CAF")
            }
            bitrate = channels == 2 ? 256_000 : 128_000
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: bitrate,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_768) else {
                throw AudioError(description: "無法建立匯出緩衝區")
            }
            do {
                // 這個區塊結束時 output 被釋放，檔案隨之關閉並寫完檔頭
                let output = try AVAudioFile(forWriting: tmp, settings: settings,
                                             commonFormat: .pcmFormatFloat32, interleaved: false)
                while input.framePosition < sourceFrames {
                    try input.read(into: buffer)
                    if buffer.frameLength == 0 { break }
                    try output.write(from: buffer)
                    progress(Double(input.framePosition) / Double(max(sourceFrames, 1)))
                }
            }
            // 驗證：重新開啟並比對長度
            let check = try AVAudioFile(forReading: tmp)
            let frames = check.length
            if abs(frames - sourceFrames) > lengthTolerance {
                throw AudioError(description: "匯出長度不符(來源 \(sourceFrames) frames，M4A \(frames) frames)")
            }
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
            return TrackResult(name: name, file: dest.lastPathComponent, sourceFrames: sourceFrames,
                               frames: frames, bitrate: bitrate, error: nil)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            return TrackResult(name: name, file: dest.lastPathComponent, sourceFrames: sourceFrames,
                               frames: 0, bitrate: bitrate, error: "\(error)")
        }
    }

    /// 匯出一個 session 資料夾的所有分軌，並把結果寫回 session.json。回傳 export 狀態（done／failed）。
    @discardableResult
    static func exportSession(_ dir: URL, log: (String) -> Void) -> String {
        let jsonURL = dir.appendingPathComponent("session.json")
        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: jsonURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = obj
        }
        // 依 session.json 的軌道清單；讀不到時退回預設檔名
        var sources: [(String, String)] = []
        if let tracks = json["tracks"] as? [String: Any] {
            for name in ["app", "microphone"] {
                if let t = tracks[name] as? [String: Any], let file = t["file"] as? String {
                    sources.append((name, file))
                }
            }
        }
        if sources.isEmpty {
            for (name, file) in [("app", "capture/app.caf"), ("microphone", "capture/microphone.caf")]
            where FileManager.default.fileExists(atPath: dir.appendingPathComponent(file).path) {
                sources.append((name, file))
            }
        }

        var results: [TrackResult] = []
        for (name, file) in sources {
            let src = dir.appendingPathComponent(file)
            let dest = dir.appendingPathComponent("\(name).m4a")
            var lastShown = -1
            let r = exportTrack(name: name, source: src, dest: dest) { fraction in
                let pct = Int(fraction * 100)
                if pct != lastShown && pct % 5 == 0 {
                    lastShown = pct
                    fputs("\r  匯出 \(name).m4a … \(pct)%   ", stdout)
                    fflush(stdout)
                }
            }
            fputs("\r", stdout)
            if r.ok {
                let seconds = r.frames > 0 ? String(format: "%.1f", Double(r.frames) / max(sampleRate(json), 1)) : "?"
                log("  ✅ \(r.file)(\(r.bitrate / 1000) kbps，\(seconds) 秒)")
            } else {
                log("  ❌ \(r.file) 匯出失敗:\(r.error ?? "?")")
            }
            results.append(r)
        }

        let status = (!results.isEmpty && results.allSatisfy { $0.ok }) ? "done" : "failed"
        let iso = ISO8601DateFormatter()
        var tracks: [String: Any] = [:]
        for r in results {
            var t: [String: Any] = ["file": r.file, "sourceFrames": r.sourceFrames, "frames": r.frames,
                                    "bitrate": r.bitrate, "ok": r.ok]
            if let e = r.error { t["error"] = e }
            tracks[r.name] = t
        }
        json["export"] = [
            "format": "M4A (AAC)",
            "status": status,
            "exportedAt": iso.string(from: Date()),
            "lengthToleranceFrames": lengthTolerance,
            "tracks": tracks,
            "note": "原始資料是 capture/ 裡的 CAF；M4A 為有損壓縮，匯出驗證成功後 CAF 仍保留。"
        ] as [String: Any]
        if let data = try? JSONSerialization.data(withJSONObject: json,
                                                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            try? data.write(to: jsonURL, options: .atomic)
        }
        return status
    }

    private static func sampleRate(_ json: [String: Any]) -> Double {
        (json["sampleRate"] as? Double) ?? (json["sampleRate"] as? NSNumber)?.doubleValue ?? 48_000
    }
}
