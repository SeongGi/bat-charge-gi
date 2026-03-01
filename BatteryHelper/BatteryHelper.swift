import Foundation

class BatteryHelperDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: BatteryHelperProtocol.self)
        newConnection.exportedObject = BatteryHelper()
        newConnection.resume()
        return true
    }
}

class BatteryHelper: NSObject, BatteryHelperProtocol {
    func setChargeLimit(limit: Int, withReply reply: @escaping (Bool, String?) -> Void) {
        let success = SMCManager.shared.setChargeLimit(limit: limit)
        reply(success, success ? nil : "Failed to set charge limit via SMC")
    }
    
    func getChargeLimit(withReply reply: @escaping (Int, String?) -> Void) {
        let limit = SMCManager.shared.getChargeLimit()
        reply(limit, nil)
    }
    
    func setDischargeMode(enabled: Bool, withReply reply: @escaping (Bool, String?) -> Void) {
        let success = SMCManager.shared.setDischargeMode(enabled: enabled)
        reply(success, success ? nil : "Failed to set discharge mode")
    }
    
    func getDischargeMode(withReply reply: @escaping (Bool, String?) -> Void) {
        reply(SMCManager.shared.isDischargeModeEnabled, nil)
    }
    
    func setSailingMode(enabled: Bool, withReply reply: @escaping (Bool, String?) -> Void) {
        let success = SMCManager.shared.setSailingMode(enabled: enabled)
        reply(success, success ? nil : "Failed to set sailing mode")
    }
    
    func getSailingMode(withReply reply: @escaping (Bool, String?) -> Void) {
        reply(SMCManager.shared.isSailingModeEnabled, nil)
    }
    
    func setCalibrationMode(enabled: Bool, withReply reply: @escaping (Bool, String?) -> Void) {
        let success = SMCManager.shared.setCalibrationMode(enabled: enabled)
        reply(success, success ? nil : "Failed to set calibration mode")
    }
    
    func getCalibrationMode(withReply reply: @escaping (Bool, String?) -> Void) {
        reply(SMCManager.shared.isCalibrationModeEnabled, nil)
    }
    
    // 고급 전력 히스토리 내역
    func getLastFullChargeDate(withReply reply: @escaping (Date?, String?) -> Void) {
        let dateInt = UserDefaults.standard.integer(forKey: "lastFullChargeDate")
        let date = dateInt > 0 ? Date(timeIntervalSince1970: TimeInterval(dateInt)) : nil
        reply(date, nil)
    }
    
    func getLastDischargeStartDate(withReply reply: @escaping (Date?, String?) -> Void) {
        let dateInt = UserDefaults.standard.integer(forKey: "lastDischargeStartDate")
        let date = dateInt > 0 ? Date(timeIntervalSince1970: TimeInterval(dateInt)) : nil
        reply(date, nil)
    }
}
