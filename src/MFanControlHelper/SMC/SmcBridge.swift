import Foundation

protocol SMCBridging {
    func readSensor(_ key: String) throws -> Double?
    func writeFanRPM(_ fan: Int, rpm: Int) throws -> Bool
    func currentFanRPM(fan: Int) throws -> Int
}

final class PlaceholderSMCBridge: SMCBridging {
    func readSensor(_ key: String) throws -> Double? { nil }
    func writeFanRPM(_ fan: Int, rpm: Int) throws -> Bool { true }
    func currentFanRPM(fan: Int) throws -> Int { 0 }
}
