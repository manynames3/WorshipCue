import Foundation

public enum KoreanSearch {
    private static let choseong = Array("ㄱㄲㄴㄷㄸㄹㅁㅂㅃㅅㅆㅇㅈㅉㅊㅋㅌㅍㅎ")

    public static func normalize(_ input: String) -> String {
        let composed = input.precomposedStringWithCanonicalMapping.lowercased()
        let kept = composed.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.punctuationCharacters.contains($0)
        }
        return String(String.UnicodeScalarView(kept))
    }

    public static func initials(_ input: String) -> String {
        var result = ""
        for scalar in normalize(input).unicodeScalars {
            let value = scalar.value
            if value >= 0xAC00 && value <= 0xD7A3 {
                result.append(choseong[Int((value - 0xAC00) / 588)])
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    /// Lower is better. Empty query is handled by the UI's recents/favorites list.
    public static func score(query: String, title: String, aliases: [String] = []) -> Int? {
        let q = normalize(query), t = normalize(title)
        guard !q.isEmpty else { return nil }
        if q == t { return 0 }
        if t.hasPrefix(q) { return 1 }
        if t.contains(q) { return 2 }
        let ti = initials(title)
        if ti == q { return 3 }
        if ti.hasPrefix(q) { return 4 }
        if ti.contains(q) { return 5 }
        if aliases.contains(where: { normalize($0) == q }) { return 6 }
        if aliases.contains(where: { normalize($0).contains(q) || initials($0).contains(q) }) { return 7 }
        return nil
    }
}
