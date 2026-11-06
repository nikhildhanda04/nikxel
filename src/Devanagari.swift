import Foundation

/// Converts Devanagari to Latin letters, so Hindi speech lands in transcripts
/// and summaries as Hinglish ("main kal meeting mein nahi aa paunga") instead
/// of Devanagari.
///
/// Whisper can't do this itself: `-l hi` returns Devanagari, and `-l en`
/// translates the meaning into English rather than writing the Hindi down.
/// Transcribing with `-l hi` and romanizing here keeps the speaker's actual
/// words.
///
/// This is a phonetic scheme aimed at readability, not a reversible standard
/// like IAST -- no diacritics, and retroflex/dental pairs collapse together,
/// which is how people type Hinglish anyway. English loanwords come back
/// spelled phonetically (फीचर -> "feechar"), since by then the original
/// spelling is gone.
enum Devanagari {
    /// True if the text contains any Devanagari (U+0900–U+097F).
    static func contains(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.value >= 0x0900 && $0.value <= 0x097F }
    }

    /// Romanizes every Devanagari run, leaving all other text untouched, so a
    /// mixed Hinglish line keeps its already-English words as they are.
    static func romanize(_ text: String) -> String {
        guard contains(text) else { return text }
        var out = ""
        // A consonant carries an inherent "a" unless a vowel sign or virama
        // follows, so it has to be held until the next character is known.
        var pendingConsonant: String?
        let scalars = Array(text.unicodeScalars)

        // Hindi drops the inherent vowel at the end of a word -- कल is "kal",
        // not "kala". Without this every Hinglish word picks up a trailing "a".
        func flush(wordContinues: Bool) {
            guard let c = pendingConsonant else { return }
            out += wordContinues ? c + "a" : c
            pendingConsonant = nil
        }

        for (i, scalar) in scalars.enumerated() {
            let next = i + 1 < scalars.count ? scalars[i + 1] : nil
            if let consonant = consonants[scalar] {
                flush(wordContinues: true)
                pendingConsonant = consonant
                // Nothing else in the word follows, so no inherent vowel.
                if !(next.map(isWordCharacter) ?? false) { flush(wordContinues: false) }
            } else if let sign = vowelSigns[scalar] {
                if let c = pendingConsonant { out += c + sign; pendingConsonant = nil } else { out += sign }
            } else if scalar == nukta {
                if let c = pendingConsonant {
                    pendingConsonant = nuktaForms[c] ?? c
                    if !(next.map(isWordCharacter) ?? false) { flush(wordContinues: false) }
                }
            } else if scalar == virama {
                if let c = pendingConsonant { out += c; pendingConsonant = nil }
            } else if let vowel = independentVowels[scalar] {
                flush(wordContinues: true)
                out += vowel
            } else if let other = standalone[scalar] {
                // Anusvara/chandrabindu nasalize the syllable already emitted,
                // so the inherent vowel belongs before the "n".
                flush(wordContinues: true)
                out += other
            } else {
                flush(wordContinues: false)
                out.unicodeScalars.append(scalar)
            }
        }
        flush(wordContinues: false)
        return out
    }

    /// Whether this scalar keeps the current word going (a letter, vowel sign,
    /// nukta or virama) as opposed to ending it (space, punctuation, danda).
    private static func isWordCharacter(_ scalar: Unicode.Scalar) -> Bool {
        consonants[scalar] != nil || vowelSigns[scalar] != nil
            || independentVowels[scalar] != nil || scalar == virama || scalar == nukta
            || scalar == "\u{0902}" || scalar == "\u{0901}" || scalar == "\u{0903}"
    }

    private static let virama: Unicode.Scalar = "\u{094D}"

    private static let independentVowels: [Unicode.Scalar: String] = [
        "अ": "a", "आ": "aa", "इ": "i", "ई": "ee", "उ": "u", "ऊ": "oo",
        "ऋ": "ri", "ए": "e", "ऐ": "ai", "ओ": "o", "औ": "au",
        "ऑ": "o", "ऎ": "e", "ऒ": "o",
    ]

    private static let vowelSigns: [Unicode.Scalar: String] = [
        "\u{093E}": "aa", "\u{093F}": "i", "\u{0940}": "ee", "\u{0941}": "u",
        "\u{0942}": "oo", "\u{0943}": "ri", "\u{0947}": "e", "\u{0948}": "ai",
        "\u{094B}": "o", "\u{094C}": "au", "\u{0949}": "o", "\u{0945}": "e",
    ]

    private static let consonants: [Unicode.Scalar: String] = [
        "क": "k", "ख": "kh", "ग": "g", "घ": "gh", "ङ": "n",
        "च": "ch", "छ": "chh", "ज": "j", "झ": "jh", "ञ": "n",
        "ट": "t", "ठ": "th", "ड": "d", "ढ": "dh", "ण": "n",
        "त": "t", "थ": "th", "द": "d", "ध": "dh", "न": "n",
        "प": "p", "फ": "ph", "ब": "b", "भ": "bh", "म": "m",
        "य": "y", "र": "r", "ल": "l", "व": "v", "ळ": "l",
        "श": "sh", "ष": "sh", "स": "s", "ह": "h",
        // Precomposed nukta forms (U+0958-U+095F). Text usually arrives with
        // these decomposed into base + U+093C instead, which `nuktaForms`
        // below handles.
        "\u{0958}": "q", "\u{0959}": "kh", "\u{095A}": "gh", "\u{095B}": "z",
        "\u{095C}": "r", "\u{095D}": "rh", "\u{095E}": "f", "\u{095F}": "y",
    ]

    /// U+093C turns the preceding consonant into its Urdu/English-sound
    /// variant: ज + nukta is "z", not "j".
    private static let nukta: Unicode.Scalar = "\u{093C}"
    private static let nuktaForms = [
        "k": "q", "kh": "kh", "g": "gh", "j": "z", "d": "r", "dh": "rh", "ph": "f", "y": "y",
    ]

    private static let standalone: [Unicode.Scalar: String] = [
        "\u{0902}": "n",   // anusvara
        "\u{0901}": "n",   // chandrabindu
        "\u{0903}": "h",   // visarga
        "।": ".", "॥": ".",
        "०": "0", "१": "1", "२": "2", "३": "3", "४": "4",
        "५": "5", "६": "6", "७": "7", "८": "8", "९": "9",
    ]
}
