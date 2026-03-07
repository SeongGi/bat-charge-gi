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
    
    private var retryTimer: Timer?
    private var retryCount: Int = 0
    private let maxRetries: Int = 12  // 최대 12회 (약 1분)
    
    private init() {
        checkDaemonStatus()
    }
    
    func checkDaemonStatus() {
        // 1단계: SMAppService 공식 API 체크
        if service.status == .enabled {
            DispatchQueue.main.async {
                self.isDaemonRegistered = true
                self.stopRetryTimer()
            }
            return
        }
        
        // 2단계: XPC 직접 Ping (launchctl로 수동 등록된 데몬 감지)
        let pingConnection = NSXPCConnection(machServiceName: "com.seonggi.bat-charge-gi.helper", options: .privileged)
        pingConnection.remoteObjectInterface = NSXPCInterface(with: BatteryHelperProtocol.self)
        pingConnection.resume()
        
        if let proxy = pingConnection.remoteObjectProxyWithErrorHandler({ _ in
            DispatchQueue.main.async {
                self.isDaemonRegistered = false
                self.logger.warning("XPC Ping failed. Daemon may not be running yet. (retry \(self.retryCount)/\(self.maxRetries))")
                // 재부팅 직후 데몬이 앱보다 늦게 뜨는 경우를 대비하여 자동 재시도
                self.startRetryTimer()
            }
            pingConnection.invalidate()
        }) as? BatteryHelperProtocol {
            proxy.getChargeLimit { _, _ in
                DispatchQueue.main.async {
                    self.isDaemonRegistered = true
                    self.stopRetryTimer()
                    self.logger.notice("Daemon connection confirmed via XPC ping!")
                }
                pingConnection.invalidate()
            }
        }
    }
    
    /// 재부팅 직후 데몬 지연 기동을 감지하기 위한 주기적 재시도 타이머
    private func startRetryTimer() {
        // 이미 타이머가 돌고 있거나, 최대 재시도 횟수 초과 시 중단
        guard retryTimer == nil, retryCount < maxRetries else { return }
        
        retryTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            self.retryCount += 1
            self.logger.notice("Retrying daemon detection... (\(self.retryCount)/\(self.maxRetries))")
            
            if self.retryCount >= self.maxRetries {
                self.stopRetryTimer()
                self.logger.warning("Max retries reached. Daemon may not be installed.")
                return
            }
            
            // 타이머 콜백에서는 새 ping만 시도 (타이머는 유지)
            let ping = NSXPCConnection(machServiceName: "com.seonggi.bat-charge-gi.helper", options: .privileged)
            ping.remoteObjectInterface = NSXPCInterface(with: BatteryHelperProtocol.self)
            ping.resume()
            
            if let proxy = ping.remoteObjectProxyWithErrorHandler({ _ in
                ping.invalidate()
            }) as? BatteryHelperProtocol {
                proxy.getChargeLimit { _, _ in
                    DispatchQueue.main.async {
                        self.isDaemonRegistered = true
                        self.stopRetryTimer()
                        self.logger.notice("Daemon detected on retry \(self.retryCount)!")
                    }
                    ping.invalidate()
                }
            }
        }
    }
    
    private func stopRetryTimer() {
        retryTimer?.invalidate()
        retryTimer = nil
        retryCount = 0
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
