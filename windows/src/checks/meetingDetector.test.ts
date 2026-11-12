// Checks the Windows meeting-detection rules: which windows and microphone
// users count as "in a meeting". The Mac detector had no check; this covers
// the parts that are new on Windows plus the Meet title rules carried over.
import { test } from "node:test";
import * as assert from "node:assert/strict";
import { detectMeeting, isMeetTitle, isMeetingMicUser, isZoomMeetingWindow } from "../main/whatsapp/meetingDetector";

test("Google Meet in a browser: same title rules as the Mac", () => {
  assert.ok(isMeetTitle("Meet - abc-defg-hij - Google Chrome"));
  assert.ok(isMeetTitle("Google Meet - Personal - Microsoft Edge"));
  assert.ok(isMeetTitle("https://meet.google.com/abc-defg-hij"));
  assert.ok(!isMeetTitle("Inbox (3) - Gmail - Google Chrome"));
  assert.ok(!isMeetTitle("Let's meet tomorrow - Notepad"));

  const win = (proc: string, title: string) => ({ windows: [{ proc, title }], mic: [] });
  assert.ok(detectMeeting(win("chrome", "Meet - abc-defg-hij - Google Chrome")));
  assert.ok(detectMeeting(win("msedge", "Meet - abc-defg-hij and 2 more pages - Personal - Microsoft Edge")));
  // Only browsers: the Mac looked at browser windows alone, and a document
  // titled "Google Meet notes" is not a call.
  assert.ok(!detectMeeting(win("notepad", "Google Meet notes.txt - Notepad")));
  assert.ok(!detectMeeting({ windows: [], mic: [] }));
});

test("native meeting apps holding the microphone", () => {
  assert.ok(isMeetingMicUser("C:#Users#asha#AppData#Roaming#Zoom#bin#Zoom.exe"));
  assert.ok(isMeetingMicUser("C:#Users#asha#AppData#Local#Microsoft#Teams#current#Teams.exe"));
  assert.ok(isMeetingMicUser("MSTeams_8wekyb3d8bbwe"));
  // Nikxel's own recorder, a browser, or a voice recorder: not a meeting by itself.
  assert.ok(!isMeetingMicUser("C:#Users#asha#AppData#Local#Programs#Nikxel#Nikxel.exe"));
  assert.ok(!isMeetingMicUser("C:#Program Files#Google#Chrome#Application#chrome.exe"));
  assert.ok(!isMeetingMicUser("Microsoft.WindowsSoundRecorder_8wekyb3d8bbwe"));
  // A folder that happens to say "teams" doesn't make its exe a meeting app.
  assert.ok(!isMeetingMicUser("C:#Users#asha#teams-tools#recorder.exe"));

  assert.ok(detectMeeting({ windows: [], mic: ["C:#Program Files#Zoom#bin#Zoom.exe"] }));
  assert.ok(!detectMeeting({ windows: [{ proc: "ms-teams", title: "Chat | Microsoft Teams" }], mic: [] }),
    "Teams merely open is not a call");
});

test("Zoom's in-call window", () => {
  assert.ok(isZoomMeetingWindow("Zoom", "Zoom Meeting"));
  assert.ok(isZoomMeetingWindow("zoom", "Zoom Webinar"));
  assert.ok(!isZoomMeetingWindow("Zoom", "Zoom Workplace"));
  assert.ok(!isZoomMeetingWindow("chrome", "Zoom Meeting"));
});
