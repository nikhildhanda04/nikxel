# Dashboard: lafda style, admin charts, ERP projects — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restyle the org dashboard to match lafda.fun. Give admins charts first and the detailed days after. Group everyone's work, meetings and ERP tasks by ERP project, with a summary and details per project.

**Architecture:** Projects come from the desktop app at 10pm.
- The summary prompt gets the user's ERP project names and adds a hidden `[[Project]]` tag after the type tag on each work and meeting bullet.
- Nikxel appends a `## ERP tasks` section listing the user's ERP tasks that changed that day.
- `dayItems` carries a new `project` field. The server stores it. The dashboard aggregates by project on the client (no new server routes).
- Charts are inline SVG with no new dependencies.

**Tech Stack:** Swift (`src/`), TypeScript/Electron (`windows/`), Node 22 + Express 5 + better-sqlite3 (`cloud/server`), React 18 + Vite + Tailwind 4 (`cloud/dashboard`).

**Spec:** the user's request of 2026-11-21 (this session):
1. Make the dashboard look like https://lafda.fun/posts/theo-vs-prateek-t3-users-called-cavemen-the-board-called-slo: same fonts, same style.
2. Admins get graphs (a visual picture of what people are doing), then the detailed summaries as today.
3. Take the projects being worked on from ERP, from meetings, from ERP tasks and from what users are doing, and keep a project-wise summary and details.

The user's answers:
- **Project attribution:** auto at 10pm, from the ERP project list. The preview still lets the user untick anything.
- **ERP tasks:** the ones assigned to the person that changed that day, with project, stage and deadline.
- **Project view:** admins (owner and admins) only.

## Global Constraints

- Every `src/*.swift` change gets the same change in `windows/` in the same commit (memory: mirror-swift-changes-to-windows).
- **Wire item shape:** becomes `{ id, section, what, type, minutes, details, project }`. `project` is a string and `""` when unknown. The `id` rule is unchanged.
- **Sent sections:** `what you worked on`, `meetings`, `browsing & reading`, `other`, plus the new `erp tasks`. Chats and open tasks are never sent.
- **Project tag format:** `[[<exact ERP project name>]] ` right after the type tag, e.g. `- [coding] [[Produce POS]] Fixed the sign-out bug…`. It is hidden on the daily page, as type tags are.
- **ERP tasks section:** written by Nikxel's code, not by the LLM. Heading `## ERP tasks`. One bullet per task: `- [[<project>]] <task name> — <stage>` plus ` (due YYYY-MM-DD)` when there's a deadline. The section is left out when ERP isn't connected or nothing changed.
- **lafda tokens, light:** bg `#fff`, card `#fff`, fg `#0a0a0a`, muted-fg `#737373`, border `#e5e5e5`, accent `#f5f5f5`.
- **lafda tokens, dark:** bg `#0a0a0a`, card `#171717`, fg `#fafafa`, muted-fg `#a1a1a1`, border `#ffffff1a`, accent `#262626`.
- **lafda fonts:** headings in **Instrument Sans** (600, tight tracking), body in **Public Sans**, both from Google Fonts.
- **lafda look:** rounded-xl cards with 1px borders, small gray rounded-md tag pills, muted meta lines separated by `·`, centered reading column about 640px wide, a moon/sun theme toggle in the header.
- **Theme:** follows the system, the toggle overrides it, and the choice is remembered in `localStorage` wrapped in try/catch.
- New npm or Swift dependencies: none. Charts are hand-written SVG.

## Review Focus

- **ERP not connected at 10pm:** the summary still generates, with no `[[…]]` tags and no `## ERP tasks` section, and nothing errors. Test in Task 1.
- **The LLM invents a project name not in the list:** `dayItems` keeps it as written. The dashboard then shows a project that isn't in ERP, which is acceptable but visible. Test that `dayItems` parses `[[Anything]]`, in Task 1.
- **Days sent before this change (no `project`):** the server stores `""`. The dashboard puts them under "No project" and doesn't crash. Tests in Tasks 2 and 4.
- **A project name with brackets or `]]` inside it:** the parser takes the first `]]`, and the server caps the name at 200 characters. Test in Task 1.
- **An admin with zero sent days:** the charts render an empty state, not NaN bars. Test in Task 4.

---

### Task 1: Desktop: project tags at 10pm, ERP tasks section, `project` in dayItems (mac + windows)

**Files:**
- Modify: `src/ERP.swift` and `windows/src/main/system/erp.ts`. Add `tasksTouched(on day: Date) -> [TouchedTask]` (TS: `tasksTouched(day: Date): Promise<TouchedTask[]>`), where `TouchedTask = { name, project, stage, deadline }`.
  - Query `project.task` `search_read` with domain `[["user_ids","in",[uid]], ["write_date",">=",<day 00:00 local, in UTC "YYYY-MM-DD HH:MM:SS">], ["write_date","<",<next day 00:00 local, in UTC>]]`.
  - Fields: `name, project_id, stage_id, date_deadline`.
  - Returns `[]` when not connected or on any failure. `uid` comes from `sessionUID()` (TS: the existing session-info call).
- Modify: `src/DayLogger.swift` and `windows/src/main/system/dayLogger.ts`.
  - When ERP is connected, `summaryPrompt` adds an `ERP projects:` list (from `ERP.projects()`) to the raw data, plus this rule: *"After the type tag, add the ERP project the bullet belongs to as `[[<exact name from the ERP projects list>]] `, only when it clearly belongs to one; otherwise add nothing."*
  - After the model's output is written, `generateSummary` appends the `## ERP tasks` section built from `tasksTouched(on: date)`, before writing the `.md`.
- Modify: `src/CloudSync.swift` and `windows/src/main/system/cloudSync.ts`.
  - `DayItem` gains `project: String`.
  - After the type tag, `dayItems` strips `^\[\[([^\]]+?)\]\]\s*` into `project` (trimmed, else `""`).
  - `sectionTypes` gains `"erp tasks": "planning"`.
  - `pushDay` sends `project` in each item.
- Modify: `src/DayPage.swift` and `windows/src/main/system/dayPage.ts`.
  - The tag-hiding regex also removes a `[[…]] ` that follows the type tag (or stands alone at the start of a bullet).
  - The preview's item row shows `project` as a gray pill after the type chip, when it isn't empty.
- Test: `check_cloud_sync.swift`, `check_day_page.swift`, `windows/src/checks/cloudSync.test.ts`, `windows/src/checks/dayPage.test.ts`.

**Interfaces:**
- Produces: items with `project`. The `erp tasks` section items carry `type: "planning"` and `project`.

- [ ] **Step 1: Write the failing tests** (Swift and TS mirror each other):
  - `dayItems` on `"## What you worked on\n- [coding] [[Produce POS]] Fixed sign-out 1h\n- [other] No project here\n\n## ERP tasks\n- [[Produce POS]] Sign-out button — In Progress (due 2026-11-25)\n- [[A ]] weird]] name]] Task — Done"` gives:
    - item 0: `project == "Produce POS"`, `what == "Fixed sign-out"`, `minutes == 60`, `type == "coding"`
    - item 1: `project == ""`
    - item 2: `section == "erp tasks"`, `type == "planning"`, `project == "Produce POS"`, `what == "Sign-out button — In Progress (due 2026-11-25)"`
    - item 3: `project == "A"`
  - The pushed item keys are exactly `id, section, what, type, minutes, details, project`.
  - `DayPage.html(md, daily)` contains neither `[[Produce POS]]` nor `[coding]`, and its embedded `nx-day` JSON item 0 has `project: "Produce POS"`.
  - The ERP-tasks section builder, `DayLogger.erpTasksSection([TouchedTask]) -> String` (static and pure; TS `DayLogger.erpTasksSection(tasks)`):
    - Given `[{name:"Sign-out button", project:"Produce POS", stage:"In Progress", deadline:"2026-11-25"}, {name:"X", project:"", stage:"Done", deadline:""}]`, it returns `"\n## ERP tasks\n- [[Produce POS]] Sign-out button — In Progress (due 2026-11-25)\n- X — Done\n"`.
    - Given `[]`, it returns `""`.
- [ ] **Step 2: Run** `swiftc -parse-as-library -target arm64-apple-macos15.0 -o /tmp/ccs src/CloudSync.swift check_cloud_sync.swift && /tmp/ccs`, the `check_day_page.swift` command in its header, and `cd windows && npx tsx --test src/checks/cloudSync.test.ts src/checks/dayPage.test.ts < /dev/null`. Expect FAIL.
- [ ] **Step 3: Implement** the changes above. `erpTasksSection` lives on DayLogger. If DayLogger's file is too entangled for a check to compile, put it in CloudSync instead and say so.
- [ ] **Step 4: Run** the step 2 commands, plus `npx tsc --noEmit -p windows` and the full Swift typecheck `swiftc -typecheck -parse-as-library -target arm64-apple-macos15.0 -D NIKXEL_PRIVATE src/*.swift private/*.swift 2>&1 | grep -E "^/.*: error:"` (it must print nothing). Expect PASS.
- [ ] **Step 5: Commit** `feat(desktop): ERP project tags and touched ERP tasks in the day (mac + windows)`.

### Task 2: Server: store `project`

**Files:**
- Modify: `cloud/server/summaries.js` (`cleanDay`: keep `project`, a string trimmed and sliced to 200 characters, defaulting to `""` when missing or not a string)
- Modify: `cloud/server/seed.js`: give the seeded items realistic `project` values (2–3 projects shared across people, some `""`), and add `erp tasks` items
- Test: `cloud/server/summaries.test.js`, `cloud/server/routes.test.js`

- [ ] **Step 1: Write the failing tests:**
  - `cleanDay` keeps `project: "Produce POS"`.
  - A missing project becomes `""`, and so does `project: 42`.
  - A 300-character project is sliced to 200.
  - `/rollup` and `/summaries/mine` return `project` on items.
- [ ] **Step 2: Run** `cd cloud/server && node --test --test-force-exit`. Expect FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the same command, then `DB_PATH=/tmp/seed-check.db node seed.js`. Expect PASS, and the seed runs cleanly.
- [ ] **Step 5: Commit** `feat(cloud): items carry their ERP project`.

### Task 3: Dashboard: lafda restyle of every screen

**Files:**
- Modify: `cloud/dashboard/index.html` (Google Fonts: Instrument Sans 500–700 and Public Sans 400–700, replacing the current fonts)
- Modify: `cloud/dashboard/src/index.css` (the Global Constraints tokens for light and dark, `[data-theme]` overrides, and type colors kept but muted to sit on these grays)
- Modify: `cloud/dashboard/src/App.jsx`. The header shows the wordmark "nikxel" on the left (Instrument Sans 700). On the right are the theme toggle (moon/sun icon button), the name, and a Log out button styled like lafda's "Sign in" pill. The tabs become a lafda-style row of muted links with the current one in fg.
- Modify: `cloud/dashboard/src/ui.jsx`, `screens/Day.jsx`, `Mine.jsx`, `Team.jsx`, `People.jsx`, `Connect.jsx`, `Login.jsx`, `Onboarding.jsx`. Restyle only; no behaviour changes. Day cards follow lafda's embedded-tweet card: border, rounded-xl, card bg, a meta line in muted with `·`. Section headings are Instrument Sans 600. Type chips become lafda gray pills with a small colored dot. The project shows as a second gray pill.
- Test: `cloud/dashboard/src/api.test.js` (add a `theme` test: `nextTheme('dark') === 'light'`, `nextTheme('light') === 'dark'`, exported from `api.js`)

Load the `frontend-design` skill first. Compare against the screenshot `/private/tmp/claude-501/-Users-nikhildhanda-Desktop-everything-projects-nikxel/a9f00cd7-52a0-40d5-ab85-0193621c6237/scratchpad/lafda/top.png` and the CSS in that folder.

- [ ] **Step 1: Write the failing test** `nextTheme`.
- [ ] **Step 2: Run** `cd cloud/dashboard && npm test`. Expect FAIL.
- [ ] **Step 3: Implement** the restyle.
- [ ] **Step 4: Run** `npm test && npm run build`. Then take headless-Chrome screenshots of My days and Team in light and dark, at 1300px and 375px wide, against the running dev server (the controller gives the URL). Check them against lafda: fonts, grays, card style, no horizontal scroll at 375px.
- [ ] **Step 5: Commit** `feat(dashboard): lafda look — Instrument/Public Sans, neutral cards, theme toggle`.

### Task 4: Dashboard: admin charts on Team, and the Projects view

**Files:**
- Create: `cloud/dashboard/src/stats.js`, pure aggregation with no React, unit-tested:
  - `byPersonDay(rows, days) -> [{name, date, minutes, byType:{type:min}}]`
  - `byProject(rows) -> [{project, minutes, people:[{name, minutes}], meetings, tasks, lastDate, items:[{date, name, ...item}]}]`, sorted by minutes descending. `""` becomes `"No project"`, which sorts last.
  - `typeTotals(rows) -> [{type, minutes}]`
- Create: `cloud/dashboard/src/screens/Charts.jsx`, three inline-SVG charts:
  - **Hours per person over the last 14 days:** a grouped or small-multiple bar chart, stacked by type.
  - **Time by project:** horizontal bars.
  - **Time by type:** horizontal bars.
  - Every chart has `role="img"`, an `aria-label` summary, and an empty state ("No days sent yet") when there's no data.
- Create: `cloud/dashboard/src/screens/Projects.jsx`.
  - The list: one lafda card per project with its name, total time, people as name pills, meeting count, ERP task count and last active date.
  - Clicking a project opens its detail (hash route `#projects/<encoded name>`):
    - a per-person summary (time and number of items)
    - the ERP tasks list with stage and deadline, newest first
    - meetings
    - the work items grouped by date, newest first, with expandable details.
- Modify: `Team.jsx`, which renders `<Charts rows={rows} />` above the existing person/date filters and day cards.
- Modify: `App.jsx`, adding a `Projects` tab for owner/admin only.
- Test: `cloud/dashboard/src/stats.test.js`

Load the `dataviz` skill before writing the charts.

- [ ] **Step 1: Write failing tests in `stats.test.js`.** Use 3 rows: two people, two dates, projects `"Produce POS"`, `"Nikxel"` and `""`, with one `erp tasks` item and one meeting. Assert:
  - `byProject` order is `["Produce POS","Nikxel","No project"]` (by minutes), with correct minutes, people minutes, `meetings` and `tasks` counts.
  - `byPersonDay` sums minutes per person per date with a `byType` breakdown.
  - `typeTotals` sums correctly.
  - `byProject([])` is `[]`, and `byPersonDay([], 14)` is `[]`.
- [ ] **Step 2: Run** `cd cloud/dashboard && npm test`. Expect FAIL.
- [ ] **Step 3: Implement** `stats.js`, then the charts and the Projects screens.
- [ ] **Step 4: Run** `npm test && npm run build`. Take headless-Chrome screenshots of Team (charts plus days) and Projects (list plus one detail), signed in as an admin against the seeded dev server, in light and dark, at 1300px and 375px wide.
- [ ] **Step 5: Commit** `feat(dashboard): admin charts and project-wise view`.
