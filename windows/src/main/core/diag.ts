import { appendLine, nikxelPath } from "./paths";

const p = (n: number, w = 2) => String(n).padStart(w, "0");
function stamp(d = new Date()): string {
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ` +
    `${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}.${p(d.getMilliseconds(), 3)}`;
}

export const DEBUG_LOG = nikxelPath("debug.log");
export const CHATBOT_LOG = nikxelPath("chatbot.log");

/// Tiny file logger, ~/.nikxel/debug.log. Mirrors Diag.log.
export function diag(tag: string, msg: string): void {
  console.log(`[${tag}] ${msg}`);
  appendLine(DEBUG_LOG, `[${stamp()}] [${tag}] ${msg}`);
}

/// ~/.nikxel/chatbot.log. Mirrors cblog — the app-wide event log, despite the name.
export function cblog(msg: string): void {
  console.log(msg);
  appendLine(CHATBOT_LOG, `[${new Date().toISOString()}] ${msg}`);
}
