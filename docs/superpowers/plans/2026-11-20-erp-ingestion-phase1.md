# Any-ERP Ingestion — Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On a schedule and on first connect, crawl the signed-in user's ERP in an on-demand browser, read its pages into bounded work-context facts with the LLM, and fold them into the sealed twin so every prompt carries "the work this person does and the business they're in."

**Architecture:** A read-only, on-demand browser crawl rides the *already-authenticated* browser profile left by ERP sign-in (macOS: headless Chrome on the isolated `erp-profile` via `CDPClient`; Windows: a hidden `BrowserWindow` on the `persist:nikxel-erp` partition). A tiny **driver** (Odoo first, proven in the Phase 0 spike; a generic fallback for everything else) enumerates the nav, opens each section, and grabs the rendered content text; the **LLM reader** (the existing `runPrompt` path) turns that text into terse facts. Facts live in a new sealed file `~/.nikxel/twin/erp.md` (0600) and inject through the single `userContextBlock` point, after the user's own context so the user still wins.

**Tech Stack:** Swift (`src/`) + TypeScript/Electron (`windows/`), mirrored. Reuses `CDPClient`, `ERP` sign-in profile/partition, `MOMGenerator.runPrompt`, and the twin's file-backed-store + injection pattern (`TwinProfile`). No new dependencies.

**Spec:** `docs/superpowers/specs/2026-11-20-any-erp-ingestion-design.md` (Phase 1, as refined by the Phase 0 spike results in that doc).

## Global Constraints

- **Mirror both platforms in the same commit.** Every `src/` change has its `windows/` twin; a task is not done until both exist and build.
- **Read-only by construction.** The crawl follows nav / list / content only, same-origin; it never submits a form or clicks an action/delete/logout control, and never issues a write RPC.
- **Bounded per run.** Cap sections (≤ 8) and total captured text (≤ ~8000 chars) before the LLM; cap stored facts (≤ 2000 chars). No run reads the whole database. (Phase 0 measured a full sweep at ~3k tokens, so a bounded sweep each run is cheap — see "Builder decisions".)
- **Sealed to self.** Facts come only from the user's own authenticated session and land only in that user's `erp.md`. No ACL logic — the session is the boundary.
- **Fail soft.** No live session, no browser, or a blocked crawl → skip the run, keep the previous `erp.md`, never error and never wipe facts.
- **User context wins.** `erp.md` injects *before* the user's own `userContext` in `userContextBlock`; it never touches `profile.md` or `userContext`.
- Local storage under `~/.nikxel`, `0600`, as the rest of the twin.

## Builder decisions (deviations from the design's first-cut, with reasons)

These are my calls, settled here so the reviewer sees they're intentional:

1. **Separate `erp.md`, not a section inside `profile.md`.** The voice distiller rewrites the *whole* `profile.md` through the LLM each run and cannot be trusted to preserve a foreign opaque region across that round-trip. A separate sealed file — same directory, same 0600, same single injection point, refreshed each run, injected so the user still wins — achieves every stated intent with less code and no risk of the voice pass clobbering ERP facts (or vice-versa).
2. **No `{url, kind}` settings / migration in Phase 1.** The only connected ERP is Forklyft. The crawler targets the existing `ERP.base` and **detects the driver from the loaded page** (Odoo DOM markers → Odoo driver, else generic fallback) — which is *more* general than a stored kind and needs zero migration. Per-URL selection is Phase 2 (adapter registry), where it belongs.
3. **Reuse the authenticated sign-in profile; no cookie capture/injection.** ERP sign-in already leaves the full authenticated session in the isolated `erp-profile` dir (macOS) / `persist:nikxel-erp` partition (Windows). Relaunching headless on that profile / loading in a hidden window on that partition is authenticated with no capture step, and generalizes to any ERP signed in through that same window. This supersedes the design's "fresh user-data-dir + inject captured cookies" note (which existed only to avoid Chrome 136+ blocking the user's *default* profile — not an issue for our own isolated profile).
4. **No incremental cursors in Phase 1.** Phase 0 measured a full bounded sweep at ~3k tokens; per-section watermarks are complexity for savings we don't need yet. The caps above keep every run bounded. Add cursors when measured cost grows.

## Review Focus

- **Expired / absent session on an unattended end-of-day run** → ingest must skip and leave `erp.md` untouched (not empty, not an error dialog). Covered by Task 3's `ingest` guard + test.
- **No Chrome installed, or headless blocked (Cloudflare challenge)** → capture returns `""`; ingest keeps the old facts. Covered by Task 3's "empty capture ⇒ keep old" test.
- **A huge ERP** → section cap and text cap keep one run bounded; the LLM never sees more than ~8000 chars. Covered by Task 1's `boundText` test.
- **Malformed / refusal LLM output from the reader** → `accept` keeps the previous facts rather than storing garbage. Covered by Task 1's `accept` test.
- **Injection order** → `erp.md` precedes user context in `userContextBlock`, so a user correction always overrides an ERP fact. Covered by Task 3's `userContextBlock` test.

---

## Task 1: ERP context store + reader (pure, both platforms)

The file-backed facts store, its prompt-injection block, the reader prompt, the text-bounding, and the accept/guard logic — everything that needs no browser, so it carries the unit tests.

**Files:**
- Create: `src/ErpContext.swift`
- Create: `windows/src/main/system/erpContext.ts`
- Create/Modify test: `windows/src/checks/erp.test.ts` (add an ErpContext section)
- Mac check: a `demo()`/`__main__`-style assert block invoked from the existing Swift check harness used for the twin (match how `TwinDistiller`/`TwinProfile` are checked — follow that file's pattern).

**Interfaces:**
- Produces (Swift `enum ErpContext`, mirror in TS `export const ErpContext`):
  - `facts: String` — get/set backing `~/.nikxel/twin/erp.md`, 0600, delete-on-empty. **Mirror `TwinProfile.learned` exactly** (same dir-create, atomic write, perms, empty-removes).
  - `injectedBlock: String` — `""` when `facts` is empty, else a one-line header + the facts (header e.g. `"What Nikxel has learned about this user's work and business from their ERP — the projects, tasks, people, and customers they work with."` then the facts). No corrections region here.
  - `readerPrompt(capturedText: String) -> String` — instructs the LLM to extract the signed-in user's work context as terse facts (their projects, tasks, the people and business entities they work with), return facts only (no commentary/fences), stay under 2000 chars, prefer facts over prose. Takes the captured ERP page text as input.
  - `accept(new: String, old: String, cap: Int = 2000) -> String` — `old` when `new` is blank or looks like a refusal (empty after trim, or no alphanumeric content); else `new` trimmed and cut to `cap` on a line boundary. (Simpler than the twin's section-header check — ERP facts have no fixed headers; the guard is "non-empty, has real content".)
  - `boundText(sections: [String], cap: Int = 8000) -> String` — join section texts with a separator, truncate to `cap` chars on a boundary. The crawl feeds its captured sections through this before the reader.

- [ ] **Step 1: Write the failing tests** (TS `erp.test.ts`, mirrored by the Swift assert block)

```ts
// accept: keeps old on blank / refusal; takes and caps new
assert(ErpContext.accept("", "OLD") === "OLD");
assert(ErpContext.accept("   \n ", "OLD") === "OLD");
assert(ErpContext.accept("Project Rentop — yours — due Fri", "") === "Project Rentop — yours — due Fri");
assert(ErpContext.accept("x".repeat(2500), "").length <= 2000);

// boundText: caps total, joins sections
assert(ErpContext.boundText(["a".repeat(5000), "b".repeat(5000)], 8000).length <= 8000);

// injectedBlock: empty store ⇒ empty block; non-empty ⇒ header + facts, facts last
ErpContext.facts = "";            assert(ErpContext.injectedBlock === "");
ErpContext.facts = "Customer C&N Distributors — active";
assert(ErpContext.injectedBlock.includes("Customer C&N Distributors"));
ErpContext.facts = "";            // cleanup
```

- [ ] **Step 2: Run the tests, verify they fail** (functions undefined).
- [ ] **Step 3: Implement `ErpContext` in both files.** Mirror `TwinProfile`'s store mechanics for `facts`; the rest is the signatures above. Keep the two files line-for-line parallel.
- [ ] **Step 4: Run the tests, verify they pass** (TS via the project's check runner; Swift via the twin check harness).
- [ ] **Step 5: Commit** (both files + tests, one commit).

---

## Task 2: On-demand browser crawl + drivers (both platforms)

Open a read-only, on-demand session on the already-authenticated ERP profile, detect the driver, and capture bounded nav+content text. This is the browser-driving half; it has no automatable unit test, so it ends with a **recorded live run against Forklyft** (like the original ERP verification).

**Files:**
- Create: `src/ErpCrawl.swift`
- Create: `windows/src/main/system/erpCrawl.ts`
- Modify: `windows/src/main/system/erp.ts` — `export const BASE`, `export const PARTITION` (currently module-private) so the crawl can target them. (Swift: `ERP.base`/`ERP.profileDir` are already accessible.)

**Interfaces:**
- Produces:
  - Swift: `enum ErpCrawl { static func capture() -> [String] }` — opens the session, returns the captured section texts (empty array on any failure: no browser, no live session, blocked). **Does not** touch `ErpContext` (Task 3 wires that).
  - TS: `export async function capture(): Promise<string[]>` — same contract.
- Internals (not a cross-task interface, but the shape to build):
  - **Session (macOS):** launch headless Chrome on `ERP.profileDir` with a distinct debug port (e.g. `9224`), `--headless=new`, same hardening flags as `ERP.launch`; connect a `CDPClient` (`port = 9224`); **quit the browser in a `defer`** (reuse `ERP.quit`-style pkill on the profile path). The profile already holds the authenticated session — no cookie step.
  - **Session (Windows):** `new BrowserWindow({ show: false, webPreferences: { partition: PARTITION, … } })`, `loadURL(BASE)`, drive via `webContents.executeJavaScript`; `destroy()` in a `finally`.
  - **Driver detection:** after the app loads, check for Odoo markers (e.g. `.o_main_navbar` / `.o_navbar` present) → Odoo driver; else generic fallback.
  - **Odoo driver** (from the spike): enumerate the apps/nav items from the menu DOM; for up to the section cap, **click** the nav item (not URL-navigate — Odoo is a hash SPA), wait for the async view (~4–6 s, or poll until `.o_content` text stabilizes), grab `.o_content` `innerText`. Skip low-value apps (Discuss, Calendar).
  - **Generic fallback driver:** read visible same-origin nav links; for up to the cap, navigate each and grab `document.body.innerText`. Best-effort.
  - Each captured section is trimmed; empty/whitespace sections dropped. Read-only throughout: only `innerText` reads, nav clicks, and GET navigations — never a form submit or action button.

- [ ] **Step 1: Implement the macOS session + Odoo driver + generic fallback** in `src/ErpCrawl.swift`, reusing `CDPClient.eval`/`clickAt` and the `ERP.launch`/`quit` pattern (headless, port 9224). Enforce the section cap.
- [ ] **Step 2: Implement the Windows twin** in `windows/src/main/system/erpCrawl.ts` (hidden `BrowserWindow` + `executeJavaScript`), and export `BASE`/`PARTITION` from `erp.ts`. Keep behavior identical.
- [ ] **Step 3: Live check (macOS), recorded in the ledger.** With the stored Forklyft session live, run `ErpCrawl.capture()` once (a throwaway top-level invocation or the check harness). Confirm: the headless browser opens and quits (no resident process after), and the returned sections contain real Forklyft content (a project / task / customer name recognizable from the spike). Record PASS + a one-line sample in the ledger. If it returns `[]`, debug before proceeding — this is the task's gate.
- [ ] **Step 4: Verify both platforms build** (`swift build` or the project's Mac build; `tsc`/the Windows build for TS). No resident browser left behind.
- [ ] **Step 5: Commit** (both crawl files + the `erp.ts` export change, one commit).

---

## Task 3: Ingest orchestration, injection, and scheduling (both platforms)

Wire capture → reader → store, inject the facts, and schedule the ingest (end-of-day + on first connect). Fail-soft throughout.

**Files:**
- Modify: `src/ErpCrawl.swift` + `windows/src/main/system/erpCrawl.ts` — add `ingest`.
- Modify: `src/NikxelSettings.swift:462-466` + `windows/src/main/core/settings.ts:252-256` — add `ErpContext.injectedBlock` to `userContextBlock`.
- Modify: `src/DayLogger.swift:613` + `windows/src/main/system/dayLogger.ts:657` — call ingest after the twin distill.
- Modify: `src/NikxelApp.swift:211-216` + `windows/src/main/main.ts:399-403` — kick off an ingest on first successful connect, and add the one-line disclosure to the connect card.

**Interfaces:**
- Consumes: `ErpCrawl.capture()` (Task 2), `ErpContext.readerPrompt/accept/boundText/facts` (Task 1), `MOMGenerator.runPrompt` / `momGenerator.runPrompt`.
- Produces:
  - Swift: `static func ingest(runPrompt: (_ prompt: String, _ kind: String) throws -> String)` — guard `ERP.isConnected && ERP.hasLiveSession()`; `let sections = capture()`; if empty, return (keep old facts); `let text = ErpContext.boundText(sections)`; `let out = try? runPrompt(ErpContext.readerPrompt(text), "erp-ingest")`; `ErpContext.facts = ErpContext.accept(new: out ?? "", old: ErpContext.facts)`. Runs on the caller's background queue.
  - TS: `export async function ingest(runPrompt): Promise<void>` — same logic, async.

- [ ] **Step 1: Write the failing tests** (TS `erp.test.ts`, mirrored Swift asserts) — pure-logic only, stubbing capture/runPrompt:

```ts
// ingest keeps old facts when capture is empty (no browser / no session)
ErpContext.facts = "OLD FACTS";
await ingestWith(async () => [], async () => "NEW");   // capture ⇒ [], runPrompt stub
assert(ErpContext.facts === "OLD FACTS");

// ingest stores new facts when capture yields text and the reader returns facts
await ingestWith(async () => ["Project Rentop — yours"], async () => "Project Rentop — yours — due Fri");
assert(ErpContext.facts.includes("Rentop"));

// userContextBlock places ERP facts before the user's own context
Settings.userContext = "ZZUSER"; ErpContext.facts = "AAERP";
const b = Settings.userContextBlock;
assert(b.indexOf("AAERP") < b.indexOf("ZZUSER"));
ErpContext.facts = "";   // cleanup
```

(Expose a tiny injectable `ingestWith(capture, runPrompt)` seam, or structure `ingest` to take the capture fn, so the test needs no real browser. Keep the seam minimal — don't build an abstraction beyond what the test needs.)

- [ ] **Step 2: Run the tests, verify they fail.**
- [ ] **Step 3: Implement** `ingest` in both crawl files; add `ErpContext.injectedBlock` to both `userContextBlock`s (ordered: `[TwinProfile.injectedBlock, ErpContext.injectedBlock, user]`); call `ingest` after the distill in both `generateSummary`s (same background context, guarded by `ERP.isConnected`); on first connect (`ERP.signIn` success branch) fire `ingest` off-main; add one disclosure line to the connect-card copy (e.g. append to the "Opening…" or success lines: "Nikxel reads and summarizes your ERP into your context."). Mirror exactly on Windows.
- [ ] **Step 4: Run the tests, verify they pass; verify both platforms build.**
- [ ] **Step 5: Live end-to-end check, recorded in the ledger.** Trigger an ingest (first-connect path or a manual `generateSummaryNow`). Confirm `~/.nikxel/twin/erp.md` now holds real Forklyft facts (0600), and that `userContextBlock` includes them. Record PASS + a sample line.
- [ ] **Step 6: Commit** (all wiring, both platforms, one commit).

---

## Self-review notes

- **Spec coverage:** adapter interface / registry and Odoo-behind-it are **Phase 2**, not here (design phasing) — Phase 1 is the generic read path + twin fold, which Tasks 1–3 cover end to end. Settings `{url,kind}` and incremental cursors are deliberately deferred (Builder decisions 2 & 4) with reasons.
- **Type consistency:** `capture() -> [String]`, `boundText([String]) -> String`, `readerPrompt(String) -> String`, `accept(new,old,cap) -> String`, `facts: String`, `injectedBlock: String` are used identically across tasks and platforms.
- **Proportion:** three tasks, two small new files per platform + four small wiring edits; the one browser-driving task is the only large body and is validated live, not transcribed here.
