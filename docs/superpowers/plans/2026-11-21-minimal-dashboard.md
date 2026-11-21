# Minimal five-tab dashboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the ERP-driven org/team/charts dashboard with five tabs: Invite, My summaries, Projects, People and Connect. Projects are created by members. Sent day items and one-click shared meeting minutes flow into them.

**Architecture:**
- **Server** (`cloud/server`, Express 5 + better-sqlite3, still SQLite; Postgres is a later plan):
  - drops the ERP org tables and endpoints;
  - adds `projects`, `project_users` and `meeting_shares` tables, a project API, a project feed, a device project list and a device meeting share;
  - widens roles to include `cofounder`.
- **Dashboard** (`cloud/dashboard`, React 18 + Vite + Tailwind 4, lafda look): five tabs, with old screens deleted.
- **Desktop** (mac `src/` + Windows `windows/`):
  - drops "Build org from ERP…";
  - tags the 10pm summary against the user's dashboard projects (fetched and cached) instead of ERP projects;
  - adds "Share to project" on meeting minutes pages.

**Tech Stack:** Node 22, Express 5, better-sqlite3, node:test; React 18, Vite, Tailwind 4; Swift/AppKit; Electron TS.

**Spec:** `docs/superpowers/specs/2026-11-21-minimal-dashboard-design.md`

## Global Constraints

- **Roles:** exactly `owner`, `cofounder`, `admin`, `member`. The display label for `cofounder` is "co-founder". "Staff" means owner, cofounder or admin.
- **Role rules:**
  - staff can change roles and remove members;
  - only the owner can grant or revoke `cofounder`;
  - only staff can grant `admin`;
  - nobody can change the owner's role or remove the owner;
  - a member cannot change their own role.
- **Invites:**
  - any member can create a `member` invite;
  - staff can create `admin` invites;
  - only the owner can create `cofounder` invites;
  - the link format stays `${origin}/#join=<token>`, single use.
- **Project names:** unique per org, case-insensitive, archived projects included. Max 80 characters. Description max 200. A conflict returns 409 `{error:'name taken'}`.
- **Project writers:** a project's members plus staff can rename it, edit its description, add or remove members, and archive or unarchive it. Any org member can read any project, including archived ones, by id.
- **Meeting share body:**
  - the meeting's minutes markdown, minus any `## Client Summary` section, at most 20000 characters;
  - title at most 200 characters; `meeting_id` matches `^[A-Za-z0-9._-]{1,100}$`; date is `YYYY-MM-DD`;
  - re-sharing the same `(project, user, meeting_id)` replaces the earlier share;
  - never send the transcript or audio.
- **Nothing on the dashboard deletes a sent day or a meeting share.**
- **Download link placeholder:** `import.meta.env.VITE_NIKXEL_DOWNLOAD_URL || 'https://nikxel.app/download'`.
- **org_id scoping on every query, as today.** The device identity comes only from the bearer token, never from the body.
- **Mirror every `src/` change into `windows/` in the same commit.**
- **Files with uncommitted changes from another session:** `src/PageShare.swift`, `src/DayPage.swift`, `src/PageEdit.swift` and `windows/src/main/system/dayPage.ts`.
  - Never commit those changes.
  - When you must edit one of these files, stage only your own hunks: `git diff <file> > /tmp/x.patch`, cut the patch down to your hunks, then `git apply --cached /tmp/x.patch`.
  - Never stash, checkout or reset them.
- **Look:** keep the lafda styling (`index.css` tokens, `ui.jsx` components) and add no new npm dependencies. Each tab has one job: no stat strips, no charts, no filters except the Projects Work/Meetings switch.

## Review Focus

- **A member who isn't on a project** opens its URL: they can read it, but every write returns 403, and the UI shows no edit controls.
- **Renaming a project to another project's name in different case** ("produce ps" vs "Produce PS"): 409. Earlier sent items stay linked through `project_id` after any rename.
- **An admin trying to make someone a co-founder, or demote or remove the owner:** 403. A co-founder trying to remove the owner: 403.
- **A device sharing a meeting to a project the user isn't on, or to another org's project id:** 404, with nothing written.
- **The 10pm summary when the dashboard is unreachable:** it uses the cached project list. With no cache it tags nothing and still writes the summary.

---

### Task 1: Server — roles, members, invites, staff summary read, ERP org removal

**Files:**
- Modify: `cloud/server/db.js`:
  - drop `org_people`, `org_projects` and `project_members` with `DROP TABLE IF EXISTS`;
  - add the tables below.
- Modify: `cloud/server/routes.js`, `cloud/server/auth.js` (add `STAFF = ['owner','cofounder','admin']`), `cloud/server/seed.js`.
- Delete: `cloud/server/org.js`, `cloud/server/org.test.js`.
- Test: `cloud/server/routes.test.js`, `cloud/server/db.test.js`.

**Interfaces:**
- Produces these tables, used by Task 2:
  - `projects(id TEXT PK, org_id, name, description NOT NULL DEFAULT '', created_by, created_at INTEGER, archived INTEGER NOT NULL DEFAULT 0)` plus `CREATE UNIQUE INDEX projects_name ON projects(org_id, lower(name))`;
  - `project_users(project_id, user_id, added_at INTEGER, PRIMARY KEY(project_id,user_id))`;
  - `meeting_shares(id TEXT PK, org_id, project_id, user_id, meeting_id, title, date, body, created_at INTEGER, UNIQUE(project_id,user_id,meeting_id))`.
- Produces these endpoints:
  - `GET /api/members` (any member): `[{user_id, role, email, name}]`.
  - `PATCH /api/members/:userId {role}` (staff, role rules above).
  - `DELETE /api/members/:userId` (staff, role rules above). It deletes the membership, the user's device tokens for the org and their `project_users` rows in the org. Sent days and shares stay.
  - `POST /api/invites {role}` (invite rules above).
  - `GET /api/summaries/user/:userId` (staff, same org): the same shape as `/summaries/mine`; 404 if not in the org.
- Removes: `/rollup`, `/teams`, `/org`, `/org/import`, `/org/projects/*`, `/org/people/*`, `linkByEmail` calls.

- [ ] **Step 1: Write failing tests** in `routes.test.js`. Add a `cofA` cofounder to `boot()`.
  - `GET /api/members` as `memA` returns 200 with 5 rows for org A.
  - Invites:
    - `memA` creates a `member` invite: 200;
    - `memA` creates an `admin` invite: 403;
    - `admA` creates an `admin` invite: 200;
    - `admA` creates a `cofounder` invite: 403;
    - `owA` creates a `cofounder` invite: 200.
  - PATCH role:
    - `admA` sets `memA` to admin: 200;
    - `admA` sets `memA` to cofounder: 403;
    - `owA` sets `memA` to cofounder: 200;
    - `cofA` sets `owA` to anything: 403;
    - `memA2` sets themselves to admin: 403.
  - DELETE:
    - `admA` removes `memA2`: 200; their device token then gets 401 on `POST /api/summaries`; their sent summary row still exists;
    - `cofA` removes `owA`: 403;
    - `admA` removes `cofA`: 403;
    - `owA` removes `cofA`: 200.
  - `GET /api/summaries/user/memA`:
    - `admA`: 200 with memA's days;
    - `memA2`: 403;
    - `owB` asking for `memA`: 404.
  - `GET /api/rollup`, `/api/org` and `/api/teams` return 404.
  - Delete the old org/rollup/team tests.
- [ ] **Step 2: Run** `cd cloud/server && npm test`. Expect the new tests to FAIL.
- [ ] **Step 3: Implement.** Use `requireRole(db, ...STAFF)` where staff is needed. Add a test in `db.test.js` that `bootstrap` on a DB that has the old `org_people` table drops it.
- [ ] **Step 4: Run** `npm test`. Expect PASS. Then `node seed.js` against a fresh `DB_PATH` succeeds; update the seed to drop the org import and give one seed user the `cofounder` role.
- [ ] **Step 5: Commit** `feat(server): co-founder role, member removal, open invites, drop ERP org`.

### Task 2: Server — projects, feed, device project list, meeting shares

**Files:**
- Create: `cloud/server/projects.js` (queries and validation), `cloud/server/projects.test.js`.
- Modify: `cloud/server/routes.js` (mount the routes). `POST /api/summaries` sets `item.project_id`.
- Modify: `cloud/server/seed.js` (two projects, a few tagged items, one meeting share).

**Interfaces:**
- Consumes: the Task 1 tables and `STAFF`.
- Produces (all org-scoped):
  - `GET /api/projects` (any member): `[{id, name, description, archived:false, members:[{user_id,name}], last_activity}]`. Non-archived only, sorted by last_activity descending then name. `last_activity` is the latest date of a share or linked item, or null.
  - `POST /api/projects {name, description?}` (any member): `{id}`. The creator becomes a member.
  - `PATCH /api/projects/:id {name?, description?, archived?}` (project writers).
  - `PUT /api/projects/:id/members/:userId` and `DELETE /api/projects/:id/members/:userId` (project writers). The target must be an org member, otherwise 400.
  - `GET /api/projects/:id` (any member):
    `{project:{id,name,description,archived,members:[{user_id,name}], can_edit}, days:[{date, meetings:[{id,title,body,user_id,name}], items:[{...item, user_id, name}]}]}`
    - `days` is newest first; only dates that have something.
    - Items are day items whose `project_id` equals this project, from any user in the org (including past members).
    - Unknown or cross-org id: 404.
  - `GET /api/device/projects` (deviceAuth): `[{id, name}]`, the user's non-archived projects, by name.
  - `POST /api/projects/:id/meetings` (deviceAuth) `{meeting_id, title, date, body}`: `{ok:true}`. The user must be a project member and the project not archived, otherwise 404. Upsert on `(project_id,user_id,meeting_id)`.
  - `POST /api/summaries`: for each item with a non-empty `project`, set `project_id` to the id of the user's own project whose `lower(name) = lower(project)`, else `null`. `project` text is kept.

- [ ] **Step 1: Write failing tests** in `projects.test.js`. Reuse `boot()`; export it from `routes.test.js` into a small `testkit.js` if needed.
  - `memA` creates "Produce PS": 200.
  - `memA2` creates "produce ps": 409.
  - Membership and writes:
    - `memA` adds `memA2`: 200;
    - `memA` adds `owB`: 400;
    - a non-member member (a new `memA3`) PATCHes the name: 403, but GETs it: 200;
    - `admA` (not a member) PATCHes `archived:true`: 200.
  - Archived:
    - the list omits it;
    - `GET` by id still returns it;
    - device projects omit it;
    - a meeting share to it returns 404.
  - Sent days:
    - `memA`'s device sends a day with an item `project: 'PRODUCE ps'` and one with `project: 'Nope'`;
    - the feed shows the first with `name`, and the second appears nowhere;
    - after renaming the project to "PPS", the feed still shows the item.
  - Meeting shares:
    - the device shares meeting `2026-11-21-1030` twice with different bodies: the feed has one meeting with the second body;
    - `memA3`'s device sharing to the project returns 404;
    - an org B device sharing to the org A project id returns 404.
  - Validation: a body over 20000 characters gives 400; a bad `meeting_id` gives 400.
- [ ] **Step 2: Run** `npm test`. Expect FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `npm test`. Expect PASS. Then `node seed.js` works.
- [ ] **Step 5: Commit** `feat(server): member-created projects with a feed and meeting shares`.

### Task 3: Dashboard — five-tab shell, Invite, My summaries, People, Connect, join flow

**Files:**
- Modify: `cloud/dashboard/src/App.jsx`, `api.js`, `screens/People.jsx`, `screens/Onboarding.jsx`, `screens/Mine.jsx` (accept an optional `userId` and title; uses `api.userSummaries`).
- Create: `screens/Invite.jsx`, `screens/Install.jsx` (onboarding steps: Install Nikxel with the download link, then a "Connect" button leading to `#connect`).
- Delete:
  - `screens/{Team,Charts,Pie,Line,Org,OrgSummary,TeamGrid,TeamDrawer,PeopleTable}.jsx`;
  - `stats.js`, `stats.test.js`, `orgView.js`, `org.test.js`;
  - every `api` method for removed endpoints.
  - Keep `Projects.jsx` only if Task 4 reuses it; otherwise Task 4 replaces it. Until Task 4, the Projects tab shows `Muted` "Coming next".
- Test: `cloud/dashboard/src/api.test.js` (extend), plus a new `src/roles.test.js` for `roles.js`.

**Interfaces:**
- Consumes: the Task 1 endpoints.
- Produces: `src/roles.js` with `STAFF`, `isStaff(role)`, `roleLabel(role)` ('co-founder' for cofounder), and `assignableRoles(myRole) -> string[]` (owner gives `['member','admin','cofounder']`, admin/cofounder give `['member','admin']`, member gives `['member']`). Task 4 uses `isStaff`.

- [ ] **Step 1: Write failing tests** for `roles.js`: every role through `assignableRoles` and `roleLabel`.
- [ ] **Step 2: Run** `cd cloud/dashboard && npm test`. Expect FAIL.
- [ ] **Step 3: Implement.** Load the `frontend-design` skill first.
  - **Tabs:** `#invite`, `#mine` (label "My summaries", the default), `#projects`, `#people` (staff only), `#connect`.
  - **Invite tab:** a role select (`assignableRoles`, hidden when it has one entry), "Create link", the link in a read-only field, Copy. Under it, one muted line: "They sign in with Google, install Nikxel, then connect it."
  - **Join flow:**
    - On load, if the hash is `#join=<token>`, save the token to `sessionStorage` and clear the hash.
    - After `me` loads with no org and a saved token, call `joinOrg` automatically, clear the token, and route to `#install`.
    - A user who is already in an org with a saved token just drops the token. A failed join shows the error on Onboarding.
    - New orgs also land on `#install` once.
  - **People (staff only):** each row shows name, email and a role select (`assignableRoles`, the owner row read-only), plus Remove (with a confirm) and "Summaries" linking to `#people/<userId>`, which renders `Mine` for that user with the person's name as the heading.
  - The header still shows the name, role label and Log out.
- [ ] **Step 4: Run** `npm test && npm run build`. Take headless-Chrome screenshots against the controller's dev server (the controller gives the URL) as a staff user and a member, at 1440 and 375, in light and dark: every tab, plus `#people/<id>`. Check:
  - members don't see People;
  - no horizontal scroll at 375;
  - opening `/#join=<token>` while signed out, then dev-login, lands in the org on `#install`.
- [ ] **Step 5: Commit** `feat(dashboard): five-tab shell with invite, people and join flow`.

### Task 4: Dashboard — Projects tab

**Files:**
- Replace: `cloud/dashboard/src/screens/Projects.jsx` (list plus create).
- Create: `screens/Project.jsx` (one project page), `src/feed.js` (pure helpers), `src/feed.test.js`.
- Modify: `api.js` (project calls), `App.jsx` (`#projects/<id>` renders `Project`).

**Interfaces:**
- Consumes: the Task 2 endpoints, `isStaff` from Task 3, and the existing `screens/Day.jsx` item rendering, where reusable.
- Produces: `feed.js`:
  - `splitFeed(days, mode) -> days`: `mode` is `'work'` or `'meetings'`. Meetings mode keeps each day's `meetings` plus items whose `section === 'meetings'`. Work mode keeps the other items and no meetings. Days left empty are dropped.
  - `mdBlocks(md) -> [{kind:'h'|'li'|'p', text}]`: `#`-lines become `h`, `- `/`* ` lines become `li`, other non-empty lines become `p`. It is used to render a shared meeting body as text nodes, never as HTML.

- [ ] **Step 1: Write failing tests:**
  - `splitFeed` on a 2-day fixture:
    - Meetings mode keeps a share and a meetings-section item;
    - Work mode drops a day that only had a meeting.
  - `mdBlocks` turns `"## Decisions\n- Ship Friday\ntext"` into `[h, li, p]`.
  - `mdBlocks('<img src=x onerror=alert(1)>')` gives a `p` with that literal text.
- [ ] **Step 2: Run** `npm test`. Expect FAIL.
- [ ] **Step 3: Implement.**
  - **Projects list:** a "New project" inline form (name, optional description) at the top. Below it, one row per project: name, description, member avatars/initials, and "active <date>". Archived projects are hidden. A 409 shows "That name is taken".
  - **Project page:**
    - Header: name, description, members.
    - When `can_edit`: Edit (rename/description), Add member (select from `GET /api/members` minus current members), remove ×, and Archive/Unarchive.
    - Work / Meetings switch.
    - Day groups newest first. A meeting share is a card with title, sharer and `mdBlocks` body, collapsed after about 6 lines with "Show all". Items show the person's name, with the type/minutes styling from `Day.jsx`.
    - An empty project shows: "Nothing yet. Work tagged to this project at 10pm and meeting minutes shared from Nikxel show up here."
- [ ] **Step 4: Run** `npm test && npm run build`. Take screenshots of the list and a seeded project page (both modes) at 1440 and 375, light and dark, as a project member and as a non-member member. Check: there are no edit controls for the non-member; no horizontal scroll; and a long meeting body collapses.
- [ ] **Step 5: Commit** `feat(dashboard): projects with a work and meetings feed`.

### Task 5: Desktop (mac + Windows) — project tagging, Share to project, drop ERP org import

**Files:**
- Delete: `src/OrgImport.swift`, `windows/src/main/system/orgImport.ts`, `windows/src/checks/orgImport.test.ts`. Also remove the "Build org from ERP…" menu item in `src/NikxelApp.swift` and `windows/src/main/main.ts`. Remove `ERP.orgSnapshot` / `CloudSync.importOrg` if nothing else uses them.
- Modify: `src/CloudSync.swift`, `windows/src/main/system/cloudSync.ts`. Add:
  - `projects(get:) -> [Project]`, which calls `GET /api/device/projects` and caches the result to `~/.nikxel/projects.json`, falling back to the cache on failure;
  - `shareMeeting(projectID:meetingID:title:date:body:)` -> Bool;
  - a `meetingShareBody(markdown) -> String` helper that strips the `## Client Summary` section and caps at 20000 characters.
- Modify: `src/DayLogger.swift:620` and `windows/src/main/system/dayLogger.ts:663`.
  - The project list comes from `CloudSync.projects()` names; an empty list when unpaired.
  - Prompt wording: replace "ERP project" with "project" and the "ERP projects:" header with "Projects:".
- Modify: `src/NotePage.swift` + `windows/src/main/system/notePage.ts` (a "Share to project" button on meeting pages, next to the client CTA). Also `src/PageShare.swift` + `windows/src/main/system/pageShare.ts`:
  - `/projects` returns `{paired, projects:[{id,name}], body}`, where `body` is exactly what would be sent;
  - `/share-project?project=<id>` sends via `shareMeeting`. The meeting id is the minutes file's stem, the title is the page's `# ` title, and the date is the first 10 characters of the stem.
  - Follow the "uncommitted changes from another session" rule.
- Test: the existing Swift self-check/test pattern used for `CloudSync` (look at how `dayItems` is tested) and `windows/src/checks/cloudSync.test.ts`.

**Interfaces:**
- Consumes: `GET /api/device/projects` and `POST /api/projects/:id/meetings` from Task 2.

- [ ] **Step 1: Write failing tests** on both platforms:
  - `meetingShareBody` drops `## Client Summary` and everything up to the next `## `, keeps the other sections, and caps at 20000 characters;
  - `projects()` with an injected getter that fails returns the cached list written by an earlier successful call; with no cache it returns `[]`.
- [ ] **Step 2: Run** the Swift check and `cd windows && npm test`. Expect FAIL.
- [ ] **Step 3: Implement.** The Share dialog:
  - lists the projects as radio buttons, shows the exact body in a scrollable preview, and has Send and Cancel;
  - unpaired shows "Connect Nikxel to the dashboard first";
  - no projects shows "You're not on any project yet. Create one on the dashboard.";
  - success shows "Shared to <name>".
- [ ] **Step 4: Run** the tests, `./build.sh`, and the Windows typecheck/build. Then, against the controller's local server, pair a device, open a real meeting minutes page, Share to a seeded project, and confirm it appears on that project's dashboard page.
- [ ] **Step 5: Commit** `feat(desktop): tag summaries with dashboard projects and share meetings to projects`.
