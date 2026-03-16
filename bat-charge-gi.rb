cask "bat-charge-gi" do
  version "3.0.2"
  sha256 "bfdbd9897f9cce2f36727050b1d9e86b0726fa29df9860d0c6405ad89094f502"

  url "https://github.com/SeongGi/bat-charge-gi/releases/download/v#{version}/bat-charge-gi.dmg"
  name "bat-charge-gi"
  desc "Advanced battery management and calibration tool for Apple Silicon"
  homepage "https://github.com/SeongGi/bat-charge-gi"

  app "bat-charge-gi.app"

  uninstall launchctl: "com.seonggi.bat-charge-gi.helper",
            delete:    "/Library/PrivilegedHelperTools/com.seonggi.bat-charge-gi.helper"

  zap trash: [
    "~/Library/Preferences/com.seonggi.bat-charge-gi.plist",
    "~/Library/Application Support/bat-charge-gi"
  ]

  postflight do
    # 앱 번들을 망가뜨리지 않고 게이트키퍼만 안전하게 해제합니다.
    system_command "xattr",
                   args: ["-cr", "#{appdir}/bat-charge-gi.app"],
                   sudo: false
  end

  caveats do
    "이 앱은 배터리 제어를 위해 루트 권한 백그라운드 헬퍼(SMAppService)를 사용합니다.\n" +
    "최초 실행 시 '백그라운드 제어 권한 허용' 버튼을 눌러 승인이 필요합니다."
  end
end
