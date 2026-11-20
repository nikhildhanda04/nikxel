# Nikxel Org Dashboard — Design

**Date:** 2026-11-20
**Status:** Draft for approval

## Intent & why

Nikxel is today a purely local, single-user desktop app (macOS Swift +
Windows Electron). Every artifact — daily/weekly summaries, the learning
twin, ERP facts, raw activity logs — is generated on-device and written to
sealed files under `~/.nikxel/` (0600). Nothing leaves the machine and
there is no backend, no accounts, no server.

We want to turn Nikxel into an **org product** without giving up that
local-first core. A hosted web dashboard lets people in the same company:

- sign in (Google) and connect their Nikxel app to their account,
- share meeting/project summaries with each other as shared context,
- invite teammates into the org,
- and give admins a management view where each member's daily summary rolls
  up into a **work summary** (time worked + what was worked on).

The dashboard is a **sharing layer on top of the existing local app**, not a
replacement for it. The desktop app keeps doing everything it does now; it
gains only the ability to push the summaries a user chooses to share.

## Goals

- Web dashboard, one view per signed-in user, minimal design.
- Google login as identity.
- Org model: users belong to an org, with roles; invite teammates.
- Peer sharing: a member can share a meeting/project summary to the org so
  connected teammates see it as context.
- Admin rollup: admins see each member's daily **work summary**.
- Member transparency + redaction: a member **sees** exactly what is going
  up to the admin, can **remove** any line (something personal slipped
  through), but **cannot add** lines and **cannot edit** the hours or the
  "what was worked on."
- **Manual release (owner's choice):** a pushed work summary is private to
  the member until they **release** it. The admin sees nothing until then,
  so there is no window in which a personal line is visible. The cost — a
  summary the member never releases never rolls up — is accepted.
- Owner role: the org owner can edit any summary (including hours/work
  items) before it is shared. Documented as a normal privileged role — not
  hidden from the code, its history, or this doc.
- Desktop app stays local-first; only user-shared summaries sync up.

## Non-goals

- Replacing the desktop app's own pages/summaries. The app is still the
  source of truth; the dashboard shows only what was pushed.
- Mobile app, real-time collaboration, billing/subscriptions, SSO beyond
  Google, fine-grained per-field ACLs.
- Email infrastructure. Invites are shareable links, not sent emails (v1).
- End-to-end encryption of shared summaries — they are shared by design.

## Anti-goals (what makes this a failure even if it "works")

- Any data the user did **not** choose to share reaching the backend. The
  twin, `erp.md`, raw logs, app-usage samples, window titles — these never
  leave the device. Only the explicitly-shared summaries sync.
- The dashboard becoming a second, authoritative copy of the twin/ERP state.
- A member being able to inflate their hours, or an admin silently seeing
  something a member removed.
- Surveillance beyond the shared work summary (no live screen, no keystroke
  feed, no raw activity).

## Constraints

- **Data boundary (hard):** only user-shared summaries leave the device;
  everything else stays sealed local (0600). Enforced on the desktop push
  side — the app only ever POSTs summary content, nothing else.
- **Stack:** Node + Express backend, React dashboard, SQLite storage,
  Google login. (Confirmed by owner.)
- **Mirror rule:** every Swift `src/` change ships with its `windows/`
  mirror in the same commit, both verified to build.
- **Identity use:** the user's Google email identifies them to **their own
  Nikxel backend** only. It is never forwarded to any third-party service.
- **Minimal design:** the owner's explicit instruction — "very very very
  minimal." Plain, high-whitespace, one clean typeface, no chrome.
- **Owner-edit honesty:** the owner-edit capability is a documented role in
  the code and commit history. It is not written into the end-user UI for
  members, but it is never concealed from the repository or its history.

## Approaches considered

**Approach 1 — one small service (CHOSEN).** A single Express app serves
both the JSON API and the built React dashboard (static assets). SQLite
file for storage. Google OAuth → signed JWT cookie (stateless, no session
table). Desktop links via a one-time pairing code → long-lived device
token, then POSTs shared summaries over HTTPS. One process, one host, one
DB file.

- *Trades off:* single-instance (SQLite) — fine until real scale.
- *Why chosen:* ships the whole org + admin + invite + share vision with
  the fewest moving parts, lowest cost, fastest path. Nothing about it
  blocks Approach 2 later; SQLite→Postgres is the only swap.

**Approach 2 — split services.** API, dashboard on Vercel, managed
Postgres, hosted auth provider. More scalable, more infra, more cost,
slower to ship. Rejected for now — earns its keep only at real scale, and
v1 does not need it.

## The design

### Topology

```
Desktop app (local, unchanged except push)  ──HTTPS POST──▶  Express API ──▶ SQLite
                                                                  │
Browser ──Google login──▶  Express (serves React SPA) ◀──reads───┘
```

One Express process:
- `/api/*` — JSON API.
- everything else — the built React SPA (static), client-side routed.

### Storage (SQLite)

Tables (exact DDL left to the builder):

- `users` — id, google_sub (unique), email, name, created_at.
- `orgs` — id, name, owner_user_id, created_at.
- `memberships` — user_id, org_id, role ∈ {owner, admin, member}. **v1: one
  org per user** — no org switcher, and the device token resolves its org
  from the member's single membership (so the push needs no org on the
  credential). The schema still keys on (user, org) so multi-org is a later
  swap, not a rewrite.
- `invites` — id, org_id, token (unique), role, created_at, accepted_by.
  (Link-based; no email send in v1.)
- `device_tokens` — id, user_id, token_hash, created_at, last_used. The
  desktop app's bearer credential.
- `pairing_codes` — code, user_id, org_id, expires_at. Short-lived 6-digit
  code the dashboard shows and the app redeems.
- `summaries` — id, user_id, org_id, kind ∈ {work, meeting, project}, date,
  items (JSON), notes (text), visibility ∈ {admin, org},
  status ∈ {pending, released}, created_at.
  - A **work** summary is pushed `pending` (private to its member + owner).
    The member releases it → `released`, and only then can an admin read it.
  - A **meeting/project** summary is pushed only when the member explicitly
    shares it, so the share *is* the release: it is created `released`.

**Summary content shape.** A summary's `items` is a JSON array of
`{ id, what, minutes, removed }`. This is what makes the redact/integrity
model enforceable at the row level:

- `removed` is the only field a **member** may change (redaction).
- `what` and `minutes` are immutable to a member.
- an **owner** may edit any field.
- an **admin** reading a rollup sees items where `removed == false`.

`notes` is free-form markdown for meeting/project summaries (no per-line
integrity needed there).

### Auth & roles

- **Web login:** Google OAuth (server-side code exchange via the official
  `google-auth-library`). On success the server issues a signed JWT in an
  httpOnly cookie (stateless — no session table). JWT carries user id +
  org + role.
- **Bootstrap / onboarding:** on first sign-in a user with no membership
  lands on a "create an org, or paste an invite link" screen. Creating an
  org makes them its **owner**; an invite link makes them a member/admin
  per the link's role. (v1: anyone may create an org.)
- **Role matrix:**

  | capability | member | admin | owner |
  |---|---|---|---|
  | read own summaries | ✓ | ✓ | ✓ |
  | redact own (flip `removed`) | ✓ | ✓ | ✓ |
  | edit own `what`/`minutes` | ✗ | ✗ | ✓ |
  | release own work summary to admin | ✓ | ✓ | ✓ |
  | read members' **released** work rollup | ✗ | ✓ | ✓ |
  | read org-shared meeting/project summaries | ✓ | ✓ | ✓ |
  | manage invites & members | ✗ | ✓ | ✓ |
  | edit **any** summary's facts | ✗ | ✗ | ✓ |

  The owner-edit row is the privileged capability requested by the owner. It
  is a real role check in the API, honestly named. "Edit before it is
  shared" maps onto the lifecycle: the owner may edit a summary's facts
  while it is `pending`; releasing is still the member's own act.

### Desktop ↔ backend pairing

1. Dashboard shows "Connect your Nikxel app" → a 6-digit code (row in
   `pairing_codes`, short expiry, bound to the signed-in user+org).
2. In the Nikxel app, the user enters the code once. App POSTs
   `/api/pair { code }`.
3. Backend validates, issues a random **device token**, stores its hash in
   `device_tokens`, returns the token once.
4. App stores the token locally (`~/.nikxel/` 0600, mirrored on Windows)
   and sends `Authorization: Bearer <token>` on every push.

Same trust model as the existing ERP sign-in: no Nikxel password, a
one-time human-in-the-loop link.

### Sync (push, one direction)

- When the desktop app generates a **daily summary**, it derives the work
  summary items (time worked + what) and POSTs them to `/api/summaries`
  with `kind=work, visibility=admin`. The row lands `pending` — private to
  the member. In the dashboard the member redacts personal lines, then
  **releases** it; only a released summary enters the admin rollup.
- **Re-push is idempotent per day.** A work summary is keyed by
  (user, org, kind, date); a regenerated day **merges by item id into the
  existing row and preserves every `removed` flag** — a re-push never
  un-redacts. It also does not change the row's `status` (a re-push of an
  already-released day stays released; new items it adds inherit that
  status — a known, accepted simplification).
- **Meeting/project** summaries are pushed as the user shares them
  (`kind=meeting|project, visibility=org`), so connected teammates see them
  as context. v1: the user triggers the share; the app pushes on share.
- Push is **the only** egress. The app never sends logs, the twin, ERP
  facts, or raw activity. The payload schema is summary-only, which is how
  the data boundary is enforced in code, not just by policy.

### Dashboard (React, minimal)

Vite React SPA, built to static, served by Express. Design is deliberately
plain (owner's instruction): one clean typeface, generous whitespace, no
decorative chrome. Screens:

- **Login** — Google button.
- **Connect app** — the pairing code.
- **My summaries** — the member's own work summary with per-line remove and
  a **Release to admin** action; `pending` vs `released` is shown per day.
  Facts are read-only (owner role shows them editable — same screen,
  role-gated). Their shared meeting/project summaries listed.
- **People** — org members, connect/invite (shareable link).
- **Admin** — (admins/owner only) the member work rollup.

Tailwind is already in the repo's web tooling, so the dashboard uses
Tailwind for the minimal styling rather than adding a UI kit.

### Hosting

A single small host (Render / Railway / Fly / a VPS) running the one Express
process with the SQLite file on disk and TLS from the host. Choice is the
owner's; nothing in the design depends on which.

### Where the code lives

A new top-level `cloud/` directory, isolated from the desktop build:
- `cloud/server` — Express + SQLite + auth.
- `cloud/dashboard` — Vite React SPA (builds into static served by server).

The desktop change (pairing + push) is small and lives in the existing
`src/` (Swift) with its `windows/` mirror.

## What's left to the builder

- Exact SQLite schema DDL and a migration/bootstrap on first run.
- Google OAuth client registration (client id/secret, redirect URI) and
  where secrets are read from (env). JWT/cookie signing secret handling.
- Device-token format, hashing, and the exact `~/.nikxel/` storage path
  (and its Windows mirror).
- The push payload JSON schema and server-side validation; the role-gated
  redaction/edit endpoint semantics.
- Invite link format and acceptance flow.
- The React route/screen implementation and the minimal visual system.
- Hosting choice and deploy steps.
- How the desktop derives work-summary `items` (what/minutes) from the
  existing daily summary generated in `DayLogger`.
