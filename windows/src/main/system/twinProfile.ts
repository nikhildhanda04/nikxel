import * as fs from "fs";
import { nikxelPath, writeAtomic } from "../core/paths";

/// What Nikxel has learned about the user over time, in ~/.nikxel/twin/profile.md.
/// Separate from the user's own userContext, which this never touches.
/// Mirrors TwinProfile.swift.
const escapeRegExp = (s: string) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
const file = () => nikxelPath("twin/profile.md");

export const TwinProfile = {
  get learned(): string {
    try { return fs.readFileSync(file(), "utf8"); } catch { return ""; }
  },
  set learned(v: string) {
    if (v) writeAtomic(file(), v);
    else { try { fs.rmSync(file(), { force: true }); } catch { /* already gone */ } }
  },

  /// The learned profile as a prompt block, or "" when empty. The
  /// <!--corrections--> region is machine data and never goes into prompts.
  get injectedBlock(): string {
    let t = this.learned;
    const a = t.indexOf("<!--corrections-->");
    const b = a < 0 ? -1 : t.indexOf("<!--/corrections-->", a);
    if (b >= 0) t = t.slice(0, a) + t.slice(b + "<!--/corrections-->".length);
    t = t.trim();
    return t ? `What Nikxel has learned about this user over time — their work, the correct names and terms they use, and how they talk and write. Match it.\n${t}` : "";
  },

  /// `wrong -> right` lines inside the <!--corrections--> region of `learned`.
  corrections(): { wrong: string; right: string }[] {
    const t = this.learned;
    const a = t.indexOf("<!--corrections-->");
    const b = a < 0 ? -1 : t.indexOf("<!--/corrections-->", a);
    if (b < 0) return [];
    const out: { wrong: string; right: string }[] = [];
    for (const line of t.slice(a + "<!--corrections-->".length, b).split(/\r?\n/)) {
      const p = line.split(" -> ");
      if (p.length === 2 && p[0].trim()) out.push({ wrong: p[0].trim(), right: p[1].trim() });
    }
    return out;
  },

  /// The text of every `[ts] Me: ...` line in a meeting transcript (the user's own mic channel).
  selfLines(transcript: string): string[] {
    return transcript.split(/\r?\n/).flatMap(line => {
      const i = line.indexOf("] Me: ");
      return i < 0 ? [] : [line.slice(i + "] Me: ".length)];
    });
  },

  /// The user's own sent WhatsApp texts, newest first, from wa_sent.jsonl.
  recentSentMessages(limit = 40): string[] {
    let t: string;
    try { t = fs.readFileSync(nikxelPath("wa_sent.jsonl"), "utf8"); } catch { return []; }
    const texts: string[] = [];
    for (const line of t.split(/\r?\n/)) {
      try { const o = JSON.parse(line); if (typeof o.text === "string") texts.push(o.text); } catch { /* skip */ }
    }
    return texts.slice(-limit).reverse();
  },

  /// Applies each learned correction, case-insensitive and on word boundaries.
  correct(text: string): string {
    let out = text;
    for (const { wrong, right } of this.corrections())
      out = out.replace(new RegExp("\\b" + escapeRegExp(wrong) + "\\b", "gi"), () => right);
    return out;
  },
};
