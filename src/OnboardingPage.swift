/// The onboarding window's page (OnboardingWindowController loads it into a
/// WKWebView). The idea: a temple on Olympus. The dashboard's ground -- its
/// paper, its grain and its dithered clouds (vendor/clouds.png, injected as
/// --clouds) -- with an eight-column temple front along the bottom, the
/// Parthenon's count. Every step the user's own sprite reaches raises that
/// step's column out of the clouds; finishing sets the roof on. Animated with
/// Framer Motion's standalone DOM build (window.Motion, from
/// vendor/framer-motion-dom.js); without it, or with Reduce Motion on,
/// everything simply appears.
///
/// Swift → page: nx.state(s) redraws (animating only when s.step changes),
/// nx.frames(rows) sets the sprite sheet as rows of data URIs, nx.progress(f)
/// moves the model download bar. Page → Swift:
/// webkit.messageHandlers.nx.postMessage({type,…}).
enum OnboardingPage {
    static let html = #"""
<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Set up Nikxel</title><meta name="description" content="Nikxel’s first-run setup: your avatar, transcription, WhatsApp, Google and your coding agent.">
<script>if (window.Motion && !matchMedia('(prefers-reduced-motion: reduce)').matches) document.documentElement.classList.add('booting');</script>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Fraunces:opsz,wght@9..144,400;9..144,500;9..144,600&family=Public+Sans:wght@400;500;600;700&display=swap">
<style>
/* Hallmark · shape: app screen · genre: editorial · theme: custom · redesign: full
 * idea: "a temple on Olympus: eight steps, the Parthenon's eight columns, raised one at a time out of the dashboard's clouds" · vibe: "marble on paper, calm, a little myth"
 * paper: #f6f4ee (the dashboard's, by request) · accent: oklch(47% 0.13 255) ink blue, for text that guides (red, then blue, by request) · display: Fraunces (by request; the dashboard's wordmark face) · body: Public Sans
 * nav: kept (top step list) · signature: the temple front the user's sprite walks while its columns rise · states: checking, installing, downloading, waiting, connected, failed, testing
 * axes: light/soft-serif/warm · posture: restrained · contrast: pass · v2.0.0 */
/* Hallmark · pre-emit critique: P4 H4 E4 S5 R4 V4 · weakest: P, paper-and-grain is a spent ground; kept because the user asked for the dashboard's own, and the clouds and the temple make it this app's */
/* Hallmark · waive 65 · cream paper + Fraunces + ink blue · the user asked for the dashboard's paper and Fraunces by name */
/* Hallmark · waive 80 · .temple marble colonnade · the user asked for a Greek design; the columns are the progress meter, one per step */
:root{
  color-scheme:only light;
  --color-paper:#f6f4ee; --color-paper-2:#efebe1; --color-card:#fdfcf8; --color-cloud:#dcd6c6;
  --color-ink:#0a0a0a; --color-ink-2:#45423b; --color-muted:#73706a; --color-faint:#a3a097;
  --color-line:#e3e0d6; --color-line-2:#d3cdbd; --color-on-ink:#fdfcf8;
  --color-accent:oklch(47% 0.13 255); --color-accent-text:oklch(43% 0.13 255); --color-focus:oklch(50% 0.13 255);
  --color-ok:oklch(47% 0.1 152); --color-ok-soft:oklch(93% 0.035 152); --color-warn:oklch(55% 0.12 70);
  --color-error:oklch(46% 0.17 29);
  /* the temple */
  --color-marble:oklch(98.5% 0.006 85); --color-marble-shade:oklch(91% 0.014 80); --color-marble-edge:oklch(72% 0.022 78);
  --color-ghost:oklch(78% 0.018 80);
  --font-display:'Fraunces',Georgia,serif;
  --font-body:'Public Sans',-apple-system,BlinkMacSystemFont,sans-serif;
  --font-code:ui-monospace,'SF Mono',Menlo,monospace;
  --color-shade-1:oklch(20% 0.02 80 / .05); --color-shade-2:oklch(30% 0.04 80 / .22); --color-shade-3:oklch(20% 0.02 80 / .12); --color-ring:oklch(20% 0.02 80 / .07);
  --shadow:0 1px 2px var(--color-shade-1),0 14px 32px -16px var(--color-shade-2);
  --ease:cubic-bezier(.16,1,.3,1);
}
*{box-sizing:border-box}
html,body{height:100%;margin:0;overflow-x:clip}
body{background:var(--color-paper);font-optical-sizing:auto;color:var(--color-ink);font:16px/1.55 var(--font-body);-webkit-font-smoothing:antialiased;overflow:clip;
  display:grid;grid-template-rows:60px minmax(0,1fr) 204px;-webkit-user-select:none;user-select:none;cursor:default}
/* The dashboard's ground: paper grain over everything, and the dithered clouds
   in the bottom-left, kept as a mask so the paper colours them. */
body::before{content:'';position:fixed;inset:0;z-index:50;pointer-events:none;opacity:.07;mix-blend-mode:multiply;
  background:url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='240' height='240'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='.85' numOctaves='3' stitchTiles='stitch'/%3E%3CfeColorMatrix values='0 0 0 0 .5 0 0 0 0 .5 0 0 0 0 .5 0 0 0 1.4 0'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23n)'/%3E%3C/svg%3E")}
.clouds{position:fixed;inset:0;z-index:0;pointer-events:none;background:var(--color-cloud);
  -webkit-mask:var(--clouds) left bottom / min(1200px,100vw) auto no-repeat;mask:var(--clouds) left bottom / min(1200px,100vw) auto no-repeat}
/* The splash: only while booting, which the head script sets when Motion is
   there to play it and Reduce Motion is off. Without script, nothing hides. */
.splash{position:fixed;inset:0;z-index:40;display:none;place-items:center;text-align:center;cursor:default}
html.booting .splash{display:grid}
html.booting header.top,html.booting main#stage,html.booting .temple,html.booting .clouds{opacity:0}
.sp-inner{display:flex;flex-direction:column;align-items:center}
.sp-avatar{width:128px;height:128px}
.sp-word{font:600 112px/1 var(--font-display);letter-spacing:-.045em;margin:12px 0 0}
.sp-word span{display:inline-block}
.sp-line{font-size:18px;color:var(--color-muted);margin:16px 0 0}
input,code{-webkit-user-select:text;user-select:text}
::selection{background:var(--color-daisy);color:var(--color-ink)}
html{caret-color:var(--color-accent);scrollbar-color:var(--color-line-2) transparent}
button{font:inherit;color:inherit}
:focus-visible{outline:2px solid var(--color-focus);outline-offset:3px}

/* top bar */
header.top{position:relative;z-index:2;display:flex;align-items:center;gap:28px;padding:0 32px 0 96px}
.mark{font:600 22px/1 var(--font-display);letter-spacing:-.02em}
.rail{list-style:none;margin:0 auto 0 0;padding:0;display:flex;gap:4px}
.rail li{padding:8px 12px;border-radius:999px;font-size:13px;color:var(--color-faint);transition:color .6s var(--ease),background-color .6s var(--ease)}
.rail li.done{color:var(--color-ink-2)}
.rail li.on{color:var(--color-ink);background:var(--color-card);box-shadow:inset 0 0 0 1px var(--color-line)}

/* stage */
main#stage{position:relative;z-index:1;overflow-y:auto;overflow-x:clip;padding:0 64px;
  -webkit-mask-image:linear-gradient(180deg,var(--color-ink) calc(100% - 24px),transparent);mask-image:linear-gradient(180deg,var(--color-ink) calc(100% - 24px),transparent)}
.panel{min-height:100%;max-width:1080px;margin:0 auto;display:grid;align-items:safe center;padding:12px 0 28px}
.panel.split{grid-template-columns:minmax(0,.9fr) minmax(0,1.1fr);gap:72px}
.panel.center{justify-items:center;text-align:center}
.panel.tour{align-content:safe center;gap:28px}
.copy{min-width:0;max-width:480px}
.center .copy{max-width:640px;display:flex;flex-direction:column;align-items:center}
.tourhead{max-width:none;display:flex;align-items:flex-end;justify-content:space-between;gap:40px}
.tourhead .sub{max-width:40ch}
.live{display:flex;flex-direction:column;gap:20px;min-width:0}

.display{font:500 44px/1.06 var(--font-display);letter-spacing:-.025em;margin:0 0 16px;overflow-wrap:break-word;min-width:0;text-wrap: balance}
.display.xl{font-size:64px;line-height:1.02;letter-spacing:-.03em}
.tour .display{margin:0 0 12px}
.sub,.lead{font-size:18px;line-height:1.55;color:var(--color-ink-2);margin:0;max-width:44ch;text-wrap:pretty}
.lead>b:first-child{color:var(--color-accent-text);font-weight:600}
.lead b{font-weight:600}
.guide{list-style:none;margin:24px 0 0;padding:0;display:flex;flex-direction:column;gap:12px}
.guide li{display:grid;grid-template-columns:28px minmax(0,1fr);gap:12px;align-items:start;font-size:15px;line-height:1.5;color:var(--color-muted);transition:color .6s var(--ease)}
.guide li>span:last-child{padding-top:4px}
.guide .n{width:28px;height:28px;border-radius:50%;display:grid;place-items:center;font:600 13px/1 var(--font-body);border:1.5px solid var(--color-line-2);color:var(--color-muted);background:var(--color-card);
  transition:background-color .6s var(--ease),border-color .6s var(--ease),color .6s var(--ease)}
.guide .n svg{width:14px;height:14px}
.guide li.now,.guide li.done{color:var(--color-ink-2)}
.guide li.now{color:var(--color-ink)}
.guide li.now .n{background:var(--color-ink);border-color:var(--color-ink);color:var(--color-on-ink)}
.guide li.done .n{background:var(--color-ok);border-color:var(--color-ok);color:var(--color-on-ink)}
.guide b{color:var(--color-ink);font-weight:600}
.note{margin:16px 0 0;font-size:14px;line-height:1.5;color:var(--color-muted);max-width:44ch}
.note b{color:var(--color-accent-text);font-weight:600}
.center .note{text-align:center}
kbd{font:600 12px/1 var(--font-body);padding:4px 8px;border:1px solid var(--color-line-2);border-bottom-width:2px;border-radius:8px;background:var(--color-card);color:var(--color-ink)}
.actions{display:flex;align-items:center;gap:8px;margin-top:32px}
.center .actions{justify-content:center}
.tourhead .actions{margin:0}

.field{display:flex;flex-direction:column;align-items:center;gap:8px;margin-top:28px;font-size:14px;color:var(--color-muted)}
.field input{width:320px;font:500 17px var(--font-body);color:var(--color-ink);text-align:center;padding:16px 16px;border-radius:14px;border:1px solid var(--color-line);background:var(--color-card);outline:none;box-shadow:var(--shadow);transition:border-color .5s var(--ease)}
.field input:hover{border-color:var(--color-line-2)}
.field input:focus-visible{outline:2px solid var(--color-focus);outline-offset:3px}
.field input::placeholder{color:var(--color-faint)}

.card{background:var(--color-card);border:1px solid var(--color-line);border-radius:20px;padding:24px 24px;box-shadow:var(--shadow)}
.cardh{display:flex;align-items:center;justify-content:space-between;font:600 19px/1.25 var(--font-display);letter-spacing:-.01em;margin:0 0 8px}
.row{display:flex;align-items:center;gap:12px;padding:12px 0;border-top:1px solid var(--color-line)}
.row:first-of-type{border-top:0}
.st{width:24px;height:24px;border-radius:50%;display:grid;place-items:center;flex:none;background:var(--color-paper-2);color:var(--color-ink);transition:background-color .6s var(--ease)}
.st.ok{background:var(--color-ok);color:var(--color-on-ink)}
.st svg{width:13px;height:13px}
.rt{flex:1;min-width:0;display:flex;flex-direction:column}
.rt b{font-weight:600;font-size:15px}
.rt small{color:var(--color-muted);font-size:13px}
.chip{font:500 12.5px/1 var(--font-body);padding:8px 8px;border-radius:999px;background:var(--color-paper-2);color:var(--color-ink-2);white-space:nowrap}
.chip.ok{background:var(--color-ok-soft);color:var(--color-ok)}

.btn{font:600 15px/1 var(--font-body);border:1px solid transparent;border-radius:999px;padding:12px 24px;cursor:pointer;display:inline-flex;align-items:center;justify-content:center;gap:8px;color:var(--color-ink);background:transparent;white-space:nowrap;
  transition:transform .45s var(--ease),background-color .45s var(--ease),border-color .45s var(--ease),box-shadow .45s var(--ease),opacity .3s}
.btn:hover:not(:disabled){transform:translateY(-1px)}
.btn:active:not(:disabled){transform:scale(.97)}
.btn:disabled{background:var(--color-paper-2);color:var(--color-muted);border-color:transparent;box-shadow:none;cursor:not-allowed}
.btn.primary{background:var(--color-ink);color:var(--color-on-ink);padding:16px 28px;box-shadow:0 10px 22px -12px var(--color-ink)}
.btn.primary:hover:not(:disabled){box-shadow:0 14px 26px -12px var(--color-ink)}
.btn.soft{background:var(--color-card);border-color:var(--color-line);box-shadow:0 1px 2px var(--color-shade-1)}
.btn.soft:hover:not(:disabled){border-color:var(--color-line-2)}
.btn.ghost{color:var(--color-muted)}
.btn.ghost:hover:not(:disabled){color:var(--color-ink);background:var(--color-paper-2)}
.btn.sm{padding:8px 16px;font-size:14px}
.btn.xs{padding:8px 12px;font-size:13px}
.btns{display:flex;flex-wrap:wrap;gap:8px;justify-content:center}

.fine{font-size:13px;line-height:1.55;color:var(--color-muted);margin:0}
.err{color:var(--color-error);font-size:14px;margin:0}
.busy{display:flex;align-items:center;gap:8px;color:var(--color-muted);font-size:14px;margin:0}
.spin{width:14px;height:14px;flex:none;border-radius:50%;border:2px solid var(--color-line);border-top-color:var(--color-ink);animation:spin 1.1s linear infinite}
@keyframes spin{to{transform:rotate(360deg)}}
.bar{height:8px;border-radius:99px;background:var(--color-paper-2);overflow:hidden;margin:8px 0 8px}
.bar i{display:block;height:100%;width:100%;border-radius:inherit;background:var(--color-stem);transform-origin:left;transform:scaleX(0);transition:transform .8s var(--ease)}


.stagecard{display:flex;flex-direction:column;align-items:center;gap:16px;text-align:center;padding:28px 28px 24px}
.well{width:200px;height:200px;border-radius:24px;display:grid;place-items:center;background:var(--color-paper-2)}
.well .sp{width:160px;height:160px}

.seg{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:4px;padding:4px;border-radius:14px;background:var(--color-paper-2)}
.seg button{border:0;background:transparent;border-radius:10px;padding:8px 8px;cursor:pointer;font:600 14px var(--font-body);color:var(--color-muted);
  transition:background-color .5s var(--ease),color .5s var(--ease),box-shadow .5s var(--ease)}
.seg button:hover{color:var(--color-ink)}
.seg button[aria-checked="true"]{background:var(--color-card);color:var(--color-ink);box-shadow:0 1px 3px var(--color-shade-3)}
.lang h2{font:600 19px/1.25 var(--font-display);letter-spacing:-.01em;margin:0 0 4px}
.lang>.fine:first-of-type{margin:0 0 12px}
.lang .fine{margin-top:8px}

.bubbles{display:flex;flex-direction:column;gap:8px;margin-bottom:16px}
.msg{max-width:80%;padding:8px 16px;border-radius:16px;font-size:14px;line-height:1.4;background:var(--color-paper-2)}
.msg.in{align-self:flex-start;border-bottom-left-radius:6px}
.msg.out{align-self:flex-end;border-bottom-right-radius:6px;background:var(--color-ok-soft)}
.msg small{display:block;margin-top:4px;font-size:12px;font-weight:600;color:var(--color-ok)}
.wa-status{display:flex;flex-direction:column;align-items:center;gap:12px;text-align:center;padding-top:16px;border-top:1px solid var(--color-line)}
.ok-line{display:flex;gap:8px;align-items:center;color:var(--color-ok);font-weight:600;margin:0}
.ok-line svg{width:18px;height:18px}


.agents{display:flex;flex-direction:column;gap:8px}
.agent{display:flex;gap:16px;align-items:flex-start;text-align:left;width:100%;padding:16px 16px;border-radius:16px;border:1px solid var(--color-line);background:var(--color-card);cursor:pointer;
  transition:border-color .5s var(--ease),box-shadow .5s var(--ease)}
.agent:not(.off):hover{border-color:var(--color-line-2)}
.agent.on{border-color:var(--color-ink);box-shadow:0 0 0 3px var(--color-ring)}
.agent.off{cursor:default}
.agent.off b{color:var(--color-muted)}
.agent b{display:block;font-weight:600;font-size:15px}
.radio{flex:none;width:18px;height:18px;margin-top:4px;border-radius:50%;border:1.5px solid var(--color-line-2);display:grid;place-items:center;transition:border-color .5s var(--ease)}
.radio::after{content:'';width:8px;height:8px;border-radius:50%;background:var(--color-ink);transform:scale(0);transition:transform .55s cubic-bezier(.34,1.56,.64,1)}
.on>.radio{border-color:var(--color-ink)}
.on>.radio::after{transform:scale(1)}
.agent.off .radio{opacity:.4}
.at{flex:1;min-width:0}
.at small{display:flex;gap:8px;align-items:center;font-size:13px;margin-top:4px}
.at small span{min-width:0;overflow-wrap:anywhere;display:-webkit-box;-webkit-box-orient:vertical;-webkit-line-clamp:2;overflow:hidden}
.tone-green{color:var(--color-ok)}.tone-red{color:var(--color-error)}.tone-orange{color:var(--color-warn)}.tone-muted{color:var(--color-muted)}
.hint{display:flex;gap:8px;align-items:center;margin-top:8px;min-width:0}
.hint code{font:12.5px var(--font-code);background:var(--color-paper-2);padding:8px 8px;border-radius:8px;white-space:nowrap;overflow-x:auto;min-width:0}
.testline{display:flex;align-items:center;justify-content:space-between;gap:12px}

.ticks{list-style:none;margin:0;padding:0;display:flex;flex-direction:column;gap:8px;font-size:15px;color:var(--color-ink-2)}
.ticks b{color:var(--color-ink);font-weight:600}
.tips{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:12px;margin-top:32px;width:min(720px,100%);text-align:left}
.tip{padding:16px 16px;border-radius:16px;background:var(--color-card);border:1px solid var(--color-line)}
.tip b{display:block;font:600 19px/1.25 var(--font-display);letter-spacing:-.01em}
.tip p{margin:4px 0 0;font-size:14px;line-height:1.5;color:var(--color-ink-2)}

/* the tour */
.cases{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:12px}
.case{display:flex;flex-direction:column;gap:8px;padding:16px 16px 16px 20px;border-radius:16px;background:var(--color-card);border:1px solid var(--color-line);min-width:0}
.case h2{margin:0;font:600 18px/1.25 var(--font-display);letter-spacing:-.01em}
.case p{margin:0;font-size:14px;line-height:1.5;color:var(--color-ink-2)}
.case q{display:block;quotes:none;margin-top:auto;align-self:flex-start;padding:8px 12px;border-radius:12px 12px 12px 4px;background:var(--color-paper-2);font-size:13.5px;line-height:1.4;color:var(--color-ink)}
.case.wide{grid-column:span 2}
.case .hint-line{margin-top:auto;color:var(--color-muted);font-size:13.5px}
.case .hint-line b{color:var(--color-accent-text);font-weight:600}
@media (max-width:1080px){.cases{grid-template-columns:repeat(2,minmax(0,1fr))}}

/* the temple */
.temple{position:relative;z-index:1;overflow:clip}
.temple svg{position:absolute;left:0;bottom:0;display:block;overflow:visible}
.col{position:absolute;bottom:12px;width:40px;height:132px;overflow:clip}
.col .ghost{position:absolute;inset:0}
.col .stone{position:absolute;inset:0}
.roof{bottom:144px}
.walker{position:absolute;left:0;bottom:10px;width:96px;height:96px;z-index:2}
.walker .face{width:100%;height:100%}
img.sprite{display:block;width:100%;height:100%;object-fit:contain;image-rendering:pixelated}
img.sprite:not([src]){visibility:hidden}
.m-fill{fill:var(--color-marble);stroke:var(--color-marble-edge);stroke-width:1;stroke-linejoin:round}
.m-shade{fill:var(--color-marble-shade)}
.m-line{stroke:var(--color-marble-shade);stroke-width:1.2}
.m-ghost{fill:none;stroke:var(--color-ghost);stroke-width:1;stroke-dasharray:3 4}
.m-step{fill:var(--color-marble);stroke:var(--color-marble-edge);stroke-width:1}
.m-step2{fill:var(--color-marble-shade);stroke:var(--color-marble-edge);stroke-width:1}

@media (max-width:1080px){
  .panel.split{gap:44px}
  .display{font-size:40px}.display.xl{font-size:56px}
  main#stage{padding-left:44px;padding-right:44px}
  .rail li{padding:8px 8px}
}
@media (max-height:820px){
  .row{padding:8px 0}
  .card{padding:16px 24px}
  .well{width:196px;height:196px}
  .well .sp{width:160px;height:160px}
}
@media (prefers-reduced-motion:reduce){
  .spin{animation:none}
  .btn,.rail li,.radio::after,.bar i{transition:none}
}
</style></head><body>
<div class="clouds" aria-hidden="true"></div>
<div class="splash" id="splash" aria-hidden="true"><div class="sp-inner">
  <div class="sp-avatar"><img class="sprite" alt="" data-row="0" src="data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"></div>
  <p class="sp-word"><span>n</span><span>i</span><span>k</span><span>x</span><span>e</span><span>l</span></p>
  <p class="sp-line">Your desk companion</p>
</div></div>
<header class="top"><span class="mark">nikxel</span><ol class="rail" id="rail"></ol></header>
<main id="stage"><section class="panel center"><div class="copy"><h1 class="display xl">Hi, I’m Nikxel.</h1><p class="sub">Getting the temple ready…</p></div></section></main>
<div class="temple" id="temple" aria-hidden="true"></div>
<script>
(function () {
'use strict';
var M = window.Motion;
var reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;
var EASE = [0.16, 1, 0.3, 1];
var ORDER = ['welcome', 'tour', 'avatar', 'deps', 'whatsapp', 'google', 'agent', 'ready'];
var RAIL = ['Hello', 'Tour', 'Avatar', 'Listening', 'WhatsApp', 'Google', 'Agent', 'Done'];
// Which sprite row the avatar plays on each step: petted, holding a page,
// idle, headphones, waving, thinking, typing, the jump. Row 5 is the run.
var ROW = { welcome: 6, tour: 9, avatar: 0, deps: 8, whatsapp: 7, google: 2, agent: 1, ready: 3 };
var RUN = 5;
var stage = document.getElementById('stage'), rail = document.getElementById('rail'), temple = document.getElementById('temple');
var S = null, current = null, rows = [], tick = 0, queue = Promise.resolve();
// Swift's "copied" flag clears after two seconds; the guide should stay ticked.
var promptCopied = false;

var CHECK = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><path d="m5 12.5 4.5 4.5L19 7.5"/></svg>';

function post(m) { webkit.messageHandlers.nx.postMessage(m); }
// The page is shared with the Windows app (windows/scripts/copy-static.js), whose state says platform: 'win'.
function mac(onMac, onWindows) { return S && S.platform === 'win' ? onWindows : onMac; }
var WIN_TERMINAL = 'Open PowerShell by pressing the <kbd>Windows</kbd> key, typing PowerShell and pressing <kbd>Enter</kbd>.';
function esc(s) {
  return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
    return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
  });
}
function wait(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }

// Every animation goes through here, so no Motion (or Reduce Motion) just
// means no animation rather than a broken page.
function animate(el, kf, opts) {
  if (!M || reduce || !el || el.length === 0) return Promise.resolve();
  return Promise.resolve(M.animate(el, kf, opts)).catch(function () {});
}
function enter(root, startDelay) {
  var items = root.querySelectorAll('[data-in]');
  if (!M || reduce || !items.length) return;
  items.forEach(function (el) { el.style.opacity = '0'; });
  animate(items, { opacity: [0, 1], y: [20, 0], filter: ['blur(10px)', 'blur(0px)'] },
    { duration: 1.6, ease: EASE, delay: M.stagger(0.12, { startDelay: startDelay || 0 }) });
}

// --- the splash -------------------------------------------------------------------
// The clouds drift up, Nikxel fades in, the name writes itself out of a blur,
// and then the whole thing dissolves into the first step. A click or a key
// skips the wait.
var splashed = false, skipSplash = function () {};
var skipped = new Promise(function (r) { skipSplash = r; });
document.addEventListener('pointerdown', function () { skipSplash(); });
document.addEventListener('keydown', function () { skipSplash(); });
function splash() {
  splashed = true;
  var root = document.documentElement, sp = document.getElementById('splash');
  if (!root.classList.contains('booting') || !M || reduce) {
    root.classList.remove('booting');
    if (sp) sp.remove();
    return Promise.resolve();
  }
  var clouds = document.querySelector('.clouds'), av = sp.querySelector('.sp-avatar'),
      letters = sp.querySelectorAll('.sp-word span'), line = sp.querySelector('.sp-line'),
      header = document.querySelector('header.top');
  [av, line].concat([].slice.call(letters)).forEach(function (el) { el.style.opacity = '0'; });
  clouds.style.opacity = '0';
  sp.style.display = 'grid';   // it shows only while booting, which ends here
  root.classList.remove('booting');
  [header, stage, temple].forEach(function (el) { el.style.opacity = '0'; });
  animate(clouds, { opacity: [0, 1], y: [48, 0] }, { duration: 3, ease: EASE });
  animate(av, { opacity: [0, 1], y: [20, 0], filter: ['blur(8px)', 'blur(0px)'] }, { duration: 1.8, ease: EASE, delay: 0.5 });
  animate(letters, { opacity: [0, 1], y: [24, 0], filter: ['blur(14px)', 'blur(0px)'] },
    { duration: 1.7, ease: EASE, delay: M.stagger(0.11, { startDelay: 1 }) });
  animate(line, { opacity: [0, 1], y: [8, 0] }, { duration: 1.6, ease: EASE, delay: 2 });
  return Promise.race([wait(4200), skipped]).then(function () {
    animate(sp, { opacity: [1, 0], scale: [1, 1.04], filter: ['blur(0px)', 'blur(14px)'] }, { duration: 1.4, ease: [0.4, 0, 0.2, 1] });
    animate(clouds, { opacity: 1 }, { duration: 0.8 });
    animate(header, { opacity: [0, 1], y: [-10, 0] }, { duration: 1.8, ease: EASE, delay: 0.7 });
    animate(temple, { opacity: [0, 1], y: [32, 0] }, { duration: 2.2, ease: EASE, delay: 0.5 });
    // The stage stays hidden until goTo has drawn the first step into it.
    setTimeout(function () { sp.remove(); }, 1600);
    return wait(600);
  });
}

// --- the sprite ------------------------------------------------------------
function frameOf(row, i) {
  var r = rows[row] && rows[row].length ? rows[row] : rows[0];
  return r && r.length ? r[i % r.length] : '';
}
function sprite(row) {
  var src = frameOf(row, 0);
  return '<img class="sprite" alt="" data-row="' + row + '"' + (src ? ' src="' + src + '"' : '') + '>';
}
function paintSprites(all) {
  document.querySelectorAll('img.sprite').forEach(function (img) {
    var running = img.dataset.row === String(RUN);
    if (!all && !running && tick % 3) return;   // 3 fps at rest, 9 fps on the run
    var src = frameOf(+img.dataset.row, reduce ? 0 : (running ? tick : Math.floor(tick / 3)));
    if (src && img.getAttribute('src') !== src) img.src = src;
  });
}
setInterval(function () { if (reduce) return; tick++; paintSprites(false); }, 1000 / 9);

// --- the temple -----------------------------------------------------------------
// A Doric column, 40 by 132: no base, a tapering fluted shaft, the cushion
// (echinus) and the slab (abacus) on top. Lit from the left.
var COLUMN =
  '<path class="m-fill" d="M7 132 L33 132 L31 20 L9 20 Z"/>' +
  '<path class="m-shade" d="M27 131.5 L32.5 131.5 L30.6 20.5 L26 20.5 Z"/>' +
  '<path class="m-line" d="M13 22V131M17 22V131M21 22V131M25 22V131"/>' +
  '<path class="m-fill" d="M9 20 L31 20 L37 12 L3 12 Z"/>' +
  '<rect class="m-fill" x="1" y="5" width="38" height="7" rx="1"/>';
var GHOST = '<path class="m-ghost" d="M7 132 L33 132 L31 20 L9 20 Z M9 20 L31 20 L37 12 L3 12 Z M1 5 H39 V12 H1 Z"/>';
var raised = {}, roofOn = false, walkerX = -120, walkerEl = null, layout = null;

function buildTemple() {
  var W = temple.clientWidth, gut = 72, n = ORDER.length, bay = (W - gut * 2) / n;
  layout = { centres: [], bay: bay };
  for (var i = 0; i < n; i++) layout.centres.push(gut + bay * (i + 0.5));
  var left = Math.round(layout.centres[0] - 20 - 18), right = Math.round(layout.centres[n - 1] + 20 + 18), w = right - left;
  // The stepped platform the columns stand on.
  var html = '<svg width="' + W + '" height="14"><rect class="m-step2" x="' + (left - 14) + '.5" y="6.5" width="' + (w + 28) + '" height="7"/>' +
    '<rect class="m-step" x="' + (left - 6) + '.5" y="0.5" width="' + (w + 12) + '" height="6"/></svg>';
  layout.centres.forEach(function (cx, i) {
    html += '<div class="col" data-col="' + i + '" style="left:' + Math.round(cx - 20) + 'px">' +
      '<svg class="ghost" width="40" height="132">' + GHOST + '</svg><svg class="stone" width="40" height="132">' + COLUMN + '</svg></div>';
  });
  // Architrave, a frieze of triglyphs, the cornice, and the low pediment.
  var tri = '', fh = 12;
  for (var x = left + 10; x < right - 10; x += 26) tri += '<rect class="m-shade" x="' + x + '" y="11" width="8" height="' + fh + '"/>';
  html += '<svg class="roof" width="' + W + '" height="60" style="bottom:144px">' +
    '<g class="roofg">' +
    '<path class="m-fill" d="M' + (left - 10) + ' 28 L' + (left + w / 2) + ' 2 L' + (right + 10) + ' 28 Z"/>' +
    '<path class="m-ghost" style="stroke-dasharray:none;stroke:var(--color-marble-shade)" d="M' + (left + 18) + ' 25 L' + (left + w / 2) + ' 8 L' + (right - 18) + ' 25"/>' +
    '<rect class="m-fill" x="' + (left - 12) + '" y="28" width="' + (w + 24) + '" height="6"/>' +
    '<rect class="m-fill" x="' + left + '" y="34" width="' + w + '" height="14"/>' +
    tri.replace(/y="11"/g, 'y="35"') +
    '<rect class="m-fill" x="' + (left - 2) + '" y="48" width="' + (w + 4) + '" height="12"/>' +
    '</g></svg>';
  html += '<div class="walker"><div class="face">' + sprite(current ? ROW[current] : RUN) + '</div></div>';
  temple.innerHTML = html;
  walkerEl = temple.querySelector('.walker');
  walkerEl.style.transform = 'translateX(' + walkerX + 'px)';
  temple.querySelectorAll('.col').forEach(function (c) {
    var i = +c.dataset.col, stone = c.querySelector('.stone');
    if (!raised[i]) stone.style.transform = 'translateY(132px)';
  });
  var roof = temple.querySelector('.roofg');
  if (!roofOn) { roof.style.opacity = '0'; roof.style.transform = 'translateY(-24px)'; }
  paintSprites(true);
}
// A column slides up out of the clouds, slowly, and settles.
function raise(i) {
  if (raised[i]) return;
  raised[i] = true;
  var c = temple.querySelector('[data-col="' + i + '"]');
  if (!c) return;
  var stone = c.querySelector('.stone'), ghost = c.querySelector('.ghost');
  if (!M || reduce) { stone.style.transform = ''; return; }
  M.animate(stone, { y: [132, 0] }, { duration: 2.4, ease: EASE });
  M.animate(ghost, { opacity: [1, 0] }, { duration: 1.6, delay: 0.8 });
}
function setRoof() {
  if (roofOn) return;
  roofOn = true;
  var roof = temple.querySelector('.roofg');
  if (!roof) return;
  if (!M || reduce) { roof.style.opacity = ''; roof.style.transform = ''; return; }
  M.animate(roof, { opacity: [0, 1], y: [-24, 0] }, { duration: 2.2, ease: EASE, delay: 1.4 });
}
function standX(i) { return Math.round(layout.centres[i] - layout.bay / 2 - 48); }
// The sprite runs to the step's column, turns to face you, and raises it.
function walkTo(step) {
  var i = ORDER.indexOf(step);
  if (!layout || !walkerEl) return;
  var target = standX(i), from = walkerX, img = walkerEl.querySelector('img'), face = walkerEl.querySelector('.face');
  walkerX = target;
  var arrive = function () {
    if (current !== step) return;   // a later step has already sent it on
    img.dataset.row = ROW[step];
    face.style.transform = '';
    paintSprites(true);
    for (var k = 0; k <= i; k++) raise(k);
    if (step === 'ready') setRoof();
  };
  if (!M || reduce || Math.abs(target - from) < 2) {
    walkerEl.style.transform = 'translateX(' + target + 'px)';
    arrive();
    return;
  }
  img.dataset.row = RUN;
  face.style.transform = target < from ? 'scaleX(-1)' : '';
  paintSprites(true);
  var dur = Math.min(3.2, 1.2 + Math.abs(target - from) / 440);
  Promise.race([wait(dur * 1000 + 400), animate(walkerEl, { x: [from, target] }, { duration: dur, ease: [0.45, 0, 0.3, 1] })]).then(arrive);
}
var resizeTimer;
window.addEventListener('resize', function () {
  clearTimeout(resizeTimer);
  resizeTimer = setTimeout(function () {
    if (!current) return;
    buildTemple();
    walkerX = standX(ORDER.indexOf(current));
    walkerEl.style.transform = 'translateX(' + walkerX + 'px)';
    walkerEl.querySelector('img').dataset.row = ROW[current];
    paintSprites(true);
  }, 150);
});

// --- builders ---------------------------------------------------------------------
function btn(label, act, attrs, cls) {
  return '<button type="button" class="btn ' + (cls || '') + '" data-act="' + act + '" ' + (attrs || '') + '>' + label + '</button>';
}
function goBtn(label, step, cls) { return btn(label, 'go', 'data-step="' + step + '"', cls); }
function back(step) { return goBtn('Back', step, 'ghost'); }
var NAV = '<div class="actions" id="nav" data-in></div>';
function row(name, ok, note, chip) {
  return '<div class="row"><span class="st' + (ok ? ' ok' : '') + '">' + (ok ? CHECK : '') + '</span>' +
    '<div class="rt"><b>' + esc(name) + '</b><small>' + esc(note) + '</small></div>' +
    '<span class="chip' + (ok ? ' ok' : '') + '">' + esc(chip || (ok ? 'Installed' : 'Not installed')) + '</span></div>';
}

// The tour: real moments in a day, what to do, and what to type. Every one of
// these is something the app does today.
var CASES = [
  ['Right before a meeting', 'Click me and ask what happened last time. I answer from your last two weeks of minutes and notes.', '“What did we decide with Rahul last week?”'],
  ['In the meeting', 'I offer to record Google Meet and WhatsApp calls. In person? Double-click me. You get minutes with action items.', ''],
  ['After the meeting', 'Fix the minutes in one sentence, then share them to WhatsApp or a project.', '“Speaker 3 is Rahul”'],
  ['In your inbox', 'Click me to find, draft and tidy mail. Nothing goes out until you say “send it”.', '“Draft a reply to Priya’s last email”'],
  ['While you’re busy', 'I reply on WhatsApp the way you would, and send a call link at the time you agreed.', ''],
  ['At the end of the day', 'At 10 pm your day is written up. Every Sunday, your week in review.', '']
];

// A step's how-to: [text, state], state 'done', 'now' or ''. Redrawn live,
// so the list tracks what the user has actually done.
function guideItems(items) {
  return items.map(function (it, i) {
    return '<li class="' + (it[1] || '') + '"><span class="n">' + (it[1] === 'done' ? CHECK : i + 1) + '</span><span>' + it[0] + '</span></li>';
  }).join('');
}
function guideFor(step) { return '<ol class="guide" id="guide" data-in>' + guideItems(VIEWS[step].guide(S)) + '</ol>'; }
function note(text) { return '<p class="note" data-in>' + text + '</p>'; }
// Walk a list of conditions: everything before the first unmet one is done,
// that one is now, the rest wait.
function track(texts, doneUpTo) {
  return texts.map(function (t, i) { return [t, i < doneUpTo ? 'done' : i === doneUpTo ? 'now' : '']; });
}
function menu() { return '<b>Setup Wizard…</b> in the Nikxel ' + mac('menu bar icon', 'tray icon (by the clock)'); }

var VIEWS = {
  welcome: {
    layout: 'center',
    copy: function (s) {
      return '<h1 class="display xl" data-in>Hi, I’m Nikxel.</h1>' +
        '<p class="lead" data-in>I’m a small helper that lives on your desktop. I take notes in your meetings, reply on WhatsApp while you’re busy, and write up your day.</p>' +
        '<label class="field" data-in><span>First, what should I call you in your notes?</span>' +
        '<input id="name" value="' + esc(s.name) + '" placeholder="Your first name (optional)" autocomplete="off" spellcheck="false"></label>' + NAV +
        note('Setup has five short steps. Only one is required; skip any other and finish it later. Each step you finish raises a column of the temple below.');
    },
    nav: function () { return goBtn('Get started', 'tour', 'primary'); }
  },

  tour: {
    layout: 'tour',
    bare: true,
    copy: function () {
      return '<div class="copy tourhead"><div><h1 class="display" data-in>A day with Nikxel</h1>' +
        '<p class="lead" data-in>Things to try in your first week. Nothing to set up here.</p></div>' + NAV + '</div>';
    },
    live: function () {
      return '<div class="cases">' + CASES.map(function (c) {
        return '<article class="case" data-in><h2>' + c[0] + '</h2><p>' + c[1] + '</p>' + (c[2] ? '<q>' + c[2] + '</q>' : '') + '</article>';
      }).join('') +
        '<article class="case wide" data-in><h2>Over the weeks, I learn how you work</h2>' +
        '<p>I learn how you write from the messages you send and the fixes you make. Each week I look at how you work and suggest changes, like a later summary time or WhatsApp quiet hours. Nothing changes until you say yes.</p>' +
        '<p class="hint-line">Tell me your role and goals in <b>Tell Nikxel About You…</b> (Nikxel menu) to get there faster.</p></article>' +
        '</div>';
    },
    nav: function () { return back('welcome') + goBtn('Start setup', 'avatar', 'primary'); }
  },

  avatar: {
    layout: 'split',
    copy: function (s) {
      return '<h1 class="display" data-in>Choose how I look</h1>' +
        '<p class="lead" data-in><b>Optional.</b> I can look like you instead of this character. You’ll need a photo of yourself and Google Gemini; it takes a few minutes.</p>' +
        guideFor('avatar') + NAV +
        note('Happy with this look? Just click Next. This step raises the third column.');
    },
    guide: function (s) {
      var a = s.avatar, items = [
        'Click <b>Copy Gemini prompt</b> on the right.',
        'Go to gemini.google.com, paste the prompt, and attach a clear photo of your face.',
        'Download the image Gemini makes: a grid of small characters.',
        'Click <b>Use my own sprite sheet…</b> and pick that file. You’ll see yourself on the right.'
      ];
      return track(items, a.custom ? 4 : (a.copied || promptCopied) ? 1 : 0);
    },
    live: function (s) {
      var a = s.avatar;
      return '<div class="card stagecard" data-in>' +
        '<div class="well"><div class="sp">' + sprite(0) + '</div></div>' +
        '<p class="fine">' + (a.custom ? 'This is your own sprite sheet.' : 'This is the character that comes with Nikxel.') + '</p>' +
        (a.error ? '<p class="err">' + esc(a.error) + '</p>' : '') +
        (a.importing ? '<p class="busy"><span class="spin"></span>Reading your image…</p>' : '') +
        '<div class="btns">' +
          btn(a.copied ? 'Prompt copied' : 'Copy Gemini prompt', 'copyPrompt', '', 'soft') +
          btn('Use my own sprite sheet…', 'chooseSheet', a.importing ? 'disabled' : '', 'soft') +
          (a.custom ? btn('Go back to the default', 'resetSheet', '', 'ghost') : '') +
        '</div>' +
        '<p class="fine" style="max-width:52ch">' + esc(a.spec) + '</p></div>';
    },
    nav: function () { return goBtn('Next', 'deps', 'primary') + back('tour'); }
  },

  deps: {
    layout: 'split',
    copy: function () {
      return '<h1 class="display" data-in>Turn meetings into notes</h1>' +
        '<p class="lead" data-in><b>Recommended.</b> To turn meeting recordings into notes I need two free tools and a speech model. One click installs them.</p>' +
        guideFor('deps') + NAV +
        note('Skip it and recordings are still saved, just not turned into notes.');
    },
    guide: function (s) {
      var d = s.deps, tools = d.whisper && d.ffmpeg;
      if (!d.checked) return [['Checking what’s already on your ' + mac('Mac', 'PC') + '…', 'now']];
      if (d.ready) return [['Everything is installed. Click <b>Next</b>.', 'done']];
      if (S.platform === 'win') {
        // No Homebrew or Terminal on Windows: whisper downloads right here, and ffmpeg comes with Nikxel.
        return track([
          'Click <b>Install</b>. I download whisper here; there’s nothing else to run.',
          'Wait while it downloads. This page updates by itself.',
          'The speech model (' + esc(d.modelSize) + ') then downloads here too. When everything is ticked, click <b>Next</b>.'
        ], tools ? 2 : d.installing ? 1 : 0);
      }
      var items = [
        'Click <b>Install</b>. A Terminal window opens.',
        'If it asks for your Mac password, type it and press <kbd>Return</kbd>. The password stays hidden as you type.',
        'Leave Terminal open until it says <b>Done</b>. This page updates by itself.',
        'The speech model (' + esc(d.modelSize) + ') then downloads here. When all three are ticked, click <b>Next</b>.'
      ];
      return track(items, tools ? 3 : d.installing ? 1 : 0);
    },
    live: function (s) {
      var d = s.deps, tools = '';
      tools += row('whisper', d.whisper, 'turns speech into text', d.checked ? '' : 'Checking…');
      tools += row('ffmpeg', d.ffmpeg, 'reads the recorded audio', d.checked ? '' : 'Checking…');
      // whisper.cpp (what Homebrew installs) ships no model of its own.
      if (d.cpp) {
        tools += row('speech model', d.model, 'what whisper listens with', d.model ? 'Ready' : 'Not downloaded');
        if (d.downloading) {
          tools += '<div class="bar"><i style="transform:scaleX(' + d.progress + ')"></i></div>' +
            '<p class="fine">Downloading ' + esc(d.modelName) + '. You can keep going; it finishes in the background.</p>';
        } else if (!d.model) {
          tools += '<div style="margin-top:8px">' + btn('Download speech model (' + esc(d.modelSize) + ')', 'downloadModel', '', 'soft sm') + '</div>';
        }
        if (d.modelError) tools += '<p class="err" style="margin-top:8px">' + esc(d.modelError) + ' Check your internet connection and try again.</p>';
      }
      if (d.checked && !(d.whisper && d.ffmpeg)) {
        if (d.installing) {
          tools += '<p class="busy" style="margin-top:12px"><span class="spin"></span><span>' + mac('Installing in Terminal. This page updates by itself.', esc(d.installMessage || 'Downloading whisper…')) + '</span></p>' +
            (d.installProgress != null ? '<div class="bar"><i style="transform:scaleX(' + d.installProgress + ')"></i></div>' : '');
        } else {
          if (d.installError) tools += '<p class="err" style="margin-top:12px">' + esc(d.installError) + ' Check your internet connection and try again.</p>';
          // Always a button: without Homebrew the script installs it first,
          // rather than leaving the user with a command to copy.
          tools += '<div style="display:flex;gap:16px;align-items:center;margin-top:12px">' +
            btn('Install', 'installDeps', '', 'primary') +
            '<p class="fine">' + mac(d.brew ? 'Installs both with Homebrew, which you already have.'
              : 'Installs Homebrew (a free Mac installer) first, then both tools.', 'Downloads whisper into Nikxel. ffmpeg comes with Nikxel.') + '</p></div>';
        }
      }
      var chosen = d.languages.filter(function (o) { return o.code === d.language; })[0] || d.languages[0];
      var seg = d.languages.map(function (o) {
        return '<button type="button" role="radio" aria-checked="' + (o.code === d.language) + '" data-act="language" data-code="' + o.code + '">' + esc(o.title) + '</button>';
      }).join('');
      return '<div class="card" data-in><div class="cardh">What I need' + btn('Check again', 'recheckDeps', '', 'ghost xs') + '</div>' + tools + '</div>' +
        '<div class="lang" data-in><h2>What language are your meetings in?</h2><p class="fine">Leave this on English unless they’re mostly Hindi.</p>' +
        '<div class="seg" role="radiogroup" aria-label="Meeting language">' + seg + '</div>' +
        '<p class="fine">' + esc(chosen.note) + '.</p></div>';
    },
    nav: function (s) {
      return s.deps.ready ? goBtn('Next', 'whatsapp', 'primary') + back('avatar') : back('avatar') + goBtn('Skip this step', 'whatsapp', 'ghost');
    }
  },

  whatsapp: {
    layout: 'split',
    copy: function (s) {
      return '<h1 class="display" data-in>Let me reply on WhatsApp</h1>' +
        '<p class="lead" data-in><b>Optional.</b> I can answer your WhatsApp messages the way you would while you’re in a meeting, or all day.</p>' +
        guideFor('whatsapp') + NAV +
        note('Skip it and connect later from ' + menu() + '.');
    },
    guide: function (s) {
      var w = s.wa, items = [
        'Click <b>Connect WhatsApp</b> on the right. A' + mac(' ' + esc(w.browser), ' WhatsApp') + ' window opens with a QR code.',
        'On your phone, open WhatsApp and go to <b>Settings</b>, then <b>Linked devices</b>, then <b>Link a device</b>.',
        'Point your phone at the QR code. This page says <b>Connected</b> when it worked.',
        mac('Leave that browser window open (minimised is fine). Click <b>Next</b>.', 'You can close that window; I keep WhatsApp running. Click <b>Next</b>.')
      ];
      return track(items, w.connected ? 3 : w.connecting ? 1 : 0);
    },
    live: function (s) {
      var w = s.wa, status;
      if (w.noBrowser) {
        status = '<p class="fine">' + esc(w.missing) + '</p>' + btn('Get Google Chrome', 'getChrome', '', 'soft');
      } else if (w.launchFailed) {
        status = '<p class="fine">' + mac('Couldn’t open ' + esc(w.browser) + ' for WhatsApp (port ' + w.port +
          ' is busy). Quit ' + esc(w.browser) + ' completely, then try again.', 'Couldn’t open WhatsApp: ' + esc(w.error) + '.') + '</p>' + btn('Try again', 'connectWhatsApp', '', 'soft');
      } else if (w.connected) {
        status = '<p class="ok-line">' + CHECK + 'Connected</p>';
      } else if (w.connecting) {
        status = '<p class="busy"><span class="spin"></span>Waiting for you to scan the QR code with your phone…</p>';
      } else {
        status = btn('Connect WhatsApp', 'connectWhatsApp', '', 'primary');
      }
      return '<div class="card" data-in><div class="bubbles">' +
        '<div class="msg in">Are you free for a quick call?</div>' +
        '<div class="msg out">In a meeting till 4. I’ll call you right after.<small>Sent by Nikxel</small></div>' +
        '</div><div class="wa-status">' + status + '</div></div>';
    },
    nav: function (s) {
      return s.wa.connected ? goBtn('Next', 'google', 'primary') + back('deps') : back('deps') + goBtn('Skip this step', 'google', 'ghost');
    }
  },

  google: {
    layout: 'split',
    copy: function () {
      return '<h1 class="display" data-in>Connect your Google account</h1>' +
        '<p class="lead" data-in><b>Optional.</b> For calendar reminders, adding action items to Google Tasks, and reading or drafting Gmail when you ask me to.</p>' +
        guideFor('google') + NAV +
        note('Nothing is sent or added without your OK. Skip it and connect later from ' + menu() + '.');
    },
    guide: function (s) {
      var g = s.google, items = [
        'Click <b>Connect Google</b> on the right. Your web browser opens a Google sign-in page.',
        'Choose your account and allow the access Nikxel asks for.',
        'Come back to this window. It turns green by itself; then click <b>Next</b>.'
      ];
      if (!g.oneClick) items[0] = 'Click <b>Connect Google…</b> on the right and follow its steps to add your own Google client, then sign in.';
      return track(items, g.connected ? 3 : g.waiting ? 1 : 0);
    },
    live: function (s) {
      var g = s.google, body = row('Google account', g.connected, 'Calendar, Tasks and Gmail', g.connected ? 'Connected' : 'Not connected');
      if (!g.connected) {
        body += '<div style="display:flex;flex-direction:column;gap:12px;align-items:flex-start;margin-top:16px">' +
          (g.waiting ? '<p class="busy"><span class="spin"></span>Finish signing in in your browser, then come back here.</p>' : '') +
          btn(g.oneClick ? 'Connect Google' : 'Connect Google…', 'connectGoogle', '', g.waiting ? 'soft' : 'primary') + '</div>';
      }
      return '<div class="card" data-in>' + body + '</div>' +
        '<ul class="ticks" data-in>' +
        '<li><b>Calendar.</b> A bubble two minutes before each event.</li>' +
        '<li><b>Tasks.</b> A meeting’s action items, once you OK them.</li>' +
        '<li><b>Gmail.</b> Search, draft and tidy when you click me and ask.</li></ul>';
    },
    nav: function (s) {
      return s.google.connected ? goBtn('Next', 'agent', 'primary') + back('whatsapp') : back('whatsapp') + goBtn('Skip this step', 'agent', 'ghost');
    }
  },

  agent: {
    layout: 'split',
    copy: function () {
      return '<h1 class="display" data-in>Choose the AI I use</h1>' +
        '<p class="lead" data-in><b>Required.</b> I don’t have an AI of my own. I ask a coding agent on your ' + mac('Mac', 'PC') + ', such as Claude Code, to write my notes, summaries and replies.</p>' +
        guideFor('agent') + NAV +
        note(mac('Open Terminal by pressing <kbd>⌘</kbd> <kbd>Space</kbd>, typing Terminal and pressing <kbd>Return</kbd>.', WIN_TERMINAL) + ' This step raises the seventh column.');
    },
    guide: function (s) {
      var working = s.agents.some(function (a) { return a.tone === 'green'; });
      var chosenOk = s.agents.some(function (a) { return a.chosen && a.tone === 'green'; });
      var items = [
        'Wait a few seconds while I test each one with a real request.',
        working ? 'Pick one that says <b>working</b>. I’ve already picked the first that does.'
                : 'None works yet. Under one, click <b>Copy</b>, paste the command into ' + mac('Terminal', 'PowerShell') + ' and press <kbd>' + mac('Return', 'Enter') + '</kbd>. Finish any sign-in it asks for.',
        working ? 'Click <b>Next</b>.' : 'Come back and click <b>Test again</b>.'
      ];
      return track(items, s.testing ? 0 : chosenOk ? 2 : 1);
    },
    live: function (s) {
      var list = s.agents.map(function (a, i) {
        var status = (a.text === 'Testing…' ? '<span class="spin" style="width:12px;height:12px"></span>' : '') + '<span title="' + esc(a.text) + '">' + esc(a.text) + '</span>';
        var hint = a.hint ? '<div class="hint"><code>' + esc(a.hint) + '</code>' +
          btn(a.copied ? 'Copied' : 'Copy', 'copyAgent', 'data-index="' + i + '"', 'soft xs') + '</div>' : '';
        return '<div class="agent' + (a.chosen ? ' on' : '') + (a.enabled ? '' : ' off') + '" data-act="pickAgent" data-index="' + i + '"' +
          (a.enabled ? ' role="radio" aria-checked="' + a.chosen + '" tabindex="0"' : ' aria-disabled="true"') + '>' +
          '<span class="radio"></span><div class="at"><b>' + esc(a.name) + '</b><small class="tone-' + a.tone + '">' + status + '</small>' + hint + '</div></div>';
      }).join('');
      return '<div class="agents" data-in role="radiogroup" aria-label="Coding agent">' + list + '</div>' +
        '<div class="testline" data-in><p class="fine">' + (s.testing
          ? 'Testing each one. This takes a few seconds…'
          : 'Fixed something in ' + mac('Terminal', 'PowerShell') + '? Test again.') + '</p>' +
        btn('Test again', 'retestAgents', s.testing ? 'disabled' : '', 'soft sm') + '</div>';
    },
    nav: function (s) {
      var ok = s.agents.some(function (a) { return a.chosen && a.tone === 'green'; });
      return goBtn(ok ? 'Next' : 'Continue anyway', 'ready', ok ? 'primary' : 'soft') + back('google');
    }
  },

  ready: {
    layout: 'center',
    copy: function (s) {
      var tips = [['Click me', 'Chat with me: ask about your mail, notes or day.'],
                  ['Double-click me', 'Start or stop recording a meeting.'],
                  [mac('The menu bar icon', 'The tray icon'), 'Every setting, and this setup again.']];
      return '<h1 class="display xl" data-in>You’re all set' + (s.name ? ', ' + esc(s.name) : '') + '.</h1>' +
        '<p class="lead" data-in>The temple is finished, and I’m on your desktop. Three ways to use me:</p>' +
        '<div class="tips" data-in>' + tips.map(function (t) {
          return '<div class="tip"><b>' + t[0] + '</b><p>' + t[1] + '</p></div>';
        }).join('') + '</div>' + NAV + '<div id="live" class="live" style="align-items:center"></div>';
    },
    // What was skipped, and how to come back to it.
    live: function (s) {
      var left = [];
      if (!s.deps.ready) left.push('meeting notes');
      if (!s.wa.connected) left.push('WhatsApp');
      if (!s.google.connected) left.push('Google');
      if (!left.length) return '';
      var list = left.length === 1 ? left[0] : left.slice(0, -1).join(', ') + ' and ' + left[left.length - 1];
      return '<p class="note">Still to set up: <b>' + list + '</b>. Finish any time from ' + menu() + '.</p>';
    },
    inlineLive: true,
    nav: function () { return btn('Start using Nikxel', 'finish', '', 'primary') + back('agent'); }
  }
};

// --- rail ------------------------------------------------------------------------
rail.innerHTML = RAIL.map(function (r) { return '<li>' + r + '</li>'; }).join('');
function markRail(step) {
  var ix = ORDER.indexOf(step), lis = rail.children;
  for (var i = 0; i < lis.length; i++) {
    lis[i].className = i < ix ? 'done' : i === ix ? 'on' : '';
    if (i === ix) lis[i].setAttribute('aria-current', 'step'); else lis[i].removeAttribute('aria-current');
  }
}

// --- drawing -------------------------------------------------------------------------
function build(step) {
  var v = VIEWS[step], el = document.createElement('section');
  el.className = 'panel ' + v.layout;
  var live = v.live ? v.live(S) : '';
  el.innerHTML = (v.bare ? v.copy(S) : '<div class="copy">' + v.copy(S) + '</div>') + (v.live && !v.inlineLive ? '<div class="live" id="live">' + live + '</div>' : '');
  var l = el.querySelector('#live');
  if (l) { if (v.inlineLive) l.innerHTML = live; l._h = live; }
  var g = el.querySelector('#guide');
  if (g) g._h = guideItems(v.guide(S));
  return el;
}
function drawNav() {
  var nav = document.getElementById('nav');
  if (!nav) return;
  var h = VIEWS[current].nav(S);
  if (h !== nav._h) { nav.innerHTML = h; nav._h = h; }
}

function goTo(step) {
  var from = current, dir = from == null ? 1 : (ORDER.indexOf(step) >= ORDER.indexOf(from) ? 1 : -1);
  // The first step replaces the static greeting outright; later ones animate out.
  var old = from == null ? null : stage.firstElementChild;
  current = step;
  markRail(step);
  if (from == null) buildTemple();
  walkTo(step);
  // Raced against a timer: WebKit stops animation frames while the window is
  // hidden, and the next step shouldn't wait for it to come back.
  var out = old ? Promise.race([wait(1100), animate(old,
    { opacity: [1, 0], x: [0, -24 * dir], filter: ['blur(0px)', 'blur(10px)'] },
    { duration: 0.9, ease: [0.4, 0, 0.2, 1] })]) : Promise.resolve();
  return out.then(function () {
    var panel = build(current);
    stage.innerHTML = '';
    stage.scrollTop = 0;
    stage.appendChild(panel);
    stage.style.opacity = '';
    drawNav();
    paintSprites(true);
    animate(panel, { x: [28 * dir, 0] }, { duration: 1.8, ease: EASE });
    enter(panel, from == null ? 0.7 : 0.1);
    var input = document.getElementById('name');
    if (input) setTimeout(function () { input.focus(); input.select(); }, 1600);
  });
}

// Same step, new facts (a check landed, an agent answered): swap the live
// region and the actions in place, without replaying the entrance.
function patch() {
  var live = document.getElementById('live');
  if (live && VIEWS[current].live) {
    var h = VIEWS[current].live(S);
    if (h !== live._h) { live.innerHTML = h; live._h = h; paintSprites(true); animate(live, { opacity: [0.4, 1] }, { duration: 0.8, ease: EASE }); }
  }
  var g = document.getElementById('guide');
  if (g && VIEWS[current].guide) {
    var gh = guideItems(VIEWS[current].guide(S));
    if (gh !== g._h) { g.innerHTML = gh; g._h = gh; animate(g.querySelectorAll('li.now'), { opacity: [0.3, 1], x: [-6, 0] }, { duration: 0.9, ease: EASE }); }
  }
  drawNav();
}

window.nx = {
  state: function (s) {
    queue = queue.then(function () {
      S = s;
      if (!splashed) return splash().then(function () { return goTo(S.step); });
      return current !== s.step ? goTo(s.step) : patch();
    }).catch(function (e) { console.error(e); });
  },
  frames: function (r) { rows = r || []; paintSprites(true); },
  progress: function (f) {
    if (S) S.deps.progress = f;
    var bar = document.querySelector('.bar i');
    if (bar) bar.style.transform = 'scaleX(' + f + ')';
  }
};

// --- input ------------------------------------------------------------------------------
document.addEventListener('click', function (e) {
  var b = e.target.closest('[data-act]');
  if (!b || b.disabled || b.getAttribute('aria-disabled') === 'true') return;
  var m = { type: b.dataset.act };
  if (m.type === 'copyPrompt') promptCopied = true;
  if (b.dataset.step) m.step = b.dataset.step;
  if (b.dataset.index) m.index = parseInt(b.dataset.index, 10);
  if (b.dataset.code) m.code = b.dataset.code;
  if (m.type === 'go' && current === 'welcome') {
    var n = document.getElementById('name');
    if (n) m.name = n.value;
  }
  post(m);
});
document.addEventListener('keydown', function (e) {
  if ((e.key !== 'Enter' && e.key !== ' ') || e.isComposing) return;
  var t = e.target;
  if (t && t.getAttribute && t.getAttribute('role') === 'radio' && t.tagName !== 'BUTTON') { e.preventDefault(); t.click(); return; }
  if (e.key !== 'Enter' || (t && t.tagName === 'BUTTON')) return;
  var p = document.querySelector('#nav .primary');
  if (p) { e.preventDefault(); p.click(); }
});
})();
</script>
</body></html>
"""#
}
