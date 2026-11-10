// Checks the WhatsApp auto-reply gate: when a mode lets a reply out, how the
// unattended timer behaves, and that group chatter is dropped unless the user
// was actually tagged.
//
//   swiftc -parse-as-library -target arm64-apple-macos15.0 -o /tmp/cwb \
//     check_wa_bot.swift src/ChatbotEngine.swift src/ChromeWhatsApp.swift \
//     src/CDPClient.swift src/NikxelSettings.swift src/MeetingDetector.swift \
//     src/LLMResponder.swift src/MOMGenerator.swift src/UsageLog.swift src/DayLogger.swift \
//     src/NoteExporter.swift src/CaptureMode.swift src/Diag.swift \
//     src/SummaryTemplates.swift src/WhatsAppActivityLogger.swift \
//     src/WAContactLists.swift src/GoogleSync.swift src/GoogleAuth.swift -framework Cocoa
import Foundation

@main
struct CheckWABot {
    typealias D = WABotGate.Decision

    static func chat(group: Bool = false, mentioned: Bool = false) -> WAUnreadChat {
        WAUnreadChat(name: "Asha", unread: 1, text: "hi", index: 0,
                     isGroup: group, mentioned: mentioned,
                     sender: group ? "Someone" : "", preview: "hi")
    }

    static func decide(_ c: WAUnreadChat,
                       waitedMinutes: Double = 0,
                       inMeeting: Bool = false,
                       mode: WABotMode = .meetings,
                       groups: Bool = false,
                       unattendedMinutes: Double = 5,
                       blocked: Bool = false,
                       quiet: Bool = false) -> D {
        let now = Date(timeIntervalSince1970: 1_000_000)
        return WABotGate.decide(
            chat: c,
            pendingSince: now.addingTimeInterval(-waitedMinutes * 60),
            now: now,
            inMeeting: inMeeting,
            mode: mode,
            groupReplies: groups,
            unattendedSeconds: unattendedMinutes * 60,
            blocked: blocked,
            quietHours: quiet)
    }

    static func at(_ hour: Int) -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = 11; c.day = 9; c.hour = hour; c.minute = 30
        return Calendar.current.date(from: c)!
    }

    static func isSkip(_ d: D) -> Bool { if case .skip = d { return true }; return false }

    static func main() {
        let one = chat()

        // --- Meeting-only: the original behaviour, unchanged ----------------
        assert(decide(one, inMeeting: true, mode: .meetings) == .reply)
        assert(isSkip(decide(one, inMeeting: false, mode: .meetings)),
               "meeting-only mode must stay silent outside a meeting")
        // Waiting does not help in meeting-only mode -- there is no timer.
        assert(isSkip(decide(one, waitedMinutes: 60, mode: .meetings)))

        // --- Always: no gate at all ----------------------------------------
        assert(decide(one, mode: .always) == .reply)
        assert(decide(one, inMeeting: true, mode: .always) == .reply)

        // --- Unattended: the timer -----------------------------------------
        assert(decide(one, waitedMinutes: 0, mode: .unattended) == .wait)
        assert(decide(one, waitedMinutes: 4.9, mode: .unattended) == .wait)
        assert(decide(one, waitedMinutes: 5, mode: .unattended) == .reply,
               "exactly at the threshold replies -- >= not >")
        assert(decide(one, waitedMinutes: 30, mode: .unattended) == .reply)
        // The delay is configurable, and the gate must honour it, not hardcode 5.
        assert(decide(one, waitedMinutes: 5, mode: .unattended, unattendedMinutes: 20) == .wait)
        assert(decide(one, waitedMinutes: 20, mode: .unattended, unattendedMinutes: 20) == .reply)
        // A meeting short-circuits the wait: telling someone "he's in a meeting"
        // five minutes late is worse than useless.
        assert(decide(one, waitedMinutes: 0, inMeeting: true, mode: .unattended) == .reply)

        // --- Groups: off by default, tag-only when on ----------------------
        let groupPlain = chat(group: true, mentioned: false)
        let groupTagged = chat(group: true, mentioned: true)
        for mode in WABotMode.allCases {
            assert(isSkip(decide(groupPlain, inMeeting: true, mode: mode, groups: false)),
                   "groups off must beat every mode, meeting included (\(mode.rawValue))")
            assert(isSkip(decide(groupTagged, inMeeting: true, mode: mode, groups: false)),
                   "groups off means off even when tagged (\(mode.rawValue))")
            assert(isSkip(decide(groupPlain, inMeeting: true, mode: mode, groups: true)),
                   "an untagged group message is never addressed to the user (\(mode.rawValue))")
        }
        // Tagged, groups on: now it follows the same rules as a 1:1.
        assert(decide(groupTagged, inMeeting: true, mode: .meetings, groups: true) == .reply)
        assert(isSkip(decide(groupTagged, mode: .meetings, groups: true)))
        assert(decide(groupTagged, waitedMinutes: 5, mode: .unattended, groups: true) == .reply)
        assert(decide(groupTagged, waitedMinutes: 1, mode: .unattended, groups: true) == .wait)
        assert(decide(groupTagged, mode: .always, groups: true) == .reply)

        // --- Which modes keep the poller alive outside a meeting -----------
        assert(WABotMode.meetings.runsOutsideMeetings == false)
        assert(WABotMode.unattended.runsOutsideMeetings)
        assert(WABotMode.always.runsOutsideMeetings)

        // --- Settings clamp -------------------------------------------------
        // A 0-minute "unattended" delay is just `.always` wearing a disguise,
        // and a negative one would reply before the message arrived.
        let saved = NikxelSettings.waUnattendedMinutes
        NikxelSettings.waUnattendedMinutes = 0
        assert(NikxelSettings.waUnattendedMinutes == 1)
        NikxelSettings.waUnattendedMinutes = 9999
        assert(NikxelSettings.waUnattendedMinutes == 120)
        NikxelSettings.waUnattendedMinutes = saved

        // An unrecognised / absent stored value must fall back to the old
        // behaviour -- upgrading must not silently put a bot on the air all day.
        assert(WABotMode(rawValue: "") == nil)
        assert(WABotMode(rawValue: "sometimes") == nil)
        assert((WABotMode(rawValue: "sometimes") ?? .meetings) == .meetings)

        // --- Never-reply list beats everything -----------------------------
        for mode in WABotMode.allCases {
            assert(isSkip(decide(one, inMeeting: true, mode: mode, blocked: true)),
                   "a blocked contact is never answered, meeting or not (\(mode.rawValue))")
            assert(isSkip(decide(groupTagged, inMeeting: true, mode: mode,
                                 groups: true, blocked: true)),
                   "blocked beats a group tag too (\(mode.rawValue))")
        }

        // --- Quiet hours ----------------------------------------------------
        // Held, not dropped: the message goes out when the quiet window ends.
        assert(decide(one, mode: .always, quiet: true) == .wait,
               "quiet hours hold a message rather than discarding it")
        assert(decide(one, waitedMinutes: 99, mode: .unattended, quiet: true) == .wait,
               "a long-expired timer still waits out quiet hours")
        // A meeting means you're awake.
        assert(decide(one, inMeeting: true, mode: .always, quiet: true) == .reply)
        // Blocked still wins over the hold.
        assert(isSkip(decide(one, mode: .always, blocked: true, quiet: true)))

        // Wraparound window 22 -> 8: the normal case, spanning midnight.
        for h in [22, 23, 0, 3, 7] {
            assert(WABotGate.isQuietHour(at(h), from: 22, to: 8), "hour \(h) is inside 22->8")
        }
        for h in [8, 9, 13, 21] {
            assert(!WABotGate.isQuietHour(at(h), from: 22, to: 8), "hour \(h) is outside 22->8")
        }
        // Same-day window 13 -> 14 (a lunch hour), no wraparound.
        assert(WABotGate.isQuietHour(at(13), from: 13, to: 14))
        assert(!WABotGate.isQuietHour(at(14), from: 13, to: 14), "the end hour is exclusive")
        assert(!WABotGate.isQuietHour(at(12), from: 13, to: 14))
        // A zero-length window is a half-filled settings file, not "silent all
        // day" -- that is what the Off switch is for.
        for h in [0, 9, 22] {
            assert(!WABotGate.isQuietHour(at(h), from: 9, to: 9))
        }

        // --- Contact-list matching ------------------------------------------
        let list = WAContactLists.parse("""
        # a comment
        Asha

        Rahul Mehta
          Priya Sharma
        Jo
        """)
        assert(list == ["Asha", "Rahul Mehta", "Priya Sharma", "Jo"],
               "comments and blanks stripped, indentation trimmed — got \(list)")
        assert(WAContactLists.matches(list, contact: "Asha"))
        assert(WAContactLists.matches(list, contact: "asha"), "case-insensitive")
        assert(WAContactLists.matches(list, contact: "Asha Verma"),
               "a first name on the list matches the full chat name")
        assert(WAContactLists.matches(list, contact: "Rahul Mehta"))
        assert(WAContactLists.matches(list, contact: "Rahul"),
               "the chat name being shorter than the entry also matches")
        assert(WAContactLists.matches(list, contact: "Priya   Sharma"),
               "runs of whitespace collapse")
        assert(!WAContactLists.matches(list, contact: "Asheesh"),
               "prefix matching must not swallow a different name that starts the same")
        assert(!WAContactLists.matches(list, contact: "Vikram"))
        assert(!WAContactLists.matches(list, contact: ""))
        // Short entries are exact-match only, so a stray "Jo" can't silence
        // Joanna, Jonathan and John at once.
        assert(WAContactLists.matches(list, contact: "Jo"))
        assert(!WAContactLists.matches(list, contact: "Joanna"))
        assert(WAContactLists.matches([], contact: "Asha") == false)

        // --- [[TASK:]] extraction -------------------------------------------
        let plain = LLMResponder.extractTask("He's in a meeting, back in an hour.")
        assert(plain.task == nil)
        assert(plain.body == "He's in a meeting, back in an hour.")

        let withTask = LLMResponder.extractTask(
            "Sure, he'll get that over.\n[[TASK: Send the deck to Priya by Friday]]")
        assert(withTask.task == "Send the deck to Priya by Friday")
        assert(withTask.body == "Sure, he'll get that over.",
               "the marker is stripped, and so is the newline it sat on — got '\(withTask.body)'")

        // A model that emits several keeps the first and the reply loses them all.
        let many = LLMResponder.extractTask(
            "On it. [[TASK: Book the room]] Also noted. [[TASK: Email Dev]]")
        assert(many.task == "Book the room")
        assert(!many.body.contains("TASK"), "every marker leaves the sent message — got '\(many.body)'")
        assert(many.body.contains("On it.") && many.body.contains("Also noted."))

        // "none" is how a model says "nothing to file" when it ignores the
        // instruction to omit the line entirely.
        assert(LLMResponder.extractTask("All good. [[TASK: none]]").task == nil)
        assert(LLMResponder.extractTask("All good. [[TASK:   ]]").task == nil)
        // An unterminated marker must not hang or eat the reply.
        let broken = LLMResponder.extractTask("Fine. [[TASK: never closed")
        assert(broken.task == nil)
        assert(broken.body == "Fine. [[TASK: never closed")

        // --- Conversation label -> (name, isGroup) --------------------------
        // The exact strings WhatsApp Web was observed to emit. Leaving the
        // "group" qualifier in the name made the engine's "am I in the right
        // chat" check fail for every group, so a tagged group message the user
        // had explicitly allowed was aborted instead of answered.
        let oneToOne = ChromeWhatsApp.parseConversationLabel("Kirti Forklyft")
        assert(oneToOne.name == "Kirti Forklyft" && !oneToOne.isGroup)

        let grp = ChromeWhatsApp.parseConversationLabel("group Warrior Tennis 🎾")
        assert(grp.isGroup, "the leading qualifier is the only reliable group signal in the page")
        assert(grp.name == "Warrior Tennis 🎾", "the qualifier must not survive into the name — got '\(grp.name)'")

        let grp2 = ChromeWhatsApp.parseConversationLabel("group Produce POS App Dev")
        assert(grp2.isGroup && grp2.name == "Produce POS App Dev")

        // A contact whose name merely begins with "group" is not a group.
        let tricky = ChromeWhatsApp.parseConversationLabel("Groupon Support")
        assert(!tricky.isGroup && tricky.name == "Groupon Support",
               "\"group\" must be a whole word, not a prefix — got \(tricky)")

        // And the name the engine compares against must pass its own check.
        func verifyPasses(header: String, target: String) -> Bool {
            let a = header.lowercased().trimmingCharacters(in: .whitespaces)
            let b = target.lowercased().trimmingCharacters(in: .whitespaces)
            return a == b || a.hasPrefix(b) || b.hasPrefix(a) || a.contains(b)
        }
        assert(verifyPasses(header: grp.name, target: "Warrior Tennis 🎾"))
        assert(verifyPasses(header: oneToOne.name, target: "Kirti Forklyft"))
        // Containment still has to reject a genuinely wrong chat.
        assert(!verifyPasses(header: "Dadaji", target: "Krishna Sharma"))

        // --- Google's "API not switched on" 403 ------------------------------
        // Verbatim from a real response. Every chat task after this one would
        // have failed the same way, in a log file nobody opens.
        let disabled = "Google Tasks API has not been used in project 115572520981 before or it is disabled. Enable it by visiting https://console.developers.google.com/apis/api/tasks.googleapis.com/overview?project=115572520981 then retry. If you enabled this API recently, wait a few minutes."
        assert(GoogleSync.isAPIDisabled(disabled))
        assert(GoogleSync.consoleURL(in: disabled)
               == "https://console.developers.google.com/apis/api/tasks.googleapis.com/overview?project=115572520981",
               "the console link must survive intact up to the next space — got \(GoogleSync.consoleURL(in: disabled) ?? "nil")")
        // An ordinary failure is not an API-disabled one and carries no link.
        assert(!GoogleSync.isAPIDisabled("Rate limit exceeded"))
        assert(GoogleSync.consoleURL(in: "Rate limit exceeded") == nil)
        // A 401 is handled by the token refresh, not by nagging about the API.
        assert(!GoogleSync.isAPIDisabled("Request had invalid authentication credentials"))

        // --- Browser detection ----------------------------------------------
        // Arc is Chromium but ignores --user-data-dir, so there is no way to get
        // an isolated profile out of it; driving the user's own logged-in
        // browser is not an acceptable fallback.
        let names = ChromeBot.supportedBrowsers.map(\.name)
        assert(names.first == "Google Chrome", "Chrome is the tested one, so it is tried first")
        assert(!names.contains("Arc") && !names.contains("Safari") && !names.contains("Firefox"))
        assert(Set(names).count == names.count, "no duplicate browsers")
        for b in ChromeBot.supportedBrowsers {
            assert(b.app.hasSuffix(".app"), "\(b.name) needs a bundle name")
            assert(!b.binary.isEmpty)
        }

        // --- Chat thread context ---------------------------------------------
        // The 3pm Shreyaa chat: "Okay" got an ERP answer because the bot never
        // saw the turns around it.
        let st = { ChromeWhatsApp.parseStamp($0)! }
        assert(ChromeWhatsApp.parseStamp("2:46 pm, 10/11/2026") != nil, "WhatsApp's lowercase pm parses")
        assert(ChromeWhatsApp.parseStamp("14:46, 10/11/2026") == st("2:46 pm, 10/11/2026"), "24h clock too")
        assert(ChromeWhatsApp.parseStamp("") == nil)
        let now = st("3:20 pm, 10/11/2026")
        let isBot = { (t: String) in t.contains("AI Assistant") }
        func m(_ out: Bool, _ at: String?, _ text: String) -> WAMessage {
            WAMessage(outgoing: out, at: at.map(st), text: text)
        }
        let thread = [
            m(false, "1:00 pm, 10/11/2026", "stale topic"),            // older than 30 min: dropped
            m(false, "2:59 pm, 10/11/2026", "tumne erp se connect kr diya hai?"),
            m(true,  "3:00 pm, 10/11/2026", "Nikhil's AI Assistant: ERP update soon"),
            m(false, "3:03 pm, 10/11/2026", "Windows se compatible bana do"),
            m(false, nil, "Okay"),                                      // continuation row = new message
        ]
        let ctx = WABotGate.threadContext(thread, now: now, isBot: isBot)
        assert(ctx.turns.map(\.text) == ["tumne erp se connect kr diya hai?", "Nikhil's AI Assistant: ERP update soon"],
               "trailing incoming run excluded, stale turn dropped: \(ctx.turns.map(\.text))")
        assert(ctx.turns[1].bot && ctx.turns[1].outgoing && !ctx.turns[0].outgoing)

        // The user's own recent message is context, labelled as theirs -- not a
        // reason to stay silent (that skip left chats on "seen" with no reply).
        let mine = [m(true, "3:15 pm, 10/11/2026", "prince?"), m(false, "3:16 pm, 10/11/2026", "hello")]
        let mc = WABotGate.threadContext(mine, now: now, isBot: isBot)
        assert(mc.turns.count == 1 && mc.turns[0].outgoing && !mc.turns[0].bot)
        // A chat idle past 30 min starts fresh.
        let old = [m(true, "2:15 pm, 10/11/2026", "prince?"), m(false, "3:16 pm, 10/11/2026", "hello")]
        let oc = WABotGate.threadContext(old, now: now, isBot: isBot)
        assert(oc.turns.isEmpty, "idle chat starts fresh")
        // Limit keeps the last five.
        let long = (0..<9).map { m($0 % 2 == 0, "3:1\($0) pm, 10/11/2026", "t\($0)") } + [m(false, "3:19 pm, 10/11/2026", "new")]
        assert(WABotGate.threadContext(long, now: now, isBot: { _ in true }).turns.map(\.text) == ["t4", "t5", "t6", "t7", "t8"])
        // Bot-to-bot: Prince's assistant and ours, three rounds since Nikhil typed.
        var loop = [m(true, "3:00 pm, 10/11/2026", "tu kr msg")]
        for i in 1...3 {
            loop.append(m(false, "3:0\(i) pm, 10/11/2026", "Haan, main Prince ka assistant hoon"))
            loop.append(m(true, "3:0\(i) pm, 10/11/2026", "Nikhil's AI Assistant here"))
        }
        loop.append(m(false, "3:05 pm, 10/11/2026", "Prince ka assistant again"))
        assert(WABotGate.threadContext(loop, now: now, isBot: isBot).botLoop, "three bot rounds stop")
        assert(!WABotGate.threadContext(Array(loop.prefix(5)) + [loop.last!], now: now, isBot: isBot).botLoop,
               "two rounds still allowed")
        // A human asking three questions in a row is not a loop.
        let human = [m(false, "3:01 pm, 10/11/2026", "update on datacap?"), m(true, "3:01 pm, 10/11/2026", "AI Assistant: ..."),
                     m(false, "3:02 pm, 10/11/2026", "produce pos?"), m(true, "3:02 pm, 10/11/2026", "AI Assistant: ..."),
                     m(false, "3:03 pm, 10/11/2026", "erp?"), m(true, "3:03 pm, 10/11/2026", "AI Assistant: ..."),
                     m(false, "3:04 pm, 10/11/2026", "bye")]
        assert(!WABotGate.threadContext(human, now: now, isBot: isBot).botLoop)
        // The user typing resets the count.
        assert(!WABotGate.threadContext(loop + [m(true, "3:06 pm, 10/11/2026", "ok stop"),
                                                m(false, "3:07 pm, 10/11/2026", "assistant hoon")], now: now, isBot: isBot).botLoop)

        assert(ChatbotEngine.fingerprint("Hi 👋 there!") == ChatbotEngine.fingerprint("Hi there"))

        print("check_wa_bot: OK")
    }
}
