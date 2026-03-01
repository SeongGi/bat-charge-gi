#!/bin/bash
# bat-charge-gi 설치 스크립트 (daemon 포함 전체 교체)
set -e

echo "🔧 bat-charge-gi 설치를 시작합니다..."

# 1. 기존 앱/daemon 종료
echo "[1/5] 기존 프로세스 종료..."
killall "bat-charge-gi" 2>/dev/null || true
sleep 1

# 2. daemon 언로드
echo "[2/5] 기존 daemon 언로드..."
osascript -e 'do shell script "launchctl bootout system/com.seonggi.bat-charge-gi.helper 2>/dev/null; rm -rf /Applications/bat-charge-gi.app" with administrator privileges'
sleep 1

# 3. 앱 복사
echo "[3/5] 새 앱을 /Applications/에 설치..."
osascript -e "do shell script \"cp -R '$(pwd)/bat-charge-gi.app' /Applications/\" with administrator privileges"

# 4. daemon 재등록
echo "[4/5] daemon 재등록..."
osascript -e "do shell script \"cp /tmp/com.seonggi.bat-charge-gi.helper.plist /Library/LaunchDaemons/ 2>/dev/null; launchctl bootstrap system /Library/LaunchDaemons/com.seonggi.bat-charge-gi.helper.plist 2>/dev/null\" with administrator privileges" 2>/dev/null || true
sleep 2

# 5. 앱 실행
echo "[5/5] 앱 실행..."
open /Applications/bat-charge-gi.app

echo ""
echo "✅ 설치 완료! 새 daemon이 루트 권한으로 실행 중입니다."
echo "=== 검증 ==="
pgrep -fl "bat-charge" 2>/dev/null || echo "(프로세스 확인 불가)"
/Applications/bat-charge-gi.app/Contents/MacOS/smc -k CHTE -r
/Applications/bat-charge-gi.app/Contents/MacOS/smc -k CHIE -r
