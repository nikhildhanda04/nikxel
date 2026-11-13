import * as crypto from "crypto";
import * as fs from "fs";
import * as http from "http";
import { nikxelPath, writeAtomic, readText } from "../core/paths";
import { openUrl } from "../core/open";
import { GoogleAuth } from "../google/googleAuth";

/// Today's Slack messages for the end-of-day summary. The user signs in once
/// in the browser (Slack's own workspace picker and Allow page); after that
/// it's one `search.messages` query at summary time: no polling, no extra
/// window, nothing running in between.

/// The shared Nikxel Slack app: PKCE on, user scope `search:read`, and
/// `redirectURI` as its redirect URL. A client ID is public, so it can ship
/// in the app; PKCE is what stands in for a client secret.
export const clientId = "";
/// Fixed, because Slack only redirects to a URL registered on the app.
const port = 47119;
const redirectURI = "http://localhost:47119/slack";

// MARK: - Tokens

/// Kept out of settings.json and owner-only, like google_token.json: it
/// reads every message the user can see.
const tokenPath = nikxelPath("slack_token.json");

interface Saved { access_token?: string; refresh_token?: string; expires_at?: number; team?: string }

function loadTokens(): Saved | null {
  try { return JSON.parse(readText(tokenPath) ?? "null"); } catch { return null; }
}

export function isConnected(): boolean {
  return !!loadTokens()?.access_token;
}

export function disconnect(): void {
  try { fs.unlinkSync(tokenPath); } catch { /* already gone */ }
}

/// Stores what `oauth.v2.access` returned, for both the first exchange
/// (user token under `authed_user`) and a refresh (at the top level).
function store(obj: any): boolean {
  const t = obj.authed_user ?? obj;
  if (typeof t.access_token !== "string") return false;
  const saved: Saved = { ...loadTokens(), access_token: t.access_token };
  if (typeof t.refresh_token === "string") saved.refresh_token = t.refresh_token;
  if (typeof t.expires_in === "number") saved.expires_at = Date.now() / 1000 + t.expires_in - 60;
  if (typeof obj.team?.name === "string") saved.team = obj.team.name;
  writeAtomic(tokenPath, JSON.stringify(saved));
  fs.chmodSync(tokenPath, 0o600);
  return true;
}

/// A working access token, refreshed first if it has expired.
async function token(): Promise<string | null> {
  const saved = loadTokens();
  if (!saved?.access_token) return null;
  if (!saved.expires_at || Date.now() / 1000 <= saved.expires_at || !saved.refresh_token) return saved.access_token;
  // PKCE refresh tokens last 30 days; the daily summary refreshes well
  // inside that. A PC left off for a month has to sign in again.
  try {
    if (!store(await post("oauth.v2.access", { grant_type: "refresh_token", refresh_token: saved.refresh_token, client_id: clientId }))) return null;
  } catch { return null; }
  return loadTokens()?.access_token ?? null;
}

// MARK: - Sign-in

let server: http.Server | null = null;

/// Opens Slack's sign-in in the browser and waits on localhost for the
/// redirect. Resolves to the workspace name; throws Slack's error if not.
export function connect(): Promise<string> {
  return new Promise((resolve, reject) => {
    if (!clientId) { reject(new Error("this build has no Slack app ID yet")); return; }
    server?.close();
    const s = http.createServer();
    server = s;
    const state = crypto.randomUUID();
    const verifier = GoogleAuth.randomVerifier();
    const finish = () => { s.close(); if (server === s) server = null; };
    // An abandoned sign-in shouldn't hold the port.
    const timer = setTimeout(finish, 600_000);

    s.on("request", (req, res) => {
      const url = new URL(req.url ?? "/", redirectURI);
      if (url.pathname !== "/slack") { res.writeHead(404, { Connection: "close" }); res.end(); return; }
      const code = url.searchParams.get("code");
      const ok = !!code && url.searchParams.get("state") === state;
      const body = "<html><body style='font-family:system-ui,Segoe UI,sans-serif;text-align:center;padding:60px'><h2>"
        + (ok ? "Nikxel: Slack connected &#10003;</h2><p>You can close this tab.</p>" : "Slack sign-in failed</h2>")
        + "</body></html>";
      res.writeHead(200, { "Content-Type": "text/html; charset=utf-8", "Content-Length": Buffer.byteLength(body), Connection: "close" });
      res.end(body);
      clearTimeout(timer);
      finish();
      if (!ok) { reject(new Error(url.searchParams.get("error") ?? "cancelled")); return; }
      post("oauth.v2.access", { code: code!, code_verifier: verifier, client_id: clientId, redirect_uri: redirectURI })
        .then(obj => store(obj) ? resolve(obj.team?.name ?? "Slack") : reject(new Error("no user token in Slack's reply")))
        .catch(reject);
    });
    s.once("error", () => { clearTimeout(timer); finish(); reject(new Error(`port ${port} is busy`)); });
    s.listen(port, "127.0.0.1", () => {
      openUrl("https://slack.com/oauth/v2/authorize?" + new URLSearchParams({
        client_id: clientId,
        user_scope: "search:read",
        redirect_uri: redirectURI,
        state,
        code_challenge: GoogleAuth.challenge(verifier),
        code_challenge_method: "S256",
      }));
    });
  });
}

// MARK: - Messages

/// One line per message on `day` (Slack's own idea of the day, in the
/// user's Slack time zone), oldest first.
export async function messages(day: string): Promise<string[]> {
  const t = await token();
  if (!t) return [];
  const lines: string[] = [];
  // ponytail: newest 300 only; a big workspace's busy day gets trimmed,
  // page further if summaries start missing things.
  for (let page = 1; page <= 3; page++) {
    let m: any;
    try {
      m = (await get("search.messages", t, {
        query: `on:${day}`, sort: "timestamp", sort_dir: "desc", count: "100", page: String(page),
      })).messages;
    } catch { break; }
    for (const x of m?.matches ?? []) {
      const text = String(x.text ?? "").replace(/\n/g, " ");
      if (!text) continue;
      const ch = x.channel ?? {};
      const place = ch.is_im || ch.is_mpim ? "DM" : "#" + (ch.name ?? "?");
      const d = new Date(Number(x.ts) * 1000);
      const time = `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
      lines.push(`- [${time}] ${place} — ${x.username ?? "?"}: ${text.slice(0, 300)}`);
    }
    if (page >= (m?.paging?.pages ?? 1)) break;
  }
  return lines.reverse();
}

// MARK: - HTTP

function get(method: string, t: string, query: Record<string, string>): Promise<any> {
  return send(`https://slack.com/api/${method}?${new URLSearchParams(query)}`, { headers: { Authorization: `Bearer ${t}` } });
}

function post(method: string, form: Record<string, string>): Promise<any> {
  return send(`https://slack.com/api/${method}`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams(form).toString(),
  });
}

async function send(url: string, init: RequestInit): Promise<any> {
  const res = await fetch(url, { ...init, signal: AbortSignal.timeout(20_000) });
  const obj: any = await res.json();
  if (!obj.ok) throw new Error(obj.error ?? "unknown_error");
  return obj;
}
