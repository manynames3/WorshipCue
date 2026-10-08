import XCTest
@testable import WorshipCueLocal

final class LibraryTests: XCTestCase {
    private func store() throws -> (LocalLibraryStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("library.sqlite")
        return (try LocalLibraryStore(url: url), url)
    }
    private func asset(pages: Int? = 2) throws -> LibraryAsset {
        let id = UUID()
        return LibraryAsset(id: id, filename: "\(id.uuidString).pdf", sha256: String(repeating: "a", count: 64), bytes: 1024,
            pages: try pages.map { count in try (0..<count).map { _ in
                try PageGeometry(cropX: 10, cropY: 20, cropWidth: 600, cropHeight: 800, rotation: 90)
            } })
    }
    private func publish(_ db: LocalLibraryStore, song: LibrarySong) throws -> LibraryVersion {
        try XCTUnwrap(db.register([LibraryImport(asset: try asset(), song: song, label: "연습 악보", writtenKey: "G")]).first)
    }

    func testImportVersionNumbersAndExplicitPreferenceSurviveReopen() throws {
        let (db, url) = try store(), song = LibrarySong(title: "주 하나님 지으신 모든 세계")
        let first = try publish(db, song: song), second = try publish(db, song: song)
        XCTAssertEqual([first.number, second.number], [1, 2])
        XCTAssertTrue(try db.snapshot().preferences.isEmpty)
        try db.setPreferred(songID: song.id, versionID: first.id)
        try db.remember(versionID: second.id, pageIndex: 1)
        let reopened = try LocalLibraryStore(url: url)
        XCTAssertEqual(try reopened.snapshot().preferences[song.id], first.id)
        XCTAssertEqual(try reopened.bookmark(versionID: second.id), 1)
        XCTAssertEqual(try reopened.bookmark(versionID: first.id), 0)
        XCTAssertEqual(try reopened.snapshot().versions(for: song.id).map(\.number), [2, 1])
    }
    func testFailedBatchPublishesNothingAndDoesNotConsumeNumber() throws {
        let (db, _) = try store(), song = LibrarySong(title: "예시")
        let first = try publish(db, song: song)
        XCTAssertThrowsError(try db.register([
            LibraryImport(asset: try asset(), song: song, label: "valid"),
            LibraryImport(asset: try asset(), song: song, label: "invalid", writtenKey: "H")]))
        XCTAssertEqual(try db.snapshot().versions, [first])
        XCTAssertEqual(try publish(db, song: song).number, 2)
    }
    func testLegacyMigrationIsAtomicIdempotentAndKeepsIDs() throws {
        let (db, url) = try store(), song = LibrarySong(title: "기존 악보"), legacy = try asset(pages: nil)
        let item = LibraryImport(asset: legacy, song: song, label: "old")
        try db.migrateLegacy([item])
        try db.migrateLegacy([item])
        XCTAssertTrue(try db.hasMigratedLegacyIndex())
        XCTAssertEqual(try db.snapshot().versions.map(\.id), [legacy.id])
        XCTAssertNil(try db.snapshot().assets.first?.pages)
        let geometry = try XCTUnwrap(asset(pages: 2).pages)
        try db.recordGeometry(assetID: legacy.id, pages: geometry)
        XCTAssertEqual(try LocalLibraryStore(url: url).snapshot().assets.first?.pages, geometry)
        XCTAssertThrowsError(try db.recordGeometry(assetID: legacy.id, pages: [geometry[0]]))
    }
    func testReceiptsAndPublishedVersionsCannotBeRewritten() throws {
        let (db, _) = try store(), song = LibrarySong(title: "immutable"), a = try asset()
        let item = LibraryImport(asset: a, song: song, label: "v1", writtenKey: "G")
        let first = try XCTUnwrap(db.register([item]).first)
        XCTAssertEqual(try db.register([item]).first, first)
        XCTAssertThrowsError(try db.register([LibraryImport(asset: a, song: song, label: "changed", writtenKey: "A")]))
        XCTAssertThrowsError(try db.register([LibraryImport(asset: try asset(pages: nil), song: song, label: "unverified")]))
        XCTAssertEqual(try db.snapshot().versions.count, 1)
    }
    func testKoreanInitialsAliasesHymnEditionAndFavorites() throws {
        let (db, _) = try store()
        let hymn = LibrarySong(title: "주 하나님 지으신 모든 세계", aliases: ["How Great Thou Art"],
                               hymnNumber: 79, hymnEdition: "새찬송가", favorite: true)
        _ = try publish(db, song: hymn)
        _ = try publish(db, song: LibrarySong(title: "다른 곡"))
        let snapshot = try db.snapshot()
        for query in ["ㅈㅎㄴㄴ", "주하나님", "79", "great thou", "주 하나님".decomposedStringWithCanonicalMapping] {
            XCTAssertEqual(snapshot.search(query).first?.id, hymn.id)
        }
        XCTAssertEqual(snapshot.search("", favoritesOnly: true).map(\.id), [hymn.id])
        XCTAssertThrowsError(try db.updateSong(LibrarySong(id: hymn.id, title: hymn.title, hymnNumber: 79)))
    }
    func testWrongSongPreferenceAndSetlistItemAreRejectedWithoutPartialSave() throws {
        let (db, _) = try store(), a = LibrarySong(title: "A"), b = LibrarySong(title: "B")
        let av = try publish(db, song: a), bv = try publish(db, song: b)
        XCTAssertThrowsError(try db.setPreferred(songID: a.id, versionID: bv.id))
        let set = try db.saveSetlist(LocalSetlist(title: "Sunday", items: [SetlistItem(songID: a.id, versionID: av.id)]))
        var invalid = set
        invalid.items.append(SetlistItem(songID: a.id, versionID: bv.id))
        XCTAssertThrowsError(try db.saveSetlist(invalid))
        XCTAssertEqual(try db.snapshot().setlists, [set])
    }
    func testSetlistRepeatsStandbyCloningAndStaleRevision() throws {
        let (db, url) = try store(), song = LibrarySong(title: "다시 부를 곡"), version = try publish(db, song: song)
        let item = SetlistItem(songID: song.id, versionID: version.id, performanceKey: "Bb")
        let repeatItem = SetlistItem(songID: song.id, versionID: version.id, section: .standby)
        let saved = try db.saveSetlist(LocalSetlist(title: "예배", items: [item, repeatItem]))
        XCTAssertEqual(saved.revision, 1)
        var changed = saved; changed.items.reverse()
        let updated = try db.saveSetlist(changed)
        XCTAssertEqual(updated.revision, 2)
        XCTAssertThrowsError(try db.saveSetlist(saved))
        let cloned = try db.saveSetlist(updated.clone(title: "다음 예배"))
        XCTAssertTrue(Set(cloned.items.map(\.id)).isDisjoint(with: updated.items.map(\.id)))
        XCTAssertEqual(cloned.items.map(\.section), updated.items.map(\.section))
        XCTAssertEqual(try LocalLibraryStore(url: url).snapshot().setlists.count, 2)
    }
    func testPacketProvenanceRequiresMatchingPageRange() throws {
        let (db, _) = try store(), packet = LibrarySong(title: "Packet")
        let source = try publish(db, song: packet)
        let slice = LibrarySong(title: "곡 1")
        XCTAssertThrowsError(try db.register([LibraryImport(asset: try asset(pages: 1), song: slice, label: "slice",
            sourceAssetID: source.assetID, sourceFirstPage: 2, sourceLastPage: 3)]))
        let version = try XCTUnwrap(db.register([LibraryImport(asset: try asset(pages: 1), song: slice, label: "slice",
            sourceAssetID: source.assetID, sourceFirstPage: 2, sourceLastPage: 2)]).first)
        XCTAssertEqual(version.sourceAssetID, source.assetID)
        XCTAssertEqual(version.sourceFirstPage, 2)
        XCTAssertEqual(try db.snapshot().assets.count, 2)
    }
}
