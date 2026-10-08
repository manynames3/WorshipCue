import Foundation
import WorshipCueCore
import WorshipCueLocal

struct CheckFailure: Error { let message: String }
func require(_ condition: Bool, _ message: String) throws {
    guard condition else { throw CheckFailure(message: message) }
}

@main struct InkChecks {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: root) } catch { print("cleanup failed") } }
        let url = root.appendingPathComponent("ink.sqlite")
        let store = try LocalInkStore(url: url)
        let church = UUID(), owner = UUID(), v1 = UUID(), v2 = UUID()
        let a = try InkAddress(churchID: church, ownerID: owner, versionID: v1, pageIndex: 0)
        let b = try InkAddress(churchID: church, ownerID: owner, versionID: v1, pageIndex: 1)
        let c = try InkAddress(churchID: church, ownerID: owner, versionID: v2, pageIndex: 0)
        let geometry = try PageGeometry(cropX: 20, cropY: 28, cropWidth: 572, cropHeight: 740, rotation: 0)
        func snapshot(_ address: InkAddress, _ generation: Int64, _ bytes: [UInt8]) -> InkSnapshot {
            InkSnapshot(address: address, geometry: geometry, generation: generation, archive: Data(bytes))
        }
        let first = snapshot(a, 1, [1, 2, 3])
        try await store.save(first)
        let reopened = try LocalInkStore(url: url)
        try require(try await reopened.load(a) == first, "durable reopen")
        try require(try await reopened.pendingRevisionCount() == 1, "atomic outbox on reopen")
        print("PASS durable reopen + exact bytes/generation/outbox")

        try await store.save(snapshot(b, 1, [4]))
        try await store.save(snapshot(c, 1, [5]))
        try await store.save(snapshot(a, 3, [6]))
        do { try await store.save(snapshot(a, 2, [7])); throw CheckFailure(message: "stale accepted") }
        catch InkStoreError.staleGeneration { }
        try require(try await store.load(b)?.archive == Data([4]), "page identity")
        try require(try await store.load(c)?.archive == Data([5]), "version identity")
        try require(try await store.load(a)?.generation == 3, "newer generation retained")
        print("PASS captured page/version identity + reordered saves")

        let count = try await store.pendingRevisionCount()
        try require(count == 3, "unsent snapshots must coalesce per exact personal layer")
        try await store.save(snapshot(a, 3, [6]))
        try require(try await store.pendingRevisionCount() == count, "idempotent save")
        do { try await store.save(snapshot(a, 3, [8])); throw CheckFailure(message: "conflict accepted") }
        catch InkStoreError.generationConflict { }
        print("PASS uncertain-save retry + generation conflict")

        let rotated = try PageGeometry(cropX: 20, cropY: 28, cropWidth: 572, cropHeight: 740, rotation: 90)
        do {
            try await store.save(InkSnapshot(address: a, geometry: rotated, generation: 4, archive: Data([9])))
            throw CheckFailure(message: "geometry mismatch accepted")
        } catch InkStoreError.geometryMismatch { }
        do {
            try await store.save(InkSnapshot(address: a, geometry: geometry, generation: 4,
                                            archive: Data(repeating: 1, count: LocalInkStore.maximumArchiveBytes + 1)))
            throw CheckFailure(message: "oversize accepted")
        } catch InkStoreError.archiveTooLarge { }
        try require(try await store.load(a)?.archive == Data([6]), "failed validation changed head")
        try require(try await store.pendingRevisionCount() == count, "failed validation changed outbox")
        print("PASS geometry/size failures preserve head + outbox")

        // Inject an actual SQLite error after head UPDATE, during outbox INSERT.
        let sqlite = Process()
        sqlite.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        sqlite.arguments = [url.path, "CREATE TRIGGER fail_outbox BEFORE INSERT ON personal_ink_outbox BEGIN SELECT RAISE(ABORT, 'injected write failure'); END;"]
        try sqlite.run(); sqlite.waitUntilExit()
        try require(sqlite.terminationStatus == 0, "fault trigger installation")
        do { try await store.save(snapshot(a, 4, [10])); throw CheckFailure(message: "fault accepted") }
        catch let error as CheckFailure { throw error }
        catch { }
        try require(try await reopened.load(a)?.archive == Data([6]), "transaction failed to roll back head")
        try require(try await reopened.pendingRevisionCount() == count, "transaction failed to roll back outbox")
        print("PASS actual SQLite mid-transaction failure rolls back head/outbox")

        // Independently expected locations of native bottom-left CropBox corner.
        let expected: [(Int, Double, Double)] = [(0,0,740), (90,0,0), (180,572,0), (270,740,572)]
        for (rotation, x, y) in expected {
            let g = try PageGeometry(cropX: 20, cropY: 28, cropWidth: 572, cropHeight: 740, rotation: rotation)
            let corner = g.canonicalPoint(pdfX: 20, pdfY: 28)
            try require(corner.x == x && corner.y == y, "rotation corner \(rotation)")
            for point in [(20.0,28.0), (592.0,768.0), (117.0,204.0)] {
                let mapped = g.canonicalPoint(pdfX: point.0, pdfY: point.1)
                let back = g.pdfPoint(x: mapped.x, y: mapped.y)
                try require(abs(back.x - point.0) < 0.001 && abs(back.y - point.1) < 0.001, "roundtrip \(rotation)")
            }
        }
        print("PASS four rotations + nonzero CropBox independent corners + roundtrips")

        let item = UUID()
        let team = try LayerIdentity(churchID: church, versionID: v1, pageIndex: 0, scope: .team(performanceItemID: item))
        try require(team.mayOverlayTeam(on: v1, performanceItem: item, church: church, page: 0), "matching team")
        try require(!team.mayOverlayTeam(on: v2, performanceItem: item, church: church, page: 0), "wrong version")
        try require(!team.mayOverlayTeam(on: v1, performanceItem: UUID(), church: church, page: 0), "wrong occurrence")
        try require(!team.mayOverlayTeam(on: v1, performanceItem: item, church: UUID(), page: 0), "wrong church")
        try require(!team.mayOverlayTeam(on: v1, performanceItem: item, church: church, page: 1), "wrong page")
        print("PASS exact team layer gating")
        let delayedDiskRead = snapshot(a, 1, [1, 2, 3])
        let committedRecent = snapshot(a, 3, [6])
        let restored = try InkSnapshot.restoreCandidate(durable: delayedDiskRead, recent: committedRecent, pending: nil)
        try require(restored == committedRecent, "delayed restore lost recently committed ink")
        do {
            _ = try InkSnapshot.restoreCandidate(durable: committedRecent, recent: snapshot(a, 3, [99]), pending: nil)
            throw CheckFailure(message: "ambiguous restore accepted")
        } catch InkStoreError.generationConflict { }
        print("PASS delayed restore after pending removal + divergent revision fails closed")

        let corrupt = Process()
        corrupt.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        let wrongAddress = try JSONEncoder().encode(c)
        let hex = wrongAddress.map { String(format: "%02x", $0) }.joined()
        corrupt.arguments = [url.path, "UPDATE personal_ink SET address=X'\(hex)' WHERE layer_key='\(a.key)';"]
        try corrupt.run(); corrupt.waitUntilExit()
        try require(corrupt.terminationStatus == 0, "corruption injection")
        do { _ = try await reopened.load(a); throw CheckFailure(message: "mismatched address restored") }
        catch InkStoreError.invalidRecord { }
        print("PASS corrupted database address cannot restore into another layer")
        print("9 check groups passed; native PencilKit archives and device behavior NOT VERIFIED")
    }
}
