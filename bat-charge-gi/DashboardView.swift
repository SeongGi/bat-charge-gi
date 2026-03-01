import SwiftUI

struct DashboardView: View {
    @State private var maxCapacity: Int = 100
    @State private var designCapacity: Int = 0
    @State private var currentCapacity: Int = 0
    @State private var cycleCount: Int = 0
    @State private var temperature: Double = 0.0
    @State private var voltage: Double = 0.0
    @State private var amperage: Double = 0.0
    
    @State private var timeRemaining: Int = 0
    @State private var adapterWatts: Int = 0
    
    @State private var lastFullChargeDate: Date? = nil
    @State private var lastDischargeStartDate: Date? = nil
    
    @State private var timer: Timer?

    private var dateFormatter: RelativeDateTimeFormatter {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.unitsStyle = .full
        return formatter
    }

    var watts: Double {
        return (voltage * amperage) / 1_000_000.0 // mV * mA to W
    }
    
    var timeRemainingString: String {
        if timeRemaining >= 65535 || timeRemaining == 0 {
            return "계산 중대기 / 완충됨"
        }
        let hours = timeRemaining / 60
        let mins = timeRemaining % 60
        return "\(hours)시간 \(mins)분"
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("고급 배터리 대시보드")
                .font(.largeTitle)
                .bold()
            
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 20) {
                
                // Card 1
                DashboardCard(title: "배터리 수명 및 용량", icon: "heart.fill", color: .red) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { Text("설계 용량:"); Spacer(); Text("\(designCapacity) mAh") }
                        HStack { Text("현재 최대 개런티:"); Spacer(); Text("\(currentCapacity) mAh") }
                        HStack { Text("배터리 헬스:"); Spacer(); Text("\(maxCapacity)%") }
                        HStack { Text("사이클 카운트:"); Spacer(); Text("\(cycleCount) 회") }
                        Divider()
                        HStack { Text("마지막 방전 시작:"); Spacer(); Text(lastDischargeStartDate != nil ? dateFormatter.localizedString(for: lastDischargeStartDate!, relativeTo: Date()) : "기록 없음") }
                        HStack { Text("마지막 완충 (100%):"); Spacer(); Text(lastFullChargeDate != nil ? dateFormatter.localizedString(for: lastFullChargeDate!, relativeTo: Date()) : "기록 없음") }
                    }
                    .font(.body)
                }
                
                // Card 2
                DashboardCard(title: "실시간 전력 및 온도", icon: "bolt.fill", color: .yellow) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { Text("전원 어댑터 전력:"); Spacer(); Text("\(adapterWatts > 0 ? "\(adapterWatts) W" : "분리됨 또는 알 수 없음")") }
                        HStack { Text("전압 (Voltage):"); Spacer(); Text("\(String(format: "%.1f", voltage / 1000.0)) V") }
                        HStack { Text("전류 (Amperage):"); Spacer(); Text("\(String(format: "%.0f", amperage)) mA") }
                        HStack { Text("배터리 소모/충전 전력:"); Spacer(); Text("\(String(format: "%.1f", abs(watts))) W") }
                        HStack { Text("예상 남은 시간:"); Spacer(); Text(timeRemainingString) }
                        HStack { Text("배터리 온도:"); Spacer(); Text("\(String(format: "%.1f", temperature)) °C") }
                    }
                }
                
                // Card 3
                DashboardCard(title: "전력 분배 흐름도", icon: "arrow.triangle.swap", color: .green) {
                    VStack(alignment: .center, spacing: 16) {
                        if adapterWatts > 0 {
                            let batteryPower = abs(watts)
                            let sysPower = max(0.0, Double(adapterWatts) - batteryPower)
                            let isChargingFromAdapter = watts > 0
                            
                            HStack(alignment: .center, spacing: 8) {
                                // 어댑터 소스
                                VStack {
                                    Image(systemName: "powerplug.fill").font(.title2)
                                    Text("\(adapterWatts)W").bold()
                                    Text("어댑터").font(.caption2).foregroundColor(.secondary)
                                }
                                
                                Image(systemName: "arrow.right").foregroundColor(.secondary).font(.subheadline)
                                
                                // 시스템 (Mac)
                                VStack {
                                    Image(systemName: "laptopcomputer").font(.title2)
                                    Text("\(String(format: "%.1f", sysPower))W").bold()
                                    Text("시스템 구동").font(.caption2).foregroundColor(.secondary)
                                }
                                
                                if isChargingFromAdapter {
                                    Image(systemName: "plus").foregroundColor(.secondary).font(.subheadline)
                                    
                                    // 배터리 충전
                                    VStack {
                                        Image(systemName: "battery.100.bolt").font(.title2)
                                        Text("\(String(format: "%.1f", batteryPower))W").bold()
                                        Text("배터리 충전").font(.caption2).foregroundColor(.secondary)
                                    }
                                }
                            }
                            .padding(.vertical, 8)
                        } else {
                            HStack {
                                Spacer()
                                VStack {
                                    Image(systemName: "battery.100").font(.title2)
                                    Text("\(String(format: "%.1f", abs(watts)))W").bold()
                                    Text("배터리 방전 중").font(.caption2).foregroundColor(.secondary)
                                }
                                Spacer()
                            }
                            .padding(.vertical, 8)
                        }
                    }
                    .font(.body)
                }
            }
            Spacer()
        }
        .padding(30)
        .frame(minWidth: 600, minHeight: 450)
        .onAppear {
            fetchSensors()
            fetchHistory()
            timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
                fetchSensors()
                fetchHistory()
            }
        }
        .onDisappear {
            timer?.invalidate()
        }
    }
    
    private func fetchHistory() {
        guard DaemonManager.shared.isDaemonRegistered else { return }
        
        if let proxy = DaemonManager.shared.helperConnection()?.remoteObjectProxyWithErrorHandler({ _ in }) as? BatteryHelperProtocol {
            proxy.getLastFullChargeDate { date, _ in
                DispatchQueue.main.async { self.lastFullChargeDate = date }
            }
            proxy.getLastDischargeStartDate { date, _ in
                DispatchQueue.main.async { self.lastDischargeStartDate = date }
            }
        }
    }
    
    private func fetchSensors() {
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
                    parseBatteryInfo(output)
                }
            } catch { }
        }
    }
    
    private func parseBatteryInfo(_ log: String) {
        let lines = log.components(separatedBy: .newlines)
        
        var tTemp = 0.0
        var tVolt = 0.0
        var tAmp = 0.0
        var tMaxCap = 0
        var tDesign = 0
        var tCurrent = 0
        var tCycle = 0
        var tTime = 0
        var tAdapter = 0
        
        for line in lines {
            if line.contains("\"Temperature\" =") {
                if let val = extractValue(line) { tTemp = Double(val) / 100.0 }
            } else if line.contains("\"Voltage\" =") {
                if let val = extractValue(line) { tVolt = Double(val) }
            } else if line.contains("\"Amperage\" =") {
                if let val = extractValue(line) { tAmp = Double(val) }
            } else if line.contains("\"MaxCapacity\" =") && !line.contains("AppleRaw") {
                if let val = extractValue(line) { tMaxCap = val }
            } else if line.contains("\"DesignCapacity\" =") && !line.contains("Fed") {
                if let val = extractValue(line) { tDesign = val }
            } else if line.contains("\"AppleRawMaxCapacity\" =") {
                if let val = extractValue(line) { tCurrent = val }
            } else if line.contains("\"CycleCount\" =") {
                if let val = extractValue(line) { tCycle = val }
            } else if line.contains("\"TimeRemaining\" =") {
                if let val = extractValue(line) { tTime = val }
            } else if line.contains("\"AdapterDetails\" =") && line.contains("\"Watts\"=") {
                let parts = line.components(separatedBy: "\"Watts\"=")
                if parts.count > 1 {
                    let wPart = parts[1].components(separatedBy: ",")
                    if let w = Int(wPart[0]) { tAdapter = w }
                }
            }
        }
        
        DispatchQueue.main.async {
            self.temperature = tTemp
            self.voltage = tVolt
            self.amperage = tAmp
            self.maxCapacity = tMaxCap
            self.designCapacity = tDesign
            if tCurrent > 0 { self.currentCapacity = tCurrent } else { self.currentCapacity = tDesign }
            self.cycleCount = tCycle
            self.timeRemaining = tTime
            self.adapterWatts = tAdapter
        }
    }
    
    private func extractValue(_ text: String) -> Int? {
        let parts = text.components(separatedBy: "=")
        guard parts.count > 1 else { return nil }
        let clean = parts[1].trimmingCharacters(in: CharacterSet.decimalDigits.inverted)
        return Int(clean)
    }
}

struct DashboardCard<Content: View>: View {
    let title: String
    let icon: String
    let color: Color
    let content: () -> Content
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(color)
                    .font(.title2)
                Text(title)
                    .font(.headline)
            }
            Divider()
            content()
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.1), radius: 5, x: 0, y: 2)
    }
}
