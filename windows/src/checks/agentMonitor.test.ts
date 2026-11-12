// Checks which processes count as a coding agent at work. The Mac matched
// " name" in a `ps aux` line; Windows matches image names and, for node/bun,
// the script path, since npm-installed agents all run as node.exe.
import { test } from "node:test";
import * as assert from "node:assert/strict";
import { AgentMonitor } from "../main/system/agentMonitor";

test("agent process matching", () => {
  const m = AgentMonitor.matchAgent;
  assert.equal(m("claude.exe", ""), "claude", "native Claude Code");
  assert.equal(m("opencode.exe", ""), "opencode");
  assert.equal(m("codex-x86_64-pc-windows-msvc.exe", ""), "codex");
  assert.equal(m("cursor-agent.exe", ""), "cursor");
  assert.equal(m("node.exe", `"C:\\Program Files\\nodejs\\node.exe" C:\\Users\\me\\AppData\\Roaming\\npm\\node_modules\\@anthropic-ai\\claude-code\\cli.js --resume`), "claude");
  assert.equal(m("node.exe", `node "C:\\Users\\me\\AppData\\Roaming\\npm\\node_modules\\@openai\\codex\\bin\\codex.js"`), "codex");
  // GUI apps are capitalised, like Cursor.app on the Mac, and stay out.
  assert.equal(m("Cursor.exe", ""), null);
  assert.equal(m("Claude.exe", ""), null);
  assert.equal(m("Kiro.exe", ""), null);
  // Other node work isn't an agent.
  assert.equal(m("node.exe", `node C:\\projects\\site\\node_modules\\vite\\bin\\vite.js --port 3000`), null);
  assert.equal(m("node.exe", ""), null);
  assert.equal(m("Code.exe", ""), null);
});
