import * as path from "path";
import { StateMachine } from "../core/stateMachine";
import { isWin } from "../core/paths";
import { run } from "../core/proc";
import { desktopRequest, stopDesktopHelper } from "./desktopHelper";

/// One candidate process from a poll: cumulative CPU seconds on Windows,
/// ps's own %cpu elsewhere.
interface ProcInfo { pid: number; image: string; cmd: string; cpuSeconds?: number; pct?: number }

/// Watches for a coding agent working in a terminal and flips the avatar to
/// "thinking" while it burns CPU, then "done" when it settles. Port of
/// OpenCodeMonitor.swift (which defines AgentMonitor).
///
/// The Mac version ran `ps aux` and `ps -p <pid> -o %cpu=` every 1.5 s. On
/// Windows that would be two process spawns per tick, so the long-lived
/// PowerShell in desktopHelper answers each tick instead: Get-Process for the candidates and
/// their CPU seconds, plus the command line (Win32_Process, cached per pid)
/// for node.exe and bun.exe — Claude Code, Codex and OpenCode installed with
/// npm all run as node.exe, so the image name alone says nothing.
export class AgentMonitor {
  private timer: NodeJS.Timeout | null = null;
  private lastActive: number | null = null;
  private lastPid: number | null = null;
  private currentAgent: string | null = null;
  private busy = false;
  /// pid -> (CPU seconds, when) from the previous poll, to turn the
  /// cumulative CPU time Windows reports into a percentage.
  private prevCpu = new Map<number, { cpu: number; at: number }>();

  static readonly agentNames = ["opencode", "claude", "claude-code", "codex", "cursor", "antigravity", "kiro"];

  constructor(private readonly stateMachine: StateMachine) {}

  startMonitoring(): void {
    if (this.timer) return;
    this.timer = setInterval(() => this.check(), 2000);
    this.check();
  }

  stopMonitoring(): void {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
    stopDesktopHelper();
  }

  private async check(): Promise<void> {
    // A slow poll (a cold PowerShell start) must not stack ticks behind it.
    if (this.busy) return;
    this.busy = true;
    try {
      const found = await this.findAgent();
      const sm = this.stateMachine;
      if (!found) {
        this.lastActive = null; this.lastPid = null; this.currentAgent = null;
        if (sm.state === "thinking" || sm.state === "done") sm.setState("idle");
        return;
      }
      this.lastPid = found.pid; this.currentAgent = found.name;
      const cpuActive = found.cpu > 12.0;

      if (cpuActive) {
        this.lastActive = Date.now();
        if (sm.state !== "thinking") sm.setState("thinking");
      } else if (this.lastActive !== null) {
        if (Date.now() - this.lastActive >= 3000) {
          if (sm.state === "thinking") sm.triggerDone();
          this.lastActive = null;
        }
      }
    } finally {
      this.busy = false;
    }
  }

  /// The agent name a process belongs to, or null. Mirrors the Mac's
  /// " name" match on a `ps aux` line: a word that *starts* with the agent
  /// name, case-sensitively. That keeps the GUI apps out (Cursor.exe,
  /// Kiro.exe, Claude.exe are capitalised, like Cursor.app on the Mac) while
  /// catching the CLIs (claude.exe, cursor-agent, codex-x86_64-...exe).
  /// For node/bun, every path segment of the command line counts, because
  /// the agent's name is in the script path:
  /// `node ...\node_modules\@anthropic-ai\claude-code\cli.js`.
  static matchAgent(imageName: string, commandLine: string): string | null {
    const image = imageName.replace(/\.exe$/i, "");
    const starts = (word: string) => AgentMonitor.agentNames.find(n => word.startsWith(n)) ?? null;
    const direct = starts(image);
    if (direct) return direct;
    if (!/^(node|bun)$/i.test(image) || !commandLine) return null;
    const words = commandLine.replace(/"/g, " ").split(/\s+/).filter(Boolean);
    // Skip the first word: it's node.exe itself.
    for (const w of words.slice(1)) {
      if (w.startsWith("-")) continue;
      for (const seg of w.split(/[\\/]/)) {
        const m = starts(seg.replace(/\.(js|cjs|mjs|exe|cmd|ts)$/i, ""));
        if (m) return m;
      }
    }
    return null;
  }

  private async findAgent(): Promise<{ pid: number; name: string; cpu: number } | null> {
    const procs: ProcInfo[] | null = isWin ? await this.pollWindows() : await this.pollPs();
    if (!procs) return null;
    const now = Date.now();
    const seen = new Set<number>();
    let best: { pid: number; name: string; cpu: number } | null = null;
    for (const p of procs) {
      const name = AgentMonitor.matchAgent(p.image, p.cmd);
      if (!name) continue;
      seen.add(p.pid);
      let cpu = p.pct ?? 0;
      if (p.cpuSeconds !== undefined) {
        const prev = this.prevCpu.get(p.pid);
        this.prevCpu.set(p.pid, { cpu: p.cpuSeconds, at: now });
        // Percent of one core, like ps's %cpu. A pid seen for the first time
        // has no baseline yet and reads as idle for one tick.
        if (prev && now > prev.at) cpu = Math.max(0, (p.cpuSeconds - prev.cpu) / ((now - prev.at) / 1000) * 100);
      }
      // One agent is often several processes (node + its native helper +
      // shells it started). Whichever is busiest speaks for it; ps aux's
      // first-match order has no equivalent here.
      if (!best || cpu > best.cpu) best = { pid: p.pid, name, cpu };
    }
    for (const pid of [...this.prevCpu.keys()]) if (!seen.has(pid)) this.prevCpu.delete(pid);
    return best;
  }

  private async pollWindows(): Promise<ProcInfo[] | null> {
    const out = await desktopRequest("agent", 15_000);
    if (out === null) return null;
    const procs: ProcInfo[] = [];
    for (const line of out.split("\n")) {
      const cols = line.split("\t");
      if (cols.length < 3) continue;
      const pid = parseInt(cols[0], 10);
      if (!Number.isFinite(pid)) continue;
      procs.push({ pid, cpuSeconds: parseFloat(cols[1]) || 0, image: cols[2], cmd: cols.slice(3).join("\t") });
    }
    return procs;
  }

  /// Non-Windows dev runs: the Mac's own `ps`.
  private async pollPs(): Promise<ProcInfo[] | null> {
    const r = await run("ps", ["-axo", "pid=,%cpu=,command="], { timeoutMs: 5000 });
    if (r.code !== 0) return null;
    const procs: ProcInfo[] = [];
    for (const line of r.stdout.split("\n")) {
      const m = line.trim().match(/^(\d+)\s+([\d.]+)\s+(.*)$/);
      if (!m || m[3].includes("grep")) continue;
      const exe = m[3].split(/\s+/)[0];
      procs.push({ pid: +m[1], pct: +m[2], image: path.basename(exe), cmd: m[3] });
    }
    return procs;
  }
}
