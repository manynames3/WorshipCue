import Foundation

public enum AnnotationScope: Equatable, Hashable, Sendable {
    case personal(ownerID: UUID)
    case team(performanceItemID: UUID)
}

public struct LayerIdentity: Equatable, Hashable, Sendable {
    public let churchID: UUID
    public let versionID: UUID
    public let pageIndex: Int
    public let scope: AnnotationScope
    public init(churchID: UUID, versionID: UUID, pageIndex: Int, scope: AnnotationScope) throws {
        guard pageIndex >= 0 else { throw DomainError.invalidPage }
        self.churchID = churchID; self.versionID = versionID
        self.pageIndex = pageIndex; self.scope = scope
    }

    public func mayOverlayTeam(on version: UUID, performanceItem: UUID,
                               church: UUID, page: Int) -> Bool {
        guard case let .team(item) = scope else { return false }
        return churchID == church && versionID == version && item == performanceItem && pageIndex == page
    }
}

public struct CanonicalPage: Equatable, Sendable {
    public let cropX: Double, cropY: Double, cropWidth: Double, cropHeight: Double
    public let rotation: Int
    public init(cropX: Double, cropY: Double, cropWidth: Double, cropHeight: Double, rotation: Int) throws {
        guard [cropX,cropY,cropWidth,cropHeight].allSatisfy({ $0.isFinite }),
              cropWidth > 0, cropHeight > 0, [0,90,180,270].contains(rotation) else {
            throw DomainError.invalidPage
        }
        self.cropX = cropX; self.cropY = cropY; self.cropWidth = cropWidth
        self.cropHeight = cropHeight; self.rotation = rotation
    }
    public var displayedWidth: Double { rotation == 90 || rotation == 270 ? cropHeight : cropWidth }
    public var displayedHeight: Double { rotation == 90 || rotation == 270 ? cropWidth : cropHeight }
}

/// Geometry helpers only. Actual PDFKit coordinate round trips require native tests.
public enum NotePlacement {
    public static func uniformScale(sourceWidth: Double, sourceHeight: Double,
                                    maxWidth: Double, maxHeight: Double) throws -> Double {
        let values = [sourceWidth, sourceHeight, maxWidth, maxHeight]
        guard values.allSatisfy({ $0.isFinite && $0 > 0 }) else { throw DomainError.invalidPage }
        return min(maxWidth / sourceWidth, maxHeight / sourceHeight)
    }
}
