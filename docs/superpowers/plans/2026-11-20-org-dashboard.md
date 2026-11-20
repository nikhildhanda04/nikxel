# Nikxel Org Dashboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up a hosted web dashboard + Node backend so people in one org connect, share meeting/project summaries, and roll daily work summaries up to admins — while the desktop app stays local-first and pushes only what the user shares.

**Architecture:** One Express process serves a JSON API over SQLite and the built React (Vite) dashboard as static assets. Google login → a crypto-signed httpOnly session cookie (stateless). The desktop app pairs via a one-time 6-digit code → a long-lived device token, then POSTs only shared summaries. Work summaries land `pending` and roll up to admins only when the member **releases** them.

**Tech Stack:** Node + Express (ESM, no build step), `better-sqlite3`, `google-auth-library` (verifies Google id tokens), `node:crypto` HMAC for the signed cookie (no JWT dep), Vite + React + Tailwind for the dashboard, Node built-in `node --test` for backend tests. Desktop: Swift (`src/`) mirrored to Electron/TypeScript (`windows/`).

**Spec:** `docs/superpowers/specs/2026-11-20-org-dashboard-design.md`

## Global Constraints

- **Data boundary (hard):** only user-shared summaries leave the device; the twin, `erp.md`, raw logs, activity samples, window titles never sync. The desktop push payload is summary-only.
- **Member integrity:** a member may only flip an item's `removed` flag (and only while `pending`); `what`/`minutes` are immutable to a member. The **owner** role may edit facts while `pending`. An **admin** reads only `released` work summaries, and only items where `removed === false`.
- **Manual release:** a work summary is pushed `pending` (private to its member + owner) and reaches the admin rollup only after the member releases it.
- **Re-push is idempotent per (user, org, kind, date):** merge incoming items by `id` into the existing row, **preserve every `removed` flag** (never un-redact), and do not change `status`.
- **One org per user (v1):** no org switcher; the device token resolves its org from the member's single membership; schema still keys on (user, org).
- **Identity use:** the Google email identifies the user to their own Nikxel backend only; never forwarded to a third-party service.
- **Owner-edit honesty:** the owner-edit capability is a real, honestly-named role in the code and commits. It may be absent from the member-facing UI, but it is never concealed from the repository, its history, or the README.
- **Mirror rule:** every Swift `src/` change ships with its `windows/` mirror in the same commit, both verified to build.
- **Minimal design:** one clean typeface, generous whitespace, no decorative chrome (Tailwind only).
- **No new heavy deps** beyond those named in Tech Stack.

## Review Focus

- **Re-push after release** adds a new item to an already-`released` day — confirm new items inherit `released` (the documented, accepted simplification) and nothing throws. *(Task 2 test.)*
- **Member edits facts via the raw API** (bypassing the read-only UI) — the server must reject a `what`/`minutes` change from a member role. *(Task 5 test.)*
- **Cross-org read** — a user of org A requesting org B's summaries/members gets nothing. *(Task 5 test.)*
- **Device token org scoping** — a push authenticates to exactly the paired member+org; a revoked/unknown token is rejected. *(Task 4 test.)*
- **Pairing code single-use + expiry** — a code cannot be redeemed twice or after it expires. *(Task 4 test.)*

---

## File Structure

- `cloud/server/` — Express API + SQLite (ESM JS, no build).
  - `db.js` — open DB, `bootstrap()` (idempotent schema).
  - `summaries.js` — pure integrity logic (merge, release, redact, owner-edit, admin view).
  - `auth.js` — Google id-token verify, signed-cookie issue/read, `requireRole`.
  - `pairing.js` — pairing codes + device tokens + `deviceAuth`.
  - `routes.js` + `app.js` — HTTP wiring; `app.js` also serves the built dashboard.
  - `*.test.js` — `node --test` suites.
- `cloud/dashboard/` — Vite React SPA (Login, Connect app, My summaries, People, Admin). Builds to `cloud/dashboard/dist`, served by `app.js`.
- `src/CloudSync.swift` + desktop UI hook — pairing + push (macOS).
- `windows/src/main/system/cloudSync.ts` — the mirror (Windows).
- `check_cloud_sync.swift` — runnable Swift check (mirrors the repo's `check_*.swift` pattern).

---

## Task 1: cloud/server scaffold + SQLite schema

**Files:**
- Create: `cloud/server/package.json`, `cloud/server/db.js`, `cloud/server/db.test.js`

**Interfaces:**
- Produces: `openDb(path)` → better-sqlite3 handle; `bootstrap(db)` → creates all tables if absent (idempotent). Tables exactly as the spec's Storage section: `users, orgs, memberships, invites, device_tokens, pairing_codes, summaries`. `summaries` columns: `id, user_id, org_id, kind, date, items (TEXT json), notes (TEXT), visibility, status, created_at`; unique index on `(user_id, org_id, kind, date)`.

- [ ] **Step 1: Write the failing test** `cloud/server/db.test.js`

```js
test('bootstrap creates tables and is idempotent', () => {
  const db = openDb(':memory:');
  bootstrap(db); bootstrap(db); // twice must not throw
  const names = db.prepare("SELECT name FROM sqlite_master WHERE type='table'").all().map(r => r.name);
  for (const t of ['users','orgs','memberships','invites','device_tokens','pairing_codes','summaries'])
    assert.ok(names.includes(t), `missing ${t}`);
});
test('summaries is unique per (user, org, kind, date)', () => {
  const db = openDb(':memory:'); bootstrap(db);
  const ins = db.prepare("INSERT INTO summaries(id,user_id,org_id,kind,date,items,notes,visibility,status,created_at) VALUES (?,?,?,?,?,?,?,?,?,?)");
  ins.run('a','u1','o1','work','2026-11-20','[]','','admin','pending',0);
  assert.throws(() => ins.run('b','u1','o1','work','2026-11-20','[]','','admin','pending',0));
});
```

- [ ] **Step 2: Run test, verify it fails** — `cd cloud/server && node --test` → FAIL (openDb not defined). Expected.
- [ ] **Step 3: Implement** `package.json` (`"type":"module"`, dep `better-sqlite3`, script `"test":"node --test"`), then `db.js` with `openDb` and `bootstrap`. `npm install`.
- [ ] **Step 4: Run test, verify it passes** — `node --test` → PASS.
- [ ] **Step 5: Commit** — `feat(cloud): server scaffold + SQLite schema`.

---

## Task 2: Summary integrity logic (the core)

**Files:**
- Create: `cloud/server/summaries.js`, `cloud/server/summaries.test.js`

**Interfaces:**
- Consumes: nothing (pure functions over plain summary objects; a summary is `{items, status, user_id, ...}`, `items` = `[{id, what, minutes, removed}]`).
- Produces:
  - `mergeItems(existing, incoming)` → array; for each incoming id present in existing, keep existing `removed`; update `what`/`minutes` from incoming; append genuinely new incoming items (`removed:false`); preserve existing order then new. Never sets an existing `removed:true` back to false.
  - `adminView(summary)` → `null` if `status !== 'released'`, else `{...summary, items: items.filter(i => !i.removed)}`.
  - `redact(summary, itemId, byRole)` → sets that item `removed:true` **only if** `summary.status === 'pending'`; throws `ForbiddenError` if released. (Any role may redact their own row; row ownership is enforced at the route layer.)
  - `ownerEdit(summary, itemId, patch, byRole)` → applies `{what?, minutes?}` **only if** `byRole === 'owner'` and `status === 'pending'`; else throws `ForbiddenError`.
  - `release(summary, byRole)` → sets `status:'released'` only if currently `pending`; idempotent-safe (throws if already released is **not** required — return unchanged).
  - `ForbiddenError` class.

- [ ] **Step 1: Write the failing tests** `cloud/server/summaries.test.js`

```js
test('mergeItems preserves removed flags on re-push', () => {
  const existing = [{id:'1',what:'A',minutes:60,removed:true},{id:'2',what:'B',minutes:30,removed:false}];
  const incoming = [{id:'1',what:'A',minutes:90},{id:'2',what:'B',minutes:45},{id:'3',what:'C',minutes:15}];
  const out = mergeItems(existing, incoming);
  assert.equal(out.find(i=>i.id==='1').removed, true);   // stays redacted
  assert.equal(out.find(i=>i.id==='1').minutes, 90);     // facts updated
  assert.equal(out.find(i=>i.id==='3').removed, false);  // new item visible
});
test('adminView hides pending and removed items', () => {
  assert.equal(adminView({status:'pending',items:[]}), null);
  const v = adminView({status:'released',items:[{id:'1',removed:true,what:'x',minutes:1},{id:'2',removed:false,what:'y',minutes:2}]});
  assert.deepEqual(v.items.map(i=>i.id), ['2']);
});
test('member cannot edit facts; owner can, only while pending', () => {
  const s = {status:'pending',items:[{id:'1',what:'A',minutes:60,removed:false}]};
  assert.throws(() => ownerEdit(s,'1',{minutes:999},'member'), ForbiddenError);
  ownerEdit(s,'1',{minutes:120},'owner');
  assert.equal(s.items[0].minutes, 120);
  const r = {status:'released',items:[{id:'1',what:'A',minutes:60,removed:false}]};
  assert.throws(() => ownerEdit(r,'1',{minutes:1},'owner'), ForbiddenError);
});
test('redact only while pending', () => {
  const s = {status:'pending',items:[{id:'1',removed:false,what:'A',minutes:1}]};
  redact(s,'1','member'); assert.equal(s.items[0].removed, true);
  assert.throws(() => redact({status:'released',items:[{id:'1',removed:false}]},'1','member'), ForbiddenError);
});
test('re-push into released day keeps it released (accepted simplification)', () => {
  const merged = mergeItems([{id:'1',what:'A',minutes:1,removed:false}], [{id:'1',what:'A',minutes:1},{id:'2',what:'N',minutes:5}]);
  assert.equal(merged.length, 2); // does not throw; status handled by caller, stays released
});
```

- [ ] **Step 2: Run tests, verify they fail** — `node --test` → FAIL (functions undefined). Expected.
- [ ] **Step 3: Implement** `summaries.js` with the five functions + `ForbiddenError`. Pure, no DB.
- [ ] **Step 4: Run tests, verify they pass** — `node --test` → PASS.
- [ ] **Step 5: Commit** — `feat(cloud): summary integrity logic (merge/release/redact/owner-edit)`.

---

## Task 3: Identity — Google login + signed cookie + role gate

**Files:**
- Create: `cloud/server/auth.js`, `cloud/server/auth.test.js`

**Interfaces:**
- Consumes: `openDb`/`bootstrap` (Task 1) for user upsert.
- Produces:
  - `signCookie(payload, secret)` / `verifyCookie(value, secret)` → base64url(JSON)+HMAC-SHA256 via `node:crypto`; `verifyCookie` returns payload or `null` on tamper/format error.
  - `issueSession(res, {userId, orgId, role}, secret)` → sets httpOnly, `SameSite=Lax`, `Secure` cookie.
  - `readSession(req, secret)` → `{userId, orgId, role} | null`.
  - `requireRole(...roles)` → Express middleware; 401 if no session, 403 if role not allowed; attaches `req.session`.
  - `verifyGoogle(idToken, clientId, verifier = defaultVerifier)` → `{sub, email, name}`; `verifier` is injectable so tests never call Google. `defaultVerifier` uses `google-auth-library` `OAuth2Client.verifyIdToken`.

- [ ] **Step 1: Write the failing tests** `cloud/server/auth.test.js`

```js
test('signed cookie round-trips and rejects tampering', () => {
  const v = signCookie({userId:'u1',orgId:'o1',role:'owner'}, 'secret');
  assert.deepEqual(verifyCookie(v,'secret'), {userId:'u1',orgId:'o1',role:'owner'});
  assert.equal(verifyCookie(v+'x','secret'), null);
  assert.equal(verifyCookie(v,'wrong'), null);
});
test('verifyGoogle uses the injected verifier', async () => {
  const fake = async (tok) => ({sub:'g1', email:'a@b.com', name:'A'});
  assert.deepEqual(await verifyGoogle('tok','cid',fake), {sub:'g1',email:'a@b.com',name:'A'});
});
test('requireRole denies wrong role', () => {
  const mw = requireRole('owner','admin');
  const res = fakeRes(); let nexted=false;
  mw(fakeReqWithSession({role:'member'}), res, ()=>{nexted=true});
  assert.equal(res.statusCode, 403); assert.equal(nexted, false);
});
```
*(test helpers `fakeRes`/`fakeReqWithSession` are small inline stubs.)*

- [ ] **Step 2: Run tests, verify they fail.** Expected: functions undefined.
- [ ] **Step 3: Implement** `auth.js`. Add dep `google-auth-library`. Cookie secret read from `process.env.SESSION_SECRET`.
- [ ] **Step 4: Run tests, verify they pass.**
- [ ] **Step 5: Commit** — `feat(cloud): Google login, signed session cookie, role gate`.

---

## Task 4: Pairing codes + device tokens

**Files:**
- Create: `cloud/server/pairing.js`, `cloud/server/pairing.test.js`

**Interfaces:**
- Consumes: Task 1 DB.
- Produces:
  - `createPairingCode(db, userId, orgId, now = Date.now)` → 6-digit string; row in `pairing_codes` with `expires_at = now + 10min`.
  - `redeemPairingCode(db, code, now = Date.now)` → `{deviceToken, userId, orgId}` and deletes the code (single-use); returns `null` if missing/expired. `deviceToken` is random 32 bytes hex; its SHA-256 stored in `device_tokens(token_hash, user_id, org_id)`.
  - `deviceAuth(db)` → Express middleware reading `Authorization: Bearer <token>`; hashes, looks up, attaches `req.device = {userId, orgId}`; 401 on miss. Updates `last_used`.

- [ ] **Step 1: Write the failing tests** `cloud/server/pairing.test.js`

```js
test('pair → redeem issues a token; code is single-use', () => {
  const db = openDb(':memory:'); bootstrap(db);
  const code = createPairingCode(db,'u1','o1');
  const first = redeemPairingCode(db, code);
  assert.ok(first.deviceToken && first.userId==='u1' && first.orgId==='o1');
  assert.equal(redeemPairingCode(db, code), null); // can't reuse
});
test('expired code cannot be redeemed', () => {
  const db = openDb(':memory:'); bootstrap(db);
  const t0 = 1_000_000;
  const code = createPairingCode(db,'u1','o1',()=>t0);
  assert.equal(redeemPairingCode(db, code, ()=>t0 + 11*60*1000), null);
});
test('deviceAuth resolves a valid bearer, rejects unknown', () => {
  const db = openDb(':memory:'); bootstrap(db);
  const {deviceToken} = redeemPairingCode(db, createPairingCode(db,'u1','o1'));
  const mw = deviceAuth(db);
  const okReq = {headers:{authorization:`Bearer ${deviceToken}`}}; let ok=false;
  mw(okReq, fakeRes(), ()=>{ok=true}); assert.ok(ok && okReq.device.userId==='u1' && okReq.device.orgId==='o1');
  const bad = fakeRes(); mw({headers:{authorization:'Bearer nope'}}, bad, ()=>{}); assert.equal(bad.statusCode,401);
});
```

- [ ] **Step 2: Run tests, verify they fail.**
- [ ] **Step 3: Implement** `pairing.js` (random via `crypto.randomBytes`, hash via `crypto.createHash`).
- [ ] **Step 4: Run tests, verify they pass.**
- [ ] **Step 5: Commit** — `feat(cloud): device pairing codes + bearer device tokens`.

---

## Task 5: HTTP API routes (orgs, invites, members, summaries)

**Files:**
- Create: `cloud/server/routes.js`, `cloud/server/app.js`, `cloud/server/routes.test.js`

**Interfaces:**
- Consumes: Tasks 1–4.
- Produces an Express `app`. Endpoints:
  - `GET /api/auth/google` → redirect to Google's consent URL (client id + redirect URI + `openid email profile`).
  - `GET /api/auth/google/callback` → exchange code, verifyGoogle → upsert user → if no membership, issue session and redirect to onboarding; else issueSession → redirect `/`.
  - `POST /api/orgs` (session) → create org, caller becomes `owner`. `POST /api/orgs/join {token}` → membership from invite.
  - `POST /api/invites` (owner/admin) → `{token, role}`. `GET /api/members` (admin/owner) → org members.
  - `GET /api/pairing-code` (session) → `{code}`.
  - `POST /api/pair {code}` (no session) → `{deviceToken}`.
  - `POST /api/summaries` (**deviceAuth**) → upsert by (user,org,kind,date) using `mergeItems`; work summaries created/kept `pending` unless already released.
  - `GET /api/summaries/mine` (session) → caller's rows (any status).
  - `POST /api/summaries/:id/redact {itemId}` (session, **own row**) → `redact`.
  - `POST /api/summaries/:id/release` (session, **own row**) → `release`.
  - `PATCH /api/summaries/:id/items/:itemId` (session, **owner**, own row) → `ownerEdit`.
  - `GET /api/rollup` (admin/owner) → every member's `adminView` (released, unremoved), **scoped to caller's org**.
- `ForbiddenError` → 403 at the error handler.

- [ ] **Step 1: Write the failing tests** `cloud/server/routes.test.js` — boot `app` on an ephemeral port, drive it with global `fetch`; seed DB + mint a session cookie directly via `signCookie`, and a device token via `redeemPairingCode`.

```js
test('member PATCH of item facts is rejected (403)', async () => { /* member cookie → PATCH → 403; minutes unchanged */ });
test('owner PATCH edits facts while pending', async () => { /* owner cookie → PATCH → 200; minutes changed */ });
test('admin rollup excludes pending and other orgs', async () => {
  // seed org A pending + released, org B released; GET /api/rollup as A-admin
  // → only A's released rows, only unremoved items, nothing from B
});
test('push merges and preserves redactions', async () => { /* push, redact item, re-push same day → item stays removed */ });
test('release makes a summary appear in the rollup', async () => { /* pending absent → release → present */ });
```

- [ ] **Step 2: Run tests, verify they fail.**
- [ ] **Step 3: Implement** `routes.js` + `app.js` (JSON body parsing, cookie parsing, mount routes, error handler, `express.static(dashboard/dist)` + SPA fallback). Wire the pure logic from Task 2 and the gates from Tasks 3–4.
- [ ] **Step 4: Run tests, verify they pass** — `node --test` (whole server suite green).
- [ ] **Step 5: Commit** — `feat(cloud): API routes for orgs, invites, pairing, summaries, rollup`.

---

## Task 6: React dashboard (Vite, minimal)

**Files:**
- Create: `cloud/dashboard/` (Vite React + Tailwind), `cloud/dashboard/src/api.js`, `cloud/dashboard/src/api.test.js`, screen components.

**Interfaces:**
- Consumes: the Task 5 API.
- Produces screens: **Login** (Google button → `/api/auth/google`), **Onboarding** (create org / paste invite link), **Connect app** (shows pairing code from `/api/pairing-code`), **My summaries** (list `mine`; per-item Remove → redact; **Release to admin**; `pending`/`released` shown; facts read-only, editable only when `role==='owner'`), **People** (members + invite link), **Admin** (rollup; admins/owner only).

- [ ] **Step 1: Write the failing test** `cloud/dashboard/src/api.test.js` — the one piece worth unit-testing is the API client's role/visibility helper:

```js
test('canEditFacts is owner-only', () => {
  assert.equal(canEditFacts('owner'), true);
  assert.equal(canEditFacts('admin'), false);
  assert.equal(canEditFacts('member'), false);
});
```
*(Run with `node --test` over the plain-JS `api.js`; React components are verified by `vite build` + manual smoke, per the ruling below — UI rendering is not unit-tested.)*

- [ ] **Step 2: Run test, verify it fails.**
- [ ] **Step 3: Implement** `api.js` (fetch wrappers + `canEditFacts`) and the screen components with Tailwind. Minimal visual system: one font, whitespace, no chrome.
- [ ] **Step 4: Verify** — `node --test` (api) PASS **and** `npm run build` (vite) succeeds with no errors.
- [ ] **Step 5: Commit** — `feat(cloud): minimal React dashboard`.

> **Ruling (altitude):** React component rendering is verified by a clean `vite build` + manual smoke, not unit tests. TDD covers the pure logic (`api.js`, and all of Tasks 1–5). Cost if wrong: a UI regression ships unnoticed; low, because all integrity/permission logic is server-side and tested there.

---

## Task 7: Desktop pairing + push (Swift `src/` + `windows/` mirror)

**Files:**
- Create: `src/CloudSync.swift`, `check_cloud_sync.swift`; `windows/src/main/system/cloudSync.ts`, `windows/src/checks/cloudSync.test.ts`
- Modify: the desktop UI to add a "Connect to dashboard" code field; the daily-summary completion hook in `src/DayLogger.swift` (+ Windows equivalent) to call the push.

**Interfaces:**
- Consumes: the Task 5 endpoints `POST /api/pair`, `POST /api/summaries`.
- Produces (both platforms, mirrored):
  - `CloudSync.pair(code)` → POST `/api/pair`, store the returned device token at `~/.nikxel/cloud-token` (0600) + Windows mirror path.
  - `CloudSync.workItems(fromDailySummary:)` → `[{id, what, minutes}]` derived from the existing daily summary (stable `id` = hash of `what`, so re-push matches). **Pure + tested.**
  - `CloudSync.pushDaily()` → if a token exists, POST the derived work items as `kind=work`. No token → no-op. Sends **only** the derived items — never logs/twin/erp.

- [ ] **Step 1: Write the failing checks** — `check_cloud_sync.swift` (runnable, sandboxed `HOME` like `check_erp_context.swift`) and `windows/src/checks/cloudSync.test.ts`:

```
- workItems maps "App — 1h 30m" style lines to {what, minutes:90} and drops non-work lines
- the same input yields the same item id twice (stable id ⇒ re-push matches, redactions survive)
- pushDaily with no stored token is a no-op (returns without a network call)
```

- [ ] **Step 2: Run checks, verify they fail** — Swift: `swiftc -parse-as-library ... src/CloudSync.swift check_cloud_sync.swift -o /tmp/ccs && /tmp/ccs`; Windows: `cd windows && npm run check`. Expected FAIL (symbols missing).
- [ ] **Step 3: Implement** `CloudSync.swift` and `cloudSync.ts` (mirror), wire `pushDaily()` into the daily-summary completion on both platforms, add the pairing code field to the UI.
- [ ] **Step 4: Run checks + builds, verify green** — Swift check PASS **and** `./build.sh` ("Build complete"); Windows `npm run check` PASS **and** the TS build clean.
- [ ] **Step 5: Commit** — `feat(desktop): pair with dashboard and push shared work summaries (mac + windows)`.

---

## Notes for the executor

- Backend tests run from `cloud/server` with `node --test`; they use `:memory:` SQLite and never hit Google or the network (verifier/token injected, app booted on an ephemeral port and driven with `fetch`).
- The secret (`SESSION_SECRET`) and Google client id/secret come from env; tests pass literals.
- Hosting/deploy is out of plan scope (owner picks the host); the single process + SQLite file runs anywhere Node does.
- Keep the owner-edit role named plainly in code and commits (Global Constraints) — do not soften or hide it.
