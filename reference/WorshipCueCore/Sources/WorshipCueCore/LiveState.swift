import Foundation

/// Pure-domain reference. This is not a network client, UI, or authorization layer.
public enum DomainError: Error, Equatable {
    case invalidSequence, invalidKey, wrongSession, conflictingSequence
    case staleIntent, missingFile, wrongChart, invalidPage
}

public struct LiveCall: Equatable, Sendable {
    public let id: UUID
    public let sessionID: UUID
    public let sequence: Int64
    public let performanceItemID: UUID
    public let songID: UUID
    public let teamChartVersionID: UUID
    public let performanceKey: String

    public init(id: UUID, sessionID: UUID, sequence: Int64,
                performanceItemID: UUID, songID: UUID,
                teamChartVersionID: UUID, performanceKey: String) throws {
        guard sequence > 0, sequence <= 9_007_199_254_740_991 else {
            throw DomainError.invalidSequence
        }
        guard MusicalKey.isValid(performanceKey) else { throw DomainError.invalidKey }
        self.id = id; self.sessionID = sessionID; self.sequence = sequence
        self.performanceItemID = performanceItemID; self.songID = songID
        self.teamChartVersionID = teamChartVersionID; self.performanceKey = performanceKey
    }
}

public struct Chart: Equatable, Sendable {
    public let id: UUID
    public let songID: UUID
    public let writtenKey: String?
    public let pageCount: Int

    public init(id: UUID, songID: UUID, writtenKey: String?, pageCount: Int) throws {
        guard pageCount > 0 else { throw DomainError.invalidPage }
        if let key = writtenKey, !MusicalKey.isValid(key) { throw DomainError.invalidKey }
        self.id = id; self.songID = songID
        self.writtenKey = writtenKey; self.pageCount = pageCount
    }
}

public struct DisplayedChart: Equatable, Sendable {
    public let chart: Chart
    public var pageIndex: Int
    public var performanceItemID: UUID?
    public var acknowledgedCallID: UUID?
    public var acknowledgedPerformanceKey: String?

    public init(chart: Chart, pageIndex: Int = 0, performanceItemID: UUID? = nil,
                acknowledgedCallID: UUID? = nil, acknowledgedPerformanceKey: String? = nil) throws {
        guard pageIndex >= 0, pageIndex < chart.pageCount else { throw DomainError.invalidPage }
        if let key = acknowledgedPerformanceKey, !MusicalKey.isValid(key) { throw DomainError.invalidKey }
        self.chart = chart; self.pageIndex = pageIndex
        self.performanceItemID = performanceItemID
        self.acknowledgedCallID = acknowledgedCallID
        self.acknowledgedPerformanceKey = acknowledgedPerformanceKey
    }
}

public enum Connectivity: Equatable, Sendable { case online, offline, stale }

/// Carries exact identity across async file operations. Never look up "whatever is latest"
/// after a download and pretend it was the call the musician tapped.
public struct OpenIntent: Equatable, Sendable {
    public let callID: UUID
    public let sequence: Int64
    public let chartID: UUID
    fileprivate let generation: UInt64
}

public struct LiveState: Equatable, Sendable {
    public let sessionID: UUID
    public private(set) var latest: LiveCall?
    public private(set) var history: [LiveCall] = []
    public private(set) var displayed: DisplayedChart?
    public private(set) var connectivity: Connectivity = .online
    public private(set) var ended = false
    private var generation: UInt64 = 0

    public init(sessionID: UUID, displayed: DisplayedChart? = nil) {
        self.sessionID = sessionID; self.displayed = displayed
    }

    public var pending: LiveCall? {
        guard let latest, displayed?.acknowledgedCallID != latest.id else { return nil }
        return latest
    }

    /// Returns true only for a newly accepted latest announcement. Never navigates.
    @discardableResult
    public mutating func receive(_ call: LiveCall) throws -> Bool {
        guard call.sessionID == sessionID else { throw DomainError.wrongSession }
        if let previous = latest {
            if call.sequence < previous.sequence { return false }
            if call.sequence == previous.sequence {
                guard call == previous else { throw DomainError.conflictingSequence }
                return false
            }
        }
        latest = call
        history.insert(call, at: 0)
        history = Array(history.prefix(10))
        generation &+= 1 // cancels an obsolete async-open intent, not the displayed chart
        return true
    }

    public mutating func beginOpen(renderedCallID: UUID, renderedSequence: Int64,
                                   selectedChart: Chart) throws -> OpenIntent {
        guard let call = latest, call.id == renderedCallID,
              call.sequence == renderedSequence else { throw DomainError.staleIntent }
        guard selectedChart.songID == call.songID else { throw DomainError.wrongChart }
        generation &+= 1
        return OpenIntent(callID: call.id, sequence: call.sequence,
                          chartID: selectedChart.id, generation: generation)
    }

    /// The production adapter calls this only after checksum/parse verification and
    /// after confirming the user has not manually navigated during loading.
    public mutating func completeOpen(_ intent: OpenIntent, chart: Chart,
                                      fileVerified: Bool) throws {
        guard let call = latest, intent.generation == generation,
              call.id == intent.callID, call.sequence == intent.sequence else {
            throw DomainError.staleIntent
        }
        guard chart.id == intent.chartID, chart.songID == call.songID else {
            throw DomainError.wrongChart
        }
        guard fileVerified else { throw DomainError.missingFile }
        let page = displayed?.chart.id == chart.id ? (displayed?.pageIndex ?? 0) : 0
        displayed = try DisplayedChart(chart: chart, pageIndex: page,
                                       performanceItemID: call.performanceItemID,
                                       acknowledgedCallID: call.id,
                                       acknowledgedPerformanceKey: call.performanceKey)
        generation &+= 1 // completion is single-use
    }

    /// Explicit local navigation cancels async-open work and has no remote side effects.
    public mutating func navigate(to destination: DisplayedChart) {
        displayed = destination; generation &+= 1
    }

    public mutating func turnPage(to index: Int) throws {
        guard var current = displayed, index >= 0, index < current.chart.pageCount else {
            throw DomainError.invalidPage
        }
        current.pageIndex = index; displayed = current
        generation &+= 1
    }

    public mutating func setConnectivity(_ value: Connectivity) { connectivity = value }
    public mutating func endSession() { ended = true; generation &+= 1 }

    /// A historical/offline open must not be reported as opening the server's newest call.
    public var openedLatestCallID: UUID? {
        guard let latest, displayed?.acknowledgedCallID == latest.id else { return nil }
        return latest.id
    }
}

public enum VersionResolution: Equatable, Sendable {
    case ready(Chart)
    case unavailable(UUID)
}

public enum VersionResolver {
    /// Missing preference never silently falls back. Offer an explicit UI choice instead.
    public static func resolve(songID: UUID, preferredID: UUID?, teamVersionID: UUID,
                               charts: [UUID: Chart], verifiedIDs: Set<UUID>) throws -> VersionResolution {
        let desired = preferredID ?? teamVersionID
        guard let chart = charts[desired] else { return .unavailable(desired) }
        guard chart.songID == songID else { throw DomainError.wrongChart }
        guard verifiedIDs.contains(desired) else { return .unavailable(desired) }
        return .ready(chart)
    }
}
