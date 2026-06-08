import XCTest
import MFanControlShared
@testable import MFanControlHelperCore

final class SystemSMCBridgeWriteTests: XCTestCase {
    private final class ManualModeGatedBackend: SMCFanWriteBackend {
        enum Event: Equatable {
            case manual(Int)
            case metadata(String)
            case write(String)
        }

        private(set) var events: [Event] = []
        private var manualEnabled = false

        func keyMetadata(for key: String) throws -> SMCKeyMetadata {
            events.append(.metadata(key))
            guard manualEnabled else {
                throw SMCBridgeError.commandFailure("metadata-requires-manual-mode")
            }
            guard key == "F0Tg" else {
                throw SMCBridgeError.commandFailure("unsupported-key:\(key)")
            }
            return SMCKeyMetadata(key: key, size: 2, dataType: 0x75313620, dataTypeCode: "u16")
        }

        func enableManualMode(for fanIndex: Int) throws {
            events.append(.manual(fanIndex))
            manualEnabled = true
        }

        func writeKey(_ key: String, bytes: [UInt8], sizeHint: UInt32?) throws {
            events.append(.write(key))
            _ = sizeHint
            XCTAssertFalse(bytes.isEmpty)
        }
    }

    func testWriteFanRPMEnablesManualModeBeforeMetadataLookup() throws {
        let backend = ManualModeGatedBackend()

        let success = try SystemSMCBridge.writeFanRPM(
            using: backend,
            fanIndex: 0,
            fanKey: "F0Tg",
            rpm: 1800
        )

        XCTAssertTrue(success)
        XCTAssertEqual(
            backend.events.prefix(3),
            [
                .manual(0),
                .metadata("F0Tg"),
                .write("F0Tg")
            ]
        )
    }
}
