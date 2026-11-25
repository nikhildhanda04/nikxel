// Checks which WhatsApp chats a chat question opens (same cases as checks/check_wa_chat_match.swift).
import { test } from "node:test";
import * as assert from "node:assert/strict";
import { day, named } from "../main/whatsapp/waChatMatch";

const chats = ["Nikxel Product Updates", "piyush co-founder forklyft", "Raj", "Family Group", "Dev Team"];

test("named chats", () => {
  assert.deepEqual(named("what did piyush say in the nikxel whatsapp group", chats), ["Nikxel Product Updates", "piyush co-founder forklyft"]);
  assert.deepEqual(named("what did Raj say about the nikxel build?", chats), ["Raj"]);
  assert.deepEqual(named("summarise my nikxel meeting", chats), []);
  assert.deepEqual(named("any messages in the group today?", chats), []);
  assert.deepEqual(named("what did they say", []), []);
});

test("the day a question asks about", () => {
  const now = new Date(2026, 10, 25, 15), d = (y: number, m: number, x: number) => new Date(y, m - 1, x).getTime();
  const at = (q: string) => day(q, now)?.getTime() ?? null;
  assert.equal(at("can you check yestaradys msgs"), d(2026, 11, 24));
  assert.equal(at("what did he say about wic on 24th"), d(2026, 11, 24));
  assert.equal(at("what was said on 3"), d(2026, 11, 3));
  assert.equal(at("messages from 28th"), d(2026, 10, 28));
  assert.equal(at("what did raj say on 2nd dec"), d(2025, 12, 2));
  assert.equal(at("what did raj say nov 20"), d(2026, 11, 20));
  assert.equal(at("messages from 2 days ago"), d(2026, 11, 23));
  assert.equal(at("what did they say on monday"), d(2026, 11, 23));
  assert.equal(at("what did they say today"), d(2026, 11, 25));
  assert.equal(at("call at 5 pm, 2026 plans"), null);
  assert.equal(at("what did he say"), null);
  assert.deepEqual(named("can you check yesterdays msgs and find what he said", ["Find My Phone", "About Town"]), []);
});
