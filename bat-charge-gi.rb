cask "bat-charge-gi" do
  version "2.8.1"
  sha256 "1b419d0d62fa1dcb16f35f911629d4ccc77dbf07f736283164fe6d3cc3561da8"

  url "https://github.com/SeongGi/bat-charge-gi/releases/download/v#{version}/bat-charge-gi.dmg"
  name "bat-charge-gi"
  desc "Advanced battery management and calibration tool for Apple Silicon"
  homepage "https://github.com/SeongGi/bat-charge-gi"

  app "bat-charge-gi.app"

  # Helper 데몬 삭제를 위한 uninstall 구문 (사용자 편의성 제공)
  uninstall launchctl: "com.seonggi.bat-charge-gi.helper",
            delete:    "/Library/PrivilegedHelperTools/com.seonggi.bat-charge-gi.helper"

  zap trash: [
    "~/Library/Preferences/com.seonggi.bat-charge-gi.plist",
    "~/Library/Application Support/bat-charge-gi"
  ]

  caveats do
    "이 앱은 배터리 제어를 위해 루트 권한 백그라운드 헬퍼(SMAppService)를 사용합니다. 최초 실행 시 '코어 업데이트'를 통한 권한 허용이 필요합니다."
  end
end
