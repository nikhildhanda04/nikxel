# Gmail in the avatar chat — design

## Why
The user wants to ask Nikxel about their inbox and have it write mail for them, from
the same avatar chat that already reads WhatsApp and creates ERP tasks.

## Goals
- Answer questions about the inbox: what's unread, who's waiting, what someone sent.
- Find older mail on request ("what did Piyush send about the invoice last month").
- Write mail: new mail, replies in the right thread, follow-ups — as Gmail drafts.
- Send a draft when the user says "send it" about the draft just made in this chat.
- Tidy: archive, mark read, star.
- Same on Mac (Swift) and Windows (Electron), same commit.

## Non-goals
- No local copy of the mailbox; nothing mail-related is written to disk.
- Mail is never sent to the cloud dashboard.
- No multi-step agent loop (option C); one decision per message.
- No permanent delete.

## Anti-goals
- Mail going out that the user never saw. Sending is never the model's choice: only an
  explicit "send it" in the same chat, for the draft that chat just made.

## Approaches
- **A (picked): read at chat open + actions.** Inbox snapshot in the chat context like
  WhatsApp; a Gmail search for older mail; drafts/labels through the Gmail API. Matches
  the existing WhatsApp/ERP chat pattern, no storage, smallest change.
- B: full local mirror. Fast offline search, but the whole mailbox on disk and much more code.
- C: tool-using agent. Most capable, but rebuilds the one-prompt chat and is slower.

## Design
- **Permission:** add `https://www.googleapis.com/auth/gmail.modify` to the one shared
  Google sign-in (`GoogleAuth.scopes`, both platforms) with a scope label. Existing users
  get the existing "reconnect" path once. Until the OAuth app passes Google's verification
  (restricted scope, CASA), only test users added in the Google console can connect.
- **Gmail client** (`src/Gmail.swift`, `windows/src/main/google/gmail.ts`), REST over the
  shared access token:
  - `inbox()`: unread in INBOX + latest ~30 INBOX messages — id, threadId, from, subject,
    date, snippet.
  - `search(q)`: up to ~8 messages for a Gmail query, with plain-text bodies (capped).
  - `createDraft(to, cc, subject, body, threadId?)` → draft id; replies set
    In-Reply-To/References and threadId.
  - `sendDraft(id)`, `modify(ids, add, remove)` for archive/read/star.
- **Chat context:** at chat open, a `### mail` block (like `### whatsapp`) with the
  snapshot, each line carrying its message id. If mail isn't connected or the scope is
  missing, the block is absent; mail questions get "Reconnect Google from the Nikxel menu".
- **Per message:** if it looks mail-related (word match: mail, email, inbox, gmail, reply,
  draft, archive, …), a small router prompt returns one JSON action:
  - `answer` → the normal chat prompt.
  - `search {query}` → run it, add results to the context, then the normal prompt.
  - `draft {to, cc, subject, body, replyTo?}` → create the draft, open it in Gmail, reply
    "Draft to X — 'subject'. Opened in Gmail; say 'send it' to send."
  - `label {ids, archive|read|star}` → do it, say what was done.
  - "send it" / "send" is matched in code, not by the model: sends the chat's last draft;
    with no draft in this chat it says there's nothing to send.

## Left to the builder
Exact caps, the router prompt wording, the mail-word list, how bodies are trimmed of
quoted history.
