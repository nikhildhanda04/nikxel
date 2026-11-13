import type { WebContents } from "electron";
import { cblog } from "../core/diag";

/// Minimal Chrome DevTools Protocol client for Nikxel's own WhatsApp window.
///
/// Why CDP instead of synthetic DOM events:
///   - `Input.dispatchMouseEvent` and `Input.dispatchKeyEvent` send TRUSTED
///     events React accepts. No focus stealing, no clipboard hijack.
///   - Targets the page in the background. The window can stay hidden.
///
/// The Mac app spoke this protocol over a WebSocket to a separately launched
/// Chrome on port 9222. Here the page is an Electron BrowserWindow, so the
/// same methods go through `webContents.debugger` — no port, no external
/// browser. When the debugger can't attach (DevTools already holds it), the
/// calls fall back to the closest webContents API so the bot keeps working.
export class CDPClient {
  private loggedAttachFailure = false;

  constructor(private readonly wc: WebContents, private readonly userAgent: string) {
    wc.debugger.on("detach", (_e, reason) => {
      // Connection died. Next op reattaches.
      cblog(`CDP: debugger detached (${reason})`);
    });
  }

  /// Attaches if needed. False when another client holds the debugger.
  attach(): boolean {
    if (this.wc.isDestroyed()) return false;
    if (this.wc.debugger.isAttached()) return true;
    try {
      this.wc.debugger.attach("1.3");
    } catch (e) {
      if (!this.loggedAttachFailure) {
        this.loggedAttachFailure = true;
        cblog(`CDP: debugger attach failed (${e}); falling back to executeJavaScript`);
      }
      return false;
    }
    this.loggedAttachFailure = false;
    // No Runtime.enable: Runtime.evaluate works without it, and with it on
    // DevTools keeps every object WhatsApp Web logs to the console alive
    // and streams each console call over the socket, all day.
    // A hidden window never has OS focus. Emulating it keeps `focus()` and
    // `document.hasFocus()` behaving as they did in a background Chrome tab,
    // so the message box accepts inserted text.
    void this.send("Emulation.setFocusEmulationEnabled", { enabled: true }, 2000);
    // The UA string alone isn't enough: client hints would still say
    // "Electron" isn't Chrome. Present as the desktop Chrome we already claim.
    const major = (process.versions.chrome ?? "").split(".")[0] || "146";
    void this.send("Emulation.setUserAgentOverride", {
      userAgent: this.userAgent,
      userAgentMetadata: {
        brands: [
          { brand: "Google Chrome", version: major },
          { brand: "Chromium", version: major },
          { brand: "Not_A Brand", version: "24" },
        ],
        fullVersion: `${major}.0.0.0`,
        platform: "Windows",
        platformVersion: "10.0.0",
        architecture: "x86",
        model: "",
        mobile: false,
        bitness: "64",
      },
    }, 2000);
    return true;
  }

  get isConnected(): boolean { return !this.wc.isDestroyed(); }

  /// Sends one command. Resolves to the result, or null on error/timeout —
  /// the same contract as the Mac client's sendSync.
  async send(method: string, params: Record<string, unknown> = {}, timeoutMs = 5000): Promise<any | null> {
    if (this.wc.isDestroyed() || !this.wc.debugger.isAttached()) return null;
    let timer: NodeJS.Timeout | undefined;
    try {
      return await Promise.race([
        this.wc.debugger.sendCommand(method, params),
        new Promise<null>(resolve => { timer = setTimeout(() => resolve(null), timeoutMs); }),
      ]);
    } catch {
      return null;
    } finally {
      if (timer) clearTimeout(timer);
    }
  }

  // MARK: - Convenience: Runtime.evaluate

  /// Evaluate JS in the page. Returns the result's string value, or null on
  /// error. `returnByValue:true` ensures we get a serializable JSON-able
  /// primitive back (string / number / object) rather than a remote handle.
  async eval(expression: string): Promise<string | null> {
    if (this.wc.isDestroyed()) return null;
    let value: unknown;
    if (this.attach()) {
      const result = await this.send("Runtime.evaluate", { expression, returnByValue: true, awaitPromise: true });
      if (!result || typeof result !== "object") return null;
      const obj = (result as any).result;
      if (!obj || typeof obj !== "object" || !("value" in obj)) return null;
      value = obj.value;
    } else {
      let timer: NodeJS.Timeout | undefined;
      try {
        value = await Promise.race([
          this.wc.executeJavaScript(expression, true),
          new Promise<undefined>(resolve => { timer = setTimeout(() => resolve(undefined), 5000); }),
        ]);
      } catch {
        return null;
      } finally {
        if (timer) clearTimeout(timer);
      }
    }
    if (value === undefined || value === null) return null;
    if (typeof value === "string") return value;
    try { return JSON.stringify(value); } catch { return String(value); }
  }

  // MARK: - Convenience: Input.dispatchMouseEvent

  /// Click at viewport-relative (x, y). `clickCount: 1` triggers React. CDP
  /// auto-dispatches pressed→released; we do both halves so React sees a
  /// full press cycle.
  async clickAt(x: number, y: number): Promise<void> {
    if (this.attach()) {
      const common = { x, y, button: "left", clickCount: 1 };
      await this.send("Input.dispatchMouseEvent", { ...common, type: "mousePressed" });
      await this.send("Input.dispatchMouseEvent", { ...common, type: "mouseReleased" });
      return;
    }
    if (this.wc.isDestroyed()) return;
    const ix = Math.round(x), iy = Math.round(y);
    this.wc.sendInputEvent({ type: "mouseDown", x: ix, y: iy, button: "left", clickCount: 1 });
    this.wc.sendInputEvent({ type: "mouseUp", x: ix, y: iy, button: "left", clickCount: 1 });
  }

  // MARK: - Convenience: Input.insertText

  /// Insert literal text into the focused element. Equivalent to typing
  /// without going through individual key codes — works with Lexical /
  /// React contenteditables.
  async insertText(text: string): Promise<void> {
    if (this.attach()) {
      await this.send("Input.insertText", { text });
      return;
    }
    if (!this.wc.isDestroyed()) await this.wc.insertText(text).catch(() => {});
  }

  /// Press the Enter key. Windows virtual-key code 13 (VK_RETURN).
  async pressEnter(): Promise<void> {
    if (this.attach()) {
      const key = { key: "Enter", code: "Enter", windowsVirtualKeyCode: 13, nativeVirtualKeyCode: 13 };
      await this.send("Input.dispatchKeyEvent", { ...key, type: "keyDown" });
      await this.send("Input.dispatchKeyEvent", { ...key, type: "keyUp" });
      return;
    }
    if (this.wc.isDestroyed()) return;
    this.wc.sendInputEvent({ type: "keyDown", keyCode: "Enter" });
    this.wc.sendInputEvent({ type: "keyUp", keyCode: "Enter" });
  }
}
