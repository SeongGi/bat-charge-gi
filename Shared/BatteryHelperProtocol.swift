import Foundation

@objc protocol BatteryHelperProtocol {
    func setChargeLimit(limit: Int, withReply reply: @escaping (Bool, String?) -> Void)
    func getChargeLimit(withReply reply: @escaping (Int, String?) -> Void)
    
    // 부가 기능 제어 (향후 확장용)
    // 방전: 물리적으로 충전을 막고 배터리를 소모시킴
    func setDischargeMode(enabled: Bool, withReply reply: @escaping (Bool, String?) -> Void)
    func getDischargeMode(withReply reply: @escaping (Bool, String?) -> Void)
    
    // 항해 모드: 타겟 설정 %이하(기본 -5%)로 떨어지기 전까지는 충전을 재개하지 않음
    func setSailingMode(enabled: Bool, withReply reply: @escaping (Bool, String?) -> Void)
    func getSailingMode(withReply reply: @escaping (Bool, String?) -> Void)
    
    // 교정 모드: 100% -> 방전 -> 100% 한 사이클을 강제하여 배터리 혼동 리셋
    func setCalibrationMode(enabled: Bool, withReply reply: @escaping (Bool, String?) -> Void)
    func getCalibrationMode(withReply reply: @escaping (Bool, String?) -> Void)
    
    // 고급 전력 히스토리 내역
    func getLastFullChargeDate(withReply reply: @escaping (Date?, String?) -> Void)
    func getLastDischargeStartDate(withReply reply: @escaping (Date?, String?) -> Void)
}
