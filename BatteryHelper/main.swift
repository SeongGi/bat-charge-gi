import Foundation

let delegate = BatteryHelperDelegate()
let listener = NSXPCListener(machServiceName: "com.seonggi.bat-charge-gi.helper")
listener.delegate = delegate
listener.resume()

// 데몬 메인 런루프 실행 (종료되지 않도록 대기)
RunLoop.main.run()
