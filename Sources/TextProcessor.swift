import Foundation

/// Deterministic, zero-model cleanup. No transcript is saved to disk.
enum TextProcessor {
    static func polish(_ original: String, replacements: [String: String]) -> String {
        var value = original.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return "" }

        // Restrict cleanup to clearly nonsemantic hesitation noises.
        value = replacing(value, pattern: #"(?i),?\s*(?<!\w)(?:uh+|um+|erm+)(?!\w)\s*[,;]?\s*"#, with: "")
        value = replacing(value, pattern: #"[ \t]+([,;:.!?])"#, with: "$1")
        value = replacing(value, pattern: #"[ \t]{2,}"#, with: " ")
        value = replacing(value, pattern: #"[,;][ \t]*([.!?])"#, with: "$1")

        // Longest match first; use word boundaries to avoid replacing substrings in other words.
        for (spoken, preferred) in replacements.sorted(by: { $0.key.count > $1.key.count }) {
            guard !spoken.isEmpty, !preferred.isEmpty else { continue }
            let escaped = NSRegularExpression.escapedPattern(for: spoken)
            value = replacing(value, pattern: "(?i)(?<![\\p{L}\\p{N}])\(escaped)(?![\\p{L}\\p{N}])", with: preferred, literal: true)
        }
        value = replacing(value, pattern: #"[ \t]{2,}"#, with: " ")
        value = applyVoiceCommands(value)
        value = formatBullets(value)
        value = formatNumberedList(value)
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "bullet point milk, bullet point eggs" → "- Milk\n- Eggs".
    static func formatBullets(_ text: String) -> String {
        let pattern = #"(?i)[,.;]?[ \t]*(?<![\p{L}\p{N}])(?:new |next )?bullet(?: point)?(?![\p{L}\p{N}])[,.:]?[ \t]*"#
        guard text.range(of: pattern, options: .regularExpression) != nil else { return text }
        let parts = replacing(text, pattern: pattern, with: "\u{1F}").components(separatedBy: "\u{1F}")
        let intro = listIntro(parts[0])
        var raw = Array(parts.dropFirst())
        guard let last = raw.popLast() else { return text }
        let (lastItem, after) = splitAfterList(last)
        let items = (raw + [lastItem]).map(listItem).filter { !$0.isEmpty }
        guard !items.isEmpty else { return text }
        return intro + items.map { "- " + $0 }.joined(separator: "\n") + after
    }

    /// The last item ends with its sentence; anything said after it becomes a paragraph below the list.
    private static func splitAfterList(_ text: String) -> (item: String, after: String) {
        guard let end = text.range(of: #"[.!?]+\s+(?=\S)|\s*\n\s*(?=\S)"#, options: .regularExpression) else {
            return (text, "")
        }
        let rest = String(text[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = rest.first else { return (text, "") }
        // What follows may hold another list of its own.
        let paragraph = formatNumberedList(formatBullets(first.uppercased() + rest.dropFirst()))
        return (String(text[..<end.lowerBound]), "\n\n" + paragraph)
    }

    private static let ordinals = ["first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth"]
    private static let numbers = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]

    /// Spoken enumerations become a numbered list: "first …, second …, and third …" or
    /// "number one … number two …". Ordinals ("first", "1st") need three in a row so a stray "second"
    /// isn't a list. Everything said before the list stays, as its lead-in line.
    static func formatNumberedList(_ text: String) -> String {
        let ordinal = ordinals.joined(separator: "|"), number = numbers.joined(separator: "|")
        // Spoken glue after a marker: "the first one is tomatoes", "second is milk", "third item: spoons".
        let filler = "(?:[ \\t]+(?:one|thing|item|point|step))?(?:[ \\t]+(?:is|was|would be|will be))?(?![\\p{L}\\p{N}])"
        let pattern = "(?i)(?:^|[.,;:!?][ \\t]+(?:and[ \\t]+)?|[ \\t]+and[ \\t]+|[ \\t]+(?=number[ \\t])|\\n)(?:the[ \\t]+)?(?:(\(ordinal))(?:ly)?|number[ \\t]+(\(number)|\\d+)|(finally|lastly)|(\\d{1,2})(?:st|nd|rd|th))(?![\\p{L}\\p{N}])" + filler + "[,:]?[ \\t]*"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        var chain: [NSTextCheckingResult] = []
        var spokenNumbers = true
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            func group(_ index: Int) -> String? {
                match.range(at: index).location == NSNotFound ? nil : ns.substring(with: match.range(at: index)).lowercased()
            }
            var position: Int?
            if let word = group(1) { position = (ordinals.firstIndex(of: word) ?? -1) + 1 }
            else if let digits = group(4) { position = Int(digits) } // "1st", "2nd", "3rd"
            else if let word = group(2) { position = numbers.firstIndex(of: word).map { $0 + 1 } ?? Int(word) }
            else if group(3) != nil, chain.count >= 2 { position = chain.count + 1 }
            guard let position else { continue }
            if position == chain.count + 1 {
                if group(1) != nil || group(3) != nil || group(4) != nil {
                    spokenNumbers = spokenNumbers && group(1) == nil && group(4) == nil
                }
                chain.append(match)
            } else if position == 1 {
                // A finished list followed by a new "first": the new list is handled after this one.
                if chain.count >= (spokenNumbers ? 2 : 3) { break }
                chain = [match]; spokenNumbers = group(2) != nil
            } else if chain.count >= 2 { break }
        }
        guard chain.count >= (spokenNumbers ? 2 : 3) else { return text }
        let intro = listIntro(ns.substring(to: chain[0].range.location))
        var items: [String] = []
        var after = ""
        for (index, match) in chain.enumerated() {
            let start = match.range.location + match.range.length
            let isLast = index + 1 == chain.count
            let end = isLast ? ns.length : chain[index + 1].range.location
            var raw = ns.substring(with: NSRange(location: start, length: end - start))
            if isLast { (raw, after) = splitAfterList(raw) }
            items.append(listItem(raw))
        }
        guard !items.contains(where: \.isEmpty) else { return text }
        return intro + items.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n") + after
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "’", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    private static func listIntro(_ text: String) -> String {
        var intro = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = intro.last, ",;:.".contains(last) { intro.removeLast() }
        return intro.isEmpty ? "" : intro + ":\n"
    }

    private static func listItem(_ text: String) -> String {
        var item = text.trimmingCharacters(in: .whitespacesAndNewlines)
        item = replacing(item, pattern: #"(?i)[,;]?\s+and(?: then)?$"#, with: "")
        while let last = item.last, ",;:.".contains(last) { item.removeLast() }
        guard let first = item.first else { return "" }
        return first.uppercased() + item.dropFirst()
    }

    /// Spoken "new line" / "new paragraph" become line breaks; the next sentence is capitalized.
    static func applyVoiceCommands(_ text: String) -> String {
        var value = replacing(text, pattern: #"(?i),?[ \t]*(?<![\p{L}\p{N}])new paragraph(?![\p{L}\p{N}])[,.]?[ \t]*"#, with: "\n\n")
        value = replacing(value, pattern: #"(?i),?[ \t]*(?<![\p{L}\p{N}])new line(?![\p{L}\p{N}])[,.]?[ \t]*"#, with: "\n")
        guard value.contains("\n") else { return value }
        var result = ""
        var capitalizeNext = false
        for character in value {
            if character == "\n" { capitalizeNext = true; result.append(character); continue }
            if capitalizeNext && character.isLetter { result += character.uppercased(); capitalizeNext = false; continue }
            if !character.isWhitespace { capitalizeNext = false }
            result.append(character)
        }
        return result
    }

    private static func replacing(_ text: String, pattern: String, with replacement: String, literal: Bool = false) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        if !literal { return regex.stringByReplacingMatches(in: text, range: range, withTemplate: replacement) }
        // Avoid treating $ and backslashes in a user-defined preferred spelling as replacement syntax.
        let matches = regex.matches(in: text, range: range)
        var result = text
        for match in matches.reversed() {
            guard let r = Range(match.range, in: result) else { continue }
            result.replaceSubrange(r, with: replacement)
        }
        return result
    }
}

/// Personal dictionary: words (misheard → preferred spelling, also used as recognition hints)
/// and snippets (spoken trigger → expansion). Both are plain JSON files on this Mac.
final class VocabularyStore {
    let directory: URL
    let file: URL
    let snippetsFile: URL
    private(set) var replacements: [String: String] = [:]
    private(set) var snippets: [String: String] = [:]

    init() {
        directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BreezeDictate", isDirectory: true)
        file = directory.appendingPathComponent("vocabulary.json")
        snippetsFile = directory.appendingPathComponent("snippets.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: file.path) {
            write(["gigadoo": "Giggadoo", "giga doo": "Giggadoo"], to: file)
        }
        if !FileManager.default.fileExists(atPath: snippetsFile.path) { write([:], to: snippetsFile) }
        reload()
    }

    func reload() {
        replacements = Self.read(file)
        snippets = Self.read(snippetsFile)
    }

    /// Words and snippets together, for text cleanup.
    var allReplacements: [String: String] { replacements.merging(snippets) { word, _ in word } }

    /// Preferred spellings: recognition hints and AI spelling instructions. Snippets are excluded.
    var contextualStrings: [String] { Array(Set(replacements.values)).sorted().prefix(100).map { $0 } }

    func addWord(heard: String, preferred: String) {
        reload()
        replacements[heard.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)] = preferred
        write(replacements, to: file)
    }

    func addSnippet(trigger: String, expansion: String) {
        reload()
        snippets[trigger.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)] = expansion
        write(snippets, to: snippetsFile)
    }

    func removeWord(_ heard: String) {
        reload()
        replacements[heard] = nil
        write(replacements, to: file)
    }

    func removeSnippet(_ trigger: String) {
        reload()
        snippets[trigger] = nil
        write(snippets, to: snippetsFile)
    }

    private static func read(_ url: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let items = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return items
    }

    private func write(_ items: [String: String], to url: URL) {
        if let data = try? JSONSerialization.data(withJSONObject: items, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
