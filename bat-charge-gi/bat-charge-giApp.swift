import SwiftUI
import Sparkle

@main
struct bat_charge_giApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        // 첫 번째 Scene으로 Settings를 주입하여 윈도우 기본 팝업 억제 시도
        Settings { 
            EmptyView() 
        }
        
        // Window 씬이 아예 없으면 SwiftUI App의 Event Loop가 메뉴바 렌더링을 드랍하는 현상이 발생하므로 다시 부활시킵니다.
        // 창이 자동으로 복원되는 고질병은 AppDelegate 단의 강제 종료 트릭으로 방어합니다.
        Window("고급 배터리 통계", id: "dashboard") {
            DashboardView()
        }
        .defaultSize(width: 600, height: 400)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var popover = NSPopover()
    var timer: Timer?
    var updaterController: SPUStandardUpdaterController!
    
    var dashboardWindow: NSWindow?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // ── 중복 실행 방지 ──
        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
        if runningApps.count > 1 {
            // 이미 다른 인스턴스가 실행 중 → 이 인스턴스 종료
            NSApp.terminate(nil)
            return
        }
        
        // 자동 업데이트 컨트롤러 초기화
        updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        
        // macOS 윈도우 상태 자동 복원 속성을 강제로 끔
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        
        let contentView = ContentView()
        popover.contentViewController = NSHostingController(rootView: contentView)
        popover.behavior = .transient
        
        // 메뉴바 아이콘(배터리 기호)은 직사각형이므로 반드시 variableLength 여야 렌더링 영역이 잘리지 않음
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        // 메인 앱 실행 직후, "고급 통계" 등 의도치 않은 윈도우만 선별적으로 닫기.
        // ⚠️ NSApplication.shared.windows 에는 NSStatusBarWindow(메뉴바 아이콘 호스팅 윈도우)도 포함되므로,
        // statusItem의 윈도우는 절대 건드리면 안 됩니다. (건드리면 아이콘 클릭 이벤트가 소멸합니다)
        DispatchQueue.main.async { [weak self] in
            let statusBarWindow = self?.statusItem?.button?.window
            for window in NSApplication.shared.windows {
                if window != statusBarWindow {
                    window.close()
                }
            }
        }
        
        if let button = statusItem?.button {
            let img = NSImage(systemSymbolName: "battery.100.bolt", accessibilityDescription: "Battery Manager") 
                   ?? NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "Battery Manager")
            img?.isTemplate = true
            button.image = img
            button.target = self
            button.action = #selector(togglePopover(_:))
        }
        
        // 아이콘 주기적 업데이트 (10초간격)
        timer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            self?.updateBatteryIcon()
        }
        updateBatteryIcon()
        
        // 데몬 상태 확인
        DaemonManager.shared.checkDaemonStatus()
    }
    
    @objc func updateBatteryIcon() {
        DispatchQueue.global(qos: .background).async {
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
                    
                    let isDischarging = output.contains("discharging")
                    let isCharging = output.contains("charging") && !output.contains("not charging") && !output.contains("discharging") && !output.contains("finishing charge")
                    let isOnAC = output.contains("ac power")
                    
                    // 배터리 잔량 레벨 아이콘
                    let level: String
                    if percentage <= 12 { level = "0" }
                    else if percentage <= 37 { level = "25" }
                    else if percentage <= 62 { level = "50" }
                    else if percentage <= 87 { level = "75" }
                    else { level = "100" }
                    
                    DispatchQueue.main.async {
                        guard let button = self.statusItem?.button else { return }
                        
                        // 상태별 아이콘 결정
                        let iconName: String
                        if isDischarging {
                            // 배터리 사용 중: 배터리 아이콘
                            iconName = "battery.\(level)"
                        } else if isCharging {
                            // 충전 중: 번개 아이콘
                            iconName = "bolt.fill"
                        } else if isOnAC {
                            // 전원만 연결 (충전 안 함): 플러그 아이콘
                            iconName = "powerplug.fill"
                        } else {
                            iconName = "battery.\(level)"
                        }
                        
                        // 아이콘 + 퍼센트 텍스트 조합
                        let icon = NSImage(systemSymbolName: iconName, accessibilityDescription: "Battery Status")
                            ?? NSImage(systemSymbolName: "battery.\(level)", accessibilityDescription: "Fallback")
                        icon?.isTemplate = true
                        
                        // 아이콘 크기 조절 (메뉴바 적합)
                        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
                        let finalIcon = icon?.withSymbolConfiguration(config) ?? icon
                        
                        button.image = finalIcon
                        button.imagePosition = .imageLeading
                        
                        // 퍼센트 텍스트 표시
                        let attrStr = NSAttributedString(
                            string: " \(percentage)%",
                            attributes: [
                                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                                .baselineOffset: 0.5
                            ]
                        )
                        button.attributedTitle = attrStr
                    }
                }
            } catch {
                print("Failed to get battery status: \(error)")
            }
        }
    }
    
    @objc func togglePopover(_ sender: AnyObject?) {
        if let button = statusItem?.button {
            if popover.isShown {
                popover.performClose(sender)
            } else {
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: NSRectEdge.minY)
                // 팝업 시 활성화 유지
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
    
    // macOS 재부팅 시 의문의 윈도우가 복원되는 것을 방지 (statusBarWindow는 절대 건드리지 않음)
    func applicationWillTerminate(_ notification: Notification) {
        let statusBarWindow = statusItem?.button?.window
        for window in NSApplication.shared.windows {
            if window != statusBarWindow {
                window.close()
            }
        }
    }
    
    // 유일한 윈도우가 닫혀도 메뉴바 앱이므로 프로세스를 종료하지 않고 유지
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}
