cask "bat-charge-gi" do
  version "3.0.5"
  sha256 "2a4a541a38f07b6f93e15c5b25b32fd1b8adc48d2a4a697c1a89471827a6d611"

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
