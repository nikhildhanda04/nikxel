// Checks which WhatsApp chats a chat question opens (same cases as checks/check_wa_chat_match.swift).
import { test } from "node:test";
import * as assert from "node:assert/strict";
import { named } from "../main/whatsapp/waChatMatch";

const chats = ["Nikxel Product Updates", "piyush co-founder forklyft", "Raj", "Family Group", "Dev Team"];

test("named chats", () => {
  assert.deepEqual(named("what did piyush say in the nikxel whatsapp group", chats), ["Nikxel Product Updates", "piyush co-founder forklyft"]);
  assert.deepEqual(named("what did Raj say about the nikxel build?", chats), ["Raj"]);
  assert.deepEqual(named("summarise my nikxel meeting", chats), []);
  assert.deepEqual(named("any messages in the group today?", chats), []);
  assert.deepEqual(named("what did they say", []), []);
});
