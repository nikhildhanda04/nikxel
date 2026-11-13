// Checks GoogleSync's parsing of a generated MOM. Pure string/date work -- no
// network, nothing written to anyone's Google account.
//
//   swiftc -parse-as-library -o /tmp/cgs check_google_sync.swift \
//     src/GoogleSync.swift src/GoogleAuth.swift src/NikxelSettings.swift \
//     src/NoteExporter.swift src/NotePage.swift src/MOMGenerator.swift src/UsageLog.swift src/CaptureMode.swift src/Diag.swift \
//     src/NikxelView.swift src/NikxelCard.swift src/StateMachine.swift src/SpriteSheetImporter.swift \
//     src/SummaryTemplates.swift
//   /tmp/cgs
import Foundation

/// ChatbotEngine's logger, which GoogleSync calls; not compiled into this check.
func cblog(_ s: String) {}

@main
struct CheckGoogleSync {
    static let tz = TimeZone(identifier: "Asia/Kolkata")!

    static func day(_ s: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = tz
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: s)!
    }

    static func main() {
        let note = """
        # Meeting — 2026-11-09 10:00

        ## Summary
        We talked about the billing migration.

        ## Decisions
        - Ship behind a flag.

        ## Action Items
        - [ ] **Send Priya the updated pricing sheet** — Owner: Rohan — Due: 2026-11-12
        - [ ] **Rewrite the retry logic — not the docs — before the demo** — Owner: Me — Due: Not specified
        - [ ] **Chase legal on the DPA** — Owner: Unassigned — Due: 2026-11-20
        - [x] **Already done thing** — Owner: Priya — Due: Not specified
        - [ ] **Book the big room** — Owner: Priya — Due: next Friday

        ## Follow-Up Meetings
        - **Design review** — When: 2026-11-12 15:30 — Duration: 45 min — With: Priya, Rohan
        - **Legal sync** — When: Not specified — Duration: 30 min — With: Meera
        - **Thursday afternoon catch-up** — When: 2026-11-13 — Duration: 60 min — With: Not specified

        ## Agent Prompts
        ### Retry logic — Me
        ```
        Add retry handling.
        ```
        """

        // --- Action items -------------------------------------------------
        let items = GoogleSync.parseActionItems(note, tz: tz)
        assert(items.count == 5, "expected 5 action items, got \(items.count)")

        assert(items[0].title == "Send Priya the updated pricing sheet", items[0].title)
        assert(items[0].owner == "Rohan")
        assert(items[0].due == day("2026-11-12 00:00"))

        // An em dash inside the task must not split the title: fields are
        // sliced from the right, which is the whole reason for that choice.
        assert(items[1].title == "Rewrite the retry logic — not the docs — before the demo", items[1].title)
        assert(items[1].owner == "Me")
        assert(items[1].due == nil, "\"Not specified\" must not become a date")

        // "Unassigned" is normalised away so the task doesn't get prefixed.
        assert(items[2].owner == "", "Unassigned should read as no owner")
        assert(items[2].due == day("2026-11-20 00:00"))

        // A ticked box is still an item -- the model sometimes marks one done.
        assert(items[3].title == "Already done thing", items[3].title)

        // Prose dates are dropped, never guessed at.
        assert(items[4].due == nil, "\"next Friday\" must not be invented into a date")

        // --- Task titles ---------------------------------------------------
        assert(items[0].taskTitle(ownName: "Jake") == "[Rohan] Send Priya the updated pricing sheet")
        assert(items[1].taskTitle(ownName: "Jake") == "Rewrite the retry logic — not the docs — before the demo",
               "a task owned by \"Me\" is mine, no prefix")
        assert(items[2].taskTitle(ownName: "Jake") == "Chase legal on the DPA", "unassigned gets no prefix")
        assert(items[0].taskTitle(ownName: "Rohan") == "Send Priya the updated pricing sheet",
               "matching the user's own name means no prefix")

        // The Speakers section labels the user "Jake (Me)", so that is the
        // owner string that really arrives -- it must read as the user's own
        // task, not get prefixed with their own name.
        let labelled = GoogleSync.parseActionItems(
            "## Action Items\n- [ ] **Approve the comp review** — Owner: Jake (Me) — Due: Not specified", tz: tz)
        assert(labelled.count == 1)
        assert(labelled[0].normalizedOwner == "Jake", labelled[0].normalizedOwner)
        assert(labelled[0].isMine(ownName: "Jake"))
        assert(labelled[0].taskTitle(ownName: "Jake") == "Approve the comp review",
               "got: \(labelled[0].taskTitle(ownName: "Jake"))")
        assert(labelled[0].taskTitle(ownName: "Anjali") == "[Jake] Approve the comp review",
               "somebody else's task keeps the name, without the (Me) marker")

        // A trailing note after the Due field must not become a due date.
        let trailing = GoogleSync.parseActionItems(
            "## Action Items\n- [ ] **Ship the guard** — Owner: Unassigned — Due: Not specified — *Waiting on the ticket.*", tz: tz)
        assert(trailing.count == 1 && trailing[0].due == nil, "trailing prose must not parse as a date")

        // --- Follow-ups ------------------------------------------------------
        let ups = GoogleSync.parseFollowUps(note, tz: tz)
        assert(ups.count == 1, "only the one with a real date AND time, got \(ups.count): \(ups.map(\.title))")
        assert(ups[0].title == "Design review", ups[0].title)
        assert(ups[0].start == day("2026-11-12 15:30"))
        assert(ups[0].durationMin == 45)
        assert(ups[0].with == "Priya, Rohan")

        // --- "None" placeholders are not items -------------------------------
        let empty = """
        ## Action Items
        - [ ] None — no tasks came out of this meeting.

        ## Follow-Up Meetings
        - None.
        """
        assert(GoogleSync.parseActionItems(empty, tz: tz).isEmpty, "\"None\" is not a task")
        assert(GoogleSync.parseFollowUps(empty, tz: tz).isEmpty, "\"None\" is not a meeting")

        // --- A note with the sections removed (custom summary style) ---------
        let stripped = """
        # Meeting — 2026-11-09 10:00

        ## Summary
        Short one.
        """
        assert(GoogleSync.parseActionItems(stripped, tz: tz).isEmpty)
        assert(GoogleSync.parseFollowUps(stripped, tz: tz).isEmpty)
        assert(GoogleSync.section(stripped, heading: "Action Items") == "",
               "a missing section reads as empty, not as the whole document")

        // --- Section slicing stops at the next ## ----------------------------
        let decisions = GoogleSync.section(note, heading: "Decisions")
        assert(decisions.contains("Ship behind a flag"))
        assert(!decisions.contains("Send Priya"), "a section must not bleed into the next one")
        // ### subheadings stay inside their ## section.
        assert(GoogleSync.section(note, heading: "Agent Prompts").contains("### Retry logic"))

        // --- Date parsers in isolation ---------------------------------------
        assert(GoogleSync.parseDay("2026-11-12", tz: tz) == day("2026-11-12 00:00"))
        assert(GoogleSync.parseDay(" **2026-11-12** ", tz: tz) == day("2026-11-12 00:00"),
               "stray bold markers must not defeat the date")
        assert(GoogleSync.parseDay("Not specified", tz: tz) == nil)
        assert(GoogleSync.parseDay("12/11/2026", tz: tz) == nil, "only ISO dates are trusted")
        assert(GoogleSync.parseMoment("2026-11-12 15:30", tz: tz) == day("2026-11-12 15:30"))
        assert(GoogleSync.parseMoment("2026-11-12T15:30", tz: tz) == day("2026-11-12 15:30"))
        assert(GoogleSync.parseMoment("2026-11-12", tz: tz) == nil,
               "a date with no time is not a moment -- it must not default to midnight")

        print("check_google_sync: all assertions passed")
    }
}
