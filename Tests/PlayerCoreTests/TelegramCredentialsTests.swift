import XCTest
@testable import PlayerCore

final class TelegramCredentialsTests: XCTestCase {
    func testCredentialsNormalizeValidValues() throws {
        let credentials = try TelegramCredentials.validated(apiID: " 12345 ", apiHash: "A1B2C3D4E5F60718293A4B5C6D7E8F90")
        XCTAssertEqual(credentials.apiID, 12345)
        XCTAssertEqual(credentials.apiHash, "a1b2c3d4e5f60718293a4b5c6d7e8f90")
    }

    func testCredentialsRejectInvalidValues() {
        XCTAssertThrowsError(try TelegramCredentials.validated(apiID: "0", apiHash: String(repeating: "a", count: 32)))
        XCTAssertThrowsError(try TelegramCredentials.validated(apiID: "42", apiHash: "not-a-telegram-hash"))
    }
}
