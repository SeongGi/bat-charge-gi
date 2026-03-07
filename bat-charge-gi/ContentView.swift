import SwiftUI
import ServiceManagement
import UserNotifications

struct ContentView: View {
    @State private var chargeLimit: Double = 80.0
    @State private var dischargeMode: Bool = false
    @State private var sailingMode: Bool = false
    @State private var calibrationMode: Bool = false
    @State private var launchAtLogin: Bool = false
    
    @State private var cycleCount: Int? = nil
    @State private var timeRemaining: Int = 0
    @State private var adapterWatts: Int = 0
    @State private var batteryVoltage: Double = 0.0
    @State private var batteryAmperage: Double = 0.0
    
    @State private var timer: Timer?
    
    @State private var isChargingStatus: Bool = false
    @State private var isFullyChargedStatus: Bool = false
    @State private var isOnACPower: Bool = false
    @State private var batteryPercent: Int = 0
    @State private var showingClamshellWarning = false
    
    var onUpdateCheck: (() -> Void)? = nil
    
    var batteryWatts: Double {
        return (batteryVoltage * batteryAmperage) / 1_000_000.0
    }
    
    @ObservedObject var daemonManager = DaemonManager.shared
    @Environment(\.openWindow) private var openWindow
    
    var timeRemainingString: String {
        if isFullyChargedStatus { return "완충 상태" }
        if timeRemaining >= 65535 || timeRemaining == 0 {
            return "잔여 시간 계산 중..."
        }
        let hours = timeRemaining / 60
        let mins = timeRemaining % 60
        let timeStr = "\(hours)시간 \(mins)분"
        
        if isChargingStatus {
            return "완충까지: \(timeStr)"
        } else {
            return "사용 가능: \(timeStr)"
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            
            // ── 상단 타이틀 + 고급통계 버튼 ──
            HStack {
                Text("배터리 관리").font(.headline)
                Spacer()
                Button(action: { openWindow(id: "dashboard") }) {
                    HStack(spacing: 4) {
                        Image(systemName: "chart.bar.doc.horizontal").font(.caption)
                        Text("고급 통계").font(.caption)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            
            // ── 배터리 잔량 대형 표시 ──
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "battery.75").font(.system(size: 32))
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(batteryPercent)%")
                        .font(.system(size: 28, weight: .bold))
                    HStack(spacing: 8) {
                        if let cycle = cycleCount {
                            Text("사이클: \(cycle)회").font(.caption2).foregroundColor(.secondary)
                        }
                        Text(timeRemainingString).font(.caption2).foregroundColor(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
            
            Divider()
            
            // ── 충전 제한 슬라이더 ──
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("충전 제한").font(.subheadline).bold()
                    Spacer()
                    Text("\(Int(chargeLimit))%")
                        .font(.subheadline).bold()
                        .foregroundColor(.accentColor)
                }
                Slider(value: $chargeLimit, in: 20...100, step: 1) { editing in
                    if !editing {
                        applyChargeLimit()
                    }
                }
                HStack {
                    Text("20%").font(.caption2).foregroundColor(.secondary)
                    Spacer()
                    Text("100%").font(.caption2).foregroundColor(.secondary)
                }
            }
            
            Divider()
            
            // ── 토글 그룹 ──
            VStack(alignment: .leading, spacing: 10) {
                // 자동 방전
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("자동 방전", isOn: Binding(
                        get: { self.dischargeMode },
                        set: { newValue in
                            self.dischargeMode = newValue
                            if newValue {
                                self.sailingMode = false
                                self.calibrationMode = false
                                applySailingMode(enabled: false)
                                applyCalibrationMode(enabled: false)
                                self.showingClamshellWarning = true
                                sendClamshellNotification()
                            }
                            applyDischargeMode(enabled: newValue)
                        }
                    ))
                    Text("어댑터 연결 중에도 배터리만 사용")
                        .font(.caption2).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 20)
                }
                
                // 배터리 보존모드
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("배터리 보존모드", isOn: Binding(
                        get: { self.sailingMode },
                        set: { newValue in
                            self.sailingMode = newValue
                            if newValue {
                                self.dischargeMode = false
                                self.calibrationMode = false
                                applyDischargeMode(enabled: false)
                                applyCalibrationMode(enabled: false)
                            }
                            applySailingMode(enabled: newValue)
                        }
                    ))
                    Text("불필요한 마이크로 충전 방지. 충전 제한 도달 후 배터리가 -10% 떨어질 때까지 전력만 공급받으며 소폭의 방전을 허용합니다.")
                        .font(.caption2).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 20)
                }
                
                // 배터리 재교정
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("배터리 재교정", isOn: Binding(
                        get: { self.calibrationMode },
                        set: { newValue in
                            self.calibrationMode = newValue
                            if newValue {
                                self.dischargeMode = false
                                self.sailingMode = false
                                applyDischargeMode(enabled: false)
                                applySailingMode(enabled: false)
                                self.showingClamshellWarning = true
                                sendClamshellNotification()
                            }
                            applyCalibrationMode(enabled: newValue)
                        }
                    ))
                    Text("100%충전→2h대기→방전→5h대기→재충전")
                        .font(.caption2).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 20)
                }
            }
            
            // ── 하드웨어 한계 경고 (인라인) ──
            if showingClamshellWarning {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("모니터 깜빡임 주의")
                            .font(.caption).bold()
                        Spacer()
                        Button(action: { showingClamshellWarning = false }) {
                            Image(systemName: "xmark")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                    Text("클램쉘모드로 사용 시 방전모드를 사용하면 모니터 깜빡임 현상이 발생됩니다.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .background(Color.orange.opacity(0.15))
                .cornerRadius(6)
            }
            
            // ── 전력 분배 위젯 ──
            if true {
                Divider()
                
                let bPower = abs(batteryWatts)
                
                // 분기 기준: 실제 전원 소스(pmset) + 충전 여부(ioreg) + 사용자 모드(방전/재교정)
                let isActiveDischarge = dischargeMode || calibrationMode
                
                if isOnACPower && isChargingStatus {
                    // ── 케이스 1: 어댑터 → 시스템 + 배터리 충전 (fork) ──
                    let sysPower = max(0.0, Double(adapterWatts) - bPower)
                    
                    ZStack {
                        PowerFlowLines(isCharging: true)
                        HStack(spacing: 0) {
                            VStack(spacing: 1) {
                                Image(systemName: "bolt.square.fill")
                                    .font(.system(size: 24))
                                    .foregroundColor(.secondary)
                            }.frame(width: 40)
                            VStack(spacing: 0) {
                                Text("어댑터").font(.caption2).foregroundColor(.secondary)
                                Text("\(adapterWatts)W").bold().font(.caption)
                            }.frame(width: 55)
                            Spacer()
                            VStack(alignment: .trailing, spacing: 12) {
                                HStack(spacing: 5) {
                                    Image(systemName: "laptopcomputer").font(.system(size: 18))
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text("시스템").font(.caption2).foregroundColor(.secondary)
                                        Text("\(String(format: "%.1f", sysPower))W").bold().font(.callout)
                                    }
                                }
                                HStack(spacing: 5) {
                                    Image(systemName: "battery.100.bolt")
                                        .font(.system(size: 18))
                                        .foregroundColor(.green)
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text("충전 중").font(.caption2).foregroundColor(.secondary)
                                        Text("\(String(format: "%.1f", bPower))W").bold().font(.callout)
                                    }
                                }
                            }.padding(.trailing, 8)
                        }
                    }
                    .frame(height: 70)
                    .padding(.horizontal, 8).padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(8)

                } else if isOnACPower && isActiveDischarge {
                    // ── 케이스 2: 어댑터 + 배터리 → 시스템 (자동 방전/재교정 모드) ──
                    let sysPower = Double(adapterWatts) + bPower
                    
                    ZStack {
                        PowerFlowLines(mode: .merge)  // 2→1 합류선
                        HStack(spacing: 0) {
                            // 왼쪽: 어댑터(위) + 배터리(아래) 세로 배치
                            VStack(spacing: 8) {
                                VStack(spacing: 1) {
                                    Image(systemName: "bolt.square.fill")
                                        .font(.system(size: 18))
                                        .foregroundColor(.secondary)
                                    Text("\(adapterWatts)W").font(.caption2)
                                }
                                VStack(spacing: 1) {
                                    Image(systemName: "battery.75")
                                        .font(.system(size: 18))
                                        .foregroundColor(.orange)
                                    Text("\(String(format: "%.1f", bPower))W").font(.caption2).foregroundColor(.orange)
                                }
                            }.frame(width: 50)
                            
                            Spacer()
                            
                            // 오른쪽: 시스템 (합산 소모)
                            HStack(spacing: 5) {
                                Image(systemName: "laptopcomputer").font(.system(size: 22))
                                VStack(alignment: .leading, spacing: 0) {
                                    Text("시스템 소모").font(.caption2).foregroundColor(.secondary)
                                    Text("\(String(format: "%.1f", sysPower))W").bold().font(.callout)
                                }
                            }
                            .padding(.trailing, 8)
                        }
                    }
                    .frame(height: 70)
                    .padding(.horizontal, 8).padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(8)

                } else if isOnACPower {
                    // ── 케이스 3: 어댑터 → 시스템만 (배터리 대기/충전차단) ──
                    ZStack {
                        PowerFlowLines(isCharging: false)
                        HStack(spacing: 0) {
                            VStack(spacing: 1) {
                                Image(systemName: "bolt.square.fill")
                                    .font(.system(size: 24))
                                    .foregroundColor(.secondary)
                            }.frame(width: 40)
                            VStack(spacing: 0) {
                                Text("어댑터").font(.caption2).foregroundColor(.secondary)
                                Text("\(adapterWatts)W").bold().font(.caption)
                            }.frame(width: 55)
                            Spacer()
                            HStack(spacing: 5) {
                                Image(systemName: "laptopcomputer").font(.system(size: 18))
                                VStack(alignment: .leading, spacing: 0) {
                                    Text("시스템").font(.caption2).foregroundColor(.secondary)
                                    Text("\(String(format: "%.1f", Double(adapterWatts)))W").bold().font(.callout)
                                }
                            }.padding(.trailing, 8)
                        }
                    }
                    .frame(height: 40)
                    .padding(.horizontal, 8).padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(8)

                } else {
                    // ── 케이스 4: 배터리 → 시스템 (어댑터 미연결) ──
                    HStack(spacing: 8) {
                        VStack(spacing: 2) {
                            Image(systemName: "battery.75")
                                .font(.system(size: 22))
                                .foregroundColor(.orange)
                            Text("배터리").font(.caption2).foregroundColor(.secondary)
                            Text("\(String(format: "%.1f", bPower))W").bold().font(.caption)
                        }.frame(width: 60)
                        HStack(spacing: 2) {
                            Rectangle()
                                .fill(Color.orange.opacity(0.5))
                                .frame(width: 30, height: 2)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8))
                                .foregroundColor(.orange)
                        }
                        HStack(spacing: 5) {
                            Image(systemName: "laptopcomputer").font(.system(size: 18))
                            VStack(alignment: .leading, spacing: 0) {
                                Text("시스템 소모").font(.caption2).foregroundColor(.secondary)
                                Text("\(String(format: "%.1f", bPower))W").bold().font(.callout)
                            }
                        }
                        Spacer()
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(8)
                }
            }
            
            Divider()
            
            // ── 데몬 상태 ──
            VStack(alignment: .leading, spacing: 4) {
                switch daemonManager.daemonState {
                case .registered:
                    HStack {
                        Image(systemName: "checkmark.circle.fill").foregroundColor(.green).font(.caption)
                        Text("백엔드 코어 연동 정상").font(.caption).foregroundColor(.green)
                    }
                case .connecting:
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("백엔드 코어 연결 중...").font(.caption).foregroundColor(.orange)
                    }
                    Text("재부팅 직후 잠시 대기합니다. 잠시만 기다려주세요.")
                        .font(.caption2).foregroundColor(.secondary)
                case .notInstalled:
                    HStack {
                        Button("백그라운드 제어 권한 허용 (Helper 설치)") {
                            daemonManager.registerDaemon()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                    }
                    Text("최초 1회 루트(Root) 데몬 설치가 필요합니다.")
                        .font(.caption2).foregroundColor(.secondary)
                }
            }
            
            Divider()
            
            // ── 하단 옵션 ──
            HStack {
                Toggle("로그인 시 자동 실행", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { newValue in
                        do {
                            if newValue {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            print("Failed to change launch at login status: \(error)")
                        }
                    }
                    .font(.caption)
                
                Spacer()
                
                if let onUpdateCheck = onUpdateCheck {
                    Button("업데이트 확인") {
                        onUpdateCheck()
                    }
                    .controlSize(.small)
                }
                
                Button("종료") {
                    NSApplication.shared.terminate(nil)
                }
                .controlSize(.small)
            }
        }
        .padding()
        .frame(width: 340)
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            fetchChargeLimit()
            fetchExtraBatteryInfo()
            
            // 실시간 갱신 타이머 시작
            timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
                fetchExtraBatteryInfo()
            }
        }
        .onDisappear {
            timer?.invalidate()
        }
    }
    
    private func fetchExtraBatteryInfo() {
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
            task.arguments = ["-rw0", "-c", "AppleSmartBattery"]
            let pipe = Pipe()
            task.standardOutput = pipe
            do {
                try task.run()
                task.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: data, encoding: .utf8) {
                    var tCycle = 0
                    var tTime = 0
                    var tAdapter = 0
                    var tVolt = 0.0
                    var tAmp = 0.0
                    var isChg = false
                    var isFull = false
                    var tPct = 0
                    
                    let lines = output.components(separatedBy: .newlines)
                    for line in lines {
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        if trimmed.hasPrefix("\"CycleCount\" =") {
                            if let val = self.extractValue(line) { tCycle = val }
                        } else if trimmed.hasPrefix("\"TimeRemaining\" =") {
                            if let val = self.extractValue(line) { tTime = val }
                        } else if trimmed.hasPrefix("\"Voltage\" =") {
                            if let val = self.extractValue(line) { tVolt = Double(val) }
                        } else if trimmed.hasPrefix("\"Amperage\" =") {
                            if let val = self.extractValue(line) { tAmp = Double(val) }
                        } else if trimmed.hasPrefix("\"IsCharging\" = Yes") {
                            isChg = true
                        } else if trimmed.hasPrefix("\"FullyCharged\" = Yes") {
                            isFull = true
                        } else if trimmed.hasPrefix("\"CurrentCapacity\" =") {
                            if let val = self.extractValue(line) { tPct = val }
                        } else if line.contains("\"AdapterDetails\" =") && line.contains("\"Watts\"=") {
                            let parts = line.components(separatedBy: "\"Watts\"=")
                            if parts.count > 1 {
                                let wPart = parts[1].components(separatedBy: ",")
                                if let w = Int(wPart[0]) { tAdapter = w }
                            }
                        }
                    }
                    DispatchQueue.main.async {
                        self.cycleCount = tCycle > 0 ? tCycle : nil
                        self.timeRemaining = tTime
                        self.adapterWatts = tAdapter
                        self.batteryVoltage = tVolt
                        self.batteryAmperage = tAmp
                        self.isChargingStatus = isChg
                        self.isFullyChargedStatus = isFull
                        self.batteryPercent = tPct > 0 ? tPct : 0
                    }
                }
            } catch { }
            
            // pmset에서 실제 전원 소스 확인
            let pmTask = Process()
            pmTask.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            pmTask.arguments = ["-g", "batt"]
            let pmPipe = Pipe()
            pmTask.standardOutput = pmPipe
            do {
                try pmTask.run()
                pmTask.waitUntilExit()
                let pmData = pmPipe.fileHandleForReading.readDataToEndOfFile()
                if let pmOutput = String(data: pmData, encoding: .utf8) {
                    let onAC = pmOutput.contains("AC Power")
                    DispatchQueue.main.async {
                        self.isOnACPower = onAC
                    }
                }
            } catch { }
        }
    }
    
    private func extractValue(_ text: String) -> Int? {
        let parts = text.components(separatedBy: "=")
        guard parts.count > 1 else { return nil }
        let trimmed = parts[1].trimmingCharacters(in: .whitespaces)
        let clean = trimmed.trimmingCharacters(in: CharacterSet.decimalDigits.inverted)
        // ioreg는 음수(방전 전류 등)를 unsigned 64비트로 출력함
        // 예: -697 → 18446744073709550919 (2^64 - 697)
        // UInt64로 파싱 후 Int64 비트캐스트로 올바른 음수 복원
        if let uVal = UInt64(clean), uVal > UInt64(Int64.max) {
            return Int(Int64(bitPattern: uVal))
        }
        return Int(clean)
    }
    
    func applyChargeLimit() {
        if daemonManager.isDaemonRegistered {
            if let proxy = daemonManager.helperConnection()?.remoteObjectProxyWithErrorHandler({ error in
                print("XPC Error: \(error)")
            }) as? BatteryHelperProtocol {
                proxy.setChargeLimit(limit: Int(chargeLimit), withReply: { success, errorMsg in
                    if success {
                        print("Limit set successfully to \(Int(chargeLimit))%")
                    } else {
                        print("Failed to set limit: \(errorMsg ?? "Unknown error")")
                    }
                })
            }
        }
    }
    
    func fetchChargeLimit() {
        if daemonManager.isDaemonRegistered {
            if let proxy = daemonManager.helperConnection()?.remoteObjectProxyWithErrorHandler({ error in
                print("XPC Error: \(error)")
            }) as? BatteryHelperProtocol {
                proxy.getChargeLimit(withReply: { limit, errorMsg in
                    DispatchQueue.main.async {
                        if limit > 0 {
                            self.chargeLimit = Double(limit)
                        }
                    }
                })
                
                proxy.getDischargeMode(withReply: { enabled, _ in
                    DispatchQueue.main.async { self.dischargeMode = enabled }
                })
                proxy.getSailingMode(withReply: { enabled, _ in
                    DispatchQueue.main.async { self.sailingMode = enabled }
                })
                proxy.getCalibrationMode(withReply: { enabled, _ in
                    DispatchQueue.main.async { self.calibrationMode = enabled }
                })
            }
        }
    }
    
    // MARK: - 부가 기능 적용 XPC Wrapper
    
    func applyDischargeMode(enabled: Bool) {
        print("[XPC] applyDischargeMode(\(enabled)) called")
        if let proxy = daemonManager.helperConnection()?.remoteObjectProxyWithErrorHandler({ error in
            print("[XPC] ERROR: \(error)")
        }) as? BatteryHelperProtocol {
            proxy.setDischargeMode(enabled: enabled, withReply: { success, errorMsg in
                print("[XPC] setDischargeMode reply: success=\(success), error=\(errorMsg ?? "nil")")
            })
        } else {
            print("[XPC] FAILED: proxy is nil, helper not connected")
        }
    }
    
    func applySailingMode(enabled: Bool) {
        if let proxy = daemonManager.helperConnection()?.remoteObjectProxyWithErrorHandler({ _ in }) as? BatteryHelperProtocol {
            proxy.setSailingMode(enabled: enabled, withReply: { _, _ in })
        }
    }
    
    func applyCalibrationMode(enabled: Bool) {
        if let proxy = daemonManager.helperConnection()?.remoteObjectProxyWithErrorHandler({ _ in }) as? BatteryHelperProtocol {
            proxy.setCalibrationMode(enabled: enabled, withReply: { _, _ in })
        }
    }
    
    private func sendClamshellNotification() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "⚠️ 모니터 깜빡임 주의"
            content.body = "클램쉘모드로 사용 시 방전모드를 사용하면 모니터 깜빡임 현상이 발생됩니다."
            content.sound = .default
            let request = UNNotificationRequest(identifier: "clamshell_warning", content: content, trigger: nil)
            center.add(request)
        }
    }
}

// MARK: - 전력 분배 배선 드로잉 (fork / merge / single)
struct PowerFlowLines: View {
    enum Mode { case fork, merge, single }
    let mode: Mode
    
    // 기존 호환용 init
    init(isCharging: Bool) {
        self.mode = isCharging ? .fork : .single
    }
    init(mode: Mode) {
        self.mode = mode
    }
    
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let midY = h / 2
            
            switch mode {
            case .fork:
                // 1→2 분기: 왼쪽 한 점에서 오른쪽 두 점으로
                let startX: CGFloat = 95
                let forkX: CGFloat = w * 0.50
                let endX: CGFloat = w - 85
                let topY = h * 0.25
                let botY = h * 0.75
                
                Path { p in
                    p.move(to: CGPoint(x: startX, y: midY))
                    p.addLine(to: CGPoint(x: forkX, y: midY))
                    p.move(to: CGPoint(x: forkX, y: midY))
                    p.addLine(to: CGPoint(x: forkX + 12, y: topY))
                    p.addLine(to: CGPoint(x: endX, y: topY))
                    p.move(to: CGPoint(x: forkX, y: midY))
                    p.addLine(to: CGPoint(x: forkX + 12, y: botY))
                    p.addLine(to: CGPoint(x: endX, y: botY))
                }
                .stroke(cyanGradient, style: lineStyle)
                
                arrowHead(at: CGPoint(x: endX, y: topY), color: .cyan)
                arrowHead(at: CGPoint(x: endX, y: botY), color: .green)
                
            case .merge:
                // 2→1 합류: 왼쪽 두 점에서 오른쪽 한 점으로
                let startX: CGFloat = 55
                let mergeX: CGFloat = w * 0.45
                let endX: CGFloat = w - 100
                let topY = h * 0.25
                let botY = h * 0.75
                
                Path { p in
                    p.move(to: CGPoint(x: startX, y: topY))
                    p.addLine(to: CGPoint(x: mergeX - 12, y: topY))
                    p.addLine(to: CGPoint(x: mergeX, y: midY))
                    p.move(to: CGPoint(x: startX, y: botY))
                    p.addLine(to: CGPoint(x: mergeX - 12, y: botY))
                    p.addLine(to: CGPoint(x: mergeX, y: midY))
                    p.move(to: CGPoint(x: mergeX, y: midY))
                    p.addLine(to: CGPoint(x: endX, y: midY))
                }
                .stroke(cyanGradient, style: lineStyle)
                
                arrowHead(at: CGPoint(x: endX, y: midY), color: .cyan)
                
            case .single:
                // 1→1 직선
                let startX: CGFloat = 95
                let endX: CGFloat = w - 85
                
                Path { p in
                    p.move(to: CGPoint(x: startX, y: midY))
                    p.addLine(to: CGPoint(x: endX, y: midY))
                }
                .stroke(cyanGradient, style: lineStyle)
                
                arrowHead(at: CGPoint(x: endX, y: midY), color: .cyan)
            }
        }
    }
    
    private var cyanGradient: LinearGradient {
        LinearGradient(colors: [.cyan.opacity(0.6), .cyan.opacity(0.3)],
                       startPoint: .leading, endPoint: .trailing)
    }
    private var lineStyle: StrokeStyle {
        StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
    }
    
    @ViewBuilder
    private func arrowHead(at point: CGPoint, color: Color) -> some View {
        Path { p in
            p.move(to: CGPoint(x: point.x - 4, y: point.y - 4))
            p.addLine(to: CGPoint(x: point.x + 2, y: point.y))
            p.addLine(to: CGPoint(x: point.x - 4, y: point.y + 4))
        }
        .fill(color.opacity(0.6))
    }
}

