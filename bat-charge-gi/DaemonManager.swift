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
    
    /// 재부팅 후에도 LaunchDaemon plist가 존재하는지 확인
    private var isDaemonPlistInstalled: Bool {
        FileManager.default.fileExists(atPath: "/Library/LaunchDaemons/com.seonggi.bat-charge-gi.helper.plist")
    }
    
    private init() {
        checkDaemonStatus()
    }
    
    func checkDaemonStatus() {
        // 1단계: SMAppService 공식 API 체크
        if service.status == .enabled {
            markAsRegistered()
            return
        }
        
        // 2단계: plist가 있으면 "설치됨이지만 아직 기동 대기 중" 상태로 표시
        if isDaemonPlistInstalled {
            DispatchQueue.main.async {
                self.daemonState = .connecting
            }
        }
        
        // 3단계: XPC 직접 Ping (launchctl로 수동 등록된 데몬 감지)
        // ⚠⚠⚠ 절대 .privileged 옵션을 붙이지 말 것! ⚠⚠⚠
        // .privileged는 구형 SMJobBless 전용이며, 이걸 붙이면 macOS가
        // "구형 헬퍼 설치가 필요하다"고 오인하여 시스템 자체적으로 강제 암호 팝업을 무한 생성함.
        let pingConnection = NSXPCConnection(machServiceName: "com.seonggi.bat-charge-gi.helper")
        pingConnection.remoteObjectInterface = NSXPCInterface(with: BatteryHelperProtocol.self)
        pingConnection.resume()
        
        if let proxy = pingConnection.remoteObjectProxyWithErrorHandler({ _ in
            DispatchQueue.main.async {
                // plist가 있으면 "연결 중..." 상태 유지, 없으면 "미설치"
                if self.isDaemonPlistInstalled {
                    self.daemonState = .connecting
                    self.isDaemonRegistered = false
                } else {
                    self.daemonState = .notInstalled
                    self.isDaemonRegistered = false
                }
                self.logger.warning("XPC Ping failed. Daemon may not be running yet. (retry \(self.retryCount)/\(self.maxRetries))")
                // 재부팅 직후 데몬이 앱보다 늦게 뜨는 경우를 대비하여 자동 재시도
                self.startRetryTimer()
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
        // 이미 타이머가 돌고 있거나, 최대 재시도 횟수 초과 시 중단
        guard retryTimer == nil, retryCount < maxRetries else { return }
        
        retryTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            self.retryCount += 1
            self.logger.notice("Retrying daemon detection... (\(self.retryCount)/\(self.maxRetries))")
            
            // 6회(30초) 실패 후, plist가 존재하면 launchctl로 데몬 강제 기동 시도 (암호 불필요)
            if self.retryCount == 6 && self.isDaemonPlistInstalled {
                self.logger.notice("Plist exists but daemon not responding. Attempting launchctl kickstart...")
                self.kickstartDaemon()
            }
            
            if self.retryCount >= self.maxRetries {
                self.stopRetryTimer()
                self.logger.warning("Max retries reached. Daemon may not be installed.")
                if !self.isDaemonPlistInstalled {
                    DispatchQueue.main.async {
                        self.daemonState = .notInstalled
                    }
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
            // launchctl kickstart는 이미 bootstrap된 서비스를 강제 기동 (암호 불필요)
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            task.arguments = ["kickstart", "-k", "system/com.seonggi.bat-charge-gi.helper"]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = pipe
            do {
                try task.run()
                task.waitUntilExit()
                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                self.logger.notice("kickstart result: \(output)")
            } catch {
                self.logger.error("kickstart failed: \(error.localizedDescription)")
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
            let privilegedPath = "/Library/PrivilegedHelperTools/com.seonggi.bat-charge-gi.helper"
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
            </dict>
            </plist>
            """
            
            let tmpPlistPath = "/tmp/com.seonggi.bat-charge-gi.helper.plist"
            try? plistContent.write(toFile: tmpPlistPath, atomically: true, encoding: .utf8)
            
            // ⚠ 보안 정책: launchd는 daemon 실행 파일이 root 소유이고 권한이 755여야만 부팅 시 실행을 허용합니다.
            let script = "do shell script \"" +
                "launchctl bootout system/com.seonggi.bat-charge-gi.helper 2>/dev/null; " +
                "mkdir -p /Library/PrivilegedHelperTools/ && " +
                "cp \\\"\(helperPath)\\\" \\\"\(privilegedPath)\\\" && " +
                "chown root:wheel \\\"\(privilegedPath)\\\" && " +
                "chmod 755 \\\"\(privilegedPath)\\\" && " +
                "cp \\\"\(tmpPlistPath)\\\" /Library/LaunchDaemons/ && " +
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
