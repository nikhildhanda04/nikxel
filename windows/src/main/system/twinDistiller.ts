import { TwinProfile } from "./twinProfile";
import { cblog } from "../core/diag";

let distillChain: Promise<void> = Promise.resolve(); // one distill at a time

/// The LLM merge pass that keeps TwinProfile.learned current. Mirrors TwinDistiller.swift.
const HEADER = /^[#*\s]*(Who|Work & projects|Names & terms|Voice & style|Relationships)[*\s:]*$/;

function trimLongestSection(t: string, cap: number): string {
  const lines = t.split("\n");
  // Each line's section (-1 before the first header); null = never dropped (headers, the corrections block).
  const section: (number | null)[] = [];
  let s = -1, inCorrections = false;
  for (const l of lines) {
    if (l.includes("<!--corrections-->")) inCorrections = true;
    if (HEADER.test(l)) { s++; section.push(null); } else section.push(inCorrections ? null : s);
    if (l.includes("<!--/corrections-->")) inCorrections = false;
  }
  let total = t.length;
  while (total > cap) {
    const size = new Map<number, number>();
    section.forEach((sec, i) => { if (sec !== null) size.set(sec, (size.get(sec) ?? 0) + lines[i].length + 1); });
    if (!size.size) break;
    const longest = [...size].reduce((a, b) => (b[1] > a[1] ? b : a))[0];
    const i = section.lastIndexOf(longest);
    total -= lines[i].length + 1;
    lines.splice(i, 1); section.splice(i, 1);
  }
  return lines.join("\n");
}

export const TwinDistiller = {
  mergePrompt(current: string, meetingSelfLines: string[], sentMessages: string[], daySummary: string): string {
    const list = (a: string[]) => (a.length ? a.map(l => `- ${l}`).join("\n") : "(none)");
    return `You maintain a short profile of the user so an assistant can write and speak like them. Merge the NEW SIGNALS into the CURRENT PROFILE and return the FULL updated profile, nothing else (no commentary, no code fences).

Sections, in order: Who / Work & projects / Names & terms / Voice & style / Relationships.
- Keep what is still true, add what is new, drop what is stale. Be terse; prefer facts over prose.
- Voice & style: a short description of how they talk and write, plus a few verbatim example lines taken from their own words below.
- Keep the corrections block, refreshed. It must stay exactly in this form, one \`wrong -> right\` per line:
<!--corrections-->
wrong -> right
<!--/corrections-->
  Only add a correction when a term is clearly mis-heard or mis-spelled and the right form is certain. Corrections are applied one after another, so do NOT chain them (no \`right\` that is itself another entry's \`wrong\`). Matching is on whole words, so prefer ordinary word terms; avoid symbols like C++ or .NET.
- The whole profile, corrections block included, must stay under 3000 characters. Rough budget: Who 300, Work & projects 1000 (one line per active project — where it stands, not its history), Names & terms 400, Voice & style 600, Relationships 400, corrections the rest. Every section must be present.

CURRENT PROFILE:
${current || "(empty)"}

NEW SIGNALS

Lines the user said in meetings:
${list(meetingSelfLines)}

Messages the user sent on WhatsApp:
${list(sentMessages)}

Summary of the user's day:
${daySummary || "(none)"}`;
  },

  /// `old` when `next` is blank or not profile-shaped; else `next` cut to `cap` characters on a line boundary.
  /// `old` when `next` is blank or not profile-shaped; else `next` brought under `cap` characters.
  /// Over the cap, the longest section loses its last lines first, so a long project list can't
  /// push Voice & style, Relationships and the corrections off the end.
  accept(next: string, old: string, cap = 3000): string {
    let t = next.trim();
    if (!t) return old;
    // Malformed (refusal, prose, garbage): must have a section header line or the corrections marker.
    if (!new RegExp(HEADER.source, "m").test(t) && !t.includes("<!--corrections-->")) return old;
    if (t.length <= cap) return t;
    t = trimLongestSection(t, cap);
    if (t.length <= cap) return t;
    if (t[cap] === "\n") return t.slice(0, cap);
    const head = t.slice(0, cap), nl = head.lastIndexOf("\n");
    return nl < 0 ? head : head.slice(0, nl);
  },

  async distill(meetingSelfLines: string[], sentMessages: string[], daySummary: string,
                runPrompt: (prompt: string, kind: string) => Promise<string>): Promise<void> {
    if (!meetingSelfLines.length && !sentMessages.length && !daySummary) return;
    const run = distillChain.then(async () => {
      const old = TwinProfile.learned;
      try {
        const out = await runPrompt(this.mergePrompt(old, meetingSelfLines, sentMessages, daySummary), "twin-distill");
        TwinProfile.learned = this.accept(out, old);
      } catch (e) { cblog(`twin distill failed: ${e}`); }
    });
    distillChain = run;
    await run;
  },
};
