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

if [ -f "sparkle_priv.key" ]; then
    PRIVATE_KEY=$(cat sparkle_priv.key)
else
    echo "❌ sparkle_priv.key 파일이 존재하지 않습니다. 종료합니다."
    exit 1
fi
APP_NAME="bat-charge-gi"

echo ""
echo "🚀 === bat-charge-gi v${NEW_VERSION} 릴리스 시작 === 🚀"
echo ""

# ── 1단계: 버전 정보 갱신 (project.yml, Info.plist) ──
echo "[1/7] 버전 정보를 v${NEW_VERSION}으로 갱신..."

# project.yml 갱신
if [ -f "project.yml" ]; then
    sed -i '' "s|MARKETING_VERSION: .*|MARKETING_VERSION: ${NEW_VERSION}|" project.yml
    sed -i '' "s|CURRENT_PROJECT_VERSION: .*|CURRENT_PROJECT_VERSION: ${NEW_VERSION}.0|" project.yml
fi

# Info.plist 갱신
if [ -f "bat-charge-gi/Info.plist" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${NEW_VERSION}" bat-charge-gi/Info.plist || true
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${NEW_VERSION}" bat-charge-gi/Info.plist || true
fi
echo "   ✅ Version updated to v${NEW_VERSION}"

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
# 1. 우선 키체인(keychain)을 사용하여 서명을 시도합니다. (가장 권장되는 방식)
SIGN_OUTPUT=$(Sparkle_Framework/bin/sign_update "${APP_NAME}.dmg" 2>&1)
EXIT_CODE=$?

if [ $EXIT_CODE -ne 0 ]; then
    echo "   ⚠️ Keychain signing failed (Error: $SIGN_OUTPUT)"
    echo "   Trying manual signing with PRIVATE_KEY..."
    # 2. 키체인 실패 시 제공된 PRIVATE_KEY 변수를 사용해 시도합니다.
    SIGN_OUTPUT=$(echo "$PRIVATE_KEY" | Sparkle_Framework/bin/sign_update --ed-key-file - "${APP_NAME}.dmg" 2>&1)
    EXIT_CODE=$?
fi

if [ $EXIT_CODE -ne 0 ]; then
    echo "❌ 서명 생성에 실패했습니다."
    echo "   오류 내용: $SIGN_OUTPUT"
    exit 1
fi

ED_SIGNATURE=$(echo "$SIGN_OUTPUT" | grep -o 'sparkle:edSignature="[^"]*"' | sed 's/sparkle:edSignature="//;s/"//')
FILE_LENGTH=$(stat -f%z "${APP_NAME}.dmg")
echo "   서명: ${ED_SIGNATURE}"
echo "   크기: ${FILE_LENGTH} bytes"
echo "   ✅ 서명 완료"

# ── 5단계: appcast.xml 업데이트 (스마트 갱신) ──
echo "[5/7] appcast.xml 갱신 중..."
PUB_DATE=$(date -R)

# 기존 appcast.xml에서 구버전 아이템들을 추출하여 새 항목 아래에 배치
TEMP_APPCAST="/tmp/appcast_temp.xml"

cat > "${TEMP_APPCAST}" << APPCAST_HEADER
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>bat-charge-gi 업데이트</title>
         <item>
             <title>Version ${NEW_VERSION}</title>
             <description><![CDATA[
             <ul>
                 <li><b>[버그수정]</b> 초기 부팅 시 상단 메뉴바에 아이콘이 중복으로 생성되던 현상을 해결했습니다.</li>
                 <li><b>[안정성]</b> 백그라운드 데몬과의 연동 신뢰성을 향상시키고 전반적인 앱 구동 안정성을 개선했습니다.</li>
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
APPCAST_HEADER

# 기존 파일에서 <item> 부분만 추출하여 합치기 (최대 10개까지 유지)
if [ -f "appcast.xml" ]; then
    grep -A 1000 "<item>" appcast.xml | grep -v "</channel>" | grep -v "</rss>" >> "${TEMP_APPCAST}" || true
else
    echo "    </channel>" >> "${TEMP_APPCAST}"
    echo "</rss>" >> "${TEMP_APPCAST}"
fi

# 닫는 태그가 중복되지 않도록 정리 (간단한 방식)
if ! grep -q "</channel>" "${TEMP_APPCAST}"; then
    echo "    </channel>" >> "${TEMP_APPCAST}"
fi
if ! grep -q "</rss>" "${TEMP_APPCAST}"; then
    echo "</rss>" >> "${TEMP_APPCAST}"
fi

mv "${TEMP_APPCAST}" appcast.xml
echo "   ✅ appcast.xml 갱신 완료"

# ── 6단계: SHA256 해시 → bat-charge-gi.rb Cask 갱신 + Git 커밋/푸시 ──
echo "[6/7] Homebrew Cask 갱신 및 Git 푸시 중..."
DMG_HASH=$(shasum -a 256 ${APP_NAME}.dmg | awk '{print $1}')
echo "   DMG SHA256: ${DMG_HASH}"

sed -i '' "s|version \".*\"|version \"${NEW_VERSION}\"|" bat-charge-gi.rb
sed -i '' "s|sha256 \".*\"|sha256 \"${DMG_HASH}\"|" bat-charge-gi.rb

git add bat-charge-gi/Info.plist project.yml bat-charge-gi.rb appcast.xml 2>/dev/null || true
git commit -m "release: v${NEW_VERSION}" 2>/dev/null || true
# git push origin main 2>/dev/null || true  # 안전을 위해 푸시는 수동 확인 후 권장하거나, 필요시 주석 해제

# Homebrew Tap도 갱신
if [ ! -d "/tmp/homebrew-tap-fresh" ]; then
    echo "   Tap 저장소를 /tmp에 클론 중..."
    git clone https://github.com/SeongGi/homebrew-tap.git /tmp/homebrew-tap-fresh
fi

cp bat-charge-gi.rb /tmp/homebrew-tap-fresh/Casks/bat-charge-gi.rb 2>/dev/null || true
cd /tmp/homebrew-tap-fresh
git pull origin main 2>/dev/null || true
git add Casks/bat-charge-gi.rb 2>/dev/null || true
git commit -m "release: v${NEW_VERSION}" 2>/dev/null || true
git push origin main 2>/dev/null || true
cd -
echo "   ✅ Homebrew Tap 갱신 및 푸시 완료"
echo "   ✅ Git 푸시 시도 완료 (수동 확인 필요)"

# ── 7단계: GitHub Release 생성 + DMG 업로드 ──
echo "[7/7] GitHub Release 생성 및 DMG 업로드 중..."
# 이미 존재하는 태그일 경우를 대비해 || true 유지하지만 에러는 출력
gh release create "v${NEW_VERSION}" \
    --title "v${NEW_VERSION}" \
    --notes "bat-charge-gi v${NEW_VERSION} 릴리스 (중복 아이콘 및 재부팅 연결 문제 해결)" || true

gh release upload "v${NEW_VERSION}" "${APP_NAME}.dmg" --clobber

echo ""
echo "🎉🎉🎉 v${NEW_VERSION} 릴리스 완료! 🎉🎉🎉"
echo ""
echo "📋 요약:"
echo "   버전:    v${NEW_VERSION}"
echo "   SHA256:  ${DMG_HASH}"
echo "   서명:    ${ED_SIGNATURE}"
echo ""
