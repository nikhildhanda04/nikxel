import * as fs from "fs";
import * as crypto from "crypto";
import { nikxelPath, writeAtomic, readText } from "../core/paths";

/// Pairs this PC with the org dashboard and pushes the derived work summary.
/// DATA BOUNDARY: the only thing that ever leaves is {kind, date, items:[{id,what,minutes}]}
/// plus the device token as bearer. Never logs, twin, erp.md, raw activity or email.
/// Port of CloudSync.swift.

export interface WorkItem { id: string; what: string; minutes: number }
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

  /// No token → no-op (poster never called). Network failure is silent.
  static async pushDaily(summary: string, day: string, post: Poster = CloudSync.httpPost): Promise<void> {
    const tok = CloudSync.token();
    if (!tok) return;
    const items = CloudSync.workItems(summary).map(({ id, what, minutes }) => ({ id, what, minutes }));
    if (items.length === 0) return;
    await post("/api/summaries", { kind: "work", date: day, items }, tok);
  }

  /// Top-level bullets of "## What you worked on". Minutes from "1h 30m" / "45 min" / "2h" (0 if none).
  static workItems(md: string): WorkItem[] {
    const dur = /\b(?:(\d+)\s*h(?:ours?|rs?)?(?:\s*(\d+)\s*m(?:in(?:ute)?s?)?)?|(\d+)\s*m(?:in(?:ute)?s?)?)\b/i;
    let inSection = false;
    const out: WorkItem[] = [];
    for (const line of md.split("\n")) {
      if (line.startsWith("## ")) { inSection = line.toLowerCase().includes("what you worked on"); continue; }
      if (!inSection || !(line.startsWith("- ") || line.startsWith("* "))) continue;
      let text = line.slice(2).replace(/\*\*/g, "");
      let minutes = 0;
      const m = dur.exec(text);
      if (m) {
        minutes = Number(m[1] ?? 0) * 60 + Number(m[2] ?? 0) + Number(m[3] ?? 0);
        text = text.slice(0, m.index) + text.slice(m.index + m[0].length);
      }
      const what = text.replace(/~/g, "").replace(/\(\)/g, "").replace(/\s+/g, " ")
        .replace(/^[ —\-–:,;]+|[ —\-–:,;]+$/g, "");
      const low = what.toLowerCase();
      if (what.length < 3 || low.startsWith("none") || low.startsWith("nothing")) continue;
      const id = crypto.createHash("sha256").update(low).digest("hex").slice(0, 12);
      out.push({ id, what, minutes });
    }
    return out;
  }
}
