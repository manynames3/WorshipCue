import Foundation
import CryptoKit
import PDFKit
import WorshipCueLocal

struct LocalChart: Codable, Identifiable, Equatable {
    let id: UUID
    let name: String
    let filename: String
    let sha256: String
    let bytes: Int
}

enum VaultError: Error { case invalidPDF, tooLarge, missingFixture, checksum, geometry, invalidRange }

struct PacketSlice: Identifiable {
    let id = UUID()
    var song: LibrarySong
    var firstPage: Int
    var lastPage: Int
    var writtenKey: String?
    var label: String
}

/// Immutable app-owned source files; importing never mutates an existing version.
@MainActor final class DocumentVault {
    let root: URL
    let library: LocalLibraryStore
    private(set) var charts: [LocalChart]

    init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        library = try LocalLibraryStore(url: root.appendingPathComponent("catalog.sqlite"))
        charts = []
        if try !library.hasMigratedLegacyIndex() {
            let index = root.appendingPathComponent("index.json")
            let legacy = FileManager.default.fileExists(atPath: index.path)
                ? try JSONDecoder().decode([LocalChart].self, from: Data(contentsOf: index)) : []
            try library.migrateLegacy(legacy.map { chart in
                LibraryImport(asset: LibraryAsset(id: chart.id, filename: chart.filename, sha256: chart.sha256,
                    bytes: chart.bytes, pages: nil), song: Self.initialSong(id: chart.id, name: chart.name),
                    label: chart.name, writtenKey: Self.fixtureKey(chart.id))
            })
            // Keep index.json as a migration receipt. SQLite is authoritative from now on.
        }
        try reload()
    }

    func importPDF(_ source: URL, name: String, fixtureID: UUID? = nil,
                   song: LibrarySong? = nil, writtenKey: String? = nil) throws -> LocalChart {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 100 * 1024 * 1024 else { throw VaultError.tooLarge }
        let data = try Data(contentsOf: source, options: .mappedIfSafe)
        guard data.count == size else { throw VaultError.checksum }
        let document = try validate(data)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let versionID = fixtureID ?? UUID()
        let chart = LocalChart(id: versionID, name: name,
                               filename: "\(versionID.uuidString).pdf", sha256: hash, bytes: data.count)
        if let fixtureID, let existing = charts.first(where: { $0.id == fixtureID }) {
            guard existing.sha256 == hash else { throw VaultError.checksum }
            _ = try open(existing)
            return existing
        }
        let asset = LibraryAsset(id: chart.id, filename: chart.filename, sha256: chart.sha256, bytes: chart.bytes,
                                 pages: try geometry(document))
        let target = root.appendingPathComponent(chart.filename)
        guard !FileManager.default.fileExists(atPath: target.path) else { throw LibraryError.immutableAsset }
        try data.write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        do {
            try verifyPromoted(asset)
            _ = try library.register([LibraryImport(asset: asset, song: song ?? Self.initialSong(id: chart.id, name: name),
                label: name, writtenKey: writtenKey ?? Self.fixtureKey(chart.id))])
        } catch {
            // Only this operation's newly created file is eligible for cleanup.
            do { try FileManager.default.removeItem(at: target) }
            catch { /* An unreferenced immutable file is safe; catalog publication already failed. */ }
            throw error
        }
        try reload()
        return chart
    }

    func open(_ chart: LocalChart) throws -> PDFDocument {
        guard let receipt = try library.snapshot().assets.first(where: { $0.id == chart.id }),
              receipt.filename == chart.filename, receipt.sha256 == chart.sha256, receipt.bytes == chart.bytes
        else { throw VaultError.checksum }
        let data = try Data(contentsOf: root.appendingPathComponent(chart.filename), options: .mappedIfSafe)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard data.count == chart.bytes, hash == chart.sha256 else { throw VaultError.checksum }
        let document = try validate(data)
        let pages = try geometry(document)
        try library.recordGeometry(assetID: chart.id, pages: pages)
        return document
    }

    /// A downloaded immutable receipt is committed only after bytes and native page geometry agree.
    func cachePublished(_ data: Data, song: LibrarySong, version: LibraryVersion,
                        sha256: String, bytes: Int, pages: [PageGeometry]) throws {
        guard data.count == bytes, bytes <= 100 * 1024 * 1024,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == sha256,
              try geometry(validate(data)) == pages else { throw VaultError.checksum }
        let asset = LibraryAsset(id: version.id, filename: "\(version.id.uuidString).pdf", sha256: sha256, bytes: bytes, pages: pages)
        let target = root.appendingPathComponent(asset.filename)
        if FileManager.default.fileExists(atPath: target.path) {
            guard try Data(contentsOf: target) == data else { throw VaultError.checksum }
            try library.cachePublished(song: song, version: version, asset: asset)
        } else {
            try data.write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            do { try verifyPromoted(asset); try library.cachePublished(song: song, version: version, asset: asset) }
            catch { try? FileManager.default.removeItem(at: target); throw error }
        }
        try reload()
    }

    func sourceBytes(_ versionID: UUID) throws -> Data {
        guard let chart = charts.first(where: { $0.id == versionID }) else { throw LibraryError.missingRecord }
        _ = try open(chart)
        return try Data(contentsOf: root.appendingPathComponent(chart.filename), options: .mappedIfSafe)
    }

    func slicePacket(_ chart: LocalChart, slices: [PacketSlice]) throws -> [LocalChart] {
        let source = try open(chart)
        guard !slices.isEmpty, slices.count <= 200 else { throw VaultError.invalidRange }
        for slice in slices {
            guard slice.firstPage > 0, slice.firstPage <= slice.lastPage, slice.lastPage <= source.pageCount else {
                throw VaultError.invalidRange
            }
            try slice.song.validate()
        }
        var imports: [LibraryImport] = []
        var created: [URL] = []
        var published = false
        do {
            for slice in slices {
                let derived = PDFDocument()
                for index in (slice.firstPage - 1)..<slice.lastPage {
                    guard let page = source.page(at: index)?.copy() as? PDFPage else { throw VaultError.invalidPDF }
                    derived.insert(page, at: derived.pageCount)
                }
                guard let data = derived.dataRepresentation() else { throw VaultError.invalidPDF }
                let verified = try validate(data)
                let id = UUID(), filename = "\(id.uuidString).pdf"
                let asset = LibraryAsset(id: id, filename: filename,
                    sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), bytes: data.count,
                    pages: try geometry(verified))
                let target = root.appendingPathComponent(filename)
                try data.write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                created.append(target)
                try verifyPromoted(asset)
                imports.append(LibraryImport(asset: asset, song: slice.song, label: slice.label, writtenKey: slice.writtenKey,
                    sourceAssetID: chart.id, sourceFirstPage: slice.firstPage, sourceLastPage: slice.lastPage))
            }
            let versions = try library.register(imports)
            published = true
            try reload()
            return versions.compactMap { version in charts.first { $0.id == version.id } }
        } catch {
            // Originals, published versions and ink are never part of cleanup.
            if !published {
                for file in created {
                    do { try FileManager.default.removeItem(at: file) }
                    catch { /* Keep an unreferenced file for recovery if cleanup itself fails. */ }
                }
            }
            throw error
        }
    }

    private func reload() throws {
        let snapshot = try library.snapshot()
        charts = try snapshot.versions.map { version in
            guard let asset = snapshot.assets.first(where: { $0.id == version.assetID }) else { throw LibraryError.missingRecord }
            return LocalChart(id: version.id, name: version.label, filename: asset.filename, sha256: asset.sha256, bytes: asset.bytes)
        }
    }
    private func geometry(_ document: PDFDocument) throws -> [PageGeometry] {
        try (0..<document.pageCount).map { index in
            guard let page = document.page(at: index) else { throw VaultError.invalidPDF }
            return try page.canonicalGeometry()
        }
    }
    private func verifyPromoted(_ asset: LibraryAsset) throws {
        let bytes = try Data(contentsOf: root.appendingPathComponent(asset.filename), options: .mappedIfSafe)
        guard bytes.count == asset.bytes,
              SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == asset.sha256,
              try geometry(validate(bytes)) == asset.pages else { throw VaultError.checksum }
    }
    private static func initialSong(id: UUID, name: String) -> LibrarySong {
        if fixtureKey(id) != nil {
            return LibrarySong(id: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!, title: "예시곡 A")
        }
        return LibrarySong(id: id, title: name.precomposedStringWithCanonicalMapping)
    }
    private static func fixtureKey(_ id: UUID) -> String? {
        switch id.uuidString {
        case "10000000-0000-0000-0000-000000000001", "10000000-0000-0000-0000-000000000002": return "G"
        case "10000000-0000-0000-0000-000000000003": return "A"
        default: return nil
        }
    }

    private func validate(_ data: Data) throws -> PDFDocument {
        guard let document = PDFDocument(data: data), !document.isLocked,
              document.pageCount > 0, document.pageCount <= 200 else { throw VaultError.invalidPDF }
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { throw VaultError.invalidPDF }
            _ = try page.canonicalGeometry()
        }
        return document
    }
}

extension PDFPage {
    func canonicalGeometry() throws -> PageGeometry {
        guard let native = pageRef else { throw VaultError.geometry }
        let crop = native.getBoxRect(.cropBox)
        let rotation = ((self.rotation % 360) + 360) % 360
        return try PageGeometry(cropX: crop.minX, cropY: crop.minY, cropWidth: crop.width,
                                cropHeight: crop.height, rotation: rotation)
    }
}
