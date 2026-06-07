import Foundation

enum SMCBridgeError: Error {
    case unsupported
    case commandFailure(String)
}

private enum SMCAccessStrategy {
    case unavailable
    case iokit(IOKitSMCBridge)

    var isAvailable: Bool {
        switch self {
        case .unavailable:
            return false
        case .iokit:
            return true
        }
    }
}

protocol SMCBridging {
    var isAvailable: Bool { get }
    func readSensor(_ key: String) throws -> Double?
    func writeFanRPM(_ fanKey: String, rpm: Int) throws -> Bool
    func currentFanRPM(fanKey: String) throws -> Int
}

final class PlaceholderSMCBridge: SMCBridging {
    var isAvailable: Bool { true }

    func readSensor(_ key: String) throws -> Double? {
        switch key {
        case SMCKeyCatalog.cpuCoreTemp:
            return 55
        case SMCKeyCatalog.cpuClusterTemp:
            return 58
        case SMCKeyCatalog.gpuTemp:
            return 60
        case SMCKeyCatalog.socTemp:
            return 57
        case SMCKeyCatalog.fanMinRPM:
            return 1200
        case SMCKeyCatalog.fanMaxRPM:
            return 6200
        case SMCKeyCatalog.fanCurrentRPM:
            return Double(self.currentRPM)
        default:
            return nil
        }
    }

    func writeFanRPM(_ fanKey: String, rpm: Int) throws -> Bool {
        currentRPM = rpm
        return true
    }

    func currentFanRPM(fanKey: String) throws -> Int {
        currentRPM
    }

    private var currentRPM = 0
}

final class SystemSMCBridge: SMCBridging {
    private static let temperatureKeys: Set<String> = [
        SMCKeyCatalog.cpuCoreTemp,
        SMCKeyCatalog.cpuClusterTemp,
        SMCKeyCatalog.gpuTemp,
        SMCKeyCatalog.socTemp
    ]
    private static let fanReadSuffixes = ["Mn", "Mx", "Ac", "Tg"]

    private let access: SMCAccessStrategy

    var isAvailable: Bool { access.isAvailable }

    init() {
        if let iokitBridge = try? IOKitSMCBridge() {
            self.access = .iokit(iokitBridge)
            print("smc-access: iokit")
            return
        }
        self.access = .unavailable
        print("smc-access: unavailable")
    }

    func readSensor(_ key: String) throws -> Double? {
        let shouldReadWithSmc = Self.temperatureKeys.contains(key) || Self.fanReadSuffixes.contains(where: { key.hasSuffix($0) })
        if shouldReadWithSmc {
            switch access {
            case .iokit(let bridge):
                do {
                    let (bytes, size) = try bridge.readKey(key)
                    return decodeSMCValue(bytes, size: size, key: key)
                } catch {
                    break
                }
            case .unavailable:
                break
            }
        }
        return nil
    }

    func writeFanRPM(_ fanKey: String, rpm: Int) throws -> Bool {
        switch access {
        case .iokit(let bridge):
            let fanIndex = Self.fanIndex(from: fanKey)
            let targetKey = Self.fanTargetRPMWriteKey(for: fanKey)
            do {
                let keyInfo = try bridge.readKey(targetKey)
                let targetBytes = encodeRPM(rpm, size: keyInfo.size)
                try bridge.enableManualMode(for: fanIndex)
                try bridge.writeKey(targetKey, bytes: targetBytes)
                return true
            } catch {
                throw error
            }
        case .unavailable:
            throw SMCBridgeError.commandFailure("smc-not-found")
        }
    }

    func currentFanRPM(fanKey: String) throws -> Int {
        let readKey = Self.fanActualRPMReadKey(for: fanKey)
        guard let value = try readSensor(readKey), value > 0 else {
            throw SMCBridgeError.commandFailure("no-fan-rpm")
        }
        return Int(value)
    }

    private static func fanTargetRPMWriteKey(for fanKey: String) -> String {
        if !fanKey.hasSuffix("Ac") && !fanKey.hasSuffix("Tg") && !fanKey.hasSuffix("Mn") && !fanKey.hasSuffix("Mx") {
            return fanKey
        }
        return SMCKeyCatalog.fanTargetRPMKey(for: fanIndex(from: fanKey))
    }

    private static func fanActualRPMReadKey(for fanKey: String) -> String {
        return SMCKeyCatalog.fanCurrentRPMKey(for: fanIndex(from: fanKey))
    }

    private static func fanIndex(from key: String) -> Int {
        guard key.hasPrefix("F"), key.count >= 2 else { return 0 }
        let numeric = key.dropFirst().prefix { $0.isNumber }
        return Int(numeric) ?? 0
    }

    private func decodeSMCValue(_ bytes: [UInt8], size: UInt32, key: String) -> Double? {
        if bytes.isEmpty || size == 0 {
            return nil
        }
        let actualSize = min(bytes.count, Int(size))
        let sample = Array(bytes.prefix(actualSize))
        if actualSize == 2 {
            let raw = sample.withUnsafeBytes {
                $0.loadUnaligned(as: UInt16.self)
            }.bigEndian
            if Self.temperatureKeys.contains(key) {
                return Double(Int16(bitPattern: raw)) / 256.0
            }
            return Double(raw) / 4.0
        }
        if actualSize == 4 {
            let value = sample.withUnsafeBytes {
                $0.loadUnaligned(as: Float.self)
            }
            return Double(value)
        }
        if actualSize == 1 {
            return Double(sample[0])
        }
        return nil
    }

    private func encodeRPM(_ rpm: Int, size: UInt32) -> [UInt8] {
        let clamped = max(0, min(30000, rpm))
        if size == 2 {
            let value = UInt16(min(Int(UInt16.max), clamped * 4))
            return [UInt8(value >> 8), UInt8(value & 0xFF)]
        }
        if size == 4 {
            var value = Float(clamped)
            return withUnsafeBytes(of: &value) { Array($0) }
        }
        if size == 1 {
            return [UInt8(clamped)]
        }
        var value = UInt32(clamped)
        return withUnsafeBytes(of: &value) { raw in
            Array(raw.prefix(4))
        }
    }

    // TODO: future enhancement: structured temperature fallback source can be added
    // using a dedicated non-invasive provider.
}
