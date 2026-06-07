import Foundation
import IOKit

enum SMCIOResult: Error {
    case unsupported
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
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8
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
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0
    )

    public init() {}
}

final class IOKitSMCBridge {
    private let connection: io_connect_t
    private let modeKeyFormat: String
    private let forceTestAvailable: Bool

    init() throws {
        let openedConnection = try SMCConnection.open()
        let forceTestAvailable = (try? Self.readKey(connection: openedConnection, key: "Ftst")) != nil
        let modeKeyFormat = Self.detectModeKey(using: openedConnection)
        connection = openedConnection
        self.forceTestAvailable = forceTestAvailable
        self.modeKeyFormat = modeKeyFormat
    }

    deinit {
        IOServiceClose(connection)
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

    func writeKey(_ key: String, bytes: [UInt8]) throws {
        let info = try fetchKeyInfo(for: key)
        var command = info
        command.data8 = SMCIOCommand.writeBytes.rawValue
        command.keyInfo.dataSize = info.keyInfo.dataSize
        guard Int(info.keyInfo.dataSize) <= 32 else {
            throw SMCBridgeError.commandFailure("iokit-unsupported-bytesize:\(info.keyInfo.dataSize)")
        }
        command.bytes = bytesToTuple(bytes, count: Int(info.keyInfo.dataSize))
        let output = try call(command)
        if let code = SMCIOResultCode(rawValue: output.result), code != .success {
            throw SMCBridgeError.commandFailure("iokit-write-failed:\(code)")
        }
        if output.result != 0 && output.result != SMCIOResultCode.success.rawValue {
            throw SMCBridgeError.commandFailure("iokit-write-result:\(output.result)")
        }
    }

    func enableManualMode(for fanIndex: Int) throws {
        let modeKey = String(format: modeKeyFormat, fanIndex)
        do {
            try writeKey(modeKey, bytes: [1])
            return
        } catch {
            guard forceTestAvailable else {
                throw error
            }
        }

        try writeKey("Ftst", bytes: [1])
        Thread.sleep(forTimeInterval: 0.5)

        let timeout = Date().addingTimeInterval(10.0)
        var lastError: Error?
        for _ in 0..<100 {
            do {
                try writeKey(modeKey, bytes: [1])
                return
            } catch {
                lastError = error
                if Date() > timeout {
                    throw lastError ?? SMCBridgeError.commandFailure("iokit-ftst-timeout")
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        throw lastError ?? SMCBridgeError.commandFailure("iokit-ftst-timeout")
    }

    func resetManualMode() throws {
        if forceTestAvailable {
            try writeKey("Ftst", bytes: [0])
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

    private static func call(connection: io_connect_t, input: SMCIOParamStruct) throws -> SMCIOParamStruct {
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
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0
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
}

private enum SMCConnection {
    static func open() throws -> io_connect_t {
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
        let clientTypeOrder: [UInt32] = [0, 1]
        for clientType in clientTypeOrder {
            let result = IOServiceOpen(service, mach_task_self_, clientType, &con)
            if result == kIOReturnSuccess {
                print("smc-open client-type: \(clientType)")
                return con
            }
            print("smc-open client-type \(clientType) failed: \(result)")
        }
        throw SMCIOResult.unsupported
    }
}
