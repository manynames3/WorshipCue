import Foundation
import GRDB

/// A single actor owns the single transactional writer. No live-call outbox exists.
public actor LocalInkStore {
    private let database: DatabaseQueue
    public static let maximumArchiveBytes = 2 * 1024 * 1024

    public init(url: URL) throws {
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = FULL")
        }
        database = try DatabaseQueue(path: url.path, configuration: configuration)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("m0-personal-ink-v1") { db in
            try db.execute(sql: """
                CREATE TABLE personal_ink (
                  layer_key TEXT PRIMARY KEY NOT NULL,
                  address BLOB NOT NULL, geometry BLOB NOT NULL,
                  generation INTEGER NOT NULL CHECK (generation > 0), archive BLOB NOT NULL);
                CREATE TABLE personal_ink_outbox (
                  layer_key TEXT NOT NULL REFERENCES personal_ink(layer_key),
                  generation INTEGER NOT NULL, archive BLOB NOT NULL,
                  base_server_revision TEXT,
                  PRIMARY KEY (layer_key, generation));
                """)
        }
        try migrator.migrate(database)
    }

    public func load(_ address: InkAddress) throws -> InkSnapshot? {
        try database.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM personal_ink WHERE layer_key = ?",
                                            arguments: [address.key]) else { return nil }
            return try Self.decode(row, expectedAddress: address)
        }
    }

    /// Returns only after both head and outbox snapshot are committed.
    public func save(_ snapshot: InkSnapshot) throws {
        guard snapshot.address.pageIndex >= 0, snapshot.generation > 0,
              !snapshot.archive.isEmpty else { throw InkStoreError.invalidRecord }
        try snapshot.geometry.validate()
        guard snapshot.archive.count <= Self.maximumArchiveBytes else { throw InkStoreError.archiveTooLarge }
        let addressData = try JSONEncoder().encode(snapshot.address)
        let geometryData = try JSONEncoder().encode(snapshot.geometry)
        try database.write { db in
            if let row = try Row.fetchOne(db, sql: "SELECT * FROM personal_ink WHERE layer_key = ?",
                                         arguments: [snapshot.address.key]) {
                let previous = try Self.decode(row, expectedAddress: snapshot.address)
                guard previous.geometry == snapshot.geometry else { throw InkStoreError.geometryMismatch }
                guard snapshot.generation >= previous.generation else { throw InkStoreError.staleGeneration }
                if previous.generation == snapshot.generation {
                    guard previous.archive == snapshot.archive else { throw InkStoreError.generationConflict }
                    return // Idempotent retry after an uncertain completion.
                }
            }
            try db.execute(sql: """
                INSERT INTO personal_ink(layer_key,address,geometry,generation,archive) VALUES (?,?,?,?,?)
                ON CONFLICT(layer_key) DO UPDATE SET generation=excluded.generation, archive=excluded.archive
                """, arguments: [snapshot.address.key, addressData, geometryData,
                                  snapshot.generation, snapshot.archive])
            // No sync worker exists in M0. Coalesce unsent full snapshots for this exact
            // layer/base only; do not accumulate an entire drawing for every pen-up.
            try db.execute(sql: "DELETE FROM personal_ink_outbox WHERE layer_key = ? AND base_server_revision IS NULL",
                           arguments: [snapshot.address.key])
            try db.execute(sql: """
                INSERT INTO personal_ink_outbox(layer_key,generation,archive) VALUES (?,?,?)
                """, arguments: [snapshot.address.key, snapshot.generation, snapshot.archive])
        }
    }

    public func pendingRevisionCount() throws -> Int {
        try database.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM personal_ink_outbox") ?? 0 }
    }

    private static func decode(_ row: Row, expectedAddress: InkAddress) throws -> InkSnapshot {
        let address = try JSONDecoder().decode(InkAddress.self, from: row["address"] as Data)
        let geometry = try JSONDecoder().decode(PageGeometry.self, from: row["geometry"] as Data)
        try geometry.validate()
        let generation: Int64 = row["generation"]
        let archive: Data = row["archive"]
        let key: String = row["layer_key"]
        guard address == expectedAddress, address.key == key, address.pageIndex >= 0,
              generation > 0, !archive.isEmpty, archive.count <= maximumArchiveBytes else {
            throw InkStoreError.invalidRecord
        }
        return InkSnapshot(address: address, geometry: geometry, generation: generation, archive: archive)
    }
}
