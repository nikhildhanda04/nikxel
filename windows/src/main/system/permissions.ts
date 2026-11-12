import { systemPreferences } from "electron";
import { ui } from "../core/ui";
import { openUrl } from "../core/open";
import { isWin } from "../core/paths";
import { diag } from "../core/diag";

/// Windows needs no Accessibility grant (the keyboard hook and window titles
/// just work) and no Screen Recording grant (WASAPI loopback needs nothing).
/// The one switch that can be off is microphone privacy -- Settings → Privacy
/// & security → Microphone, both "Microphone access" and "Let desktop apps
/// access your microphone". When it's off, recording silently captures
/// nothing from the mic, so say so up front.

/// What's missing right now, as (label, settings page).
function missing(): [string, string][] {
  const m: [string, string][] = [];
  if (!isWin) return m;
  let mic: string;
  try { mic = systemPreferences.getMediaAccessStatus("microphone"); } catch { return m; }
  // "not-determined" isn't refused: Windows asks nobody for desktop apps;
  // only an explicit "denied" means a switch is off.
  if (mic === "denied" || mic === "restricted") {
    m.push(["Microphone — meeting and notes recording", "ms-settings:privacy-microphone"]);
  }
  return m;
}

/// Opens the Settings page for each missing grant. There's no prompt to
/// raise on Windows; the user flips the switch there and it applies live.
function request(pages: string[]): void {
  for (const p of new Set(pages)) {
    diag("permissions", `opening ${p}`);
    openUrl(p);
  }
}

/// Bubble listing what's missing, with one Allow button. No-op when all granted.
function offer(): void {
  const m = missing();
  if (m.length === 0) return;
  ui.ask({
    icon: "🔐",
    title: "Allow Nikxel's permissions",
    lines: [...m.map(x => x[0]), "Tap Allow, then switch microphone access on for desktop apps in the Settings page that opens."],
    kind: "warning",
    buttons: [
      { title: "Allow", action: () => request(m.map(x => x[1])) },
      { title: "Later", action: () => {} },
    ],
  });
}

export const Permissions = { offer, missing, request };
