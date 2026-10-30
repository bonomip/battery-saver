import XCTest
import SMCBridge

final class BridgeTests: XCTestCase {
    func testArbitrarySMCWritesRejectedWithoutOpeningHardware() {
        var bytes: UInt8 = 0
        XCTAssertEqual(bs_smc_write(0, "F0Tg", &bytes, 1), -6)
        XCTAssertEqual(bs_smc_write(0, "CHTE", &bytes, 1), -6)
        XCTAssertEqual(bs_smc_write(0, nil, &bytes, 1), -6)
    }
    func testInvalidGateValuesRejectedBeforeHardwareCall() {
        var invalid: UInt8 = 255
        XCTAssertEqual(bs_smc_write(0, "CH0B", &invalid, 1), -7)
        XCTAssertEqual(bs_smc_write(0, "CH0C", &invalid, 1), -7)
        XCTAssertEqual(bs_smc_write(0, "CH0I", &invalid, 1), -7)
        XCTAssertEqual(bs_smc_write(0, "CH0B", &invalid, 2), -5)
        XCTAssertEqual(bs_smc_write(0, "CH0B", nil, 1), -5)
    }
}
