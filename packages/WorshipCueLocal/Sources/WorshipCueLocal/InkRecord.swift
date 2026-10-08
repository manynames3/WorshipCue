import Foundation
import WorshipCueCore

/// Immutable personal-layer key captured by each canvas and every save request.
public struct InkAddress: Codable, Hashable, Sendable {
    public let churchID: UUID
    public let ownerID: UUID
    public let versionID: UUID
    public let pageIndex: Int

    public init(churchID: UUID, ownerID: UUID, versionID: UUID, pageIndex: Int) throws {
        guard pageIndex >= 0 else { throw InkStoreError.invalidRecord }
        self.churchID = churchID; self.ownerID = ownerID
        self.versionID = versionID; self.pageIndex = pageIndex
    }
    public var key: String {
        "\(churchID.uuidString)/\(ownerID.uuidString)/\(versionID.uuidString)/\(pageIndex)"
    }
}

public struct PageGeometry: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let cropX: Double, cropY: Double, cropWidth: Double, cropHeight: Double
    public let rotation: Int

    public init(cropX: Double, cropY: Double, cropWidth: Double, cropHeight: Double, rotation: Int) throws {
        _ = try CanonicalPage(cropX: cropX, cropY: cropY, cropWidth: cropWidth,
                              cropHeight: cropHeight, rotation: rotation)
        schemaVersion = 1
        self.cropX = cropX; self.cropY = cropY; self.cropWidth = cropWidth
        self.cropHeight = cropHeight; self.rotation = rotation
    }
    public var width: Double { rotation == 90 || rotation == 270 ? cropHeight : cropWidth }
    public var height: Double { rotation == 90 || rotation == 270 ? cropWidth : cropHeight }

    /// PDF native bottom-left coordinates to displayed, rotated CropBox top-left points.
    public func canonicalPoint(pdfX: Double, pdfY: Double) -> (x: Double, y: Double) {
        let x = pdfX - cropX, y = pdfY - cropY
        switch rotation {
        case 90: return (y, x)
        case 180: return (cropWidth - x, y)
        case 270: return (cropHeight - y, cropWidth - x)
        default: return (x, cropHeight - y)
        }
    }
    public func pdfPoint(x: Double, y: Double) -> (x: Double, y: Double) {
        switch rotation {
        case 90: return (cropX + y, cropY + x)
        case 180: return (cropX + cropWidth - x, cropY + y)
        case 270: return (cropX + cropWidth - y, cropY + cropHeight - x)
        default: return (cropX + x, cropY + cropHeight - y)
        }
    }
    public func validate() throws {
        guard schemaVersion == 1 else { throw InkStoreError.invalidRecord }
        _ = try PageGeometry(cropX: cropX, cropY: cropY, cropWidth: cropWidth,
                             cropHeight: cropHeight, rotation: rotation)
    }
}

public struct InkSnapshot: Sendable, Equatable {
    public let address: InkAddress
    public let geometry: PageGeometry
    public let generation: Int64
    public let archive: Data
    public init(address: InkAddress, geometry: PageGeometry, generation: Int64, archive: Data) {
        self.address = address; self.geometry = geometry
        self.generation = generation; self.archive = archive
    }
}

extension InkSnapshot {
    /// A delayed disk read cannot replace a newer snapshot already committed in this process.
    public static func restoreCandidate(durable: InkSnapshot?, recent: InkSnapshot?, pending: InkSnapshot?) throws -> InkSnapshot? {
        let snapshots = [durable, recent, pending].compactMap { $0 }
        guard let newest = snapshots.max(by: { $0.generation < $1.generation }) else { return nil }
        for snapshot in snapshots {
            guard snapshot.address == newest.address, snapshot.geometry == newest.geometry else {
                throw InkStoreError.invalidRecord
            }
            if snapshot.generation == newest.generation, snapshot.archive != newest.archive {
                throw InkStoreError.generationConflict
            }
        }
        return newest
    }
}

public enum InkStoreError: Error, Equatable {
    case invalidRecord, geometryMismatch, staleGeneration, generationConflict, archiveTooLarge
}
