import SwiftUI
import Sparkle

@main
struct bat_charge_giApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        // WindowGroup으로 변경하여 시작 시 자동 오픈 방지 (id로만 호출)
        WindowGroup(id: "dashboard") {
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
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // App Nap 방지: 시스템이 앱을 절전 상태로 만드는 것을 막아 아이콘 선명도 유지
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .background], reason: "Keeping menu bar icon active")
        
        // 1. 메뉴바 아이콘 즉시 생성
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem?.button {
            button.isEnabled = true
            let img = NSImage(systemSymbolName: "battery.100.bolt", accessibilityDescription: "Battery Manager")
            img?.isTemplate = true
            button.image = img
            button.target = self
            button.action = #selector(togglePopover(_:))
        }
        
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
        timer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            self?.updateBatteryIcon()
        }
        updateBatteryIcon()
        
        // 5. 데몬 상태 확인
        DaemonManager.shared.checkDaemonStatus()
        
        // 6. 시작 시 불필요하게 뜬 모든 창 닫기 (메뉴바 앱 전용)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSApplication.shared.windows.forEach { window in
                // 메뉴바 팝업(NSPanel)이나 스파클 업데이트 창이 아닌 경우에만 닫음
                if window.title == "고급 배터리 통계" || window.identifier?.rawValue == "dashboard" {
                    window.close()
                }
            }
        }
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
