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

export interface Sample { t: number; app: string; title: string }
export interface Meeting { start: number; end: number; title: string }

/** Samples in time order with lock-screen ones dropped. */
const awake = (s: Sample[]) => s.filter((x) => x.app !== "LockApp").sort((a, b) => a.t - b.t);
const slot = (t: number) => { const d = new Date(t * 1000); return `${d.getFullYear()}-${d.getMonth()}-${d.getDate()}-${d.getHours()}`; };

/** App changes between consecutive samples in the same clock hour of the same day; a change across an hour boundary isn't counted. */
function switches(s: Sample[]) {
  const a = awake(s), out: { from: string; to: string; hour: number }[] = [];
  for (let i = 1; i < a.length; i++) {
    if (a[i - 1].app !== a[i].app && slot(a[i - 1].t) === slot(a[i].t)) out.push({ from: a[i - 1].app, to: a[i].app, hour: new Date(a[i].t * 1000).getHours() });
  }
  return out;
}

/** Hour of day -> average app changes per active hour (an hour is active when it has at least one sample). */
export function switchesByHour(s: Sample[]): Record<number, number> {
  const active = new Set(awake(s).map((x) => slot(x.t)));
  const hours: Record<number, number> = {}, total: Record<number, number> = {};
  for (const k of active) { const h = Number(k.split("-")[3]); hours[h] = (hours[h] ?? 0) + 1; }
  for (const w of switches(s)) total[w.hour] = (total[w.hour] ?? 0) + 1;
  return Object.fromEntries(Object.entries(hours).map(([h, n]) => [h, (total[Number(h)] ?? 0) / n]));
}

const cmp = (x: string, y: string) => (x < y ? -1 : x > y ? 1 : 0);

/** Unordered app pairs by direct switches between them, most first, ties by name. */
export function topPairs(s: Sample[], limit = 5): { a: string; b: string; count: number }[] {
  const n = new Map<string, { a: string; b: string; count: number }>();
  for (const w of switches(s)) {
    const [a, b] = [w.from, w.to].sort(cmp), k = JSON.stringify([a, b]);
    n.set(k, { a, b, count: (n.get(k)?.count ?? 0) + 1 });
  }
  return [...n.values()].sort((x, y) => y.count - x.count || cmp(x.a, y.a) || cmp(x.b, y.b)).slice(0, Math.max(0, limit));
}

/** Apps seen within 30 minutes after at least two meetings ended (once per meeting), most first, ties by name. */
export function afterMeetings(m: Meeting[], s: Sample[]): { app: string; meetings: number }[] {
  const a = awake(s), n = new Map<string, number>();
  for (const mt of m) for (const app of new Set(a.filter((x) => x.t >= mt.end && x.t < mt.end + 1800).map((x) => x.app))) n.set(app, (n.get(app) ?? 0) + 1);
  return [...n].filter(([, c]) => c >= 2).map(([app, meetings]) => ({ app, meetings })).sort((x, y) => y.meetings - x.meetings || cmp(x.app, y.app));
}
