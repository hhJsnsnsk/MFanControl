import Foundation
import IOKit
import MFanControlShared

enum SMCIOResult: Error {
    case unsupported
}

public struct SMCKeyMetadata: Sendable {
    public let key: String
    public let size: UInt32
    public let dataType: UInt32
    public let dataTypeCode: String

    public init(key: String, size: UInt32, dataType: UInt32, dataTypeCode: String) {
        self.key = key
        self.size = size
        self.dataType = dataType
        self.dataTypeCode = dataTypeCode
    }
}

private enum SMCIOCommand: UInt8 {
    case kernelIndex = 2
    case readBytes = 5
    case writeBytes = 6
    case readIndex = 8
    case readKeyInfo = 9
}

private enum SMCIOResultCode: UInt8, Error {
    case success = 0x00
    case error = 0x01
    case badCommand = 0x82
    case badParameter = 0x83
    case notFound = 0x84
    case notReadable = 0x85
    case notWritable = 0x86
    case keySizeMismatch = 0x87
    case framingError = 0x88
    case badArgumentError = 0x89
}

private struct SMCIOParamStruct {
    public typealias Bytes32 = (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
    )

    public struct Version {
        public var major: UInt8 = 0
        public var minor: UInt8 = 0
        public var build: UInt8 = 0
        public var reserved: UInt8 = 0
        public var release: UInt16 = 0
        public init() {}
    }

    public struct PowerLimits {
        public var version: UInt16 = 0
        public var length: UInt16 = 0
        public var cpuPowerLimit: UInt32 = 0
        public var gpuPowerLimit: UInt32 = 0
        public var memPowerLimit: UInt32 = 0
        public init() {}
    }

    public struct KeyInfo {
        public var dataSize: UInt32 = 0
        public var dataType: UInt32 = 0
        public var dataAttributes: UInt8 = 0
        public init() {}
    }

    public var key: UInt32 = 0
    public var version = Version()
    public var powerLimits = PowerLimits()
    public var keyInfo = KeyInfo()
    public var padding: UInt16 = 0
    public var result: UInt8 = 0
    public var status: UInt8 = 0
    public var data8: UInt8 = 0
    public var data32: UInt32 = 0
    public var bytes: Bytes32 = (
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0
    )

    public init() {}
}

final class IOKitSMCBridge {
    private let connection: io_connect_t
    private let fallbackConnection: io_connect_t?
    private let modeKeyFormat: String
    private let forceTestAvailable: Bool

    init() throws {
        let (openedConnection, openedClientType) = try SMCConnection.openWithClientType(preferredClientTypes: [1, 0])
        let fallbackConnection = openedClientType == 1 ? (try? SMCConnection.openClientType(0)) : nil
        let forceTestAvailable = (try? Self.readKey(connection: openedConnection, key: "Ftst")) != nil
        let modeKeyFormat = Self.detectModeKey(using: openedConnection)
        connection = openedConnection
        self.fallbackConnection = fallbackConnection
        self.forceTestAvailable = forceTestAvailable
        self.modeKeyFormat = modeKeyFormat
    }

    deinit {
        IOServiceClose(connection)
        if let fallbackConnection {
            IOServiceClose(fallbackConnection)
        }
    }

    func readKey(_ key: String) throws -> (bytes: [UInt8], size: UInt32) {
        let info = try fetchKeyInfo(for: key)
        var command = info
        command.data8 = SMCIOCommand.readBytes.rawValue
        command.keyInfo.dataSize = info.keyInfo.dataSize
        let output = try call(command)
        if let code = SMCIOResultCode(rawValue: output.result), code != .success {
            throw SMCBridgeError.commandFailure("iokit-read-failed:\(code)")
        }
        return (bytes: tupleToBytes(output.bytes), size: output.keyInfo.dataSize)
    }

    func writeKey(_ key: String, bytes: [UInt8], sizeHint: UInt32? = nil) throws {
        do {
            try writeKey(key, bytes: bytes, sizeHint: sizeHint, on: connection)
            return
        } catch {
            guard let fallbackConnection else {
                throw error
            }
            try writeKey(key, bytes: bytes, sizeHint: sizeHint, on: fallbackConnection)
        }
    }

    private func writeKey(_ key: String, bytes: [UInt8], sizeHint: UInt32?, on connection: io_connect_t) throws {
        var info: SMCIOParamStruct
        if let sizeHint {
            info = SMCIOParamStruct()
            info.keyInfo.dataSize = sizeHint
        } else {
            info = try fetchKeyInfo(for: key)
        }
        var command = info
        command.key = try Self.fourCharacterCode(from: key)
        command.data8 = SMCIOCommand.writeBytes.rawValue
        command.keyInfo.dataSize = info.keyInfo.dataSize
        guard Int(info.keyInfo.dataSize) <= 32 else {
            throw SMCBridgeError.commandFailure("iokit-unsupported-bytesize:\(info.keyInfo.dataSize)")
        }
        command.bytes = bytesToTuple(bytes, count: Int(info.keyInfo.dataSize))
        let output = try call(command, connection: connection)
        if let code = SMCIOResultCode(rawValue: output.result), code != .success {
            throw SMCBridgeError.commandFailure("iokit-write-failed:\(code)")
        }
        if output.result != 0 && output.result != SMCIOResultCode.success.rawValue {
            throw SMCBridgeError.commandFailure("iokit-write-result:\(output.result)")
        }
    }

    func keyMetadata(for key: String) throws -> SMCKeyMetadata {
        let info = try fetchKeyInfo(for: key)
        return SMCKeyMetadata(
            key: key,
            size: info.keyInfo.dataSize,
            dataType: info.keyInfo.dataType,
            dataTypeCode: Self.decodeDataType(info.keyInfo.dataType)
        )
    }

    func disableManualMode(for fanIndex: Int) {
        let modeKey = String(format: modeKeyFormat, fanIndex)
        let offPayloads: [([UInt8], UInt32)] = [([0], 1), ([0], 2), ([0, 0], 2)]
        for (bytes, sizeHint) in offPayloads {
            if (try? writeKey(modeKey, bytes: bytes, sizeHint: sizeHint)) != nil {
                MFanLogger.log("smc manual mode disabled fan=\(fanIndex) key=\(modeKey)")
                return
            }
        }
        MFanLogger.log("smc manual mode disable failed fan=\(fanIndex) key=\(modeKey) — macOS will reclaim control on next tick")
    }

    func enableManualMode(for fanIndex: Int) throws {
        let modeKey = String(format: modeKeyFormat, fanIndex)
        let directPayloads: [([UInt8], UInt32)] = [
            ([1], 1),
            ([1], 2),
            ([0, 1], 2),
            ([1, 0], 2)
        ]

        func tryDirectWrite(_ key: String) -> Error? {
            var lastError: Error?
            for (bytes, sizeHint) in directPayloads {
                do {
                    try writeKey(key, bytes: bytes, sizeHint: sizeHint)
                    return nil
                } catch {
                    lastError = error
                }
            }
            return lastError
        }

        MFanLogger.log("smc manual unlock direct attempt fan=\(fanIndex) key=\(modeKey)")
        if tryDirectWrite(modeKey) == nil {
            MFanLogger.log("smc manual unlock direct success fan=\(fanIndex) key=\(modeKey)")
            return
        }

        MFanLogger.log("smc manual unlock direct failed fan=\(fanIndex) key=\(modeKey)")
        MFanLogger.log("smc manual unlock ftst attempt fan=\(fanIndex)")
        let ftstError = tryDirectWrite("Ftst")
        if let ftstError {
            MFanLogger.log("smc manual unlock ftst failed fan=\(fanIndex) error=\(ftstError)")
            throw ftstError
        }

        Thread.sleep(forTimeInterval: 0.5)
        let deadline = Date().addingTimeInterval(10.0)
        var attempt = 0
        while true {
            attempt += 1
            MFanLogger.log("smc manual unlock retry fan=\(fanIndex) key=\(modeKey) attempt=\(attempt)")
            if tryDirectWrite(modeKey) == nil {
                MFanLogger.log("smc manual unlock retry success fan=\(fanIndex) key=\(modeKey) attempt=\(attempt)")
                return
            }
            if Date() >= deadline {
                MFanLogger.log("smc manual unlock timeout fan=\(fanIndex) key=\(modeKey) attempts=\(attempt)")
                throw SMCBridgeError.commandFailure("iokit-ftst-timeout")
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    func resetManualMode() throws {
        if forceTestAvailable {
            let payloads: [([UInt8], UInt32)] = [
                ([0], 1),
                ([0], 2),
                ([0, 0], 2)
            ]
            for (bytes, sizeHint) in payloads {
                if (try? writeKey("Ftst", bytes: bytes, sizeHint: sizeHint)) != nil {
                    return
                }
            }
            try writeKey("Ftst", bytes: [0], sizeHint: 1)
        }
    }

    private func fetchKeyInfo(for key: String) throws -> SMCIOParamStruct {
        return try Self.fetchKeyInfo(connection: connection, for: key)
    }

    private static func fetchKeyInfo(connection: io_connect_t, for key: String) throws -> SMCIOParamStruct {
        var request = SMCIOParamStruct()
        request.key = try Self.fourCharacterCode(from: key)
        request.data8 = SMCIOCommand.readKeyInfo.rawValue
        let output = try Self.call(connection: connection, input: request)
        guard output.result == SMCIOResultCode.success.rawValue else {
            throw SMCBridgeError.commandFailure("iokit-keyinfo-failed:\(output.result)")
        }
        return output
    }

    private func call(_ input: SMCIOParamStruct) throws -> SMCIOParamStruct {
        return try Self.call(connection: connection, input: input)
    }

    private func call(_ input: SMCIOParamStruct, connection: io_connect_t) throws -> SMCIOParamStruct {
        return try Self.call(connection: connection, input: input)
    }

    private static func call(connection: io_connect_t, input: SMCIOParamStruct) throws -> SMCIOParamStruct {
        precondition(MemoryLayout<SMCIOParamStruct>.stride == 80, "SMCIOParamStruct must match AppleSMC's 80-byte contract")
        var inputStruct = input
        var outputStruct = SMCIOParamStruct()
        var outputSize = MemoryLayout<SMCIOParamStruct>.stride
        let result = IOConnectCallStructMethod(
            connection,
            UInt32(SMCIOCommand.kernelIndex.rawValue),
            &inputStruct,
            MemoryLayout<SMCIOParamStruct>.stride,
            &outputStruct,
            &outputSize
        )
        guard result == kIOReturnSuccess else {
            throw SMCBridgeError.commandFailure("iokit-call-failed:0x\(String(format: "%x", result))")
        }
        return outputStruct
    }

    private func detectModeKey() -> String {
        return Self.detectModeKey(using: connection)
    }

    private static func detectModeKey(using connection: io_connect_t) -> String {
        if (try? fetchKeyInfo(connection: connection, for: "F0md")) != nil {
            return "F%dmd"
        }
        if (try? fetchKeyInfo(connection: connection, for: "F0Md")) != nil {
            return "F%dMd"
        }
        return "F%dMd"
    }

    private func bytesToTuple(_ bytes: [UInt8], count: Int) -> SMCIOParamStruct.Bytes32 {
        var padded = bytes + Array(repeating: 0, count: max(0, 32 - bytes.count))
        if padded.count > 32 {
            padded = Array(padded.prefix(32))
        }
        _ = count
        var tupleBytes = SMCIOParamStruct.Bytes32(
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0
        )

        withUnsafeMutableBytes(of: &tupleBytes) { bytes32 in
            let source = Data(padded).prefix(32)
            source.withUnsafeBytes { bytes32.copyBytes(from: $0) }
        }
        let tuple = tupleBytes
        return tuple
    }

    private func tupleToBytes(_ bytes: SMCIOParamStruct.Bytes32) -> [UInt8] {
        return withUnsafeBytes(of: bytes) { raw in
            Array(raw)
        }
    }

    private func fourCharacterCode(from key: String) throws -> UInt32 {
        try Self.fourCharacterCode(from: key)
    }

    private static func fourCharacterCode(from key: String) throws -> UInt32 {
        guard key.utf8.count == 4 else {
            throw SMCBridgeError.commandFailure("invalid-smc-key:\(key)")
        }
        return key.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }
}

extension IOKitSMCBridge: SMCFanWriteBackend {}

extension IOKitSMCBridge {
    private static func readKey(connection: io_connect_t, key: String) throws -> (bytes: [UInt8], size: UInt32) {
        let info = try fetchKeyInfo(connection: connection, for: key)
        var command = info
        command.data8 = SMCIOCommand.readBytes.rawValue
        command.keyInfo.dataSize = info.keyInfo.dataSize
        let output = try call(connection: connection, input: command)
        if let code = SMCIOResultCode(rawValue: output.result), code != .success {
            throw SMCBridgeError.commandFailure("iokit-read-failed:\(code)")
        }
        return (bytes: tupleToBytes(output.bytes), size: output.keyInfo.dataSize)
    }

    private static func tupleToBytes(_ bytes: SMCIOParamStruct.Bytes32) -> [UInt8] {
        return withUnsafeBytes(of: bytes) { raw in
            Array(raw)
        }
    }

    private static func decodeDataType(_ rawType: UInt32) -> String {
        let candidates = [rawType, rawType.byteSwapped]
        for typeValue in candidates {
            let bytes = [
                UInt8((typeValue >> 24) & 0xFF),
                UInt8((typeValue >> 16) & 0xFF),
                UInt8((typeValue >> 8) & 0xFF),
                UInt8(typeValue & 0xFF)
            ]
            let decoded = String(bytes: bytes, encoding: .ascii)?
                .trimmingCharacters(in: .controlCharacters)
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            if let decoded, !decoded.isEmpty,
               decoded.utf8.allSatisfy({ $0 >= 0x20 && $0 <= 0x7E }) {
                return decoded
            }
        }
        return String(format: "0x%08x", rawType)
    }
}

private enum SMCConnection {
    static func open() throws -> io_connect_t {
        return try Self.openWithClientType(preferredClientTypes: [1, 0]).0
    }

    static func openClientType(_ clientType: UInt32) throws -> io_connect_t {
        return try openWithClientType(preferredClientTypes: [clientType]).0
    }

    static func openWithClientType(preferredClientTypes: [UInt32]) throws -> (io_connect_t, UInt32) {
        var iterator: io_iterator_t = 0
        let services = IOServiceMatching("AppleSMC")
        guard let services else {
            throw SMCIOResult.unsupported
        }
        guard IOServiceGetMatchingServices(kIOMainPortDefault, services, &iterator) == kIOReturnSuccess else {
            IOObjectRelease(iterator)
            throw SMCIOResult.unsupported
        }
        defer { IOObjectRelease(iterator) }

        let service = IOIteratorNext(iterator)
        guard service != 0 else {
            throw SMCIOResult.unsupported
        }
        defer { IOObjectRelease(service) }

        var con: io_connect_t = 0
        let clientTypeOrder = preferredClientTypes.isEmpty ? [1, 0] : preferredClientTypes
        for clientType in clientTypeOrder {
            let result = IOServiceOpen(service, mach_task_self_, clientType, &con)
            if result == kIOReturnSuccess {
                MFanLogger.log("smc-open client-type: \(clientType)")
                return (con, clientType)
            }
            MFanLogger.log("smc-open client-type \(clientType) failed: \(result)")
        }
        throw SMCIOResult.unsupported
    }
}
