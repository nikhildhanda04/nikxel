# Minimal dashboard: Invite · My summaries · Projects · People · Connect

## Why
The dashboard got cluttered. It pulled every ERP employee and project, and it had a team page, charts and an org editor. The user wants something a new person can open and understand right away. That means five tabs with no clutter. Projects become something people create themselves. They are not imported.

## Goals
- **Invite.** Copy an invite link and send it. The person who opens it signs in with Google and joins the org. They're then told to install Nikxel (download link) if they don't have it, or to connect it if they do.
- **My summaries.** The logged-in user's own sent days, newest first, using the existing day view. Only their own.
- **Projects.** Any member can create a project (name plus an optional one-line description) and add org members to it. A project page shows what's being done and the latest meeting summaries. It's built from:
  - day items that members Sent tagged to the project;
  - meeting summaries shared to it in one click from the desktop app.
  Everyone in the org can read every project, so HR or a co-founder who isn't on the project can still follow it.
- **People.** Lists every member with their role. Admins change roles and remove people.
- **Connect.** Unchanged: a pairing code for the desktop app.

## Non-goals and anti-goals
- No ERP import of people or projects into the dashboard. These are removed:
  - the "Build org from ERP…" menu item;
  - `/api/org*` and `/api/teams`;
  - the `org_people`, `org_projects` and old `project_members` tables.
  The ERP still feeds the personal "erp tasks" section of the daily summary on the device. That section is unchanged.
- No team page, no rollup, no charts.
- **Anti-goal:** a busy screen. Each tab has one job. No stat strips and no filters unless a list is long enough to need one.
- The data boundary is unchanged:
  - raw activity, logs, the twin and full summaries never leave the device;
  - only items the user Sends leave;
  - only the minutes text of a meeting the user explicitly shares leaves, never its transcript or audio.

## Approaches considered
- **A (chosen):** projects are owned by the dashboard. The app downloads the user's project names and tags the 10pm summary against them. Sent items flow onto project pages automatically. Meeting minutes pages get a "Share to project" button. This is the only option that delivers tracking without extra work.
- **B:** projects are a manual post board. Rejected: tracking would depend on people remembering to post.
- **C:** A plus seeding from the ERP project list. Deferred: it brings ERP clutter back.

## Decided
- **Roles: owner, co-founder, admin, member.**
  - Co-founder has the same powers as admin; the label is different.
  - Owner, co-founder and admin can change roles and remove people.
  - Only the owner can make or remove co-founders.
  - The existing rule stays: only admins and above can make admins.
  - Nobody can change the owner's role or remove the owner.
- **Projects: any member creates one.**
  - The creator is added as a member automatically.
  - Project members, admins, co-founders and the owner can do the following. Everyone else in the org can only read.
    - rename and edit the description;
    - add and remove members;
    - archive. An archived project is hidden from the list and from tagging, but its page still opens.
- **Tagging:**
  - The app fetches `GET /api/device/projects`: the non-archived projects the paired user is a member of. It fetches before the 10pm summary, and the dashboard-project list replaces the ERP project list in the summary prompt.
  - Items keep the `[[Project]]` tag format.
  - On `POST /api/summaries` the server resolves each item's project name (case-insensitive) against the user's projects. It stores the project id on the item, so a rename doesn't break the link. Unknown names are kept as text and stay unlinked.
- **Project page:**
  - One feed, newest day first.
  - Each day shows meeting summaries shared that day, then members' sent work and meeting items for the project, with the person's name on each.
  - A small Work / Meetings switch is the only control.
  - The member list sits in the header.
  - Items from users who are no longer project members still show. History stays.
- **Meeting share:**
  - The minutes page that the app's local page server serves gets a "Share to project" button. It opens a dialog listing the user's projects, plus a preview of exactly the text that will be sent.
  - The app sends it with its device token via `POST /api/projects/:id/meetings` `{meeting_id, title, date, body}`.
  - Re-sharing the same meeting to the same project replaces the earlier share.
  - Nothing can be removed on the dashboard, the same rule as days.
- **Invites:**
  - Any member can copy a member invite. Only admins and above can choose admin or co-founder.
  - The invite landing page leads into a two-step onboarding: Install Nikxel (link from `NIKXEL_DOWNLOAD_URL`, macOS and Windows), then Connect.
- **Visibility:** a user's full sent day is visible only to that user, under My summaries. Others see a person's items only through the projects those items are tagged to. Items with no project are effectively private to their sender. (This changes things: admins previously saw everyone's days on the Team page.)
- **Platforms:** every desktop change goes into both `src/` (Swift) and `windows/` (TS) in the same commit.
- **Look:** keep the existing lafda styling, tokens and components. Remove unused screens:
  - Team, Charts, Pie, Line, Org, OrgSummary, TeamGrid, TeamDrawer, PeopleTable, Projects;
  - plus `stats.js` and `orgView.js` if nothing else uses them.

## Calls made after the builder check
- **Project names are unique per org, case-insensitive, and archived projects count too.** Creating or renaming to a taken name returns 409. Tag resolution is never ambiguous.
- **Meetings switch:** "Meetings" shows the shared minutes plus members' sent items from the day's "meetings" section tagged to the project. "Work" shows everything else.
- **Meeting id:** the minutes file's timestamp stem, which already exists on both platforms (`MOMGenerator.swift` / `momGenerator.ts`, with the page in `NotePage.swift` / `notePage.ts`). Windows gets the Share button too.
- **Project list fetch:** the app caches the last good `GET /api/device/projects` result and falls back to it. With no cache, there's no tagging; the summary is never blocked.
- **Old days:** no backfill. Old ERP-named tags stay as unlinked text.
- **Invites:**
  - The existing single-use token, with the role stored on it.
  - Inviting as admin or co-founder follows the role rules above.
  - A user who is already in the org skips onboarding and lands on My summaries.
- **Owner:** today's org creator, who already has the `owner` membership role. `co-founder` is a new role value.

## Left to the builder
- Exact layout of each tab, within "one job per tab, no clutter".
- Migrating the existing dev SQLite data. Dropping the old org tables is fine, since it's dev data only.
- Ordering against the pending Postgres plan: this redesign lands first, and the Postgres plan is rewritten afterwards for the smaller schema.
