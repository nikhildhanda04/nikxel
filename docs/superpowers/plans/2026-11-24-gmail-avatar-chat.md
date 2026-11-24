# Gmail in the Avatar Chat Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The avatar chat reads the user's Gmail, answers about it, searches it, drafts/sends mail and archives/marks/stars.

**Architecture:** One more scope on the shared Google sign-in. A small Gmail REST client per platform. Pure intent/parse/MIME logic in its own file per platform (checked by a script). The chat adds a `### mail` block at open and, for mail-looking messages, asks a router prompt for one JSON action.

**Tech Stack:** Swift (src/, swiftc via build.sh), TypeScript/Electron (windows/), Gmail REST v1.

**Spec:** docs/superpowers/specs/2026-11-24-gmail-avatar-chat-design.md

## Global Constraints

- Scope: `https://www.googleapis.com/auth/gmail.modify`; label "Read, draft and organise your mail (avatar chat)".
- Nothing mail-related written to disk; nothing sent to CloudSync.
- Sending only via `isSendCommand(text)` matched in code, for the draft made earlier in the same chat.
- Every src/ change mirrored in windows/, same commit.
- Commit trailer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`; never stage private/.

## Review Focus

- "send it" with no draft in this chat → "There's no draft from this chat to send." and nothing is sent.
- Router reply that isn't valid JSON (prose, fenced JSON) → fenced JSON is parsed; prose falls back to a normal answer.
- Google connected without the mail scope → mail questions answer "Reconnect Google from the Nikxel menu to give me your mail." instead of a 403.
- Non-ASCII subject/body (₹, Hindi, emoji) → subject RFC 2047 encoded, body UTF-8; check decodes it back.
- Label action naming ids not in this chat's snapshot/search → ignored, not passed to Gmail.

---

### Task 1: Mail intent logic (both platforms) + check

**Files:**
- Create: `src/MailIntent.swift` (Foundation only), `windows/src/main/google/mailIntent.ts` (no Electron imports)
- Test: `checks/check_mail_intent.swift`, `windows/scripts/check-mail-intent.js`

**Interfaces — Produces (same names both platforms):**
- `MailIntent.looksLikeMail(_ text) -> Bool` — word match: mail, email, e-mail, inbox, gmail, reply, draft, archive, unread, starred?, cc, subject, "send it".
- `MailIntent.isSendCommand(_ text) -> Bool` — whole message is e.g. "send it", "ok send", "yes send it now", "send the draft".
- `MailIntent.routerPrompt(request:context:history:today:) -> String`
- `enum MailAction { answer, search(query), draft(MailDraft), label(ids:[String], op: archive|read|unread|star) }`; `struct MailDraft { to, cc, subject, body, replyTo: String? }` (replyTo = message id).
- `MailIntent.parseAction(_ reply) -> MailAction` — strips ``` fences, first `{…}`; anything unparsable → `.answer`.
- `MailIntent.rawMessage(draft, inReplyTo: String?, references: String?) -> String` — RFC 2822, `Content-Type: text/plain; charset=UTF-8`, `Content-Transfer-Encoding: base64`, subject `=?UTF-8?B?…?=` when non-ASCII; returned base64url.

- [ ] Write checks asserting: looksLikeMail("any mail from Piyush?") true, ("what did I do today") false; isSendCommand("send it")/("Ok, send it now.") true, ("send Piyush the invoice") false; parseAction of fenced `{"action":"search","query":"from:piyush"}` → search; of "Sure!" → answer; of draft JSON → fields; rawMessage with subject "₹ invoice" decodes to a header containing `=?UTF-8?B?` and body round-trips.
- [ ] Run, see fail; implement; run, see pass:
  `swiftc src/MailIntent.swift checks/check_mail_intent.swift -o /tmp/cmi && /tmp/cmi` → `ALL PASS`;
  `cd windows && npm run build && node scripts/check-mail-intent.js` → `ALL PASS`.

### Task 2: Gmail client + scope

**Files:** Create `src/Gmail.swift`, `windows/src/main/google/gmail.ts`; modify `src/GoogleAuth.swift` and `windows/src/main/google/googleAuth.ts` (scopes, scopeLabel).

**Interfaces — Produces:**
- `Gmail.scope` constant; `Gmail.isReady` = authorized && hasScope(scope).
- `struct MailMessage { id, threadId, from, to, subject, date, snippet, body, messageId (RFC Message-ID header), references }`
- `Gmail.inbox() -> [MailMessage]` — `in:inbox is:unread` (≤20) + `in:inbox` (≤30), deduped, metadata format.
- `Gmail.search(_ q) -> [MailMessage]` — ≤8, full format, text/plain body (fallback stripped HTML), cut at first `On … wrote:` line, ≤3000 chars.
- `Gmail.message(id) -> MailMessage?` (metadata, for reply headers).
- `Gmail.createDraft(_ draft: MailDraft, replyTo: MailMessage?) -> (draftId, messageId)?`
- `Gmail.sendDraft(_ id) -> Bool`, `Gmail.modify(ids, op) -> Bool`.
- `MailIntent.contextBlock(unread:[MailMessage], recent:[MailMessage]) -> String` lines `- [id] from · subject · date: snippet` under `### mail`.
- Swift calls are synchronous (chat runs them off-main, like ERP); TS ones async.

- [ ] Implement; `./build.sh` succeeds; `cd windows && npm run typecheck` clean.
- [ ] Live check on the owner's account after reconnecting: inbox() returns messages.

### Task 3: Wire into the avatar chat

**Files:** Modify `src/AvatarChat.swift`, `windows/src/main/system/avatarChat.ts`.

- At open (same background read as WhatsApp): `mailSnapshot` = contextBlock when `Gmail.isReady`, plus the ids it shows into `knownIds`.
- In send handler, before the ERP check:
  1. `isSendCommand` → send `lastDraftId` or reply "There's no draft from this chat to send."; on success "Sent." and clear it.
  2. `looksLikeMail` and Google authorized but not `isReady` → "Reconnect Google from the Nikxel menu to give me your mail."
  3. `looksLikeMail` and ready → router (haiku, 30 s) → action:
     - search → results added (ids to knownIds) under `### mail search: <q>`, then the normal prompt.
     - draft → createDraft (replyTo resolved via `Gmail.message`), open `https://mail.google.com/mail/u/0/#drafts?compose=<messageId>`, keep `lastDraftId`, reply "Draft to <to> — “<subject>”. Opened in Gmail; say “send it” to send."
     - label → ids ∩ knownIds; modify; reply "Archived 3." / "Marked 2 read." / "Starred 1."; none known → "I couldn't tell which emails you meant."
     - answer → normal prompt.
- [ ] Build both; open chat, ask "what's unread in my mail", "draft a reply to …", "send it" on the owner's account.
- [ ] Commit all three tasks' files together, push.
