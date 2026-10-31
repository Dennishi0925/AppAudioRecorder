#!/bin/bash
# 把 AppAudioRecorder 組成 .app 並簽署。只需要 Command Line Tools，不需要 Xcode。
#
# 用法（在 AppAudioRecorder 資料夾裡）：
#   ./scripts/build-app.sh
# 產出：build/AppAudioRecorder.app
#
# 簽署：若鑰匙圈裡有名為「AppAudioRecorder Local」的程式碼簽署憑證就用它
#（固定身分，重新建置後 macOS 較可能沿用已授權的錄音權限）；否則改用臨時簽署（ad-hoc）。
# 可用 SIGN_IDENTITY 環境變數指定其他憑證名稱。
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Sources/AppAudioRecorder/Info.plist)
echo "建置 AppAudioRecorder ${VERSION}（release）…"
swift build -c release

APP="build/AppAudioRecorder.app"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp .build/release/AppAudioRecorder "${APP}/Contents/MacOS/AppAudioRecorder"
sed "s/__VERSION__/${VERSION}/g" packaging/Info.plist > "${APP}/Contents/Info.plist"
printf 'APPL????' > "${APP}/Contents/PkgInfo"
cp packaging/AppIcon.icns "${APP}/Contents/Resources/AppIcon.icns"

IDENTITY="${SIGN_IDENTITY:-AppAudioRecorder Local}"
if security find-identity -p codesigning 2>/dev/null | grep -q "\"${IDENTITY}\""; then
    codesign --force --sign "${IDENTITY}" "${APP}"
    echo "已用憑證「${IDENTITY}」簽署。"
else
    codesign --force --sign - "${APP}"
    echo "⚠️  找不到程式碼簽署憑證「${IDENTITY}」，改用臨時簽署（ad-hoc）。"
    echo "    這樣每次重新建置後，macOS 可能會重新詢問錄音／麥克風權限。"
    echo "    建立固定憑證的步驟見 README「圖形介面」一節。"
fi
codesign --verify --verbose=1 "${APP}"

echo ""
touch "${APP}"   # 讓 Finder／Dock 重新讀取圖示
echo "完成：${APP}"
echo "開啟：open \"${APP}\""
echo "要放進「應用程式」資料夾：cp -R \"${APP}\" /Applications/"
