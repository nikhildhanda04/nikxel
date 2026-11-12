import { EventEmitter } from "events";

/// App-wide notifications — the NotificationCenter posts of the Mac app.
export interface BusEvents {
  /// ChatbotEngine: the contact currently typing/texting, or null.
  activeTexterChanged: [name: string | null];
  /// MeetingDetector: isInMeeting flipped.
  meetingStateChanged: [inMeeting: boolean];
  /// Sprite sheet installed or reset; the avatar reloads it.
  spritesChanged: [];
  /// Something a tray menu item shows changed (settings, recording, auth).
  menuChanged: [];
  /// The system woke from sleep / the session was unlocked.
  wake: [];
}

class Bus extends EventEmitter {
  emit<K extends keyof BusEvents>(event: K, ...args: BusEvents[K]): boolean {
    return super.emit(event, ...args);
  }
  on<K extends keyof BusEvents>(event: K, listener: (...args: BusEvents[K]) => void): this {
    return super.on(event, listener as (...a: unknown[]) => void);
  }
  off<K extends keyof BusEvents>(event: K, listener: (...args: BusEvents[K]) => void): this {
    return super.off(event, listener as (...a: unknown[]) => void);
  }
}

export const bus = new Bus();
bus.setMaxListeners(50);
