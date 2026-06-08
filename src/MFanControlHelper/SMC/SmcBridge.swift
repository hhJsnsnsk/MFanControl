import Foundation
import MFanControlShared

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
    func keyMetadata(for key: String) throws -> SMCKeyMetadata
    func releaseManualControl(fanCount: Int)
}

protocol SMCFanWriteBackend {
    func keyMetadata(for key: String) throws -> SMCKeyMetadata
    func enableManualMode(for fanIndex: Int) throws
    func writeKey(_ key: String, bytes: [UInt8], sizeHint: UInt32?) throws
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

    func keyMetadata(for key: String) throws -> SMCKeyMetadata {
        .init(key: key, size: 2, dataType: 0, dataTypeCode: "u16")
    }

    func writeKey(_ key: String, bytes: [UInt8], sizeHint: UInt32?) throws {
        _ = key
        _ = sizeHint
        currentRPM = bytes.first.map { Int($0) } ?? currentRPM
    }

    func releaseManualControl(fanCount: Int) {
        currentRPM = 0
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
            MFanLogger.log("smc-access: iokit")
            return
        }
        self.access = .unavailable
        MFanLogger.log("smc-access: unavailable")
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
            return try Self.writeFanRPM(using: bridge, fanIndex: fanIndex, fanKey: fanKey, rpm: rpm)
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

    func keyMetadata(for key: String) throws -> SMCKeyMetadata {
        guard case .iokit(let bridge) = access else {
            throw SMCBridgeError.commandFailure("smc-bridge-missing")
        }
        return try bridge.keyMetadata(for: key)
    }

    func releaseManualControl(fanCount: Int) {
        guard case .iokit(let bridge) = access else { return }
        for fan in 0..<max(1, fanCount) {
            bridge.disableManualMode(for: fan)
        }
        MFanLogger.log("smc manual control released for \(fanCount) fans")
    }

    private static func fanTargetRPMWriteKey(for fanKey: String) -> String {
        if !fanKey.hasSuffix("Ac") && !fanKey.hasSuffix("Tg") && !fanKey.hasSuffix("Mn") && !fanKey.hasSuffix("Mx") {
            return fanKey
        }
        return SMCKeyCatalog.fanTargetRPMKey(for: fanIndex(from: fanKey))
    }

    private static func fanTargetRPMWriteKeys(for fanIndex: Int) -> [String] {
        let normalized = max(0, fanIndex)
        let primary = fanTargetRPMWriteKey(for: "F\(normalized)Ac")
        var unique = [primary]
        let secondary = SMCKeyCatalog.fanTargetRPMKey(for: normalized)
        if !unique.contains(secondary) {
            unique.append(secondary)
        }
        let suffixes: [String] = ["Tp", "Md", "md"]
        for suffix in suffixes {
            let candidate = "F\(normalized)\(suffix)"
            if !unique.contains(candidate) {
                unique.append(candidate)
            }
        }
        let current = SMCKeyCatalog.fanCurrentRPMKey(for: normalized)
        if !unique.contains(current) {
            unique.append(current)
        }
        return unique
    }

    private static func fanActualRPMReadKey(for fanKey: String) -> String {
        return SMCKeyCatalog.fanCurrentRPMKey(for: fanIndex(from: fanKey))
    }

    static func writeFanRPM(
        using backend: SMCFanWriteBackend,
        fanIndex: Int,
        fanKey: String,
        rpm: Int
    ) throws -> Bool {
        let candidateKeys = fanTargetRPMWriteKeys(for: fanIndex)
        var lastFailure: Error?
        for targetKey in candidateKeys {
            do {
                do {
                    try backend.enableManualMode(for: fanIndex)
                } catch {
                    // Some systems expose writable target fan keys without manual mode flip.
                    // Keep best-effort behavior for compatibility with such devices.
                    MFanLogger.log("smc write: manual mode enable skipped for fanIndex=\(fanIndex): \(error)")
                }

                let keyInfo = try backend.keyMetadata(for: targetKey)
                MFanLogger.log("smc write target probe key=\(targetKey) size=\(keyInfo.size) type=\(keyInfo.dataTypeCode)")
                let candidatePayloads = Self.encodeRPMCandidates(
                    rpm,
                    size: keyInfo.size,
                    dataType: keyInfo.dataTypeCode
                )
                var lastError: Error?
                for payload in candidatePayloads {
                    do {
                        try backend.writeKey(targetKey, bytes: payload, sizeHint: keyInfo.size)
                        MFanLogger.log("smc write success target=\(targetKey) fanIndex=\(fanIndex) payload=\(payloadHex(payload))")
                        if targetKey != fanKey {
                            MFanLogger.log("smc write success using fallback key=\(targetKey) fanIndex=\(fanIndex)")
                        }
                        return true
                    } catch {
                        lastError = error
                        lastFailure = error
                        MFanLogger.log("smc write payload failed fan=\(fanIndex) key=\(targetKey) payload=\(payloadHex(payload)) error=\(error)")
                    }
                }
                if let lastError {
                    MFanLogger.log("smc write target failed for fanIndex=\(fanIndex), key=\(targetKey): \(lastError)")
                }
                continue
            } catch {
                lastFailure = error
                MFanLogger.log("smc write target metadata failed fanIndex=\(fanIndex), key=\(targetKey): \(error)")
                for fallbackSize in [UInt32(2), 4] {
                    MFanLogger.log("smc write fallback size fan=\(fanIndex) key=\(targetKey) size=\(fallbackSize)")
                    let fallbackPayloads = Self.encodeRPMCandidates(rpm, size: fallbackSize, dataType: "")
                    for payload in fallbackPayloads {
                        do {
                            MFanLogger.log("smc write fallback attempt fan=\(fanIndex) key=\(targetKey) size=\(fallbackSize) payload=\(payloadHex(payload))")
                            try backend.writeKey(targetKey, bytes: payload, sizeHint: fallbackSize)
                            MFanLogger.log("smc write success target=\(targetKey) fanIndex=\(fanIndex) payload=\(payloadHex(payload))")
                            if targetKey != fanKey {
                                MFanLogger.log("smc write success using fallback key=\(targetKey) fanIndex=\(fanIndex)")
                            }
                            return true
                        } catch {
                            lastFailure = error
                            MFanLogger.log("smc write fallback failed fan=\(fanIndex) key=\(targetKey) size=\(fallbackSize) payload=\(payloadHex(payload)) error=\(error)")
                            continue
                        }
                    }
                }
            }
        }
        if let lastFailure {
            throw SMCBridgeError.commandFailure("smc-write-target-unavailable-fan\(fanIndex):\(lastFailure)")
        }
        throw SMCBridgeError.commandFailure("smc-write-target-unavailable-fan\(fanIndex)")
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

    private static func encodeRPMCandidates(_ rpm: Int, size: UInt32, dataType: String) -> [[UInt8]] {
        let clamped = max(0, min(30000, rpm))
        if size == 2 {
            var payloads: Set<String> = []
            let scales: [Double] = Self.dataTypeScales(for: dataType.lowercased(), size: 2)

            for scale in scales {
                let scaled = Int(Double(clamped) * scale)
                let candidate = clampIntToUInt16(scaled)
                payloads.insert(payloadHex(encodeUInt16BE(candidate)))
                payloads.insert(payloadHex(encodeUInt16LE(candidate)))
            }

            payloads.insert(payloadHex(encodeUInt16BE(clampIntToUInt16(clamped))))
            payloads.insert(payloadHex(encodeUInt16LE(clampIntToUInt16(clamped))))
            payloads.insert(payloadHex(encodeUInt16BE(clampIntToUInt16(clamped * 4))))
            payloads.insert(payloadHex(encodeUInt16LE(clampIntToUInt16(clamped * 4))))

            return payloads
                .compactMap { decodeHexPayload($0) }
        }
        if size == 4 {
            var payloads: Set<String> = []
            let scales: [Double] = Self.dataTypeScales(for: dataType.lowercased(), size: 4)

            for scale in scales {
                let scaled = Int(Double(clamped) * scale)
                payloads.insert(payloadHex(encodeUInt32BE(clampIntToUInt32(scaled))))
                payloads.insert(payloadHex(encodeUInt32LE(clampIntToUInt32(scaled))))

                let asFloat = Float(max(0, min(Double(clamped) * scale, Double(Float.greatestFiniteMagnitude))))
                payloads.insert(payloadHex(encodeFloatLE(asFloat)))
                payloads.insert(payloadHex(encodeFloatBE(asFloat)))
                payloads.insert(payloadHex(encodeFloatLE(Float(max(0, Double(clamped) / max(scale, 1))))))
                payloads.insert(payloadHex(encodeFloatBE(Float(max(0, Double(clamped) / max(scale, 1))))))
            }
            return payloads.compactMap { decodeHexPayload($0) }
        }
        if size == 1 {
            return [[UInt8(clamped)]]
        }
        return [
            encodeUInt32LE(clampIntToUInt32(clamped)),
            encodeUInt32BE(clampIntToUInt32(clamped))
        ]
    }

    private static func dataTypeScales(for dataType: String, size: Int) -> [Double] {
        if dataType.isEmpty {
            return size == 2 ? [1, 4, 16, 64] : [1, 1/4, 4]
        }
        if dataType == "sp78" || dataType == "sp" {
            return size == 2 ? [1, 4, 16, 64, 256, 1 / 4] : [1, 1 / 4]
        }
        if dataType == "fpe2" || dataType.contains("fpe") {
            return size == 2 ? [4, 16, 256, 65536] : [1, 4, 16, 256]
        }
        if size == 4 {
            return [1, 4, 16, 1 / 4, 1 / 16]
        }
        return [1, 4, 16, 64]
    }

    private static func clampIntToUInt16(_ value: Int) -> UInt16 {
        UInt16(max(0, min(Int(UInt16.max), value)))
    }

    private static func clampIntToUInt32(_ value: Int) -> UInt32 {
        UInt32(max(0, min(Int(UInt32.max), value)))
    }

    private static func encodeUInt16BE(_ value: UInt16) -> [UInt8] {
        let data = value.bigEndian
        return [UInt8(data >> 8), UInt8(data & 0xFF)]
    }

    private static func encodeUInt16LE(_ value: UInt16) -> [UInt8] {
        let data = value.littleEndian
        return [UInt8(data & 0xFF), UInt8((data >> 8) & 0xFF)]
    }

    private static func encodeUInt32BE(_ value: UInt32) -> [UInt8] {
        [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    private static func encodeUInt32LE(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)]
    }

    private static func encodeFloatBE(_ value: Float) -> [UInt8] {
        var copy = value
        let raw = Array(withUnsafeBytes(of: &copy) { Array($0) })
        return Array(raw.prefix(4))
    }

    private static func encodeFloatLE(_ value: Float) -> [UInt8] {
        var copy = value
        let raw = Array(withUnsafeBytes(of: &copy) { Array($0) })
        return Array(raw.prefix(4))
    }

    private static func payloadHex(_ payload: [UInt8]) -> String {
        payload.map { String(format: "%02x", $0) }.joined()
    }

    private static func decodeHexPayload(_ text: String) -> [UInt8]? {
        guard text.count.isMultiple(of: 2), !text.isEmpty else { return nil }
        var bytes: [UInt8] = []
        var index = text.startIndex
        for _ in 0..<text.count / 2 {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    // TODO: future enhancement: structured temperature fallback source can be added
    // using a dedicated non-invasive provider.
}
