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

enum VaultError: Error { case invalidPDF, tooLarge, missingFixture, checksum, geometry }

/// Immutable app-owned source files; importing never mutates an existing version.
@MainActor final class DocumentVault {
    let root: URL
    private(set) var charts: [LocalChart]
    private var indexURL: URL { root.appendingPathComponent("index.json") }

    init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        let index = root.appendingPathComponent("index.json")
        charts = FileManager.default.fileExists(atPath: index.path)
            ? try JSONDecoder().decode([LocalChart].self, from: Data(contentsOf: index)) : []
    }

    func importPDF(_ source: URL, name: String, fixtureID: UUID? = nil) throws -> LocalChart {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 100 * 1024 * 1024 else { throw VaultError.tooLarge }
        let data = try Data(contentsOf: source, options: .mappedIfSafe)
        guard data.count == size else { throw VaultError.checksum }
        _ = try validate(data)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let versionID = fixtureID ?? UUID()
        let chart = LocalChart(id: versionID, name: name,
                               filename: "\(versionID.uuidString).pdf", sha256: hash, bytes: data.count)
        if let fixtureID, let existing = charts.first(where: { $0.id == fixtureID }) {
            guard existing.sha256 == hash else { throw VaultError.checksum }
            _ = try open(existing)
            return existing
        }
        let target = root.appendingPathComponent(chart.filename)
        try data.write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var updated = charts; updated.append(chart)
        do { try JSONEncoder().encode(updated).write(to: indexURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
        catch { try FileManager.default.removeItem(at: target); throw error }
        charts = updated
        return chart
    }

    func open(_ chart: LocalChart) throws -> PDFDocument {
        let data = try Data(contentsOf: root.appendingPathComponent(chart.filename), options: .mappedIfSafe)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard data.count == chart.bytes, hash == chart.sha256 else { throw VaultError.checksum }
        return try validate(data)
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
