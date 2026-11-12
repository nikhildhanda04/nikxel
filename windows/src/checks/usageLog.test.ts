// Per-kind usage totals and the daily average. Port of check_usage_log.swift.
import { test } from "node:test";
import * as assert from "node:assert/strict";
import * as fs from "fs";
import * as os from "os";
import * as path from "path";
import { UsageLog } from "../main/recording/usageLog";

test("usage totals and daily average", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "nikxel-usage-"));
  try {
    const now = new Date(2026, 10, 10, 12);
    const day = (n: number) => new Date(2026, 10, 10 - n, 12);
    const run = (tokens: number, cost: number) => JSON.stringify({
      result: "hi", total_cost_usd: cost,
      usage: { input_tokens: 2, output_tokens: 8, cache_read_input_tokens: tokens - 10, cache_creation_input_tokens: 0 },
    });

    UsageLog.record("whatsapp", run(1000, 0.01), dir, now);
    UsageLog.record("whatsapp", run(2000, 0.02), dir, now);
    UsageLog.record("daily-summary", run(5000, 0.10), dir, now);
    UsageLog.record("whatsapp", "not json", dir, now);
    const t = UsageLog.totals(now, dir);
    assert.equal(t.whatsapp.calls, 2);
    assert.equal(t.whatsapp.tokens, 3000);
    assert.ok(Math.abs(t.whatsapp.cost - 0.03) < 1e-9);
    assert.equal(t["daily-summary"].calls, 1);

    // Average skips empty days and excludes today: days 1 and 3 only.
    UsageLog.record("whatsapp", run(4000, 0.04), dir, day(1));
    UsageLog.record("whatsapp", run(2000, 0.02), dir, day(3));
    const { avg, days } = UsageLog.dailyAverage(7, dir, now);
    assert.equal(days, 2);
    assert.equal(avg.tokens, 3000);
    assert.equal(avg.calls, 1);
    assert.ok(Math.abs(avg.cost - 0.03) < 1e-9);
    assert.equal(UsageLog.dailyAverage(7, path.join(dir, "none"), now).days, 0);
    assert.equal(UsageLog.line({ calls: 1, tokens: 37400, cost: 0.041 }), "$0.041 · 37k tokens · 1 call");
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
