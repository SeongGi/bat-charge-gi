import Foundation
import AppKit
import ServiceManagement
import os.log

class DaemonManager: ObservableObject {
    static let shared = DaemonManager()
    private let logger = Logger(subsystem: "com.seonggi.bat-charge-gi", category: "DaemonManager")
    
    let service = SMAppService.daemon(plistName: "com.seonggi.bat-charge-gi.helper.plist")
    
    /// 데몬 연결 상태 (3단계: registered / connecting / notInstalled)
    enum DaemonState {
        case registered       // 정상 연결됨
        case connecting       // plist는 존재하나 아직 XPC 응답 없음 (재부팅 직후)
        case notInstalled     // 설치 안됨 (초기 상태)
    }
    
    @Published var isDaemonRegistered: Bool = false
    @Published var daemonState: DaemonState = .notInstalled
    
    private var connection: NSXPCConnection?
    
    private var retryTimer: Timer?
    private var retryCount: Int = 0
    private let maxRetries: Int = 24  // 최대 24회 = 약 2분
    private let registerLock = NSLock()
    
    /// 재부팅 후에도 LaunchDaemon plist가 존재하는지 확인
    private var isDaemonPlistInstalled: Bool {
        let plistExists = FileManager.default.fileExists(atPath: "/Library/LaunchDaemons/com.seonggi.bat-charge-gi.helper.plist")
        let binExists = FileManager.default.fileExists(atPath: "/Library/PrivilegedHelperTools/com.seonggi.bat-charge-gi.helper")
        return plistExists && binExists
    }
    
    private init() {
        checkDaemonStatus()
    }
    
    func checkDaemonStatus() {
        // 1단계: SMAppService 공식 API 체크
        let currentStatus = service.status
        if currentStatus == .enabled {
            markAsRegistered()
            return
        }
        
        // 2단계: 파일 존재 여부 확인
        let installed = isDaemonPlistInstalled
        
        DispatchQueue.main.async {
            if installed {
                self.daemonState = .connecting
                self.logger.notice("Daemon installed but not enabled/responded. status: \(String(describing: currentStatus))")
            } else {
                self.daemonState = .notInstalled
            }
        }
        
        // 3단계: XPC Ping (Mach Port 직접 연결)
        // ⚠ 절대 .privileged 붙이지 말 것!
        let pingConnection = NSXPCConnection(machServiceName: "com.seonggi.bat-charge-gi.helper")
        pingConnection.remoteObjectInterface = NSXPCInterface(with: BatteryHelperProtocol.self)
        pingConnection.resume()
        
        if let proxy = pingConnection.remoteObjectProxyWithErrorHandler({ error in
            DispatchQueue.main.async {
                self.isDaemonRegistered = false
                if installed {
                    self.daemonState = .connecting
                    // 첫 로드 시 바로 타이머 시작하여 기동 대기
                    self.startRetryTimer()
                } else {
                    self.daemonState = .notInstalled
                }
            }
            pingConnection.invalidate()
        }) as? BatteryHelperProtocol {
            proxy.getChargeLimit { _, _ in
                self.markAsRegistered()
                pingConnection.invalidate()
            }
        }
    }
    
    /// 연결 성공 시 상태를 일괄 갱신
    private func markAsRegistered() {
        DispatchQueue.main.async {
            self.isDaemonRegistered = true
            self.daemonState = .registered
            self.stopRetryTimer()
            self.logger.notice("Daemon connection confirmed!")
        }
    }
    
    /// 재부팅 직후 데몬 지연 기동을 감지하기 위한 주기적 재시도 타이머
    private func startRetryTimer() {
        self.registerLock.lock()
        defer { self.registerLock.unlock() }
        
        // 이미 타이머가 돌고 있거나, 최대 재시도 횟수 초과 시 중단
        guard retryTimer == nil, retryCount < maxRetries else { return }
        
        retryTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            
            self.registerLock.lock()
            self.retryCount += 1
            let currentCount = self.retryCount
            self.registerLock.unlock()
            
            self.logger.notice("Retrying daemon detection... (\(currentCount)/\(self.maxRetries))")
            
            // 3회(약 15초) 실패 후, plist가 존재하면 launchctl로 데몬 강제 기동 시도 (암호 불필요)
            if currentCount == 3 && self.isDaemonPlistInstalled {
                self.logger.notice("Plist exists but daemon not responding. Attempting kickstart...")
                self.kickstartDaemon()
                // 킥스타트 후 즉시 재연결 시도
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.checkDaemonStatus()
                }
            }
            
            if currentCount >= self.maxRetries {
                self.stopRetryTimer()
                self.logger.warning("Max retries reached. Daemon failed to respond.")
                DispatchQueue.main.async {
                    self.daemonState = .notInstalled
                    self.isDaemonRegistered = false
                }
                return
            }
            
            // ⚠ 절대 .privileged 옵션 금지!
            let ping = NSXPCConnection(machServiceName: "com.seonggi.bat-charge-gi.helper")
            ping.remoteObjectInterface = NSXPCInterface(with: BatteryHelperProtocol.self)
            ping.resume()
            
            if let proxy = ping.remoteObjectProxyWithErrorHandler({ _ in
                ping.invalidate()
            }) as? BatteryHelperProtocol {
                proxy.getChargeLimit { _, _ in
                    self.markAsRegistered()
                    ping.invalidate()
                }
            }
        }
    }
    
    /// plist가 이미 /Library/LaunchDaemons에 있을 때, 암호 없이 데몬을 강제 기동
    private func kickstartDaemon() {
        DispatchQueue.global(qos: .userInitiated).async {
            self.logger.notice("Kickstarting helper daemon...")
            
            // 1. 데몬 바이너리 및 프레임워크 게이트키퍼 격리 해제 (어드민 비밀번호 없이도 가능한 범위)
            let helperPath = "/Library/PrivilegedHelperTools/com.seonggi.bat-charge-gi.helper"
            let fixXattr = Process()
            fixXattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            fixXattr.arguments = ["-cr", helperPath]
            try? fixXattr.run()
            fixXattr.waitUntilExit()

            // 2. launchctl bootout -> bootstrap 을 통해 서비스 완전 재기동
            let plistPath = "/Library/LaunchDaemons/com.seonggi.bat-charge-gi.helper.plist"
            
            let bootout = Process()
            bootout.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            bootout.arguments = ["bootout", "system", plistPath]
            try? bootout.run()
            bootout.waitUntilExit()
            
            let bootstrap = Process()
            bootstrap.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            bootstrap.arguments = ["bootstrap", "system", plistPath]
            try? bootstrap.run()
            bootstrap.waitUntilExit()
            
            self.logger.notice("Kickstart process completed.")
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
            let privilegedPath = "/Library/PrivilegedHelperTools/com.seonggi.bat-charge-gi.helper"
            let privilegedSmcPath = "/Library/PrivilegedHelperTools/smc"
            
            let helperPath = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/com.seonggi.bat-charge-gi.helper").path
            let smcPath = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/smc").path
            
            let plistContent = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key>
                <string>com.seonggi.bat-charge-gi.helper</string>
                <key>ProgramArguments</key>
                <array>
                    <string>\(privilegedPath)</string>
                </array>
                <key>MachServices</key>
                <dict>
                    <key>com.seonggi.bat-charge-gi.helper</key>
                    <true/>
                </dict>
                <key>RunAtLoad</key>
                <true/>
                <key>KeepAlive</key>
                <true/>
                <key>StandardOutPath</key>
                <string>/tmp/com.seonggi.bat-charge-gi.helper.out.log</string>
                <key>StandardErrorPath</key>
                <string>/tmp/com.seonggi.bat-charge-gi.helper.err.log</string>
            </dict>
            </plist>
            """
            
            let tmpPlistPath = "/tmp/com.seonggi.bat-charge-gi.helper.plist"
            try? plistContent.write(toFile: tmpPlistPath, atomically: true, encoding: .utf8)
            
            let script = "do shell script \"" +
                "launchctl bootout system/com.seonggi.bat-charge-gi.helper 2>/dev/null; " +
                "mkdir -p /Library/PrivilegedHelperTools/ && " +
                "cp \\\"\(helperPath)\\\" \\\"\(privilegedPath)\\\" && " +
                "cp \\\"\(smcPath)\\\" \\\"\(privilegedSmcPath)\\\" && " +
                "xattr -cr \\\"\(privilegedPath)\\\" \\\"\(privilegedSmcPath)\\\" && " +
                "chown root:wheel \\\"\(privilegedPath)\\\" \\\"\(privilegedSmcPath)\\\" && " +
                "chmod 755 \\\"\(privilegedPath)\\\" \\\"\(privilegedSmcPath)\\\" && " +
                "cp \\\"\(tmpPlistPath)\\\" /Library/LaunchDaemons/ && " +
                "xattr -cr /Library/LaunchDaemons/com.seonggi.bat-charge-gi.helper.plist && " +
                "chown root:wheel /Library/LaunchDaemons/com.seonggi.bat-charge-gi.helper.plist && " +
                "chmod 644 /Library/LaunchDaemons/com.seonggi.bat-charge-gi.helper.plist && " +
                "launchctl bootstrap system /Library/LaunchDaemons/com.seonggi.bat-charge-gi.helper.plist" +
                "\" with administrator privileges"
            var scriptError: NSDictionary?
            if let appleScript = NSAppleScript(source: script) {
                appleScript.executeAndReturnError(&scriptError)
                if let err = scriptError {
                    print("AppleScript Fallback Error: \(err)")
                    DispatchQueue.main.async {
                        let alert = NSAlert()
                        alert.messageText = "백그라운드 제어 권한 획득 실패"
                        alert.informativeText = "원인: \(err)\n설정을 확인해주세요."
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
            // ⚠ 핵심: launchctl bootout (현대식) 사용
            let script = "do shell script \"launchctl bootout system/com.seonggi.bat-charge-gi.helper 2>/dev/null; rm -f /Library/LaunchDaemons/com.seonggi.bat-charge-gi.helper.plist; rm -f /Library/PrivilegedHelperTools/com.seonggi.bat-charge-gi.helper\" with administrator privileges"
            var scriptError: NSDictionary?
            if let appleScript = NSAppleScript(source: script) {
                appleScript.executeAndReturnError(&scriptError)
            }
        }
        DispatchQueue.main.async {
            self.isDaemonRegistered = false
            self.daemonState = .notInstalled
        }
    }
    
    func helperConnection() -> NSXPCConnection? {
        if let connection = connection {
            return connection
        }
        
        // ⚠ 절대 .privileged 옵션 금지! (재부팅 팝업 원흉)
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
