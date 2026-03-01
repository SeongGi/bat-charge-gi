#!/bin/bash
set -e

APP_NAME="bat-charge-gi"
BUNDLE="bat-charge-gi.app"

echo "Building Helper Daemon..."
export TMPDIR=/tmp/
export DARWIN_USER_TEMP_DIR=/tmp/
export DARWIN_USER_CACHE_DIR=/tmp/

rm -rf "${BUNDLE}/Contents/MacOS"
mkdir -p "${BUNDLE}/Contents/MacOS"
mkdir -p "${BUNDLE}/Contents/MacOS"
mkdir -p "${BUNDLE}/Contents/Resources"

cp bat-charge-gi/Info.plist "${BUNDLE}/Contents/Info.plist"

# 앱 시스템 아이콘 이식
echo "Injecting AppIcon Asset..."
cp AppIcon.icns "${BUNDLE}/Contents/Resources/AppIcon.icns"

# SMC 바이너리 추출 (Apple Silicon 전용)
echo "Fetching SMC Utility..."
curl -sL https://raw.githubusercontent.com/actuallymentor/battery/main/dist/smc -o "${BUNDLE}/Contents/MacOS/smc"
chmod +x "${BUNDLE}/Contents/MacOS/smc"

echo "Compiling Helper Daemon..."
swiftc BatteryHelper/main.swift BatteryHelper/BatteryHelper.swift BatteryHelper/SMCManager.swift Shared/BatteryHelperProtocol.swift \
    -o helper_bin -module-cache-path /tmp/swmodulecache -target arm64-apple-macosx13.0 \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker BatteryHelper/Info.plist
cp helper_bin "${BUNDLE}/Contents/MacOS/com.seonggi.bat-charge-gi.helper"

# SMAppService를 위한 Plist 복제
mkdir -p "${BUNDLE}/Contents/Library/LaunchDaemons"
cat <<EOF > "${BUNDLE}/Contents/Library/LaunchDaemons/com.seonggi.bat-charge-gi.helper.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.seonggi.bat-charge-gi.helper</string>
    <key>BundleProgram</key>
    <string>MacOS/com.seonggi.bat-charge-gi.helper</string>
    <key>MachServices</key>
    <dict>
        <key>com.seonggi.bat-charge-gi.helper</key>
        <true/>
    </dict>
</dict>
</plist>
EOF

echo "Building Main App..."
swiftc \
    bat-charge-gi/bat-charge-giApp.swift \
    bat-charge-gi/ContentView.swift \
    bat-charge-gi/DashboardView.swift \
    bat-charge-gi/DaemonManager.swift \
    Shared/BatteryHelperProtocol.swift \
    -o main_bin -module-cache-path /tmp/swmodulecache -target arm64-apple-macosx13.0 \
    -F Sparkle_Framework -framework Sparkle \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks

cp main_bin "${BUNDLE}/Contents/MacOS/${APP_NAME}"

echo "Embedding Sparkle Framework..."
mkdir -p "${BUNDLE}/Contents/Frameworks"
rm -rf "${BUNDLE}/Contents/Frameworks/Sparkle.framework"
cp -a Sparkle_Framework/Sparkle.framework "${BUNDLE}/Contents/Frameworks/"

echo "Signing App..."
# Remove extended attributes that might break signature
xattr -cr "${BUNDLE}"
# Sign Sparkle framework inner components first
codesign -f -s - "${BUNDLE}/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app" || true
codesign -f -s - "${BUNDLE}/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc" || true
codesign -f -s - "${BUNDLE}/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc" || true
codesign -f -s - "${BUNDLE}/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate" || true

codesign -f -s - "${BUNDLE}/Contents/MacOS/smc" || true
codesign -f -s - "${BUNDLE}/Contents/MacOS/com.seonggi.bat-charge-gi.helper" || true
codesign -f -s - "${BUNDLE}/Contents/MacOS/bat-charge-gi" || true

# Sign the whole app
codesign -f -s - "${BUNDLE}"

rm -f helper_bin main_bin smc_bin
echo "Build and App Signing Complete!"
