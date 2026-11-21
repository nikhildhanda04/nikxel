import * as fs from "fs";
import * as crypto from "crypto";
import { nikxelPath, writeAtomic, readText } from "../core/paths";

/// Pairs this PC with the org dashboard and pushes the derived work summary.
/// DATA BOUNDARY: the only things that ever leave are {kind, date, headline, items:[{id,section,what,type,minutes,details,project}]}, sent on the user's Send click
/// (items include ERP task names, stages, deadlines and project names), and a meeting's minutes minus its Client Summary, sent on Share to project
/// (never the transcript or audio), plus the device token as bearer. Never logs, twin, erp.md, raw activity or email.
/// Port of CloudSync.swift.

export interface DayItem { id: string; section: string; what: string; type: string; minutes: number; details: string[]; project: string }
/// Resolves the parsed JSON body on 2xx, null on any failure.
export type Poster = (path: string, body: unknown, bearer: string | null) => Promise<any | null>;
/// Resolves the parsed JSON body on 2xx, null on any failure.
export type Getter = (path: string, bearer: string | null) => Promise<any | null>;
export interface Project { id: string; name: string }

/// The sections that are sent (work and meetings; never chats or open tasks),
/// and the type an untagged bullet in each gets.
const SECTION_TYPES: Record<string, string> = { "what you worked on": "other", "meetings": "meeting", "browsing & reading": "research", "erp tasks": "planning" };

export class CloudSync {
  /// Dev default; set NIKXEL_BACKEND to point elsewhere. No production URL yet.
  static backendBase(): string { return process.env.NIKXEL_BACKEND || "http://localhost:3001"; }
  static tokenFile(): string { return nikxelPath("cloud-token"); }

  static token(): string | null {
    const t = (readText(CloudSync.tokenFile()) ?? "").trim();
    return t === "" ? null : t;
  }

  /// The raw response, null when the server can't be reached.
  static async send(p: string, body: unknown, bearer: string | null): Promise<Response | null> {
    try {
      return await fetch(CloudSync.backendBase() + p, {
        method: "POST",
        headers: { "Content-Type": "application/json", ...(bearer ? { Authorization: `Bearer ${bearer}` } : {}) },
        body: JSON.stringify(body),
        signal: AbortSignal.timeout(20000),
      });
    } catch { return null; }
  }

  static httpPost: Poster = async (p, body, bearer) => {
    const res = await CloudSync.send(p, body, bearer);
    if (!res?.ok) return null;
    return await res.json().catch(() => ({}));
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
    try { fs.rmSync(CloudSync.projectsFile(), { force: true }); } catch { /* best-effort */ } // the last user's project names
    return CloudSync.token() === r.deviceToken;
  }

  static readonly types = new Set(["coding", "shipped", "meeting", "research", "learning", "writing", "review", "planning", "comms", "other"]);

  /// First 12 hex of SHA-256(section + "\n" + what.toLowerCase()). The daily page uses it for data-id.
  /// A trailing "— open/done/unclear" is left out, so ticking a task doesn't change its id.
  static itemID(section: string, what: string): string {
    what = what.replace(/\s+[—–-]\s*\**(done|open|unclear)\**\.?\s*$/i, "");
    return crypto.createHash("sha256").update(section + "\n" + what.toLowerCase()).digest("hex").slice(0, 12);
  }

  /// Sends the day (minus `skip` ids; "headline" drops the headline) as kind "day". False on no token, no items (unless allowEmpty: retracts a sent day) or failed POST.
  static async pushDay(summary: string, day: string, skip: Set<string>, post: Poster = CloudSync.httpPost, allowEmpty = false): Promise<boolean> {
    const tok = CloudSync.token();
    if (!tok) return false;
    const { headline, items: all } = CloudSync.dayItems(summary);
    const items = all.filter((i) => !skip.has(i.id));
    if (items.length === 0 && !allowEmpty) return false;
    return (await post("/api/summaries", { kind: "day", date: day, headline: skip.has("headline") ? "" : headline, items }, tok)) !== null;
  }

  static httpGet: Getter = async (p, bearer) => {
    try {
      const res = await fetch(CloudSync.backendBase() + p, { headers: bearer ? { Authorization: `Bearer ${bearer}` } : {}, signal: AbortSignal.timeout(20000) });
      return res.ok ? await res.json() : null;
    } catch { return null; }
  };

  static projectsFile(): string { return nikxelPath("projects.json"); }

  /// The user's dashboard projects (for [[Project]] tags and Share to project). The last good list
  /// (projects.json) when the dashboard can't be reached; [] when unpaired or never fetched.
  static async projects(get: Getter = CloudSync.httpGet): Promise<Project[]> {
    const tok = CloudSync.token();
    if (!tok) return [];
    const parse = (v: unknown): Project[] | null => Array.isArray(v)
      ? v.filter((r) => r && typeof r.id === "string" && typeof r.name === "string").map((r) => ({ id: r.id, name: r.name }))
      : null;
    const fresh = parse(await get("/api/device/projects", tok));
    if (fresh) {
      try { writeAtomic(CloudSync.projectsFile(), JSON.stringify(fresh)); } catch { /* cache is best-effort */ }
      return fresh;
    }
    try { return parse(JSON.parse(readText(CloudSync.projectsFile()) ?? "null")) ?? []; } catch { return []; }
  }

  /// The meeting minutes as shared to a project: everything but the "## Client Summary" section
  /// (up to the next "## "), capped at the server's 20000 characters. Never the transcript.
  static meetingShareBody(md: string): string {
    let skipping = false;
    return md.split("\n").filter((line) => {
      if (line.startsWith("## ")) skipping = line.slice(3).trim().toLowerCase() === "client summary";
      return !skipping;
    }).join("\n").slice(0, 20000);
  }

  /// Sends a meeting's minutes to one of the user's projects; re-sharing the same meeting replaces it.
  /// False on no token or failed POST (404 when the user isn't on that project).
  static async shareMeeting(projectID: string, meetingID: string, title: string, date: string, body: string, post: Poster = CloudSync.httpPost): Promise<boolean> {
    const tok = CloudSync.token();
    if (!tok) return false;
    return (await post(`/api/projects/${encodeURIComponent(projectID)}/meetings`, { meeting_id: meetingID, title, date, body }, tok)) !== null;
  }

  /// Top-level bullets of every "## " section but Summary; indented bullets become details.
  /// Minutes from "1h 30m" / "45 min" / "2h" (0 if none). Headline = first paragraph of Summary.
  static dayItems(md: string): { headline: string; items: DayItem[] } {
    const body = String.raw`(?:(\d+)\s*h(?:ours?|rs?)?(?:\s*(\d+)\s*m(?:in(?:ute)?s?)?)?|(\d+)\s*m(?:in(?:ute)?s?)?)`;
    const dur = new RegExp(String.raw`\b${body}\b`, "i");
    // A trailing "(~45m)" estimate (optionally before a " — Done" tail or a final ".") beats any duration mentioned earlier in the text.
    const est = new RegExp(String.raw`\(\s*~?\s*${body}\s*\)(?=\s*(?:[—–-].*)?\.?\s*$)`, "i");
    let section = "", headline = "", headlineDone = false, open = false; // open: last top-level bullet was kept
    const out: DayItem[] = [];
    for (const line of md.split("\n")) {
      if (line.startsWith("## ")) { section = line.slice(3).toLowerCase().trim(); open = false; continue; }
      if (section === "summary") {
        const t = line.trim();
        if (!t) { if (headline) headlineDone = true; } else if (!headlineDone) headline += (headline ? " " : "") + t;
        continue;
      }
      const base = SECTION_TYPES[section];
      if (!base) continue;
      if (line.startsWith("- ") || line.startsWith("* ")) {
        open = false;
        let text = line.slice(2).replace(/\*\*/g, "");
        let type = base;
        // Any [word] tag is hidden on the daily page, so strip it here; unknown ones keep the default type.
        const tag = /^\[([a-z]+)\]\s*/.exec(text);
        if (tag) { if (CloudSync.types.has(tag[1])) type = tag[1]; text = text.slice(tag[0].length); }
        // Then an optional [[ERP project]] tag.
        const pj = /^\[\[([^\]]+?)\]\]\s*/.exec(text);
        const project = pj ? pj[1].trim() : "";
        if (pj) text = text.slice(pj[0].length);
        let minutes = 0;
        const m = section === "erp tasks" ? null : est.exec(text) ?? dur.exec(text);
        if (m) {
          minutes = Number(m[1] ?? 0) * 60 + Number(m[2] ?? 0) + Number(m[3] ?? 0);
          text = text.slice(0, m.index) + text.slice(m.index + m[0].length);
        }
        const what = text.replace(/~/g, "").replace(/\(\)/g, "").replace(/\s+/g, " ").replace(/ \.$/, ".")
          .replace(/^[ —\-–:,;]+|[ —\-–:,;]+$/g, "");
        const low = what.toLowerCase();
        if (what.length < 3 || CloudSync.isNone(low) || ["none today", "nothing", "no calls", "no tasks"].some((p) => low.startsWith(p))) continue;
        out.push({ id: CloudSync.itemID(section, what), section, what, type, minutes, details: [], project });
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
