import { dialog } from "electron";

/// The main process's handle on the avatar — what the Swift modules reached
/// through `nikxelView?.` and `NikxelView.tell/ask`. Feature modules import
/// `ui` and call it; avatarWindow.ts installs the real implementation with
/// `setAvatar()` at startup. Before that (or while the avatar is hidden) cards
/// fall back to a native message box, like NikxelView.ask/tell fell back to an
/// NSAlert.

export type CardKind = "info" | "success" | "warning" | "error";

export interface CardButton {
  title: string;
  action: () => void;
}

export interface CardOptions {
  icon?: string;
  title: string;
  lines: string[];
  bulleted?: boolean;
  kind?: CardKind;
  /// Seconds. Infinity = stays until clicked. Default 20.
  lifetime?: number;
  /// Tapping the card (when it has no buttons) runs this and dismisses it.
  action?: () => void;
  /// A question: only these answer it, tapping elsewhere on the card does nothing.
  buttons?: CardButton[];
}

/// Implemented by avatarWindow.ts.
export interface AvatarSurface {
  isVisible(): boolean;
  show(): void;
  hide(): void;
  showCard(card: CardOptions): void;
  dismissCard(): void;
  /// Small tappable bubble (Apple Reminders / Google Tasks style). Tapping it
  /// calls the onReminderTapped handler with the id, then dismisses it.
  pushReminder(id: string, title: string): void;
  dismissReminder(id: string): void;
  /// One-line calendar ping above the head; null clears it.
  setReminderText(text: string | null): void;
  /// ms timestamp (Date.now()) recording started, or null — drives the timer.
  setRecordingStartedAt(ms: number | null): void;
  setInMeeting(on: boolean): void;
  setActiveTexter(name: string | null): void;
  applyAvatarSize(): void;
  reloadSprites(): void;
  triggerPuff(): void;
}

let avatar: AvatarSurface | null = null;
let reminderTapped: (id: string) => void = () => {};

function messageBoxFallback(c: CardOptions): void {
  const buttons = c.buttons?.length ? c.buttons : [{ title: "OK", action: () => {} }];
  dialog.showMessageBox({
    type: c.kind === "error" ? "error" : c.kind === "warning" ? "warning" : "info",
    title: "Nikxel",
    message: [c.icon, c.title].filter(Boolean).join(" "),
    detail: c.lines.join("\n"),
    buttons: buttons.map(b => b.title),
    defaultId: 0,
    cancelId: buttons.length - 1,
    noLink: true,
  }).then(r => buttons[r.response]?.action()).catch(() => {});
}

export const ui = {
  setAvatar(a: AvatarSurface): void { avatar = a; },
  get avatar(): AvatarSurface | null { return avatar; },

  onReminderTapped(handler: (id: string) => void): void { reminderTapped = handler; },
  /// Called by avatarWindow.ts when a reminder bubble is tapped.
  reminderWasTapped(id: string): void { reminderTapped(id); },

  /// A card on the avatar. Shows the window first if it was hidden — for
  /// feedback the user asked for from the tray (updates, logs copied).
  showCard(c: CardOptions, opts: { forceVisible?: boolean } = {}): void {
    if (!avatar) { messageBoxFallback(c); return; }
    if (opts.forceVisible && !avatar.isVisible()) avatar.show();
    avatar.showCard(c);
  },

  /// A notice that needs no answer: fades, tap to dismiss. NikxelView.tell.
  tell(c: Omit<CardOptions, "buttons">): void {
    if (!avatar || !avatar.isVisible()) { messageBoxFallback(c); return; }
    avatar.showCard({ lifetime: 20, ...c });
  },

  /// A question with buttons, stays until answered. NikxelView.ask.
  ask(c: Omit<CardOptions, "action" | "lifetime"> & { buttons: CardButton[] }): void {
    if (!avatar || !avatar.isVisible()) { messageBoxFallback(c); return; }
    avatar.showCard({ ...c, lifetime: Infinity });
  },

  pushReminder(id: string, title: string): void { avatar?.pushReminder(id, title); },
  dismissReminder(id: string): void { avatar?.dismissReminder(id); },
  setReminderText(text: string | null): void { avatar?.setReminderText(text); },
  setRecordingStartedAt(ms: number | null): void { avatar?.setRecordingStartedAt(ms); },
  setInMeeting(on: boolean): void { avatar?.setInMeeting(on); },
  setActiveTexter(name: string | null): void { avatar?.setActiveTexter(name); },
};
