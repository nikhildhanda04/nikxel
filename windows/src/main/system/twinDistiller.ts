import { TwinProfile } from "./twinProfile";
import { cblog } from "../core/diag";

let distillChain: Promise<void> = Promise.resolve(); // one distill at a time

/// The LLM merge pass that keeps TwinProfile.learned current. Mirrors TwinDistiller.swift.
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
- The whole profile, corrections block included, must stay under 3000 characters.

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
  accept(next: string, old: string, cap = 3000): string {
    const t = next.trim();
    if (!t) return old;
    // Malformed (refusal, prose, garbage): must have a section header line or the corrections marker.
    if (!/^[#*\s]*(Who|Work & projects|Names & terms|Voice & style|Relationships)[*\s:]*$/m.test(t)
        && !t.includes("<!--corrections-->")) return old;
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
