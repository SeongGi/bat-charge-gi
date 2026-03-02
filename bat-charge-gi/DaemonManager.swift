import Foundation
import AppKit
import ServiceManagement
import os.log

class DaemonManager: ObservableObject {
    static let shared = DaemonManager()
    private let logger = Logger(subsystem: "com.seonggi.bat-charge-gi", category: "DaemonManager")
    
    let service = SMAppService.daemon(plistName: "com.seonggi.bat-charge-gi.helper.plist")
    
    @Published var isDaemonRegistered: Bool = false
    
    private var connection: NSXPCConnection?
    private var hasAttemptedAutoRegister: Bool = false
    private let registerLock = NSLock()
    
    private init() {
        checkDaemonStatus()
    }
    
    func checkDaemonStatus() {
        if service.status == .enabled {
            DispatchQueue.main.async { self.isDaemonRegistered = true }
            return
        }
        
        // Fallback: Ping via XPC
        let pingConnection = NSXPCConnection(machServiceName: "com.seonggi.bat-charge-gi.helper")
        pingConnection.remoteObjectInterface = NSXPCInterface(with: BatteryHelperProtocol.self)
        pingConnection.resume()
        
        if let proxy = pingConnection.remoteObjectProxyWithErrorHandler({ _ in
            DispatchQueue.main.async { 
                self.isDaemonRegistered = false
                self.logger.warning("XPC Ping failed. Daemon may not be running yet.")
                // 재부팅 시 딜레이로 인해 무한 팝업이 뜨는 고질적 버그를 원천 제거하기 위해
                // 자동 AppleScript 권한 요구(registerDaemon) 로직을 전면 삭제했습니다.
                // 연결이 실패하면 단순히 UI에서 "활성화 안됨"으로 빨간 불만 띄워주고,
                // 사용자가 권한 버튼을 직접 누를 때만 registerDaemon()을 수동 발동시킵니다.
            }
            pingConnection.invalidate()
        }) as? BatteryHelperProtocol {
            proxy.getChargeLimit { _, _ in
                DispatchQueue.main.async { self.isDaemonRegistered = true }
                pingConnection.invalidate()
            }
        }
    }
    
    func registerDaemon() {
        do {
            try service.register()
            logger.notice("Daemon successfully registered via SMAppService.")
            checkDaemonStatus()
        } catch {
            logger.error("SMAppService failed: \(error.localizedDescription). Trying Fallback...")
            
            // Xcode 서명이 완벽하지 않아 SMAppService가 실패할 경우 launchctl로 강제 등록
            let helperPath = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/com.seonggi.bat-charge-gi.helper").path
            let plistContent = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key>
                <string>com.seonggi.bat-charge-gi.helper</string>
                <key>ProgramArguments</key>
                <array>
                    <string>\(helperPath)</string>
                </array>
                <key>MachServices</key>
                <dict>
                    <key>com.seonggi.bat-charge-gi.helper</key>
                    <true/>
                </dict>
                <key>RunAtLoad</key>
                <true/>
            </dict>
            </plist>
            """
            
            let tmpPlistPath = "/tmp/com.seonggi.bat-charge-gi.helper.plist"
            try? plistContent.write(toFile: tmpPlistPath, atomically: true, encoding: .utf8)
            
            let script = "do shell script \"cp \\\"\(tmpPlistPath)\\\" /Library/LaunchDaemons/ && chown root:wheel /Library/LaunchDaemons/com.seonggi.bat-charge-gi.helper.plist && launchctl load -w /Library/LaunchDaemons/com.seonggi.bat-charge-gi.helper.plist\" with administrator privileges"
            var scriptError: NSDictionary?
            if let appleScript = NSAppleScript(source: script) {
                appleScript.executeAndReturnError(&scriptError)
                if let err = scriptError {
                    print("AppleScript Fallback Error: \(err)")
                    DispatchQueue.main.async {
                        let alert = NSAlert()
                        alert.messageText = "백그라운드 제어 권한 획득 실패"
                        alert.informativeText = "원인: \(err)\\n설정을 확인해주세요."
                        alert.alertStyle = .critical
                        alert.addButton(withTitle: "확인")
                        alert.runModal()
                    }
                }
            }
            // re-check via ping
            checkDaemonStatus()
        }
    }
    
    func unregisterDaemon() {
        do {
            try service.unregister()
            logger.notice("Daemon successfully unregistered.")
        } catch {
            let script = "do shell script \"launchctl unload -w /Library/LaunchDaemons/com.seonggi.bat-charge-gi.helper.plist && rm /Library/LaunchDaemons/com.seonggi.bat-charge-gi.helper.plist\" with administrator privileges"
            var scriptError: NSDictionary?
            if let appleScript = NSAppleScript(source: script) {
                appleScript.executeAndReturnError(&scriptError)
            }
        }
        DispatchQueue.main.async { self.isDaemonRegistered = false }
    }
    
    func helperConnection() -> NSXPCConnection? {
        if let connection = connection {
            return connection
        }
        
        // ping 확인 후 실제 커넥션 생성
        let newConnection = NSXPCConnection(machServiceName: "com.seonggi.bat-charge-gi.helper")
        newConnection.remoteObjectInterface = NSXPCInterface(with: BatteryHelperProtocol.self)
        
        newConnection.interruptionHandler = { [weak self] in
            self?.logger.warning("XPC connection interrupted.")
            self?.connection = nil
        }
        
        newConnection.invalidationHandler = { [weak self] in
            self?.logger.warning("XPC connection invalidated.")
            self?.connection = nil
        }
        
        newConnection.resume()
        self.connection = newConnection
        return newConnection
    }
}
