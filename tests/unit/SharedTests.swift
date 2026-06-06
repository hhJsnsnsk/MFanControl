import XCTest
import MFanControlShared

final class SharedTests: XCTestCase {
    func testThermalScoreInit() {
        let score = ThermalScore(value: 42.0)
        XCTAssertEqual(score.value, 42.0)
    }
}
