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

const virama = "्";

const independentVowels: Record<string, string> = {
  "अ": "a", "आ": "aa", "इ": "i", "ई": "ee", "उ": "u", "ऊ": "oo",
  "ऋ": "ri", "ए": "e", "ऐ": "ai", "ओ": "o", "औ": "au",
  "ऑ": "o", "ऎ": "e", "ऒ": "o",
};

const vowelSigns: Record<string, string> = {
  "ा": "aa", "ि": "i", "ी": "ee", "ु": "u",
  "ू": "oo", "ृ": "ri", "े": "e", "ै": "ai",
  "ो": "o", "ौ": "au", "ॉ": "o", "ॅ": "e",
};

const consonants: Record<string, string> = {
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
  "क़": "q", "ख़": "kh", "ग़": "gh", "ज़": "z",
  "ड़": "r", "ढ़": "rh", "फ़": "f", "य़": "y",
};

/// U+093C turns the preceding consonant into its Urdu/English-sound
/// variant: ज + nukta is "z", not "j".
const nukta = "़";
const nuktaForms: Record<string, string> = {
  k: "q", kh: "kh", g: "gh", j: "z", d: "r", dh: "rh", ph: "f", y: "y",
};

const standalone: Record<string, string> = {
  "ं": "n",   // anusvara
  "ँ": "n",   // chandrabindu
  "ः": "h",   // visarga
  "।": ".", "॥": ".",
  "०": "0", "१": "1", "२": "2", "३": "3", "४": "4",
  "५": "5", "६": "6", "७": "7", "८": "8", "९": "9",
};

const has = (table: Record<string, string>, c: string) => Object.prototype.hasOwnProperty.call(table, c);

/// Whether this scalar keeps the current word going (a letter, vowel sign,
/// nukta or virama) as opposed to ending it (space, punctuation, danda).
function isWordCharacter(c: string): boolean {
  return has(consonants, c) || has(vowelSigns, c)
    || has(independentVowels, c) || c === virama || c === nukta
    || c === "ं" || c === "ँ" || c === "ः";
}

export const Devanagari = {
  /// True if the text contains any Devanagari (U+0900–U+097F).
  contains(text: string): boolean {
    return /[ऀ-ॿ]/.test(text);
  },

  /// Romanizes every Devanagari run, leaving all other text untouched, so a
  /// mixed Hinglish line keeps its already-English words as they are.
  romanize(text: string): string {
    if (!Devanagari.contains(text)) return text;
    let out = "";
    // A consonant carries an inherent "a" unless a vowel sign or virama
    // follows, so it has to be held until the next character is known.
    let pendingConsonant: string | null = null;
    const scalars = Array.from(text);

    // Hindi drops the inherent vowel at the end of a word -- कल is "kal",
    // not "kala". Without this every Hinglish word picks up a trailing "a".
    const flush = (wordContinues: boolean) => {
      if (pendingConsonant === null) return;
      out += wordContinues ? pendingConsonant + "a" : pendingConsonant;
      pendingConsonant = null;
    };

    for (let i = 0; i < scalars.length; i++) {
      const scalar = scalars[i];
      const next = i + 1 < scalars.length ? scalars[i + 1] : null;
      const nextIsWord = next !== null && isWordCharacter(next);
      if (has(consonants, scalar)) {
        flush(true);
        pendingConsonant = consonants[scalar];
        // Nothing else in the word follows, so no inherent vowel.
        if (!nextIsWord) flush(false);
      } else if (has(vowelSigns, scalar)) {
        const sign = vowelSigns[scalar];
        if (pendingConsonant !== null) { out += pendingConsonant + sign; pendingConsonant = null; } else { out += sign; }
      } else if (scalar === nukta) {
        if (pendingConsonant !== null) {
          pendingConsonant = nuktaForms[pendingConsonant] ?? pendingConsonant;
          if (!nextIsWord) flush(false);
        }
      } else if (scalar === virama) {
        if (pendingConsonant !== null) { out += pendingConsonant; pendingConsonant = null; }
      } else if (has(independentVowels, scalar)) {
        flush(true);
        out += independentVowels[scalar];
      } else if (has(standalone, scalar)) {
        // Anusvara/chandrabindu nasalize the syllable already emitted,
        // so the inherent vowel belongs before the "n".
        flush(true);
        out += standalone[scalar];
      } else {
        flush(false);
        out += scalar;
      }
    }
    flush(false);
    return out;
  },
};
