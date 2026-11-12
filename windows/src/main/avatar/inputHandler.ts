import type { UiohookKeyboardEvent } from "uiohook-napi";
import { StateMachine } from "../core/stateMachine";
import { diag } from "../core/diag";

type Hook = typeof import("uiohook-napi").uIOhook;

/// Port of InputHandler.swift: a global key-down hook that makes Nikxel type
/// along with the user. The Mac needed an Accessibility grant and a CGEvent
/// tap (plus polling until the grant arrived); Windows needs neither, a
/// low-level keyboard hook through uiohook-napi just works.
///
/// The hook only sees that a key went down, never which one: nothing is
/// logged or kept.
export class InputHandler {
  private hook: Hook | null = null;
  private readonly onKeyDown = (_e: UiohookKeyboardEvent) => {
    this.stateMachine.triggerTyping();
    this.onKeystroke();
  };

  constructor(private readonly stateMachine: StateMachine, private readonly onKeystroke: () => void) {}

  startMonitoring(): void {
    if (this.hook) return;
    let hook: Hook;
    try {
      // Loaded lazily: a native module that fails to load (missing VC++
      // runtime, wrong ABI after an Electron bump) must cost the typing
      // animation, not the whole app.
      // eslint-disable-next-line @typescript-eslint/no-var-requires
      hook = (require("uiohook-napi") as typeof import("uiohook-napi")).uIOhook;
    } catch (e) {
      diag("input", `uiohook-napi failed to load, no typing animation: ${e}`);
      return;
    }
    try {
      hook.on("keydown", this.onKeyDown);
      hook.start();
      this.hook = hook;
      diag("input", "keyboard hook started");
    } catch (e) {
      hook.removeListener("keydown", this.onKeyDown);
      diag("input", `keyboard hook failed to start: ${e}`);
    }
  }

  stopMonitoring(): void {
    const hook = this.hook;
    if (!hook) return;
    this.hook = null;
    hook.removeListener("keydown", this.onKeyDown);
    try { hook.stop(); } catch (e) { diag("input", `keyboard hook stop failed: ${e}`); }
  }
}
