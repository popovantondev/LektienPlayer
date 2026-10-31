import Foundation
import XCTest
import PlayerCore
@testable import PlayerTranslation

final class TranslationWireFormatTests: XCTestCase {
    func testSparseIDsAndReviewFlagsRoundTripWithoutChangingOrder() throws {
        let wire = try TranslationWireFormat(cueIDs: [103001, 103007, 104002])
        let input = try wire.rows([.init(id: 103001, text: "A"), .init(id: 104002, text: "C"), .init(id: 103007, text: "B")])
        XCTAssertEqual(input.map(\.id), [1, 3, 2])
        let answer = try wire.decode(Data(#"{"translations":{"3":"Три","1":"Один","2":"Два"},"reviewIDs":[2]}"#.utf8))
        XCTAssertEqual(answer.translations.map(\.id), [103001, 103007, 104002])
        XCTAssertEqual(answer.translations.map(\.text), ["Один", "Два", "Три"])
        XCTAssertEqual(answer.reviewIDs, [103007])
        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: wire.schema()) as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: [String: Any]])
        XCTAssertEqual(properties["translations"]?["required"] as? [String], ["1", "2", "3"])
        XCTAssertEqual(properties["translations"]?["additionalProperties"] as? Bool, false)
    }

    func testInvalidRowsCannotBeSilentlyDroppedOrAssignedToOtherCues() throws {
        let wire = try TranslationWireFormat(cueIDs: [9001, 9005])
        for json in [
            #"{"translations":{"1":"Один"},"reviewIDs":[]}"#,
            #"{"translations":{"1":"Один","2":"Два","3":"Лишнее"},"reviewIDs":[]}"#,
            #"{"translations":{"1":"Один","2":"Два"},"reviewIDs":[-1]}"#,
            #"{"translations":{"1":"Один","2":"Два"},"reviewIDs":[3]}"#,
            #"{"translations":{"1":"Один","2":" "},"reviewIDs":[]}"#,
            #"{"translations":{"1":"Один","2":"сло��о"},"reviewIDs":[]}"#
        ] { XCTAssertThrowsError(try wire.decode(Data(json.utf8))) }
        XCTAssertThrowsError(try TranslationWireFormat(cueIDs: []))
        XCTAssertThrowsError(try TranslationWireFormat(cueIDs: [1, 1]))
        XCTAssertThrowsError(try wire.rows([.init(id: 9001, text: "A"), .init(id: 9001, text: "B")]))
    }
}
