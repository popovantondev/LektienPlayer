import XCTest
import PlayerCore
import PlayerTranslation

final class PlayerComfortTests: XCTestCase {
    func testDuckingAttacksHoldsBetweenSyllablesAndReleasesWithoutSteps() {
        var envelope = DuckingEnvelope()
        var levels: [Double] = []
        for step in 0..<80 {
            let time = Double(step) * 0.05
            levels.append(envelope.update(speaking: step < 20 && step % 3 != 0, enabled: true,
                                          attenuation: 0.25, time: time, elapsed: 0.05))
        }
        XCTAssertLessThan(levels[10], 0.28)
        XCTAssertLessThan(levels[22], 0.3, "Hold gain across brief speech gaps")
        XCTAssertGreaterThan(levels.last!, 0.98)
        for pair in zip(levels, levels.dropFirst()) { XCTAssertLessThan(abs(pair.1 - pair.0), 0.4) }
    }

    func testInitialWindowFitStaysInsideScreenEvenWhenMinimumCannotFit() {
        let result = VideoWindowGeometry.fittedSize(proposed: CGSize(width: 1800, height: 1200),
            videoSize: CGSize(width: 1920, height: 1080), chrome: CGSize(width: 0, height: 60),
            minimum: CGSize(width: 1300, height: 1000), maximum: CGSize(width: 1000, height: 700))
        XCTAssertLessThanOrEqual(result.width, 1000)
        XCTAssertLessThanOrEqual(result.height, 700)
        XCTAssertEqual(result.width / (result.height - 60), 16.0 / 9.0, accuracy: 0.0001)
    }

    func testUsageUsesRemainingMatchesWindowLengthAndExcludesSpark() throws {
        let json = #"{"rateLimits":{"limitId":"spark","primary":{"usedPercent":99,"windowDurationMins":300}},"rateLimitsByLimitId":{"spark":{"primary":{"usedPercent":99,"windowDurationMins":300}},"codex":{"planType":"plus","primary":{"usedPercent":31.2,"windowDurationMins":300,"resetsAt":1788894000},"secondary":{"usedPercent":17,"windowDurationMins":10080}}}}"#
        let limits = try JSONDecoder().decode(UsageLimits.self, from: Data(json.utf8))
        XCTAssertEqual(limits.buckets.count, 1)
        XCTAssertEqual(limits.buckets.first?.planType, "plus")
        XCTAssertEqual(limits.buckets.first?.primary?.remaining, 68)
        XCTAssertEqual(limits.buckets.first?.secondary?.remaining, 83)
        let empty = try JSONDecoder().decode(UsageLimits.self, from: Data(#"{"rateLimits":{"primary":{"usedPercent":null,"windowDurationMins":null}}}"#.utf8))
        XCTAssertNil(empty.buckets.first?.primary?.remaining)
    }

    func testLiveReadOnlyUsageWhenEnabled() throws {
        guard ProcessInfo.processInfo.environment["LEKTIEN_USAGE_SMOKE"] == "1" else { throw XCTSkip("Read-only account check") }
        let executable = try XCTUnwrap(CodexClient.installedExecutable())
        let limits = try UsageLimitsClient.read(executable: executable, cancellation: TranslationCancellation())
        XCTAssertFalse(limits.buckets.isEmpty)
        XCTAssertFalse(limits.buckets.contains { ($0.limitId ?? "").lowercased().contains("spark") })
        XCTAssertTrue(limits.buckets.flatMap(\.windows).contains { $0.remaining != nil })
    }
}
