cask "bat-charge-gi" do
  version "2.8.7"
  sha256 :no_check

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

  postflight do
    # 1. 모든 찌꺼기 속성 및 인터넷 격리(Quarantine) 속성 완전 제거
    system_command "xattr",
                   args: ["-cr", "#{appdir}/bat-charge-gi.app"],
                   sudo: false
    
    # 2. 로컬 권한으로 앱 재서명 (Gatekeeper '손상된 앱' 에러 방지용)
    system_command "codesign",
                   args: ["--force", "--deep", "--sign", "-", "#{appdir}/bat-charge-gi.app"],
                   sudo: false
  end

  caveats do
    "이 앱은 배터리 제어를 위해 루트 권한 백그라운드 헬퍼(SMAppService)를 사용합니다.\n" +
    "최초 실행 시 '백그라운드 제어 권한 허용' 버튼을 눌러 승인이 필요합니다.\n" +
    "Gatekeeper 차단을 자동으로 해제하도록 설정되었습니다."
  end
end
