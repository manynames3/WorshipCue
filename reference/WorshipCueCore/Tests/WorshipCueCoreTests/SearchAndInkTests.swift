import XCTest
@testable import WorshipCueCore

final class SearchAndInkTests: XCTestCase {
    private func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))! }
    func testKoreanWhitespace() { XCTAssertEqual(KoreanSearch.normalize(" 주 품에 \n"), "주품에") }
    func testInitialConsonants() { XCTAssertEqual(KoreanSearch.initials("주 품에"), "ㅈㅍㅇ") }
    func testInitialPrefixSearch() { XCTAssertNotNil(KoreanSearch.score(query: "ㅇㅁㄱㄷ", title: "아무것도 두려워 말라")) }
    func testInitialExactSearch() { XCTAssertNotNil(KoreanSearch.score(query: "ㅈㅍㅇ", title: "주 품에")) }
    func testEnglishAliasCaseInsensitive() { XCTAssertNotNil(KoreanSearch.score(query: "SONG OF PEACE", title: "평안의 노래", aliases: ["Song of Peace"])) }
    func testDecomposedHangulNormalizes() {
        let title = "주 품에"
        XCTAssertEqual(KoreanSearch.normalize(title.decomposedStringWithCanonicalMapping), KoreanSearch.normalize(title))
    }
    func testExactTitleRanksBeforeAlias() {
        XCTAssertLessThan(KoreanSearch.score(query: "평안의 노래", title: "평안의 노래")!,
                          KoreanSearch.score(query: "평안의 노래", title: "다른 이름", aliases: ["평안의 노래"])!)
    }
    func testEmptySearchIsNotAllMatched() { XCTAssertNil(KoreanSearch.score(query: "  ", title: "곡 A")) }
    func testUnrelatedSearchDoesNotMatch() { XCTAssertNil(KoreanSearch.score(query: "ㅂㅂㅂㅂㅂ", title: "주 품에")) }
    func testValidKeys() { ["G","Bb","F#","Am","C#m","Abm"].forEach { XCTAssertTrue(MusicalKey.isValid($0)) } }
    func testInvalidKeys() { ["H","g","G major","","B##","Cmm"].forEach { XCTAssertFalse(MusicalKey.isValid($0)) } }
    func testEnharmonicKeysMatch() { XCTAssertEqual(MusicalKey.compare(written: "A#", performance: "Bb"), .matching) }
    func testMinorAndMajorDiffer() { XCTAssertEqual(MusicalKey.compare(written: "A", performance: "Am"), .different) }
    func testUnknownWrittenKeyIsNotMatch() { XCTAssertEqual(MusicalKey.compare(written: nil, performance: "G"), .unknown) }
    func testMismatchedKeysFlagged() { XCTAssertEqual(MusicalKey.compare(written: "A", performance: "G"), .different) }
    func testSameTeamContextOverlays() throws {
        let layer = try LayerIdentity(churchID: id(1), versionID: id(2), pageIndex: 0, scope: .team(performanceItemID: id(3)))
        XCTAssertTrue(layer.mayOverlayTeam(on: id(2), performanceItem: id(3), church: id(1), page: 0))
    }
    func testDifferentVersionNeverOverlays() throws {
        let layer = try LayerIdentity(churchID: id(1), versionID: id(2), pageIndex: 0, scope: .team(performanceItemID: id(3)))
        XCTAssertFalse(layer.mayOverlayTeam(on: id(9), performanceItem: id(3), church: id(1), page: 0))
    }
    func testDifferentOccurrenceNeverOverlays() throws {
        let layer = try LayerIdentity(churchID: id(1), versionID: id(2), pageIndex: 0, scope: .team(performanceItemID: id(3)))
        XCTAssertFalse(layer.mayOverlayTeam(on: id(2), performanceItem: id(8), church: id(1), page: 0))
    }
    func testDifferentChurchNeverOverlays() throws {
        let layer = try LayerIdentity(churchID: id(1), versionID: id(2), pageIndex: 0, scope: .team(performanceItemID: id(3)))
        XCTAssertFalse(layer.mayOverlayTeam(on: id(2), performanceItem: id(3), church: id(9), page: 0))
    }
    func testDifferentPageNeverOverlays() throws {
        let layer = try LayerIdentity(churchID: id(1), versionID: id(2), pageIndex: 0, scope: .team(performanceItemID: id(3)))
        XCTAssertFalse(layer.mayOverlayTeam(on: id(2), performanceItem: id(3), church: id(1), page: 1))
    }
    func testPersonalLayerIsNeverTeamOverlay() throws {
        let layer = try LayerIdentity(churchID: id(1), versionID: id(2), pageIndex: 0, scope: .personal(ownerID: id(3)))
        XCTAssertFalse(layer.mayOverlayTeam(on: id(2), performanceItem: id(3), church: id(1), page: 0))
    }
    func testQuarterTurnSwapsDimensions() throws {
        let p = try CanonicalPage(cropX: 20, cropY: 30, cropWidth: 400, cropHeight: 600, rotation: 90)
        XCTAssertEqual(p.displayedWidth, 600); XCTAssertEqual(p.displayedHeight, 400)
    }
    func testHalfTurnKeepsDimensions() throws {
        let p = try CanonicalPage(cropX: 20, cropY: 30, cropWidth: 400, cropHeight: 600, rotation: 180)
        XCTAssertEqual(p.displayedWidth, 400); XCTAssertEqual(p.cropX, 20)
    }
    func testThreeQuarterTurnSwapsDimensions() throws {
        let p = try CanonicalPage(cropX: 0, cropY: 0, cropWidth: 400, cropHeight: 600, rotation: 270)
        XCTAssertEqual(p.displayedWidth, 600)
    }
    func testInvalidGeometryRejected() {
        XCTAssertThrowsError(try CanonicalPage(cropX: 0, cropY: 0, cropWidth: 0, cropHeight: 10, rotation: 0))
        XCTAssertThrowsError(try CanonicalPage(cropX: 0, cropY: 0, cropWidth: 10, cropHeight: 10, rotation: 45))
        XCTAssertThrowsError(try CanonicalPage(cropX: .nan, cropY: 0, cropWidth: 10, cropHeight: 10, rotation: 0))
    }
    func testCopyPlacementUsesUniformScale() throws {
        XCTAssertEqual(try NotePlacement.uniformScale(sourceWidth: 100, sourceHeight: 50, maxWidth: 200, maxHeight: 60), 1.2)
    }
    func testInvalidSelectionRejected() {
        XCTAssertThrowsError(try NotePlacement.uniformScale(sourceWidth: 0, sourceHeight: 1, maxWidth: 2, maxHeight: 2))
    }
}
