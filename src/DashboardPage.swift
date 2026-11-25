/// The dashboard window's page (DashboardWindowController loads it into a
/// WKWebView): a sidebar of sections and the settings in each, on the same
/// paper, grain and clouds as the onboarding (--clouds comes from PageAssets).
/// Content is always visible: entrances are CSS animations that only ever
/// play over content already in place, so a hidden window or a lost race can't
/// leave a section blank. While a summary is open, the page draws the reader
/// bar and SummaryViewer covers the rest of the main column.
///
/// Swift → page: nx.state(s) redraws the open section (left alone while the
/// user is typing in it), nx.frames(rows) sets the sprite sheet. Page → Swift:
/// {type:'section', id}, {type:'set', key, value}, {type:'action', name},
/// {type:'open', id} (a library file).
enum DashboardPage {
    static let html = #"""
<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Nikxel</title><meta name="description" content="Every Nikxel setting in one window: you, meetings and notes, WhatsApp, connections.">
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Fraunces:opsz,wght@9..144,400;9..144,500;9..144,600&family=Public+Sans:wght@400;500;600;700&display=swap">
<style>
/* Hallmark · shape: app screen · genre: editorial · theme: custom · redesign: none
 * idea: "the onboarding's room, with every setting on its shelf" · vibe: "marble-quiet paper, red where to look"
 * paper: #f6f4ee (the dashboard's, by request) · accent: oklch(47% 0.13 255) ink blue, for text that guides and the current section (red recording dot stays red) · display: Fraunces · body: Public Sans
 * nav: a sidebar of seven sections (Home, Library, five settings) · signature: the home page's at-a-glance of what is connected, beside the user's own sprite · states: connected, not connected, disabled, saved
 * axes: light/soft-serif/warm · posture: restrained · contrast: pass · v2.0.0 */
/* Hallmark · pre-emit critique: P4 H4 E4 S4 R4 V4 · weakest: S, a settings window is a known shape; the home page's live status of every connection, next to the user's sprite, is what makes it Nikxel's */
/* Hallmark · waive 65 · cream paper + Fraunces + ink blue · the user asked for the dashboard's paper and Fraunces by name */
:root{
  color-scheme:light dark;
  --color-paper:#f6f4ee; --color-paper-2:#efebe1; --color-card:#fdfcf8; --color-cloud:#dcd6c6;
  --color-ink:#0a0a0a; --color-ink-2:#45423b; --color-muted:#73706a; --color-faint:#a3a097;
  --color-line:#e3e0d6; --color-line-2:#d3cdbd; --color-on-ink:#fdfcf8;
  --color-accent:oklch(47% 0.13 255); --color-accent-text:oklch(43% 0.13 255); --color-focus:oklch(50% 0.13 255);
  --color-rec:oklch(55% 0.2 28); --color-ok:oklch(47% 0.1 152); --color-ok-soft:oklch(93% 0.035 152);
  --color-side:oklch(95.5% 0.008 85 / .72);
  --color-select:oklch(90% 0.05 255); --color-me:oklch(93% 0.03 255); --color-due:oklch(94% 0.04 75); --color-due-text:oklch(45% 0.09 70); --color-mark:oklch(92% 0.06 90);
  --grain:.07; --grain-blend:multiply;
  --color-shade-1:oklch(20% 0.02 80 / .05); --color-shade-2:oklch(30% 0.04 80 / .2); --color-shade-3:oklch(20% 0.02 80 / .14);
  --shadow:0 1px 2px var(--color-shade-1),0 12px 28px -16px var(--color-shade-2);
  --font-display:'Fraunces',Georgia,serif;
  --font-body:'Public Sans',-apple-system,BlinkMacSystemFont,sans-serif;
  --font-code:ui-monospace,'SF Mono',Menlo,monospace;
  --ease:cubic-bezier(.16,1,.3,1);
}
/* Dark: warm charcoal, the paper's night side. The window follows the
   system unless You → Appearance says otherwise (the app sets the window's
   appearance, which is what this media query reads). */
@media (prefers-color-scheme:dark){:root{
  --color-paper:#151411; --color-paper-2:#1d1b17; --color-card:#211f1a; --color-cloud:#2b2822;
  --color-ink:#f2efe7; --color-ink-2:#cdc8bb; --color-muted:#9b968a; --color-faint:#6b675e;
  --color-line:#2d2a24; --color-line-2:#3c3830; --color-on-ink:#151411;
  --color-accent:oklch(72% 0.12 255); --color-accent-text:oklch(78% 0.1 255); --color-focus:oklch(72% 0.12 255);
  --color-rec:oklch(66% 0.19 28); --color-ok:oklch(76% 0.12 152); --color-ok-soft:oklch(30% 0.05 152);
  --color-side:oklch(19% 0.008 85 / .78);
  --color-select:oklch(40% 0.08 255); --color-me:oklch(30% 0.06 255); --color-due:oklch(30% 0.05 75); --color-due-text:oklch(82% 0.09 75); --color-mark:oklch(40% 0.08 90);
  --grain:.05; --grain-blend:screen;
  --color-shade-1:oklch(0% 0 0 / .3); --color-shade-2:oklch(0% 0 0 / .55); --color-shade-3:oklch(0% 0 0 / .4);
}}
*{box-sizing:border-box}
html,body{height:100%;margin:0;overflow-x:clip}
body{background:var(--color-paper);color:var(--color-ink);font:15px/1.5 var(--font-body);-webkit-font-smoothing:antialiased;overflow:clip;
  display:grid;grid-template-columns:248px minmax(0,1fr);grid-template-rows:minmax(0,1fr);-webkit-user-select:none;user-select:none;cursor:default}
body::before{content:'';position:fixed;inset:0;z-index:50;pointer-events:none;opacity:var(--grain);mix-blend-mode:var(--grain-blend);
  background:url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='240' height='240'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='.85' numOctaves='3' stitchTiles='stitch'/%3E%3CfeColorMatrix values='0 0 0 0 .5 0 0 0 0 .5 0 0 0 0 .5 0 0 0 1.4 0'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23n)'/%3E%3C/svg%3E")}
.clouds{position:fixed;inset:0;z-index:0;pointer-events:none;background:var(--color-cloud);
  -webkit-mask:var(--clouds) left bottom / min(1200px,100vw) auto no-repeat;mask:var(--clouds) left bottom / min(1200px,100vw) auto no-repeat}
@keyframes rise{from{opacity:0;transform:translateY(14px);filter:blur(6px)}}
@keyframes fade{from{opacity:0}}
@keyframes leave{to{opacity:0;transform:translateY(-8px);filter:blur(4px)}}
@keyframes slide{from{opacity:0;transform:translateX(-14px)}}
.side{animation:slide 1.3s var(--ease) .15s backwards}
.page [data-in]{animation:rise 1.2s var(--ease) backwards;animation-delay:calc(var(--i,0) * 70ms + 50ms)}
.page.leaving{position:absolute;inset:0 0 auto;pointer-events:none;animation:leave .45s cubic-bezier(.4,0,.2,1) forwards}
input,textarea,code{-webkit-user-select:text;user-select:text}
button,input,select,textarea{font:inherit;color:inherit}
:focus-visible{outline:2px solid var(--color-focus);outline-offset:2px}
::selection{background:var(--color-select);color:var(--color-ink)}
html{caret-color:var(--color-accent);scrollbar-color:var(--color-line-2) transparent}

/* sidebar */
.side{position:relative;z-index:2;display:flex;flex-direction:column;gap:24px;min-height:0;overflow:hidden;padding:56px 16px 20px;background:var(--color-side);border-right:1px solid var(--color-line);-webkit-backdrop-filter:blur(12px);backdrop-filter:blur(12px)}
.brand{display:flex;align-items:center;gap:8px;padding:0 8px}
.brand .sp{width:40px;height:40px}
.mark{font:600 24px/1 var(--font-display);letter-spacing:-.02em}
/* The sections scroll when the window is short; the brand and the record/mute footer stay put. */
.nav{display:flex;flex-direction:column;gap:4px;flex:1 1 auto;min-height:0;overflow-y:auto;overscroll-behavior:contain;scrollbar-width:thin;margin:0 -8px;padding:0 8px}
.nav .label{font:600 11.5px/1 var(--font-body);letter-spacing:.08em;text-transform:uppercase;color:var(--color-faint);padding:16px 12px 8px}
.nav button{display:block;width:100%;text-align:left;border:0;background:transparent;border-radius:12px;padding:10px 12px;cursor:pointer;font:500 15px/1.2 var(--font-body);color:var(--color-ink-2);
  transition:background-color .5s var(--ease),color .5s var(--ease)}
.nav button:hover{background:var(--color-paper-2);color:var(--color-ink)}
.nav button[aria-current="page"]{background:var(--color-card);color:var(--color-accent-text);font-weight:600;box-shadow:inset 0 0 0 1px var(--color-line)}
.side-foot{margin-top:auto;flex:none;display:flex;flex-direction:column;gap:8px}
.rec{display:flex;align-items:center;gap:10px;width:100%;padding:12px 14px;border-radius:14px;border:1px solid var(--color-line);background:var(--color-card);cursor:pointer;font:600 14px/1.2 var(--font-body);color:var(--color-ink);text-align:left;
  transition:border-color .5s var(--ease),background-color .5s var(--ease)}
.rec:hover{border-color:var(--color-line-2)}
.rec .dot{flex:none;width:10px;height:10px;border-radius:50%;background:var(--color-rec)}
.rec.on{border-color:var(--color-rec);color:var(--color-rec)}
.rec.on .dot{border-radius:2px;animation:pulse 1.6s ease-in-out infinite}
@keyframes pulse{50%{opacity:.35}}
.side-foot .link{padding:4px 14px;text-align:left;font-weight:500;color:var(--color-ink-2)}

/* main */
main{position:relative;z-index:1;overflow-y:auto;overflow-x:clip}
main.reading{overflow:hidden}
main.reading .inner{display:none}
.inner{position:relative}
.inner{max-width:800px;margin:0 auto;padding:56px 48px 80px}
.display{font:500 40px/1.08 var(--font-display);letter-spacing:-.025em;margin:0 0 12px;overflow-wrap:break-word;min-width:0;text-wrap: balance}
.lead{font-size:17px;line-height:1.55;color:var(--color-ink-2);margin:0;max-width:56ch;text-wrap:pretty}
.hero{display:grid;grid-template-columns:minmax(0,1fr) auto;gap:24px;align-items:end;margin-bottom:8px}
.hero .sp{width:96px;height:96px}
.group{margin-top:32px}
.group>h2{font:600 19px/1.25 var(--font-display);letter-spacing:-.01em;margin:0 0 12px}
.card{background:var(--color-card);border:1px solid var(--color-line);border-radius:16px;box-shadow:var(--shadow)}
.row{display:grid;grid-template-columns:minmax(0,1fr) auto;gap:24px;align-items:center;padding:16px 20px;border-top:1px solid var(--color-line)}
.row:first-child{border-top:0}
.row.stack{grid-template-columns:minmax(0,1fr)}
.row b{display:block;font-weight:600;font-size:15px}
.row small{display:block;color:var(--color-muted);font-size:13.5px;line-height:1.45;margin-top:2px;max-width:52ch}
.row .ctl{display:flex;align-items:center;gap:8px;justify-content:flex-end;flex-wrap:wrap}
.row.off b,.row.off small{color:var(--color-faint)}

/* controls */
.switch{position:relative;width:44px;height:26px;flex:none;border:0;border-radius:999px;background:var(--color-line-2);cursor:pointer;transition:background-color .5s var(--ease)}
.switch::after{content:'';position:absolute;left:3px;top:3px;width:20px;height:20px;border-radius:50%;background:var(--color-card);box-shadow:0 1px 3px var(--color-shade-3);transition:transform .55s cubic-bezier(.34,1.4,.64,1)}
.switch[aria-checked="true"]{background:var(--color-ink)}
.switch[aria-checked="true"]::after{transform:translateX(18px)}
.switch:disabled{cursor:not-allowed;background:var(--color-paper-2)}
.seg{display:inline-grid;grid-auto-flow:column;gap:4px;padding:4px;border-radius:12px;background:var(--color-paper-2)}
.seg button{border:0;background:transparent;border-radius:8px;padding:8px 12px;cursor:pointer;font:600 13.5px/1 var(--font-body);color:var(--color-muted);white-space:nowrap;
  transition:background-color .5s var(--ease),color .5s var(--ease),box-shadow .5s var(--ease)}
.seg button:hover{color:var(--color-ink)}
.seg button[aria-checked="true"]{background:var(--color-card);color:var(--color-ink);box-shadow:0 1px 3px var(--color-shade-3)}
.choices{display:flex;flex-direction:column;gap:8px;margin-top:12px}
.choice{display:flex;gap:12px;align-items:center;text-align:left;width:100%;padding:12px 16px;border-radius:12px;border:1px solid var(--color-line);background:var(--color-paper);cursor:pointer;font:500 14.5px var(--font-body);color:var(--color-ink-2);
  transition:border-color .5s var(--ease),background-color .5s var(--ease)}
.choice:hover{border-color:var(--color-line-2)}
.choice[aria-checked="true"]{border-color:var(--color-ink);background:var(--color-card);color:var(--color-ink)}
.radio{flex:none;width:16px;height:16px;border-radius:50%;border:1.5px solid var(--color-line-2);display:grid;place-items:center}
.radio::after{content:'';width:8px;height:8px;border-radius:50%;background:var(--color-ink);transform:scale(0);transition:transform .5s cubic-bezier(.34,1.56,.64,1)}
[aria-checked="true"]>.radio{border-color:var(--color-ink)}
[aria-checked="true"]>.radio::after{transform:scale(1)}
select,.text,.num{height:36px;border:1px solid var(--color-line);border-radius:10px;background:var(--color-paper);padding:0 12px;font:500 14px var(--font-body);color:var(--color-ink);outline:none;
  transition:border-color .5s var(--ease),background-color .5s var(--ease)}
select{padding-right:8px;cursor:pointer}
select:hover,.text:hover,.num:hover{border-color:var(--color-line-2)}
select:focus-visible,.text:focus-visible,.num:focus-visible,textarea:focus-visible{outline:2px solid var(--color-focus);outline-offset:1px;background:var(--color-card)}
select:disabled,.num:disabled{color:var(--color-faint);cursor:not-allowed}
.text{width:240px}
.num{width:76px}
textarea{width:100%;min-height:120px;resize:vertical;border:1px solid var(--color-line);border-radius:12px;background:var(--color-paper);padding:12px 16px;font:15px/1.55 var(--font-body);color:var(--color-ink);outline:none;margin-top:12px}
textarea::placeholder,.text::placeholder{color:var(--color-faint)}
.btn{font:600 14px/1 var(--font-body);border:1px solid transparent;border-radius:999px;padding:10px 16px;cursor:pointer;display:inline-flex;align-items:center;gap:8px;white-space:nowrap;color:var(--color-ink);background:var(--color-card);border-color:var(--color-line);
  transition:transform .45s var(--ease),background-color .45s var(--ease),border-color .45s var(--ease),box-shadow .45s var(--ease)}
.btn:hover{border-color:var(--color-line-2);transform:translateY(-1px)}
.btn:active{transform:scale(.97)}
.btn.primary{background:var(--color-ink);color:var(--color-on-ink);border-color:var(--color-ink);box-shadow:0 8px 18px -10px var(--color-ink)}
.link{border:0;background:transparent;padding:4px 0;cursor:pointer;font:600 14px/1.3 var(--font-body);color:var(--color-accent-text);border-radius:4px;transition:color .4s var(--ease)}
.link:hover{color:var(--color-ink)}
.chip{font:500 12.5px/1 var(--font-body);padding:6px 10px;border-radius:999px;background:var(--color-paper-2);color:var(--color-ink-2);white-space:nowrap}
.chip.ok{background:var(--color-ok-soft);color:var(--color-ok)}
.saved{font-size:13px;color:var(--color-ok);opacity:0;transition:opacity .6s var(--ease)}
.saved.on{opacity:1}
code.path{font:13px var(--font-code);background:var(--color-paper-2);padding:6px 10px;border-radius:8px;max-width:320px;overflow-x:auto;white-space:nowrap}

/* home */
.stats{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:12px}
.stat{display:flex;flex-direction:column;gap:8px;padding:16px 20px;border-radius:16px;background:var(--color-card);border:1px solid var(--color-line);box-shadow:var(--shadow);min-width:0}
.stat h3{margin:0;display:flex;flex-direction:column;align-items:flex-start;gap:8px;font:600 17px/1.25 var(--font-display);letter-spacing:-.01em}
.stat p{margin:0;font-size:13.5px;line-height:1.45;color:var(--color-muted);flex:1}
.stat .link{align-self:flex-start}
.usage{font:500 22px/1.3 var(--font-display);margin:0}
.actions{display:flex;flex-wrap:wrap;gap:8px}
.banner{display:flex;align-items:center;justify-content:space-between;gap:16px;padding:16px 20px;margin-top:24px;border-radius:16px;background:var(--color-card);border:1px solid var(--color-line)}
.banner p{margin:0;color:var(--color-ink-2)}
.banner b{color:var(--color-accent-text)}

/* library */
.tabs{display:flex;gap:4px;flex-wrap:wrap;align-items:center;justify-content:space-between;margin-top:24px}
.tabs .seg button span{color:var(--color-faint);font-weight:500;margin-left:6px}
.search{width:240px}
.list{margin-top:16px}
.item{display:grid;grid-template-columns:minmax(0,1fr) auto;gap:16px;align-items:center;width:100%;text-align:left;border:0;border-top:1px solid var(--color-line);background:transparent;padding:14px 20px;cursor:pointer;font:inherit;color:inherit;
  transition:background-color .4s var(--ease)}
.item:first-child{border-top:0}
.item:hover{background:var(--color-paper)}
.item:first-child:hover{border-radius:16px 16px 0 0}
.item:last-child:hover{border-radius:0 0 16px 16px}
.item b{display:block;font-weight:600;font-size:15px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.item small{display:block;color:var(--color-muted);font-size:13.5px;margin-top:2px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.item time{font-size:13px;color:var(--color-muted);white-space:nowrap;display:flex;gap:8px;align-items:center}
.empty{padding:32px 20px;color:var(--color-muted);text-align:center}
/* chat */
main.chatting{overflow:hidden}
main.chatting .inner{max-width:1120px;height:100%;padding-bottom:32px}
main.chatting .inner>div{height:100%;display:flex;flex-direction:column}
.chat-head{display:flex;align-items:flex-end;justify-content:space-between;gap:24px}
.chatwrap{flex:1;min-height:0;display:grid;grid-template-columns:minmax(0,1fr) 280px;gap:16px;margin-top:24px}
.convo{display:flex;flex-direction:column;min-height:0;overflow:hidden}
.log{flex:1;min-height:0;overflow-y:auto;display:flex;flex-direction:column;gap:12px;padding:24px}
.log>:first-child{margin-top:auto}
.msg{max-width:82%;padding:10px 16px;border-radius:18px;font-size:15px;line-height:1.55;-webkit-user-select:text;user-select:text;animation:rise .5s var(--ease) backwards;overflow-wrap:break-word}
.msg.bot{align-self:flex-start;background:var(--color-paper);border:1px solid var(--color-line);border-bottom-left-radius:6px}
.msg.me{align-self:flex-end;background:var(--color-ink);color:var(--color-on-ink);border-bottom-right-radius:6px;white-space:pre-wrap}
.msg p{margin:0 0 8px}.msg p:last-child{margin:0}
.msg ul,.msg ol{margin:4px 0;padding-left:20px}.msg li{margin:2px 0}
.msg code{font:13px var(--font-code);background:var(--color-paper-2);padding:1px 5px;border-radius:4px}
.msg .h{display:block;font-weight:600;margin:6px 0 2px}.msg .h:first-child{margin-top:0}
.msg .hint{color:var(--color-muted);font-size:13px;margin-left:8px}
.dots{display:inline-flex;gap:4px;padding:4px 0}
.dots i{width:6px;height:6px;border-radius:50%;background:var(--color-faint);animation:bob 1.1s infinite}
.dots i:nth-child(2){animation-delay:.15s}.dots i:nth-child(3){animation-delay:.3s}
@keyframes bob{0%,70%,100%{opacity:.3;transform:none}35%{opacity:1;transform:translateY(-3px)}}
.hello{align-self:center;text-align:center;max-width:46ch;color:var(--color-muted);margin:auto 0}
.hello .sp{width:72px;height:72px;margin:0 auto 12px}
.hello p{margin:0 0 16px}
.suggest{display:flex;flex-wrap:wrap;gap:8px;justify-content:center}
.suggest button{border:1px solid var(--color-line);background:var(--color-paper);border-radius:999px;padding:8px 14px;font:500 13.5px var(--font-body);color:var(--color-ink-2);cursor:pointer;transition:border-color .4s var(--ease),color .4s var(--ease)}
.suggest button:hover{border-color:var(--color-accent);color:var(--color-accent-text)}
.field{flex:none;display:flex;align-items:center;gap:8px;margin:0 16px 16px;padding:6px 6px 6px 18px;border:1px solid var(--color-line-2);border-radius:999px;background:var(--color-paper);transition:border-color .4s var(--ease)}
.field:focus-within{border-color:var(--color-accent)}
.field input{flex:1;min-width:0;border:0;outline:0;background:transparent;font:15px var(--font-body);color:var(--color-ink);padding:8px 0}
.field input::placeholder{color:var(--color-faint)}
.icon{flex:none;width:36px;height:36px;border-radius:50%;border:0;display:grid;place-items:center;cursor:pointer;background:transparent;color:var(--color-muted);transition:background-color .3s var(--ease)}
.icon:hover:not(:disabled){background:var(--color-paper-2)}
.icon:disabled{opacity:.35;cursor:default}
.icon svg{width:17px;height:17px}
.icon.go{background:var(--color-accent);color:var(--color-on-ink)}
.icon.go:hover:not(:disabled){background:var(--color-accent-text)}
.icon.rec{background:var(--color-rec);color:var(--color-on-ink);animation:pulse 1.4s ease-in-out infinite}
.srcs{padding:20px;overflow-y:auto;min-height:0}
.srcs h2{font:600 17px/1.25 var(--font-display);margin:0 0 4px}
.srcs>p{margin:0 0 12px;font-size:13px;color:var(--color-muted)}
.src{display:grid;grid-template-columns:10px minmax(0,1fr);gap:10px;padding:10px 0;border-top:1px solid var(--color-line)}
.src i{width:8px;height:8px;border-radius:50%;margin-top:6px;background:var(--color-line-2)}
.src.on i{background:var(--color-ok)}
.src b{display:block;font-size:14px;font-weight:600}
.src small{display:block;font-size:12.5px;line-height:1.4;color:var(--color-muted)}
.src.off b{color:var(--color-muted)}
@media (max-width:1000px){.chatwrap{grid-template-columns:minmax(0,1fr)}.srcs{display:none}}
/* today, tasks, people, activity */
.live{display:flex;align-items:center;gap:16px;padding:16px 20px;margin-top:24px;border-radius:16px;background:var(--color-card);border:1px solid var(--color-rec);box-shadow:var(--shadow)}
.live .dot{flex:none;width:12px;height:12px;border-radius:3px;background:var(--color-rec);animation:pulse 1.6s ease-in-out infinite}
.live b{font:600 17px/1.2 var(--font-display)}
.live .clock{font:500 22px/1 var(--font-code);font-variant-numeric:tabular-nums;color:var(--color-rec);margin-left:auto}
.live small{display:block;color:var(--color-muted);font-size:13px}
.today{display:grid;grid-template-columns:minmax(0,1fr) minmax(0,1fr);gap:12px}
.today .card{padding:4px 0}
.today h3{font:600 15px/1.2 var(--font-body);margin:0;padding:14px 20px 6px;color:var(--color-ink-2)}
.ev{display:grid;grid-template-columns:64px minmax(0,1fr) auto;gap:12px;align-items:center;padding:10px 20px;border-top:1px solid var(--color-line)}
.ev time{font:500 13.5px var(--font-code);color:var(--color-muted);font-variant-numeric:tabular-nums}
.ev b{font-weight:600;font-size:14.5px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.ev.now time{color:var(--color-accent-text)}
.ev.past{opacity:.5}
.none{padding:10px 20px 16px;color:var(--color-muted);font-size:14px;margin:0}
.tk{display:grid;grid-template-columns:22px minmax(0,1fr) auto;gap:12px;align-items:start;padding:12px 20px;border-top:1px solid var(--color-line)}
.tk:first-child{border-top:0}
.box{width:18px;height:18px;margin-top:2px;border-radius:6px;border:1.5px solid var(--color-line-2);background:var(--color-paper);cursor:pointer;display:grid;place-items:center;padding:0;transition:background-color .3s var(--ease),border-color .3s var(--ease)}
.box:hover{border-color:var(--color-accent)}
.box[aria-checked="true"]{background:var(--color-accent);border-color:var(--color-accent)}
.box[aria-checked="true"]::after{content:'';width:8px;height:4px;border:2px solid var(--color-on-ink);border-top:0;border-right:0;transform:translateY(-1px) rotate(-45deg)}
.tk .t{font-size:14.5px;line-height:1.45}
.tk.done .t{color:var(--color-faint);text-decoration:line-through}
.tk .meta{display:flex;flex-wrap:wrap;gap:6px;margin-top:6px}
.tk .meta .link{font-size:13px;padding:2px 0}
.chip.me{background:var(--color-me);color:var(--color-accent-text)}
.chip.due{background:var(--color-due);color:var(--color-due-text)}
.people{display:grid;grid-template-columns:repeat(auto-fill,minmax(220px,1fr));gap:12px;margin-top:24px}
.person{display:flex;flex-direction:column;gap:6px;text-align:left;padding:16px 18px;border-radius:16px;background:var(--color-card);border:1px solid var(--color-line);box-shadow:var(--shadow);cursor:pointer;font:inherit;color:inherit;
  transition:border-color .4s var(--ease),transform .4s var(--ease)}
.person:hover{border-color:var(--color-line-2);transform:translateY(-1px)}
.ini{width:40px;height:40px;border-radius:50%;display:grid;place-items:center;font:600 15px var(--font-body);background:var(--color-paper-2);color:var(--color-ink-2)}
.person b{font:600 16px/1.25 var(--font-display)}
.person small{color:var(--color-muted);font-size:13px}
.owe{display:flex;gap:6px;flex-wrap:wrap;margin-top:4px}
.who{display:flex;align-items:center;gap:16px}
.who .ini{width:56px;height:56px;font-size:19px}
.reply{display:grid;grid-template-columns:56px minmax(0,1fr) auto;gap:12px;align-items:start;padding:12px 20px;border-top:1px solid var(--color-line)}
.reply:first-child{border-top:0}
.reply time{font:500 13px var(--font-code);color:var(--color-muted);padding-top:2px}
.reply b{font-size:14.5px}
.reply p{margin:2px 0 0;font-size:14px;color:var(--color-ink-2);overflow-wrap:break-word}
.reply .link{font-size:13px;white-space:nowrap}
.chart{padding:20px 20px 12px}
.bars{position:relative;display:grid;grid-template-columns:repeat(14,minmax(0,1fr));gap:6px;align-items:end;height:160px;border-bottom:1px solid var(--color-line-2)}
.bar{position:relative;height:100%;display:flex;align-items:flex-end;justify-content:center;cursor:default}
.bar i{display:block;width:min(100%,22px);min-height:2px;border-radius:4px 4px 0 0;background:var(--color-accent);transition:opacity .3s var(--ease)}
.bar.zero i{background:var(--color-line-2)}
.bars:hover .bar i{opacity:.45}
.bars .bar:hover i{opacity:1}
.bar .tip{position:absolute;bottom:calc(100% + 6px);left:50%;transform:translateX(-50%);white-space:nowrap;padding:6px 10px;border-radius:8px;background:var(--color-ink);color:var(--color-on-ink);font-size:12.5px;line-height:1.35;opacity:0;pointer-events:none;transition:opacity .2s;z-index:2}
.bar:hover .tip{opacity:1}
.bar .peak{position:absolute;bottom:calc(var(--h) + 4px);font:500 11.5px var(--font-code);color:var(--color-muted)}
.axis{display:grid;grid-template-columns:repeat(14,minmax(0,1fr));gap:6px;margin-top:6px;font-size:11.5px;color:var(--color-muted);text-align:center}
.lib-match mark{background:var(--color-mark);color:inherit;border-radius:3px;padding:0 1px}
@media (max-width:1000px){.today{grid-template-columns:minmax(0,1fr)}}
/* automations */
.make{display:flex;gap:8px;padding:8px;border-radius:999px;background:var(--color-card);border:1px solid var(--color-line-2);box-shadow:var(--shadow);margin-top:24px;transition:border-color .4s var(--ease)}
.make:focus-within{border-color:var(--color-accent)}
.make input{flex:1;min-width:0;border:0;outline:0;background:transparent;font:15.5px var(--font-body);color:var(--color-ink);padding:8px 14px}
.make input::placeholder{color:var(--color-faint)}
.make-note{margin:8px 0 0 16px;font-size:13.5px;color:var(--color-muted)}
.make-note.err{color:var(--color-rec)}
.draft{padding:20px;display:grid;gap:14px}
.draft label{display:grid;gap:6px;font-weight:600;font-size:14px}
.draft .text{width:100%}
.draft textarea{margin:0;min-height:96px}
.draft .when{display:flex;gap:8px;flex-wrap:wrap;align-items:center}
.auto{display:grid;grid-template-columns:minmax(0,1fr) auto;gap:16px;align-items:start;padding:16px 20px;border-top:1px solid var(--color-line)}
.auto:first-child{border-top:0}
.auto b{font-size:15.5px}
.auto p{margin:6px 0 0;font-size:14px;color:var(--color-ink-2);line-height:1.5;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden}
.auto .meta{display:flex;gap:8px;align-items:center;margin-top:8px;flex-wrap:wrap}
.auto .ctl{display:flex;align-items:center;gap:12px}
.auto.off b,.auto.off p{color:var(--color-faint)}
.ideas{display:grid;grid-template-columns:repeat(auto-fill,minmax(240px,1fr));gap:12px}
.idea{display:flex;flex-direction:column;gap:8px;text-align:left;padding:16px 18px;border-radius:16px;background:var(--color-card);border:1px solid var(--color-line);cursor:pointer;font:inherit;color:inherit;transition:border-color .4s var(--ease),transform .4s var(--ease)}
.idea:hover{border-color:var(--color-accent);transform:translateY(-1px)}
.idea b{font:600 16px/1.3 var(--font-display)}
.idea small{color:var(--color-muted);font-size:13px;line-height:1.45}
.idea .why{color:var(--color-accent-text)}
.idea .use{margin-top:auto;font:600 13.5px var(--font-body);color:var(--color-accent-text)}
.run{padding:14px 20px;border-top:1px solid var(--color-line)}
.run:first-child{border-top:0}
.run header{display:flex;gap:10px;align-items:baseline;flex-wrap:wrap}
.run header time{font:500 13px var(--font-code);color:var(--color-muted)}
.run .out{margin-top:6px;font-size:14px;line-height:1.55;color:var(--color-ink-2);max-height:9.5em;overflow:hidden}
.run .out p{margin:0 0 6px}.run .out ul,.run .out ol{margin:4px 0;padding-left:20px}
.run.skip .out{color:var(--color-faint)}
.busy{display:inline-flex;align-items:center;gap:8px;color:var(--color-muted);font-size:14px}
/* first-run tour: one place at a time, lit, with a note beside it */
.tour-hole{position:fixed;z-index:60;border-radius:14px;pointer-events:none;box-shadow:0 0 0 9999px oklch(15% 0.01 80 / .5),0 0 0 3px var(--color-accent);
  transition:left .5s var(--ease),top .5s var(--ease),width .5s var(--ease),height .5s var(--ease)}
.tour-tip{position:fixed;z-index:61;width:300px;padding:16px 18px 14px;border-radius:16px;background:var(--color-card);border:1px solid var(--color-line);box-shadow:var(--shadow);
  transition:left .5s var(--ease),top .5s var(--ease);animation:rise .6s var(--ease) backwards}
.tour-arrow{position:absolute;left:-62px;top:calc(var(--ay,28px) - 18px);width:58px;height:44px;color:var(--color-accent);overflow:visible;pointer-events:none}
.tour-arrow path{stroke-dasharray:120;stroke-dashoffset:120;animation:pen .6s var(--ease) .2s forwards}
.tour-arrow path.head{animation-delay:.55s}
@keyframes pen{to{stroke-dashoffset:0}}
.tour-tip b{display:block;font:600 17px/1.25 var(--font-display);margin-bottom:4px}
.tour-tip p{margin:0;font-size:14px;color:var(--color-ink-2)}
.tour-tip .row2{display:flex;align-items:center;gap:8px;margin-top:12px}
.tour-tip .row2 .count{margin-right:auto;font-size:12.5px;color:var(--color-muted)}
.tour-block{position:fixed;inset:0;z-index:59}
/* file editor */
textarea.file{min-height:min(56vh,520px);font:14.5px/1.6 var(--font-code);background:var(--color-card);margin-top:0}
/* tab bar: open summaries, like files in an editor */
.tabbar{position:sticky;top:0;z-index:4;height:52px;display:flex;align-items:stretch;background:var(--color-paper-2);border-bottom:1px solid var(--color-line)}
.tabbar[hidden]{display:none}
.tabs-row{flex:1;min-width:0;display:flex;overflow-x:auto;scrollbar-width:none}
.tabs-row::-webkit-scrollbar{display:none}
.tab{position:relative;flex:0 1 220px;min-width:120px;display:flex;align-items:center;gap:8px;padding:0 8px 0 14px;border:0;border-right:1px solid var(--color-line);background:transparent;cursor:pointer;font:500 13.5px var(--font-body);color:var(--color-muted);text-align:left;
  transition:background-color .3s var(--ease),color .3s var(--ease)}
.tab:hover{background:var(--color-paper);color:var(--color-ink-2)}
.tab[aria-selected="true"]{background:var(--color-card);color:var(--color-ink)}
.tab[aria-selected="true"]::before{content:'';position:absolute;left:0;right:0;top:0;height:2px;background:var(--color-accent)}
.tab .tt{flex:1;min-width:0;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.tab svg{flex:none;width:15px;height:15px}
.tab.home{flex:0 0 auto;min-width:0;padding-right:16px;font-weight:600}
.tab .x{flex:none;width:22px;height:22px;border-radius:6px;display:grid;place-items:center;color:var(--color-muted);opacity:0;transition:opacity .2s,background-color .2s}
.tab:hover .x,.tab[aria-selected="true"] .x{opacity:1}
.tab .x:hover{background:var(--color-paper-2);color:var(--color-ink)}
.tab .x svg{width:12px;height:12px}
.tabbar .acts{flex:none;display:flex;align-items:center;gap:16px;padding:0 16px;border-left:1px solid var(--color-line);background:var(--color-card)}
.tabbar .acts .link{font-size:13.5px}
/* folded sidebar: icons only */
body{transition:grid-template-columns .35s var(--ease)}
.rec .lbl{display:flex;flex:1;gap:8px;align-items:center}
.nav button,.side-foot .link{display:flex;align-items:center;gap:12px}
.nav svg,.side-foot svg{flex:none;width:18px;height:18px}
.fold{margin-left:auto;width:28px;height:28px;border:0;border-radius:8px;background:transparent;color:var(--color-muted);cursor:pointer;display:grid;place-items:center}
.fold:hover{background:var(--color-paper-2);color:var(--color-ink)}
.fold svg{width:16px;height:16px;transition:transform .35s var(--ease)}
body.folded{grid-template-columns:76px minmax(0,1fr)}
body.folded .side{padding-left:12px;padding-right:12px}
body.folded .mark,body.folded .nav .lbl,body.folded .side-foot .lbl,body.folded .rec .lbl{display:none}
body.folded .brand{flex-direction:column;padding:0;gap:12px}
body.folded .fold{margin:0}
body.folded .fold svg{transform:rotate(180deg)}
body.folded .nav button{justify-content:center;padding:10px 0}
body.folded .nav .label{height:1px;padding:0;margin:8px 6px;background:var(--color-line);font-size:0}
body.folded .rec{justify-content:center;padding:12px 0}
body.folded .side-foot .link{justify-content:center;padding:4px 0}

@media (max-width:1000px){.stats{grid-template-columns:repeat(2,minmax(0,1fr))}.inner{padding:48px 32px 64px}}
@media (prefers-reduced-motion:reduce){
  .nav button,.switch,.switch::after,.seg button,.choice,.radio::after,.btn,.saved,.rec,.item{transition:none}
  *,*::before,*::after{animation:none!important}
}
</style></head><body>
<div class="clouds" aria-hidden="true"></div>
<aside class="side">
  <div class="brand"><span class="sp"><img class="sprite" alt="" data-row="0" src="data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"></span><span class="mark">nikxel</span>
    <button type="button" class="fold" id="fold" aria-label="Collapse sidebar" title="Collapse sidebar"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M15 18l-6-6 6-6"/></svg></button></div>
  <nav class="nav" id="nav" aria-label="Sections"></nav>
  <div class="side-foot" id="foot"></div>
</aside>
<main id="main"><div class="tabbar" id="tabbar" role="tablist" aria-label="Open summaries" hidden></div><div class="inner" id="inner"><div><h1 class="display">Nikxel</h1><p class="lead">Your settings, one moment…</p></div></div></main>
<script>
(function () {
'use strict';
var reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;
var SECTIONS = [['home', 'Home'], ['chat', 'Chat'], ['library', 'Library'], ['tasks', 'Tasks'], ['automations', 'Automations'], ['people', 'People'], ['activity', 'Activity'], null, ['you', 'You'], ['meetings', 'Recording & notes'], ['whatsapp', 'WhatsApp'], ['connections', 'Connections'], ['advanced', 'Advanced']];
var ICON = {
  home: '<path d="M3 11l9-8 9 8"/><path d="M5 10v10h14V10"/>',
  chat: '<path d="M21 12a8 8 0 0 1-11.6 7.1L4 20l1-4.6A8 8 0 1 1 21 12z"/>',
  library: '<path d="M4 4h6a2 2 0 0 1 2 2v14a2 2 0 0 0-2-2H4z"/><path d="M20 4h-6a2 2 0 0 0-2 2v14a2 2 0 0 1 2-2h6z"/>',
  tasks: '<rect x="3" y="3" width="18" height="18" rx="4"/><path d="M8 12l3 3 5-6"/>',
  people: '<circle cx="9" cy="8" r="3.5"/><path d="M2.5 20a6.5 6.5 0 0 1 13 0"/><path d="M16 4.5a3.5 3.5 0 0 1 0 7M18 14a6.5 6.5 0 0 1 3.5 6"/>',
  activity: '<path d="M3 12h4l3-8 4 16 3-8h4"/>',
  automations: '<path d="M13 2L4 14h7l-1 8 9-12h-7z"/>',
  you: '<circle cx="12" cy="8" r="4"/><path d="M4 21a8 8 0 0 1 16 0"/>',
  meetings: '<rect x="9" y="2" width="6" height="12" rx="3"/><path d="M5 10a7 7 0 0 0 14 0M12 17v5"/>',
  whatsapp: '<path d="M21 12a9 9 0 0 1-13.3 7.9L3 21l1.2-4.5A9 9 0 1 1 21 12z"/><path d="M9 9.5c0 3 2.5 5.5 5.5 5.5"/>',
  connections: '<path d="M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1"/><path d="M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1"/>',
  advanced: '<path d="M4 6h10M18 6h2M4 12h4M12 12h8M4 18h12"/><circle cx="16" cy="6" r="2"/><circle cx="10" cy="12" r="2"/><circle cx="18" cy="18" r="2"/>',
  doc: '<path d="M14 3H6v18h12V7z"/><path d="M14 3v4h4M9 13h6M9 17h4"/>',
  x: '<path d="M6 6l12 12M18 6L6 18"/>',
  mic: '<rect x="9" y="2" width="6" height="12" rx="3"/><path d="M5 10a7 7 0 0 0 14 0M12 17v5"/>'
};
function icon(name) { return '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' + (ICON[name] || ICON.doc) + '</svg>'; }
var KINDS = [['meetings', 'Meetings'], ['notes', 'Notes'], ['daily', 'Days'], ['weekly', 'Weeks']];
var nav = document.getElementById('nav'), main = document.getElementById('main'), inner = document.getElementById('inner'), foot = document.getElementById('foot');
var S = null, current = null, rows = [], tick = 0, libKind = 'meetings', libQuery = '';
var taskView = 'mine', person = null, found = { q: '', list: [] };
var draft = null, making = false, makeText = '', makeError = '', suggesting = false, suggestions = null;
var md = (function () {
\#(AvatarChat.markdownJS)
return md;
})();

// The page is shared with the Windows app (windows/scripts/copy-static.js), whose state says platform: 'win'.
function mac(onMac, onWindows) { return S && S.platform === 'win' ? onWindows : onMac; }
function post(m) { webkit.messageHandlers.nx.postMessage(m); }
function esc(s) {
  return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
    return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
  });
}
var MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
var DAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
// "2026-11-24 17:08" → "Tue 24 Nov · 17:08"; day and week pages have no time.
function when(e) {
  var m = /^(\d{4})-(\d\d)-(\d\d) (\d\d:\d\d)$/.exec(e.date || '');
  if (!m) return '';
  var d = new Date(+m[1], +m[2] - 1, +m[3]);
  var day = DAYS[d.getDay()] + ' ' + d.getDate() + ' ' + MONTHS[d.getMonth()] + (d.getFullYear() !== new Date().getFullYear() ? ' ' + m[1] : '');
  if (e.kind === 'weekly') return 'Week to ' + day;
  return e.kind === 'daily' ? day : day + ' · ' + m[4];
}

// --- the sprite ----------------------------------------------------------------
function frameOf(row, i) {
  var r = rows[row] && rows[row].length ? rows[row] : rows[0];
  return r && r.length ? r[i % r.length] : '';
}
function sprite(row) {
  var src = frameOf(row, 0);
  return '<img class="sprite" alt="" data-row="' + row + '"' + (src ? ' src="' + src + '"' : '') + '>';
}
function paintSprites() {
  document.querySelectorAll('img.sprite').forEach(function (img) {
    var src = frameOf(+img.dataset.row, reduce ? 0 : tick);
    if (src && img.getAttribute('src') !== src) img.src = src;
  });
}
setInterval(function () { if (reduce) return; tick++; paintSprites(); }, 1000 / 3);
// Recording clocks tick in place; the page isn't redrawn for them.
setInterval(function () {
  document.querySelectorAll('.clock[data-since]').forEach(function (el) { if (+el.dataset.since) el.textContent = clock(+el.dataset.since); });
}, 1000);

// --- controls -------------------------------------------------------------------
function row(label, help, control, cls) {
  return '<div class="row' + (cls ? ' ' + cls : '') + '"><div><b>' + label + '</b>' + (help ? '<small>' + help + '</small>' : '') + '</div>' +
    (control ? '<div class="ctl">' + control + '</div>' : '') + '</div>';
}
function group(title, body) { return '<section class="group" data-in><h2>' + title + '</h2><div class="card">' + body + '</div></section>'; }
function sw(key, on, disabled) {
  return '<button type="button" class="switch" role="switch" aria-checked="' + !!on + '" data-key="' + key + '"' + (disabled ? ' disabled' : '') + ' aria-label="' + key + '"></button>';
}
function seg(key, options, value, kind) {
  return '<div class="seg" role="radiogroup" data-kind="' + (kind || 'str') + '">' + options.map(function (o) {
    return '<button type="button" role="radio" aria-checked="' + (String(o[0]) === String(value)) + '" data-key="' + key + '" data-value="' + esc(o[0]) + '">' + esc(o[1]) + '</button>';
  }).join('') + '</div>';
}
function choices(key, options, value) {
  return '<div class="choices" role="radiogroup">' + options.map(function (o) {
    return '<button type="button" class="choice" role="radio" aria-checked="' + (o[0] === value) + '" data-key="' + key + '" data-value="' + esc(o[0]) + '"><span class="radio"></span>' + esc(o[1]) + '</button>';
  }).join('') + '</div>';
}
function select(key, options, value, kind, disabled) {
  var has = options.some(function (o) { return String(o[0]) === String(value); });
  if (!has) options = options.concat([[value, String(value)]]);
  return '<select data-key="' + key + '" data-kind="' + (kind || 'str') + '"' + (disabled ? ' disabled' : '') + '>' + options.map(function (o) {
    return '<option value="' + esc(o[0]) + '"' + (String(o[0]) === String(value) ? ' selected' : '') + '>' + esc(o[1]) + '</option>';
  }).join('') + '</select>';
}
function text(key, value, placeholder) {
  return '<span class="saved" data-saved="' + key + '">Saved</span><input class="text" data-key="' + key + '" data-kind="str" value="' + esc(value) + '" placeholder="' + esc(placeholder || '') + '" spellcheck="false" autocomplete="off">';
}
function num(key, value, min, max, disabled) {
  return '<input class="num" type="number" data-key="' + key + '" data-kind="num" value="' + value + '" min="' + min + '" max="' + max + '"' + (disabled ? ' disabled' : '') + '>';
}
function link(label, act) { return '<button type="button" class="link" data-act="' + act + '">' + label + '</button>'; }
function go(label, section) { return '<button type="button" class="link" data-go="' + section + '">' + label + '</button>'; }
function btn(label, act, cls) { return '<button type="button" class="btn ' + (cls || '') + '" data-act="' + act + '">' + label + '</button>'; }
function chip(on, yes, no) { return '<span class="chip' + (on ? ' ok' : '') + '">' + (on ? (yes || 'Connected') : (no || 'Not connected')) + '</span>'; }
function hourLabel(h) { return h === 0 ? '12 am' : h < 12 ? h + ' am' : h === 12 ? '12 pm' : (h - 12) + ' pm'; }
var HOURS = []; for (var h = 0; h < 24; h++) HOURS.push([h, hourLabel(h)]);
var SUMMARY_TIMES = [[1260, '9 pm'], [1320, '10 pm'], [1380, '11 pm'], [1440, 'Midnight'], [1500, '1 am'], [1560, '2 am']];
function pairs(list) { return list.map(function (x) { return [x.id, x.name]; }); }

// --- today, tasks, people ----------------------------------------------------------
function hhmm(t) { var d = new Date(t * 1000); return ('0' + d.getHours()).slice(-2) + ':' + ('0' + d.getMinutes()).slice(-2); }
function clock(since) {
  var s = Math.max(0, Math.floor(Date.now() / 1000 - since)), h = Math.floor(s / 3600), m = Math.floor(s / 60) % 60;
  return (h ? h + ':' + ('0' + m).slice(-2) : m) + ':' + ('0' + s % 60).slice(-2);
}
function initials(n) { return esc(String(n).split(/\s+/).filter(Boolean).slice(0, 2).map(function (w) { return w[0]; }).join('').toUpperCase()); }
function liveCard(s) {
  if (!s.recording) return '';
  return '<div class="live" data-in><span class="dot"></span><div><b>Recording · ' + esc(s.captureLabel) + '</b><small>' + (s.micMuted ? 'Your mic is muted.' : 'Your mic and the call audio.') + ' The summary is written when you stop.</small></div>' +
    '<span class="clock" data-since="' + s.recordingSince + '">' + clock(s.recordingSince) + '</span>' +
    btn(s.micMuted ? 'Unmute' : 'Mute', 'toggleMicMute') + btn('Stop', 'toggleRecording', 'primary') + '</div>';
}
function taskRow(t) {
  var chips = (t.mine ? '<span class="chip me">You</span>' : t.owner ? '<span class="chip">' + esc(t.owner) + '</span>' : '') +
    (t.due ? '<span class="chip due">Due ' + esc(t.due) + '</span>' : '');
  return '<div class="tk' + (t.done ? ' done' : '') + '"><button type="button" class="box" role="checkbox" aria-checked="' + t.done + '" aria-label="Done" data-md="' + esc(t.md) + '" data-n="' + t.n + '"></button>' +
    '<div><div class="t">' + esc(t.text) + '</div><div class="meta">' + chips +
    '<button type="button" class="link" data-open="' + esc(t.meeting.id) + '">' + esc(t.meeting.title) + ' · ' + esc(when({ date: t.meeting.date, kind: 'meetings' }).split(' · ')[0]) + '</button></div></div></div>';
}
function todayCards(s) {
  var t = s.today || {}, now = Date.now() / 1000;
  var ev = !t.google ? '<p class="none">' + link('Connect Google', 'connectGoogle') + ' to see today’s meetings.</p>'
    : !(t.events || []).length ? '<p class="none">Nothing else on your calendar today.</p>'
    : t.events.map(function (e) {
        var cls = e.end < now ? ' past' : e.start <= now ? ' now' : '';
        return '<div class="ev' + cls + '"><time>' + hhmm(e.start) + '</time><b>' + esc(e.title) + '</b>' +
          (e.link && e.end >= now ? '<button type="button" class="link" data-url="' + esc(e.link) + '">Join</button>' : '') + '</div>';
      }).join('');
  var open = (t.openTasks || []);
  var tasks = !t.dayId ? '<p class="none">No day summary yet.</p>'
    : !open.length ? '<p class="none">Nothing open from ' + esc(when({ date: t.dayDate, kind: 'daily' })) + '.</p>'
    : open.slice(0, 6).map(function (x) {
        return '<div class="tk"><button type="button" class="box" role="checkbox" aria-checked="false" aria-label="Done" data-day="' + esc(t.dayId) + '" data-i="' + x.i + '"></button><div class="t">' + esc(x.text) + '</div></div>';
      }).join('') + (open.length > 6 ? '<p class="none">' + (open.length - 6) + ' more on your ' + '<button type="button" class="link" data-open="' + esc(t.dayId) + '">day page</button>.</p>' : '');
  return '<section class="group" data-in><h2>Today</h2><div class="today"><div class="card"><h3>Coming up</h3>' + ev + '</div>' +
    '<div class="card"><h3>Still open</h3>' + tasks + '</div></div></section>';
}
var TRIGGERS = [['meeting', 'After every meeting'], ['day', 'After my day summary'], ['week', 'After my week summary'], ['schedule', 'On a schedule']];
var DAYSETS = [['daily', 'Every day'], ['weekdays', 'Weekdays'], ['mon', 'Mondays'], ['tue', 'Tuesdays'], ['wed', 'Wednesdays'], ['thu', 'Thursdays'], ['fri', 'Fridays'], ['sat', 'Saturdays'], ['sun', 'Sundays']];
function draftCard() {
  var d = draft;
  return '<section class="group" data-in id="draft"><h2>' + (d.id ? 'Edit automation' : 'New automation') + '</h2><div class="card draft">' +
    '<label>Name<input class="text" data-draft="name" value="' + esc(d.name) + '" autocomplete="off"></label>' +
    '<label>When<span class="when"><select data-draft="trigger">' + TRIGGERS.map(function (t) { return '<option value="' + t[0] + '"' + (t[0] === d.trigger ? ' selected' : '') + '>' + t[1] + '</option>'; }).join('') + '</select>' +
      (d.trigger === 'schedule' ? '<select data-draft="days">' + DAYSETS.map(function (t) { return '<option value="' + t[0] + '"' + (t[0] === d.days ? ' selected' : '') + '>' + t[1] + '</option>'; }).join('') + '</select>' +
        '<input class="text" type="time" data-draft="time" value="' + esc(d.time) + '" style="width:120px">' : '') + '</span></label>' +
    '<label>What I should do<textarea data-draft="instruction" spellcheck="false">' + esc(d.instruction) + '</textarea></label>' +
    '<div class="actions"><button type="button" class="btn primary" data-autosave>Save automation</button><button type="button" class="btn" data-autocancel>Cancel</button></div></div></section>';
}
function redrawAutomations() { if (current === 'automations' && !S.active && !S.editor) show('automations', false); }
function openDraft(a) {
  draft = { id: a.id || '', name: a.name, trigger: a.trigger, time: a.time || '09:00', days: a.days || 'daily', instruction: a.instruction };
  redrawAutomations();
  var el = document.getElementById('draft'); if (el) el.scrollIntoView({ behavior: reduce ? 'auto' : 'smooth', block: 'start' });
}
function personCard(p, i) {
  return '<button type="button" class="person" data-person="' + i + '"><span class="ini">' + initials(p.name) + '</span><b>' + esc(p.name) + '</b>' +
    '<small>' + p.meetings.length + ' meeting' + (p.meetings.length === 1 ? '' : 's') + ' · last ' + esc(when({ date: p.last, kind: 'daily' })) + '</small>' +
    '<span class="owe">' + (p.theirs.length ? '<span class="chip">They owe ' + p.theirs.length + '</span>' : '') + (p.mine.length ? '<span class="chip me">You owe ' + p.mine.length + '</span>' : '') + '</span></button>';
}
function personPage(p) {
  return '<div data-in><p style="margin:0 0 16px"><button type="button" class="link" data-person="">← People</button></p>' +
    '<div class="who"><span class="ini">' + initials(p.name) + '</span><div><h1 class="display" style="margin:0">' + esc(p.name) + '</h1>' +
    '<p class="lead">' + p.meetings.length + ' meeting' + (p.meetings.length === 1 ? '' : 's') + ' together, the last ' + esc(when({ date: p.last, kind: 'daily' })) + '.</p></div></div>' +
    '<div class="actions" style="margin-top:16px"><button type="button" class="btn" data-chatwith="' + esc(p.name) + '">Open WhatsApp chat</button></div></div>' +
    '<section class="group" data-in><h2>You owe ' + esc(p.name.split(' ')[0]) + '</h2><div class="card">' + (p.mine.length ? p.mine.map(taskRow).join('') : '<p class="none" style="padding-top:16px">Nothing open.</p>') + '</div></section>' +
    '<section class="group" data-in><h2>' + esc(p.name.split(' ')[0]) + ' owes you</h2><div class="card">' + (p.theirs.length ? p.theirs.map(taskRow).join('') : '<p class="none" style="padding-top:16px">Nothing open.</p>') + '</div></section>' +
    '<section class="group" data-in><h2>Meetings</h2><div class="card">' + p.meetings.slice(0, 12).map(function (m) { return item({ id: m.id, title: m.title, date: m.date, kind: 'meetings', snippet: '', ext: 'html' }); }).join('') + '</div></section>';
}
function usageChart(days) {
  var max = Math.max.apply(null, days.map(function (d) { return d.cost; }).concat([0.0001])), peak = -1, total = 0, calls = 0;
  days.forEach(function (d, i) { total += d.cost; calls += d.calls; if (peak < 0 || d.cost > days[peak].cost) peak = i; });
  var bars = days.map(function (d, i) {
    var h = d.cost ? Math.max(2, Math.round(d.cost / max * 100)) : 0, label = when({ date: d.day + ' 00:00', kind: 'daily' });
    return '<div class="bar' + (d.cost ? '' : ' zero') + '" style="--h:' + h + '%" aria-label="' + esc(label) + ': $' + d.cost.toFixed(3) + ', ' + d.calls + ' runs">' +
      '<i style="height:' + (d.cost ? h + '%' : '2px') + '"></i><span class="tip">' + esc(label) + '<br>$' + d.cost.toFixed(3) + ' · ' + d.calls + ' run' + (d.calls === 1 ? '' : 's') + '</span>' +
      (i === peak && d.cost ? '<span class="peak">$' + d.cost.toFixed(2) + '</span>' : '') + '</div>';
  }).join('');
  var axis = days.map(function (d, i) { return '<span>' + (i % 2 === (days.length - 1) % 2 ? +d.day.slice(8) : '') + '</span>'; }).join('');
  return '<div class="chart"><p class="usage">$' + total.toFixed(2) + ' <small style="font:400 14px var(--font-body);color:var(--color-muted)">over 14 days · ' + calls + ' runs</small></p>' +
    '<div class="bars" style="margin-top:28px">' + bars + '</div><div class="axis">' + axis + '</div></div>';
}

// --- sections --------------------------------------------------------------------
var VIEWS = {
  home: function (s) {
    var greet = s.hour < 5 ? 'Working late' : s.hour < 12 ? 'Good morning' : s.hour < 17 ? 'Good afternoon' : 'Good evening';
    var st = s.status, mode = (s.waModes.filter(function (m) { return m.id === s.waBotMode; })[0] || {}).name || '';
    var agent = (s.agents.filter(function (a) { return a.id === s.agent; })[0] || {}).name || s.agent;
    function stat(title, on, sub, action) {
      return '<div class="stat"><h3>' + title + chip(on) + '</h3><p>' + sub + '</p>' + action + '</div>';
    }
    return '<div class="hero" data-in><div><h1 class="display">' + greet + (s.name ? ', ' + esc(s.name) : '') + '.</h1>' +
      '<p class="lead">Everything I do, in one place. Change anything here or from the ' + mac('menu bar', 'tray') + '; they stay in step.</p></div>' +
      '<div class="sp">' + sprite(6) + '</div></div>' + liveCard(s) + todayCards(s) +
      '<section class="group" data-in><h2>What’s connected</h2><div class="stats">' +
        stat('WhatsApp', st.whatsapp, st.whatsapp ? (s.botEnabled ? 'Auto-replies on: ' + esc(mode.toLowerCase()) + '.' : 'Auto-replies are off.') : 'Connect to let me reply while you’re busy.',
          st.whatsapp ? go('WhatsApp settings', 'whatsapp') : link('Connect WhatsApp', 'whatsappConnection')) +
        stat('Google', st.google, 'Calendar heads-ups, meeting tasks, and Gmail from the chat.', link(st.google ? 'Reconnect' : 'Connect Google', 'connectGoogle')) +
        stat('Slack', st.slack, 'The day’s messages, in your day summary.', link(st.slack ? 'Manage' : 'Connect Slack', 'connectSlack')) +
        stat(mac('Apple Reminders', 'Google Tasks'), st.reminders, mac('Reminders you add on your phone bubble up on your Mac.', 'Tasks you add on your phone bubble up on your PC.'), link(st.reminders ? 'Manage' : mac('Connect Reminders', 'Connect Google Tasks'), 'connectReminders')) +
        stat('Team dashboard', st.dashboard, 'Send your day to your team, item by item.', link(st.dashboard ? 'Manage' : 'Connect', 'connectDashboard')) +
        '<div class="stat"><h3>Coding agent<span class="chip ok">' + esc(agent) + '</span></h3><p>Writes your minutes, day summaries and replies.</p>' + go('Change', 'you') + '</div>' +
      '</div></section>' +
      (s.library.length ? '<section class="group" data-in><h2>Recent summaries</h2><div class="card">' + s.library.slice(0, 5).map(item).join('') + '</div>' +
        '<p style="margin:12px 0 0">' + go('Everything in the library', 'library') + '</p></section>' : '') +
      group('AI use today', row('<span class="usage">' + esc(s.usageToday) + '</span>',
        s.usageAverage ? 'Daily average this past week: ' + esc(s.usageAverage) + '.' : 'No history yet. Only Claude Code reports cost.', go('Last 14 days', 'activity'))) +
      '<section class="group" data-in><h2>Do it now</h2><div class="actions">' +
        btn('Summarize today', 'summarizeNow', 'primary') + btn('Summarize this week', 'summarizeWeek') +
        btn(s.visible ? 'Hide Nikxel' : 'Show Nikxel', 'toggleVisibility') +
      '</div></section>';
  },

  chat: function (s) {
    return '<div class="chat-head" data-in><div><h1 class="display">Chat</h1><p class="lead">Ask about your meetings, days, projects, WhatsApp and mail, the same as clicking me on screen.</p></div>' +
      btn('New chat', 'chatNew') + '</div>' +
      '<div class="chatwrap" data-in><div class="card convo"><div class="log" id="log">' + logHTML() + '</div>' +
        '<form class="field" id="chatf"><input id="ci" placeholder="Ask anything…" autocomplete="off" spellcheck="false" aria-label="Message" value="' + esc(chatDraft) + '">' +
        '<button type="button" class="icon" data-chat="mic" aria-label="Speak"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="9" y="2" width="6" height="12" rx="3"/><path d="M5 10a7 7 0 0 0 14 0M12 17v5"/></svg></button>' +
        '<button class="icon go" data-chat="send" aria-label="Send"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M12 19V5M5 12l7-7 7 7"/></svg></button></form></div>' +
      '<aside class="card srcs"><h2>What I can see</h2><p>Each question is answered from these.</p><div id="srcs">' + sourcesHTML() + '</div></aside></div>';
  },

  tasks: function (s) {
    var list = s.tasks.filter(function (t) { return taskView === 'done' ? t.done : !t.done && (taskView === 'all' || t.mine); });
    list.sort(function (a, b) { return a.meeting.date < b.meeting.date ? 1 : a.meeting.date > b.meeting.date ? -1 : a.n - b.n; });
    var mine = s.tasks.filter(function (t) { return t.mine && !t.done; }).length, open = s.tasks.filter(function (t) { return !t.done; }).length;
    return '<div data-in><h1 class="display">Tasks</h1><p class="lead">Every action item from your meetings and notes. Tick one here and it’s ticked in the summary too.</p></div>' +
      '<div class="tabs" data-in><div class="seg" role="tablist">' + [['mine', 'Yours', mine], ['all', 'Everyone’s', open], ['done', 'Done', s.tasks.length - open]].map(function (k) {
        return '<button type="button" role="tab" aria-checked="' + (k[0] === taskView) + '" data-taskview="' + k[0] + '">' + k[1] + '<span>' + k[2] + '</span></button>';
      }).join('') + '</div></div>' +
      '<div class="card list" data-in>' + (list.length ? list.slice(0, 200).map(taskRow).join('') : '<p class="empty">' + (taskView === 'done' ? 'Nothing ticked yet.' : 'Nothing open. Nice.') + '</p>') + '</div>';
  },

  automations: function (s) {
    var mine = s.automations.length ? s.automations.map(function (a) {
      var on = a.id === s.automationRunning;
      return '<div class="auto' + (a.enabled ? '' : ' off') + '"><div><b>' + esc(a.name) + '</b><p>' + esc(a.instruction) + '</p>' +
        '<div class="meta"><span class="chip">' + esc(a.when) + '</span>' + (on ? '<span class="busy"><span class="dots"><i></i><i></i><i></i></span>Running…</span>' : '') + '</div></div>' +
        '<div class="ctl">' + '<button type="button" class="link" data-autorun="' + esc(a.id) + '"' + (on ? ' disabled' : '') + '>Run now</button>' +
        '<button type="button" class="link" data-autoedit="' + esc(a.id) + '">Edit</button>' +
        '<button type="button" class="link" data-autodel="' + esc(a.id) + '">Delete</button>' +
        '<button type="button" class="switch" role="switch" aria-checked="' + a.enabled + '" aria-label="On" data-autotoggle="' + esc(a.id) + '"></button></div></div>';
    }).join('') : '<p class="empty">None yet. Describe one above, or start from an idea below.</p>';
    var have = s.automations.map(function (a) { return a.name.toLowerCase(); });
    function ideaCard(a, i, from) {
      return '<button type="button" class="idea" data-' + from + '="' + i + '"><span class="chip" style="align-self:flex-start">' + esc(a.when) + '</span><b>' + esc(a.name) + '</b>' +
        (a.why ? '<small class="why">' + esc(a.why) + '</small>' : '') + '<small>' + esc(a.instruction) + '</small><span class="use">Use this →</span></button>';
    }
    var suggested = suggesting ? '<p class="busy" style="padding:4px 0"><span class="dots"><i></i><i></i><i></i></span>Reading your last two weeks to find what’s worth automating…</p>'
      : suggestions === null ? '<div class="banner" style="margin-top:0"><p>I can look at your recent meetings, days and notes and suggest automations made for <b>your</b> work.</p>' + '<button type="button" class="btn primary" data-autosuggest>Suggest some</button></div>'
      : suggestions.length ? '<div class="ideas">' + suggestions.map(function (a, i) { return ideaCard(a, i, 'sugg'); }).join('') + '</div><p style="margin:12px 0 0"><button type="button" class="link" data-autosuggest>Suggest others</button></p>'
      : '<p class="lead">Nothing stood out yet. Try again after a few more meetings.</p>';
    // Every bubble Nikxel raised about how you work, in case one was missed: an open offer can still be answered here.
    var made = (s.nikxelSuggested || []).length ? s.nikxelSuggested.map(function (x) {
      var d = new Date(x.t * 1000), day = d.getFullYear() + '-' + ('0' + (d.getMonth() + 1)).slice(-2) + '-' + ('0' + d.getDate()).slice(-2);
      var ctl = x.kind !== 'offer' ? '<span class="chip">Idea</span>'
        : x.answer === 'yes' ? '<span class="chip">You said yes</span>' : x.answer === 'no' ? '<span class="chip">You said no</span>'
        : '<button type="button" class="btn primary" data-learnyes="' + esc(x.key) + '">Yes, do it</button><button type="button" class="link" data-learnno="' + esc(x.key) + '">No thanks</button>';
      return '<div class="auto"><div><b>' + esc(x.title) + '</b><p>' + esc(x.line) + '</p><div class="meta"><span class="chip">' + esc(when({ date: day + ' ' + hhmm(x.t), kind: 'meetings' })) + '</span></div></div><div class="ctl">' + ctl + '</div></div>';
    }).join('') : '<p class="empty">Nothing yet. As I learn how you work, my ideas show up here, even the ones you missed on screen.</p>';
    var runs = s.automationRuns.length ? s.automationRuns.slice(0, 15).map(function (r) {
      return '<div class="run' + (r.skipped ? ' skip' : '') + '"><header><time>' + esc(when({ date: (function (d) { return d.getFullYear() + '-' + ('0' + (d.getMonth() + 1)).slice(-2) + '-' + ('0' + d.getDate()).slice(-2); })(new Date(r.t * 1000)) + ' ' + hhmm(r.t), kind: 'meetings' })) + '</time><b>' + esc(r.name) + '</b>' +
        (r.file ? '<button type="button" class="link" data-open="' + esc(r.file) + '">Open summary</button>' : '') + '</header>' +
        '<div class="out">' + (r.skipped ? 'Nothing to do this time.' : md(r.text)) + '</div></div>';
    }).join('') : '<p class="empty">Nothing has run yet.</p>';
    return '<div data-in><h1 class="display">Automations</h1><p class="lead">Tell me what to do when something happens, and I’ll do it every time: answer, draft an email, or make an ERP task. I never send anything without you.</p></div>' +
      '<div data-in><form class="make" id="makef"><input id="mk" placeholder="e.g. After every client call, draft a follow-up email with the next steps" value="' + esc(makeText) + '" autocomplete="off" spellcheck="false" aria-label="Describe an automation"' + (making ? ' disabled' : '') + '>' +
        '<button class="btn primary"' + (making ? ' disabled' : '') + '>' + (making ? 'Working it out…' : 'Make it') + '</button></form>' +
        (makeError ? '<p class="make-note err">' + esc(makeError) + '</p>' : '<p class="make-note">Say when it should run and what I should do. You’ll see it before it’s saved.</p>') + '</div>' +
      (draft ? draftCard() : '') +
      '<section class="group" data-in><h2>Yours</h2><div class="card">' + mine + '</div></section>' +
      '<section class="group" data-in><h2>What I’ve suggested</h2><div class="card">' + made + '</div></section>' +
      '<section class="group" data-in><h2>Suggested for you</h2>' + suggested + '</section>' +
      '<section class="group" data-in><h2>Ideas to start with</h2><div class="ideas">' + s.ideas.filter(function (a) { return have.indexOf(a.name.toLowerCase()) < 0; }).map(function (a) { return ideaCard(a, s.ideas.indexOf(a), 'idea'); }).join('') + '</div></section>' +
      '<section class="group" data-in><h2>Recent runs</h2><div class="card">' + runs + '</div></section>';
  },

  people: function (s) {
    var p = person != null && s.people[person];
    if (p) return personPage(p);
    return '<div data-in><h1 class="display">People</h1><p class="lead">Everyone from your meetings: what you’ve met about, and what’s still open between you.</p></div>' +
      (s.people.length ? '<div class="people" data-in>' + s.people.map(personCard).join('') + '</div>' : '<p class="lead" data-in style="margin-top:24px">No one yet. People show up here from your meeting minutes.</p>');
  },

  activity: function (s) {
    var never = s.neverReply.map(function (n) { return n.toLowerCase(); });
    var replies = s.botReplies.length ? s.botReplies.map(function (r) {
      var muted = never.indexOf(String(r.name).toLowerCase()) >= 0;
      return '<div class="reply"><time>' + hhmm(r.t) + '</time><div><b>' + esc(r.name) + '</b><p>' + esc(r.text) + '</p></div>' +
        (muted ? '<span class="chip">Never replying</span>' : '<button type="button" class="link" data-never="' + esc(r.name) + '">Don’t reply again</button>') + '</div>';
    }).join('') : '<p class="empty">No replies sent today.</p>';
    return '<div data-in><h1 class="display">Activity</h1><p class="lead">What I did for you on WhatsApp today, and what the AI has cost.</p></div>' +
      '<section class="group" data-in><h2>WhatsApp replies today</h2><div class="card">' + replies + '</div></section>' +
      '<section class="group" data-in><h2>AI use, last 14 days</h2><div class="card">' + usageChart(s.usageDays) + '</div>' +
      '<p style="margin:12px 0 0">' + link('Open usage log', 'openUsage') + '</p></section>';
  },

  library: function (s) {
    var counts = {};
    s.library.forEach(function (e) { counts[e.kind] = (counts[e.kind] || 0) + 1; });
    return '<div data-in><h1 class="display">Library</h1><p class="lead">Every summary I’ve written. Open one to read, share, edit or rename it right here.</p></div>' +
      '<div class="tabs" data-in><div class="seg" role="tablist">' + KINDS.map(function (k) {
        return '<button type="button" role="tab" aria-checked="' + (k[0] === libKind) + '" data-kindtab="' + k[0] + '">' + k[1] + '<span>' + (counts[k[0]] || 0) + '</span></button>';
      }).join('') + '</div>' +
      '<input class="text search" id="q" type="search" placeholder="Search every summary" value="' + esc(libQuery) + '" spellcheck="false" autocomplete="off" aria-label="Search every summary"></div>' +
      '<div class="card list" id="list" data-in>' + libraryList(s) + '</div>';
  },

  you: function (s) {
    return '<div data-in><h1 class="display">You</h1><p class="lead">Who you are and how I work for you. I keep all of this in mind in every summary and reply.</p></div>' +
      group('How I know you',
        row('Your name in notes', 'What I call you in meeting minutes and summaries.', text('userName', s.name, 'Your first name')) +
        row('Your name on WhatsApp', 'As it shows in WhatsApp, so I can tell your messages apart.', text('waOwnName', s.waOwnName, 'Your WhatsApp name'))) +
      '<section class="group" data-in><h2>About you</h2><div class="card"><div class="row stack"><div><b>Your role, your company, what you’re aiming for</b>' +
        '<small>A few lines is plenty. Every summary and reply follows it.</small>' +
        '<textarea id="ctx" placeholder="I’m a developer at Forklyft, building the POS. I care about shipping fast and keeping things simple…">' + esc(s.userContext) + '</textarea>' +
        '<div class="actions" style="margin-top:12px;align-items:center">' + '<button type="button" class="btn primary" data-save="userContext">Save</button>' +
        '<span class="saved" data-saved="userContext">Saved</span>' + link('Prefer to talk? Use the voice version', 'aboutMeVoice') + '</div></div></div></div></section>' +
      group('How I work',
        row('Coding agent', 'The AI on your ' + mac('Mac', 'PC') + ' that writes my minutes, summaries and replies.', select('agent', pairs(s.agents), s.agent)) +
        row('Language I write in', 'Match the meeting or chat, or always use one language.', seg('language', [['auto', 'Match'], ['English', 'English'], ['Hindi', 'Hindi']], s.language)) +
        row('Appearance', 'Match your computer, or always light or dark.', seg('appearance', [['system', 'Auto'], ['light', 'Light'], ['dark', 'Dark']], s.appearance)) +
        row('My size on screen', 'Smaller suits a 13-inch screen.', seg('avatarSize', [[0.6, 'S'], [0.8, 'M'], [1, 'L'], [1.25, 'XL']], s.avatarSize, 'num')) +
        row('How I look', 'Turn your own photo into my character with Gemini.', link('Open the avatar step', 'setupWizard')));
  },

  meetings: function (s) {
    var tpl = (s.templates.filter(function (t) { return t.id === s.summaryTemplate; })[0] || {}).name || s.summaryTemplate;
    return '<div data-in><h1 class="display">Recording & notes</h1><p class="lead">How I record, what I write, and when your day gets written up.</p></div>' +
      group('Recording',
        row('What I’m recording', 'Meetings get minutes per speaker. Videos and lectures get key points and quotes.', seg('captureMode', [['meeting', 'Meetings'], ['notes', 'Videos & lectures']], s.captureMode)) +
        row('Meeting language', 'English also transcribes Hindi, as Hinglish.', seg('transcriptionLanguage', [['en', 'English'], ['hi', 'Hindi'], ['auto', 'Auto']], s.transcriptionLanguage)) +
        row('Record calls without asking', 'When I notice a Google Meet or WhatsApp call, start recording straight away.', sw('autoRecordCalls', s.autoRecordCalls)) +
        row('In-person meeting mode', 'For meetings in a room, when there’s no call for me to notice.', sw('forceMeeting', s.forceMeeting))) +
      group('What I write',
        row('Note format', 'The file your minutes and notes are saved as.', select('noteFormat', pairs(s.noteFormats), s.noteFormat)) +
        row('Day summary time', 'When I write up your day. Later suits late nights.', select('summaryMinutes', SUMMARY_TIMES, s.summaryMinutes, 'num')) +
        row('Send meeting tasks to Google', 'Offer to add action items to Google Tasks. I always show the list first.', sw('googleSyncEnabled', s.googleSyncEnabled)) +
        row('Open summaries in Nikxel', 'Off opens them in your browser instead.', sw('openInApp', s.openInApp))) +
      group('Templates',
        row('Summary template', 'The structure your minutes follow.', select('summaryTemplate', pairs(s.templates), s.summaryTemplate)) +
        row('Change “' + esc(tpl) + '”', s.templateShipped ? 'Reset puts back the built-in version.' : 'Delete sends summaries back to the Default template.',
          link('Edit…', 'editTemplate') + (s.templateShipped ? link('Reset…', 'resetTemplate') : link('Delete…', 'deleteTemplate'))) +
        row('More templates', 'One per kind of meeting: client calls, design reviews, the board.', link('New…', 'newTemplate') + link('Open folder', 'openTemplates'))) +
      group('Your files',
        row('Meeting minutes', '', link('Open folder', 'openMeetings')) +
        row('Notes', '', link('Open folder', 'openNotes')) +
        row('Day summaries', '', link('Open folder', 'openDaily')) +
        row('A summary that didn’t finish', 'The transcript is saved first, so it can be written again.', link('Regenerate…', 'regenerate')));
  },

  whatsapp: function (s) {
    var connected = s.status.whatsapp, unattended = s.waBotMode === 'unattended';
    return '<div data-in><h1 class="display">WhatsApp</h1><p class="lead">When I reply for you, how, and what I know when I do.</p></div>' +
      (connected ? '' : '<div class="banner" data-in><p><b>WhatsApp isn’t connected.</b> These settings take effect once it is.</p>' + btn('Connect WhatsApp', 'whatsappConnection', 'primary') + '</div>') +
      '<section class="group" data-in><h2>Replies</h2><div class="card">' +
        row('Auto-replies', 'Turn off to pause every reply at once.', sw('botEnabled', s.botEnabled)) +
        '<div class="row stack"><div><b>When to reply</b><small>Quiet hours below apply outside meetings.</small>' + choices('waBotMode', pairs(s.waModes), s.waBotMode) + '</div></div>' +
        row('Wait before replying', 'For “if unanswered for a while”: minutes a message sits before I answer.', num('waUnattendedMinutes', s.waUnattendedMinutes, 1, 120, !unattended) + '<span class="chip">min</span>', unattended ? '' : 'off') +
        row('Group chats', 'Only when someone @-mentions you.', sw('waGroupReplies', s.waGroupReplies)) +
        row('Draft only', 'Type the reply into the chat and let you press send.', sw('waDraftOnly', s.waDraftOnly)) +
      '</div></section>' +
      group('Quiet hours',
        row('Quiet hours', 'No replies overnight.', sw('waQuietHours', s.waQuietHours)) +
        row('From', '', select('waQuietFrom', HOURS, s.waQuietFrom, 'num', !s.waQuietHours), s.waQuietHours ? '' : 'off') +
        row('Until', '', select('waQuietTo', HOURS, s.waQuietTo, 'num', !s.waQuietHours), s.waQuietHours ? '' : 'off')) +
      group('What I know when I reply',
        row('What you’re working on', 'Your current app and today so far, so “any update?” gets a real answer.', sw('waWorkContext', s.waWorkContext)) +
        row('Past days', 'How many day summaries I read before replying.', select('botMemoryDays', [[0, 'None'], [1, '1 day'], [2, '2 days'], [3, '3 days'], [5, '5 days'], [7, '7 days']], s.botMemoryDays, 'num')) +
        row('Tasks from chats', 'A clear ask, like “send the deck by Friday”, becomes a Google Task.', sw('waChatTasks', s.waChatTasks))) +
      group('Personality & people',
        row('How I sound', 'The voice and rules I reply with.', link('Edit personality…', 'editPersonality')) +
        row('Trusted contacts', 'People I can say more to.', link('Edit list…', 'editTrusted')) +
        row('Never reply to', 'People I always leave to you.', link('Edit list…', 'editNeverReply'))) +
      group('Connection',
        row('WhatsApp window', 'The browser window I reply through.', link('Open', 'openWhatsApp')) +
        row(connected ? 'Disconnect' : 'Connect', connected ? 'Signs this ' + mac('Mac', 'PC') + ' out of WhatsApp.' : 'Scan a QR code with your phone.', link(connected ? 'Disconnect…' : 'Connect…', 'whatsappConnection')));
  },

  connections: function (s) {
    var st = s.status;
    function conn(name, help, on, act) { return row(name, help, chip(on) + btn(on ? 'Manage' : 'Connect', act)); }
    return '<div data-in><h1 class="display">Connections</h1><p class="lead">The accounts I work with. Nothing is sent or added without your OK.</p></div>' +
      group('Accounts',
        conn('Google account', 'Calendar heads-ups, meeting tasks to Google Tasks, Gmail from the chat.', st.google, 'connectGoogle') +
        conn('Slack', 'The day’s messages go into your day summary.', st.slack, 'connectSlack') +
        conn(mac('Apple Reminders', 'Google Tasks reminders'), mac('New reminders bubble up when you open your Mac.', 'New Google Tasks bubble up on your PC.'), st.reminders, 'connectReminders') +
        conn('Team dashboard', 'Send your day and your meeting minutes to your team.', st.dashboard, 'connectDashboard') +
        conn('Forklyft ERP', 'What I read there helps me know your work.', st.erp, 'connectERP')) +
      group('WhatsApp', row('WhatsApp', 'Replies, call links and tasks from chats.', chip(st.whatsapp) + go('Settings', 'whatsapp')));
  },

  advanced: function (s) {
    return '<div data-in><h1 class="display">Advanced</h1><p class="lead">Folders, files and the things to share when something breaks.</p></div>' +
      group('Where I look',
        row('Projects folder', 'I scan it for git repos to see what you worked on.', '<code class="path">' + esc(s.projectsRoot) + '</code>' + btn('Choose…', 'chooseProjects'))) +
      group('Behind the scenes',
        row('Settings file', 'Everything here, as plain JSON.', link('Open settings.json', 'editSettings')) +
        row('AI usage log', 'One line per AI run, with its cost.', link('Open folder', 'openUsage')) +
        row('Logs', 'Copy them to share when something breaks.', link('Copy logs', 'copyLogs')) +
        row('Updates', 'Pull the latest Nikxel and rebuild.', link('Check for updates…', 'checkUpdates')) +
        row('Setup wizard', 'Go through setup again.', link('Open', 'setupWizard')) +
        row('Show me around', 'Arrows at the avatar, the ' + mac('menu bar icon', 'tray icon') + ' and this window again.', link('Show me around again', 'replayTour'))) +
      group('Nikxel', row('Quit Nikxel', 'Stops recording, replies and reminders until you open it again.', btn('Quit', 'quit')));
  }
};

// --- first-run tour -------------------------------------------------------------------
var TOUR = [
  ['[data-section="home"]', 'Home', 'Today at a glance: what’s coming up, what’s still open, and the recording timer.'],
  ['[data-section="library"]', 'Library', 'Every meeting’s notes, your days and weeks. Open one and it opens here in a tab.'],
  ['[data-section="chat"]', 'Chat', 'Ask me about your meetings, mail and work: “what did I promise Ali?”'],
  ['[data-section="tasks"]', 'Tasks', 'Everything people agreed to do in your meetings. Tick them off here.'],
  ['[data-section="automations"]', 'Automations', 'Tell me what to do after every meeting or each morning, and I’ll do it.'],
  ['.rec', 'Record', 'Start or stop recording a meeting. You can also double-click me on your screen.'],
  ['[data-section="you"]', 'Settings', 'Your name, how I look, WhatsApp, Google, and everything else I do.']
];
var tourAt = -1, tourEls = null;
function startTour() {
  if (tourAt >= 0) return;
  tourEls = { block: document.createElement('div'), hole: document.createElement('div'), tip: document.createElement('div') };
  tourEls.block.className = 'tour-block'; tourEls.hole.className = 'tour-hole'; tourEls.tip.className = 'tour-tip';
  tourEls.tip.setAttribute('role', 'dialog');
  document.body.append(tourEls.block, tourEls.hole, tourEls.tip);
  tourAt = 0; showTourStep();
}
function showTourStep() {
  var step = TOUR[tourAt], el = document.querySelector(step[0]);
  if (!el) { tourAt++; return tourAt < TOUR.length ? showTourStep() : endTour(); }
  var r = el.getBoundingClientRect(), pad = 6;
  Object.assign(tourEls.hole.style, { left: r.left - pad + 'px', top: r.top - pad + 'px', width: r.width + pad * 2 + 'px', height: r.height + pad * 2 + 'px' });
  var last = tourAt === TOUR.length - 1;
  // A pen-stroke arrow from the note back to what it's about.
  tourEls.tip.innerHTML = '<svg class="tour-arrow" viewBox="0 0 58 44" fill="none" aria-hidden="true"><g stroke="currentColor" stroke-width="3.4" stroke-linecap="round" stroke-linejoin="round">' +
    '<path d="M56 30 C 44 40, 26 38, 14 26 S 6 14, 4 12"/><path class="head" d="M3 24 L 3 11 L 16 10"/></g></svg>' +
    '<b>' + step[1] + '</b><p>' + step[2] + '</p><div class="row2"><span class="count">' + (tourAt + 1) + ' of ' + TOUR.length + '</span>' +
    (last ? '' : '<button type="button" class="link" data-tour="end">Skip</button>') +
    '<button type="button" class="btn primary" data-tour="next" style="padding:8px 14px">' + (last ? 'Got it' : 'Next') + '</button></div>';
  var top = Math.max(12, Math.min(innerHeight - tourEls.tip.offsetHeight - 12, r.top + r.height / 2 - 34));
  tourEls.tip.style.left = r.right + 66 + 'px';
  tourEls.tip.style.top = top + 'px';
  tourEls.tip.style.setProperty('--ay', Math.max(14, r.top + r.height / 2 - top - 8) + 'px');
  tourEls.tip.querySelector('[data-tour="next"]').focus();
}
function endTour() {
  if (!tourEls) return;
  tourEls.block.remove(); tourEls.hole.remove(); tourEls.tip.remove();
  tourEls = null; tourAt = -1;
  post({ type: 'tourDone' });
}

// --- library and reader ------------------------------------------------------------
var EXT = { pdf: 'PDF', md: 'Markdown', docx: 'Word' };
function item(e) {
  return '<button type="button" class="item" data-open="' + esc(e.id) + '"><div><b>' + esc(e.title) + '</b>' + (e.snippet ? '<small>' + esc(e.snippet) + '</small>' : '') + '</div>' +
    '<time>' + (EXT[e.ext] ? '<span class="chip">' + EXT[e.ext] + '</span>' : '') + esc(when(e)) + '</time></button>';
}
function libraryList(s) {
  var q = libQuery.trim().toLowerCase();
  var hits = {};
  if (q && found.q.trim().toLowerCase() === q) found.list.forEach(function (f) { hits[f.id] = f.match; });
  var list = s.library.filter(function (e) { return e.kind === libKind && (!q || hits[e.id] != null || (e.title + ' ' + e.snippet).toLowerCase().indexOf(q) >= 0); });
  if (list.length) return list.map(function (e) { return hits[e.id] ? item({ id: e.id, title: e.title, date: e.date, kind: e.kind, ext: e.ext, snippet: hits[e.id] }) : item(e); }).join('');
  return '<p class="empty">' + (q ? 'Nothing here matches “' + esc(libQuery.trim()) + '”.' : 'Nothing here yet.') + '</p>';
}
var searchTimer = 0;
function searchSoon() {
  clearTimeout(searchTimer);
  if (libQuery.trim().length < 3) return;
  searchTimer = setTimeout(function () { post({ type: 'search', q: libQuery.trim() }); }, 300);
}
// The tab bar: the section you came from, then every open summary.
function drawTabs(s) {
  var bar = document.getElementById('tabbar');
  if (!s.tabs.length) { bar.hidden = true; bar.innerHTML = ''; bar._h = ''; return; }
  var name = (SECTIONS.filter(function (x) { return x && x[0] === current; })[0] || ['', 'Home'])[1];
  var h = '<div class="tabs-row"><button type="button" class="tab home" role="tab" aria-selected="' + !s.active + '" data-sectiontab>' + icon(current) + '<span class="tt">' + esc(name) + '</span></button>' +
    s.tabs.map(function (t) {
      return '<button type="button" class="tab" role="tab" aria-selected="' + (t.id === s.active) + '" data-tab="' + esc(t.id) + '" title="' + esc(t.title + (t.date ? ' · ' + when(t) : '')) + '">' + icon('doc') +
        '<span class="tt">' + esc(t.title) + '</span><span class="x" role="button" aria-label="Close tab" data-closetab="' + esc(t.id) + '">' + icon('x') + '</span></button>';
    }).join('') + '</div>' +
    (s.active ? '<div class="acts">' + link('Open in browser', 'openInBrowser') + link(mac('Show in Finder', 'Show in Explorer'), 'revealSummary') + '</div>' : '');
  if (bar._h === h) return;
  bar.innerHTML = h; bar._h = h; bar.hidden = false;
  var on = bar.querySelector('.tab[aria-selected="true"]');
  if (on && on.scrollIntoView) on.scrollIntoView({ block: 'nearest', inline: 'nearest' });
}
function drawFoot(s) {
  var h = '<button type="button" class="rec' + (s.recording ? ' on' : '') + '" data-act="toggleRecording"><span class="dot"></span><span class="lbl">' + (s.recording ? 'Stop recording <span class="clock" data-since="' + s.recordingSince + '" style="margin-left:auto;font:500 13px var(--font-code)">' + clock(s.recordingSince) + '</span>' : 'Start recording') + '</span></button>' +
    '<button type="button" class="link" data-act="toggleMicMute" title="' + (s.micMuted ? 'Unmute mic' : 'Mute mic') + '">' + icon('mic') + '<span class="lbl">' + (s.micMuted ? 'Unmute mic' : 'Mute mic') + '</span></button>';
  if (foot._h !== h) { foot.innerHTML = h; foot._h = h; }
}

// --- chat ------------------------------------------------------------------------
var chatLog = [], chatDraft = '', chatBusy = false, chatListening = false, chatSources = null, chatSeq = 0, chatPending = {};
var SUGGEST = ['What did I agree to in today’s meetings?', 'Who’s waiting on me on WhatsApp?', 'What did I work on this week?', 'Anything urgent in my inbox?'];
function chatAsk(type, text) {
  return new Promise(function (r) { var id = ++chatSeq; chatPending[id] = r; post({ type: type, id: id, text: text || '' }); });
}
function logHTML() {
  if (!chatLog.length) return '<div class="hello"><div class="sp">' + sprite(0) + '</div><p>Ask me about the last two weeks: meetings, days, notes, projects, WhatsApp and Gmail. I can draft emails and make ERP tasks too.</p>' +
    '<div class="suggest">' + SUGGEST.map(function (q) { return '<button type="button" data-chat="suggest">' + esc(q) + '</button>'; }).join('') + '</div></div>';
  return chatLog.map(function (m) {
    if (m.pending) return '<div class="msg bot"><span class="dots"><i></i><i></i><i></i></span><span class="hint">' + esc(m.pending) + '</span></div>';
    return '<div class="msg ' + m.who + '">' + (m.who === 'bot' ? md(m.text) : esc(m.text)) + '</div>';
  }).join('');
}
function sourcesHTML() {
  if (!chatSources) return '<p class="src"><i></i><small>Reading WhatsApp, your inbox and the team dashboard…</small></p>';
  return chatSources.map(function (x) {
    return '<div class="src ' + (x.on ? 'on' : 'off') + '"><i></i><div><b>' + esc(x.name) + '</b><small>' + esc(x.detail) + '</small></div></div>';
  }).join('');
}
function drawLog() {
  var log = document.getElementById('log');
  if (!log) return;
  log.innerHTML = logHTML(); log.scrollTop = log.scrollHeight;
  paintSprites(); syncChat();
}
function syncChat() {
  var ci = document.getElementById('ci'), mic = document.querySelector('[data-chat="mic"]'), go = document.querySelector('[data-chat="send"]');
  if (!ci) return;
  var meeting = !!(S && S.recording);
  ci.disabled = chatBusy || chatListening;
  ci.placeholder = chatListening ? 'Listening… tap the mic to send' : 'Ask anything…';
  mic.disabled = chatBusy || (meeting && !chatListening);
  mic.title = meeting ? 'Recording a meeting: type instead' : 'Tap, speak, tap again to send';
  mic.classList.toggle('rec', chatListening);
  go.disabled = chatBusy || chatListening || !ci.value.trim();
}
function chatRun(text) {
  chatLog.push({ who: 'me', text: text });
  var wait = { pending: 'thinking…' };
  chatLog.push(wait); chatBusy = true; drawLog();
  chatAsk('chat', text).then(function (r) {
    chatLog[chatLog.indexOf(wait)] = { who: 'bot', text: r.text };
    chatBusy = false;
    var ci = document.getElementById('ci');
    if (r.error && ci && !ci.value) { ci.value = chatDraft = text; }   // keep the question to try again
    drawLog();
    if (ci) ci.focus();
  });
}
function chatMic() {
  if (!chatListening) {
    chatAsk('chatMic').then(function (r) {
      if (r === 'recording') chatListening = true;
      else chatLog.push({ who: 'bot', text: r === 'busy' ? 'I’m recording a meeting, so the mic is taken. Type instead.' : 'Couldn’t use the microphone.' });
      drawLog();
    });
    return;
  }
  chatListening = false;
  var wait = { pending: 'Listening back…' };
  chatLog.push(wait); chatBusy = true; drawLog();
  chatAsk('chatMic').then(function (text) {
    chatLog.splice(chatLog.indexOf(wait), 1);
    chatBusy = false;
    if (!text) { chatLog.push({ who: 'bot', text: 'Didn’t catch that.' }); drawLog(); return; }
    chatRun(text);
  });
}

// --- drawing ---------------------------------------------------------------------
nav.innerHTML = SECTIONS.map(function (x) {
  return x ? '<button type="button" data-section="' + x[0] + '" title="' + x[1] + '">' + icon(x[0]) + '<span class="lbl">' + x[1] + '</span></button>' : '<div class="label">Settings</div>';
}).join('');
function markNav() {
  var at = S && S.active ? null : current;
  nav.querySelectorAll('button').forEach(function (b) {
    if (b.dataset.section === at) b.setAttribute('aria-current', 'page'); else b.removeAttribute('aria-current');
  });
}
function render() {
  main.classList.toggle('reading', !!S.active);
  main.classList.toggle('chatting', !S.active && !S.editor && current === 'chat');
  drawTabs(S);
  return S.active ? '' : S.editor ? editorView(S.editor) : VIEWS[current](S);
}
function stagger(page) {
  page.querySelectorAll('[data-in]').forEach(function (el, i) { el.style.setProperty('--i', i); });
}
// Switch what the main column shows. The new page goes in at once, fully
// there; its entrance is a CSS animation over content already in place. The
// old page fades out on top and is removed when that ends, or after a timer if
// it never runs (a hidden window doesn't run animations).
function show(section, animateIn) {
  current = section;
  markNav();
  var old = inner.firstElementChild;
  var page = document.createElement('div');
  page.className = animateIn && !reduce ? 'page' : '';
  page.innerHTML = render(); page._h = page.innerHTML;
  stagger(page);
  if (section === 'chat' && !chatSources) post({ type: 'chatStart' });
  if (old && animateIn && !reduce && !S.active) {
    old.classList.add('leaving');
    var gone = function () { if (old.parentNode) old.parentNode.removeChild(old); };
    old.addEventListener('animationend', gone);
    setTimeout(gone, 600);
  } else if (old) {
    old.remove();
  }
  inner.insertBefore(page, inner.firstChild);
  main.scrollTop = 0;
  paintSprites();
  syncChat();
  var log = document.getElementById('log'); if (log) log.scrollTop = log.scrollHeight;
  // A window that's hidden or covered doesn't advance animations; if this
  // entrance hasn't played out by now, end it so nothing waits on it.
  setTimeout(function () {
    if (page.getAnimations) page.getAnimations({ subtree: true }).forEach(function (a) { try { a.finish(); } catch (e) {} });
  }, 2000);
}
// New facts on the same section: redraw in place, unless the user is typing in it.
function patch() {
  markNav();
  if (S.editor) return;   // never put the file back over what's being written
  if (current === 'chat' && !S.active) { drawTabs(S); return syncChat(); }
  if (current === 'automations' && draft && !S.active) { drawTabs(S); return; }   // keep what's being written   // the conversation draws itself
  var a = document.activeElement;
  if (a && inner.contains(a) && (a.tagName === 'INPUT' || a.tagName === 'TEXTAREA')) return;
  var page = inner.querySelector(':scope > div:not(.leaving)');
  if (!page) return show(current, false);
  var h = render(), probe = document.createElement('div');
  probe.innerHTML = h;
  if (probe.innerHTML === page._h) return;
  var top = main.scrollTop;
  page.innerHTML = h; page._h = page.innerHTML;
  page.className = '';
  main.scrollTop = top;
  paintSprites();
}

window.nx = {
  state: function (s) {
    var was = S;
    S = s;
    drawFoot(s);
    if (!was) {
      document.body.classList.toggle('folded', !!s.sideCollapsed);
      if (s.tour) setTimeout(function () { if (!S.active && !S.editor) startTour(); }, reduce ? 200 : 1400);
      return show(s.section || 'home', !reduce);
    }
    if (s.tour && !was.tour) startTour();   // replayed from Advanced
    document.body.classList.toggle('folded', !!s.sideCollapsed);
    if (was.active !== s.active || !!was.editor !== !!s.editor) return show(current, !s.active);
    patch();
  },
  frames: function (r) { rows = r || []; paintSprites(); },
  go: function (section) { if (S) goTo(section); },
  found: function (q, list) {
    found = { q: q, list: list };
    var el = document.getElementById('list');
    if (el && current === 'library' && !S.active) el.innerHTML = libraryList(S);
  },
  reply: function (id, v) { var f = chatPending[id]; delete chatPending[id]; if (f) f(v); },
  sources: function (list) { chatSources = list; var el = document.getElementById('srcs'); if (el) el.innerHTML = sourcesHTML(); }
};

// --- input ------------------------------------------------------------------------
function flash(key) {
  var el = document.querySelector('[data-saved="' + key + '"]');
  if (!el) return;
  el.classList.add('on');
  setTimeout(function () { el.classList.remove('on'); }, 1800);
}
function goTo(section) {
  if (section === 'people' && person != null && !(S && (S.active || S.editor))) { person = null; show('people', true); return; }
  if (section === current && !(S && S.active)) return;
  post({ type: 'section', id: section });
  if (S && S.active) { current = section; post({ type: 'action', name: 'closeSummary' }); return; }   // the state push redraws
  if (S && S.editor) { current = section; post({ type: 'closeFile' }); return; }
  show(section, true);
}
document.addEventListener('click', function (e) {
  var tb = e.target.closest('[data-tour]');
  if (tb) {
    if (tb.dataset.tour === 'next' && tourAt < TOUR.length - 1) { tourAt++; showTourStep(); } else endTour();
    return;
  }
  var x = e.target.closest('[data-closetab]');
  if (x) { e.stopPropagation(); post({ type: 'closeTab', id: x.dataset.closetab }); return; }
  var t = e.target.closest('button');
  if (!t || t.disabled) return;
  if (t.id === 'fold') {
    var folded = !document.body.classList.contains('folded');
    document.body.classList.toggle('folded', folded);
    t.setAttribute('aria-label', folded ? 'Expand sidebar' : 'Collapse sidebar'); t.title = t.getAttribute('aria-label');
    post({ type: 'side', collapsed: folded });
    return;
  }
  if (t.dataset.tab) { if (t.dataset.tab !== S.active) post({ type: 'tab', id: t.dataset.tab }); return; }
  if (t.hasAttribute('data-sectiontab')) { if (S.active) post({ type: 'action', name: 'closeSummary' }); return; }
  if (t.dataset.chat === 'suggest') { if (!chatBusy && !chatListening) chatRun(t.textContent); return; }
  if (t.dataset.chat === 'mic') { chatMic(); return; }
  if (t.dataset.chat === 'send') return;   // the form's submit sends
  if (t.dataset.act === 'chatNew') {
    chatLog = []; chatDraft = ''; chatSources = null; chatBusy = chatListening = false; chatPending = {};
    post({ type: 'chatNew' });
    drawLog(); document.getElementById('srcs').innerHTML = sourcesHTML();
    return;
  }
  if (t.dataset.section) return goTo(t.dataset.section);
  if (t.dataset.go) return goTo(t.dataset.go);
  if (t.dataset.open) { post({ type: 'open', id: t.dataset.open }); return; }
  if (t.dataset.taskview) { taskView = t.dataset.taskview; show('tasks', false); return; }
  if (t.hasAttribute('data-person')) { person = t.dataset.person === '' ? null : +t.dataset.person; show('people', true); return; }
  if (t.dataset.autotoggle) { var on2 = t.getAttribute('aria-checked') !== 'true'; t.setAttribute('aria-checked', String(on2)); post({ type: 'autoToggle', id: t.dataset.autotoggle, on: on2 }); return; }
  if (t.dataset.autorun) { post({ type: 'autoRun', id: t.dataset.autorun }); return; }
  if (t.dataset.learnyes || t.dataset.learnno) { post({ type: 'learnDecide', key: t.dataset.learnyes || t.dataset.learnno, yes: !!t.dataset.learnyes }); return; }
  if (t.dataset.autodel) { if (confirm('Delete this automation?')) post({ type: 'autoDelete', id: t.dataset.autodel }); return; }
  if (t.dataset.autoedit) { openDraft(S.automations.filter(function (a) { return a.id === t.dataset.autoedit; })[0]); return; }
  if (t.hasAttribute('data-idea')) { var idea = S.ideas[+t.dataset.idea]; openDraft({ name: idea.name, trigger: idea.trigger, time: idea.time, days: idea.days, instruction: idea.instruction }); return; }
  if (t.hasAttribute('data-sugg')) { var sg = suggestions[+t.dataset.sugg]; openDraft({ name: sg.name, trigger: sg.trigger, time: sg.time, days: sg.days, instruction: sg.instruction }); return; }
  if (t.hasAttribute('data-autocancel')) { draft = null; redrawAutomations(); return; }
  if (t.hasAttribute('data-autosave')) {
    if (!draft.instruction.trim()) { var ta = document.querySelector('[data-draft="instruction"]'); if (ta) ta.focus(); return; }
    post({ type: 'autoSave', a: draft }); draft = null; redrawAutomations(); return;
  }
  if (t.hasAttribute('data-autosuggest')) {
    suggesting = true; redrawAutomations();
    chatAsk('autoSuggest').then(function (list) { suggesting = false; suggestions = list || []; redrawAutomations(); });
    return;
  }
  if (t.dataset.url) { post({ type: 'openURL', url: t.dataset.url }); return; }
  if (t.dataset.chatwith) { post({ type: 'openChat', name: t.dataset.chatwith }); return; }
  if (t.dataset.never) { post({ type: 'neverReply', name: t.dataset.never }); t.outerHTML = '<span class="chip">Never replying</span>'; return; }
  if (t.dataset.md) {
    var done = t.getAttribute('aria-checked') !== 'true';
    t.setAttribute('aria-checked', String(done)); t.closest('.tk').classList.toggle('done', done);
    post({ type: 'task', md: t.dataset.md, n: +t.dataset.n, done: done });
    return;
  }
  if (t.dataset.day) {
    t.setAttribute('aria-checked', 'true'); t.closest('.tk').classList.add('done');
    post({ type: 'dayTask', id: t.dataset.day, i: +t.dataset.i });
    return;
  }
  if (t.dataset.kindtab) {
    libKind = t.dataset.kindtab;
    t.parentNode.querySelectorAll('button').forEach(function (b) { b.setAttribute('aria-checked', String(b === t)); });
    document.getElementById('list').innerHTML = libraryList(S);
    return;
  }
  if (t.hasAttribute('data-savefile')) { post({ type: 'saveFile', text: document.getElementById('filetext').value }); return; }
  if (t.dataset.act === 'closeFile') { post({ type: 'closeFile' }); return; }
  if (t.dataset.act) { post({ type: 'action', name: t.dataset.act }); return; }
  if (t.dataset.save === 'userContext') {
    post({ type: 'set', key: 'userContext', value: document.getElementById('ctx').value });
    flash('userContext');
    return;
  }
  if (t.classList.contains('switch')) {
    var on = t.getAttribute('aria-checked') !== 'true';
    t.setAttribute('aria-checked', String(on));   // answer the click at once; the state push confirms
    post({ type: 'set', key: t.dataset.key, value: on });
    return;
  }
  if (t.dataset.key && t.hasAttribute('data-value')) {
    var kind = (t.closest('[data-kind]') || {}).dataset ? t.closest('[data-kind]').dataset.kind : 'str';
    post({ type: 'set', key: t.dataset.key, value: kind === 'num' ? parseFloat(t.dataset.value) : t.dataset.value });
  }
});
document.addEventListener('submit', function (e) {
  if (e.target.id === 'makef') {
    e.preventDefault();
    var text = document.getElementById('mk').value.trim();
    if (!text || making) return;
    making = true; makeText = text; makeError = ''; redrawAutomations();
    chatAsk('autoMake', text).then(function (r) {
      making = false;
      if (r && r.error) { makeError = r.error; redrawAutomations(); return; }
      makeText = ''; openDraft(r);
    });
    return;
  }
  if (e.target.id !== 'chatf') return;
  e.preventDefault();
  var ci = document.getElementById('ci'), text = ci.value.trim();
  if (!text || chatBusy || chatListening) return;
  ci.value = chatDraft = '';
  chatRun(text);
});
document.addEventListener('input', function (e) {
  if (e.target.dataset && e.target.dataset.draft && draft) { draft[e.target.dataset.draft] = e.target.value; return; }
  if (e.target.id === 'mk') { makeText = e.target.value; return; }
  if (e.target.id === 'ci') { chatDraft = e.target.value; syncChat(); return; }
  if (e.target.id !== 'q') return;
  libQuery = e.target.value;
  document.getElementById('list').innerHTML = libraryList(S);
  searchSoon();
});
document.addEventListener('change', function (e) {
  var t = e.target;
  if (t.dataset && t.dataset.draft && draft) { draft[t.dataset.draft] = t.value; if (t.dataset.draft === 'trigger') redrawAutomations(); return; }
  if (!t.dataset || !t.dataset.key) return;
  var v = t.dataset.kind === 'num' ? Number(t.value) : t.value;
  post({ type: 'set', key: t.dataset.key, value: v });
  flash(t.dataset.key);
});
document.addEventListener('auxclick', function (e) {
  var t = e.target.closest('[data-tab]');
  if (t && e.button === 1) post({ type: 'closeTab', id: t.dataset.tab });
});
document.addEventListener('keydown', function (e) {
  if (tourEls && e.key === 'Escape') { endTour(); return; }
  if (e.metaKey && e.key === 'w' && S && S.active) { e.preventDefault(); post({ type: 'closeTab', id: S.active }); return; }
  if (e.key === 's' && e.metaKey && S && S.editor) { e.preventDefault(); post({ type: 'saveFile', text: document.getElementById('filetext').value }); return; }
  if (e.key === 'Enter' && e.target.classList && e.target.classList.contains('text')) e.target.blur();
});
})();
</script>
</body></html>
"""#
}
