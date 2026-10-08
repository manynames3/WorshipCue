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
        migrator.registerMigration("m2-personal-sync-v1") { db in
            try db.execute(sql: """
                ALTER TABLE personal_ink_outbox ADD COLUMN command_id TEXT;
                ALTER TABLE personal_ink_outbox ADD COLUMN attempted INTEGER NOT NULL DEFAULT 0;
                ALTER TABLE personal_ink_outbox ADD COLUMN payload BLOB;
                CREATE TABLE personal_sync_heads (layer_key TEXT PRIMARY KEY NOT NULL,
                    revision_id TEXT NOT NULL, generation INTEGER NOT NULL, archive BLOB NOT NULL);
                CREATE TABLE personal_sync_conflict_copies (id TEXT PRIMARY KEY NOT NULL,
                    layer_key TEXT NOT NULL, archive BLOB NOT NULL, created_at REAL NOT NULL);
                """)
            for row in try Row.fetchAll(db, sql: "SELECT rowid FROM personal_ink_outbox") {
                try db.execute(sql: "UPDATE personal_ink_outbox SET command_id = ? WHERE rowid = ?", arguments: [UUID().uuidString, row["rowid"] as Int64])
            }
            try db.execute(sql: "CREATE UNIQUE INDEX personal_outbox_command ON personal_ink_outbox(command_id)")
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
            // Once attempted, retain the exact command/payload across uncertain network completion.
            try db.execute(sql: "DELETE FROM personal_ink_outbox WHERE layer_key = ? AND attempted = 0",
                           arguments: [snapshot.address.key])
            let base = try String.fetchOne(db, sql: "SELECT revision_id FROM personal_sync_heads WHERE layer_key = ?", arguments: [snapshot.address.key])
            try db.execute(sql: """
                INSERT INTO personal_ink_outbox(layer_key,generation,archive,base_server_revision,command_id) VALUES (?,?,?,?,?)
                """, arguments: [snapshot.address.key, snapshot.generation, snapshot.archive, base, UUID().uuidString])
        }
    }

    public func pendingRevisionCount() throws -> Int {
        try database.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM personal_ink_outbox") ?? 0 }
    }

    public func pendingUploads() throws -> [PersonalInkUpload] {
        try database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT o.*, i.address, i.geometry FROM personal_ink_outbox o
                JOIN personal_ink i ON i.layer_key=o.layer_key ORDER BY o.generation
                """).map { row in
                let address = try JSONDecoder().decode(InkAddress.self, from: row["address"] as Data)
                let snapshot = try Self.decode(row, expectedAddress: address)
                guard let command = UUID(uuidString: row["command_id"] as String) else { throw InkStoreError.invalidRecord }
                let base: String? = row["base_server_revision"]
                if let base, Int64(base) == nil { throw InkStoreError.invalidRecord }
                return PersonalInkUpload(commandID: command, snapshot: snapshot,
                    parentRevision: base.flatMap(Int64.init), payload: row["payload"])
            }
        }
    }

    /// Freeze before contacting the server; a newer pen-up becomes a separate unsent descendant.
    public func freezeUpload(_ command: UUID) throws {
        try database.write { db in
            try db.execute(sql: "UPDATE personal_ink_outbox SET attempted=1 WHERE command_id=?", arguments: [command.uuidString])
            guard db.changesCount == 1 else { throw InkStoreError.invalidRecord }
        }
    }
    public func attachPayload(_ payload: Data, command: UUID) throws {
        guard !payload.isEmpty, payload.count <= 32 * 1024 else { throw InkStoreError.invalidRecord }
        try database.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM personal_ink_outbox WHERE command_id=?", arguments: [command.uuidString]),
                  row["attempted"] as Int == 1 else { throw InkStoreError.invalidRecord }
            let old: Data? = row["payload"]
            guard old == nil || old == payload else { throw InkStoreError.generationConflict }
            try db.execute(sql: "UPDATE personal_ink_outbox SET payload=? WHERE command_id=?", arguments: [payload, command.uuidString])
        }
    }
    public func acknowledgeUpload(_ command: UUID, revision: Int64) throws {
        try database.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM personal_ink_outbox WHERE command_id=?", arguments: [command.uuidString]),
                  row["attempted"] as Int == 1 else { throw InkStoreError.invalidRecord }
            let key: String = row["layer_key"], archive: Data = row["archive"], generation: Int64 = row["generation"]
            let base: String? = row["base_server_revision"]
            let current = try String.fetchOne(db, sql: "SELECT revision_id FROM personal_sync_heads WHERE layer_key=?", arguments: [key])
            guard base == current else { throw InkStoreError.generationConflict }
            try db.execute(sql: "INSERT INTO personal_sync_heads(layer_key,revision_id,generation,archive) VALUES(?,?,?,?) ON CONFLICT(layer_key) DO UPDATE SET revision_id=excluded.revision_id,generation=excluded.generation,archive=excluded.archive",
                arguments: [key, String(revision), generation, archive])
            try db.execute(sql: "DELETE FROM personal_ink_outbox WHERE command_id=?", arguments: [command.uuidString])
            // Only still-unsent local descendants can adopt their now-acknowledged parent's receipt.
            try db.execute(sql: "UPDATE personal_ink_outbox SET base_server_revision=? WHERE layer_key=? AND attempted=0 AND generation>?",
                arguments: [String(revision), key, generation])
        }
    }
    public func hasPending(_ address: InkAddress) throws -> Bool {
        try database.read { db in try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM personal_ink_outbox WHERE layer_key=?)", arguments: [address.key]) ?? false }
    }
    /// Reconciliation can replace a clean head only. Dirty/local copies survive a remote conflict.
    public func installRemote(_ incoming: InkSnapshot, revision: Int64) throws -> InkSnapshot {
        try incoming.geometry.validate()
        guard revision > 0, !incoming.archive.isEmpty, incoming.archive.count <= Self.maximumArchiveBytes else { throw InkStoreError.invalidRecord }
        return try database.write { db in
            guard try !Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM personal_ink_outbox WHERE layer_key=?)", arguments: [incoming.address.key])! else { throw InkStoreError.generationConflict }
            let row = try Row.fetchOne(db, sql: "SELECT * FROM personal_ink WHERE layer_key=?", arguments: [incoming.address.key])
            let old = try row.map { try Self.decode($0, expectedAddress: incoming.address) }
            guard old == nil || old?.geometry == incoming.geometry else { throw InkStoreError.geometryMismatch }
            let previous = try String.fetchOne(db, sql: "SELECT revision_id FROM personal_sync_heads WHERE layer_key=?", arguments: [incoming.address.key]).flatMap(Int64.init)
            if let previous, previous > revision, let old { return old }
            let same = previous == revision
            if same, let old {
                guard old.archive == incoming.archive else { throw InkStoreError.generationConflict }; return old
            }
            let generation = (old?.generation ?? 0) + 1
            let saved = InkSnapshot(address: incoming.address, geometry: incoming.geometry, generation: generation, archive: incoming.archive)
            try db.execute(sql: "INSERT INTO personal_ink(layer_key,address,geometry,generation,archive) VALUES(?,?,?,?,?) ON CONFLICT(layer_key) DO UPDATE SET generation=excluded.generation,archive=excluded.archive", arguments:
                [incoming.address.key, try JSONEncoder().encode(incoming.address), try JSONEncoder().encode(incoming.geometry), generation, incoming.archive])
            try db.execute(sql: "INSERT INTO personal_sync_heads(layer_key,revision_id,generation,archive) VALUES(?,?,?,?) ON CONFLICT(layer_key) DO UPDATE SET revision_id=excluded.revision_id,generation=excluded.generation,archive=excluded.archive",
                arguments: [incoming.address.key, String(revision), generation, incoming.archive])
            return saved
        }
    }

    /// Explicit whole-copy resolution preserves both archives; it never combines strokes.
    public func resolveConflict(_ incoming: InkSnapshot, revision: Int64, keepLocal: Bool) throws -> InkSnapshot {
        try incoming.geometry.validate()
        guard revision > 0, !incoming.archive.isEmpty, incoming.archive.count <= Self.maximumArchiveBytes else { throw InkStoreError.invalidRecord }
        return try database.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM personal_ink WHERE layer_key=?", arguments: [incoming.address.key]) else { throw InkStoreError.invalidRecord }
            let old = try Self.decode(row, expectedAddress: incoming.address)
            guard old.geometry == incoming.geometry else { throw InkStoreError.geometryMismatch }
            for data in [old.archive, incoming.archive] {
                try db.execute(sql: "INSERT INTO personal_sync_conflict_copies VALUES(?,?,?,?)", arguments: [UUID().uuidString, incoming.address.key, data, Date().timeIntervalSince1970])
            }
            for outbox in try Row.fetchAll(db, sql: "SELECT archive FROM personal_ink_outbox WHERE layer_key=?", arguments: [incoming.address.key]) {
                try db.execute(sql: "INSERT INTO personal_sync_conflict_copies VALUES(?,?,?,?)", arguments: [UUID().uuidString, incoming.address.key, outbox["archive"] as Data, Date().timeIntervalSince1970])
            }
            let saved = InkSnapshot(address: old.address, geometry: old.geometry, generation: old.generation + 1,
                                    archive: keepLocal ? old.archive : incoming.archive)
            try db.execute(sql: "UPDATE personal_ink SET generation=?,archive=? WHERE layer_key=?", arguments: [saved.generation, saved.archive, old.address.key])
            try db.execute(sql: "INSERT INTO personal_sync_heads VALUES(?,?,?,?) ON CONFLICT(layer_key) DO UPDATE SET revision_id=excluded.revision_id,generation=excluded.generation,archive=excluded.archive",
                arguments: [old.address.key, String(revision), saved.generation, incoming.archive])
            try db.execute(sql: "DELETE FROM personal_ink_outbox WHERE layer_key=?", arguments: [old.address.key])
            if keepLocal {
                try db.execute(sql: "INSERT INTO personal_ink_outbox(layer_key,generation,archive,base_server_revision,command_id) VALUES(?,?,?,?,?)", arguments:
                    [old.address.key, saved.generation, saved.archive, String(revision), UUID().uuidString])
            }
            return saved
        }
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
