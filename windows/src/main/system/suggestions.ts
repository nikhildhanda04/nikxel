// Pure logic behind the weekly suggestions — port of Suggestions.swift: no settings, files or clock.

/** One wait for a reply: when a chat's message arrived and when the user answered (null = still waiting). */
export interface Reply { chat: string; group: boolean; incomingAt: number; repliedAt: number | null }

/** Reply times from the chat-list log. The list only shows each chat's latest preview, so a wait opens at the first
 *  incoming after the user's last message and closes at their next one — except Nikxel's own bot sends, which aren't the user. */
export function replies(chats: any[], bot: any[]): Reply[] {
  const botRows = bot.filter((r) => typeof r?.t === "number" && typeof r.name === "string" && typeof r.text === "string");
  // The sidebar flattens newlines and whitespace runs and may end a long preview with "…", so compare on that footing.
  const norm = (s: string) => s.split(/\s+/).filter(Boolean).join(" ").replace(/(…|\.\.\.)$/, "").trim();
  const bots = botRows.map((b) => ({ ...b, text: norm(b.text) }));
  // An empty own text (a photo, a sticker) never matches: it's the user's.
  const isBot = (name: string, t: number, raw: string) => {
    const own = norm(raw);
    return own !== "" && bots.some((b) => b.name === name && Math.abs(b.t - t) <= 300 && (own.startsWith(b.text.slice(0, 40)) || b.text.startsWith(own)));
  };
  const byChat = new Map<string, { t: number; preview: string }[]>();
  for (const r of chats) {
    if (typeof r?.t !== "number" || typeof r.name !== "string" || typeof r.preview !== "string") continue;
    byChat.set(r.name, [...(byChat.get(r.name) ?? []), { t: r.t, preview: r.preview }]);
  }
  const out: Reply[] = [];
  for (const [name, rows] of byChat) {
    let open: number | null = null, group = false;
    const done: { at: number; reply: number | null }[] = [];
    for (const { t, preview: p } of rows.sort((a, b) => a.t - b.t)) {
      if (p.startsWith("You:")) {
        if (isBot(name, t, p.slice(4))) continue;
        if (open !== null) { done.push({ at: open, reply: t }); open = null; }
      } else {
        if (open === null) open = t;
        // ponytail: heuristic — a 1:1 message that itself starts "Word: ..." reads as a group; WhatsApp's list doesn't say
        const c = p.indexOf(":");
        if (c >= 1 && c <= 40) group = true;
      }
    }
    if (open !== null) done.push({ at: open, reply: null });
    for (const d of done) out.push({ chat: name, group, incomingAt: d.at, repliedAt: d.reply });
  }
  return out.sort((a, b) => a.incomingAt - b.incomingAt || (a.chat < b.chat ? -1 : a.chat > b.chat ? 1 : 0));
}
