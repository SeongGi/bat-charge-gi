cask "bat-charge-gi" do
  version "3.0.7"
  sha256 "2a4643f98db59cc4de47dee720573322cafd16a3fecd44edbb01cba4840a5386"

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
    # 타 PC 환경에서 상단 바 아이콘이 뜨지 않는 문제(애드혹 서명 깨짐)를 원천적으로 해결합니다.
    system_command "xattr", args: ["-cr", "#{appdir}/bat-charge-gi.app"], sudo: true
    system_command "codesign", args: ["--force", "--deep", "--sign", "-", "#{appdir}/bat-charge-gi.app"], sudo: true
  end

  caveats do
    "이 앱은 배터리 제어를 위해 루트 권한 백그라운드 헬퍼(SMAppService)를 사용합니다.\n" +
    "최초 실행 시 '백그라운드 제어 권한 허용' 버튼을 눌러 승인이 필요합니다."
  end
end
