import Foundation

class SMCManager {
    static let shared = SMCManager()
    
    private var currentLimit: Int {
        get {
            let val = UserDefaults.standard.integer(forKey: "currentLimit")
            return val == 0 ? 80 : val
        }
        set { UserDefaults.standard.set(newValue, forKey: "currentLimit") }
    }
    
    // Apple 정석 교정 모드 (Calibration) 5-Step 상태 정의
    enum CalibrationState: Int {
        case idle = 0
        case chargingTo100 = 1
        case waitingTwoHoursAt100 = 2
        case dischargingToZero = 3
        case waitingFiveHoursAtZero = 4
        case rechargingToTarget = 5
    }
    
    private(set) var isDischargeModeEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "isDischargeModeEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "isDischargeModeEnabled") }
    }
    private(set) var isSailingModeEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "isSailingModeEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "isSailingModeEnabled") }
    }
    private(set) var isCalibrationModeEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "isCalibrationModeEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "isCalibrationModeEnabled") }
    }
    
    private var calibrationStateRaw: Int {
        get { UserDefaults.standard.integer(forKey: "calibrationStateRaw") }
        set { UserDefaults.standard.set(newValue, forKey: "calibrationStateRaw") }
    }
    private var calibrationState: CalibrationState {
        get { CalibrationState(rawValue: calibrationStateRaw) ?? .idle }
        set { calibrationStateRaw = newValue.rawValue }
    }
    // 교정 모드 구간 대기 시작 시간 기록 (앱 재시작 대응)
    private var calibrationWaitStartTimeRaw: Double {
        get { UserDefaults.standard.double(forKey: "calibrationWaitStartTimeRaw") }
        set { UserDefaults.standard.set(newValue, forKey: "calibrationWaitStartTimeRaw") }
    }
    private var calibrationWaitStartTime: Date? {
        get {
            let val = calibrationWaitStartTimeRaw
            return val > 0 ? Date(timeIntervalSince1970: val) : nil
        }
        set {
            if let d = newValue { calibrationWaitStartTimeRaw = d.timeIntervalSince1970 }
            else { calibrationWaitStartTimeRaw = 0 }
        }
    }
    
    private var timer: Timer?
    private var smcPath: String = ""
    
    private var supportsTahoe: Bool = false
    private var supportsLegacy: Bool = false
    
    private var supportsAdapterChie: Bool = false
    private var supportsAdapterCh0j: Bool = false
    private var supportsAdapterCh0i: Bool = false
    
    // 현재 충전 제어 상태 추적 (중복 호출 방지용)
    private enum ChargingState: Int {
        case unknown = 0
        case charging = 1
        case chargingDisabled = 2
        case discharging = 3
    }
    private var currentChargingState: ChargingState = .unknown
    private var isClamshellSleepPrevented: Bool = false
    
    init() {
        // 1. 우선적으로 같은 실행 파일 옆에 smc가 있는지 확인 (Helper 데몬용)
        if let executableURL = Bundle.main.executableURL {
            let localSmc = executableURL.deletingLastPathComponent().appendingPathComponent("smc").path
            if FileManager.default.fileExists(atPath: localSmc) {
                self.smcPath = localSmc
            }
        }
        
        // 2. 위에서 못 찾았으면 표준 경로들 확인
        if self.smcPath.isEmpty {
            let fallbacks = [
                "/Library/PrivilegedHelperTools/smc",
                "/Applications/bat-charge-gi.app/Contents/MacOS/smc",
                "/usr/local/bin/smc"
            ]
            self.smcPath = fallbacks.first(where: { FileManager.default.fileExists(atPath: $0) }) ?? "/Applications/bat-charge-gi.app/Contents/MacOS/smc"
        }
        
        print("[SMCManager] Using smc path: \(self.smcPath)")
        
        // CHTE (M2/M3) 지원 여부 체크
        let chteRes = runSMC(args: ["-k", "CHTE", "-r"])
        self.supportsTahoe = !chteRes.contains("Error") && !chteRes.contains("no data")
        
        let ch0bRes = runSMC(args: ["-k", "CH0B", "-r"])
        self.supportsLegacy = !ch0bRes.contains("Error") && !ch0bRes.contains("no data")
        
        let chieRes = runSMC(args: ["-k", "CHIE", "-r"])
        self.supportsAdapterChie = !chieRes.contains("no data")
        
        let ch0jRes = runSMC(args: ["-k", "CH0J", "-r"])
        self.supportsAdapterCh0j = !ch0jRes.contains("Error") && !ch0jRes.contains("no data")
        
        let ch0iRes = runSMC(args: ["-k", "CH0I", "-r"])
        self.supportsAdapterCh0i = !ch0iRes.contains("no data")
        
        // 시작 즉시 충전 제어 적용 (재부팅 시 SMC 키 리셋 대응)
        enforceBatteryLimit()
        
        // Start polling timer (every 10 seconds)
        DispatchQueue.main.async {
            self.timer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
                self?.enforceBatteryLimit()
            }
        }
    }
    
    private func runSMC(args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: smcPath)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        } catch {
            return "Error: \(error)"
        }
    }
    
    private func getBatteryPercentage() -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "batt"]
        let pipe = Pipe()
        process.standardOutput = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                // Parse charging percentage, e.g. "x%; charging"
                let components = output.components(separatedBy: .whitespaces)
                for comp in components {
                    if comp.contains("%") {
                        let numStr = comp.replacingOccurrences(of: "%", with: "").replacingOccurrences(of: ";", with: "")
                        if let pct = Int(numStr) { return pct }
                    }
                }
            }
        } catch { }
        return 100
    }
    
    private func setDischargeKeys(enabled: Bool) {
        if enabled {
            let currentNow = Int(Date().timeIntervalSince1970)
            UserDefaults.standard.set(currentNow, forKey: "lastDischargeStartDate")
            
            if supportsAdapterChie { _ = runSMC(args: ["-k", "CHIE", "-w", "08"]) }
            else if supportsAdapterCh0j { _ = runSMC(args: ["-k", "CH0J", "-w", "01"]) }
            else if supportsAdapterCh0i { _ = runSMC(args: ["-k", "CH0I", "-w", "01"]) }
        } else {
            if supportsAdapterChie { _ = runSMC(args: ["-k", "CHIE", "-w", "00"]) }
            else if supportsAdapterCh0j { _ = runSMC(args: ["-k", "CH0J", "-w", "00"]) }
            else if supportsAdapterCh0i { _ = runSMC(args: ["-k", "CH0I", "-w", "00"]) }
        }
    }

    private var caffeinateProcess: Process?

    private func setPreventClamshellSleep(prevent: Bool) {
        // 이미 같은 상태면 중복 호출 방지
        guard isClamshellSleepPrevented != prevent else { return }
        
        caffeinateProcess?.terminate()
        caffeinateProcess = nil
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-b", "sleep", prevent ? "0" : "1"]
        try? process.run()
        process.waitUntilExit()

        if prevent {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
            p.arguments = ["-i", "-s", "-d"] // idle / system / display sleep 방지
            try? p.run()
            caffeinateProcess = p
        }
        isClamshellSleepPrevented = prevent
    }

    private func enableCharging() {
        guard currentChargingState != .charging else { return }
        if supportsTahoe {
            _ = runSMC(args: ["-k", "CHTE", "-w", "00000000"])
        } else if supportsLegacy {
            _ = runSMC(args: ["-k", "CH0B", "-w", "00"])
            _ = runSMC(args: ["-k", "CH0C", "-w", "00"])
        }
        setDischargeKeys(enabled: false)
        currentChargingState = .charging
    }
    
    private func disableCharging() {
        guard currentChargingState != .chargingDisabled else { return }
        // 단지 전원 공급을 제한(유지)할 뿐, 적극적 방전은 아님
        if supportsTahoe {
            _ = runSMC(args: ["-k", "CHTE", "-w", "01000000"])
        } else if supportsLegacy {
            _ = runSMC(args: ["-k", "CH0B", "-w", "02"])
            _ = runSMC(args: ["-k", "CH0C", "-w", "02"])
        }
        setDischargeKeys(enabled: false)
        currentChargingState = .chargingDisabled
    }
    
    private func enableDischarge() {
        // guard 없이 매번 키를 강제 적용 (USB-C 환경에서 시스템이 CHIE를 리셋할 수 있음)
        if supportsTahoe {
            _ = runSMC(args: ["-k", "CHTE", "-w", "01000000"]) // 충전 차단
        } else if supportsLegacy {
            _ = runSMC(args: ["-k", "CH0B", "-w", "02"])
            _ = runSMC(args: ["-k", "CH0C", "-w", "02"])
        }
        setDischargeKeys(enabled: true)
        setPreventClamshellSleep(prevent: true)
        currentChargingState = .discharging
    }
    
    private var isCurrentlyChargingToLimit: Bool {
        get { UserDefaults.standard.bool(forKey: "isCurrentlyChargingToLimit") }
        set { UserDefaults.standard.set(newValue, forKey: "isCurrentlyChargingToLimit") }
    }
    
    @objc private func enforceBatteryLimit() {
        let pct = getBatteryPercentage()
        
        // 1. 배터리가 100%에 닿은 시점을 감지해 기록 (마지막 완충)
        if pct == 100 {
            let currentNow = Int(Date().timeIntervalSince1970)
            if UserDefaults.standard.integer(forKey: "lastFullChargeDate") != currentNow {
                UserDefaults.standard.set(currentNow, forKey: "lastFullChargeDate")
            }
        }
        
        // 2. 방전 모드 돌입 혹은 물리적 방전 상태(Adapter Watts == 0 등)를 대략적으로 유추해 기록
        // 정밀한 판단(어댑터 뽑힘)은 getBatteryPercentage() 내부의 pmset 문자열 파싱 등을 활용할 수도 있으나,
        // 여기서는 앱의 "방전 제어"가 개입된 순간을 '마지막 방전 시작' 관점으로 우선 반영합니다.
        
        // 교정 모드 우선 처리 로직
        if isCalibrationModeEnabled {
            processCalibrationMode(pct: pct)
            return
        }
        
        // 방전 모드 처리 로직
        if isDischargeModeEnabled {
            if pct > currentLimit && pct > 5 {
                // 목표치 초과 → 적극적 방전 (매번 키 재적용)
                enableDischarge()
            } else {
                // 목표 도달 or 5% 하한선 → 방전 해제, 충전차단 유지
                // isDischargeModeEnabled는 유지 (사용자가 수동 해제)
                if currentChargingState == .discharging {
                    currentChargingState = .unknown
                    setDischargeKeys(enabled: false)
                    setPreventClamshellSleep(prevent: false)
                }
                disableCharging()
            }
            return
        }
        
        guard currentLimit < 100 else {
            enableCharging()
            return
        }
        
        // 항해 모드 활성화 시 재충전 시작 기준점을 더 낮게(-10%) 설정, 기본은 -3%
        let dropThreshold = isSailingModeEnabled ? 10 : 3
        
        if pct >= currentLimit {
            disableCharging()
            isCurrentlyChargingToLimit = false
        } else if pct <= (currentLimit - dropThreshold) {
            enableCharging()
            isCurrentlyChargingToLimit = true
        } else {
            // (currentLimit - dropThreshold) < pct < currentLimit 사이 구간 (Sailing 중)
            // 현재 올라가는 중이면 충전 조치, 타겟 찍고 내려오는 구간이면 계속 보존 처리
            if isCurrentlyChargingToLimit {
                enableCharging()
            } else {
                disableCharging()
            }
        }
    }
    
    private func processCalibrationMode(pct: Int) {
        switch calibrationState {
        case .idle:
            if pct >= 100 {
                calibrationState = .waitingTwoHoursAt100
                calibrationWaitStartTime = Date()
                enableCharging() // 100% 유지(보존)를 위해 어댑터 연결 상태 인가
            } else {
                calibrationState = .chargingTo100
                enableCharging() // 먼저 100% 목표로 충전 시작
            }
            
        case .chargingTo100:
            if pct >= 100 {
                calibrationState = .waitingTwoHoursAt100
                calibrationWaitStartTime = Date()
                enableCharging()
            } else {
                enableCharging()
            }
            
        case .waitingTwoHoursAt100:
            if let startTime = calibrationWaitStartTime {
                // 2시간(7200초) 100% 상태 유지 및 쿨링 대기
                if Date().timeIntervalSince(startTime) >= 7200 {
                    calibrationState = .dischargingToZero
                    enableDischarge() // 2시간 경과 후 강제 방전 트리거
                } else {
                    enableCharging() // 대기 중에는 계속 100% 공급 유지
                }
            } else {
                calibrationWaitStartTime = Date()
                enableCharging()
            }
            
        case .dischargingToZero:
            // 배터리를 3% 이하까지 방전
            if pct <= 3 {
                // 3% 도달 → 방전 즉시 중단, 5시간 대기 시작
                calibrationState = .waitingFiveHoursAtZero
                calibrationWaitStartTime = Date()
                // 방전 해제 + 충전 차단 (CHIE=00, CHTE=01) → 어댑터 전원만 사용
                currentChargingState = .unknown
                setDischargeKeys(enabled: false)
                setPreventClamshellSleep(prevent: false)
                disableCharging()
            } else {
                enableDischarge()
            }
            
        case .waitingFiveHoursAtZero:
            // 방전 완료 후 5시간 대기 (충전도 방전도 하지 않는 상태)
            if let startTime = calibrationWaitStartTime {
                if Date().timeIntervalSince(startTime) >= 18000 {
                    calibrationState = .rechargingToTarget
                    enableCharging() // 5시간 대기 완료 → 충전 재개
                } else {
                    disableCharging() // 대기 중: 어댑터 전원만 사용, 충전/방전 둘 다 안 함
                }
            } else {
                calibrationWaitStartTime = Date()
                disableCharging()
            }
            
        case .rechargingToTarget:
            // 최종적으로 기존 설정된 Limit (CurrentLimit) 만큼 도달하면, 모든 교정 절차 끝!
            if pct >= currentLimit {
                self.isCalibrationModeEnabled = false
                self.calibrationState = .idle
                self.calibrationWaitStartTime = nil
                enforceBatteryLimit() // 일반 모드로 복귀
            } else {
                enableCharging()
            }
        }
    }
    
    func setChargeLimit(limit: Int) -> Bool {
        self.currentLimit = limit
        enforceBatteryLimit()
        return true
    }
    
    func getChargeLimit() -> Int {
        return self.currentLimit
    }
    
    // MARK: - 부가 기능 구현부 (Mock)
    
    func setDischargeMode(enabled: Bool) -> Bool {
        print("SMCManager Helper: Setting discharge mode to \(enabled)")
        self.isDischargeModeEnabled = enabled
        enforceBatteryLimit()
        return true
    }
    
    func setSailingMode(enabled: Bool) -> Bool {
        print("SMCManager Helper: Setting sailing mode to \(enabled)")
        self.isSailingModeEnabled = enabled
        enforceBatteryLimit()
        return true
    }
    
    func setCalibrationMode(enabled: Bool) -> Bool {
        print("SMCManager Helper: Setting calibration mode to \(enabled)")
        self.isCalibrationModeEnabled = enabled
        if enabled {
            self.calibrationState = .idle
        } else {
            self.calibrationState = .idle
            self.calibrationStateRaw = 0
            self.calibrationWaitStartTime = nil
            // 수동으로 방전 키 원복 및 충전 제어권 되돌려줌
            enableCharging() 
        }
        enforceBatteryLimit()
        return true
    }
}
