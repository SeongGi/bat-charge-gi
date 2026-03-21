#!/bin/bash
# ==========================================================
# bat-charge-gi 완벽 복구 및 자동 프레임워크 교체 빌드 (v2.8.8+)
# ==========================================================
set -e

APP_NAME="bat-charge-gi"
BUNDLE="bat-charge-gi.app"
BUNDLE_ID="com.seonggi.bat-charge-gi"

echo "1. 🚑 Checking Sparkle Framework..."
# 프레임워크가 없거나 망가졌다면 새로 받습니다.
if [ ! -d "Sparkle_Framework/Sparkle.framework" ] || ([ -d "Sparkle_Framework/Sparkle.framework/Versions/Current" ] && [ ! -L "Sparkle_Framework/Sparkle.framework/Versions/Current" ]); then
    echo "   ⚠️ Framework missing or corrupted! Downloading fresh Sparkle..."
    rm -rf Sparkle_Framework sparkle.tar.xz || true
    mkdir -p Sparkle_Framework
    # Sparkle 2.x 정식 릴리스 다운로드
    curl -L https://github.com/sparkle-project/Sparkle/releases/download/2.5.2/Sparkle-2.5.2.tar.xz -o sparkle.tar.xz
    tar -xf sparkle.tar.xz -C Sparkle_Framework/
    rm sparkle.tar.xz
    echo "   ✅ Fresh Sparkle Downloaded and Extracted."
fi

# 소스 경로 권한 및 보안 속성 제거
xattr -cr Sparkle_Framework/Sparkle.framework || true

echo "2. Cleaning up old build..."
rm -rf "${BUNDLE}"
mkdir -p "${BUNDLE}/Contents/MacOS"
mkdir -p "${BUNDLE}/Contents/Resources"
mkdir -p "${BUNDLE}/Contents/Frameworks"

echo "3. Injecting Info.plist & Assets..."
cp bat-charge-gi/Info.plist "${BUNDLE}/Contents/Info.plist"
cp AppIcon.icns "${BUNDLE}/Contents/Resources/AppIcon.icns"
if [ ! -f "smc_cache" ]; then
    curl -sL https://raw.githubusercontent.com/actuallymentor/battery/main/dist/smc -o "smc_cache"
fi
cp "smc_cache" "${BUNDLE}/Contents/MacOS/smc"
chmod +x "${BUNDLE}/Contents/MacOS/smc"

echo "4. Compiling Helper Daemon..."
mkdir -p .swift_cache
swiftc BatteryHelper/main.swift BatteryHelper/BatteryHelper.swift BatteryHelper/SMCManager.swift Shared/BatteryHelperProtocol.swift \
    -o helper_bin -module-cache-path .swift_cache -target arm64-apple-macosx13.0 \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker BatteryHelper/Info.plist
cp helper_bin "${BUNDLE}/Contents/MacOS/com.seonggi.bat-charge-gi.helper"

echo "5. Building Main App..."
swiftc \
    bat-charge-gi/bat-charge-giApp.swift \
    bat-charge-gi/ContentView.swift \
    bat-charge-gi/DashboardView.swift \
    bat-charge-gi/DaemonManager.swift \
    Shared/BatteryHelperProtocol.swift \
    -o main_bin -module-cache-path .swift_cache -target arm64-apple-macosx13.0 \
    -F Sparkle_Framework -framework Sparkle \
    -Xcc -ISparkle_Framework/Sparkle.framework/Headers \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks
cp main_bin "${BUNDLE}/Contents/MacOS/${APP_NAME}"

echo "6. Embedding Framework (Using ditto to preserve links)..."
ditto Sparkle_Framework/Sparkle.framework "${BUNDLE}/Contents/Frameworks/Sparkle.framework"

echo "7. Final Signing (Inner-to-Outer)..."
# 격리 속성 전면 제거 (타 PC 배포 시 '손상됨' 방지의 핵심)
find "${BUNDLE}" -name "*" -exec xattr -c {} \; || true
xattr -cr "${BUNDLE}" || true

codesign --force --options runtime --sign - "${BUNDLE}/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate" || true
codesign --force --options runtime --sign - "${BUNDLE}/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app" || true
codesign --force --options runtime --sign - "${BUNDLE}/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle" || true
codesign --force --options runtime --sign - "${BUNDLE}/Contents/MacOS/smc" || true
codesign --force --options runtime --sign - "${BUNDLE}/Contents/MacOS/com.seonggi.bat-charge-gi.helper" || true
codesign --force --options runtime --sign - "${BUNDLE}/Contents/MacOS/bat-charge-gi" || true
codesign --force --deep --options runtime --sign - "${BUNDLE}"

rm -f helper_bin main_bin
echo "--------------------------------------------------"
echo "✅ CLEAN BUILD SUCCESSFUL!"
echo "Now run the sudo installation commands provided above."
echo "--------------------------------------------------"
