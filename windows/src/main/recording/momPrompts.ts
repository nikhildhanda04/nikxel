/// The shipped prompt templates, verbatim from MOMGenerator.swift. Each one
/// starts with the version tag (see MOMGenerator.promptVersion) so an
/// out-of-date copy in ~/.nikxel/prompts/ is replaced on next launch.

export function notesPrompt(versionTag: string): string {
  return versionTag + `
You are generating structured notes from the transcript of a YouTube video,
lecture, podcast, talk, or other single-source spoken content. Always produce
the Markdown below — never refuse or output a "not enough content" message.

{{language_instruction}}
Section headings (Summary, Key Points, etc.) stay in English regardless, so
the structure is always scannable — only the content inside each section
follows the language rule above.

Recorded: {{date}}
Duration: {{duration}}

{{custom_instructions}}
Output this exact Markdown structure (keep section headings in English):

# Notes — {{date}}

## Summary
**One sentence, under 25 words: what this is about and its main takeaway.**

2-3 sentences expanding on that: the main thrust and how it develops.

## Key Points
- The substantive ideas, claims, arguments, facts, or topics covered.
- Be specific. Quote numbers, names, examples, and concrete claims where they appear.
- Cover the full arc of the content, not just the opening.

## Notable Quotes / Examples
- Direct quotes, vivid examples, or stories the speaker used to make a point.
- If none stand out, write "- None." — don't skip the section.

## Open Questions
- Unresolved questions, things to look up, or topics flagged for later.
- If none, write "- None." — don't skip the section.

Rules:
- Never invent claims, numbers, or quotes not in the transcript.
- If the transcript is short or sparse, still produce all four sections —
  scale the content to the source.
- Output ONLY the Markdown — no preamble, no closing remarks, no commentary.

---
TRANSCRIPT:
{{transcript}}`;
}

export function meetingPrompt(versionTag: string): string {
  return versionTag + `
You are generating Minutes of Meeting (MOM) from a transcript of a meeting,
call, or 1:1 conversation.

## How to read this transcript

Every line is "[timestamp] Channel: text". There are only two channels, and
they are AUDIO CHANNELS, NOT PEOPLE:

  "Me"     = the microphone. Exactly one person: {{user_name}}, who recorded
             this meeting.
  "Others" = the speaker output. EVERYONE ELSE on the call, mixed together.
             This may be one person or six. The label never changes even when
             the person talking does.

Your first job is to work out how many distinct people are hiding behind
"Others", and which lines belong to which of them.

### Separating the people inside "Others"

Use the evidence actually present in the transcript:
- Self-introductions ("Hi, this is Priya", "Rohan here").
- Direct address and handoffs ("Sam, what do you think?", "over to you, Ann")
  — the lines that follow usually belong to the person just addressed.
- Someone answering a question that was clearly put to a specific person.
- Continuity of role and topic: whoever owns the design discussion through the
  call is one person; whoever keeps answering budget questions is another.
- Timestamp gaps between consecutive "Others" lines. A noticeable pause often
  marks a turn change; continuous back-to-back lines usually do not.
- Shifts in how someone speaks: a different register, filler words, or
  language mix is a real signal.

### Speaker rules (these matter — getting them wrong is worse than being vague)

- Give every distinct person ONE stable label and use it everywhere in the
  output. Use a real name only when the transcript gives you evidence for it.
  Otherwise use "Speaker 2", "Speaker 3", … numbered by when they first speak
  ("Me" is effectively speaker 1).
- Never collapse two different people into one label. If two people clearly
  spoke, list two speakers — even if one of them has no name.
- Never split one person into two just because they paused or changed topic.
- A name MENTIONED in the meeting is not automatically a SPEAKER. People get
  talked about while absent. Only treat a name as a speaker when someone
  addresses them and they respond, or they introduce themselves.
- When you genuinely cannot separate them, say so plainly: list
  "Others — multiple participants, could not be separated reliably" and
  attribute those lines to "Others". An honest "Others" beats a confident
  wrong name.

### Who "Me" is

"Me" is exactly one person: {{user_name}}. Never reassign "Me"'s lines to
anyone else, never describe "Me" as if they were another participant, and
never attribute something "Others" said to "Me" just because the topic
involves them. If {{user_name}} is literally "Me", then no name was
configured — refer to that person as "Me" throughout and do NOT invent or
guess a name for them.

Always produce the Markdown below — never refuse, never output a "not a real
meeting" message, and never claim "no credible conversation occurred" or any
similar bail-out. If the transcript has any speech at all, treat it as a real
meeting and fill in every section from what was said. A short, casual, or
non-English meeting is still a meeting.

{{language_instruction}}
Section headings stay in English regardless, so the structure is always
scannable — only the content inside each section follows the language rule
above.

Recorded: {{date}}
Duration: {{duration}}

{{custom_instructions}}
Output this exact Markdown structure (keep section headings in English):

# Meeting — {{date}}

## Summary
**One sentence, under 25 words: what the meeting was about and where it landed.**

Then 3-5 sentences: the main threads of discussion, what was agreed, and what
is still open. Someone who missed the call should be able to read only this
section and know what happened. Keep it a short paragraph, not a transcript
recap.

## Speakers
- **{{user_name}} (Me)** — role/context if the transcript shows it.
- One line per distinct person you identified in "Others": the bold label you
  will use for them below, then the evidence you used ("introduced themselves",
  "addressed as Priya", "answered all the pricing questions").

## Per-Speaker Highlights
One block per person: their label in bold on its own line, then 2-5 short
bullets (one point each, one line where possible) on what they contributed,
asked, proposed, pushed back on, or committed to. Use the exact labels from
the Speakers list.

**{{user_name}} (Me)**
- …

**<next speaker>**
- …

## Decisions
- The actual decisions reached — what was decided, and by whom if the
  transcript shows it. Only things genuinely settled during the call, not
  options that were merely discussed. If none, write "- None."

## Blockers & Risks
- Anything stopping work: dependencies, missing approvals, people waiting on
  each other, technical obstacles, deadline or resource risks raised.
- Note who is blocked and on what. If none, write "- None."

## Open Questions
- Questions raised and left unanswered, and points parked for later.
- If none, write "- None."

## Action Items
This is the section people open the note for. Be thorough and be specific.
- Format every task as: \`- [ ] **Task** — Owner: <name or Unassigned> — Due: <YYYY-MM-DD or Not specified>\`
- Due dates must be written as YYYY-MM-DD. If a day was named without a date
  ("by Friday", "end of next week"), work out the actual date from the
  "Recorded" date above and write that. If no deadline was mentioned at all,
  write "Not specified" — never guess one.
- Write each task as a complete, self-contained instruction. "Send Priya the
  updated pricing sheet" — not "pricing sheet". Someone should be able to act
  on the bullet without reading the rest of the note.
- Include tasks that were assigned AND tasks someone took on themselves
  ("I'll check with finance" is a task owned by that speaker).
- Include things the meeting clearly implied need doing, but only when the
  transcript supports them.
- Owner is the speaker label from the Speakers section. If nobody picked it
  up, write "Unassigned".
- Scan the entire transcript for these, including the last few minutes —
  tasks cluster at the end of calls.
- If there are genuinely none, write "- [ ] None — no tasks came out of this
  meeting."

## Follow-Up Meetings
Only meetings the call actually agreed to schedule — "let's do a design review
Thursday at 3", "same time next week", "I'll set up a call with legal".
- Format each as: \`- **Title** — When: <YYYY-MM-DD HH:MM or Not specified> — Duration: <N> min — With: <names or Not specified>\`
- When must be a real date and a real 24-hour time, worked out from the
  "Recorded" date above. A meeting agreed for "Thursday afternoon" with no
  time given is \`Not specified\` — do NOT pick a plausible hour. A calendar
  entry at an invented time is worse than no entry.
- Duration: use what was said; if nothing was said, write 30 min.
- Do not list meetings that already happened, recurring meetings that already
  exist, or vague intentions ("we should sync more often").
- If none, write "- None."

## Agent Prompts
Ready-to-paste prompts for the Action Items that are software work, so a task
can go straight into a coding agent without being rewritten by hand.

Which tasks get one:
- Include anything that lands as a code, config, schema, infrastructure, test,
  or documentation change in a repository.
- Skip everything else — calls, approvals, chasing people, scheduling,
  purchasing, decisions still to be made. Forcing those into a prompt produces
  something nobody can run. Most meetings yield only one or two codeable tasks,
  and sometimes none.
- If none qualify, write "- None — no code changes came out of this meeting."
  and nothing else in this section.

Format each one as a heading followed by a fenced code block, so it can be
copied in one go:

### <short task name> — <Owner>
\`\`\`
<prompt text>
\`\`\`

What goes inside each fenced block, as flowing prose and bullets — not as
these labels:
1. One opening sentence stating the goal in the imperative ("Add retry
   handling to the webhook consumer so transient 5xx responses don't drop
   events.").
2. The background the agent needs, drawn from the meeting: the problem being
   solved, why it came up, constraints that were stated, the deadline, and who
   wanted it. Someone who wasn't on the call should understand the task from
   this alone.
3. The specific changes required, as bullets — behaviour to add or alter,
   edge cases raised, error handling, anything explicitly ruled in or out
   during the discussion.
4. How to tell it's done: the acceptance criteria, and what to verify or test.
5. Whatever the meeting left unspecified, listed plainly as open points the
   agent should ask about before it starts.

Rules for these prompts, which matter more than the formatting:
- NEVER invent file paths, function names, module names, table names, API
  endpoints, library names, or version numbers. Use only identifiers that were
  actually said out loud. Where the meeting referred to something vaguely ("the
  payments service", "that cron job"), keep the vague wording and add it to the
  open points so the agent asks instead of guessing.
- Do not guess at the repository's structure, language, or framework. The
  agent will be run inside the repo and can look for itself.
- Keep every requirement traceable to something in the transcript. A prompt
  that smuggles in your own design opinions will send the agent off building
  the wrong thing.
- Write the prompt so it reads correctly on its own, without the rest of this
  document. It will be pasted somewhere else, with no surrounding context.
- Length follows the task: a one-line config change needs a short prompt, a
  migration discussed for twenty minutes needs a thorough one.

Rules:
- Never invent attendees, decisions, owners, blockers, or commitments that
  aren't in the transcript.
- Keep speaker labels identical across every section.
- Output ONLY the Markdown — no preamble, no closing remarks, no commentary.

---
TRANSCRIPT (labeled by audio channel, not by person):
{{transcript}}`;
}
