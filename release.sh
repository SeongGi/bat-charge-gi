#!/bin/bash
# =============================================================
# bat-charge-gi 통합 릴리스 스크립트
# 사용법: ./release.sh 2.7.6
# 1) 소스코드 빌드 → 2) DMG 패키징 → 3) Sparkle 서명 →
# 4) appcast.xml 자동 갱신 → 5) Git 커밋/푸시 → 6) GitHub Release 생성
# =============================================================
set -e

NEW_VERSION="${1}"
if [ -z "$NEW_VERSION" ]; then
    echo "❌ 사용법: ./release.sh [버전번호]"
    echo "   예시: ./release.sh 2.7.6"
    exit 1
fi

PRIVATE_KEY="npsrXuHJQ78Ban4rBCX9pWE+l66IFkQ3YUwiMcrGspI="
APP_NAME="bat-charge-gi"

echo ""
echo "🚀 === bat-charge-gi v${NEW_VERSION} 릴리스 시작 === 🚀"
echo ""

# ── 1단계: Info.plist 버전 갱신 ──
echo "[1/7] Info.plist 버전을 v${NEW_VERSION}으로 갱신..."
sed -i '' "s|<string>[0-9]*\.[0-9]*\.[0-9]*</string><!-- CFBundleShortVersionString -->|<string>${NEW_VERSION}</string><!-- CFBundleShortVersionString -->|g" bat-charge-gi/Info.plist 2>/dev/null || true
# plutil 방식 (더 안전)
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${NEW_VERSION}" bat-charge-gi/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${NEW_VERSION}" bat-charge-gi/Info.plist
echo "   ✅ Info.plist → v${NEW_VERSION}"

# ── 2단계: 앱 빌드 ──
echo "[2/7] 최신 소스코드로 앱 빌드 중..."
./build.sh
echo "   ✅ 빌드 완료"

# ── 3단계: DMG 패키징 ──
echo "[3/7] DMG 패키징 중..."
./build_dmg.sh
echo "   ✅ DMG 생성 완료"

# ── 4단계: Sparkle EdDSA 서명 ──
echo "[4/7] Sparkle EdDSA 서명 생성 중..."
# Sparkle은 zip을 서명해야 하므로 앱을 zip으로도 압축
rm -f ${APP_NAME}.zip
zip -r -q ${APP_NAME}.zip ${APP_NAME}.app
SIGN_OUTPUT=$(echo "$PRIVATE_KEY" | Sparkle_Framework/bin/sign_update --ed-key-file - ${APP_NAME}.zip 2>&1)
ED_SIGNATURE=$(echo "$SIGN_OUTPUT" | grep -o 'sparkle:edSignature="[^"]*"' | sed 's/sparkle:edSignature="//;s/"//')
FILE_LENGTH=$(stat -f%z ${APP_NAME}.dmg)
echo "   서명: ${ED_SIGNATURE}"
echo "   크기: ${FILE_LENGTH} bytes"
echo "   ✅ 서명 완료"

# ── 5단계: appcast.xml 자동 갱신 ──
echo "[5/7] appcast.xml 갱신 중..."
PUB_DATE=$(date -R)
cat > appcast.xml << APPCAST_EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>bat-charge-gi 업데이트</title>
        <item>
            <title>Version ${NEW_VERSION}</title>
            <description><![CDATA[
            <ul>
                <li>최신 버전 v${NEW_VERSION} 릴리스</li>
            </ul>
            ]]></description>
            <pubDate>${PUB_DATE}</pubDate>
            <enclosure url="https://github.com/SeongGi/bat-charge-gi/releases/download/v${NEW_VERSION}/${APP_NAME}.dmg"
                       sparkle:version="${NEW_VERSION}"
                       sparkle:shortVersionString="${NEW_VERSION}"
                       type="application/octet-stream"
                       length="${FILE_LENGTH}"
                       sparkle:edSignature="${ED_SIGNATURE}" />
        </item>
    </channel>
</rss>
APPCAST_EOF
echo "   ✅ appcast.xml → v${NEW_VERSION}"

# ── 6단계: SHA256 해시 → bat-charge-gi.rb Cask 갱신 + Git 커밋/푸시 ──
echo "[6/7] Homebrew Cask 갱신 및 Git 푸시 중..."
DMG_HASH=$(shasum -a 256 ${APP_NAME}.dmg | awk '{print $1}')
echo "   DMG SHA256: ${DMG_HASH}"

sed -i '' "s|version \".*\"|version \"${NEW_VERSION}\"|" bat-charge-gi.rb
sed -i '' "s|sha256 \".*\"|sha256 \"${DMG_HASH}\"|" bat-charge-gi.rb

git add bat-charge-gi/Info.plist bat-charge-gi.rb appcast.xml ${APP_NAME}.zip
git commit -m "release: v${NEW_VERSION}"
git push origin main

# Homebrew Tap도 갱신
if [ -d /tmp/homebrew-tap-fresh ]; then
    cp bat-charge-gi.rb /tmp/homebrew-tap-fresh/Casks/bat-charge-gi.rb
    cd /tmp/homebrew-tap-fresh
    git pull origin main 2>/dev/null || true
    git add Casks/bat-charge-gi.rb
    git commit -m "release: v${NEW_VERSION}" 2>/dev/null || true
    git push origin main
    cd -
fi
echo "   ✅ Git 푸시 완료"

# ── 7단계: GitHub Release 생성 + DMG 업로드 ──
echo "[7/7] GitHub Release 생성 및 DMG 업로드 중..."
gh release create "v${NEW_VERSION}" \
    --title "v${NEW_VERSION}" \
    --notes "bat-charge-gi v${NEW_VERSION} 릴리스" 2>/dev/null || true
gh release upload "v${NEW_VERSION}" "${APP_NAME}.dmg" --clobber 2>/dev/null || true

echo ""
echo "🎉🎉🎉 v${NEW_VERSION} 릴리스 완료! 🎉🎉🎉"
echo ""
echo "📋 요약:"
echo "   버전:    v${NEW_VERSION}"
echo "   SHA256:  ${DMG_HASH}"
echo "   서명:    ${ED_SIGNATURE}"
echo ""
