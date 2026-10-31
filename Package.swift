// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AppAudioRecorder",
    platforms: [.macOS("14.4")],
    targets: [
        // 無鎖 ring buffer 與回呼診斷（C，供即時 callback 使用，不經過 Swift 執行環境）
        .target(
            name: "CRing",
            path: "Sources/CRing"
        ),
        .executableTarget(
            name: "AppAudioRecorder",
            dependencies: ["CRing"],
            path: "Sources/AppAudioRecorder",
            exclude: ["Info.plist"],
            linkerSettings: [
                // 把 Info.plist 嵌進執行檔,讓系統能顯示「音訊擷取／麥克風」權限說明
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/AppAudioRecorder/Info.plist",
                ])
            ]
        )
    ]
)
