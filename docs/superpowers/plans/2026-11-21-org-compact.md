# Org tab: compact team grid + edit drawer + people table — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** See and edit the whole org without long scrolling. Teams appear as a dense grid of small cards. Clicking a card opens a side drawer for editing. People become a compact table on their own sub-tab.

**Architecture:** This is dashboard-only (`cloud/dashboard`), with no server or desktop changes.
- `Org.jsx` gains a sub-tab switch (Teams | People) and a summary strip.
- Teams render as a responsive card grid (`TeamGrid.jsx`). Clicking a card opens `TeamDrawer.jsx`, which holds today's team editing controls moved out of the inline cards.
- People render as `PeopleTable.jsx`.
- New pure helpers in `orgView.js` are unit-tested.
- The existing mutation helper `run` (refresh from `GET /api/org` after each change, errors shown inline) is reused unchanged.

**Tech Stack:** React 18 + Vite + Tailwind 4, the lafda look (`src/index.css` tokens, `src/ui.jsx` components).

**Spec:** the user's request of 2026-11-21: "plan out a better way to show the org, right now it's very linear and I have to scroll so much". They chose the **compact grid of cards** option:
- small cards, 3 to a row, each showing the team name, lead, member avatars and a count;
- clicking a card opens a side drawer to edit;
- people become a slim table with filters.

Real data at the time: 25 people (4 joined) and 90 projects (66 active).

## Global Constraints

- **The page breaks out of the 640px column the way the Team page does:** up to 1200px wide at ≥1280px. The header and tabs stay as they are.
- **Grid columns:** 3 at ≥1024px, 2 at ≥640px, 1 below that. No horizontal page scroll at 375px.
- **A team card is about 96px tall at most.** It shows:
  - the name on one line, truncated, with the full name in a `title`;
  - the lead line: `★ <first lead>` plus `+n` when there's more than one, or `— no lead` in muted text;
  - up to 4 member initials circles plus `+k`;
  - the member count on the right;
  - an `inactive in ERP` tag (and a dimmed card) for inactive teams, and `archived` for archived ones.
  - The card is a `<button>` with an `aria-label` like `"A to Z Wholesaler — 4 members, lead Shivay Sharan"`.
- **The drawer** is on the right, 440px wide (a full-screen sheet below 640px).
  - It uses `role="dialog"` with `aria-modal` and `aria-labelledby`, and closes on Esc or a backdrop click.
  - Focus moves into it when it opens and returns to the card when it closes.
  - It contains the description and today's controls: members with a lead toggle and remove, Add person, Rename, Archive/Unarchive. Behaviour is the same as now.
  - The open team is kept in the hash as `#org/team/<id>`, so a reload or a shared link reopens it. An unknown id just shows the grid.
- **The summary strip** sits above the sub-tabs as one muted line: `66 active teams · 12 without a lead · 25 people · 4 joined`. "12 without a lead" is a button that applies the No-lead filter.
- **The Teams toolbar** has search, the status chips (Active / Inactive / Archived / All, same meaning as today), a "No lead" toggle chip, and sort (Size | Name, size meaning member count descending).
- **The People table** has columns Name (with title under it), Email, Teams, Status.
  - **Teams column:** up to 2 team pills plus `+n`, from `teamsOfPerson`.
  - **Status column:** a `joined` tag, or the Invite button plus the Link-to-user select.
  - It keeps today's search and the All / Joined / Not joined filter, and shows every row (no 12-row cap) with no pagination below 200 rows.
  - Below 640px each row becomes two lines, and nothing scrolls sideways.
- The lafda look stays. New npm dependencies: none.

## Review Focus

- **A team with 0 members, or a lead who has been removed:** the card shows `— no lead`, 0 avatars and a count of 0, with no crash.
- **A 60-character team name, or a person in 15 teams:** the card truncates the name, and the table shows 2 pills plus `+13` with no overflow at 375px.
- **A mutation inside the drawer fails:** the error shows inside the drawer and the drawer stays open.
- **The hash points at an archived team while the Active filter is on:** the drawer still opens for it.
- **A keyboard-only user:** Tab reaches the cards, Enter opens the drawer, Esc closes it, and focus returns to the same card.

---

### Task 1: Pure helpers and the Teams view (grid, drawer, summary, toolbar)

**Files:**
- Modify: `cloud/dashboard/src/orgView.js`. Add:
  - `initials(name) -> string`: one or two uppercase letters; `"Shivay Sharan"` gives `"SS"`, `"Aarib"` gives `"A"`, and `""` gives `"?"`.
  - `teamSummary(project) -> {id, name, leads:[name], members:[{person_id,name}], count, active, archived}`, excluding removed members.
  - `orgStats(org) -> {activeTeams, noLead, people, joined}`, where `noLead` counts active, non-archived teams with no non-removed lead.
  - `sortTeams(cards, by)` with `by` either `'size'` (count descending, then name) or `'name'`.
  - Extend `teamCards(projects, which, {noLead})` so it can filter to teams without a lead.
- Create: `cloud/dashboard/src/screens/TeamGrid.jsx` (the cards), `TeamDrawer.jsx` (the editor, holding the controls moved from today's `Org.jsx` team cards) and `OrgSummary.jsx`.
- Modify: `cloud/dashboard/src/screens/Org.jsx`. Add the sub-tabs (Teams | People, Teams by default, remembered in the hash: `#org` for Teams, `#org/people` for People), the summary strip, the toolbar, the grid, and the drawer driven by `#org/team/<id>`. `App.jsx`'s route matching must accept `org/...`.
- Test: `cloud/dashboard/src/org.test.js` (extend)

- [ ] **Step 1: Write failing tests**
  - `initials` covers the three cases above.
  - `teamSummary`:
    - drops removed members;
    - lists leads first, and the count excludes removed members.
  - `orgStats` on a fixture with 3 active teams (one without a lead, one whose only lead is removed), 1 archived and 1 inactive gives `{activeTeams: 3, noLead: 2, ...}`, plus correct `people` and `joined` counts.
  - `sortTeams`:
    - `'size'` puts the 6-member team before the 2-member team, and breaks ties by name;
    - `'name'` sorts alphabetically, ignoring case.
  - `teamCards(..., 'active', {noLead: true})` returns only active teams with no lead.
- [ ] **Step 2: Run** `cd cloud/dashboard && npm test`. Expect FAIL.
- [ ] **Step 3: Implement** the helpers and the Teams view as described in Global Constraints. Load the `frontend-design` skill first.
- [ ] **Step 4: Run** `npm test && npm run build`. Then take headless-Chrome screenshots of `#org` as dev-jake, against the controller's dev server (http://localhost:5191, real imported data: 25 people, 66 active teams):
  - the grid at 1440px, 1024px and 375px, in light and dark;
  - an open drawer at 1440px and 375px.
  Check:
  - 3, 2 and 1 columns respectively;
  - no horizontal scroll;
  - at least 15 cards visible above the fold at 1440×900;
  - keyboard: Tab to a card, Enter opens the drawer, Esc closes it, and focus returns to the card.
- [ ] **Step 5: Commit** `feat(dashboard): Org teams as a compact grid with an edit drawer`.

### Task 2: People table

**Files:**
- Modify: `cloud/dashboard/src/orgView.js`. Add `teamsOfPerson(projects, personId) -> [name]`, covering non-archived teams where the person is a non-removed member, with teams they lead first.
- Create: `cloud/dashboard/src/screens/PeopleTable.jsx` (the table described in Global Constraints, reusing today's Invite and Link-to-user logic moved out of `Org.jsx`).
- Modify: `cloud/dashboard/src/screens/Org.jsx`. The People sub-tab renders `PeopleTable`.
- Test: `cloud/dashboard/src/org.test.js` (extend)

- [ ] **Step 1: Write failing tests** for `teamsOfPerson`:
  - it excludes archived teams and removed memberships;
  - led teams come first;
  - a person on no teams gives `[]`.
- [ ] **Step 2: Run** `npm test`. Expect FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `npm test && npm run build`. Take screenshots of `#org/people` at 1440px and 375px, in light and dark. Check that all 25 rows are visible without a "Show all" button, that there's no horizontal scroll at 375px, and that Invite copies a link.
- [ ] **Step 5: Commit** `feat(dashboard): Org people as a compact table`.
