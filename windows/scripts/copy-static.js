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
