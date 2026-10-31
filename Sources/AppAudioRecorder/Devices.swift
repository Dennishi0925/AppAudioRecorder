import Foundation
import CoreAudio

// MARK: - 共用小工具

struct AudioError: Error, CustomStringConvertible {
    let description: String
}

func check(_ status: OSStatus, _ what: String) throws {
    guard status == noErr else {
        throw AudioError(description: "\(what)失敗(OSStatus \(status))")
    }
}

func address(_ selector: AudioObjectPropertySelector,
             scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func getString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var addr = address(selector)
    var value: Unmanaged<CFString>? = nil
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value)
    guard status == noErr, let value else { return nil }
    return value.takeRetainedValue() as String
}

func getUInt32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
    var addr = address(selector)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value)
    return status == noErr ? value : nil
}

func getFloat64(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Double? {
    var addr = address(selector)
    var value: Float64 = 0
    var size = UInt32(MemoryLayout<Float64>.size)
    let status = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value)
    return status == noErr ? value : nil
}

// MARK: - 行程

struct AudioProcess {
    let object: AudioObjectID
    let pid: pid_t
    let bundleID: String
    let isOutputting: Bool
}

func listAudioProcesses() -> [AudioProcess] {
    var addr = address(kAudioHardwarePropertyProcessObjectList)
    var size: UInt32 = 0
    let system = AudioObjectID(kAudioObjectSystemObject)
    guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }

    var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &objects) == noErr else { return [] }

    return objects.compactMap { obj in
        guard let pid = getUInt32(obj, kAudioProcessPropertyPID) else { return nil }
        let bundleID = getString(obj, kAudioProcessPropertyBundleID) ?? "(無 bundle id)"
        let running = (getUInt32(obj, kAudioProcessPropertyIsRunningOutput) ?? 0) != 0
        return AudioProcess(object: obj, pid: pid_t(pid), bundleID: bundleID, isOutputting: running)
    }
}

/// 多個 App 共用、無法由 bundle ID 判斷屬於哪個 App 的系統元件。
/// 例如 com.apple.WebKit.GPU：Safari 與其他使用 WebKit 的 App 各有一個，bundle ID 完全相同。
let sharedComponentPrefixes = ["com.apple.WebKit."]

func isSharedComponent(_ process: AudioProcess) -> Bool {
    sharedComponentPrefixes.contains { process.bundleID.hasPrefix($0) }
}

struct ProcessSelection {
    var matched: [AudioProcess] = []
    /// 名稱相關但屬於共用元件、未自動納入的行程（只供提示）
    var sharedCandidates: [AudioProcess] = []
    var byPID = false
}

/// 選擇要錄的行程。
/// - 全是數字（可用逗號分隔，例如 "1467,34321"）：只錄這些 PID，包含共用元件。
/// - 其他：比對 bundle ID 是否包含關鍵字（不分大小寫），但**不會**自動納入共用元件。
///   bundle ID 子字串只是方便搜尋，不代表行程歸屬已被驗證。
/// 某個 App 的音訊行程：bundle ID 完全相同，或以「bundle ID + .」開頭的輔助行程（例如 com.microsoft.edgemac.helper）。
/// 共用元件一律排除。這是依命名慣例歸類，不是經驗證的行程歸屬。
func processesForBundle(_ bundleID: String, in all: [AudioProcess]) -> [AudioProcess] {
    all.filter { ($0.bundleID == bundleID || $0.bundleID.hasPrefix(bundleID + ".")) && !isSharedComponent($0) }
}

func selectProcesses(_ selector: String, in all: [AudioProcess]) -> ProcessSelection {
    var result = ProcessSelection()
    // 圖形介面用：bundle:<id> 依 bundle ID 歸類
    if selector.hasPrefix("bundle:") {
        result.matched = processesForBundle(String(selector.dropFirst("bundle:".count)), in: all)
        return result
    }
    let parts = selector.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    let pids = parts.compactMap { Int32($0) }
    if !parts.isEmpty && pids.count == parts.count {
        result.byPID = true
        result.matched = all.filter { pids.contains($0.pid) }
        return result
    }
    let needle = selector.lowercased()
    for p in all where p.bundleID.lowercased().contains(needle) {
        if isSharedComponent(p) {
            result.sharedCandidates.append(p)
        } else {
            result.matched.append(p)
        }
    }
    // 以 WebKit 播放聲音的 App（例如 Safari）主程式本身通常不出聲，提示可能相關的共用元件
    let webKitHosts = ["safari", "com.apple.safari"]
    if webKitHosts.contains(needle) {
        let already = Set(result.sharedCandidates.map { $0.pid })
        let extra = all.filter { isSharedComponent($0) && !already.contains($0.pid) }
        result.sharedCandidates.append(contentsOf: extra)
    }
    return result
}

// MARK: - 音訊裝置

struct AudioDevice {
    let id: AudioObjectID
    let uid: String
    let name: String
    let inputChannels: Int
    let outputChannels: Int
    let nominalRate: Double
    let transport: String
    let isBluetooth: Bool
}

func channelCount(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
    var addr = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw) == noErr else { return 0 }
    let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    var total = 0
    for buffer in list { total += Int(buffer.mNumberChannels) }
    return total
}

private func transportName(_ type: UInt32?) -> (String, Bool) {
    guard let type else { return ("未知", false) }
    switch type {
    case kAudioDeviceTransportTypeBuiltIn: return ("內建", false)
    case kAudioDeviceTransportTypeUSB: return ("USB", false)
    case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return ("藍牙", true)
    case kAudioDeviceTransportTypeAggregate: return ("Aggregate", false)
    case kAudioDeviceTransportTypeVirtual: return ("虛擬", false)
    case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return ("HDMI／DisplayPort", false)
    case kAudioDeviceTransportTypeAirPlay: return ("AirPlay", false)
    default: return ("其他", false)
    }
}

func makeDevice(_ id: AudioObjectID) -> AudioDevice? {
    guard let uid = getString(id, kAudioDevicePropertyDeviceUID) else { return nil }
    let name = getString(id, kAudioObjectPropertyName) ?? uid
    let (transport, bluetooth) = transportName(getUInt32(id, kAudioDevicePropertyTransportType))
    return AudioDevice(
        id: id,
        uid: uid,
        name: name,
        inputChannels: channelCount(id, scope: kAudioObjectPropertyScopeInput),
        outputChannels: channelCount(id, scope: kAudioObjectPropertyScopeOutput),
        nominalRate: getFloat64(id, kAudioDevicePropertyNominalSampleRate) ?? 0,
        transport: transport,
        isBluetooth: bluetooth
    )
}

func listDevices() -> [AudioDevice] {
    var addr = address(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    let system = AudioObjectID(kAudioObjectSystemObject)
    guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids.compactMap { makeDevice($0) }
}

func defaultDeviceID(_ selector: AudioObjectPropertySelector) -> AudioObjectID? {
    var addr = address(selector)
    var device = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device)
    return (status == noErr && device != AudioObjectID(kAudioObjectUnknown)) ? device : nil
}

/// "default" = 系統預設輸入；其他字串 = 裝置名稱或 UID 的部分比對（不分大小寫）。
func findInputDevice(_ keyword: String) -> AudioDevice? {
    if keyword.lowercased() == "default" {
        guard let id = defaultDeviceID(kAudioHardwarePropertyDefaultInputDevice) else { return nil }
        return makeDevice(id)
    }
    let needle = keyword.lowercased()
    return listDevices().first {
        $0.inputChannels > 0 && ($0.name.lowercased().contains(needle) || $0.uid.lowercased().contains(needle))
    }
}

// MARK: - Stream 配置

/// 每個 stream（也就是 IO callback 裡的每個緩衝區）的聲道數，依系統回報的順序。
func streamChannelLayout(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> [Int] {
    var addr = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw) == noErr else { return [] }
    let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return list.map { Int($0.mNumberChannels) }
}

/// 讀取 AudioObjectID 陣列型別的屬性。
func getObjectIDs(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                  scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID]? {
    var addr = address(selector, scope: scope)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr else { return nil }
    let count = Int(size) / MemoryLayout<AudioObjectID>.size
    if count == 0 { return [] }
    var ids = [AudioObjectID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &ids) == noErr else { return nil }
    return ids
}

/// 每個輸入 stream 在 IO callback 中提供的格式（virtual format）。
func inputStreamFormats(_ device: AudioObjectID) -> [AudioStreamBasicDescription]? {
    guard let streams = getObjectIDs(device, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput) else {
        return nil
    }
    var formats: [AudioStreamBasicDescription] = []
    for stream in streams {
        var addr = address(kAudioStreamPropertyVirtualFormat)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(stream, &addr, 0, nil, &size, &asbd) == noErr else { return nil }
        formats.append(asbd)
    }
    return formats
}

/// 是否為本程式能直接搬移的格式：32 位元浮點、交錯（每個緩衝區一個 stream）。
func isInterleavedFloat32(_ f: AudioStreamBasicDescription) -> Bool {
    f.mFormatID == kAudioFormatLinearPCM
        && (f.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        && (f.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
        && f.mBitsPerChannel == 32
}
