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
        if (c >= 1 && c <= 40 && p[c + 1] === " ") group = true;
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
const locked = (app: string) => app === "LockApp";
const awake = (s: Sample[]) => s.filter((x) => !locked(x.app)).sort((a, b) => a.t - b.t);
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

// The weekly AI review — digest in, checked items out.

/** The settings the catalogue can change, as they stand now. */
export interface Settings {
  summaryMinutes: number; autoRecordCalls: boolean; waDraftOnly: boolean; waQuietHours: boolean; waQuietFrom: number; waQuietTo: number;
  waChatTasks: boolean; summaryTemplate: string; templates: string[];
}
/** One week of what Nikxel keeps; `chats`/`bot` are the raw WhatsApp log rows `replies` reads, `declined` the answered keys. */
export interface Input {
  samples: Sample[]; meetings: Meeting[]; chats: any[]; bot: any[]; edits: string[];
  erp: { day: string; name: string; project: string }[]; settings: Settings; declined: string[];
}

/** One line, at most `n` characters. */
const cut = (s: string, n: number) => Array.from(s.split(/\s+/).filter(Boolean).join(" ")).slice(0, n).join("");
/** Lower middle of an even count, so it's always a wait that really happened. */
const median = (x: number[]) => [...x].sort((a, b) => a - b)[Math.floor((x.length - 1) / 2)];
const mins = (seconds: number) => Math.round(seconds / 60);
const pad = (n: number) => String(n).padStart(2, "0");
const hour = (h: number) => `${pad(h)}:00`;
/** "10pm", "2:30am" — habits.ts's `clock` twin, so this file stands alone. */
const clock = (minutes: number) => {
  const m = minutes % 1440, h = Math.floor(m / 60), mm = m % 60;
  return `${h % 12 === 0 ? 12 : h % 12}${mm === 0 ? "" : ":" + pad(mm)}${h < 12 ? "am" : "pm"}`;
};
/** Most first, ties by name. */
const ranked = (n: Map<string, number>) => [...n].sort((x, y) => y[1] - x[1] || cmp(x[0], y[0]));
const bump = <K>(m: Map<K, number>, k: K) => m.set(k, (m.get(k) ?? 0) + 1);
const byKey = <K extends string | number, V>(m: Map<K, V>) => [...m].sort((x, y) => (x[0] < y[0] ? -1 : x[0] > y[0] ? 1 : 0));
const day = (t: number) => { const d = new Date(t * 1000); return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`; };
const hm = (t: number) => { const d = new Date(t * 1000); return `${pad(d.getHours())}:${pad(d.getMinutes())}`; };
const hr = (t: number) => new Date(t * 1000).getHours();

/** The week as plain text for the AI: counts and times only, titles cut to 90, chat names only among the five slowest, no message text. */
export function digest(i: Input): string {
  const out: string[] = [];
  const section = (head: string, lines: string[]) => out.push(head + ":\n" + (lines.length === 0 ? "(none)" : lines.map((l) => "- " + l).join("\n")));
  const on = (b: boolean) => (b ? "on" : "off");
  const list = (x: string[]) => (x.length === 0 ? "(none)" : x.join(", "));

  const apps = new Map<string, number>(), windows = new Map<string, number>(), days = new Map<string, { first: number; last: number }>();
  // The log is written on change, so a sample owns the gap to the next one, capped at 5 min, the last one 15s —
  // as DayLogger counts it. Gaps run over every sample; a lock-screen one then counts for nothing.
  const all = [...i.samples].sort((a, b) => a.t - b.t);
  const add = (m: Map<string, number>, k: string, v: number) => m.set(k, (m.get(k) ?? 0) + v);
  all.forEach((x, n) => {
    if (locked(x.app)) return;
    const dur = n + 1 < all.length ? Math.min(all[n + 1].t - x.t, 300) : 15;
    add(apps, x.app, dur);
    const t = cut(x.title, 90);
    if (t !== "") add(windows, x.app + " — " + t, dur);
    const d = day(x.t);
    days.set(d, { first: days.get(d)?.first ?? x.t, last: x.t + dur });
  });
  section("Minutes per app (top 10)", ranked(apps).slice(0, 10).map(([k, s]) => `${k}: ${mins(s)} min`));
  section("Minutes per window title (top 10)", ranked(windows).slice(0, 10).map(([k, s]) => `${k}: ${mins(s)} min`));
  section("First and last activity per day", byKey(days).map(([d, v]) => `${d}: ${hm(v.first)}–${hm(v.last)}`));
  section("App switches per hour of day (average per active hour)",
    Object.entries(switchesByHour(i.samples)).map(([h, v]) => [Number(h), v]).sort((x, y) => x[0] - y[0]).map(([h, v]) => `${hour(h)}: ${v.toFixed(1)}`));
  section("Most frequent back-and-forth app pairs", topPairs(i.samples).map((p) => `${p.a} ↔ ${p.b} x${p.count}`));

  const starts = new Map<number, number>(), titles = new Map<string, number>();
  for (const m of i.meetings) { bump(starts, hr(m.start)); bump(titles, cut(m.title, 90)); }
  section(`Meetings (${i.meetings.length} this week)`, [
    "start hours: " + list(byKey(starts).map(([h, n]) => `${hour(h)} x${n}`)),
    "recurring titles: " + list(ranked(new Map([...titles].filter(([k, n]) => n >= 2 && k !== ""))).slice(0, 10).map(([k, n]) => `${k} x${n}`)),
    "apps opened within 30 min after a meeting: " + list(afterMeetings(i.meetings, i.samples).slice(0, 10).map((a) => `${a.app} (after ${a.meetings})`)),
  ]);

  const r = replies(i.chats, i.bot);
  const done = r.filter((x) => x.repliedAt !== null).map((x) => ({ x, wait: x.repliedAt! - x.incomingAt }));
  const group = <K>(f: (d: (typeof done)[number]) => K) => { const m = new Map<K, number[]>(); for (const d of done) m.set(f(d), [...(m.get(f(d)) ?? []), d.wait]); return m; };
  const kinds = ([["1:1", false], ["group", true]] as const).flatMap(([label, g]) => {
    const w = done.filter((d) => d.x.group === g).map((d) => d.wait);
    return w.length === 0 ? [] : [`${label} ${mins(median(w))}`];
  });
  const unanswered = new Map<string, number>();
  for (const x of r) if (x.repliedAt === null) bump(unanswered, day(x.incomingAt));
  section(`WhatsApp reply waits (median minutes, replied messages; ${done.length} replied, ${r.length - done.length} unanswered)`, [
    "by hour the message arrived: " + list(byKey(group((d) => hr(d.x.incomingAt))).map(([h, w]) => `${hour(h)} ${mins(median(w))}`)),
    "1:1 vs group: " + list(kinds),
    "5 slowest chats: " + list(ranked(new Map([...group((d) => d.x.chat)].map(([c, w]) => [c, median(w)]))).slice(0, 5).map(([c, m]) => `${c} ${mins(m)}`)),
    "unanswered by day: " + list(byKey(unanswered).map(([d, n]) => `${d} ${n}`)),
  ]);

  section("Fixes typed into meeting summaries (last 20)", i.edits.slice(-20).map((e) => cut(e, 120)));
  section("ERP tasks logged (last 40)", i.erp.slice(-40).map((e) => `${e.day} ${cut(e.name, 90)} (${cut(e.project, 90)})`));
  const s = i.settings;
  section("Current settings", [
    `summary time: ${clock(s.summaryMinutes)} (minutes=${s.summaryMinutes})`,
    `auto-record calls: ${on(s.autoRecordCalls)}`,
    `WhatsApp draft-only: ${on(s.waDraftOnly)}`,
    `WhatsApp quiet hours: ${on(s.waQuietHours)}, from ${s.waQuietFrom} to ${s.waQuietTo}`,
    `WhatsApp chat tasks: ${on(s.waChatTasks)}`,
    `summary template: ${s.summaryTemplate} (installed: ${s.templates.join(", ")})`,
  ]);
  section("Already answered -- don't suggest these again (latest 30)", i.declined.slice(-30));
  return out.join("\n\n");
}

/** What Nikxel can take on: id, params, what a yes does. `offerParams` is the matching check. */
export const catalogue: { id: string; params: string; meaning: string }[] = [
  { id: "summaryTime", params: `{"minutes": <1080-1740>}`, meaning: "write the daily summary at this time; minutes after midnight, 1080 = 6pm, 1740 = 5am next morning" },
  { id: "autoRecordCalls", params: "{}", meaning: "record and summarize calls as soon as one starts, instead of asking each time" },
  { id: "summaryRule", params: `{"text": "<instruction, under 120 characters>"}`, meaning: "add a standing instruction for how every meeting summary is written" },
  { id: "waQuietHours", params: `{"from": <0-23>, "to": <0-23>}`, meaning: "the WhatsApp bot doesn't answer between these hours; wraps past midnight when to < from" },
  { id: "waDraftOnly", params: "{}", meaning: "the WhatsApp bot types its reply into the chat and leaves sending to the person" },
  { id: "waChatTasks", params: "{}", meaning: "a WhatsApp message that plainly asks for something becomes a Google Task" },
  { id: "summaryTemplate", params: `{"name": "<an installed template>"}`, meaning: "switch to another installed template, which changes how daily, weekly and meeting summaries are written" },
];

/** The weekly review prompt: the digest, the catalogue and who the person is; the reply is one line of JSON. */
export function prompt(digest: string, context: string): string {
  return `Below is a digest of the user's last 7 days, from what Nikxel logs on their computer: apps and window titles, meetings, WhatsApp reply times, ERP tasks, and fixes they typed into meeting summaries.

Suggest at most 3 things that would make their work easier, each one of two kinds:
- advice: something they can change themselves.
- offer: a task Nikxel takes on for them from now on. ONLY the actions in the list below -- never invent one. If the idea isn't on the list, it can only be advice.

Rules:
- Ground every item in this person's own numbers from the digest and put them in "evidence" (e.g. "median WhatsApp wait 45 min for messages arriving at 14:00 and 15:00, against 8 min at 10:00"). An item you can't back with a number from the digest is left out.
- Nothing generic (take breaks, use a to-do list, turn off notifications) unless the digest shows why it fits this person.
- One sharp item beats three weak ones. If nothing is clearly worth saying, return no items.
- Don't repeat anything under "Already answered", or anything that means the same.
- Don't offer what their current settings already do.
- An offer's "line" is the question Nikxel will ask them, in plain words, starting "I'm thinking of" (e.g. "I'm thinking of writing your daily summary at 1am, since you're usually still working at midnight.").

WHAT NIKXEL CAN DO (action, params, what a yes does):
${catalogue.map((c) => `- ${c.id} ${c.params} -- ${c.meaning}`).join("\n")}

ABOUT THE USER:
${context === "" ? "(nothing given)" : context}

Reply with exactly one line of JSON and nothing else:
{"items": [{"kind": "advice", "text": "<what to try, under 30 words>", "evidence": "<their numbers>"}, {"kind": "offer", "action": "<an action from the list>", "params": {<its params>}, "line": "I'm thinking of …", "evidence": "<their numbers>"}]}
or {"items": []} when nothing is worth saying.

DIGEST:
${digest}`;
}

export type Item =
  | { kind: "advice"; text: string; evidence: string }
  | { kind: "offer"; action: string; params: Record<string, string>; line: string; evidence: string };

/** The answered-key for an offer; a summary rule shares `rule:<text>` and auto-record `autoRecord` with the daily checks. */
export function key(action: string, params: Record<string, string>): string {
  if (action === "summaryRule") return "rule:" + (params.text ?? "");
  if (action === "autoRecordCalls") return "autoRecord";
  return `weekly:${action}:` + Object.keys(params).sort(cmp).map((k) => `${k}=${params[k]}`).join(",");
}

/** An offer's params checked against the catalogue and written canonically; null when invalid or when it would change nothing. */
function offerParams(action: string, raw: any, s: Settings): Record<string, string> | null {
  const val = (k: string): string | null => {
    const v = raw?.[k];
    return typeof v === "string" ? v : typeof v === "number" && Number.isFinite(v) ? String(v) : null;  // 1560 or 1560.0, not true
  };
  const int = (k: string, lo: number, hi: number): number | null => {
    const v = val(k);
    if (v === null || !/^[+-]?\d+$/.test(v)) return null;
    const n = Number(v);
    return n >= lo && n <= hi ? n : null;
  };
  switch (action) {
    case "summaryTime": {
      const m = int("minutes", 1080, 1740);
      return m === null || m === s.summaryMinutes ? null : { minutes: String(m) };
    }
    case "autoRecordCalls": return s.autoRecordCalls ? null : {};
    case "waDraftOnly": return s.waDraftOnly ? null : {};
    case "waChatTasks": return s.waChatTasks ? null : {};
    case "summaryRule": {
      const t = val("text")?.trim() ?? "", n = Array.from(t).length;
      return n >= 1 && n <= 120 ? { text: t } : null;
    }
    case "waQuietHours": {
      const f = int("from", 0, 23), t = int("to", 0, 23);
      if (f === null || t === null || f === t || (s.waQuietHours && f === s.waQuietFrom && t === s.waQuietTo)) return null;
      return { from: String(f), to: String(t) };
    }
    case "summaryTemplate": {
      const n = val("name");
      return n !== null && s.templates.includes(n) && n !== s.summaryTemplate ? { name: n } : null;
    }
    default: return null;
  }
}

/** The items out of the reply to `prompt`: up to 3 in reply order, offers only from the catalogue, valid, changing
 *  something and not answered before. Prose, a code fence or NONE around or instead of the JSON is fine. */
export function parse(reply: string, settings: Settings, answered: Set<string>): Item[] {
  const a = reply.indexOf("{"), b = reply.lastIndexOf("}");
  if (a < 0 || b <= a) return [];
  let list: unknown;
  try { list = JSON.parse(reply.slice(a, b + 1))?.items; } catch { return []; }
  if (!Array.isArray(list)) return [];
  const out: Item[] = [], seen = new Set<string>();
  for (const x of list) {
    if (out.length >= 3) break;
    if (typeof x !== "object" || x === null || Array.isArray(x)) continue;
    const str = (k: string) => (typeof x[k] === "string" ? x[k].trim() : "");
    if (x.kind === "advice") {
      if (str("text") !== "") out.push({ kind: "advice", text: str("text"), evidence: str("evidence") });
    } else if (x.kind === "offer") {
      const p = str("line") === "" ? null : offerParams(str("action"), typeof x.params === "object" ? x.params : {}, settings);
      if (p === null) continue;
      const k = key(str("action"), p);
      if (answered.has(k) || seen.has(k)) continue;  // and not twice in one reply
      if (str("action") === "summaryTime" && answered.has("summaryTime")) continue;  // the daily summary-time question was answered
      seen.add(k);
      out.push({ kind: "offer", action: str("action"), params: p, line: str("line"), evidence: str("evidence") });
    }
  }
  return out;
}
