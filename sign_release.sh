#!/bin/bash
# 차기 버전 릴리즈 시 사용할 Sparkle 자동 서명(Signature) 스크립트
# 사용법: 앱 코드를 수정하고 ./build.sh 로 빌드한 뒤, zip -r bat-charge-gi.zip bat-charge-gi.app 으로 압축하고 이 스크립트를 실행하세요.

export PRIVATE_KEY="npsrXuHJQ78Ban4rBCX9pWE+l66IFkQ3YUwiMcrGspI="

echo "[1] bat-charge-gi.zip 파일에 대한 EdDSA 서명을 발급합니다..."
echo "$PRIVATE_KEY" | Sparkle_Framework/bin/sign_update --ed-key-file - bat-charge-gi.zip

echo ""
echo "✅ 위에 출력된 'sparkle:edSignature' 값과 'length' 값을 복사해서 appcast.xml의 <enclosure> 태그를 교체해주시면 업데이트가 완성됩니다!"
