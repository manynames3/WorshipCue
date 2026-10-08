import Foundation

/// Monotonic fallback cadence for missed metadata hints, independent of the live cue polling cadence.
public struct CatalogRefreshSchedule: Sendable {
    private var lastRefresh: TimeInterval?
    public init() {}
    public func isDue(at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard let lastRefresh else { return true }
        return uptime < lastRefresh || uptime - lastRefresh >= 60
    }
    public mutating func refreshed(at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) { lastRefresh = uptime }
    public mutating func reset() { lastRefresh = nil }
}
