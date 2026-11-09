// Checks the WhatsApp auto-reply gate: when a mode lets a reply out, how the
// unattended timer behaves, and that group chatter is dropped unless the user
// was actually tagged.
//
//   swiftc -parse-as-library -target arm64-apple-macos15.0 -o /tmp/cwb \
//     check_wa_bot.swift src/ChatbotEngine.swift src/ChromeWhatsApp.swift \
//     src/CDPClient.swift src/NikxelSettings.swift src/MeetingDetector.swift \
//     src/LLMResponder.swift src/MOMGenerator.swift src/DayLogger.swift \
//     src/NoteExporter.swift src/CaptureMode.swift src/Diag.swift \
//     src/SummaryTemplates.swift src/WhatsAppActivityLogger.swift
import Foundation

@main
struct CheckWABot {
    typealias D = WABotGate.Decision

    static func chat(group: Bool = false, mentioned: Bool = false) -> WAUnreadChat {
        WAUnreadChat(name: "Asha", unread: 1, text: "hi", index: 0,
                     isGroup: group, mentioned: mentioned)
    }

    static func decide(_ c: WAUnreadChat,
                       waitedMinutes: Double = 0,
                       inMeeting: Bool = false,
                       mode: WABotMode = .meetings,
                       groups: Bool = false,
                       unattendedMinutes: Double = 5) -> D {
        let now = Date(timeIntervalSince1970: 1_000_000)
        return WABotGate.decide(
            chat: c,
            pendingSince: now.addingTimeInterval(-waitedMinutes * 60),
            now: now,
            inMeeting: inMeeting,
            mode: mode,
            groupReplies: groups,
            unattendedSeconds: unattendedMinutes * 60)
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

        print("check_wa_bot: OK")
    }
}
