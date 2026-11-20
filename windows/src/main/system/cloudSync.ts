import * as fs from "fs";
import * as crypto from "crypto";
import { nikxelPath, writeAtomic, readText } from "../core/paths";

/// Pairs this PC with the org dashboard and pushes the derived work summary.
/// DATA BOUNDARY: the only thing that ever leaves is {kind, date, headline, items:[{id,section,what,type,minutes,details}]}, sent on the user's Send click,
/// plus the device token as bearer. Never logs, twin, erp.md, raw activity or email.
/// Port of CloudSync.swift.

export interface DayItem { id: string; section: string; what: string; type: string; minutes: number; details: string[] }
/// Resolves the parsed JSON body on 2xx, null on any failure.
export type Poster = (path: string, body: unknown, bearer: string | null) => Promise<any | null>;

export class CloudSync {
  /// Dev default; set NIKXEL_BACKEND to point elsewhere. No production URL yet.
  static backendBase(): string { return process.env.NIKXEL_BACKEND || "http://localhost:3001"; }
  static tokenFile(): string { return nikxelPath("cloud-token"); }

  static token(): string | null {
    const t = (readText(CloudSync.tokenFile()) ?? "").trim();
    return t === "" ? null : t;
  }

  static httpPost: Poster = async (p, body, bearer) => {
    try {
      const res = await fetch(CloudSync.backendBase() + p, {
        method: "POST",
        headers: { "Content-Type": "application/json", ...(bearer ? { Authorization: `Bearer ${bearer}` } : {}) },
        body: JSON.stringify(body),
        signal: AbortSignal.timeout(20000),
      });
      if (!res.ok) return null;
      return await res.json().catch(() => ({}));
    } catch { return null; }
  };

  static async pair(code: string, post: Poster = CloudSync.httpPost): Promise<boolean> {
    const c = code.trim();
    if (!c) return false;
    const r = await post("/api/pair", { code: c }, null);
    if (!r || typeof r.deviceToken !== "string" || !r.deviceToken) return false;
    try {
      writeAtomic(CloudSync.tokenFile(), r.deviceToken);
      fs.chmodSync(CloudSync.tokenFile(), 0o600); // best-effort on Windows
    } catch { /* chmod unsupported */ }
    return CloudSync.token() === r.deviceToken;
  }

  static readonly types = new Set(["coding", "shipped", "meeting", "research", "learning", "writing", "review", "planning", "comms", "other"]);

  /// First 12 hex of SHA-256(section + "\n" + what.toLowerCase()). The daily page uses it for data-id.
  /// A trailing "— open/done/unclear" is left out, so ticking a task doesn't change its id.
  static itemID(section: string, what: string): string {
    what = what.replace(/\s+[—–-]\s*\**(done|open|unclear)\**\.?\s*$/i, "");
    return crypto.createHash("sha256").update(section + "\n" + what.toLowerCase()).digest("hex").slice(0, 12);
  }

  /// Sends the day (minus `skip` ids) as kind "day". False on no token, no items or failed POST.
  static async pushDay(summary: string, day: string, skip: Set<string>, post: Poster = CloudSync.httpPost): Promise<boolean> {
    const tok = CloudSync.token();
    if (!tok) return false;
    const { headline, items: all } = CloudSync.dayItems(summary);
    const items = all.filter((i) => !skip.has(i.id));
    if (items.length === 0) return false;
    return (await post("/api/summaries", { kind: "day", date: day, headline, items }, tok)) !== null;
  }

  /// Top-level bullets of every "## " section but Summary; indented bullets become details.
  /// Minutes from "1h 30m" / "45 min" / "2h" (0 if none). Headline = first paragraph of Summary.
  static dayItems(md: string): { headline: string; items: DayItem[] } {
    const dur = /\b(?:(\d+)\s*h(?:ours?|rs?)?(?:\s*(\d+)\s*m(?:in(?:ute)?s?)?)?|(\d+)\s*m(?:in(?:ute)?s?)?)\b/i;
    let section = "", headline = "", headlineDone = false, open = false; // open: last top-level bullet was kept
    const out: DayItem[] = [];
    for (const line of md.split("\n")) {
      if (line.startsWith("## ")) { section = line.slice(3).toLowerCase().trim(); open = false; continue; }
      if (section === "summary") {
        const t = line.trim();
        if (!t) { if (headline) headlineDone = true; } else if (!headlineDone) headline += (headline ? " " : "") + t;
        continue;
      }
      if (!section) continue;
      if (line.startsWith("- ") || line.startsWith("* ")) {
        open = false;
        let text = line.slice(2).replace(/\*\*/g, "");
        let type = section === "meetings" ? "meeting" : "other";
        // Any [word] tag is hidden on the daily page, so strip it here; unknown ones keep the default type.
        const tag = /^\[([a-z]+)\]\s*/.exec(text);
        if (tag) { if (CloudSync.types.has(tag[1])) type = tag[1]; text = text.slice(tag[0].length); }
        let minutes = 0;
        const m = dur.exec(text);
        if (m) {
          minutes = Number(m[1] ?? 0) * 60 + Number(m[2] ?? 0) + Number(m[3] ?? 0);
          text = text.slice(0, m.index) + text.slice(m.index + m[0].length);
        }
        const what = text.replace(/~/g, "").replace(/\(\)/g, "").replace(/\s+/g, " ")
          .replace(/^[ —\-–:,;]+|[ —\-–:,;]+$/g, "");
        const low = what.toLowerCase();
        if (what.length < 3 || CloudSync.isNone(low) || ["none today", "nothing", "no calls", "no tasks"].some((p) => low.startsWith(p))) continue;
        out.push({ id: CloudSync.itemID(section, what), section, what, type, minutes, details: [] });
        open = true;
      } else if (open && /^\s+[-*] /.test(line)) {
        out[out.length - 1].details.push(line.trim().slice(2).replace(/\*\*/g, ""));
      }
    }
    return { headline, items: out };
  }

  /// Same rule as NoteExporter.isNone (kept local so this file stands alone).
  private static isNone(low: string): boolean {
    return low === "none" || low === "none." || low.startsWith("none —") || low.startsWith("none -");
  }
}
