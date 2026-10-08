import Foundation
import WorshipCueCore

public enum LibraryError: Error, Equatable {
    case invalidMetadata, missingRecord, immutableAsset, staleSetlist, invalidPageRange
}

public struct LibrarySong: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public var aliases: [String]
    public var hymnNumber: Int?
    public var hymnEdition: String?
    public var favorite: Bool

    public init(id: UUID = UUID(), title: String, aliases: [String] = [], hymnNumber: Int? = nil,
                hymnEdition: String? = nil, favorite: Bool = false) {
        self.id = id; self.title = title; self.aliases = aliases
        self.hymnNumber = hymnNumber; self.hymnEdition = hymnEdition; self.favorite = favorite
    }

    public func validate() throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 300,
              aliases.count <= 30, aliases.allSatisfy({ !$0.isEmpty && $0.count <= 300 }),
              (hymnNumber == nil && hymnEdition == nil) ||
                ((hymnNumber ?? 0) > 0 && !(hymnEdition?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true))
        else { throw LibraryError.invalidMetadata }
    }
}

/// A receipt describes immutable bytes. Unknown legacy geometry is verified on first open.
public struct LibraryAsset: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let filename: String
    public let sha256: String
    public let bytes: Int
    public let pages: [PageGeometry]?

    public init(id: UUID, filename: String, sha256: String, bytes: Int, pages: [PageGeometry]?) {
        self.id = id; self.filename = filename; self.sha256 = sha256; self.bytes = bytes; self.pages = pages
    }
    public func validate() throws {
        guard filename == "\(id.uuidString).pdf", bytes > 0, bytes <= 100 * 1024 * 1024,
              sha256.count == 64, sha256.allSatisfy({ "0123456789abcdef".contains($0) })
        else { throw LibraryError.invalidMetadata }
        if let pages {
            guard !pages.isEmpty, pages.count <= 200 else { throw LibraryError.invalidMetadata }
            for page in pages { try page.validate() }
        }
    }
}

public struct LibraryVersion: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let songID: UUID
    public let number: Int
    public let assetID: UUID
    public let label: String
    public let writtenKey: String?
    public let sourceAssetID: UUID?
    /// One-based inclusive range in an immutable weekly packet. Derived pages start at zero for ink.
    public let sourceFirstPage: Int?
    public let sourceLastPage: Int?

    public init(id: UUID, songID: UUID, number: Int, assetID: UUID, label: String, writtenKey: String?,
                sourceAssetID: UUID? = nil, sourceFirstPage: Int? = nil, sourceLastPage: Int? = nil) {
        self.id = id; self.songID = songID; self.number = number; self.assetID = assetID
        self.label = label; self.writtenKey = writtenKey; self.sourceAssetID = sourceAssetID
        self.sourceFirstPage = sourceFirstPage; self.sourceLastPage = sourceLastPage
    }
}

public struct LibraryImport: Sendable {
    public let asset: LibraryAsset
    public let song: LibrarySong
    public let label: String
    public let writtenKey: String?
    public let sourceAssetID: UUID?
    public let sourceFirstPage: Int?
    public let sourceLastPage: Int?
    public init(asset: LibraryAsset, song: LibrarySong, label: String, writtenKey: String? = nil,
                sourceAssetID: UUID? = nil, sourceFirstPage: Int? = nil, sourceLastPage: Int? = nil) {
        self.asset = asset; self.song = song; self.label = label; self.writtenKey = writtenKey
        self.sourceAssetID = sourceAssetID; self.sourceFirstPage = sourceFirstPage; self.sourceLastPage = sourceLastPage
    }
}

public enum SetlistSection: String, Codable, CaseIterable, Sendable { case planned, standby }

public struct SetlistItem: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var songID: UUID
    public var versionID: UUID
    public var performanceKey: String?
    public var section: SetlistSection
    public init(id: UUID = UUID(), songID: UUID, versionID: UUID, performanceKey: String? = nil,
                section: SetlistSection = .planned) {
        self.id = id; self.songID = songID; self.versionID = versionID
        self.performanceKey = performanceKey; self.section = section
    }
}

public struct LocalSetlist: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public var serviceDate: Date
    public var timeZoneID: String
    public private(set) var revision: Int
    public var items: [SetlistItem]
    public init(id: UUID = UUID(), title: String, serviceDate: Date = Date(),
                timeZoneID: String = TimeZone.current.identifier, revision: Int = 0, items: [SetlistItem] = []) {
        self.id = id; self.title = title; self.serviceDate = serviceDate; self.timeZoneID = timeZoneID
        self.revision = revision; self.items = items
    }
    public func replacingRevision(_ revision: Int) -> Self {
        Self(id: id, title: title, serviceDate: serviceDate, timeZoneID: timeZoneID, revision: revision, items: items)
    }
    public func clone(title: String, serviceDate: Date = Date()) -> Self {
        Self(title: title, serviceDate: serviceDate, timeZoneID: timeZoneID, items: items.map {
            SetlistItem(songID: $0.songID, versionID: $0.versionID, performanceKey: $0.performanceKey, section: $0.section)
        })
    }
}

public struct LibrarySnapshot: Equatable, Sendable {
    public var songs: [LibrarySong]
    public var versions: [LibraryVersion]
    public var assets: [LibraryAsset]
    public var setlists: [LocalSetlist]
    public var preferences: [UUID: UUID]
    public static let empty = Self(songs: [], versions: [], assets: [], setlists: [], preferences: [:])
    public func versions(for songID: UUID) -> [LibraryVersion] {
        versions.filter { $0.songID == songID }.sorted { $0.number > $1.number }
    }
    public func search(_ query: String, favoritesOnly: Bool = false) -> [LibrarySong] {
        let candidates = songs.filter { !favoritesOnly || $0.favorite }
        let query = KoreanSearch.normalize(query)
        if query.isEmpty {
            return candidates.sorted {
                if $0.favorite != $1.favorite { return $0.favorite }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        }
        return candidates.compactMap { song -> (LibrarySong, Int)? in
            var aliases = song.aliases
            if let number = song.hymnNumber { aliases.append(String(number)); aliases.append("찬송가 \(number)") }
            return KoreanSearch.score(query: query, title: song.title, aliases: aliases).map { (song, $0) }
        }.sorted {
            $0.1 == $1.1 ? $0.0.title.localizedStandardCompare($1.0.title) == .orderedAscending : $0.1 < $1.1
        }.map(\.0)
    }
}
