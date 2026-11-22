/// The pure half of what Nikxel learns from habits and edits: given the logs, what would it
/// suggest? Nothing here changes anything -- learning.ts asks the user first. Port of src/Habits.swift.

/// When each day ended: the last activity sample of that day, as minutes after the day's
/// midnight (past 1440 when it ran on after midnight). A day runs 6am to 6am, so 1:30am
/// belongs to the evening before. Lock-screen samples don't count as activity, and the day
/// `now` is in hasn't ended yet, so it's left out.
export function dayEnds(samples: { t: number; app: string }[], now: Date): number[] {
  const dayOf = (ms: number) => { const d = new Date(ms - 6 * 3600_000); return new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime(); };
  const current = dayOf(now.getTime());
  const last = new Map<number, number>();
  for (const s of samples) {
    if (["LockApp", "LogonUI", "loginwindow", "ScreenSaverEngine"].includes(s.app)) continue;
    const at = s.t * 1000, day = dayOf(at);
    if (day !== current && at > (last.get(day) ?? -Infinity)) last.set(day, at);
  }
  return [...last].map(([day, at]) => Math.floor((at - day) / 60_000));
}

/// The summary time to suggest, in minutes after the day's midnight (1440+ = the early hours
/// after it): 30 minutes past the usual wrap-up, rounded up to the half hour. null when there
/// are fewer than 7 days to go on, or the user usually stops before 10:30pm, or the
/// suggestion is within an hour of `current`.
export function summaryTime(ends: number[], current: number): number | null {
  if (ends.length < 7) return null;
  const median = [...ends].sort((a, b) => a - b)[Math.floor(ends.length / 2)];
  if (median < 22 * 60 + 30) return null;
  const suggested = Math.min(Math.ceil((median + 30) / 30) * 30, 1440 + 5 * 60);  // never past 5am
  return Math.abs(suggested - current) >= 60 ? suggested : null;
}

/// "2:30am" for 1590, "11pm" for 1380.
export function clock(minutes: number): string {
  const m = minutes % 1440, h = Math.floor(m / 60), mm = m % 60, h12 = h % 12 === 0 ? 12 : h % 12;
  return `${h12}${mm === 0 ? "" : ":" + String(mm).padStart(2, "0")}${h < 12 ? "am" : "pm"}`;
}

/// Enough "record it?" answers, nearly all yes, to offer recording calls without asking.
export function offerAutoRecord(recorded: number, skipped: number): boolean {
  const total = recorded + skipped;
  return total >= 5 && recorded * 5 >= total * 4;
}

/// The prompt that looks over the user's summary fixes for one standing rule.
export function rulePrompt(edits: string[], decided: string[]): string {
  return `Below are fixes the user typed into Nikxel's meeting-summary editor over the last 30 days, oldest first.

Find ONE kind of fix about how meeting summaries should ALWAYS be written -- structure, length, what to include or leave out, how to word things -- that the user asked for at least twice. Ignore one-off corrections of facts in a single summary (a wrong name, a wrong date, a mis-heard word).

Already suggested to the user -- don't suggest these again or anything that means the same:
${decided.length ? decided.map(d => `- ${d}`).join("\n") : "(none)"}

Reply with exactly one line of JSON and nothing else:
{"rule": "<one instruction for future meeting summaries, imperative, under 20 words>", "times": <how many fixes asked for it>, "example": "<one of the user's fixes, verbatim>"}
or the single word NONE.

FIXES:
${edits.map(e => `- ${e}`).join("\n")}`;
}

/// The rule out of the reply to `rulePrompt`, or null for NONE, prose, or a rule seen fewer than twice.
export function parseRule(reply: string): { rule: string; times: number; example: string } | null {
  const a = reply.indexOf("{"), b = reply.lastIndexOf("}");
  if (a < 0 || b < a) return null;
  try {
    const o = JSON.parse(reply.slice(a, b + 1));
    const rule = typeof o.rule === "string" ? o.rule.trim() : "";
    if (!rule || typeof o.times !== "number" || o.times < 2) return null;
    return { rule, times: o.times, example: typeof o.example === "string" ? o.example : "" };
  } catch { return null; }
}
