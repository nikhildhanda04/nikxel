import { EventEmitter } from "events";

export type NikxelState =
  | "idle" | "walk" | "typing" | "thinking" | "done" | "dragging" | "pounce" | "petted"
  | "alert" | "recording" | "momReady" | "writingMOM";

/// Port of StateMachine.swift. Emits "state" (NikxelState) on every change.
export class StateMachine extends EventEmitter {
  private _state: NikxelState = "idle";
  position = { x: 0, y: 0 };

  private typingTimer?: NodeJS.Timeout;
  private doneTimer?: NodeJS.Timeout;
  private pounceTimer?: NodeJS.Timeout;
  private pettedTimer?: NodeJS.Timeout;
  private alertTimer?: NodeJS.Timeout;
  private momReadyTimer?: NodeJS.Timeout;

  get state(): NikxelState { return this._state; }
  private set state(s: NikxelState) {
    if (s === this._state) return;
    this._state = s;
    this.emit("state", s);
  }

  setState(s: NikxelState): void {
    // Recording (headphone) has priority over everything. Only stopRecording()
    // can leave .recording, and it bypasses this filter by writing state directly.
    if (this._state === "recording" && s !== "recording") return;
    // writingMOM is sticky for the same reason — the agent monitor seeing CPU
    // would otherwise flip it to thinking. Only endWritingMOM() can leave.
    if (this._state === "writingMOM" && s !== "writingMOM") return;
    // While the user is actively typing, the agent monitor would otherwise stomp
    // typing with thinking every 1.5 s. Block that so typing gets to play.
    if (this._state === "typing" && s === "thinking") return;
    this.state = s;
  }

  private later(timer: NodeJS.Timeout | undefined, ms: number): NodeJS.Timeout {
    if (timer) clearTimeout(timer);
    return setTimeout(() => this.setState("idle"), ms);
  }

  triggerTyping(): void {
    if (this._state === "recording") return;
    this.setState("typing");
    this.typingTimer = this.later(this.typingTimer, 200);
  }
  triggerDone(): void {
    if (this._state === "recording") return;
    this.setState("done");
    this.doneTimer = this.later(this.doneTimer, 1500);
  }
  triggerPounce(): void {
    if (this._state === "recording") return;
    this.setState("pounce");
    this.pounceTimer = this.later(this.pounceTimer, 700);
  }
  triggerPetted(): void {
    if (this._state === "recording") return;
    this.setState("petted");
    this.pettedTimer = this.later(this.pettedTimer, 2500);
  }
  triggerAlert(): void {
    if (this._state === "recording") return;
    this.setState("alert");
    this.alertTimer = this.later(this.alertTimer, 2000);
  }

  startRecording(): void { this.state = "recording"; }
  stopRecording(): void { if (this._state === "recording") this.state = "idle"; }

  startWritingMOM(): void { this.state = "writingMOM"; }
  endWritingMOM(): void { if (this._state === "writingMOM") this.state = "idle"; }

  triggerMomReady(): void {
    this.setState("momReady");
    this.momReadyTimer = this.later(this.momReadyTimer, 2000);
  }
}
