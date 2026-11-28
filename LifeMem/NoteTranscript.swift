import Foundation

struct NoteTranscript {
    private struct Phrase {
        let text: String
        let range: Range<TimeInterval>
    }

    private var phrases: [Phrase] = []
    private var reportsCumulativeText = false
    private var lastUpdate: (words: String, display: String)?

    // Timed results can revise an earlier phrase or start a new one after a pause.
    // Untimed hypotheses are previews. Only settled, timed phrases are kept.
    mutating func update(_ text: String, range: Range<TimeInterval>?, settled: Bool) -> String {
        if range == nil, settled, let lastUpdate, lastUpdate.words == text { return lastUpdate.display }
        let previous: ArraySlice<Phrase>
        if let range {
            previous = phrases.prefix { $0.range.upperBound <= range.lowerBound + 0.05 && $0.range.lowerBound < range.lowerBound }
        } else if reportsCumulativeText, let first = phrases.first, text.hasPrefix(first.text) {
            previous = phrases.prefix(0)
        } else {
            // An untimed preview after a pause can start with exactly the same words as the previous phrase.
            previous = phrases[...]
        }
        if settled, let range {
            let replaced = phrases.count - previous.count
            if replaced > 1 { reportsCumulativeText = true }
            if replaced == 0 && !previous.isEmpty { reportsCumulativeText = false }
            phrases = Array(previous) + [Phrase(text: text, range: range)]
        }
        let display = Self.join(previous.reduce("") { Self.join($0, $1.text) }, text)
        lastUpdate = (text, display)
        return display
    }

    static func join(_ prefix: String, _ words: String) -> String {
        let needsSpace = prefix.last.map { $0.isASCII && ($0.isLetter || $0.isNumber) } == true
            && words.first.map { $0.isASCII && ($0.isLetter || $0.isNumber) } == true
        return prefix + (needsSpace ? " " : "") + words
    }
}
