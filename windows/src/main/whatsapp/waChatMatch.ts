/// The WhatsApp chats a chat question names (ChatSession reads them live).
/// Port of src/WAChatMatch.swift.

const ABOUT_MESSAGES = new Set(["whatsapp", "wa", "group", "chat", "chats", "message", "messages", "msg", "msgs",
  "text", "texted", "say", "said", "says", "saying", "sent", "wrote", "reply",
  "replied", "asked", "told", "ping", "pinged", "discussed", "talking"]);
const GENERIC = new Set(["group", "team", "chat", "chats", "whatsapp", "official", "community", "with", "from",
  "what", "about", "check", "find", "that", "this", "they", "said", "when", "today", "yesterday"]);

const words = (s: string) => new Set(s.toLowerCase().split(/[^\p{L}\p{N}]+/u).filter(w => w));

/// Which recent chats a question is about: only a question about messages
/// ("say", "group", "whatsapp", …), and only chats sharing a word of 4+
/// letters with it (or all of its name). At most two, the best matches, newest first.
export function named(question: string, chats: string[]): string[] {
  const q = words(question);
  if (![...q].some(w => ABOUT_MESSAGES.has(w))) return [];
  // Every word of the name ("Raj") beats a shared word ("Nikxel" of "Nikxel Product Updates").
  const scored = chats.map(name => {
    const w = [...words(name)];
    return { name, score: w.length && w.every(x => q.has(x)) ? 100 : w.filter(x => x.length >= 4 && !GENERIC.has(x) && q.has(x)).length };
  });
  const best = Math.max(0, ...scored.map(s => s.score));
  return best === 0 ? [] : scored.filter(s => s.score === best).map(s => s.name).slice(0, 2);
}

const MONTHS = ["january", "february", "march", "april", "may", "june", "july",
  "august", "september", "october", "november", "december"];
const WEEKDAYS = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"];

/// The day a question asks about, as its local midnight: "today", "yesterday" (any
/// spelling starting "yest"), "3 days ago", a weekday ("on monday", the last
/// one before today), or a date ("24th", "on 24", "24 nov", "nov 24"; a
/// day still to come this month means last month). Null: no day asked.
export function day(question: string, now = new Date()): Date | null {
  const q = question.toLowerCase();
  const w = q.split(/[^\p{L}\p{N}]+/u).filter(x => x);
  const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  const back = (n: number) => new Date(today.getFullYear(), today.getMonth(), today.getDate() - n);
  const ago = q.match(/(\d+) days? ago/);
  if (ago) return back(parseInt(ago[1], 10));
  if (w.some(x => x.startsWith("yest"))) return back(w.includes("before") ? 2 : 1);
  // "24 nov", "24th of november", "nov 24", or alone: "24th", "on 24".
  const month = (x: string) => { const i = x.length >= 3 ? MONTHS.findIndex(m => m.startsWith(x)) : -1; return i < 0 ? null : i; };
  const num = "(\\d{1,2})(?:st|nd|rd|th)?";
  const forms: [RegExp, number, number][] = [[new RegExp("\\b" + num + "\\s+(?:of\\s+)?([a-z]+)", "g"), 1, 2], [new RegExp("([a-z]+)\\s+" + num + "\\b", "g"), 2, 1],
    [/\b(\d{1,2})(?:st|nd|rd|th)\b/g, 1, 0], [/\bon (\d{1,2})\b/g, 1, 0]];
  for (const [rx, n, mo] of forms) {
    for (const m of q.matchAll(rx)) {
      const d = parseInt(m[n], 10);
      if (!(d >= 1 && d <= 31)) continue;
      const mm = mo ? month(m[mo]) : null;
      if (mo && mm === null) continue;
      let date = new Date(today.getFullYear(), mm ?? today.getMonth(), d);
      if (date > today) date = mm === null ? new Date(date.getFullYear(), date.getMonth() - 1, d) : new Date(date.getFullYear() - 1, mm, d);
      return date;
    }
  }
  const i = WEEKDAYS.findIndex(x => w.includes(x));
  if (i >= 0) { const n = (today.getDay() - i + 7) % 7; return back(n === 0 ? 7 : n); }
  return w.includes("today") ? today : null;
}
