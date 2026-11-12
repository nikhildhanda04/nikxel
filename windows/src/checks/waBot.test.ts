// Checks the WhatsApp auto-reply gate: when a mode lets a reply out, how the
// unattended timer behaves, and that group chatter is dropped unless the user
// was actually tagged. Port of check_wa_bot.swift.
//
// The Mac check's "Browser detection" section is gone with the code it
// covered: Windows runs WhatsApp Web in Nikxel's own window, not a Chrome it
// has to find.
import { test } from "node:test";
import * as assert from "node:assert/strict";
import * as fs from "fs";
import { WABotGate, runsOutsideMeetings, fingerprint, containsMeetingLink, extractTask, extractMarker, parseMeet, type Decision } from "../main/whatsapp/waBotGate";
import { WAContactLists } from "../main/whatsapp/waContactLists";
import { ChromeWhatsApp, chromeUserAgent, type WAMessage, type WAUnreadChat } from "../main/whatsapp/chromeWhatsApp";
import { Devanagari } from "../main/whatsapp/devanagari";
import { Settings, SETTINGS_FILE, WA_BOT_MODES, type WABotMode } from "../main/core/settings";
import { GoogleSync } from "../main/google/googleSync";

function chat(group = false, mentioned = false): WAUnreadChat {
  return { name: "Asha", unread: 1, text: "hi", index: 0, isGroup: group, mentioned, sender: group ? "Someone" : "", preview: "hi" };
}

function decide(c: WAUnreadChat, o: { waitedMinutes?: number; inMeeting?: boolean; mode?: WABotMode; groups?: boolean;
                                      unattendedMinutes?: number; blocked?: boolean; quiet?: boolean } = {}): Decision {
  const now = new Date(1_000_000 * 1000);
  return WABotGate.decide({
    chat: c,
    pendingSince: new Date(now.getTime() - (o.waitedMinutes ?? 0) * 60_000),
    now,
    inMeeting: o.inMeeting ?? false,
    mode: o.mode ?? "meetings",
    groupReplies: o.groups ?? false,
    unattendedSeconds: (o.unattendedMinutes ?? 5) * 60,
    blocked: o.blocked ?? false,
    quietHours: o.quiet ?? false,
  });
}

const at = (hour: number) => new Date(2026, 10, 9, hour, 30);
const isSkip = (d: Decision) => d.kind === "skip";
const REPLY: Decision = { kind: "reply" };
const WAIT: Decision = { kind: "wait" };

test("meeting-only: the original behaviour, unchanged", () => {
  const one = chat();
  assert.deepEqual(decide(one, { inMeeting: true, mode: "meetings" }), REPLY);
  assert.ok(isSkip(decide(one, { inMeeting: false, mode: "meetings" })), "meeting-only mode must stay silent outside a meeting");
  // Waiting does not help in meeting-only mode -- there is no timer.
  assert.ok(isSkip(decide(one, { waitedMinutes: 60, mode: "meetings" })));
});

test("always: no gate at all", () => {
  const one = chat();
  assert.deepEqual(decide(one, { mode: "always" }), REPLY);
  assert.deepEqual(decide(one, { inMeeting: true, mode: "always" }), REPLY);
});

test("unattended: the timer", () => {
  const one = chat();
  assert.deepEqual(decide(one, { waitedMinutes: 0, mode: "unattended" }), WAIT);
  assert.deepEqual(decide(one, { waitedMinutes: 4.9, mode: "unattended" }), WAIT);
  assert.deepEqual(decide(one, { waitedMinutes: 5, mode: "unattended" }), REPLY, "exactly at the threshold replies -- >= not >");
  assert.deepEqual(decide(one, { waitedMinutes: 30, mode: "unattended" }), REPLY);
  // The delay is configurable, and the gate must honour it, not hardcode 5.
  assert.deepEqual(decide(one, { waitedMinutes: 5, mode: "unattended", unattendedMinutes: 20 }), WAIT);
  assert.deepEqual(decide(one, { waitedMinutes: 20, mode: "unattended", unattendedMinutes: 20 }), REPLY);
  // A meeting short-circuits the wait: telling someone "he's in a meeting"
  // five minutes late is worse than useless.
  assert.deepEqual(decide(one, { waitedMinutes: 0, inMeeting: true, mode: "unattended" }), REPLY);
});

test("groups: off by default, tag-only when on", () => {
  const groupPlain = chat(true, false);
  const groupTagged = chat(true, true);
  for (const mode of WA_BOT_MODES) {
    assert.ok(isSkip(decide(groupPlain, { inMeeting: true, mode, groups: false })), `groups off must beat every mode, meeting included (${mode})`);
    assert.ok(isSkip(decide(groupTagged, { inMeeting: true, mode, groups: false })), `groups off means off even when tagged (${mode})`);
    assert.ok(isSkip(decide(groupPlain, { inMeeting: true, mode, groups: true })), `an untagged group message is never addressed to the user (${mode})`);
  }
  // Tagged, groups on: now it follows the same rules as a 1:1.
  assert.deepEqual(decide(groupTagged, { inMeeting: true, mode: "meetings", groups: true }), REPLY);
  assert.ok(isSkip(decide(groupTagged, { mode: "meetings", groups: true })));
  assert.deepEqual(decide(groupTagged, { waitedMinutes: 5, mode: "unattended", groups: true }), REPLY);
  assert.deepEqual(decide(groupTagged, { waitedMinutes: 1, mode: "unattended", groups: true }), WAIT);
  assert.deepEqual(decide(groupTagged, { mode: "always", groups: true }), REPLY);
});

test("which modes keep the poller alive outside a meeting", () => {
  assert.equal(runsOutsideMeetings("meetings"), false);
  assert.ok(runsOutsideMeetings("unattended"));
  assert.ok(runsOutsideMeetings("always"));
});

test("settings clamp and unknown mode fallback", () => {
  // Writes the real ~/.nikxel/settings.json, as the Mac check did; the exact
  // bytes are put back afterwards.
  let original: string | null = null;
  try { original = fs.readFileSync(SETTINGS_FILE, "utf8"); } catch { /* no file yet */ }
  try {
    // A 0-minute "unattended" delay is just `always` wearing a disguise,
    // and a negative one would reply before the message arrived.
    Settings.waUnattendedMinutes = 0;
    assert.equal(Settings.waUnattendedMinutes, 1);
    Settings.waUnattendedMinutes = 9999;
    assert.equal(Settings.waUnattendedMinutes, 120);

    // An unrecognised / absent stored value must fall back to the old
    // behaviour -- upgrading must not silently put a bot on the air all day.
    const raw = JSON.parse(fs.readFileSync(SETTINGS_FILE, "utf8"));
    for (const bad of ["", "sometimes"]) {
      raw.waBotMode = bad;
      fs.writeFileSync(SETTINGS_FILE, JSON.stringify(raw));
      assert.equal(Settings.waBotMode, "meetings");
    }
  } finally {
    if (original === null) fs.rmSync(SETTINGS_FILE, { force: true });
    else fs.writeFileSync(SETTINGS_FILE, original);
  }
});

test("never-reply list beats everything", () => {
  const one = chat();
  const groupTagged = chat(true, true);
  for (const mode of WA_BOT_MODES) {
    assert.ok(isSkip(decide(one, { inMeeting: true, mode, blocked: true })), `a blocked contact is never answered, meeting or not (${mode})`);
    assert.ok(isSkip(decide(groupTagged, { inMeeting: true, mode, groups: true, blocked: true })), `blocked beats a group tag too (${mode})`);
  }
});

test("quiet hours", () => {
  const one = chat();
  // Held, not dropped: the message goes out when the quiet window ends.
  assert.deepEqual(decide(one, { mode: "always", quiet: true }), WAIT, "quiet hours hold a message rather than discarding it");
  assert.deepEqual(decide(one, { waitedMinutes: 99, mode: "unattended", quiet: true }), WAIT, "a long-expired timer still waits out quiet hours");
  // A meeting means you're awake.
  assert.deepEqual(decide(one, { inMeeting: true, mode: "always", quiet: true }), REPLY);
  // Blocked still wins over the hold.
  assert.ok(isSkip(decide(one, { mode: "always", blocked: true, quiet: true })));

  // Wraparound window 22 -> 8: the normal case, spanning midnight.
  for (const h of [22, 23, 0, 3, 7]) assert.ok(WABotGate.isQuietHour(at(h), 22, 8), `hour ${h} is inside 22->8`);
  for (const h of [8, 9, 13, 21]) assert.ok(!WABotGate.isQuietHour(at(h), 22, 8), `hour ${h} is outside 22->8`);
  // Same-day window 13 -> 14 (a lunch hour), no wraparound.
  assert.ok(WABotGate.isQuietHour(at(13), 13, 14));
  assert.ok(!WABotGate.isQuietHour(at(14), 13, 14), "the end hour is exclusive");
  assert.ok(!WABotGate.isQuietHour(at(12), 13, 14));
  // A zero-length window is a half-filled settings file, not "silent all
  // day" -- that is what the Off switch is for.
  for (const h of [0, 9, 22]) assert.ok(!WABotGate.isQuietHour(at(h), 9, 9));
});

test("contact-list matching", () => {
  const list = WAContactLists.parse("# a comment\nAsha\n\nRahul Mehta\n  Priya Sharma\nJo");
  assert.deepEqual(list, ["Asha", "Rahul Mehta", "Priya Sharma", "Jo"], "comments and blanks stripped, indentation trimmed");
  // Windows line endings, as Notepad writes them.
  assert.deepEqual(WAContactLists.parse("Asha\r\n# x\r\nRahul\r\n"), ["Asha", "Rahul"]);
  assert.ok(WAContactLists.matches(list, "Asha"));
  assert.ok(WAContactLists.matches(list, "asha"), "case-insensitive");
  assert.ok(WAContactLists.matches(list, "Asha Verma"), "a first name on the list matches the full chat name");
  assert.ok(WAContactLists.matches(list, "Rahul Mehta"));
  assert.ok(WAContactLists.matches(list, "Rahul"), "the chat name being shorter than the entry also matches");
  assert.ok(WAContactLists.matches(list, "Priya   Sharma"), "runs of whitespace collapse");
  assert.ok(!WAContactLists.matches(list, "Asheesh"), "prefix matching must not swallow a different name that starts the same");
  assert.ok(!WAContactLists.matches(list, "Vikram"));
  assert.ok(!WAContactLists.matches(list, ""));
  // Short entries are exact-match only, so a stray "Jo" can't silence
  // Joanna, Jonathan and John at once.
  assert.ok(WAContactLists.matches(list, "Jo"));
  assert.ok(!WAContactLists.matches(list, "Joanna"));
  assert.equal(WAContactLists.matches([], "Asha"), false);
});

test("[[TASK:]] extraction", () => {
  const plain = extractTask("He's in a meeting, back in an hour.");
  assert.equal(plain.task, null);
  assert.equal(plain.body, "He's in a meeting, back in an hour.");

  const withTask = extractTask("Sure, he'll get that over.\n[[TASK: Send the deck to Priya by Friday]]");
  assert.equal(withTask.task, "Send the deck to Priya by Friday");
  assert.equal(withTask.body, "Sure, he'll get that over.", "the marker is stripped, and so is the newline it sat on");

  // A model that emits several keeps the first and the reply loses them all.
  const many = extractTask("On it. [[TASK: Book the room]] Also noted. [[TASK: Email Dev]]");
  assert.equal(many.task, "Book the room");
  assert.ok(!many.body.includes("TASK"), `every marker leaves the sent message — got '${many.body}'`);
  assert.ok(many.body.includes("On it.") && many.body.includes("Also noted."));

  // "none" is how a model says "nothing to file" when it ignores the
  // instruction to omit the line entirely.
  assert.equal(extractTask("All good. [[TASK: none]]").task, null);
  assert.equal(extractTask("All good. [[TASK:   ]]").task, null);
  // An unterminated marker must not hang or eat the reply.
  const broken = extractTask("Fine. [[TASK: never closed");
  assert.equal(broken.task, null);
  assert.equal(broken.body, "Fine. [[TASK: never closed");
});

test("conversation label -> (name, isGroup)", () => {
  // The exact strings WhatsApp Web was observed to emit. Leaving the
  // "group" qualifier in the name made the engine's "am I in the right
  // chat" check fail for every group, so a tagged group message the user
  // had explicitly allowed was aborted instead of answered.
  const oneToOne = ChromeWhatsApp.parseConversationLabel("Kirti Forklyft");
  assert.ok(oneToOne.name === "Kirti Forklyft" && !oneToOne.isGroup);

  const grp = ChromeWhatsApp.parseConversationLabel("group Warrior Tennis 🎾");
  assert.ok(grp.isGroup, "the leading qualifier is the only reliable group signal in the page");
  assert.equal(grp.name, "Warrior Tennis 🎾", "the qualifier must not survive into the name");

  const grp2 = ChromeWhatsApp.parseConversationLabel("group Produce POS App Dev");
  assert.ok(grp2.isGroup && grp2.name === "Produce POS App Dev");

  // A contact whose name merely begins with "group" is not a group.
  const tricky = ChromeWhatsApp.parseConversationLabel("Groupon Support");
  assert.ok(!tricky.isGroup && tricky.name === "Groupon Support", "\"group\" must be a whole word, not a prefix");

  // And the name the engine compares against must pass its own check.
  assert.ok(ChromeWhatsApp.headerMatches(grp.name, "Warrior Tennis 🎾"));
  assert.ok(ChromeWhatsApp.headerMatches(oneToOne.name, "Kirti Forklyft"));
  // Containment still has to reject a genuinely wrong chat.
  assert.ok(!ChromeWhatsApp.headerMatches("Dadaji", "Krishna Sharma"));
});

test("Google's \"API not switched on\" 403", () => {
  // Verbatim from a real response. Every chat task after this one would
  // have failed the same way, in a log file nobody opens.
  const disabled = "Google Tasks API has not been used in project 115572520981 before or it is disabled. Enable it by visiting https://console.developers.google.com/apis/api/tasks.googleapis.com/overview?project=115572520981 then retry. If you enabled this API recently, wait a few minutes.";
  assert.ok(GoogleSync.isAPIDisabled(disabled));
  assert.equal(GoogleSync.consoleURL(disabled),
    "https://console.developers.google.com/apis/api/tasks.googleapis.com/overview?project=115572520981",
    "the console link must survive intact up to the next space");
  // An ordinary failure is not an API-disabled one and carries no link.
  assert.ok(!GoogleSync.isAPIDisabled("Rate limit exceeded"));
  assert.equal(GoogleSync.consoleURL("Rate limit exceeded"), null);
  // A 401 is handled by the token refresh, not by nagging about the API.
  assert.ok(!GoogleSync.isAPIDisabled("Request had invalid authentication credentials"));
});

test("WhatsApp window passes as desktop Chrome", () => {
  // Windows only: replaces the Mac's browser-detection section.
  const ua = chromeUserAgent("146.0.7680.31");
  assert.equal(ua, "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36");
  assert.ok(!/Electron|nikxel/i.test(chromeUserAgent()), "Electron's own UA token is what WhatsApp rejects");
});

test("chat thread context", () => {
  // The 3pm Shreyaa chat: "Okay" got an ERP answer because the bot never
  // saw the turns around it.
  const st = (s: string) => ChromeWhatsApp.parseStamp(s)!;
  assert.notEqual(ChromeWhatsApp.parseStamp("2:46 pm, 10/11/2026"), null, "WhatsApp's lowercase pm parses");
  assert.equal(ChromeWhatsApp.parseStamp("14:46, 10/11/2026")?.getTime(), st("2:46 pm, 10/11/2026").getTime(), "24h clock too");
  assert.equal(ChromeWhatsApp.parseStamp(""), null);
  const now = st("3:20 pm, 10/11/2026");
  const isBot = (t: string) => t.includes("AI Assistant");
  const m = (out: boolean, a: string | null, text: string): WAMessage => ({ outgoing: out, at: a === null ? null : st(a), text });
  const thread = [
    m(false, "1:00 pm, 10/11/2026", "stale topic"),            // older than 30 min: dropped
    m(false, "2:59 pm, 10/11/2026", "tumne erp se connect kr diya hai?"),
    m(true,  "3:00 pm, 10/11/2026", "Nikhil's AI Assistant: ERP update soon"),
    m(false, "3:03 pm, 10/11/2026", "Windows se compatible bana do"),
    m(false, null, "Okay"),                                      // continuation row = new message
  ];
  const ctx = WABotGate.threadContext(thread, now, isBot);
  assert.deepEqual(ctx.turns.map(t => t.text), ["tumne erp se connect kr diya hai?", "Nikhil's AI Assistant: ERP update soon"],
    "trailing incoming run excluded, stale turn dropped");
  assert.ok(ctx.turns[1].bot && ctx.turns[1].outgoing && !ctx.turns[0].outgoing);

  // The user's own recent message is context, labelled as theirs -- not a
  // reason to stay silent (that skip left chats on "seen" with no reply).
  const mine = [m(true, "3:15 pm, 10/11/2026", "prince?"), m(false, "3:16 pm, 10/11/2026", "hello")];
  const mc = WABotGate.threadContext(mine, now, isBot);
  assert.ok(mc.turns.length === 1 && mc.turns[0].outgoing && !mc.turns[0].bot);
  // A chat idle past 30 min starts fresh.
  const old = [m(true, "2:15 pm, 10/11/2026", "prince?"), m(false, "3:16 pm, 10/11/2026", "hello")];
  assert.equal(WABotGate.threadContext(old, now, isBot).turns.length, 0, "idle chat starts fresh");
  // Limit keeps the last five.
  const long = [...Array(9).keys()].map(i => m(i % 2 === 0, `3:1${i} pm, 10/11/2026`, `t${i}`)).concat([m(false, "3:19 pm, 10/11/2026", "new")]);
  assert.deepEqual(WABotGate.threadContext(long, now, () => true).turns.map(t => t.text), ["t4", "t5", "t6", "t7", "t8"]);
  // Bot-to-bot: Prince's assistant and ours, three rounds since Nikhil typed.
  const loop = [m(true, "3:00 pm, 10/11/2026", "tu kr msg")];
  for (let i = 1; i <= 3; i++) {
    loop.push(m(false, `3:0${i} pm, 10/11/2026`, "Haan, main Prince ka assistant hoon"));
    loop.push(m(true, `3:0${i} pm, 10/11/2026`, "Nikhil's AI Assistant here"));
  }
  loop.push(m(false, "3:05 pm, 10/11/2026", "Prince ka assistant again"));
  assert.ok(WABotGate.threadContext(loop, now, isBot).botLoop, "three bot rounds stop");
  assert.ok(!WABotGate.threadContext([...loop.slice(0, 5), loop[loop.length - 1]], now, isBot).botLoop, "two rounds still allowed");
  // A human asking three questions in a row is not a loop.
  const human = [m(false, "3:01 pm, 10/11/2026", "update on datacap?"), m(true, "3:01 pm, 10/11/2026", "AI Assistant: ..."),
                 m(false, "3:02 pm, 10/11/2026", "produce pos?"), m(true, "3:02 pm, 10/11/2026", "AI Assistant: ..."),
                 m(false, "3:03 pm, 10/11/2026", "erp?"), m(true, "3:03 pm, 10/11/2026", "AI Assistant: ..."),
                 m(false, "3:04 pm, 10/11/2026", "bye")];
  assert.ok(!WABotGate.threadContext(human, now, isBot).botLoop);
  // The user typing resets the count.
  assert.ok(!WABotGate.threadContext([...loop, m(true, "3:06 pm, 10/11/2026", "ok stop"),
                                      m(false, "3:07 pm, 10/11/2026", "assistant hoon")], now, isBot).botLoop);

  // The 5:27 chat: sidebar already showed the datacap question, pane still ended at "Np".
  const pane = [m(false, "5:20 pm, 10/11/2026", "Np"), m(true, "5:21 pm, 10/11/2026", "try asking both again")];
  assert.ok(!WABotGate.showsLatest(pane, "And the datacap task for pos?"));
  assert.ok(WABotGate.showsLatest([...pane, m(false, "5:27 pm, 10/11/2026", "And the datacap task for pos?")], "And the datacap task for pos?"));
  assert.ok(WABotGate.showsLatest([...pane, m(false, null, "And the datacap task for pos? 5:27 pm")], "And the datacap task for pos…"),
    "truncated preview / trailing time still match");
  assert.ok(WABotGate.showsLatest(pane, ""), "nothing to check against");
});

test("calls agreed in chat", () => {
  const both = extractMarker("MEET", extractTask("Sure, I'll send a Meet link at 5:47.\n[[TASK: Call Shreyaa]]\n[[MEET: 20]]").body);
  assert.ok(both.body === "Sure, I'll send a Meet link at 5:47." && both.value === "20", JSON.stringify(both));
  assert.deepEqual(parseMeet("20"), { kind: "inMinutes", minutes: 20 });
  assert.deepEqual(parseMeet(" Cancel "), { kind: "cancel" });
  assert.ok(parseMeet("0") === null && parseMeet("721") === null, "outside 1 min..12 h");
  assert.ok(parseMeet("in a bit") === null && parseMeet(null) === null);
  assert.equal(extractMarker("MEET", "No call talk here.").value, null);
  assert.ok(containsMeetingLink("join here https://meet.google.com/abc-defg-hij"));
  assert.ok(containsMeetingLink("https://us02web.zoom.us/j/123456"));
  assert.ok(containsMeetingLink("https://teams.microsoft.com/l/meetup-join/x"));
  assert.ok(!containsMeetingLink("let's meet in 20 mins"));
  // No Google: a fresh, unguessable Jitsi room, which our own detector recognises.
  const j1 = GoogleSync.jitsiLink(), j2 = GoogleSync.jitsiLink();
  assert.ok(j1.startsWith("https://meet.jit.si/Nikxel-") && j1.length === 43 && j1 !== j2, j1);
  assert.ok(containsMeetingLink(j1));

  assert.equal(fingerprint("Hi 👋 there!"), fingerprint("Hi there"));
});

test("Devanagari romanization", () => {
  // Not in the Mac check; the README's own examples.
  assert.equal(Devanagari.romanize("कल"), "kal", "word-final schwa is dropped");
  assert.equal(Devanagari.romanize("फीचर"), "pheechar");
  assert.equal(Devanagari.romanize("ज़रूर"), "zaroor", "nukta turns j into z");
  assert.equal(Devanagari.romanize("meeting कल है"), "meeting kal hai", "Latin text untouched");
  assert.ok(!Devanagari.contains("plain English"));
});
