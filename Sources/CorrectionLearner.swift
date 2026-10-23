import Foundation

/// Works out which words the user fixed in text Velo just pasted, so the
/// personal dictionary can learn them (like Wispr Flow's auto-learned words).
enum CorrectionLearner {
    struct Correction: Equatable {
        let heard: String // As pasted, lowercased: the dictionary key.
        let meant: String // As the user wrote it.
    }

    /// `after` is the field right after pasting, with the pasted text at `span` (character offsets);
    /// `later` is the same field after the user's edits.
    static func corrections(after: String, span: Range<Int>, later: String) -> [Correction] {
        let a = Array(after), l = Array(later)
        guard span.lowerBound >= 0, span.upperBound <= a.count, !span.isEmpty else { return [] }
        var prefix = 0
        while prefix < min(a.count, l.count) && a[prefix] == l[prefix] { prefix += 1 }
        // Edits before the pasted text shift everything; don't guess.
        guard prefix >= span.lowerBound else { return [] }
        var suffix = 0
        while suffix < min(a.count, l.count) - prefix && a[a.count - 1 - suffix] == l[l.count - 1 - suffix] { suffix += 1 }
        let tail = a.count - span.upperBound
        let exactEnd = suffix >= tail
        // When the text after the paste changed too (the user kept typing), only a window is comparable.
        let end = exactEnd ? l.count - tail : min(l.count, span.upperBound + span.count + 80)
        guard end >= span.lowerBound else { return [] }
        return diff(String(a[span]), String(l[span.lowerBound..<end]), trailingIsReliable: exactEnd)
    }

    static func diff(_ original: String, _ edited: String, trailingIsReliable: Bool) -> [Correction] {
        let old = original.split(whereSeparator: \.isWhitespace).map(String.init)
        let new = edited.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !old.isEmpty, !new.isEmpty else { return [] }
        func token(_ word: String) -> String { word.trimmingCharacters(in: .punctuationCharacters) }

        // Longest common subsequence of words (case-sensitive, so capitalization fixes count).
        var table = Array(repeating: Array(repeating: 0, count: new.count + 1), count: old.count + 1)
        for i in stride(from: old.count - 1, through: 0, by: -1) {
            for j in stride(from: new.count - 1, through: 0, by: -1) {
                table[i][j] = token(old[i]) == token(new[j]) ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var anchors: [(Int, Int)] = []
        var i = 0, j = 0
        while i < old.count && j < new.count {
            if token(old[i]) == token(new[j]) { anchors.append((i, j)); i += 1; j += 1 }
            else if table[i + 1][j] >= table[i][j + 1] { i += 1 } else { j += 1 }
        }

        // Unmatched stretches between anchors are the edits.
        var blocks: [(ArraySlice<String>, ArraySlice<String>)] = []
        var previous = (-1, -1)
        for anchor in anchors + [(old.count, new.count)] {
            let isTrailing = anchor == (old.count, new.count)
            let removed = old[(previous.0 + 1)..<anchor.0]
            let added = new[(previous.1 + 1)..<anchor.1]
            if !(removed.isEmpty && added.isEmpty) && (!isTrailing || trailingIsReliable) {
                blocks.append((removed, added))
            }
            previous = anchor
        }
        // Many or large edits mean the user rewrote the text rather than fixing words.
        let changedWords = blocks.reduce(0) { $0 + $1.0.count }
        guard blocks.count <= 3, changedWords <= max(4, old.count / 2) else { return [] }

        return blocks.compactMap { removed, added in
            guard (1...4).contains(removed.count), (1...4).contains(added.count) else { return nil }
            let heard = removed.joined(separator: " ").trimmingCharacters(in: .punctuationCharacters)
            let meant = added.joined(separator: " ").trimmingCharacters(in: .punctuationCharacters)
            guard heard.count >= 2, meant.count >= 2, heard != meant, looksAlike(heard, meant) else { return nil }
            return Correction(heard: heard.lowercased(), meant: meant)
        }
    }

    /// A misrecognition sounds and looks similar ("whisper flow" → "Wispr Flow");
    /// a different word ("good" → "great") is an edit, not something to learn.
    static func looksAlike(_ a: String, _ b: String) -> Bool {
        let x = Array(a.lowercased().filter { $0.isLetter || $0.isNumber })
        let y = Array(b.lowercased().filter { $0.isLetter || $0.isNumber })
        guard !x.isEmpty, !y.isEmpty else { return false }
        var row = Array(0...y.count)
        for i in 1...x.count {
            var diagonal = row[0]
            row[0] = i
            for j in 1...y.count {
                let above = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, diagonal + (x[i - 1] == y[j - 1] ? 0 : 1))
                diagonal = above
            }
        }
        return Double(row[y.count]) / Double(max(x.count, y.count)) <= 0.5
    }
}
