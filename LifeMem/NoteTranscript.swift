import Foundation

struct NoteTranscript {
    private struct Phrase {
        let text: String
        let range: Range<TimeInterval>
    }

    private var phrases: [Phrase] = []

    // Timed results can revise an earlier phrase or start a new one after a pause.
    // Untimed hypotheses are previews. Only settled, timed phrases are kept.
    mutating func update(_ text: String, range: Range<TimeInterval>?, settled: Bool) -> String {
        let previous: ArraySlice<Phrase>
        if let range {
            previous = phrases.prefix { $0.range.upperBound <= range.lowerBound + 0.05 && $0.range.lowerBound < range.lowerBound }
        } else {
            // Older recognizers may keep reporting the whole task instead of just the current utterance.
            let cumulative = phrases.indices.first { index in
                text.hasPrefix(phrases[index...].reduce("") { Self.join($0, $1.text) })
            }
            previous = phrases.prefix(upTo: cumulative ?? phrases.endIndex)
        }
        if settled, let range {
            phrases = Array(previous) + [Phrase(text: text, range: range)]
        }
        return Self.join(previous.reduce("") { Self.join($0, $1.text) }, text)
    }

    static func join(_ prefix: String, _ words: String) -> String {
        let needsSpace = prefix.last.map { $0.isASCII && ($0.isLetter || $0.isNumber) } == true
            && words.first.map { $0.isASCII && ($0.isLetter || $0.isNumber) } == true
        return prefix + (needsSpace ? " " : "") + words
    }
}
