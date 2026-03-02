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
        let pingConnection = NSXPCConnection(machServiceName: "com.seonggi.bat-charge-gi.helper", options: .privileged)
        pingConnection.remoteObjectInterface = NSXPCInterface(with: BatteryHelperProtocol.self)
        pingConnection.resume()
        
        if let proxy = pingConnection.remoteObjectProxyWithErrorHandler({ _ in
            DispatchQueue.main.async { 
                self.isDaemonRegistered = false
                
                // 완벽한 1회성 실행을 보장하기 위한 락 스코프
                self.registerLock.lock()
                
                let plistPath = "/Library/LaunchDaemons/com.seonggi.bat-charge-gi.helper.plist"
                let plistExists = FileManager.default.fileExists(atPath: plistPath)
                
                // plist가 이미 존재하면(설치 이력 있음) 재부팅 직후 지연 현상이므로 강제 팝업 금지
                let shouldRegister = !self.hasAttemptedAutoRegister && !plistExists
                
                if !self.hasAttemptedAutoRegister {
                    self.hasAttemptedAutoRegister = true
                }
                self.registerLock.unlock()
                
                // 통신 실패 시 즉각 백그라운드 재설치 로직(Applescript 팝업) 자동 점화 
                // (단, 앱 최초 설치 시점에만 동작하도록 플래그 + Plist 존재여부 교차 검증)
                if shouldRegister {
                    self.logger.notice("Attempting auto-register (First time only, Plist not found)")
                    self.registerDaemon()
                } else {
                    self.logger.notice("Auto-register blocked (Already attempted or Plist already exists)")
                }
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
        let newConnection = NSXPCConnection(machServiceName: "com.seonggi.bat-charge-gi.helper", options: .privileged)
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
