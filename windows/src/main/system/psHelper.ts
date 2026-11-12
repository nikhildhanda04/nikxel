import { ChildProcess } from "child_process";
import { spawnProcess, killTree } from "../core/proc";
import { diag } from "../core/diag";

/// The line a helper script prints after each answer. Anything before it is
/// the answer, so an answer can span several lines.
export const PS_END = "<<NIKXEL-END>>";

/// A PowerShell process that stays up and answers one request per line on
/// stdin. Starting powershell.exe costs ~300 ms of CPU and a few hundred ms
/// more for any Add-Type, so a sampler that ran every few seconds as a fresh
/// process would be the heaviest thing Nikxel does. One process, one pipe.
///
/// `script` is the loop body's setup plus a `while` loop that reads
/// `[Console]::In.ReadLine()`, writes its answer and then `PS_END`. Requests
/// are serialised: a second one waits for the first answer. A request that
/// takes longer than its timeout kills the helper; the next request starts a
/// fresh one.
export class PSHelper {
  private child: ChildProcess | null = null;
  private buf = "";
  private pending: { resolve: (s: string | null) => void; timer: NodeJS.Timeout } | null = null;
  private queue: Promise<unknown> = Promise.resolve();
  private failures = 0;
  private retryAfter = 0;

  constructor(private readonly name: string, private readonly script: string) {}

  /// Sends `line` and resolves with the answer, or null when the helper
  /// couldn't start, died, or timed out.
  request(line: string, timeoutMs = 10_000): Promise<string | null> {
    const next = this.queue.then(() => this.send(line, timeoutMs));
    this.queue = next.catch(() => null);
    return next;
  }

  stop(): void {
    const c = this.child;
    this.child = null;
    if (c) {
      try { c.stdin?.end(); } catch { /* already gone */ }
      killTree(c);
    }
    this.finish(null);
  }

  private ensure(): ChildProcess | null {
    if (this.child && this.child.exitCode === null && !this.child.killed) return this.child;
    if (Date.now() < this.retryAfter) return null;
    // UTF-8 both ways: window titles and command lines are full Unicode, and
    // PowerShell 5.1 otherwise writes in the console's OEM code page.
    // Setting a console encoding can throw when there's no console to set
    // it on; the answers are then ASCII-safe JSON or plain names anyway.
    const prelude = "$ErrorActionPreference = 'SilentlyContinue'\n" +
      "try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch { }\n" +
      "try { [Console]::InputEncoding = New-Object System.Text.UTF8Encoding $false } catch { }\n";
    const encoded = Buffer.from(prelude + this.script, "utf16le").toString("base64");
    let child: ChildProcess;
    try {
      child = spawnProcess("powershell.exe",
        ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-EncodedCommand", encoded],
        { stdio: ["pipe", "pipe", "pipe"] });
    } catch (e) {
      this.noteFailure(`spawn threw: ${e}`);
      return null;
    }
    this.buf = "";
    child.stdout?.setEncoding("utf8");
    child.stdout?.on("data", (d: string) => this.onData(d));
    child.stderr?.on("data", () => { /* errors are swallowed in-script; ignore stray noise */ });
    child.stdin?.on("error", () => { /* helper exited before reading */ });
    child.on("error", err => { this.noteFailure(`${err}`); if (this.child === child) this.child = null; this.finish(null); });
    child.on("exit", code => {
      if (this.child === child) { this.child = null; this.noteFailure(`exited with ${code}`); }
      this.finish(null);
    });
    this.child = child;
    return child;
  }

  /// Backs off after repeated failures so a machine where PowerShell is
  /// blocked (AppLocker, a broken install) isn't hammered every tick.
  private noteFailure(why: string): void {
    this.failures += 1;
    diag("ps", `${this.name} helper: ${why}`);
    if (this.failures >= 3) this.retryAfter = Date.now() + Math.min(300_000, 10_000 * this.failures);
  }

  private send(line: string, timeoutMs: number): Promise<string | null> {
    return new Promise(resolve => {
      const child = this.ensure();
      if (!child?.stdin) { resolve(null); return; }
      const timer = setTimeout(() => {
        diag("ps", `${this.name} helper timed out; restarting`);
        this.stop();
      }, timeoutMs);
      this.pending = { resolve, timer };
      try {
        child.stdin.write(line.replace(/[\r\n]/g, " ") + "\n");
      } catch {
        this.finish(null);
      }
    });
  }

  private onData(d: string): void {
    this.buf += d;
    for (;;) {
      const i = this.buf.indexOf(PS_END);
      if (i < 0) break;
      const answer = this.buf.slice(0, i).replace(/\r/g, "").replace(/^\n+|\n+$/g, "");
      this.buf = this.buf.slice(i + PS_END.length).replace(/^\r?\n/, "");
      this.failures = 0;
      this.finish(answer);
    }
  }

  private finish(answer: string | null): void {
    const p = this.pending;
    if (!p) return;
    this.pending = null;
    clearTimeout(p.timer);
    p.resolve(answer);
  }
}
