import * as fs from "fs";
import * as path from "path";
import { dayStamp, ensureDir, nikxelPath } from "../core/paths";

/// Port of UsageLog.swift.
///
/// Tokens and dollars spent on Claude Code runs, one JSON line per run in
/// ~/.nikxel/usage/YYYY-MM-DD.jsonl. Read back for the tray's usage line.
/// Only Claude Code reports cost in its output; opencode/codex runs aren't logged.

export interface UsageTotals { calls: number; tokens: number; cost: number }

const empty = (): UsageTotals => ({ calls: 0, tokens: 0, cost: 0 });
const int = (v: unknown): number => (typeof v === "number" && Number.isFinite(v) ? Math.trunc(v) : 0);
const num = (v: unknown): number => (typeof v === "number" && Number.isFinite(v) ? v : 0);

const usageDir = (): string => nikxelPath("usage");

export const UsageLog = {
  get directory(): string { return usageDir(); },

  /// Records one `claude -p --output-format json` result. Anything that
  /// isn't that shape is ignored rather than logged as a zero.
  record(kind: string, agentJsonOutput: string, dir: string = usageDir(), now: Date = new Date()): void {
    let obj: any;
    try { obj = JSON.parse(agentJsonOutput); } catch { return; }
    if (!obj || typeof obj !== "object" || Array.isArray(obj)) return;
    const usage = obj.usage;
    if (!usage || typeof usage !== "object") return;
    const tokens = ["input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"]
      .reduce((sum, k) => sum + int(usage[k]), 0);
    const modelUsage = obj.modelUsage && typeof obj.modelUsage === "object" ? Object.keys(obj.modelUsage).sort().join(",") : "";
    const entry = {
      t: now.getTime() / 1000,
      kind,
      model: modelUsage,
      tokens,
      cost: num(obj.total_cost_usd),
      ms: int(obj.duration_ms),
    };
    try {
      ensureDir(dir);
      fs.appendFileSync(path.join(dir, `${dayStamp(now)}.jsonl`), JSON.stringify(entry) + "\n");
    } catch { /* usage logging must never break a run */ }
  },

  /// Per-kind totals for one day ("whatsapp", "daily-summary", "meeting", "notes").
  totals(day: Date, dir: string = usageDir()): Record<string, UsageTotals> {
    let content: string;
    try { content = fs.readFileSync(path.join(dir, `${dayStamp(day)}.jsonl`), "utf8"); } catch { return {}; }
    const out: Record<string, UsageTotals> = {};
    for (const line of content.split("\n")) {
      if (!line.trim()) continue;
      let obj: any;
      try { obj = JSON.parse(line); } catch { continue; }
      if (!obj || typeof obj.kind !== "string") continue;
      const t = (out[obj.kind] ??= empty());
      t.calls += 1;
      t.tokens += int(obj.tokens);
      t.cost += num(obj.cost);
    }
    return out;
  },

  /// Average per day over the `days` days before `now`, counting only days
  /// with any usage -- a week the PC was off shouldn't drag the average to zero.
  dailyAverage(days = 7, dir: string = usageDir(), now: Date = new Date()): { avg: UsageTotals; days: number } {
    const sum = empty();
    let counted = 0;
    for (let offset = 1; offset <= days; offset++) {
      const d = new Date(now);
      d.setDate(d.getDate() - offset);
      const day = Object.values(UsageLog.totals(d, dir));
      if (day.length === 0) continue;
      counted += 1;
      for (const t of day) { sum.calls += t.calls; sum.tokens += t.tokens; sum.cost += t.cost; }
    }
    if (counted === 0) return { avg: empty(), days: 0 };
    return {
      avg: { calls: Math.trunc(sum.calls / counted), tokens: Math.trunc(sum.tokens / counted), cost: sum.cost / counted },
      days: counted,
    };
  },

  /// "$0.041 · 37k tokens · 12 calls"
  line(t: UsageTotals): string {
    const tok = t.tokens >= 1000 ? `${Math.trunc(t.tokens / 1000)}k` : `${t.tokens}`;
    return `$${t.cost.toFixed(3)} · ${tok} tokens · ${t.calls} call${t.calls === 1 ? "" : "s"}`;
  },
};
