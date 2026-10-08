import Foundation
import GRDB
import WorshipCueCore

/// GRDB serializes the short metadata transactions; PDF/ink work stays outside them.
public final class LocalLibraryStore: Sendable {
    private let database: DatabaseQueue
    public init(url: URL) throws {
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = FULL")
        }
        database = try DatabaseQueue(path: url.path, configuration: configuration)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("m1-library-v1") { db in
            try db.execute(sql: """
                CREATE TABLE library_flags (key TEXT PRIMARY KEY, value INTEGER NOT NULL);
                CREATE TABLE songs (id TEXT PRIMARY KEY NOT NULL, record BLOB NOT NULL);
                CREATE TABLE assets (id TEXT PRIMARY KEY NOT NULL, record BLOB NOT NULL);
                CREATE TABLE versions (
                  id TEXT PRIMARY KEY NOT NULL, song_id TEXT NOT NULL REFERENCES songs(id),
                  asset_id TEXT NOT NULL UNIQUE REFERENCES assets(id), number INTEGER NOT NULL CHECK(number > 0),
                  record BLOB NOT NULL, UNIQUE(song_id, number), UNIQUE(song_id, id));
                CREATE TABLE preferences (song_id TEXT PRIMARY KEY NOT NULL, version_id TEXT NOT NULL,
                  FOREIGN KEY(song_id, version_id) REFERENCES versions(song_id, id));
                CREATE TABLE bookmarks (version_id TEXT PRIMARY KEY NOT NULL REFERENCES versions(id),
                  page_index INTEGER NOT NULL CHECK(page_index >= 0));
                CREATE TABLE setlists (id TEXT PRIMARY KEY NOT NULL, revision INTEGER NOT NULL CHECK(revision > 0),
                  record BLOB NOT NULL);
                CREATE TABLE setlist_items (
                  id TEXT PRIMARY KEY NOT NULL, setlist_id TEXT NOT NULL REFERENCES setlists(id) ON DELETE CASCADE,
                  song_id TEXT NOT NULL, version_id TEXT NOT NULL, position INTEGER NOT NULL CHECK(position >= 0),
                  record BLOB NOT NULL, UNIQUE(setlist_id, position),
                  FOREIGN KEY(song_id, version_id) REFERENCES versions(song_id, id));
                """)
        }
        try migrator.migrate(database)
    }

    public func snapshot() throws -> LibrarySnapshot {
        try database.read { db in
            let songs: [LibrarySong] = try Self.records(db, "songs")
            let versions: [LibraryVersion] = try Self.records(db, "versions")
            let assets: [LibraryAsset] = try Self.records(db, "assets")
            var setlists: [LocalSetlist] = try Self.records(db, "setlists")
            for index in setlists.indices {
                setlists[index].items = try Row.fetchAll(db, sql: "SELECT record FROM setlist_items WHERE setlist_id = ? ORDER BY position",
                    arguments: [setlists[index].id.uuidString]).map { try JSONDecoder().decode(SetlistItem.self, from: $0["record"]) }
            }
            var preferences: [UUID: UUID] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT * FROM preferences") {
                guard let song = UUID(uuidString: row["song_id"]), let version = UUID(uuidString: row["version_id"])
                else { throw LibraryError.invalidMetadata }
                preferences[song] = version
            }
            return LibrarySnapshot(songs: songs, versions: versions, assets: assets,
                                   setlists: setlists.sorted { $0.serviceDate > $1.serviceDate }, preferences: preferences)
        }
    }

    public func hasMigratedLegacyIndex() throws -> Bool {
        try database.read { db in try Int.fetchOne(db, sql: "SELECT value FROM library_flags WHERE key = 'legacy-index'") == 1 }
    }
    /// The entire legacy index becomes visible together. Reopening cannot duplicate versions.
    public func migrateLegacy(_ imports: [LibraryImport]) throws {
        try database.write { db in
            if try Int.fetchOne(db, sql: "SELECT value FROM library_flags WHERE key = 'legacy-index'") == 1 { return }
            for item in imports { _ = try Self.insert(item, db: db, allowUnknownGeometry: true) }
            try db.execute(sql: "INSERT INTO library_flags(key,value) VALUES('legacy-index',1)")
        }
    }

    /// Number allocation and batch publication share one transaction. No partial packet imports.
    public func register(_ imports: [LibraryImport]) throws -> [LibraryVersion] {
        try database.write { db in try imports.map { try Self.insert($0, db: db, allowUnknownGeometry: false) } }
    }

    /// Remote version numbers are server receipts, never renumbered by download order.
    public func cachePublished(song: LibrarySong, version: LibraryVersion, asset: LibraryAsset) throws {
        try song.validate(); try asset.validate()
        guard version.songID == song.id, version.assetID == asset.id, version.id == asset.id,
              version.number > 0, version.number <= 9_007_199_254_740_991,
              !version.label.isEmpty, version.label.count <= 300, asset.pages != nil,
              version.writtenKey.map(MusicalKey.isValid) ?? true,
              version.sourceAssetID == nil, version.sourceFirstPage == nil, version.sourceLastPage == nil
        else { throw LibraryError.invalidMetadata }
        try database.write { db in
            if let old: LibraryVersion = try Self.record(db, table: "versions", id: version.id) {
                let previous: LibraryAsset? = try Self.record(db, table: "assets", id: old.assetID)
                guard old == version, previous == asset else { throw LibraryError.immutableAsset }; return
            }
            if try !Self.exists(db, table: "songs", id: song.id) {
                try db.execute(sql: "INSERT INTO songs(id,record) VALUES(?,?)", arguments: [song.id.uuidString, try JSONEncoder().encode(song)])
            }
            try db.execute(sql: "INSERT INTO assets(id,record) VALUES(?,?)", arguments: [asset.id.uuidString, try JSONEncoder().encode(asset)])
            try db.execute(sql: "INSERT INTO versions(id,song_id,asset_id,number,record) VALUES(?,?,?,?,?)", arguments:
                [version.id.uuidString, song.id.uuidString, asset.id.uuidString, version.number, try JSONEncoder().encode(version)])
        }
    }
    private static func insert(_ item: LibraryImport, db: Database, allowUnknownGeometry: Bool) throws -> LibraryVersion {
        try item.song.validate(); try item.asset.validate()
        guard allowUnknownGeometry || item.asset.pages != nil, !item.label.isEmpty, item.label.count <= 300,
              item.writtenKey.map(MusicalKey.isValid) ?? true else { throw LibraryError.invalidMetadata }
        if let existing: LibraryVersion = try record(db, table: "versions", id: item.asset.id) {
            let asset: LibraryAsset? = try record(db, table: "assets", id: existing.assetID)
            guard asset == item.asset, existing.songID == item.song.id, existing.label == item.label,
                  existing.writtenKey == item.writtenKey, existing.sourceAssetID == item.sourceAssetID,
                  existing.sourceFirstPage == item.sourceFirstPage, existing.sourceLastPage == item.sourceLastPage
            else { throw LibraryError.immutableAsset }
            return existing
        }
        if let sourceID = item.sourceAssetID {
            let source: LibraryAsset? = try record(db, table: "assets", id: sourceID)
            guard let count = source?.pages?.count, let first = item.sourceFirstPage, let last = item.sourceLastPage,
                  first > 0, first <= last, last <= count, item.asset.pages?.count == last - first + 1
            else { throw LibraryError.invalidPageRange }
        } else if item.sourceFirstPage != nil || item.sourceLastPage != nil { throw LibraryError.invalidPageRange }
        if try !exists(db, table: "songs", id: item.song.id) {
            try db.execute(sql: "INSERT INTO songs(id,record) VALUES(?,?)", arguments: [item.song.id.uuidString, try JSONEncoder().encode(item.song)])
        }
        let next = (try Int.fetchOne(db, sql: "SELECT MAX(number) FROM versions WHERE song_id = ?", arguments: [item.song.id.uuidString]) ?? 0) + 1
        let version = LibraryVersion(id: item.asset.id, songID: item.song.id, number: next, assetID: item.asset.id,
            label: item.label, writtenKey: item.writtenKey, sourceAssetID: item.sourceAssetID,
            sourceFirstPage: item.sourceFirstPage, sourceLastPage: item.sourceLastPage)
        try db.execute(sql: "INSERT INTO assets(id,record) VALUES(?,?)", arguments: [item.asset.id.uuidString, try JSONEncoder().encode(item.asset)])
        try db.execute(sql: "INSERT INTO versions(id,song_id,asset_id,number,record) VALUES(?,?,?,?,?)",
            arguments: [version.id.uuidString, version.songID.uuidString, version.assetID.uuidString, next, try JSONEncoder().encode(version)])
        return version
    }

    /// A legacy receipt may gain verified geometry once; an established manifest never changes.
    public func recordGeometry(assetID: UUID, pages: [PageGeometry]) throws {
        try database.write { db in
            guard let asset: LibraryAsset = try Self.record(db, table: "assets", id: assetID) else { throw LibraryError.missingRecord }
            if let previous = asset.pages {
                guard previous == pages else { throw LibraryError.immutableAsset }; return
            }
            let verified = LibraryAsset(id: asset.id, filename: asset.filename, sha256: asset.sha256, bytes: asset.bytes, pages: pages)
            try verified.validate()
            try db.execute(sql: "UPDATE assets SET record = ? WHERE id = ?", arguments: [try JSONEncoder().encode(verified), assetID.uuidString])
        }
    }
    public func updateSong(_ song: LibrarySong) throws {
        try song.validate()
        try database.write { db in
            guard try Self.exists(db, table: "songs", id: song.id) else { throw LibraryError.missingRecord }
            try db.execute(sql: "UPDATE songs SET record = ? WHERE id = ?", arguments: [try JSONEncoder().encode(song), song.id.uuidString])
        }
    }
    public func setPreferred(songID: UUID, versionID: UUID) throws {
        try database.write { db in
            guard let version: LibraryVersion = try Self.record(db, table: "versions", id: versionID), version.songID == songID
            else { throw LibraryError.missingRecord }
            try db.execute(sql: "INSERT INTO preferences(song_id,version_id) VALUES(?,?) ON CONFLICT(song_id) DO UPDATE SET version_id=excluded.version_id",
                arguments: [songID.uuidString, versionID.uuidString])
        }
    }
    public func bookmark(versionID: UUID) throws -> Int {
        try database.read { db in try Int.fetchOne(db, sql: "SELECT page_index FROM bookmarks WHERE version_id = ?", arguments: [versionID.uuidString]) ?? 0 }
    }
    public func remember(versionID: UUID, pageIndex: Int) throws {
        try database.write { db in
            guard let version: LibraryVersion = try Self.record(db, table: "versions", id: versionID),
                  let asset: LibraryAsset = try Self.record(db, table: "assets", id: version.assetID),
                  let pages = asset.pages, pages.indices.contains(pageIndex) else { throw LibraryError.invalidPageRange }
            try db.execute(sql: "INSERT INTO bookmarks(version_id,page_index) VALUES(?,?) ON CONFLICT(version_id) DO UPDATE SET page_index=excluded.page_index",
                arguments: [versionID.uuidString, pageIndex])
        }
    }

    public func saveSetlist(_ draft: LocalSetlist) throws -> LocalSetlist {
        guard !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, draft.title.count <= 300,
              draft.serviceDate.timeIntervalSince1970.isFinite, TimeZone(identifier: draft.timeZoneID) != nil,
              draft.items.count <= 200, Set(draft.items.map(\.id)).count == draft.items.count,
              draft.items.allSatisfy({ $0.performanceKey.map(MusicalKey.isValid) ?? true }) else { throw LibraryError.invalidMetadata }
        return try database.write { db in
            let revision = try Int.fetchOne(db, sql: "SELECT revision FROM setlists WHERE id = ?", arguments: [draft.id.uuidString]) ?? 0
            guard revision == draft.revision else { throw LibraryError.staleSetlist }
            let saved = draft.replacingRevision(revision + 1)
            var header = saved; header.items = []
            try db.execute(sql: "INSERT INTO setlists(id,revision,record) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET revision=excluded.revision,record=excluded.record",
                arguments: [saved.id.uuidString, saved.revision, try JSONEncoder().encode(header)])
            try db.execute(sql: "DELETE FROM setlist_items WHERE setlist_id = ?", arguments: [saved.id.uuidString])
            for (position, item) in saved.items.enumerated() {
                try db.execute(sql: "INSERT INTO setlist_items(id,setlist_id,song_id,version_id,position,record) VALUES(?,?,?,?,?,?)",
                    arguments: [item.id.uuidString, saved.id.uuidString, item.songID.uuidString, item.versionID.uuidString,
                                position, try JSONEncoder().encode(item)])
            }
            return saved
        }
    }

    private static func exists(_ db: Database, table: String, id: UUID) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM \(table) WHERE id = ?)", arguments: [id.uuidString]) ?? false
    }
    private static func record<T: Decodable>(_ db: Database, table: String, id: UUID) throws -> T? {
        try Data.fetchOne(db, sql: "SELECT record FROM \(table) WHERE id = ?", arguments: [id.uuidString])
            .map { try JSONDecoder().decode(T.self, from: $0) }
    }
    private static func records<T: Decodable>(_ db: Database, _ table: String) throws -> [T] {
        try Data.fetchAll(db, sql: "SELECT record FROM \(table) ORDER BY rowid").map { try JSONDecoder().decode(T.self, from: $0) }
    }
}
