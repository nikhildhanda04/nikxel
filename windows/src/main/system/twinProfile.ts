import * as fs from "fs";
import { nikxelPath, writeAtomic } from "../core/paths";

/// What Nikxel has learned about the user over time, in ~/.nikxel/twin/profile.md.
/// Separate from the user's own userContext, which this never touches.
/// Mirrors TwinProfile.swift.
const file = () => nikxelPath("twin/profile.md");

export const TwinProfile = {
  get learned(): string {
    try { return fs.readFileSync(file(), "utf8"); } catch { return ""; }
  },
  set learned(v: string) {
    if (v) writeAtomic(file(), v);
    else { try { fs.rmSync(file(), { force: true }); } catch { /* already gone */ } }
  },

  /// The learned profile as a prompt block, or "" when empty. The
  /// <!--corrections--> region is machine data and never goes into prompts.
  get injectedBlock(): string {
    let t = this.learned;
    const a = t.indexOf("<!--corrections-->");
    const b = a < 0 ? -1 : t.indexOf("<!--/corrections-->", a);
    if (b >= 0) t = t.slice(0, a) + t.slice(b + "<!--/corrections-->".length);
    t = t.trim();
    return t ? `What Nikxel has learned about this user over time — their work, the correct names and terms they use, and how they talk and write. Match it.\n${t}` : "";
  },
};
