import Foundation
import CoreAudio
import AVFoundation
import CRing

// MARK: - 緩衝區對應

/// 開始前依 aggregate 實際配置算出的搬移計畫。IO callback 只照表搬移，不在即時路徑解析配置。
struct CaptureLayout {
    /// IO callback 預期的緩衝區數量與各自的聲道數
    let bufferChannels: [Int]
    /// App（tap）佔用的緩衝區索引
    let appBuffers: [Int]
    /// 麥克風佔用的緩衝區索引
    let micBuffers: [Int]
    /// 依 active subdevice 清單推算出的預期配置
    let expectedLayout: [Int]
    /// 每個 active subdevice 的名稱與輸入聲道配置（記錄用）
    let subDevices: [[String: Any]]
    /// 是否能由聲道配置本身確認 App 與麥克風沒有對調
    let discriminative: Bool

    var appChannels: Int { appBuffers.reduce(0) { $0 + bufferChannels[$1] } }
    var micChannels: Int { micBuffers.reduce(0) { $0 + bufferChannels[$1] } }
}

// MARK: - 寫檔端

/// 從共同時間線 ring 讀出資料，拆成 App 與麥克風兩個 CAF；遇到缺口時兩軌同位置補零。
/// 只在背景寫檔執行緒使用；對外的查詢透過 lock。
final class CaptureWriter {
    struct GapRecord {
        let timelineFrame: Int64
        let frames: Int64
        let kind: UInt32
        let sampleTime: Double
        let startupFrames: Int64   // 落在開頭啟動暫態區間內的部分；其餘屬於錄音中
        var recordingFrames: Int64 { frames - startupFrames }
    }

    struct Snapshot {
        var timeline: Int64 = 0
        var data: Int64 = 0
        var zeros: Int64 = 0
        var gaps: [GapRecord] = []
        var gapRecordsDropped = 0
        var appPeak: Float = 0
        var micPeak: Float = 0
        var startupEvents: Int64 = 0
        var startupFrames: Int64 = 0
        var midEvents: Int64 = 0
        var midFrames: Int64 = 0
        var appFramesOnDisk: Int64 = 0
        var micFramesOnDisk: Int64 = 0
    }

    private let capture: OpaquePointer
    private let appChannels: Int
    private let micChannels: Int
    private let totalChannels: Int
    private var appFile: AVAudioFile?
    private var micFile: AVAudioFile?
    private let appPCM: AVAudioPCMBuffer?
    private let micPCM: AVAudioPCMBuffer?
    private let scratch: UnsafeMutablePointer<Float>
    private let chunk: Int
    /// 時間線開頭這麼多 frame 內的缺口視為啟動暫態
    let startupWindowFrames: Int64

    private let lock = NSLock()
    private var stopRequested = false
    private let finished = DispatchSemaphore(value: 0)

    // 以下由寫檔執行緒更新，外部經 lock 讀取
    private var _timelineFrames: Int64 = 0
    private var _dataFrames: Int64 = 0
    private var _zeroFrames: Int64 = 0
    private var _gaps: [GapRecord] = []
    private var _gapRecordsDropped = 0
    private var _error: String?
    private var _appRecentPeak: Float = 0, _micRecentPeak: Float = 0
    private var _appPeak: Float = 0, _micPeak: Float = 0
    private var _startupEvents: Int64 = 0, _startupFrames: Int64 = 0
    private var _midEvents: Int64 = 0, _midFrames: Int64 = 0
    private var _appFramesOnDisk: Int64 = 0, _micFramesOnDisk: Int64 = 0
    private let maxGapRecords = 1000

    init(capture: OpaquePointer, appChannels: Int, micChannels: Int, sampleRate: Double,
         startupWindowSeconds: Double, appURL: URL?, micURL: URL?) throws {
        let chunk = 4096
        func makeFile(_ url: URL, _ channels: Int) throws -> AVAudioFile {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
            return try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        }
        var appFile: AVAudioFile? = nil
        var appPCM: AVAudioPCMBuffer? = nil
        if let appURL, appChannels > 0 {
            let f = try makeFile(appURL, appChannels)
            guard let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat,
                                           frameCapacity: AVAudioFrameCount(chunk)) else {
                throw AudioError(description: "無法建立 App 軌的寫檔緩衝區")
            }
            appFile = f
            appPCM = b
        }
        var micFile: AVAudioFile? = nil
        var micPCM: AVAudioPCMBuffer? = nil
        if let micURL, micChannels > 0 {
            let f = try makeFile(micURL, micChannels)
            guard let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat,
                                           frameCapacity: AVAudioFrameCount(chunk)) else {
                throw AudioError(description: "無法建立麥克風軌的寫檔緩衝區")
            }
            micFile = f
            micPCM = b
        }
        let appCh = appFile == nil ? 0 : appChannels
        let micCh = micFile == nil ? 0 : micChannels
        guard appCh + micCh > 0 else { throw AudioError(description: "App 與麥克風都沒有要錄") }
        self.capture = capture
        self.appChannels = appCh
        self.micChannels = micCh
        self.totalChannels = appCh + micCh
        self.appFile = appFile
        self.micFile = micFile
        self.appPCM = appPCM
        self.micPCM = micPCM
        self.chunk = chunk
        self.startupWindowFrames = Int64(sampleRate * startupWindowSeconds)
        self.scratch = UnsafeMutablePointer<Float>.allocate(capacity: chunk * (appCh + micCh))
    }

    deinit { scratch.deallocate() }

    // MARK: 執行緒

    func start() {
        let thread = Thread { [self] in self.run() }
        thread.name = "AppAudioRecorder.writer"
        thread.qualityOfService = .utility
        thread.start()
    }

    private func shouldStop() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return stopRequested
    }

    private func run() {
        while !shouldStop() {
            drain()
            usleep(10_000)
        }
        drain()   // IO 已停止且 flush 過，這是最後一次清空
        appFile = nil   // 關檔才會寫完 CAF 檔頭
        micFile = nil
        finished.signal()
    }

    /// 由控制端（主執行緒）呼叫；寫檔執行緒本身不呼叫，避免等待自己。
    func stopAndWait() {
        lock.lock(); stopRequested = true; lock.unlock()
        finished.wait()
    }

    // MARK: 清空

    private func drain() {
        while true {
            var gap = ar_gap()
            if ar_capture_pop_gap(capture, &gap) == 1 {
                let missing = Int64(gap.missing_frames)
                writeZeros(missing)
                lock.lock()
                // 缺口可能跨越啟動視窗（連續同類缺口會被合併），依實際位置拆成兩段計算
                let start = _timelineFrames
                let startupPart = max(0, min(start + missing, startupWindowFrames) - start)
                let midPart = missing - startupPart
                if startupPart > 0 { _startupEvents += 1; _startupFrames += startupPart }
                if midPart > 0 { _midEvents += 1; _midFrames += midPart }
                if _gaps.count < maxGapRecords {
                    _gaps.append(GapRecord(timelineFrame: start, frames: missing, kind: gap.kind,
                                           sampleTime: gap.sample_time, startupFrames: startupPart))
                } else {
                    _gapRecordsDropped += 1
                }
                _timelineFrames += missing
                _zeroFrames += missing
                lock.unlock()
                continue
            }
            let n = Int(ar_capture_read(capture, scratch, UInt32(chunk)))
            if n == 0 { return }
            writeData(n)
            lock.lock()
            _timelineFrames += Int64(n)
            _dataFrames += Int64(n)
            lock.unlock()
        }
    }

    private func hasError() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return _error != nil
    }

    private func setError(_ message: String) {
        lock.lock()
        if _error == nil { _error = message }
        lock.unlock()
    }

    /// 寫入一軌；成功才累計該檔的 frame 數。回傳是否成功。
    private func write(_ pcm: AVAudioPCMBuffer, to file: AVAudioFile?, frames n: Int, isApp: Bool, what: String) -> Bool {
        guard let file else { return true }
        pcm.frameLength = AVAudioFrameCount(n)
        do {
            try file.write(from: pcm)
        } catch {
            setError("\(what)寫檔失敗(\(isApp ? "app" : "microphone")):\(error)")
            return false
        }
        lock.lock()
        if isApp { _appFramesOnDisk += Int64(n) } else { _micFramesOnDisk += Int64(n) }
        lock.unlock()
        return true
    }

    /// 把 scratch 裡的 n 個 frame 拆成兩軌寫出。
    private func writeData(_ n: Int) {
        if hasError() { return }   // 已經寫檔失敗：繼續清空 ring 避免卡住，但不再寫入（各檔計數也停止）
        var appPeak: Float = 0, micPeak: Float = 0
        if let appPCM, let planes = appPCM.floatChannelData {
            for c in 0..<appChannels {
                let dst = planes[c]
                var src = scratch + c
                for i in 0..<n {
                    let v = src.pointee
                    dst[i] = v
                    let a = abs(v)
                    if a > appPeak { appPeak = a }
                    src += totalChannels
                }
            }
        }
        if let micPCM, let planes = micPCM.floatChannelData {
            for c in 0..<micChannels {
                let dst = planes[c]
                var src = scratch + appChannels + c
                for i in 0..<n {
                    let v = src.pointee
                    dst[i] = v
                    let a = abs(v)
                    if a > micPeak { micPeak = a }
                    src += totalChannels
                }
            }
        }
        if let appPCM {
            guard write(appPCM, to: appFile, frames: n, isApp: true, what: "") else { return }
        }
        if let micPCM {
            guard write(micPCM, to: micFile, frames: n, isApp: false, what: "") else { return }
        }
        lock.lock()
        _appRecentPeak = max(_appRecentPeak, appPeak); _appPeak = max(_appPeak, appPeak)
        _micRecentPeak = max(_micRecentPeak, micPeak); _micPeak = max(_micPeak, micPeak)
        lock.unlock()
    }

    private func writeZeros(_ frames: Int64) {
        if hasError() { return }
        var remaining = frames
        while remaining > 0 {
            let n = Int(min(remaining, Int64(chunk)))
            if let appPCM {
                if let planes = appPCM.floatChannelData {
                    for c in 0..<appChannels { planes[c].update(repeating: 0, count: n) }
                }
                guard write(appPCM, to: appFile, frames: n, isApp: true, what: "補零") else { return }
            }
            if let micPCM {
                if let planes = micPCM.floatChannelData {
                    for c in 0..<micChannels { planes[c].update(repeating: 0, count: n) }
                }
                guard write(micPCM, to: micFile, frames: n, isApp: false, what: "補零") else { return }
            }
            remaining -= Int64(n)
        }
    }

    // MARK: 查詢（任一執行緒）

    var error: String? { lock.lock(); defer { lock.unlock() }; return _error }

    func takeRecentPeaks() -> (app: Float, mic: Float) {
        lock.lock(); defer { lock.unlock() }
        let app = _appRecentPeak, mic = _micRecentPeak
        _appRecentPeak = 0; _micRecentPeak = 0
        return (app: app, mic: mic)
    }

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        var r = Snapshot()
        r.timeline = _timelineFrames; r.data = _dataFrames; r.zeros = _zeroFrames
        r.gaps = _gaps; r.gapRecordsDropped = _gapRecordsDropped
        r.appPeak = _appPeak; r.micPeak = _micPeak
        r.startupEvents = _startupEvents; r.startupFrames = _startupFrames
        r.midEvents = _midEvents; r.midFrames = _midFrames
        r.appFramesOnDisk = _appFramesOnDisk; r.micFramesOnDisk = _micFramesOnDisk
        return r
    }

    /// 錄音中途（非啟動暫態）的缺口次數。
    func midGapEvents() -> Int64 {
        lock.lock(); defer { lock.unlock() }
        return _midEvents
    }
}

// MARK: - 錄音工作階段

enum ClockChoice: String {
    case output = "out"
    case mic = "mic"
}

struct RecordOptions {
    var selector: String
    var processes: [AudioProcess]
    var mic: AudioDevice?
    var clock: ClockChoice = .output
    // 實測：設為 true 時，被錄的 App 沒出聲前整個 aggregate 的 IO（含麥克風）都不會啟動。
    var tapAutoStart = false
    var outputRoot: URL
    /// false = 不錄 App（只錄麥克風）：不建立 process tap，aggregate 只含麥克風，也不產生 app.caf
    var recordApp = true
}

final class SessionRecorder {
    private let options: RecordOptions
    private(set) var sessionDir: URL?
    private var captureDir: URL?

    // 目前這一段錄音管線的 Core Audio 物件；裝置變動時整組拆掉重建
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "recorder.io", qos: .userInteractive)
    private var layout: CaptureLayout?
    private var micActive = false            // 目前這一段有沒有麥克風

    // callback 用的預先配置陣列（每段管線開始前填好，callback 只讀）
    private var srcPointers: UnsafeMutablePointer<UnsafePointer<Float>?>?
    private var srcChannels: UnsafeMutablePointer<UInt32>?
    private var srcBuffers: UnsafeMutablePointer<Int>?

    // 整次錄音固定不變：共同時間線 ring 的聲道配置與取樣率
    private var capture: OpaquePointer?
    private var writer: CaptureWriter?
    private var sessionAppChannels = 0
    private var sessionMicChannels = 0

    private var requestedAt: Date?
    private var started: Date?            // AudioDeviceStart 成功的時間
    private var ended: Date?
    private var startError: String?
    private var stopped = false
    private var startUptime: TimeInterval = 0
    private var lastTraceWall: TimeInterval = -100
    private var clockTrace: [[String: Any]] = []
    // 跨段落的時鐘追蹤
    private var traceSegmentOffset: Double = 0
    private var traceLastAudio: Double = 0
    private var traceNeedsRebase = false
    private var traceCallbacksAtRebuild: UInt64 = 0
    private var traceGapFramesAtRebuild: UInt64 = 0
    private var traceResumeOffset: Double = 0

    private var sampleRate: Double = 0
    private var tapRate: Double = 0
    private var tapChannels = 0
    private var outputDevice: AudioDevice?
    private var initialOutputDevice: AudioDevice?
    private var clockUID = ""
    private var bufferFrameSize: UInt32 = 512
    private let hostTicksToSeconds: Double
    /// 開頭這段時間內的缺口視為啟動暫態（實測：偶發於開始後約 21 ms，長 1024 frames）
    let startupWindowSeconds = 0.1

    private var tappedPIDs = Set<pid_t>()
    private var reportedNewPIDs = Set<pid_t>()
    private var reportedGonePIDs = Set<pid_t>()
    private let eventLock = NSLock()
    private var events: [[String: Any]] = []
    private(set) var layoutWarnings: [String] = []

    // 裝置監看：記下基準值，任何差異都觸發一次重建
    private var formatBaseline: [String: String] = [:]
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private let listenerQueue = DispatchQueue(label: "recorder.format-listener")
    private let formatLock = NSLock()
    private var pendingChange: [String: Any]?
    private var deviceSwitches: [[String: Any]] = []
    private var deviceStopReason: String?
    private var micLostAt: Double?
    // 看門狗：錄音中超過 stallLimit 秒沒有新資料寫入，視為裝置問題並觸發重建
    let stallLimitSeconds = 2.0
    private var stallFrames: UInt64 = 0
    private var stallSince = ProcessInfo.processInfo.systemUptime
    // 尚未結算的中斷（重建失敗或還沒收到新資料就停止時，停止時以停止時間補齊）
    private var segmentPausedAt: Date?
    private var reportedRebases: UInt64 = 0
    // 監看的世代：拆管線時立刻失效，讓拆建期間（或之後才送達）的監聽回呼不會被當成新的裝置變動
    private var watchActive = false
    private var watchGeneration = 0
    private var lastRebuildUptime: Double = -100
    let rebuildCooldownSeconds = 1.0
    /// 檔案長度與實際經過時間的容許差距
    let lengthToleranceSeconds = 1.0
    private var settledAtStop: [String: Any]?

    private struct RateMismatch: Error, CustomStringConvertible { let description: String }

    init(options: RecordOptions) {
        self.options = options
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        hostTicksToSeconds = Double(tb.numer) / Double(tb.denom) / 1_000_000_000
    }

    // MARK: 開始

    func start() throws {
        requestedAt = Date()
        do {
            try startImpl()
        } catch {
            startError = "\(error)"
            throw error
        }
    }

    private func startImpl() throws {
        let dir = try makeUniqueSessionDirectory()
        let capDir = dir.appendingPathComponent("capture")
        try FileManager.default.createDirectory(at: capDir, withIntermediateDirectories: false)
        sessionDir = dir
        captureDir = capDir

        try buildPipeline(processes: options.processes, mic: options.mic)
        guard let layout else { throw AudioError(description: "沒有緩衝區對應") }
        initialOutputDevice = outputDevice
        sessionAppChannels = layout.appChannels
        sessionMicChannels = layout.micChannels

        // 共同時間線 ring（10 秒容量）與寫檔端：整次錄音只建立一次，裝置切換時沿用
        let total = sessionAppChannels + sessionMicChannels
        let capacity = UInt32(max(sampleRate, 8000) * 10)
        guard let c = ar_capture_create(UInt32(total), capacity, 4096, sampleRate) else {
            throw AudioError(description: "無法配置擷取緩衝區")
        }
        capture = c
        let w = try CaptureWriter(capture: c, appChannels: sessionAppChannels, micChannels: sessionMicChannels,
                                  sampleRate: sampleRate, startupWindowSeconds: startupWindowSeconds,
                                  appURL: options.recordApp ? capDir.appendingPathComponent("app.caf") : nil,
                                  micURL: options.mic == nil ? nil : capDir.appendingPathComponent("microphone.caf"))
        writer = w
        w.start()

        try installIOProc()

        started = Date()
        startUptime = ProcessInfo.processInfo.systemUptime
        startFormatWatch()
        try writeJSON(buildSessionJSON(status: "recording"))
    }

    // MARK: 錄音管線

    /// 建立一段管線：process tap、aggregate device（麥克風＋預設輸出＋tap）、取樣率與緩衝區對應。
    /// 失敗時已建立的物件留給 teardownPipeline() 清理。
    private func buildPipeline(processes: [AudioProcess], mic: AudioDevice?) throws {
        // 1. process tap：把指定行程的聲音混成立體聲，不靜音原本的輸出（不錄 App 時跳過）
        var tapUUID: String? = nil
        if options.recordApp {
            let tapDescription = CATapDescription(stereoMixdownOfProcesses: processes.map { $0.object })
            tapDescription.name = "AppAudioRecorder Tap"
            tapDescription.muteBehavior = .unmuted
            tapDescription.isPrivate = true
            try check(AudioHardwareCreateProcessTap(tapDescription, &tapID), "建立 process tap")
            tappedPIDs = Set(processes.map { $0.pid })

            var formatAddr = address(kAudioTapPropertyFormat)
            var asbd = AudioStreamBasicDescription()
            var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try check(AudioObjectGetPropertyData(tapID, &formatAddr, 0, nil, &asbdSize, &asbd), "讀取 tap 格式")
            let ch = Int(asbd.mChannelsPerFrame)
            guard ch > 0 else { throw AudioError(description: "tap 回報的聲道數為 0") }
            if tapChannels == 0 {
                tapChannels = ch
            } else if ch != tapChannels {
                throw RateMismatch(description: "App 聲音的聲道數從 \(tapChannels) 變成 \(ch)，無法接在同一個檔案")
            }
            tapRate = asbd.mSampleRate
            tapUUID = tapDescription.uuid.uuidString
        } else {
            tappedPIDs = []
            guard mic != nil else { throw AudioError(description: "沒有可錄的來源：沒有選 App，麥克風也不在") }
        }

        // 2. 私有 aggregate device：麥克風（若有）＋預設輸出裝置（主時鐘）＋ tap。
        //    不錄 App 時只放麥克風，並以麥克風為主時鐘；輸出裝置與錄音無關，換耳機也不需要重建。
        var out: AudioDevice? = nil
        if options.recordApp {
            guard let outID = defaultDeviceID(kAudioHardwarePropertyDefaultOutputDevice),
                  let o = makeDevice(outID) else {
                throw AudioError(description: "讀不到預設輸出裝置")
            }
            out = o
        }
        outputDevice = out
        if let out {
            clockUID = (options.clock == .mic && mic != nil) ? mic!.uid : out.uid
        } else {
            clockUID = mic?.uid ?? ""
        }

        var subDeviceList: [[String: Any]] = []
        if let mic {
            subDeviceList.append([kAudioSubDeviceUIDKey: mic.uid,
                                  kAudioSubDeviceDriftCompensationKey: mic.uid != clockUID])
        }
        if let out, out.uid != mic?.uid {
            subDeviceList.append([kAudioSubDeviceUIDKey: out.uid,
                                  kAudioSubDeviceDriftCompensationKey: out.uid != clockUID])
        }
        var aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "AppAudioRecorder Aggregate",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: clockUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceSubDeviceListKey: subDeviceList,
        ]
        if let tapUUID {
            aggregateDescription[kAudioAggregateDeviceTapAutoStartKey] = options.tapAutoStart
            let tapList: [[String: Any]] = [
                [kAudioSubTapDriftCompensationKey: true,
                 kAudioSubTapUIDKey: tapUUID]
            ]
            aggregateDescription[kAudioAggregateDeviceTapListKey] = tapList
        }
        try check(AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateID),
                  "建立 aggregate device")

        // 3. 取樣率：第一段決定整次錄音的取樣率；之後的段落必須相同（不同就嘗試調整）
        let micRate = mic?.nominalRate ?? 0
        let fallbackRate = tapRate > 0 ? tapRate : (micRate > 0 ? micRate : 48_000)
        var rate = getFloat64(aggregateID, kAudioDevicePropertyNominalSampleRate) ?? fallbackRate
        if sampleRate == 0 {
            sampleRate = rate
        } else if abs(rate - sampleRate) > 0.5 {
            var target = Float64(sampleRate)
            var addr = address(kAudioDevicePropertyNominalSampleRate)
            _ = AudioObjectSetPropertyData(aggregateID, &addr, 0, nil, UInt32(MemoryLayout<Float64>.size), &target)
            for _ in 0..<10 {
                usleep(100_000)
                rate = getFloat64(aggregateID, kAudioDevicePropertyNominalSampleRate) ?? rate
                if abs(rate - sampleRate) <= 0.5 { break }
            }
            guard abs(rate - sampleRate) <= 0.5 else {
                throw RateMismatch(description: "新裝置的取樣率是 \(Int(rate)) Hz，與這次錄音的 \(Int(sampleRate)) Hz 不同，而且無法調整")
            }
        }
        bufferFrameSize = getUInt32(aggregateID, kAudioDevicePropertyBufferFrameSize) ?? 512

        // 4. 由實際配置推導緩衝區對應；對不上就拒絕
        layout = try resolveLayout(mic: mic)
        micActive = mic != nil
    }

    /// 依目前的 layout 建立 IO callback 並開始。這一段沒有麥克風時，麥克風聲道以無聲補上，時間線不變。
    private func installIOProc() throws {
        guard let layout, let c = capture else { throw AudioError(description: "管線尚未建立") }
        var order: [(Int, UInt32)] = layout.appBuffers.map { ($0, UInt32(layout.bufferChannels[$0])) }
        if micActive {
            order += layout.micBuffers.map { ($0, UInt32(layout.bufferChannels[$0])) }
        } else if sessionMicChannels > 0 {
            order.append((-1, UInt32(sessionMicChannels)))   // -1 = 沒有來源，寫入無聲
        }
        let total = order.reduce(0) { $0 + Int($1.1) }
        guard total == sessionAppChannels + sessionMicChannels else {
            throw AudioError(description: "聲道配置與錄音開始時不同（\(total) vs \(sessionAppChannels + sessionMicChannels)）")
        }
        freeSourceTables()
        let n = order.count
        let ptrs = UnsafeMutablePointer<UnsafePointer<Float>?>.allocate(capacity: n)
        ptrs.initialize(repeating: nil, count: n)
        let chs = UnsafeMutablePointer<UInt32>.allocate(capacity: n)
        let idx = UnsafeMutablePointer<Int>.allocate(capacity: n)
        for (i, item) in order.enumerated() {
            idx[i] = item.0
            chs[i] = item.1
        }
        srcPointers = ptrs; srcChannels = chs; srcBuffers = idx

        // IO callback：只照表搬移與計數，不配置記憶體、不加鎖、不碰磁碟
        let expectedCount = layout.bufferChannels.count
        // 以第一個 App 緩衝區決定 frame 數；不錄 App 時改用第一個麥克風緩衝區
        let firstApp = layout.appBuffers.first ?? layout.micBuffers.first ?? 0
        let fallbackFrames = bufferFrameSize
        let floatSize = UInt32(MemoryLayout<Float>.size)
        let ticks = hostTicksToSeconds
        try check(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, ioQueue) {
            _, inputData, inputTime, _, _ in
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            let count = list.count

            // 以第一個 App 緩衝區決定本次 frame 數
            var frames: UInt32 = fallbackFrames
            if firstApp < count {
                let b = list[firstApp]
                if b.mNumberChannels > 0 { frames = b.mDataByteSize / (b.mNumberChannels * floatSize) }
            }
            let time = inputTime.pointee
            let host: Double = time.mFlags.contains(.hostTimeValid) ? Double(time.mHostTime) * ticks : -1
            ar_capture_begin_cycle(c, time.mSampleTime, host, frames, UInt32(count))
            let noted = count < 8 ? count : 8
            for i in 0..<noted {
                let b = list[i]
                let f = b.mNumberChannels > 0 ? b.mDataByteSize / (b.mNumberChannels * floatSize) : 0
                ar_capture_note_buffer(c, UInt32(i), b.mNumberChannels, f)
            }
            if frames == 0 { return }

            var ok = count == expectedCount
            if ok {
                for i in 0..<n {
                    let bi = idx[i]
                    if bi < 0 { ptrs[i] = nil; continue }
                    let b = list[bi]
                    guard let data = b.mData, b.mNumberChannels == chs[i],
                          b.mDataByteSize == frames * chs[i] * floatSize else { ok = false; break }
                    ptrs[i] = UnsafePointer(data.assumingMemoryBound(to: Float.self))
                }
            }
            if ok {
                _ = ar_capture_write(c, ptrs, chs, UInt32(n), frames)
            } else {
                ar_capture_drop(c, frames, UInt32(AR_GAP_LAYOUT))
            }
        }, "建立 IO callback")
        try check(AudioDeviceStart(aggregateID, ioProcID), "開始錄音")
    }

    /// 拆掉目前這一段管線（寫檔端與 ring 不動）。
    private func teardownPipeline() {
        stopFormatWatch()
        if let ioProcID, aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        freeSourceTables()   // IO 已銷毀，callback 不會再用到
    }

    private func freeSourceTables() {
        srcPointers?.deallocate(); srcPointers = nil
        srcChannels?.deallocate(); srcChannels = nil
        srcBuffers?.deallocate(); srcBuffers = nil
    }

    // MARK: 裝置變動：自動接續

    /// 是否有待處理的裝置變動（主執行緒定時檢查）。
    var needsRebuild: Bool {
        checkStall()
        // 剛重建完的 1 秒內先不處理，避免裝置還在變動時連續重建
        if ProcessInfo.processInfo.systemUptime - lastRebuildUptime < rebuildCooldownSeconds { return false }
        formatLock.lock(); defer { formatLock.unlock() }
        return pendingChange != nil && !stopped
    }

    /// 看門狗（主執行緒）：有資料寫入過之後，超過 stallLimitSeconds 沒有新資料就排一次重建。
    private func checkStall() {
        if let capture, !stopped {
            let rb = ar_capture_rebase_events(capture)
            if rb > reportedRebases {
                reportedRebases = rb
                addEvent("輸入時間戳重新起算（通常是裝置拔插造成），已依實際經過時間接上，空白處補零")
            }
        }
        // tap 自動啟動時，App 沒出聲 IO 本來就可能不跑，不能用「沒資料」判斷故障
        guard started != nil, !stopped, !options.tapAutoStart, let capture else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let frames = ar_capture_frames_written(capture)
        if frames != stallFrames {
            stallFrames = frames
            stallSince = now
            return
        }
        guard frames > 0, now - stallSince > stallLimitSeconds else { return }
        stallSince = now                       // 避免重建完成前重複觸發
        var info: [String: Any] = ["changes": ["超過 \(Int(stallLimitSeconds)) 秒沒有收到音訊資料"]]
        if let started { info["wallSeconds"] = Date().timeIntervalSince(started) }
        formatLock.lock()
        if pendingChange == nil { pendingChange = info }
        formatLock.unlock()
    }

    private func resetStallWatch() {
        if let capture { stallFrames = ar_capture_frames_written(capture) }
        stallSince = ProcessInfo.processInfo.systemUptime
    }

    /// 新管線啟動後，等待它真的寫入資料（最多 seconds 秒）。
    private func waitForNewData(after baseline: UInt64, seconds: Double) -> Bool {
        guard let capture else { return false }
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while ProcessInfo.processInfo.systemUptime < deadline {
            if ar_capture_frames_written(capture) > baseline { return true }
            usleep(50_000)
        }
        return ar_capture_frames_written(capture) > baseline
    }

    private func takePendingChange() -> [String: Any]? {
        formatLock.lock(); defer { formatLock.unlock() }
        let c = pendingChange
        pendingChange = nil
        return c
    }

    /// 拆掉舊管線、依目前的預設輸出裝置重建並接著錄。中斷的時間由 C 端依 host time 計算並補零。
    /// 成功回傳 nil；無法接續時回傳原因（呼叫端應停止錄音，已錄內容保留）。
    func handleDeviceChange() -> String? {
        guard !stopped, let capture, let change = takePendingChange() else { return nil }
        let changes = change["changes"] as? [String] ?? []
        let detectedAt = started.map { Date().timeIntervalSince($0) } ?? 0
        sampleClock(force: true)                  // 記下舊段落最後一個時鐘點
        let resumeOffset = traceLastAudio
        let oldOutput = outputDevice?.name ?? "?"
        teardownPipeline()
        let pausedAt = Date()
        segmentPausedAt = pausedAt

        var lastError = "未知原因"
        var attempts = 0
        for attempt in 1...4 {
            attempts = attempt
            if attempt > 1 { usleep(500_000) }    // 裝置剛插拔時清單可能還在變動
            var processes: [AudioProcess] = []
            if options.recordApp {
                processes = selectProcesses(options.selector, in: listAudioProcesses()).matched
                if processes.isEmpty {
                    lastError = "被錄的 App 已沒有音訊行程（可能已關閉）"
                    continue
                }
            }
            var mic: AudioDevice? = nil
            if let wanted = options.mic, micLostAt == nil {
                mic = listDevices().first { $0.uid == wanted.uid && $0.inputChannels == sessionMicChannels }
            }
            if !options.recordApp && mic == nil {
                // 只錄麥克風：麥克風不在就沒有東西可錄，重試幾次後停止（已錄內容保留）
                lastError = "麥克風「\(options.mic?.name ?? "?")」已斷開，沒有其他來源可以接著錄"
                continue
            }
            do {
                try buildPipeline(processes: processes, mic: mic)
                ar_capture_begin_segment(capture, Date().timeIntervalSince(pausedAt) * sampleRate)
                traceCallbacksAtRebuild = ar_capture_callbacks(capture)
                traceGapFramesAtRebuild = ar_capture_device_gap_frames(capture)
                traceResumeOffset = resumeOffset
                traceNeedsRebase = true
                let baseline = ar_capture_frames_written(capture)
                try installIOProc()
                // 啟動成功不代表有資料：確認新管線真的寫入資料才算接續
                if !waitForNewData(after: baseline, seconds: 2.0) {
                    teardownPipeline()
                    // 這段管線可能送過 callback 卻沒有可用資料（中斷已被結算到那時）：重新標記待結算，
                    // 讓下一段或停止時從最後一次 callback 之後接著補
                    ar_capture_begin_segment(capture, Date().timeIntervalSince(pausedAt) * sampleRate)
                    lastError = "新管線 2 秒內沒有收到音訊資料"
                    continue
                }
            } catch let e as RateMismatch {
                teardownPipeline()
                lastError = e.description
                break                              // 物理上無法接在同一個檔案，不重試
            } catch {
                teardownPipeline()
                lastError = "\(error)"
                continue
            }
            // 成功（新管線已寫入資料，中斷空白已由 C 端依第一個 callback 結算）
            segmentPausedAt = nil
            resetStallWatch()
            if let wanted = options.mic, mic == nil, micLostAt == nil {
                micLostAt = detectedAt
                addEvent("麥克風「\(wanted.name)」已斷開，之後的麥克風軌為無聲")
            }
            reportedNewPIDs.removeAll()
            deviceSwitches.append([
                "atSeconds": (detectedAt * 1000).rounded() / 1000, "changes": changes, "result": "resumed",
                "attempts": attempts, "fromOutput": oldOutput, "toOutput": outputDevice?.name ?? "?",
                "microphoneActive": micActive, "processes": processes.map { Int($0.pid) },
            ])
            addEvent("裝置變動（\(changes.joined(separator: "；"))），已自動接續" + (outputDevice.map { "：輸出改為 \($0.name)" } ?? ""))
            // 重建期間記下的變動已經反映在新管線上，丟棄；之後以新管線的狀態為基準重新監看
            _ = takePendingChange()
            lastRebuildUptime = ProcessInfo.processInfo.systemUptime
            startFormatWatch()
            return nil
        }
        deviceStopReason = "裝置變動後無法接續：\(lastError)"
        deviceSwitches.append(["atSeconds": (detectedAt * 1000).rounded() / 1000, "changes": changes,
                               "result": "failed", "attempts": attempts, "error": lastError])
        return deviceStopReason
    }

    // MARK: 裝置監看

    /// 目前的裝置狀態快照：預設輸出裝置、aggregate 取樣率與輸入配置、每個輸入 stream 與 tap 的格式、
    /// 各子裝置的取樣率與是否仍連接。任何一項和基準不同都觸發重建。
    private func formatSignature() -> [String: String] {
        func describe(_ f: AudioStreamBasicDescription) -> String {
            "\(f.mSampleRate)Hz \(f.mChannelsPerFrame)ch id\(f.mFormatID) flags\(f.mFormatFlags) \(f.mBitsPerChannel)b"
        }
        var sig: [String: String] = [:]
        // 不錄 App 時輸出裝置與錄音無關：換耳機、換喇叭不觸發重建
        if options.recordApp {
            if let id = defaultDeviceID(kAudioHardwarePropertyDefaultOutputDevice) {
                sig["預設輸出裝置"] = getString(id, kAudioDevicePropertyDeviceUID) ?? "\(id)"
            } else {
                sig["預設輸出裝置"] = "無"
            }
        }
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            sig["aggregate 取樣率"] = "\(getFloat64(aggregateID, kAudioDevicePropertyNominalSampleRate) ?? -1)"
            sig["aggregate 輸入配置"] = "\(streamChannelLayout(aggregateID, scope: kAudioObjectPropertyScopeInput))"
            sig["aggregate 連接"] = "\(getUInt32(aggregateID, kAudioDevicePropertyDeviceIsAlive) ?? 0)"
            if let formats = inputStreamFormats(aggregateID) {
                for (i, f) in formats.enumerated() { sig["輸入 stream #\(i) 格式"] = describe(f) }
            }
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            var addr = address(kAudioTapPropertyFormat)
            var f = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            if AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &f) == noErr { sig["tap 格式"] = describe(f) }
        }
        var devices: [AudioDevice] = []
        if let out = outputDevice { devices.append(out) }
        if micActive, let mic = options.mic, mic.uid != outputDevice?.uid { devices.append(mic) }
        for d in devices {
            sig["\(d.name) 取樣率"] = "\(getFloat64(d.id, kAudioDevicePropertyNominalSampleRate) ?? -1)"
            sig["\(d.name) 連接"] = "\(getUInt32(d.id, kAudioDevicePropertyDeviceIsAlive) ?? 0)"
        }
        return sig
    }

    private func startFormatWatch() {
        let baseline = formatSignature()
        formatLock.lock()
        formatBaseline = baseline
        watchGeneration += 1
        watchActive = true
        formatLock.unlock()
        func listen(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector,
                    _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) {
            guard obj != AudioObjectID(kAudioObjectUnknown) else { return }
            var addr = address(selector, scope: scope)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.checkFormatChange() }
            if AudioObjectAddPropertyListenerBlock(obj, &addr, listenerQueue, block) == noErr {
                listeners.append((obj, addr, block))
            }
        }
        let system = AudioObjectID(kAudioObjectSystemObject)
        if options.recordApp { listen(system, kAudioHardwarePropertyDefaultOutputDevice) }
        listen(system, kAudioHardwarePropertyDevices)
        listen(aggregateID, kAudioDevicePropertyNominalSampleRate)
        listen(aggregateID, kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput)
        listen(aggregateID, kAudioDevicePropertyDeviceIsAlive)
        listen(tapID, kAudioTapPropertyFormat)
        for stream in getObjectIDs(aggregateID, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput) ?? [] {
            listen(stream, kAudioStreamPropertyVirtualFormat)
        }
        var ids: [AudioObjectID] = []
        if let out = outputDevice { ids.append(out.id) }
        if micActive, let mic = options.mic, mic.uid != outputDevice?.uid { ids.append(mic.id) }
        for id in ids {
            listen(id, kAudioDevicePropertyNominalSampleRate)
            listen(id, kAudioDevicePropertyDeviceIsAlive)
        }
    }

    private func stopFormatWatch() {
        formatLock.lock()
        watchActive = false
        watchGeneration += 1
        formatLock.unlock()
        for (obj, addr, block) in listeners {
            var a = addr
            AudioObjectRemovePropertyListenerBlock(obj, &a, listenerQueue, block)
        }
        listeners.removeAll()
        listenerQueue.sync { }   // 等仍在執行的監聽回呼結束，之後才拆管線，避免把自己的動作誤判成裝置變動
    }

    /// 由屬性監聽與主執行緒定時呼叫。與基準不同就記下一次待處理的變動，交由 handleDeviceChange() 重建。
    func checkFormatChange() {
        guard started != nil, !stopped else { return }
        formatLock.lock()
        let usable = watchActive && pendingChange == nil && !formatBaseline.isEmpty
        let generation = watchGeneration
        let baseline = formatBaseline
        formatLock.unlock()
        if !usable { return }
        let now = formatSignature()
        var diffs: [String] = []
        for key in Set(baseline.keys).union(now.keys).sorted() where baseline[key] != now[key] {
            diffs.append("\(key):\(baseline[key] ?? "無") → \(now[key] ?? "無")")
        }
        if diffs.isEmpty { return }
        var info: [String: Any] = ["changes": diffs]
        if let started { info["wallSeconds"] = Date().timeIntervalSince(started) }
        if stopped { return }
        formatLock.lock()
        // 比對期間管線被拆掉或重建過（世代改變）：這次比對的是過時的狀態，丟棄
        if watchActive && generation == watchGeneration && pendingChange == nil { pendingChange = info }
        formatLock.unlock()
    }

    /// 以排他方式建立 session 資料夾：名稱已存在就加 -2、-3…，絕不沿用既有資料夾
    ///（mkdir 本身是原子操作，同時啟動的兩個實例不會拿到同一個資料夾）。
    private func makeUniqueSessionDirectory() throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: options.outputRoot, withIntermediateDirectories: true)
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let base = stamp.string(from: Date())
        for n in 1...999 {
            let candidate = options.outputRoot.appendingPathComponent(n == 1 ? base : "\(base)-\(n)")
            do {
                // 0700：錄音是私人內容，同一台 Mac 的其他使用者不能讀取
                try fm.createDirectory(at: candidate, withIntermediateDirectories: false,
                                       attributes: [.posixPermissions: 0o700])
                return candidate
            } catch let error as NSError where error.domain == NSCocoaErrorDomain
                        && error.code == NSFileWriteFileExistsError {
                continue
            }
        }
        throw AudioError(description: "無法建立唯一的錄音資料夾(\(base)-1 到 -999 都已存在)")
    }

    /// 由 aggregate 的 active subdevice 清單與各裝置的輸入 stream 配置，推算 IO callback 的緩衝區排列，
    /// 並與 aggregate 實際回報的配置比對。規則：子裝置依清單順序排列，tap 排在最後。
    private func resolveLayout(mic: AudioDevice?) throws -> CaptureLayout {
        // aggregate 建立後 stream 可能稍後才出現，最多等約 2 秒
        var subUIDs = Set<String>()
        if let mic { subUIDs.insert(mic.uid) }
        if let out = outputDevice { subUIDs.insert(out.uid) }
        let expectedSubs = max(subUIDs.count, 1)
        var actual: [Int] = []
        var subs: [AudioObjectID] = []
        for _ in 0..<20 {
            actual = streamChannelLayout(aggregateID, scope: kAudioObjectPropertyScopeInput)
            subs = getObjectIDs(aggregateID, kAudioAggregateDevicePropertyActiveSubDeviceList) ?? []
            if !actual.isEmpty && subs.count >= expectedSubs { break }
            usleep(100_000)
        }
        guard !actual.isEmpty else {
            throw AudioError(description: "aggregate 沒有任何輸入 stream，無法確認配置")
        }
        guard !subs.isEmpty else {
            throw AudioError(description: "讀不到 aggregate 的 active subdevice 清單，無法確認緩衝區對應")
        }

        var expected: [Int] = []
        var micRange: Range<Int>? = nil
        var subInfo: [[String: Any]] = []
        for sub in subs {
            let streams = streamChannelLayout(sub, scope: kAudioObjectPropertyScopeInput)
            let uid = getString(sub, kAudioDevicePropertyDeviceUID) ?? "?"
            let name = getString(sub, kAudioObjectPropertyName) ?? uid
            subInfo.append(["uid": uid, "name": name, "inputLayout": streams])
            if let mic, uid == mic.uid {
                micRange = expected.count..<(expected.count + streams.count)
            }
            expected += streams
        }
        var tapIndex: Int? = nil
        if options.recordApp {
            tapIndex = expected.count
            expected.append(tapChannels)
        }

        guard expected == actual else {
            throw AudioError(description: "aggregate 輸入配置與推算不符(推算 \(expected)，實際 \(actual))。為避免錄錯來源，拒絕開始。")
        }
        var micBuffers: [Int] = []
        if mic != nil {
            guard let micRange, !micRange.isEmpty else {
                throw AudioError(description: "麥克風沒有出現在 aggregate 的有效輸入中")
            }
            micBuffers = Array(micRange)
        }

        // 格式：每個要搬移的 stream 都必須是交錯 32 位元浮點
        guard let formats = inputStreamFormats(aggregateID), formats.count == actual.count else {
            throw AudioError(description: "讀不到 aggregate 輸入 stream 的格式")
        }
        let appBuffers = tapIndex.map { [$0] } ?? []
        for b in appBuffers + micBuffers where !isInterleavedFloat32(formats[b]) {
            throw AudioError(description: "緩衝區 #\(b) 不是交錯 32 位元浮點格式(formatID \(formats[b].mFormatID)，flags \(formats[b].mFormatFlags)，\(formats[b].mBitsPerChannel) 位元)")
        }

        // 若麥克風與 App 的配置相同，對調也會符合同一份配置，這時只能依排列規則判斷
        let micLayout = micBuffers.map { actual[$0] }
        let discriminative = mic == nil || tapIndex == nil || micLayout != [tapChannels]
        if !discriminative {
            let warning = "麥克風與 App 聲道配置相同(都是 \(tapChannels) 聲道)，無法由配置本身確認沒有對調；目前依「子裝置在前、tap 在後」的規則對應。建議做一次「只有 App 出聲／只有麥克風出聲」的確認。"
            if !layoutWarnings.contains(warning) { layoutWarnings.append(warning) }
        }
        return CaptureLayout(bufferChannels: actual, appBuffers: appBuffers, micBuffers: micBuffers,
                             expectedLayout: expected, subDevices: subInfo, discriminative: discriminative)
    }

    // MARK: 監看

    func hasCallbacks() -> Bool {
        guard let capture else { return false }
        return ar_capture_callbacks(capture) > 0
    }

    func startupReport() -> [String] {
        var lines: [String] = []
        if options.recordApp {
            lines.append("取樣率 \(Int(sampleRate)) Hz(tap \(Int(tapRate)) Hz，\(tapChannels) 聲道)")
        } else {
            lines.append("取樣率 \(Int(sampleRate)) Hz(不錄 App，只錄麥克風)")
        }
        if let layout {
            let parts = layout.bufferChannels.enumerated().map { "#\($0.offset): \($0.element) 聲道" }
            lines.append("aggregate 輸入緩衝區 \(layout.bufferChannels.count) 個 → \(parts.joined(separator: "、"))")
            var parts2: [String] = []
            if !layout.appBuffers.isEmpty {
                parts2.append("App = #\(layout.appBuffers.map { String($0) }.joined(separator: ","))")
            }
            if !layout.micBuffers.isEmpty {
                parts2.append("麥克風 = #\(layout.micBuffers.map { String($0) }.joined(separator: ","))")
            }
            let mapping = parts2.joined(separator: "，")
            lines.append("對應(由配置推算並核對):\(mapping)")
        }
        lines += layoutWarnings.map { "⚠️ " + $0 }
        return lines
    }

    /// 需要立即停止的問題：寫檔失敗、時間線無法保證。裝置變動不在此列（會自動接續）。
    func fatalProblem() -> String? {
        if let err = writer?.error { return err }
        if let capture {
            if ar_capture_lost_gap_events(capture) > 0 { return "缺口記錄佇列已滿，時間線無法保證" }
            if ar_capture_backwards_events(capture) > 0 { return "輸入時間戳倒退，時間線無法保證" }
        }
        return nil
    }

    // MARK: 給圖形介面用的查詢（主執行緒）

    /// 自上次呼叫以來的峰值（線性振幅）。
    func takeLevels() -> (app: Float, mic: Float) {
        writer?.takeRecentPeaks() ?? (app: 0, mic: 0)
    }

    func midGapEventCount() -> Int64 { writer?.midGapEvents() ?? 0 }

    var startedAt: Date? { started }

    var deviceSwitchCount: Int { deviceSwitches.filter { ($0["result"] as? String) == "resumed" }.count }

    func eventMessages() -> [String] {
        eventLock.lock(); defer { eventLock.unlock() }
        return events.compactMap { $0["message"] as? String }
    }

    func statusLine() -> String {
        guard let started else { return "" }
        let elapsed = Int(Date().timeIntervalSince(started))
        func db(_ v: Float) -> String { v > 0.000_01 ? String(format: "%5.1f", 20 * log10(Double(v))) : " -inf" }
        var line = String(format: "%02d:%02d:%02d", elapsed / 3600, (elapsed / 60) % 60, elapsed % 60)
        if let writer {
            let peaks = writer.takeRecentPeaks()
            if options.recordApp { line += "  App \(db(peaks.app)) dBFS" }
            if options.mic != nil { line += "  麥克風 \(micLostAt == nil ? db(peaks.mic) : " 斷開") dBFS" }
        }
        if let writer {
            let mid = writer.midGapEvents()
            if mid > 0 { line += "  ⚠️ 錄音中缺口 \(mid)(已補零)" }
        }
        if deviceSwitchCount > 0 { line += "  裝置切換 \(deviceSwitchCount)" }
        return line
    }

    /// 每約 10 秒記錄一筆時鐘對照：牆鐘、系統清醒時間（不含睡眠）、音訊時間線已前進的秒數。
    /// 裝置切換後新段落的取樣時間會重新起算，這裡接上前一段的終點與切換空白，維持連續。
    func sampleClock(force: Bool = false) {
        guard let capture, let started, ar_capture_callbacks(capture) > 0, sampleRate > 0 else { return }
        let wall = Date().timeIntervalSince(started)
        if !force && wall - lastTraceWall < 10 { return }
        if traceNeedsRebase {
            guard ar_capture_callbacks(capture) > traceCallbacksAtRebuild else { return }   // 新段落還沒有 callback
            let gap = Double(ar_capture_device_gap_frames(capture) - traceGapFramesAtRebuild) / sampleRate
            traceSegmentOffset = traceResumeOffset + gap
            traceNeedsRebase = false
        }
        lastTraceWall = wall
        let awake = ProcessInfo.processInfo.systemUptime - startUptime
        let audio = traceSegmentOffset
            + (ar_capture_next_sample_time(capture) - ar_capture_segment_first_sample_time(capture)) / sampleRate
        traceLastAudio = audio
        func r3(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }
        clockTrace.append(["wall": r3(wall), "awake": r3(awake), "audioSeconds": r3(audio)])
    }

    /// 檢查符合條件的行程集合是否改變。新增的行程會在下一次裝置切換重建時納入；目前只記錄。
    func pollProcesses() {
        guard options.recordApp else { return }
        let current = selectProcesses(options.selector, in: listAudioProcesses()).matched
        let currentPIDs = Set(current.map { $0.pid })
        for p in current where !tappedPIDs.contains(p.pid) && !reportedNewPIDs.contains(p.pid) {
            reportedNewPIDs.insert(p.pid)
            addEvent("新增符合的行程 PID \(p.pid) \(p.bundleID)，未納入目前的 tap")
        }
        for pid in tappedPIDs where !currentPIDs.contains(pid) && !reportedGonePIDs.contains(pid) {
            reportedGonePIDs.insert(pid)
            addEvent("已錄製的行程 PID \(pid) 不再出現在音訊行程清單")
        }
    }

    private func addEvent(_ message: String) {
        let t = started.map { Date().timeIntervalSince($0) } ?? 0
        eventLock.lock()
        events.append(["t": (t * 1000).rounded() / 1000, "message": message])
        eventLock.unlock()
        fputs("\n⚠️ \(message)\n", stderr)
    }

    // MARK: 停止

    /// 停止並寫出 session.json。啟動失敗後也可以呼叫，用來清理資源。
    @discardableResult
    func stop(reason: String? = nil) -> [String: Any] {
        if stopped { return buildSessionJSON(status: finalStatus()) }
        if started != nil { sampleClock(force: true) }
        stopped = true
        if let reason { addEvent("停止原因:\(reason)") }
        teardownPipeline()
        if let capture {
            // 裝置切換後新管線一直沒有資料就停止：以停止時間補齊中斷（估算值）
            let nowHost = Double(mach_absolute_time()) * hostTicksToSeconds
            let fallback = segmentPausedAt.map { Date().timeIntervalSince($0) * sampleRate } ?? 0
            let settled = ar_capture_settle_segment(capture, nowHost, fallback)
            if settled > 0 {
                let sec = sampleRate > 0 ? Double(settled) / sampleRate : 0
                settledAtStop = ["frames": Int(settled), "seconds": (sec * 1000).rounded() / 1000, "estimated": true]
                addEvent("裝置切換後的中斷沒有接上新資料，停止時補上 \(humanDuration(sec))無聲（估算）")
            }
            segmentPausedAt = nil
            ar_capture_flush(capture)   // IO 已停止：送出最後一筆待送缺口
        }
        writer?.stopAndWait()                          // 清空 ring、補零、關檔
        ended = Date()

        let json = buildSessionJSON(status: finalStatus())
        try? writeJSON(json)
        return json
    }

    /// 完成狀態。只有沒有任何問題時才是 completed。
    func finalStatus() -> String {
        if startError != nil { return "failed_to_start" }
        guard let capture else { return "failed_to_start" }
        if ar_capture_callbacks(capture) == 0 { return "no_data" }
        // 有 callback 但沒有任何有效資料（例如從頭到尾配置不符、全部補零）也算 no_data
        if let writer, writer.snapshot().data == 0 { return "no_data" }
        if writer?.error != nil { return "write_error" }
        if ar_capture_lost_gap_events(capture) > 0 || ar_capture_backwards_events(capture) > 0 { return "timeline_error" }
        if deviceStopReason != nil { return "stopped_on_device_change" }
        // 啟動暫態（開頭 startupWindowSeconds 內）的缺口照樣補零並記錄，但不影響完成狀態；
        // 錄音中途的缺口（含裝置切換的空白）算 completed_with_gaps。
        if let writer, writer.midGapEvents() > 0 { return "completed_with_gaps" }
        return "completed"
    }

    // MARK: session.json

    private func buildSessionJSON(status: String) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var json: [String: Any] = [
            "schema": 2,
            "app": "AppAudioRecorder 0.8.0",
            "status": status,
            "container": "CAF",
            "sampleFormat": "float32 interleaved",
            "sampleRate": sampleRate,
            "selector": options.selector,
            "processes": options.processes.map { p -> [String: Any] in ["pid": Int(p.pid), "bundleID": p.bundleID] },
            "recordsApp": options.recordApp,
            "tapAutoStart": options.tapAutoStart,
            "clock": ["choice": options.clock.rawValue, "uid": clockUID] as [String: Any],
            "notes": [
                "分軌為擷取管線提供的資料，未套用增益、限制器或混音。",
                "App 與麥克風寫入同一個共同時間線；任何無法取得的區段都在兩軌同位置補零，並記錄於 gaps。",
                "Aggregate Device 可能已做取樣率轉換與漂移補償，並非硬體逐位元原音。",
                "固定延遲（App 與麥克風）尚未量測。",
                "錄音中輸出裝置、取樣率、格式或裝置連接改變時會自動重建錄音管線並接著錄；中斷的空白在兩軌同位置補零（gaps 中 kind 為 device），經過記錄於 deviceSwitches。",
                "本版不輸出 WAV 與混音檔。"
            ],
        ]
        if options.recordApp { json["tap"] = ["sampleRate": tapRate, "channels": tapChannels] as [String: Any] }
        if let startError { json["startError"] = startError }
        json["deviceSwitches"] = deviceSwitches
        if let deviceStopReason { json["deviceStopReason"] = deviceStopReason }
        if let settledAtStop { json["deviceGapSettledAtStop"] = settledAtStop }
        if let requestedAt { json["requestedAt"] = iso.string(from: requestedAt) }
        if let started { json["startedAt"] = iso.string(from: started) }
        if let ended { json["endedAt"] = iso.string(from: ended) }
        if let started, let ended { json["wallSeconds"] = ended.timeIntervalSince(started) }
        if let out = initialOutputDevice ?? outputDevice {
            // 錄音開始時的輸出裝置（逐字稿自動模式的說明依此）
            json["outputDevice"] = ["name": out.name, "uid": out.uid, "nominalRate": out.nominalRate,
                                    "transport": out.transport, "bluetooth": out.isBluetooth] as [String: Any]
        }
        if let out = outputDevice, out.uid != initialOutputDevice?.uid {
            json["outputDeviceAtEnd"] = ["name": out.name, "uid": out.uid, "transport": out.transport] as [String: Any]
        }
        if let mic = options.mic {
            var m: [String: Any] = ["name": mic.name, "uid": mic.uid, "nominalRate": mic.nominalRate,
                                    "channels": mic.inputChannels, "transport": mic.transport,
                                    "bluetooth": mic.isBluetooth]
            if let micLostAt { m["disconnectedAtSeconds"] = micLostAt }
            json["microphone"] = m
        }
        if let layout {
            json["bufferMapping"] = [
                "rule": "active subdevice 依清單順序在前，tap 在最後",
                "expectedLayout": layout.expectedLayout,
                "actualLayout": layout.bufferChannels,
                "subDevices": layout.subDevices,
                "appBuffers": layout.appBuffers,
                "microphoneBuffers": layout.micBuffers,
                "confirmedByLayout": layout.discriminative,
            ] as [String: Any]
        }

        if let writer {
            let snap = writer.snapshot()
            var tracks: [String: Any] = [:]
            if options.recordApp {
                tracks["app"] = ["file": "capture/app.caf", "channels": sessionAppChannels,
                                 "framesOnDisk": snap.appFramesOnDisk,
                                 "peakDbfs": snap.appPeak > 0 ? 20 * log10(Double(snap.appPeak)) : -999] as [String: Any]
            }
            if options.mic != nil {
                tracks["microphone"] = ["file": "capture/microphone.caf", "channels": sessionMicChannels,
                                        "framesOnDisk": snap.micFramesOnDisk,
                                        "peakDbfs": snap.micPeak > 0 ? 20 * log10(Double(snap.micPeak)) : -999] as [String: Any]
            }
            json["tracks"] = tracks
            json["timeline"] = ["frames": snap.timeline, "dataFrames": snap.data, "zeroFilledFrames": snap.zeros,
                                "seconds": sampleRate > 0 ? Double(snap.timeline) / sampleRate : 0] as [String: Any]
            // 最後一道保險：檔案長度應等於實際經過的時間。不符代表有沒預料到的時間錯誤（例如假空白）
            if let started, let ended, sampleRate > 0 {
                let fileSec = Double(snap.timeline) / sampleRate
                let wallSec = ended.timeIntervalSince(started)
                let diff = fileSec - wallSec
                json["lengthCheck"] = ["fileSeconds": (fileSec * 1000).rounded() / 1000,
                                       "wallSeconds": (wallSec * 1000).rounded() / 1000,
                                       "differenceSeconds": (diff * 1000).rounded() / 1000,
                                       "toleranceSeconds": lengthToleranceSeconds,
                                       "ok": abs(diff) <= lengthToleranceSeconds] as [String: Any]
            }
            let kindName: [UInt32: String] = [UInt32(AR_GAP_OVERFLOW): "overflow",
                                              UInt32(AR_GAP_TIMESTAMP): "timestamp",
                                              UInt32(AR_GAP_LAYOUT): "layout",
                                              UInt32(AR_GAP_DEVICE): "device"]
            let rate = sampleRate
            var gaps: [String: Any] = [
                "list": snap.gaps.map { g -> [String: Any] in
                    ["timelineFrame": g.timelineFrame, "frames": g.frames,
                     "startSeconds": rate > 0 ? Double(g.timelineFrame) / rate : 0,
                     "kind": kindName[g.kind] ?? "\(g.kind)", "sampleTime": g.sampleTime,
                     "startupFrames": g.startupFrames, "recordingFrames": g.recordingFrames,
                     "phase": g.recordingFrames == 0 ? "startup" : (g.startupFrames > 0 ? "spansStartup" : "recording")]
                },
                "listTruncated": snap.gapRecordsDropped,
                "startupWindowSeconds": startupWindowSeconds,
                "startup": ["events": snap.startupEvents, "frames": snap.startupFrames] as [String: Any],
                "midRecording": ["events": snap.midEvents, "frames": snap.midFrames] as [String: Any],
            ]
            if let capture {
                gaps["overflow"] = ["events": ar_capture_overflow_events(capture),
                                    "frames": ar_capture_overflow_frames(capture)] as [String: Any]
                gaps["timestamp"] = ["events": ar_capture_timestamp_gap_events(capture),
                                     "frames": ar_capture_timestamp_gap_frames(capture)] as [String: Any]
                gaps["layout"] = ["events": ar_capture_layout_gap_events(capture),
                                  "frames": ar_capture_layout_gap_frames(capture)] as [String: Any]
                gaps["device"] = ["events": ar_capture_device_gap_events(capture),
                                  "frames": ar_capture_device_gap_frames(capture)] as [String: Any]
                gaps["lostRecords"] = ar_capture_lost_gap_events(capture)
                gaps["backwardsTimestamps"] = ar_capture_backwards_events(capture)
                gaps["timestampRebase"] = ["events": ar_capture_rebase_events(capture),
                                           "gapFrames": ar_capture_rebase_gap_frames(capture),
                                           "overlapFrames": ar_capture_rebase_overlap_frames(capture)] as [String: Any]
            }
            json["gaps"] = gaps
            if let err = writer.error { json["writeError"] = err }
        }

        if let capture {
            var lastLayout: [[String: Any]] = []
            let count = Int(ar_capture_buffer_count(capture))
            for i in 0..<min(count, 8) {
                lastLayout.append(["index": i, "channels": ar_capture_buffer_channels(capture, UInt32(i)),
                                   "frames": ar_capture_buffer_frames(capture, UInt32(i))])
            }
            json["diagnostics"] = [
                "callbacks": ar_capture_callbacks(capture),
                "segments": ar_capture_segments(capture),
                "framesWrittenToRing": ar_capture_frames_written(capture),
                "firstSampleTime": ar_capture_first_sample_time(capture),
                "nextSampleTime": ar_capture_next_sample_time(capture),
                "bufferFrameSize": bufferFrameSize,
                "lastCallbackLayout": lastLayout,
            ] as [String: Any]
        }
        eventLock.lock()
        json["events"] = events
        eventLock.unlock()
        json["clockTrace"] = clockTrace
        return json
    }

    private func writeJSON(_ json: [String: Any]) throws {
        guard let sessionDir else { return }
        let data = try JSONSerialization.data(withJSONObject: json,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: sessionDir.appendingPathComponent("session.json"), options: .atomic)
    }

    deinit {
        freeSourceTables()
        if let capture { ar_capture_destroy(capture) }
    }
}

/// 給人看的時間長度：不到 10 秒到小數一位，1 分鐘以上寫成「幾分幾秒」（不用毫秒）。
func humanDuration(_ seconds: Double) -> String {
    let t = abs(seconds)
    if t < 0.05 { return "不到 0.1 秒" }
    if t < 10 { return String(format: "%.1f 秒", t) }
    let total = Int(t.rounded())
    if total < 60 { return "\(total) 秒" }
    let m = total / 60, sec = total % 60
    return sec == 0 ? "\(m) 分鐘" : "\(m) 分 \(sec) 秒"
}
