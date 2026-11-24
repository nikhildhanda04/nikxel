// Copies the renderer's HTML and CSS next to the compiled scripts; tsc only
// emits .js.
const fs = require("fs");
const path = require("path");
const src = path.join(__dirname, "..", "src", "renderer");
const out = path.join(__dirname, "..", "dist", "renderer");
fs.mkdirSync(out, { recursive: true });
for (const f of fs.readdirSync(src)) {
  if (/\.(html|css)$/.test(f)) fs.copyFileSync(path.join(src, f), path.join(out, f));
}

// Optional shared Google OAuth client, as build.sh bundles it. With it,
// "Connect Google" is one click; without it, users bring their own.
const client = path.join(__dirname, "..", "..", "google_client.json");
if (fs.existsSync(client)) fs.copyFileSync(client, path.join(__dirname, "..", "resources", "google_client.json"));

// The Nikxel window's page is the Mac's, as is: it lives in a Swift raw string
// (src/DashboardPage.swift), with the chat's markdown helper spliced in from
// src/AvatarChat.swift. Taken from there at build time, so the two apps can't
// drift. The preload gives it the webkit.messageHandlers bridge it talks through.
const repo = path.join(__dirname, "..", "..");
function swiftRaw(file, decl) {
  const text = fs.readFileSync(path.join(repo, "src", file), "utf8");
  const start = text.indexOf(decl);
  if (start < 0) throw new Error(`copy-static: ${decl} not found in ${file}`);
  const from = text.indexOf('#"""', start) + 4;
  const to = text.indexOf('"""#', from);
  return text.slice(from, to).replace(/^\n/, "");
}
const markdown = swiftRaw("AvatarChat.swift", "static let markdownJS");
const dashboard = swiftRaw("DashboardPage.swift", "static let html").split("\\#(AvatarChat.markdownJS)").join(markdown);
if (dashboard.includes("\\#(")) throw new Error("copy-static: DashboardPage.swift has an interpolation this script doesn't fill");
fs.writeFileSync(path.join(out, "dashboard.html"), dashboard);
fs.copyFileSync(path.join(repo, "vendor", "clouds.png"), path.join(out, "clouds.png"));
