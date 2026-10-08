import XCTest
@testable import WorshipCueCore

final class LiveStateTests: XCTestCase {
    private func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))! }
    private var session: UUID { id(1) }
    private func chartA(version: Int = 10, key: String = "G") throws -> Chart {
        try Chart(id: id(version), songID: id(2), writtenKey: key, pageCount: 3)
    }
    private func chartB() throws -> Chart {
        try Chart(id: id(20), songID: id(3), writtenKey: "D", pageCount: 2)
    }
    private func call(_ seq: Int64, songB: Bool = false, key: String = "G", uniqueID: Int? = nil) throws -> LiveCall {
        try LiveCall(id: id(uniqueID ?? (100 + Int(seq))), sessionID: session, sequence: seq,
                     performanceItemID: id(songB ? 31 : 30), songID: id(songB ? 3 : 2),
                     teamChartVersionID: id(songB ? 20 : 11), performanceKey: key)
    }
    private func state() throws -> LiveState {
        try LiveState(sessionID: session, displayed: DisplayedChart(chart: chartA(), pageIndex: 2))
    }

    func testReceiveNeverNavigates() throws {
        var s = try state(); let before = s.displayed
        try s.receive(call(1, songB: true, key: "D"))
        XCTAssertEqual(s.displayed, before); XCTAssertNotNil(s.pending)
    }
    func testLatestOnlyAndNoQueue() throws {
        var s = try state()
        for n in 1...5 { try s.receive(call(Int64(n))) }
        XCTAssertEqual(s.pending?.sequence, 5); XCTAssertEqual(s.displayed?.pageIndex, 2)
    }
    func testOlderEventsDoNotRegress() throws {
        var s = try state(); try s.receive(call(4)); XCTAssertFalse(try s.receive(call(3)))
        XCTAssertEqual(s.latest?.sequence, 4); XCTAssertEqual(s.history.count, 1)
    }
    func testDuplicateIsIdempotent() throws {
        var s = try state(); let c = try call(1)
        XCTAssertTrue(try s.receive(c)); XCTAssertFalse(try s.receive(c))
        XCTAssertEqual(s.history.count, 1)
    }
    func testConflictingSameSequenceRejected() throws {
        var s = try state(); try s.receive(call(1))
        XCTAssertThrowsError(try s.receive(call(1, key: "A"))) { XCTAssertEqual($0 as? DomainError, .conflictingSequence) }
        XCTAssertEqual(s.latest?.performanceKey, "G")
    }
    func testWrongSessionRejected() throws {
        var s = try state()
        let c = try LiveCall(id: id(100), sessionID: id(99), sequence: 1, performanceItemID: id(30),
                             songID: id(2), teamChartVersionID: id(11), performanceKey: "G")
        XCTAssertThrowsError(try s.receive(c)); XCTAssertNil(s.latest)
    }
    func testHistoryBoundedToTen() throws {
        var s = try state()
        for n in 1...25 { try s.receive(call(Int64(n))) }
        XCTAssertEqual(s.history.count, 10); XCTAssertEqual(s.history.first?.sequence, 25)
        XCTAssertEqual(s.history.last?.sequence, 16)
    }
    func testStaleRenderedBannerRejected() throws {
        var s = try state(); let old = try call(1); try s.receive(old); try s.receive(call(2))
        XCTAssertThrowsError(try s.beginOpen(renderedCallID: old.id, renderedSequence: 1, selectedChart: chartA()))
        XCTAssertEqual(s.displayed?.pageIndex, 2)
    }
    func testNewCallInvalidatesDownloadCompletion() throws {
        var s = try state(); let c = try call(1, songB: true, key: "D"); try s.receive(c)
        let intent = try s.beginOpen(renderedCallID: c.id, renderedSequence: 1, selectedChart: chartB())
        try s.receive(call(2))
        XCTAssertThrowsError(try s.completeOpen(intent, chart: chartB(), fileVerified: true))
        XCTAssertEqual(s.displayed?.chart.id, id(10))
    }
    func testManualNavigationCancelsCompletion() throws {
        var s = try state(); let c = try call(1, songB: true, key: "D"); try s.receive(c)
        let intent = try s.beginOpen(renderedCallID: c.id, renderedSequence: 1, selectedChart: chartB())
        s.navigate(to: try DisplayedChart(chart: chartA(version: 12), pageIndex: 1))
        XCTAssertThrowsError(try s.completeOpen(intent, chart: chartB(), fileVerified: true))
        XCTAssertEqual(s.displayed?.chart.id, id(12))
    }
    func testPageTurnCancelsPendingOpen() throws {
        var s = try state(); let c = try call(1); try s.receive(c)
        let intent = try s.beginOpen(renderedCallID: c.id, renderedSequence: 1, selectedChart: chartA())
        try s.turnPage(to: 1)
        XCTAssertThrowsError(try s.completeOpen(intent, chart: chartA(), fileVerified: true))
    }
    func testMissingFileKeepsCurrentChart() throws {
        var s = try state(); let before = s.displayed; let c = try call(1, songB: true, key: "D")
        try s.receive(c)
        let intent = try s.beginOpen(renderedCallID: c.id, renderedSequence: 1, selectedChart: chartB())
        XCTAssertThrowsError(try s.completeOpen(intent, chart: chartB(), fileVerified: false))
        XCTAssertEqual(s.displayed, before); XCTAssertNotNil(s.pending)
    }
    func testSuccessfulExplicitOpenStartsDifferentSongAtPageOne() throws {
        var s = try state(); let c = try call(1, songB: true, key: "D"); try s.receive(c)
        let intent = try s.beginOpen(renderedCallID: c.id, renderedSequence: 1, selectedChart: chartB())
        try s.completeOpen(intent, chart: chartB(), fileVerified: true)
        XCTAssertEqual(s.displayed?.pageIndex, 0); XCTAssertEqual(s.displayed?.chart.songID, id(3))
        XCTAssertEqual(s.openedLatestCallID, c.id); XCTAssertNil(s.pending)
    }
    func testSameChartAcceptancePreservesPage() throws {
        var s = try state(); let c = try call(1, key: "A"); try s.receive(c)
        let intent = try s.beginOpen(renderedCallID: c.id, renderedSequence: 1, selectedChart: chartA())
        try s.completeOpen(intent, chart: chartA(), fileVerified: true)
        XCTAssertEqual(s.displayed?.pageIndex, 2)
        XCTAssertEqual(s.displayed?.acknowledgedPerformanceKey, "A")
        XCTAssertEqual(s.displayed?.chart.writtenKey, "G")
    }
    func testKeyOnlyReceiveDoesNotChangeAcceptedKey() throws {
        var s = try state(); let c = try call(1); try s.receive(c)
        let intent = try s.beginOpen(renderedCallID: c.id, renderedSequence: 1, selectedChart: chartA())
        try s.completeOpen(intent, chart: chartA(), fileVerified: true)
        try s.receive(call(2, key: "A"))
        XCTAssertEqual(s.displayed?.acknowledgedPerformanceKey, "G")
        XCTAssertEqual(s.pending?.performanceKey, "A"); XCTAssertNil(s.openedLatestCallID)
    }
    func testOpenIntentIsSingleUse() throws {
        var s = try state(); let c = try call(1); try s.receive(c)
        let intent = try s.beginOpen(renderedCallID: c.id, renderedSequence: 1, selectedChart: chartA())
        try s.completeOpen(intent, chart: chartA(), fileVerified: true)
        XCTAssertThrowsError(try s.completeOpen(intent, chart: chartA(), fileVerified: true))
    }
    func testWrongSongCannotBeOpenedAsCall() throws {
        var s = try state(); let c = try call(1); try s.receive(c)
        XCTAssertThrowsError(try s.beginOpen(renderedCallID: c.id, renderedSequence: 1, selectedChart: chartB()))
    }
    func testWrongVersionCompletionRejected() throws {
        var s = try state(); let c = try call(1); try s.receive(c)
        let intent = try s.beginOpen(renderedCallID: c.id, renderedSequence: 1, selectedChart: chartA())
        XCTAssertThrowsError(try s.completeOpen(intent, chart: chartA(version: 12), fileVerified: true))
    }
    func testOfflineAndReconnectNeverNavigate() throws {
        var s = try state(); let before = s.displayed
        s.setConnectivity(.offline); XCTAssertEqual(s.displayed, before)
        s.setConnectivity(.online); try s.receive(call(8, songB: true, key: "D"))
        XCTAssertEqual(s.displayed, before); XCTAssertEqual(s.latest?.sequence, 8)
    }
    func testCachedLastReceivedCallCanBeOpenedOffline() throws {
        var s = try state(); let c = try call(1); try s.receive(c); s.setConnectivity(.offline)
        let intent = try s.beginOpen(renderedCallID: c.id, renderedSequence: 1, selectedChart: chartA())
        try s.completeOpen(intent, chart: chartA(), fileVerified: true)
        XCTAssertEqual(s.connectivity, .offline); XCTAssertEqual(s.displayed?.pageIndex, 2)
    }
    func testSessionEndPreservesDisplayedChart() throws {
        var s = try state(); let before = s.displayed; s.endSession()
        XCTAssertEqual(s.displayed, before); XCTAssertTrue(s.ended)
    }
    func testManualPageTurnDoesNotChangeLatestCall() throws {
        var s = try state(); try s.receive(call(1)); let latest = s.latest
        try s.turnPage(to: 0); XCTAssertEqual(s.latest, latest); XCTAssertEqual(s.displayed?.pageIndex, 0)
    }
    func testPageBoundsRejectNegativeAndEnd() throws {
        var s = try state()
        XCTAssertThrowsError(try s.turnPage(to: -1)); XCTAssertThrowsError(try s.turnPage(to: 3))
        XCTAssertEqual(s.displayed?.pageIndex, 2)
    }
    func testPreferredVersionRetained() throws {
        let a = try chartA(), team = try chartA(version: 11, key: "A")
        XCTAssertEqual(try VersionResolver.resolve(songID: id(2), preferredID: a.id, teamVersionID: team.id,
                       charts: [a.id:a,team.id:team], verifiedIDs: [a.id,team.id]), .ready(a))
    }
    func testMissingPreferredDoesNotSilentlyFallback() throws {
        let team = try chartA(version: 11)
        XCTAssertEqual(try VersionResolver.resolve(songID: id(2), preferredID: id(10), teamVersionID: team.id,
                       charts: [team.id:team], verifiedIDs: [team.id]), .unavailable(id(10)))
    }
    func testNoPreferenceUsesTeamChart() throws {
        let team = try chartA(version: 11)
        XCTAssertEqual(try VersionResolver.resolve(songID: id(2), preferredID: nil, teamVersionID: team.id,
                       charts: [team.id:team], verifiedIDs: [team.id]), .ready(team))
    }
    func testUnverifiedPreferredNotReady() throws {
        let a = try chartA()
        XCTAssertEqual(try VersionResolver.resolve(songID: id(2), preferredID: a.id, teamVersionID: id(11),
                       charts: [a.id:a], verifiedIDs: []), .unavailable(a.id))
    }
    func testInvalidSequencesRejected() throws {
        XCTAssertThrowsError(try call(0)); XCTAssertThrowsError(try call(-1))
    }
}
