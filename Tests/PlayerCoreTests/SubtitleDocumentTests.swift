import Foundation
import Testing
@testable import PlayerCore

@Test func parsesRussianAndGermanSubtitles() throws {
    let document = try SRTParser.parse(text: """
    1
    00:00:01,000 --> 00:00:03,500
    Guten Tag

    2
    00:00:03,500 --> 00:00:05,000
    Здравствуйте
    """)

    #expect(document.cues.count == 2)
    #expect(document.text(at: 1.1) == "Guten Tag")
    #expect(document.text(at: 3.5) == "Здравствуйте")
    #expect(document.text(at: 5) == nil)
}

@Test func rejectsBrokenTimeRange() {
    #expect(throws: SubtitleError.invalidTimestamp(1)) {
        _ = try SRTParser.parse(text: """
        1
        00:00:04,000 --> 00:00:01,000
        Broken
        """)
    }
}

@Test func preservesTwoLinesInOneCue() throws {
    let document = try SRTParser.parse(text: """
    7
    01:02:03,004 --> 01:02:06,008
    Первая строка
    Вторая строка
    """)

    #expect(document.text(at: 3724) == "Первая строка\nВторая строка")
}

@Test func acceptsBOMAndExtraBlankSeparators() throws {
    let document = try SRTParser.parse(text: "\u{FEFF}1\r\n00:00:00,000 --> 00:00:01,000\r\nОдин\r\n \r\n\r\n2\r\n00:00:02,000 --> 00:00:03,000\r\nДва")
    #expect(document.cues.count == 2)
}

@Test func rejectsNegativeComponentsAndInfiniteTimes() throws {
    for timestamp in ["01:-01:00,000", "01:00:-01,000", "inf:00:00,000", "1.5:00:00,000"] {
        #expect(throws: SubtitleError.self) {
            _ = try SRTParser.parse(text: "1\n00:00:00,000 --> \(timestamp)\nТекст")
        }
    }
    #expect(throws: SubtitleError.self) {
        _ = try SubtitleDocument(cues: [.init(identifier: 1, start: 0, end: .infinity, text: "Текст")])
    }
}
