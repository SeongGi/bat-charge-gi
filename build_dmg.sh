#!/bin/bash
# bat-charge-gi 배포용 DMG 생성 스크립트

APP_NAME="bat-charge-gi"
APP_DIR="${APP_NAME}.app"
VOL_NAME="${APP_NAME}_Installer"
DMG_NAME="${APP_NAME}.dmg"
TMP_DIR="/tmp/dmg_build_output"

echo "[1] 기존 오류 마운트 포인트를 모두 정리합니다..."
hdiutil detach "/Volumes/${VOL_NAME}" -force 2>/dev/null || true
rm -rf "${TMP_DIR}" "${DMG_NAME}"

echo "[2] 디스크 이미지 빌드용 임시 폴더( /tmp )를 구축합니다..."
mkdir -p "${TMP_DIR}"
# 권한과 심볼릭 링크를 유지하며 복사
cp -a "${APP_DIR}" "${TMP_DIR}/"
ln -s /Applications "${TMP_DIR}/Applications"

echo "[3] UDZO(압축) 포맷으로 DMG 파일을 추출합니다..."
# 간혹 발생하는 "디렉토리가 비어있지 않음" 오류가 있어도 파일은 정상 생성되므로 무시합니다.
rm -f /tmp/dmg_hybrid.dmg
hdiutil makehybrid -hfs -hfs-volume-name "${VOL_NAME}" -hfs-openfolder "${TMP_DIR}" "${TMP_DIR}" -o /tmp/dmg_hybrid.dmg -quiet
hdiutil convert -format UDZO /tmp/dmg_hybrid.dmg -o "${DMG_NAME}" -quiet
rm -f /tmp/dmg_hybrid.dmg

echo "[4] 임시 파일을 정리합니다..."
rm -rf "${TMP_DIR}"

if [ -f "${DMG_NAME}" ]; then
    echo ""
    echo "✅ 완벽 복구: ${DMG_NAME} 파일이 작업 폴더에 다시 생성되었습니다!"
    echo "➡️ (참고) Homebrew 배포 전 SHA256 해시: $(shasum -a 256 ${DMG_NAME})"
    echo ""
else
    echo "❌ DMG 생성에 실패했습니다."
fi
