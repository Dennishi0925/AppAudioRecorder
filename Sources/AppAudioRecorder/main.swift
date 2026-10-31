import Foundation
import CoreAudio
import AVFoundation

setvbuf(stdout, nil, _IOLBF, 0)

// 從 .app 開啟（沒有參數）或執行 `AppAudioRecorder gui` 時顯示視窗；其他情況是命令列。
let launchArgs = Array(CommandLine.arguments.dropFirst())
let launchedFromAppBundle = Bundle.main.bundlePath.hasSuffix(".app")
if launchArgs.first == "gui"
    || (launchedFromAppBundle && (launchArgs.isEmpty || launchArgs.first?.hasPrefix("-psn") == true)) {
    MainActor.assumeIsolated { RecorderGUIApp.main() }
    exit(0)
}

func fail(_ message: String) -> Never {
    fputs("錯誤:\(message)\n", stderr)
    exit(1)
}

func printUsage() {
    print("""
    用法:
      AppAudioRecorder gui
          開啟圖形介面（打包成 .app 後直接點兩下即可）

      AppAudioRecorder list
          列出目前向系統註冊音訊的行程(▶ = 正在出聲，◆ = 共用元件，無法由名稱判斷屬於哪個 App)

      AppAudioRecorder mics
          列出有輸入聲道的音訊裝置(★ 為系統預設輸入)

      AppAudioRecorder transcript <session資料夾> [auto|mix|mic|none] [--app-db <dB>] [--mic-db <dB>]
          產生（或重新產生）逐字稿用檔案；預設 auto。
          --app-db／--mic-db：合成時在自動調整之外再加減音量（-12 到 +12），例如 --mic-db 3 讓你的聲音大 3 dB

      AppAudioRecorder export <session資料夾>
          從 capture/ 裡的 CAF 重新匯出 M4A（例如上次匯出失敗時）

      AppAudioRecorder record <關鍵字 | PID[,PID...]> [選項]
          錄下指定行程的聲音，可同時錄麥克風，分別存成 CAF 分軌，並寫入 session.json；
          停止後自動匯出 app.m4a、microphone.m4a（AAC）。
          關鍵字比對 bundle ID(例如 edgemac)，但不會自動納入共用元件(◆)；
          共用元件只能用 PID 明確指定，且你需要自行確認它屬於目標 App。

    選項:
      -o <資料夾>          輸出根目錄，預設 ./recordings（每次錄音建立一個時間命名的子資料夾）
      -t <秒>              錄製秒數；不加則按 Ctrl-C 結束
      --mic <名稱|default>  同時錄麥克風。default = 系統預設輸入；或給裝置名稱／UID 的一部分
      --clock out|mic      aggregate 的主時鐘，預設 out（預設輸出裝置）
      --tap-autostart on|off  實驗用：aggregate 的 tap 自動啟動設定，預設 off（on 會等 App 出聲才開始錄）
      --no-export          停止後不匯出 M4A（之後可用 export 指令匯出）
      --transcript auto|mix|mic|none
                           逐字稿用檔案，預設 auto：麥克風確定收到對方聲音（喇叭）才只用麥克風，
                           其他情況一律混音成 mix.m4a，確保不漏掉任何一方

    結束碼: 0 = completed(開頭 0.1 秒內的啟動暫態不影響)，2 = completed_with_gaps(錄音中有缺口，已補零)，
            3 = 錄音完成但 M4A 匯出失敗(CAF 仍在，可用 export 重試)，
            4 = 錄音與匯出完成，但逐字稿用檔案失敗(可用 transcript 重試)，
            1 = 其他失敗(含 no_data、write_error、timeline_error、stopped_on_device_change)

    裝置變動（拔耳機、換輸出裝置、取樣率改變、麥克風斷開）時會自動重建並接著錄，只有你按 Ctrl-C 才停止；
    中斷的空白補成無聲並記錄。新裝置取樣率不同且無法調整、被錄的 App 關閉、或重建連續失敗時才會停止。

    範例:
      AppAudioRecorder list
      AppAudioRecorder mics
      AppAudioRecorder record edgemac -t 10 --mic default
      AppAudioRecorder record 1467 -t 30 --mic "MacBook"
    """)
}

func ensureMicrophoneAccess() -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
        return true
    case .notDetermined:
        let semaphore = DispatchSemaphore(value: 0)
        var granted = false
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            granted = ok
            semaphore.signal()
        }
        semaphore.wait()
        return granted
    default:
        return false
    }
}

func formatRate(_ rate: Double) -> String {
    rate > 0 ? "\(Int(rate)) Hz" : "?"
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { printUsage(); exit(0) }

switch command {
case "list":
    let processes = listAudioProcesses().sorted { ($0.isOutputting ? 0 : 1, $0.bundleID) < ($1.isOutputting ? 0 : 1, $1.bundleID) }
    if processes.isEmpty { print("目前沒有行程註冊音訊。先讓要錄的 App 播放聲音再試一次。") }
    for p in processes {
        let mark = p.isOutputting ? "▶" : " "
        let shared = isSharedComponent(p) ? "◆" : " "
        print("\(mark)\(shared) PID \(p.pid)\t\(p.bundleID)")
    }
    if processes.contains(where: isSharedComponent) {
        print("\n◆ 共用元件：多個 App 可能各有一個同名行程，無法由名稱判斷歸屬，關鍵字比對不會自動納入。")
    }

case "mics":
    let defaultID = defaultDeviceID(kAudioHardwarePropertyDefaultInputDevice)
    let inputs = listDevices().filter { $0.inputChannels > 0 }
    if inputs.isEmpty { print("找不到任何輸入裝置。") }
    for d in inputs {
        let mark = d.id == defaultID ? "★" : " "
        print("\(mark) \(d.name)\t\(d.inputChannels) 聲道\t\(formatRate(d.nominalRate))\t\(d.transport)\(d.isBluetooth ? "(藍牙)" : "")")
        print("    UID: \(d.uid)")
    }

case "transcript":
    guard args.count >= 2 else { printUsage(); exit(1) }
    let dir = URL(fileURLWithPath: (args[1] as NSString).expandingTildeInPath)
    var choice: TranscriptMode? = .auto
    var appDb = 0.0, micDb = 0.0
    var j = 2
    while j < args.count {
        switch args[j] {
        case "--app-db", "--mic-db":
            guard j + 1 < args.count, let v = Double(args[j + 1]), v >= -12, v <= 12 else {
                fail("\(args[j]) 需要 -12 到 +12 之間的數字")
            }
            if args[j] == "--app-db" { appDb = v } else { micDb = v }
            j += 2
        default:
            choice = TranscriptMode(rawValue: args[j]); j += 1
        }
    }
    guard let choice else { fail("模式只能是 auto、mix、mic 或 none") }
    guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("capture").path) else {
        fail("\(dir.path) 裡沒有 capture/ 資料夾，不是錄音 session。")
    }
    print("產生逐字稿用檔案（\(choice.label)）→ \(dir.path)")
    let outcome = TranscriptMaker.run(dir: dir, choice: choice, appOffsetDb: appDb, micOffsetDb: micDb, log: { print($0) })
    outcome.warnings.forEach { print("  ⚠️ \($0)") }
    if let file = outcome.file, outcome.ok { print("逐字稿請上傳：\(dir.appendingPathComponent(file).path)") }
    exit(outcome.ok ? 0 : 1)

case "export":
    guard args.count >= 2 else { printUsage(); exit(1) }
    let dir = URL(fileURLWithPath: (args[1] as NSString).expandingTildeInPath)
    guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("capture").path) else {
        fail("\(dir.path) 裡沒有 capture/ 資料夾，不是錄音 session。")
    }
    print("從 CAF 匯出 M4A → \(dir.path)")
    let status = M4AExporter.exportSession(dir, log: { print($0) })
    print(status == "done" ? "匯出完成。" : "匯出失敗，原始 CAF 仍保留。")
    exit(status == "done" ? 0 : 3)

case "record":
    guard args.count >= 2 else { printUsage(); exit(1) }
    let selector = args[1]
    var outputPath = "recordings"
    var duration: Double? = nil
    var micKeyword: String? = nil
    var clock = ClockChoice.output
    var tapAutoStart = false
    var doExport = true
    var transcriptChoice = TranscriptMode.auto
    var i = 2
    while i < args.count {
        switch args[i] {
        case "-o" where i + 1 < args.count: outputPath = args[i + 1]; i += 2
        case "-t" where i + 1 < args.count:
            guard let seconds = Double(args[i + 1]), seconds > 0 else { fail("-t 後面要接大於 0 的秒數") }
            duration = seconds; i += 2
        case "--mic" where i + 1 < args.count: micKeyword = args[i + 1]; i += 2
        case "--clock" where i + 1 < args.count:
            guard let c = ClockChoice(rawValue: args[i + 1]) else { fail("--clock 只能是 out 或 mic") }
            clock = c; i += 2
        case "--tap-autostart" where i + 1 < args.count:
            switch args[i + 1] {
            case "on": tapAutoStart = true
            case "off": tapAutoStart = false
            default: fail("--tap-autostart 只能是 on 或 off")
            }
            i += 2
        case "--no-export": doExport = false; i += 1
        case "--transcript" where i + 1 < args.count:
            guard let t = TranscriptMode(rawValue: args[i + 1]) else { fail("--transcript 只能是 auto、mix、mic 或 none") }
            transcriptChoice = t; i += 2
        case "--swap":
            fail("--swap 已移除：緩衝區對應現在由 aggregate 實際配置推算，對不上會拒絕開始。")
        default: fail("看不懂的參數:\(args[i])")
        }
    }

    let selection = selectProcesses(selector, in: listAudioProcesses())
    if !selection.sharedCandidates.isEmpty {
        print("以下為共用元件，無法由名稱確認屬於目標 App，未自動納入:")
        selection.sharedCandidates.forEach { print("  ◆ PID \($0.pid)\t\($0.bundleID)\($0.isOutputting ? "(正在出聲)" : "")") }
        print("  若你確認其中某個屬於目標 App(例如在「活動監視器」裡查看)，可以用 PID 指定:record <PID>")
    }
    if selection.matched.isEmpty {
        fail("找不到符合「\(selector)」的行程。請先讓該 App 播放聲音,再用 list 確認名稱或 PID。")
    }
    print("將錄製這些行程:")
    selection.matched.forEach { print("  PID \($0.pid)\t\($0.bundleID)\(isSharedComponent($0) ? "(共用元件，依你指定的 PID 納入)" : "")") }

    var mic: AudioDevice? = nil
    if let micKeyword, micKeyword.lowercased() != "none" {
        guard let device = findInputDevice(micKeyword) else {
            fail("找不到符合「\(micKeyword)」的輸入裝置。用 mics 查看可用的裝置。")
        }
        mic = device
        print("麥克風:\(device.name)(\(device.inputChannels) 聲道,\(formatRate(device.nominalRate)),\(device.transport))")
        if device.isBluetooth {
            print("⚠️ 這是藍牙輸入裝置。啟用藍牙麥克風可能讓耳機切到通話模式，播放音質下降；建議改用內建、有線或 USB 麥克風。")
        }
        if !ensureMicrophoneAccess() {
            fail("沒有麥克風權限。請到 系統設定 → 隱私權與安全性 → 麥克風，允許目前使用的終端機 App,然後重開終端機再試。")
        }
    }

    let root = URL(fileURLWithPath: (outputPath as NSString).expandingTildeInPath)
    let options = RecordOptions(selector: selector, processes: selection.matched, mic: mic,
                                clock: clock, tapAutoStart: tapAutoStart, outputRoot: root)
    let recorder = SessionRecorder(options: options)
    do {
        try recorder.start()
    } catch {
        recorder.stop()
        if let dir = recorder.sessionDir { fputs("(已寫入 \(dir.path)/session.json，狀態 failed_to_start)\n", stderr) }
        fail("\(error)")
    }
    let sessionPath = recorder.sessionDir?.path ?? "?"
    print("錄音中 → \(sessionPath)(\(duration.map { "\(Int($0)) 秒" } ?? "按 Ctrl-C 結束"))")

    func tryStartupReport(_ attempt: Int) {
        if recorder.hasCallbacks() {
            recorder.startupReport().forEach { print("  " + $0) }
            return
        }
        if attempt >= 10 {
            print("  ⚠️ 約 6 秒內仍未收到任何 IO callback。若一直如此，結束時狀態會是 no_data。")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { tryStartupReport(attempt + 1) }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { tryStartupReport(1) }

    func finish(reason: String? = nil) -> Never {
        print("")
        let summary = recorder.stop(reason: reason)
        let status = summary["status"] as? String ?? "?"
        print("已結束(\(status))→ \(sessionPath)")
        if let t = summary["timeline"] as? [String: Any] {
            print("  時間線 \(t["frames"] ?? 0) frames(其中補零 \(t["zeroFilledFrames"] ?? 0))")
        }
        if let lc = summary["lengthCheck"] as? [String: Any] {
            let f = (lc["fileSeconds"] as? NSNumber)?.doubleValue ?? 0
            let w = (lc["wallSeconds"] as? NSNumber)?.doubleValue ?? 0
            if (lc["ok"] as? Bool) == false {
                print("  ⚠️ 檔案長度與實際時間不符：檔案 \(humanDuration(f))，實際經過 \(humanDuration(w))（\(f > w ? "多了" : "少了") \(humanDuration(f - w))）。可能有不正確的空白或缺漏，請重聽確認。")
            } else {
                print("  長度核對:檔案 \(humanDuration(f))，實際經過 \(humanDuration(w)) ✅")
            }
        }
        if let g = summary["gaps"] as? [String: Any] {
            func ev(_ k: String) -> String {
                guard let d = g[k] as? [String: Any] else { return "?" }
                return "\(d["events"] ?? 0) 次／\(d["frames"] ?? 0) frames"
            }
            print("  缺口:啟動暫態 \(ev("startup"))，錄音中 \(ev("midRecording"))")
            print("        依原因:溢位 \(ev("overflow"))，時間戳 \(ev("timestamp"))，配置不符 \(ev("layout"))")
        }
        if let d = summary["diagnostics"] as? [String: Any] {
            print("  callback \(d["callbacks"] ?? 0) 次")
        }
        if let err = summary["writeError"] as? String { print("  ❌ \(err)") }
        var exportFailed = false
        var transcriptFailed = false
        let exportable = !["failed_to_start", "no_data"].contains(status)
        if doExport && exportable, let dir = recorder.sessionDir {
            print("匯出 M4A(請稍候，匯出期間按 Ctrl-C 無效)…")
            let exportStatus = M4AExporter.exportSession(dir, log: { print($0) })
            exportFailed = exportStatus != "done"
            if exportFailed { print("  原始 CAF 仍保留，可用:.build/release/AppAudioRecorder export \"\(sessionPath)\" 重試") }
            if transcriptChoice != .none {
                print("產生逐字稿用檔案…")
                let outcome = TranscriptMaker.run(dir: dir, choice: transcriptChoice, log: { print($0) })
                outcome.warnings.forEach { print("  ⚠️ \($0)") }
                if !outcome.ok {
                    transcriptFailed = true
                    print("  ❌ 逐字稿用檔案沒有產生，可用 transcript 指令重試")
                } else if let file = outcome.file {
                    print("  逐字稿請上傳:\(file)")
                }
            }
        } else if !doExport && exportable {
            print("未匯出 M4A(--no-export)。之後可用 export 指令匯出。")
        }
        print("檢查:python3 tools/check_session.py \"\(sessionPath)\"")
        switch status {
        case "completed": exit(exportFailed ? 3 : (transcriptFailed ? 4 : 0))
        case "completed_with_gaps": exit(2)
        default: exit(1)
        }
    }

    signal(SIGINT, SIG_IGN)
    let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sigint.setEventHandler { finish() }
    sigint.resume()

    // 每 0.2 秒：裝置變動就自動重建並接續；寫檔失敗或時間線無法保證才停止
    let guardTimer = DispatchSource.makeTimerSource(queue: .main)
    guardTimer.schedule(deadline: .now() + 0.2, repeating: 0.2)
    guardTimer.setEventHandler {
        if recorder.needsRebuild {
            fputs("\n🔄 偵測到裝置變動，重建錄音管線…\n", stderr)
            if let failure = recorder.handleDeviceChange() {
                fputs("\n❌ \(failure)，停止並保存已錄內容。\n", stderr)
                finish(reason: failure)
            }
        }
        if let problem = recorder.fatalProblem() {
            fputs("\n❌ \(problem)，立即停止並保存已錄內容。\n", stderr)
            finish(reason: problem)
        }
    }
    guardTimer.resume()

    // 每秒更新狀態、檢查行程集合，並輪詢一次裝置格式（監聽之外的備援）
    let ticker = DispatchSource.makeTimerSource(queue: .main)
    ticker.schedule(deadline: .now() + 1, repeating: 1)
    ticker.setEventHandler {
        recorder.checkFormatChange()
        recorder.pollProcesses()
        recorder.sampleClock()
        fputs("\r" + recorder.statusLine() + "   ", stdout)
        fflush(stdout)
    }
    ticker.resume()

    if let duration {
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { finish() }
    }
    dispatchMain()

default:
    printUsage()
    exit(1)
}
