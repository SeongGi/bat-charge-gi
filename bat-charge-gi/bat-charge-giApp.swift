import SwiftUI
import Sparkle

@main
struct bat_charge_giApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Settings {
            EmptyView()
        }
        
        // 대시보드 창은 명시적으로 부를 때만 띄우도록 설정
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
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        print("[App] Launching...")
        
        // 1. 메뉴바 아이콘 즉시 생성 (최우선 순위)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem?.button {
            // 기본 아이콘 설정
            let img = NSImage(systemSymbolName: "battery.100.bolt", accessibilityDescription: "Battery Manager")
            img?.isTemplate = true
            button.image = img
            button.target = self
            button.action = #selector(togglePopover(_:))
            print("[App] Status Item Created")
        }
        
        // 2. 팝업 뷰 초기화
        var contentView = ContentView()
        contentView.onUpdateCheck = { [weak self] in
            self?.updaterController.checkForUpdates(nil)
        }
        popover.contentViewController = NSHostingController(rootView: contentView)
        popover.behavior = .transient
        
        // 3. 업데이트 컨트롤러 초기화
        updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        
        // 4. 아이콘 실시간 업데이트 타이머
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.updateBatteryIcon()
        }
        updateBatteryIcon() // 즉시 한 번 실행
        
        // 5. 데몬 연결 확인
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
                print("Icon update failed: \(error)")
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
