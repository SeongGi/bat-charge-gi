import SwiftUI
import Sparkle
import ServiceManagement

@main
struct bat_charge_giApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        // 1. Settings 씬이 메인이 되면 시작 시 아무 창도 뜨지 않습니다.
        // Settings 씬을 메인으로 두어 부팅 시 빈 창이 뜨는 것 방지
        Settings {
            EmptyView()
        }
        
        // 대시보드 창은 메인 Scene 목록에서 제외하거나 필요할 때만 호출되도록 관리
        // WindowGroup 대신 개별 Window로 정의 (SwiftUI 4.0+)
        Window("고급 배터리 통계", id: "dashboard") {
            DashboardView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var popover = NSPopover()
    var timer: Timer?
    var updaterController: SPUStandardUpdaterController!
    
    // App Nap 방지용 활동 토큰
    var activity: NSObjectProtocol?
    
    func applicationWillFinishLaunching(_ notification: Notification) {
        // ── 1. 중복 실행 원천 차단 (Early Exit) ──
        // 초기 부팅 시 여러 기작(LaunchAgent + LoginItem 등)으로 중복 실행되는 것을 방지합니다.
        let bundleID = Bundle.main.bundleIdentifier ?? "com.seonggi.bat-charge-gi"
        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        let currentPID = ProcessInfo.processInfo.processIdentifier
        
        // 나를 제외한 다른 인스턴스가 있는지 확인
        let otherApps = runningApps.filter { $0.processIdentifier != currentPID }
        
        if !otherApps.isEmpty {
            let otherPIDs = otherApps.map { String($0.processIdentifier) }.joined(separator: ", ")
            print("Singleton: Another instance is already running (PIDs: \(otherPIDs)). Exiting this instance (PID: \(currentPID)).")
            exit(0)
        }
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // ── 재부팅 후 아이콘 소멸 방지 핵심 조치 1: 앱 자체 격리 속성 제거 ──
        // 타 PC에서 Homebrew로 설치 후 재부팅 시, macOS가 quarantine 속성을 재부착하여
        // 앱 실행 자체를 차단하거나 NSStatusBar 등록을 방해합니다.
        DispatchQueue.global(qos: .background).async {
            let appPath = Bundle.main.bundleURL.path
            let xattrTask = Process()
            xattrTask.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            xattrTask.arguments = ["-cr", appPath]
            try? xattrTask.run()
            xattrTask.waitUntilExit()
        }

        // App Nap 방지: 메뉴바 아이콘이 절전 모드에 빠져 멈추는 것 방지 (중요)
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .background, .latencyCritical],
            reason: "Keeping menu bar icon active"
        )
        
        // 1. 메뉴바 아이콘 즉시 생성
        setupStatusItem()
        
        // 2. 팝업 뷰 초기화 (기존 프로퍼티 방식 복구)
        var contentView = ContentView()
        contentView.onUpdateCheck = { [weak self] in
            self?.updaterController.checkForUpdates(nil)
        }
        popover.contentViewController = NSHostingController(rootView: contentView)
        popover.behavior = .transient
        
        // 3. 업데이트 컨트롤러 초기화
        updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        
        // 4. 아이콘 주기적 업데이트 (10초)
        //    ── 핵심 조치 2: 상태 갱신마다 statusItem이 살아있는지 확인/복구 ──
        timer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            // statusItem이 어떤 이유로 nil이 된 경우 자동 복구
            if self.statusItem == nil || self.statusItem?.button == nil {
                print("⚠️ StatusItem lost, recreating...")
                self.setupStatusItem()
            }
            self.updateBatteryIcon()
        }
        updateBatteryIcon()
        
        // 5. 데몬 상태 확인
        DaemonManager.shared.checkDaemonStatus()
        
        // 6. 시작 시 불필요하게 뜬 모든 창 닫기 (메뉴바 앱 전용 강력 조치)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApplication.shared.windows.forEach { window in
                let className = window.className
                if className != "NSStatusBarWindow" && className != "NSPanel" && !className.contains("NSPopover") {
                    print("Startup Cleanup: Closing unexpected window: \(window.title) (\(className))")
                    window.setIsVisible(false)
                    window.close()
                }
            }
        }
    }

    /// 메뉴바 아이콘(statusItem)을 생성하거나 복구합니다.
    /// 재부팅 후 아이콘이 소멸하는 경우를 대비해 별도 메서드로 분리하였습니다.
    func setupStatusItem() {
        // 이미 정상 상태면 재생성하지 않음
        if let item = statusItem, item.button != nil {
            item.isVisible = true
            return
        }

        // 새로 생성
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        guard let button = statusItem?.button else {
            print("❌ Failed to create statusItem button")
            return
        }

        button.isEnabled = true
        // isVisible 명시적으로 true (macOS가 숨겨버릴 수 있음)
        statusItem?.isVisible = true

        let img = NSImage(systemSymbolName: "battery.100.bolt", accessibilityDescription: "Battery Manager")
        img?.isTemplate = true
        button.image = img
        button.title = "--"
        button.target = self
        button.action = #selector(togglePopover(_:))
        print("✅ StatusItem setup complete")
    }

    @objc func updateBatteryIcon() {
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            task.arguments = ["-g", "batt"]
            let pipe = Pipe()
            task.standardOutput = pipe
            
            do {
                try task.run()
                task.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: data, encoding: .utf8)?.lowercased() {
                    var percentage = 100
                    if let regex = try? NSRegularExpression(pattern: "(\\d+)%"),
                       let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
                       let range = Range(match.range(at: 1), in: output),
                       let val = Int(output[range]) {
                        percentage = val
                    }
                    
                    let isCharging = output.contains("charging") && !output.contains("not charging") && !output.contains("discharging")
                    let isOnAC = output.contains("ac power")
                    
                    let level: String
                    if percentage <= 12 { level = "0" }
                    else if percentage <= 37 { level = "25" }
                    else if percentage <= 62 { level = "50" }
                    else if percentage <= 87 { level = "75" }
                    else { level = "100" }
                    
                    DispatchQueue.main.async {
                        guard let button = self.statusItem?.button else { return }
                        
                        // 항상 아이콘이 흐려지지 않도록 명시적으로 활성화
                        button.isEnabled = true
                        
                        let iconName: String
                        if isCharging { iconName = "bolt.fill" }
                        else if isOnAC { iconName = "powerplug.fill" }
                        else { iconName = "battery.\(level)" }
                        
                        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
                        let icon = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)?
                            .withSymbolConfiguration(config)
                        icon?.isTemplate = true
                        
                        button.image = icon
                        button.title = "\(percentage)%"
                    }
                }
            } catch {
                print("Update failed: \(error)")
            }
        }
    }
    
    @objc func togglePopover(_ sender: AnyObject?) {
        if let button = statusItem?.button {
            if popover.isShown {
                popover.performClose(sender)
            } else {
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: NSRectEdge.minY)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}
