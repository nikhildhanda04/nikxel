import * as fs from "fs";
import { nikxelPath, writeAtomic } from "../core/paths";

/// Work-and-business facts Nikxel has read from the user's ERP, kept sealed in
/// ~/.nikxel/twin/erp.md (0600, like the twin profile). Its own file — the
/// voice distiller rewrites profile.md wholesale through the LLM and can't be
/// trusted to preserve a foreign region, so ERP facts live apart and inject
/// alongside, after the user's own context (so the user always wins).
/// Mirrors ErpContext.swift.
const file = () => nikxelPath("twin/erp.md");

export const ErpContext = {
  get facts(): string {
    try { return fs.readFileSync(file(), "utf8"); } catch { return ""; }
  },
  set facts(v: string) {
    if (v) { writeAtomic(file(), v); try { fs.chmodSync(file(), 0o600); } catch { /* perms best-effort */ } }
    else { try { fs.rmSync(file(), { force: true }); } catch { /* already gone */ } }
  },

  /// The ERP facts as a prompt block, or "" when empty.
  get injectedBlock(): string {
    const t = this.facts.trim();
    return t ? `What Nikxel has learned about this user's work and business from their ERP — the projects, tasks, people, and customers they work with.\n${t}` : "";
  },

  /// Prompt that turns captured ERP page text into terse work-context facts.
  readerPrompt(capturedText: string): string {
    return `Below is text captured from the pages of the user's ERP, read as the signed-in user (so it is only what they are allowed to see). Extract this user's work context as short facts an assistant can carry everywhere: the projects and tasks they work on, the people they work with, and the business and customers involved. Return the facts only — no commentary, no preamble, no code fences. Be terse; prefer facts over prose. Keep the whole thing under 2000 characters. If there is nothing useful, return nothing.

ERP PAGES:
${capturedText}`;
  },

  /// `old` when `next` is blank or has no real content (a refusal); else `next`
  /// trimmed and cut to `cap` on a line boundary.
  accept(next: string, old: string, cap = 2000): string {
    const t = next.trim();
    if (!t || !/[\p{L}\p{N}]/u.test(t)) return old; // Unicode: non-Latin facts are real content, not a refusal
    if (t.length <= cap) return t;
    if (t[cap] === "\n") return t.slice(0, cap);
    const head = t.slice(0, cap), nl = head.lastIndexOf("\n");
    return nl < 0 ? head : head.slice(0, nl);
  },

  /// Capture → read → store, with the capture and the LLM call injected (so it
  /// runs without a browser in tests). Empty capture keeps the old facts; a
  /// blank/refusal read keeps them too (via `accept`). The browser-backed
  /// capture and the connection guard live in ErpCrawl.ingest.
  async ingestWith(capture: () => Promise<string[]>,
                   runPrompt: (prompt: string, kind: string) => Promise<string>): Promise<void> {
    const sections = await capture();
    if (!sections.length) return;
    let out = "";
    try { out = await runPrompt(this.readerPrompt(this.boundText(sections)), "erp-ingest"); } catch { /* keep old */ }
    this.facts = this.accept(out, this.facts);
  },

  /// True for a nav link the read-only crawl must NOT follow — logout and
  /// delete/destroy-style controls some ERPs expose as plain GET links. The
  /// crawl rides the authenticated session, so following one could log the user
  /// out or mutate data; the Odoo driver never hits this (fixed read views),
  /// but the generic fallback follows discovered links.
  skipLink(href: string): boolean {
    const h = href.toLowerCase();
    return ["logout", "signout", "sign-out", "logoff", "delete", "destroy", "unlink"].some(w => h.includes(w));
  },

  /// Captured sections joined and truncated to `cap` chars (on a line
  /// boundary) — the bound on what the reader LLM ever sees in one run.
  boundText(sections: string[], cap = 8000): string {
    const joined = sections.map(s => s.trim()).filter(Boolean).join("\n\n---\n\n");
    if (joined.length <= cap) return joined;
    const head = joined.slice(0, cap), nl = head.lastIndexOf("\n");
    return nl < 0 ? head : head.slice(0, nl);
  },
};
