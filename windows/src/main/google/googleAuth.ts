import { clipboard, dialog } from "electron";
import * as crypto from "crypto";
import * as fs from "fs";
import * as http from "http";
import { nikxelPath, resourcePath, writeAtomic } from "../core/paths";
import { diag } from "../core/diag";
import { openUrl } from "../core/open";
import { ui } from "../core/ui";
import { bus } from "../core/bus";

/// Google OAuth, shared by everything in Nikxel that talks to Google: the
/// calendar watcher that reads upcoming events, GoogleSync, which writes
/// tasks and follow-up meetings out of a finished MOM, and (on Windows) the
/// ReminderWatcher, which reads Google Tasks.
///
/// One shared instance because there is exactly one ~/.nikxel/google_token.json.
/// Two independent copies would each refresh the access token and clobber the
/// other's, and a second OAuth flow would silently drop the first one's scopes.
export class GoogleAuth {
  static readonly shared: GoogleAuth = new GoogleAuth();

  /// Everything Nikxel ever asks for, requested together on one consent
  /// screen. Asking per-feature would mean a second browser round-trip the
  /// first time a summary happened to produce a task.
  static readonly scopes = [
    "https://www.googleapis.com/auth/calendar.readonly",
    "https://www.googleapis.com/auth/calendar.events",
    "https://www.googleapis.com/auth/tasks",
  ];

  private readonly credsPath: string;
  private readonly tokenPath: string;
  private server: http.Server | null = null;

  private clientId: string | null = null;
  private clientSecret: string | null = null;
  private accessToken: string | null = null;
  private refreshToken: string | null = null;
  /// ms since epoch.
  private accessTokenExpiry: number | null = null;
  /// Scopes the stored refresh token was actually granted. Empty for tokens
  /// written by a build that predates write access -- those only ever had
  /// calendar.readonly, so a write has to send the user back through consent.
  private grantedScopes = new Set<string>();
  /// One refresh at a time: the calendar poll, a chat task and the Tasks
  /// watcher can all ask for a token in the same tick.
  private refreshing: Promise<string> | null = null;

  /// Fired after a successful authorization, so the calendar watcher can
  /// start polling without GoogleAuth knowing it exists.
  onAuthorized: (() => void) | null = null;
  /// Extra listeners for the same moment. onAuthorized is a single slot the
  /// calendar watcher owns; the Google Tasks watcher needs to hear it too.
  private authorizedListeners: Array<() => void> = [];

  private constructor() {
    this.credsPath = nikxelPath("google_creds.json");
    this.tokenPath = nikxelPath("google_token.json");
  }

  // MARK: - State

  get hasCreds(): boolean { return this.loadCreds(); }

  /// True when sign-in needs no setup from the user (a client is bundled or
  /// already saved), i.e. Connect goes straight to Google's consent screen.
  get isOneClick(): boolean { return this.loadCreds(); }

  /// True once the user has authorized at least once.
  get isAuthorized(): boolean {
    if (this.refreshToken !== null) return true;
    return this.loadTokens();
  }

  /// Whether the stored grant covers `scope`. Writes check this before
  /// trying, so the user gets "reconnect your Google account" instead of a
  /// bare 403 from the API.
  hasScope(scope: string): boolean {
    this.loadTokens();
    return this.grantedScopes.has(scope);
  }

  /// Subscribe to successful authorizations (in addition to onAuthorized).
  addAuthorizedListener(fn: () => void): void {
    if (!this.authorizedListeners.includes(fn)) this.authorizedListeners.push(fn);
  }

  removeAuthorizedListener(fn: () => void): void {
    this.authorizedListeners = this.authorizedListeners.filter(f => f !== fn);
  }

  private fireAuthorized(): void {
    bus.emit("menuChanged");
    try { this.onAuthorized?.(); } catch (e) { diag("GoogleAuth", `onAuthorized threw: ${e}`); }
    for (const fn of this.authorizedListeners) {
      try { fn(); } catch (e) { diag("GoogleAuth", `authorized listener threw: ${e}`); }
    }
  }

  /// A valid access token, refreshing first if the current one has expired.
  /// Rejects when there is nothing to refresh from, or the refresh failed.
  /// (Swift: withAccessToken, which handed back nil in those cases.)
  getAccessToken(): Promise<string> {
    const at = this.accessToken;
    if (at && this.accessTokenExpiry !== null && this.accessTokenExpiry > Date.now()) {
      return Promise.resolve(at);
    }
    if (!this.loadCreds()) return Promise.reject(new Error("No Google client configured"));
    if (!this.loadTokens() || !this.refreshToken || !this.clientId || !this.clientSecret) {
      return Promise.reject(new Error("Google account not connected"));
    }
    if (this.refreshing) return this.refreshing;
    const rt = this.refreshToken, cid = this.clientId, cs = this.clientSecret;
    this.refreshing = (async () => {
      try {
        const res = await fetch("https://oauth2.googleapis.com/token", {
          method: "POST",
          headers: { "Content-Type": "application/x-www-form-urlencoded" },
          body: new URLSearchParams({
            refresh_token: rt,
            client_id: cid,
            client_secret: cs,
            grant_type: "refresh_token",
          }).toString(),
        });
        const obj = await res.json().catch(() => null) as Record<string, unknown> | null;
        const token = obj?.access_token;
        if (typeof token !== "string") {
          const why = (obj?.error_description ?? obj?.error ?? `HTTP ${res.status}`) as string;
          diag("GoogleAuth", `refresh failed: ${why}`);
          throw new Error(`Couldn't refresh the Google login: ${why}`);
        }
        this.accessToken = token;
        if (typeof obj!.expires_in === "number") {
          this.accessTokenExpiry = Date.now() + (obj!.expires_in - 60) * 1000;
        }
        // A refresh response repeats the granted scopes; keep them in sync
        // in case the user narrowed the grant from their Google account.
        if (typeof obj!.scope === "string") {
          this.grantedScopes = new Set(obj!.scope.split(" ").filter(Boolean));
        }
        this.saveTokens();
        return token;
      } finally {
        this.refreshing = null;
      }
    })();
    return this.refreshing;
  }

  /// Forces the next `getAccessToken` to refresh -- call after a 401.
  invalidateAccessToken(): void { this.accessTokenExpiry = 0; }

  // MARK: - Entry points

  /// Resume an existing connection on launch. Google is optional, so this
  /// never nags or opens a sign-in -- connecting is the menu's "Connect
  /// Google Account…" (`reauthenticate`).
  start(): void {
    if (!this.loadCreds() || !this.loadTokens()) return;
    setImmediate(() => this.fireAuthorized());
  }

  /// Re-run consent from scratch -- the menu's "Connect Google Account", and
  /// the recovery path when a stored grant is missing a scope.
  reauthenticate(): void {
    void (async () => {
      // A client JSON already on the clipboard (the last step of the manual
      // path) is taken as-is, so the user never has to find the file.
      if (!this.loadCreds()) await this.importCredsFromClipboard(true);
      if (!this.loadCreds()) { await this.showSetupAlert(); return; }
      await this.startOAuthFlow();
    })();
  }

  /// Saves Google client credentials copied to the clipboard as
  /// ~/.nikxel/google_creds.json. Accepts the downloaded JSON verbatim.
  async importCredsFromClipboard(silent = false): Promise<boolean> {
    let text = "";
    try { text = await clipboard.readText(); } catch { /* no clipboard outside Electron */ }
    if (!this.saveCredsText(text)) {
      if (!silent) this.showAlert("The clipboard doesn't hold Google client credentials. Copy the downloaded JSON's contents, then try again.");
      return false;
    }
    return true;
  }

  /// Same, from the downloaded file itself -- Windows' answer to digging the
  /// JSON out of Downloads and copying its contents.
  async importCredsFromFile(): Promise<boolean> {
    const r = await dialog.showOpenDialog({
      title: "Choose the Google client JSON you downloaded",
      filters: [{ name: "JSON", extensions: ["json"] }],
      properties: ["openFile"],
    });
    if (r.canceled || r.filePaths.length === 0) return false;
    let text = "";
    try { text = await fs.promises.readFile(r.filePaths[0], "utf8"); } catch { /* reported below */ }
    if (!this.saveCredsText(text)) {
      this.showAlert("That file doesn't hold Google client credentials. Download the OAuth client JSON (Desktop app) and pick that.");
      return false;
    }
    return true;
  }

  private saveCredsText(text: string): boolean {
    if (!text || !this.parseCreds(text)) {
      this.clientId = null; this.clientSecret = null;
      return false;
    }
    try {
      writeAtomic(this.credsPath, text);
      fs.chmodSync(this.credsPath, 0o600);
    } catch (e) { diag("GoogleAuth", `saving creds failed: ${e}`); }
    return true;
  }

  stop(): void {
    this.closeServer();
  }

  private closeServer(): void {
    const s = this.server;
    this.server = null;
    if (!s) return;
    s.close();
    s.closeAllConnections();
  }

  // MARK: - Persistence

  private loadCreds(): boolean {
    if (this.clientId !== null && this.clientSecret !== null) return true;
    // The user's own file wins, so anyone who already set up their own
    // Cloud project (or wants a private quota) keeps working unchanged.
    // Otherwise fall back to the client shipped inside the app, which is
    // what makes "Connect Google" a single click.
    for (const file of [this.credsPath, resourcePath("google_client.json")]) {
      let text: string;
      try { text = fs.readFileSync(file, "utf8"); } catch { continue; }
      if (this.parseCreds(text)) return true;
    }
    return false;
  }

  private parseCreds(text: string): boolean {
    // Google's downloaded creds JSON wraps everything under "installed" or "web".
    let outer: any;
    try { outer = JSON.parse(text); } catch { return false; }
    if (!outer || typeof outer !== "object") return false;
    const inner = (outer.installed && typeof outer.installed === "object" ? outer.installed : null)
      ?? (outer.web && typeof outer.web === "object" ? outer.web : null);
    if (inner && typeof inner.client_id === "string" && typeof inner.client_secret === "string") {
      this.clientId = inner.client_id; this.clientSecret = inner.client_secret; return true;
    }
    if (typeof outer.client_id === "string" && typeof outer.client_secret === "string") {
      this.clientId = outer.client_id; this.clientSecret = outer.client_secret; return true;
    }
    return false;
  }

  private loadTokens(): boolean {
    if (this.refreshToken !== null) return true;
    let obj: any;
    try { obj = JSON.parse(fs.readFileSync(this.tokenPath, "utf8")); } catch { return false; }
    if (!obj || typeof obj.refresh_token !== "string") return false;
    this.refreshToken = obj.refresh_token;
    this.accessToken = typeof obj.access_token === "string" ? obj.access_token : null;
    // Stored in seconds since 1970, like the Mac app writes it.
    if (typeof obj.expires_at === "number") this.accessTokenExpiry = obj.expires_at * 1000;
    if (typeof obj.scope === "string") this.grantedScopes = new Set(obj.scope.split(" ").filter(Boolean));
    return true;
  }

  private saveTokens(): void {
    const obj: Record<string, unknown> = {};
    if (this.refreshToken) obj.refresh_token = this.refreshToken;
    if (this.accessToken) obj.access_token = this.accessToken;
    if (this.accessTokenExpiry !== null) obj.expires_at = this.accessTokenExpiry / 1000;
    if (this.grantedScopes.size > 0) obj.scope = [...this.grantedScopes].sort().join(" ");
    try {
      writeAtomic(this.tokenPath, JSON.stringify(obj, null, 2));
      fs.chmodSync(this.tokenPath, 0o600);
    } catch (e) { diag("GoogleAuth", `saving token failed: ${e}`); }
  }

  // MARK: - OAuth (Installed App / loopback redirect)

  private async startOAuthFlow(): Promise<void> {
    const clientId = this.clientId;
    if (!clientId) return;
    // Tear down any listener left over from a prior (aborted) attempt --
    // its request handler keeps the OLD `state` and any new auth would be
    // rejected as a state mismatch -> "Authorization failed".
    this.closeServer();

    const bound = await GoogleAuth.bindLoopbackServer();
    if (!bound) {
      this.showAlert("Could not bind a local port for the OAuth callback.");
      return;
    }
    this.continueOAuthFlow(bound.server, bound.port, clientId);
  }

  private continueOAuthFlow(server: http.Server, port: number, clientId: string): void {
    this.server = server;
    const redirectURI = `http://127.0.0.1:${port}/callback`;
    const state = crypto.randomUUID().toUpperCase();
    // PKCE: the code only redeems with the verifier that started this
    // flow, so a local process that sniffs the loopback redirect can't
    // trade it for tokens. Google supports it for desktop clients.
    const verifier = GoogleAuth.randomVerifier();

    server.on("request", (req, res) => {
      const url = new URL(req.url ?? "/", redirectURI);
      // Browsers also ask for /favicon.ico; only the redirect itself counts.
      if (url.pathname !== "/callback") {
        res.writeHead(404, { Connection: "close" });
        res.end();
        return;
      }
      const code = url.searchParams.get("code");
      const returnedState = url.searchParams.get("state");
      let body: string;
      if (code && returnedState === state) {
        body = "<html><body style='font-family:system-ui,Segoe UI,sans-serif;text-align:center;padding:60px'><h2>Nikxel: connected &#10003;</h2><p>You can close this tab.</p></body></html>";
        void this.exchangeCodeForToken(code, redirectURI, verifier);
      } else {
        body = "<html><body style='font-family:system-ui,Segoe UI,sans-serif;text-align:center;padding:60px'><h2>Authorization failed</h2></body></html>";
      }
      res.writeHead(200, {
        "Content-Type": "text/html; charset=utf-8",
        "Content-Length": Buffer.byteLength(body),
        Connection: "close",
      });
      res.end(body);
      setTimeout(() => {
        if (this.server === server) this.closeServer();
      }, 300);
    });

    const params = new URLSearchParams({
      client_id: clientId,
      redirect_uri: redirectURI,
      response_type: "code",
      scope: GoogleAuth.scopes.join(" "),
      access_type: "offline",
      prompt: "consent",
      state,
      code_challenge: GoogleAuth.challenge(verifier),
      code_challenge_method: "S256",
    });
    openUrl(`https://accounts.google.com/o/oauth2/v2/auth?${params.toString()}`);
  }

  /// Listens on 127.0.0.1 only, on a random port in 49100-49199 -- a busy
  /// port reports EADDRINUSE asynchronously, so try the next one.
  private static bindLoopbackServer(): Promise<{ server: http.Server; port: number } | null> {
    const ports = Array.from({ length: 100 }, (_, i) => 49100 + i);
    for (let i = ports.length - 1; i > 0; i--) {
      const j = Math.floor(Math.random() * (i + 1));
      [ports[i], ports[j]] = [ports[j], ports[i]];
    }
    return new Promise(resolve => {
      const attempt = (idx: number) => {
        if (idx >= ports.length) { resolve(null); return; }
        const port = ports[idx];
        const server = http.createServer();
        const onError = (err: Error) => {
          diag("GoogleAuth", `OAuth bind port ${port} failed: ${err.message}`);
          server.close();
          attempt(idx + 1);
        };
        server.once("error", onError);
        server.listen(port, "127.0.0.1", () => {
          server.off("error", onError);
          server.on("error", e => diag("GoogleAuth", `OAuth listener error: ${e.message}`));
          resolve({ server, port });
        });
      };
      attempt(0);
    });
  }

  private async exchangeCodeForToken(code: string, redirectURI: string, verifier: string): Promise<void> {
    const clientId = this.clientId, clientSecret = this.clientSecret;
    if (!clientId || !clientSecret) return;
    let obj: Record<string, unknown> | null = null;
    try {
      const res = await fetch("https://oauth2.googleapis.com/token", {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body: new URLSearchParams({
          code,
          client_id: clientId,
          client_secret: clientSecret,
          redirect_uri: redirectURI,
          code_verifier: verifier,
          grant_type: "authorization_code",
        }).toString(),
      });
      obj = await res.json().catch(() => null) as Record<string, unknown> | null;
      if (!obj) { this.showAlert(`Token exchange failed: no response`); return; }
    } catch (e) {
      this.showAlert(`Token exchange failed: ${(e as Error).message ?? "no response"}`);
      return;
    }
    if (typeof obj.access_token === "string") {
      this.accessToken = obj.access_token;
      if (typeof obj.expires_in === "number") {
        this.accessTokenExpiry = Date.now() + (obj.expires_in - 60) * 1000;
      }
      if (typeof obj.refresh_token === "string") this.refreshToken = obj.refresh_token;
      if (typeof obj.scope === "string") {
        this.grantedScopes = new Set(obj.scope.split(" ").filter(Boolean));
      }
      this.saveTokens();
      const missing = GoogleAuth.scopes.filter(s => !this.grantedScopes.has(s));
      this.fireAuthorized();
      if (missing.length === 0) {
        this.showAlert("Google account connected ✓\n\nCalendar reminders, Google Tasks and follow-up meetings are all available.");
      } else {
        // Google lets the user untick individual permissions on the
        // consent screen. Say which ones, rather than failing mysteriously
        // later.
        this.showAlert(`Connected, but some permissions were declined:\n\n${missing.map(s => "• " + GoogleAuth.scopeLabel(s)).join("\n")}\n\nReconnect and leave every box ticked to enable those.`);
      }
    } else {
      const desc = (obj.error_description as string | undefined) ?? (obj.error as string | undefined) ?? "unknown error";
      this.showAlert(`Token exchange failed: ${desc}`);
    }
  }

  static scopeLabel(scope: string): string {
    switch (scope) {
      case "https://www.googleapis.com/auth/calendar.readonly": return "Read your calendar (meeting reminders)";
      case "https://www.googleapis.com/auth/calendar.events": return "Create calendar events (follow-up meetings)";
      case "https://www.googleapis.com/auth/tasks": return "Create tasks (action items in Google Tasks)";
      default: return scope;
    }
  }

  private static randomVerifier(): string {
    return crypto.randomBytes(32).toString("base64url");
  }

  private static challenge(verifier: string): string {
    return crypto.createHash("sha256").update(verifier, "utf8").digest("base64url");
  }

  // MARK: - UI

  async showSetupAlert(): Promise<void> {
    const r = await dialog.showMessageBox({
      type: "info",
      title: "Nikxel",
      message: "Connect your Google account",
      detail:
        "This build has no shared Google client, so you need your own (free, ~3 minutes, once):\n\n" +
        "1. Click \"Open Google Cloud Console\", create a project, and enable the Google Calendar API and Google Tasks API.\n" +
        "2. OAuth consent screen -> External -> add yourself as a test user.\n" +
        "3. Credentials -> Create OAuth client ID -> \"Desktop app\" -> Download JSON.\n" +
        "4. Open the JSON, copy everything, and click \"Paste from Clipboard\" here (or click \"Choose File…\" and pick the downloaded JSON).",
      buttons: ["Paste from Clipboard", "Choose File…", "Open Google Cloud Console", "Later"],
      defaultId: 0,
      cancelId: 3,
      noLink: true,
    });
    switch (r.response) {
      case 0:
        if (await this.importCredsFromClipboard()) await this.startOAuthFlow();
        break;
      case 1:
        if (await this.importCredsFromFile()) await this.startOAuthFlow();
        break;
      case 2:
        openUrl("https://console.cloud.google.com/apis/credentials");
        break;
      default: break;
    }
  }

  /// A bubble over the avatar, not a modal: these arrive while you're in
  /// another app (after a sync, a sign-in) and a modal would open behind it.
  showAlert(message: string): void {
    ui.tell({
      icon: "🔗", title: "Google",
      lines: message.split("\n").filter(l => l.trim() !== ""),
      lifetime: 30,
    });
  }
}
