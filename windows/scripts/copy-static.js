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

// What each update added: the Nikxel window's What's new and its tour (system/whatsNew.ts).
fs.copyFileSync(path.join(__dirname, "..", "..", "WHATSNEW.md"), path.join(__dirname, "..", "resources", "whatsnew.md"));

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

// The setup wizard's page, the same way (src/OnboardingPage.swift). It reads
// window.Motion and --clouds before its own scripts run, which the Mac
// injects (PageAssets); here they go at the top of its head.
const onboarding = swiftRaw("OnboardingPage.swift", "static let html");
if (onboarding.includes("\\#(")) throw new Error("copy-static: OnboardingPage.swift has an interpolation this script doesn't fill");
fs.copyFileSync(path.join(repo, "vendor", "framer-motion-dom.js"), path.join(out, "framer-motion-dom.js"));
const preamble = '<script src="framer-motion-dom.js"></script>' +
  "<script>document.documentElement.style.setProperty('--clouds', 'url(clouds.png)')</script>";
fs.writeFileSync(path.join(out, "onboarding.html"), onboarding.replace(/<head>/i, "<head>" + preamble));

// The first-run tour's pointer card (src/CoachPage.swift).
fs.writeFileSync(path.join(out, "coach.html"), swiftRaw("CoachPage.swift", "static let html"));
