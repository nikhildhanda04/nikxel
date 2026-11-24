import type { UiohookKeyboardEvent, UiohookMouseEvent } from "uiohook-napi";
import { StateMachine } from "../core/stateMachine";
import { diag } from "../core/diag";

type Hook = typeof import("uiohook-napi").uIOhook;

/// Port of InputHandler.swift: a global key-down hook that makes Nikxel type
/// along with the user. The Mac needed an Accessibility grant and a CGEvent
/// tap (plus polling until the grant arrived); Windows needs neither, a
/// low-level keyboard hook through uiohook-napi just works.
///
/// The hook only sees that a key went down, never which one: nothing is
/// logged or kept. Left presses and releases go to the avatar too, so it can
/// still be picked up when Windows doesn't deliver a click to its window.
export class InputHandler {
  private hook: Hook | null = null;
  private readonly onKeyDown = (_e: UiohookKeyboardEvent) => {
    this.stateMachine.triggerTyping();
    this.onKeystroke();
  };

  // Button 1 is the left button.
  private readonly onMouseDown = (e: UiohookMouseEvent) => { if (e.button === 1) this.mouse.down(); };
  private readonly onMouseUp = (e: UiohookMouseEvent) => { if (e.button === 1) this.mouse.up(); };

  constructor(private readonly stateMachine: StateMachine, private readonly onKeystroke: () => void,
              private readonly mouse: { down(): void; up(): void }) {}

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
      hook.on("mousedown", this.onMouseDown);
      hook.on("mouseup", this.onMouseUp);
      hook.start();
      this.hook = hook;
      diag("input", "keyboard hook started");
    } catch (e) {
      hook.removeListener("keydown", this.onKeyDown);
      hook.removeListener("mousedown", this.onMouseDown);
      hook.removeListener("mouseup", this.onMouseUp);
      diag("input", `keyboard hook failed to start: ${e}`);
    }
  }

  stopMonitoring(): void {
    const hook = this.hook;
    if (!hook) return;
    this.hook = null;
    hook.removeListener("keydown", this.onKeyDown);
    hook.removeListener("mousedown", this.onMouseDown);
    hook.removeListener("mouseup", this.onMouseUp);
    try { hook.stop(); } catch (e) { diag("input", `keyboard hook stop failed: ${e}`); }
  }
}
