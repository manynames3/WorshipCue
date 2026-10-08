import Foundation

public enum KeyComparison: Equatable, Sendable { case matching, different, unknown }

public enum MusicalKey {
    // Transport spelling is ASCII: Bb, F#, Am. Display may use ♭/♯ separately.
    public static func isValid(_ value: String) -> Bool { parsed(value) != nil }

    public static func compare(written: String?, performance: String) -> KeyComparison {
        guard let written, let a = parsed(written), let b = parsed(performance) else { return .unknown }
        return (a.pitch == b.pitch && a.minor == b.minor) ? .matching : .different
    }

    private static func parsed(_ value: String) -> (pitch: Int, minor: Bool)? {
        guard value.range(of: "^[A-G](#|b)?m?$", options: .regularExpression) != nil,
              let first = value.first else { return nil }
        let pitches: [Character: Int] = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11]
        guard var pitch = pitches[first] else { return nil }
        if value.contains("#") { pitch += 1 }
        if value.contains("b") { pitch -= 1 }
        return ((pitch + 12) % 12, value.hasSuffix("m"))
    }
}
