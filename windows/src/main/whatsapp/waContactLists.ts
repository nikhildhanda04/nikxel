import * as fs from "fs";
import { nikxelPath, readText, writeAtomic } from "../core/paths";

/// The two per-contact lists the WhatsApp bot consults: who it must never
/// answer, and who it may speak freely in front of.
///
/// Plain text files in `~/.nikxel/`, one name per line, `#` for comments —
/// same shape as `bot_personality.txt` and the summary templates, so they can
/// be edited in any editor without Nikxel running. Re-read on every check
/// rather than cached: editing the file should take effect on the next
/// message, not the next launch.

export type WAContactListKind = "neverReply" | "trusted";

const FILE_NAMES: Record<WAContactListKind, string> = {
  neverReply: "never_reply.txt",
  trusted: "trusted_contacts.txt",
};

const SEED_CONTENTS: Record<WAContactListKind, string> = {
  neverReply: `# Contacts Nikxel must never auto-reply to, one name per line.
#
# Write the name exactly as it appears in your WhatsApp chat list.
# A first name on its own is enough as long as it's 3+ letters --
# "Asha" matches the chat "Asha Verma".
#
# Entries here beat every other setting: not during meetings, not
# when tagged in a group, not ever.
#
# Lines starting with # are ignored. Examples:
# Mum
# Priya Sharma`,
  trusted: `# Contacts the bot may speak freely in front of, one name per line.
#
# By default the bot is told never to disclose what you are
# working on -- project names, repos, clients, meeting topics, who
# else you spoke to -- because it answers whoever happens to write
# to you. Names listed here are exempt: it will answer them with
# the specifics instead of "heads-down on work stuff".
#
# Only list people who would already be told. A co-founder,
# your own team. Not a client, not a group.
#
# Write the name exactly as it appears in your WhatsApp chat list.
# A first name on its own is enough as long as it's 3+ letters.
#
# Lines starting with # are ignored. Examples:
# Anjali
# Rahul Mehta`,
};

function normalize(s: string): string {
  return s.toLowerCase().split(/\s+/).filter(Boolean).join(" ");
}

export const WAContactLists = {
  fileURL(kind: WAContactListKind): string {
    return nikxelPath(FILE_NAMES[kind]);
  },

  /// Writes the commented template if the file doesn't exist yet. Never
  /// overwrites — an empty-but-present file is a user who deleted the
  /// comments, not a user who needs them back.
  seedIfMissing(kind: WAContactListKind): string {
    const file = WAContactLists.fileURL(kind);
    if (!fs.existsSync(file)) {
      try { writeAtomic(file, SEED_CONTENTS[kind]); } catch { /* unwritable home: the editor opens nothing */ }
    }
    return file;
  },

  /// The names on a list, comments and blanks stripped.
  names(kind: WAContactListKind): string[] {
    const text = readText(WAContactLists.fileURL(kind));
    return text === null ? [] : WAContactLists.parse(text);
  },

  /// Split out from `names` so the matching rules can be checked without
  /// writing to the user's home directory — see checks/waBot.test.ts.
  parse(text: string): string[] {
    return text.split(/\r\n|\r|\n/)
      .map(l => l.replace(/^[ \t]+|[ \t]+$/g, ""))
      .filter(l => l !== "" && !l.startsWith("#"));
  },

  contains(kind: WAContactListKind, contact: string): boolean {
    return WAContactLists.matches(WAContactLists.names(kind), contact);
  },

  /// Whether `contact` is on `list`.
  ///
  /// Tolerant in the same way the conversation-header verification is: a chat
  /// called "Asha Verma" is matched by an entry of "Asha", because that is how
  /// people actually write these lists. Prefix matching is restricted to
  /// entries of 3+ characters, so a stray "Al" can't silence Alice, Alex and
  /// Ali at once.
  matches(list: string[], contact: string): boolean {
    const c = normalize(contact);
    if (!c) return false;
    for (const raw of list) {
      const n = normalize(raw);
      if (!n) continue;
      if (n === c) return true;
      if (Array.from(n).length >= 3 && (c.startsWith(n) || n.startsWith(c))) return true;
    }
    return false;
  },
};
