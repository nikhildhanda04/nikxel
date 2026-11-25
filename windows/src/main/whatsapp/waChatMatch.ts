/// The WhatsApp chats a chat question names (ChatSession reads them live).
/// Port of src/WAChatMatch.swift.

const ABOUT_MESSAGES = new Set(["whatsapp", "wa", "group", "chat", "chats", "message", "messages", "msg", "msgs",
  "text", "texted", "say", "said", "says", "saying", "sent", "wrote", "reply",
  "replied", "asked", "told", "ping", "pinged", "discussed", "talking"]);
const GENERIC = new Set(["group", "team", "chat", "chats", "whatsapp", "official", "community", "with", "from"]);

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
