// npm run build && node scripts/check-mail-intent.js — same cases as checks/check_mail_intent.swift.
const m = require("../dist/main/google/mailIntent.js");
let fails = 0;
const check = (ok, what) => { if (!ok) { fails++; console.log("FAIL: " + what); } };

check(m.looksLikeMail("any mail from Piyush?"), "mail question");
check(m.looksLikeMail("reply to the invoice email"), "reply");
check(!m.looksLikeMail("what did I do today"), "not mail");
check(m.isSendCommand("send it"), "send it");
check(m.isSendCommand("Ok, send it now."), "ok send it now");
check(m.isSendCommand("yes send the draft"), "send the draft");
check(!m.isSendCommand("send Piyush the invoice"), "not a send command");

const s = m.parseAction('```json\n{"action":"search","query":"from:piyush"}\n```');
check(s.kind === "search" && s.query === "from:piyush", "fenced search");
check(m.parseAction("Sure! Here you go.").kind === "answer", "prose -> answer");
const d = m.parseAction('{"action":"draft","to":"a@b.com","cc":"","subject":"Hi","body":"Hello","replyTo":"18c"}');
check(d.kind === "draft" && d.draft.to === "a@b.com" && d.draft.subject === "Hi" && d.draft.body === "Hello" && d.draft.replyTo === "18c", "draft fields");
const l = m.parseAction('{"action":"label","ids":["1","2"],"op":"archive"}');
check(l.kind === "label" && l.ids.join() === "1,2" && l.op === "archive", "label");

const text = Buffer.from(m.rawMessage({ to: "a@b.com", cc: "", subject: "₹ invoice", body: "नमस्ते 👋", replyTo: null }, "<x@y>", null), "base64url").toString("utf8");
check(text.includes("Subject: =?UTF-8?B?"), "subject encoded");
check(text.includes("In-Reply-To: <x@y>") && text.includes("References: <x@y>"), "reply headers");
const body = text.split("\r\n\r\n").pop().replace(/\r\n/g, "");
check(Buffer.from(body, "base64").toString("utf8") === "नमस्ते 👋", "body round-trip");

console.log(fails ? `${fails} FAILED` : "ALL PASS");
process.exit(fails ? 1 : 0);
