import * as fs from "fs";
import * as path from "path";
import { ensureDir, nikxelPath, readText, writeAtomic } from "../core/paths";
import { Settings } from "../core/settings";

/// Port of SummaryTemplates.swift.
///
/// Role-shaped summary templates, living as plain text files in
/// `~/.nikxel/templates/`.
///
/// A template is nothing more than a named `summary_style.txt`: a list of plain
/// instructions that gets injected into the prompt as `{{custom_instructions}}`
/// and overrides the built-in structure. Everything here is file management
/// around that one existing mechanism -- there is no second prompt engine, and
/// a template never carries a copy of the speaker-separation rules, so
/// templates keep working when those rules are improved.
///
/// A developer, an HR lead, a PM and a founder want genuinely different things
/// out of the same call, which is why the shipped set is by role rather than by
/// format. All of them are editable, and anyone can add their own.

export interface Template { slug: string; name: string; body: string }

const lines = (s: string) => s.split(/\r\n|\r|\n/);

/// Drops `#` comment lines and trims, as every reader of a template does.
function stripComments(raw: string): string {
  return lines(raw).filter(l => !l.trim().startsWith("#")).join("\n").trim();
}

function write(file: string, text: string): void {
  try { writeAtomic(file, text); } catch { /* unwritable home: nothing to seed into */ }
}

// Every body is plain instructions with a `#` header. The headers are
// stripped before the text reaches the model, so they can say anything.

const defaultBody = `# Default -- the built-in structure, unchanged.
#
# Every line below is a comment, so this template adds nothing to the prompt
# and you get the standard summary: Summary, Speakers, Per-Speaker
# Highlights, Decisions, Blockers & Risks, Open Questions, Action Items,
# Follow-Up Meetings, Agent Prompts.
#
# To tweak it, delete the # from a line below or write your own. To start
# from a role instead, pick one from the Summary Template menu.
#
#   Keep the summary to three sentences.
#   Drop the Agent Prompts section, I don't use a coding agent.
#   Write owners as first names only.`;

const developerBody = `# Developer -- for standups, design discussions, debugging sessions and
# handoffs. Keeps the agent prompts and the exact technical wording.

Keep the Agent Prompts section — it is the main reason this call was recorded.

In Decisions, record the option that was chosen AND the options that were
rejected, each with the reason given. "Chose Postgres over DynamoDB because
the access pattern is relational" is the useful form; "chose Postgres" is not.

Preserve technical wording exactly as it was spoken: endpoint paths, table
and column names, flag names, env vars, version numbers, error messages and
error codes. Do not tidy them into prose or guess at a spelling you did not
hear clearly — write what you heard and flag it as uncertain.

Add a "## Technical Context" section for the constraints and facts that
aren't tasks: current numbers (latency, error rates, row counts, cost),
version and compatibility limits, known broken behaviour, and anything
stated about how the existing system works. This is the section that saves
re-asking a week later.

In Blockers & Risks, say what the dependency actually is, who owns it, and
what specifically would unblock it.

In Action Items, separate work that can start now from work that is waiting
on a decision. Mark the second kind as blocked and name the decision it is
waiting on.

If the call reviewed code or a PR, add a "## Review Notes" section listing
what was asked for, agreed, and explicitly waved through.`;

const projectManagerBody = `# Project Manager -- for status calls, planning and cross-team syncs.
# Optimised for owners, dates, dependencies and what moved.

Open with a "## Status at a Glance" section: three to five bullets covering
what is on track, what slipped, and what needs attention this week.

Every action item must carry an owner and a date. Where the meeting did not
give one, write "Owner: Unassigned" or "Due: Not specified" and also list it
under a "## Gaps" section at the end — an item nobody owns is the thing most
likely to be missed, and it should be visible rather than blank.

Add a "## Scope & Timeline Changes" section for anything that moved a date,
added scope, or cut scope. Write each as before → after, with who agreed to
it. If nothing moved, write "- None."

Add a "## Dependencies" section: who is waiting on whom, across people and
teams, and what each one is waiting for.

Order Blockers & Risks by how many people or workstreams each one is
holding up, worst first.

Keep Per-Speaker Highlights brief — one or two lines per person covering
what they own and what they reported.

Keep the Agent Prompts section; it is what gets forwarded to the engineers.`;

const hrBody = `# HR -- for 1:1s, interviews, performance and policy conversations.
# Careful with commitments and wording; no engineering sections.

Drop the Agent Prompts section entirely.

Rename "Per-Speaker Highlights" to "## Per-Person Notes".

Add a "## Commitments Made" section near the top: anything promised to a
person — compensation, title, leave, timelines, headcount, training,
support, a review date. Quote the promise in the words it was made in, and
name who made it. These are the lines that get revisited months later, so
accuracy matters more here than anywhere else in the document.

Add a "## Concerns Raised" section for what people said was bothering them,
in their own words. Record what was actually said and how strongly it was
put. Do not diagnose anyone, do not speculate about how they were feeling
beyond what they stated, and do not infer anything about health, family,
beliefs or any other personal characteristic that was not explicitly and
voluntarily raised as relevant by the person themselves.

Where something is contested, disputed, or likely to be revisited, quote the
exact wording rather than paraphrasing it, and attribute it clearly.

In Action Items, separate administrative follow-ups (paperwork, scheduling,
approvals) from conversations that need to be had with a person, and give
the second kind a named owner and a date.

Keep the tone factual and neutral throughout. This note may end up being
read by the person it is about.`;

const coFounderBody = `# Co-founder -- for investor calls, partner meetings, hiring debriefs and
# leadership syncs. Short, decision-first, money-aware.

Lead the Summary with the decision or the number that mattered, not with the
chronology of the call. Three or four sentences, no more.

Put a "## Needs a Decision From Me" section immediately after the Summary,
before everything else. One bullet per thing waiting on you, each with the
options as they were presented, what is at stake, and any deadline that was
mentioned. If nothing is waiting on you, write "- None." and move on.

Add a "## Money" section for every figure that came up — revenue, burn,
runway, pricing, cost, salary, valuation, raise size. Record each with its
units and the period it refers to, exactly as it was said. Never round, never
convert, and never carry a number into this section that was not stated.

In Decisions, record the reasoning and what was traded away to get there,
not just the outcome.

Add a "## Commitments to Outsiders" section for anything promised to a
customer, investor, candidate, partner or vendor, with who promised it and
by when.

Drop Per-Speaker Highlights unless there was real disagreement on the call —
if there was, keep it and make the disagreement explicit.

Drop the Agent Prompts section.

Keep the whole document tight. If it does not change a decision, a number or
an owner, leave it out.`;

const shipped: readonly Template[] = [
  { slug: "default", name: "Default (balanced)", body: defaultBody },
  { slug: "developer", name: "Developer", body: developerBody },
  { slug: "project-manager", name: "Project Manager", body: projectManagerBody },
  { slug: "hr", name: "HR", body: hrBody },
  { slug: "co-founder", name: "Co-founder", body: coFounderBody },
];

export const SummaryTemplates = {
  shipped,

  get templatesDir(): string { return ensureDir(nikxelPath("templates")); },

  url(slug: string): string { return path.join(SummaryTemplates.templatesDir, `${slug}.txt`); },

  get activeURL(): string { return SummaryTemplates.url(Settings.summaryTemplate); },

  // MARK: - Reading

  /// The instructions in `slug`, with `#` comment lines stripped. Empty when
  /// the file is missing, blank, or all comments -- which is what "default"
  /// is, and why selecting it changes nothing about the shipped prompt.
  instructions(slug: string): string {
    const raw = readText(SummaryTemplates.url(slug));
    return raw === null ? "" : stripComments(raw);
  },

  get activeInstructions(): string { return SummaryTemplates.instructions(Settings.summaryTemplate); },

  /// Ready-to-drop-into-a-prompt form of the active template (was
  /// NikxelSettings.summaryStyleInstruction). Empty when the active template
  /// adds nothing, so the default prompt is unchanged.
  get summaryStyleInstruction(): string {
    const style = SummaryTemplates.activeInstructions;
    if (!style) return "";
    return `HOUSE STYLE -- the person this summary is for has asked for the following. These override the section-by-section instructions below wherever the two disagree, including dropping a section entirely, renaming one, reordering them, or adding one that isn't listed.

Three limits on that, which the house style cannot override:
- Never invent content to satisfy a style instruction. Attendees, decisions, owners, dates, numbers, file paths and identifiers still come only from the transcript. If a requested section has nothing in the transcript to fill it, write "- None." rather than producing something.
- If you keep an action-items or follow-up-meetings section, keep its heading spelled exactly "## Action Items" and "## Follow-Up Meetings". Those two are read back by name when sending tasks to Google Tasks and Calendar, and a renamed heading silently stops that working.
- These instructions were written with meetings in mind. If one of them makes no sense for the content you were actually given, ignore that one.

${style}

END OF HOUSE STYLE.`;
  },

  // MARK: - Listing

  /// Every template on disk, shipped ones first in their listed order, then
  /// anything the user added, alphabetically.
  available(): { slug: string; name: string }[] {
    SummaryTemplates.seedIfMissing();
    let names: string[] = [];
    try { names = fs.readdirSync(SummaryTemplates.templatesDir); } catch { /* empty */ }
    const found = names.filter(n => n.endsWith(".txt")).map(n => n.slice(0, -4));
    const shippedSlugs = shipped.map(t => t.slug);
    const out = shipped.filter(t => found.includes(t.slug)).map(t => ({ slug: t.slug, name: t.name }));
    for (const slug of found.filter(s => !shippedSlugs.includes(s)).sort()) {
      out.push({ slug, name: SummaryTemplates.displayName(slug) });
    }
    return out;
  },

  /// "project-manager" -> "Project Manager". Short all-consonant slugs that
  /// are obviously acronyms ("hr", "qa") are upper-cased instead.
  displayName(slug: string): string {
    const s = shipped.find(t => t.slug === slug);
    if (s) return s.name;
    return slug.split("-").filter(Boolean).map(w => {
      const chars = Array.from(w);
      if (chars.length <= 2) return w.toUpperCase();
      return chars[0].toUpperCase() + chars.slice(1).join("");
    }).join(" ");
  },

  isShipped(slug: string): boolean { return shipped.some(t => t.slug === slug); },

  exists(slug: string): boolean { return fs.existsSync(SummaryTemplates.url(slug)); },

  // MARK: - Writing

  /// Writes any shipped template that isn't on disk. Never overwrites: a
  /// template the user has edited is their content, and silently replacing
  /// somebody's HR template on an update would be a nasty surprise. "Reset to
  /// default" is the deliberate way back.
  seedIfMissing(): void {
    for (const t of shipped) if (!SummaryTemplates.exists(t.slug)) write(SummaryTemplates.url(t.slug), t.body);
    migrateLegacyStyleFile();
  },

  /// Creates a template from a display name. Returns its slug, or null if the
  /// name is unusable or already taken.
  create(name: string, copying: string | null = null): string | null {
    const slug = SummaryTemplates.slugify(name);
    if (!slug || SummaryTemplates.exists(slug)) return null;
    let body = `# ${name}
# How you want your meeting summaries written, as plain instructions --
# one per line, the way you'd tell a person. Lines starting with # are ignored.
#
# These override the built-in structure: you can drop a section you don't
# use, add one you do, change the order, or set the length and tone.
#
# Two headings to leave spelled exactly as they are if you keep them:
# "## Action Items" and "## Follow-Up Meetings" are read by name when
# sending tasks to Google.
`;
    if (copying) {
      const copied = SummaryTemplates.instructions(copying);
      if (copied) body += `# Copied from ${SummaryTemplates.displayName(copying)}:\n\n` + copied + "\n";
    }
    write(SummaryTemplates.url(slug), body);
    return slug;
  },

  /// Restores a shipped template to what the current build ships. Only
  /// meaningful for shipped slugs -- a user's own template has no default.
  reset(slug: string): boolean {
    const t = shipped.find(s => s.slug === slug);
    if (!t) return false;
    write(SummaryTemplates.url(slug), t.body);
    return true;
  },

  delete(slug: string): void {
    try { fs.rmSync(SummaryTemplates.url(slug), { force: true }); } catch { /* already gone */ }
    if (Settings.summaryTemplate === slug) Settings.summaryTemplate = "default";
  },

  slugify(name: string): string {
    const lowered = name.toLowerCase().trim();
    let out = "";
    for (const ch of lowered) {
      if (/[\p{L}\p{N}]/u.test(ch)) out += ch;
      else if (ch === " " || ch === "-" || ch === "_") { if (!out.endsWith("-")) out += "-"; }
    }
    out = out.replace(/^-+/, "").replace(/-+$/, "");
    return Array.from(out).slice(0, 40).join("");
  },
};

/// `summary_style.txt` was the single-file version of this. Anything the
/// user actually wrote in it becomes a template called "My Style" and is
/// selected, so the upgrade doesn't quietly drop their customization.
function migrateLegacyStyleFile(): void {
  const legacy = nikxelPath("summary_style.txt");
  const raw = readText(legacy);
  if (raw === null) return;
  const content = stripComments(raw);
  // All comments means they never wrote anything -- just retire the file.
  if (!content) {
    try { fs.rmSync(legacy, { force: true }); } catch { /* ignore */ }
    return;
  }
  const slug = "my-style";
  if (!SummaryTemplates.exists(slug)) {
    const header = `# My Style -- carried over from summary_style.txt, which this replaces.
# Edit freely. Lines starting with # are ignored.
`;
    write(SummaryTemplates.url(slug), header + content);
    Settings.summaryTemplate = slug;
  }
  try { fs.rmSync(legacy, { force: true }); } catch { /* ignore */ }
}
