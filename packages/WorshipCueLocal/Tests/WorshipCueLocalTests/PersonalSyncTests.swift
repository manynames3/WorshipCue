import XCTest
@testable import WorshipCueLocal

final class PersonalSyncTests: XCTestCase {
    private func location() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root.appendingPathComponent("sync.sqlite")
    }
    private func snapshot(_ generation: Int64, archive: UInt8, address: InkAddress? = nil) throws -> InkSnapshot {
        InkSnapshot(address: try address ?? InkAddress(churchID: UUID(), ownerID: UUID(), versionID: UUID(), pageIndex: 0),
            geometry: try PageGeometry(cropX: 0, cropY: 0, cropWidth: 600, cropHeight: 800, rotation: 0),
            generation: generation, archive: Data([archive]))
    }
    func testUncertainPayloadAndNewerInkSurviveColdStartWithoutLosingEitherCommand() async throws {
        let url = try location(), store = try LocalInkStore(url: url), first = try snapshot(1, archive: 1)
        try await store.save(first)
        let jobs = try await store.pendingUploads(), job = try XCTUnwrap(jobs.first)
        try await store.freezeUpload(job.commandID)
        try await store.attachPayload(Data("immutable-payload".utf8), command: job.commandID)
        try await store.save(snapshot(2, archive: 2, address: first.address))
        let cold = try LocalInkStore(url: url), pending = try await cold.pendingUploads()
        XCTAssertEqual(pending.count, 2)
        XCTAssertEqual(pending[0].commandID, job.commandID)
        XCTAssertEqual(pending[0].payload, Data("immutable-payload".utf8))
        XCTAssertEqual(pending[0].snapshot.archive, first.archive)
        try await cold.acknowledgeUpload(job.commandID, revision: 1)
        let next = try await cold.pendingUploads()
        XCTAssertEqual(next.count, 1); XCTAssertEqual(next[0].parentRevision, 1)
        XCTAssertEqual(next[0].snapshot.archive, Data([2]))
        let durable = try await cold.load(first.address); XCTAssertEqual(durable?.generation, 2)
    }
    func testCleanRemoteRecoveryDoesNotCreateOutboxButDirtyRemoteConflictCannotOverwrite() async throws {
        let store = try LocalInkStore(url: location()), incoming = try snapshot(1, archive: 3)
        let installed = try await store.installRemote(incoming, revision: 1)
        XCTAssertEqual(installed.archive, incoming.archive)
        let count = try await store.pendingRevisionCount(); XCTAssertEqual(count, 0)
        try await store.save(snapshot(installed.generation + 1, archive: 9, address: incoming.address))
        do { _ = try await store.installRemote(snapshot(1, archive: 7, address: incoming.address), revision: 2); XCTFail("Dirty note overwritten") }
        catch { XCTAssertEqual(error as? InkStoreError, .generationConflict) }
        let local = try await store.load(incoming.address); XCTAssertEqual(local?.archive, Data([9]))
    }
    func testDelayedRemoteSnapshotCannotRewindAnAcknowledgedNewerRevision() async throws {
        let store = try LocalInkStore(url: location()), original = try snapshot(1, archive: 1)
        let installed = try await store.installRemote(original, revision: 1)
        try await store.save(snapshot(installed.generation + 1, archive: 2, address: original.address))
        let jobs = try await store.pendingUploads(), job = try XCTUnwrap(jobs.first)
        try await store.freezeUpload(job.commandID); try await store.acknowledgeUpload(job.commandID, revision: 2)
        let stale = try await store.installRemote(original, revision: 1)
        XCTAssertEqual(stale.archive, Data([2]))
        let durable = try await store.load(original.address); XCTAssertEqual(durable?.archive, Data([2]))
        do { _ = try await store.installRemote(original, revision: 0); XCTFail("Invalid revision accepted") }
        catch { XCTAssertEqual(error as? InkStoreError, .invalidRecord) }
    }
    func testExplicitConflictChoiceKeepsLocalOrServerWithoutAutomaticMerging() async throws {
        for keepLocal in [true, false] {
            let store = try LocalInkStore(url: location()), local = try snapshot(1, archive: 1)
            try await store.save(local)
            let remote = try snapshot(1, archive: 2, address: local.address)
            let chosen = try await store.resolveConflict(remote, revision: 4, keepLocal: keepLocal)
            XCTAssertEqual(chosen.archive, Data([keepLocal ? 1 : 2]))
            XCTAssertEqual(chosen.generation, 2)
            let jobs = try await store.pendingUploads()
            XCTAssertEqual(jobs.count, keepLocal ? 1 : 0)
            if keepLocal { XCTAssertEqual(jobs.first?.parentRevision, 4); XCTAssertEqual(jobs.first?.snapshot.archive, local.archive) }
            let cold = try LocalInkStore(url: location())
            let unrelated = try await cold.load(local.address); XCTAssertNil(unrelated)
        }
    }
    func testPayloadCannotChangeAfterAttemptAndAcknowledgementCannotDropUnrelatedOwner() async throws {
        let store = try LocalInkStore(url: location()), first = try snapshot(1, archive: 1), other = try snapshot(1, archive: 2)
        try await store.save(first); try await store.save(other)
        let jobs = try await store.pendingUploads(), job = try XCTUnwrap(jobs.first { $0.snapshot.address == first.address })
        try await store.freezeUpload(job.commandID); try await store.attachPayload(Data([1]), command: job.commandID)
        do { try await store.attachPayload(Data([2]), command: job.commandID); XCTFail("Payload rewrite accepted") }
        catch { XCTAssertEqual(error as? InkStoreError, .generationConflict) }
        try await store.acknowledgeUpload(job.commandID, revision: 1)
        let pending = try await store.pendingUploads(); XCTAssertEqual(pending.count, 1); XCTAssertEqual(pending[0].snapshot.address, other.address)
    }
    func testPublishedCachePreservesServerNumberAcrossOutOfOrderDownloadsAndRejectsMutation() throws {
        let store = try LocalLibraryStore(url: location()), song = LibrarySong(title: "Synthetic remote song")
        func receipt(_ number: Int) throws -> (LibraryVersion, LibraryAsset) {
            let id = UUID()
            let asset = LibraryAsset(id: id, filename: "\(id.uuidString).pdf", sha256: String(repeating: "a", count: 64), bytes: 500,
                pages: [try PageGeometry(cropX: 0, cropY: 0, cropWidth: 600, cropHeight: 800, rotation: 0)])
            return (LibraryVersion(id: id, songID: song.id, number: number, assetID: id, label: "version", writtenKey: "G"), asset)
        }
        let third = try receipt(3), first = try receipt(1)
        try store.cachePublished(song: song, version: third.0, asset: third.1)
        try store.cachePublished(song: song, version: first.0, asset: first.1)
        try store.cachePublished(song: song, version: third.0, asset: third.1)
        XCTAssertEqual(try store.snapshot().versions(for: song.id).map(\.number), [3, 1])
        let bad = LibraryVersion(id: third.0.id, songID: song.id, number: 2, assetID: third.1.id, label: "changed", writtenKey: "A")
        XCTAssertThrowsError(try store.cachePublished(song: song, version: bad, asset: third.1))
        XCTAssertEqual(try store.snapshot().versions.count, 2)
    }
}
