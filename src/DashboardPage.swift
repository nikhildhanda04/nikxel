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
/* Any page on its way out, whether or not it came in animated (a redrawn page loses .page). */
.inner > .leaving{position:absolute;pointer-events:none;animation:leave .45s cubic-bezier(.4,0,.2,1) forwards}
input,textarea,code{-webkit-user-select:text;user-select:text}
button,input,select,textarea{font:inherit;color:inherit}
:focus-visible{outline:2px solid var(--color-focus);outline-offset:2px}
::selection{background:var(--color-select);color:var(--color-ink)}
html{caret-color:var(--color-accent);scrollbar-color:var(--color-line-2) transparent}

/* sidebar */
.side{position:relative;z-index:2;display:flex;flex-direction:column;gap:24px;min-height:0;overflow:hidden;padding:56px 16px 20px;background:var(--color-side);border-right:1px solid var(--color-line);-webkit-backdrop-filter:blur(12px);backdrop-filter:blur(12px)}
.brand{display:flex;align-items:center;gap:8px;padding:0 8px}
.brand .sp{width:40px;height:40px}.brand .sp img{width:40px;height:40px;border-radius:10px;display:block}
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
.wnb p{margin:4px 0 0;color:var(--color-ink-2);font-size:14.5px;line-height:1.5;max-width:64ch}
.nav button.new::after{content:'';flex:none;width:8px;height:8px;margin-left:auto;border-radius:50%;background:var(--color-accent)}
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
.field{flex:none;display:flex;align-items:center;gap:8px;margin:0 16px 16px;padding:6px 6px 6px 6px;border:1px solid var(--color-line-2);border-radius:999px;background:var(--color-paper);transition:border-color .4s var(--ease)}
.field:focus-within{border-color:var(--color-accent)}
/* Files for Nikxel to read: chips above the chat box (and on an automation); the chat lights up when one's dragged over. */
.atts{display:flex;flex-wrap:wrap;gap:6px;margin:0 16px 8px}.atts:empty{display:none}
.att{display:inline-flex;align-items:center;gap:6px;max-width:260px;padding:5px 6px 5px 10px;border-radius:999px;background:var(--color-paper-2);font:500 12.5px/1.2 var(--font-body);color:var(--color-ink-2)}
.att span{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.att button{border:0;background:transparent;color:var(--color-muted);cursor:pointer;padding:0 4px;font:inherit}
.att.reading{opacity:.6}.draft .label-like{font-weight:600;font-size:14px}.msg .files{display:block;margin-top:6px;font-size:12.5px;opacity:.75}
body.dropping .convo,body.dropping #draft .card{outline:2px dashed var(--color-accent);outline-offset:-6px}
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
/* dialogs: the template editor, and plain text files (a contact list, how I sound) */
.dlg-scrim{position:fixed;inset:0;z-index:40;background:oklch(15% 0.01 80 / .4);animation:fade .35s var(--ease) backwards}
.dlg-wrap{position:fixed;inset:0;z-index:41;display:grid;place-items:center;padding:24px;pointer-events:none}
.dlg{pointer-events:auto;width:min(920px,100%);height:min(720px,100%);display:flex;flex-direction:column;min-height:0;background:var(--color-card);border:1px solid var(--color-line);border-radius:20px;
  box-shadow:0 2px 6px var(--color-shade-1),0 32px 70px -24px var(--color-shade-2);overflow:hidden;animation:rise .55s var(--ease) backwards;-webkit-user-select:text;user-select:text}
.dlg.small{width:min(680px,100%)}
.dlg-head{display:flex;align-items:center;justify-content:space-between;gap:16px;padding:18px 20px 16px 24px;border-bottom:1px solid var(--color-line)}
.dlg-head h2{margin:0;font:600 20px/1.2 var(--font-display);letter-spacing:-.01em}
.dlg-head p{margin:2px 0 0;font-size:13.5px;color:var(--color-muted)}
.dlg-x{flex:none;width:32px;height:32px;border:0;border-radius:50%;background:transparent;color:var(--color-muted);cursor:pointer;display:grid;place-items:center;transition:background-color .4s var(--ease),color .4s var(--ease)}
.dlg-x:hover{background:var(--color-paper-2);color:var(--color-ink)}
.dlg-x svg{width:16px;height:16px}
.dlg-body{flex:1;min-height:0;display:flex;flex-direction:column;padding:20px 24px;overflow-y:auto}
.dlg-body textarea.file{flex:1;min-height:240px;margin-top:0;resize:none}
.dlg-foot{display:flex;align-items:center;gap:8px;padding:14px 20px 14px 24px;border-top:1px solid var(--color-line);background:var(--color-paper)}
.dlg-foot .grow{margin-right:auto;font-size:13.5px;color:var(--color-ink-2);min-width:0}
.dlg-foot .grow.warn{color:var(--color-rec);font-weight:600}
.tpl{flex:1;min-height:0;display:grid;grid-template-columns:220px minmax(0,1fr)}
.tpl-list{display:flex;flex-direction:column;gap:2px;padding:16px 12px;border-right:1px solid var(--color-line);background:var(--color-paper);overflow-y:auto}
.tpl-list button{display:flex;flex-direction:column;align-items:flex-start;gap:2px;width:100%;text-align:left;border:0;border-radius:10px;background:transparent;padding:10px 12px;cursor:pointer;font:500 14px/1.3 var(--font-body);color:var(--color-ink-2);
  transition:background-color .4s var(--ease),color .4s var(--ease)}
.tpl-list button:hover{background:var(--color-paper-2);color:var(--color-ink)}
.tpl-list button[aria-current]{background:var(--color-card);color:var(--color-ink);font-weight:600;box-shadow:0 1px 3px var(--color-shade-3)}
.tpl-list button small{font:500 12px/1.2 var(--font-body);color:var(--color-ok)}
.tpl-list .tpl-add{margin-top:8px;color:var(--color-accent-text);font-weight:600}
.tpl-main{min-height:0;overflow-y:auto;padding:20px 24px 24px;display:flex;flex-direction:column}
.tpl-top{display:flex;align-items:flex-start;justify-content:space-between;gap:16px;flex-wrap:wrap}
.tpl-top h3{margin:0;font:600 22px/1.2 var(--font-display);letter-spacing:-.015em;overflow-wrap:break-word;min-width:0}
.tpl-top p{margin:4px 0 0;font-size:13.5px;color:var(--color-muted)}
.tpl-block{margin-top:22px}
.tpl-block>b{display:block;font-weight:600;font-size:15px}
.tpl-block>small{display:block;color:var(--color-muted);font-size:13.5px;line-height:1.45;margin-top:2px}
.togs{display:flex;flex-wrap:wrap;gap:8px;margin-top:10px}
.tog{position:relative;display:inline-flex;align-items:center;gap:8px;border:1px solid var(--color-line);border-radius:999px;background:var(--color-paper);padding:7px 12px 7px 8px;cursor:pointer;font:500 13.5px/1 var(--font-body);color:var(--color-muted);
  transition:border-color .4s var(--ease),background-color .4s var(--ease),color .4s var(--ease)}
.tog:hover{border-color:var(--color-line-2)}
.tog::before{content:'';width:16px;height:16px;border-radius:50%;border:1.5px solid var(--color-line-2);box-sizing:border-box;transition:background-color .4s var(--ease),border-color .4s var(--ease)}
.tog[aria-pressed="true"]{color:var(--color-ink);background:var(--color-card);border-color:var(--color-line-2)}
.tog[aria-pressed="true"]::before{border:0;background:var(--color-ink)}
.tog[aria-pressed="true"]::after{content:'';position:absolute;left:16px;top:50%;width:4px;height:8px;border:solid var(--color-on-ink);border-width:0 1.8px 1.8px 0;transform:translate(-50%,-62%) rotate(45deg)}
.tog.fixed{cursor:default;opacity:.7}
.tpl-block .seg{margin-top:10px}
.adds{margin-top:10px;display:flex;flex-direction:column;gap:6px}
.add{display:grid;grid-template-columns:minmax(0,1fr) auto;gap:12px;align-items:center;padding:10px 6px 10px 14px;border:1px solid var(--color-line);border-radius:12px;background:var(--color-paper)}
.add b{font-weight:600;font-size:14px}
.add span{display:block;font-size:13.5px;color:var(--color-muted);overflow-wrap:break-word}
.addform{display:grid;grid-template-columns:180px minmax(0,1fr) auto;gap:8px;margin-top:10px}
.addform .text{width:100%}
.tpl-main textarea{min-height:110px;margin-top:10px;font-size:14.5px}
.tpl-main textarea.file{flex:1;min-height:320px;resize:none}
.ideas-row{display:flex;flex-wrap:wrap;gap:6px;margin-top:10px}
.idea{border:1px dashed var(--color-line-2);border-radius:999px;background:transparent;padding:6px 11px;cursor:pointer;font:500 13px/1.2 var(--font-body);color:var(--color-ink-2);text-align:left;
  transition:border-color .4s var(--ease),color .4s var(--ease),background-color .4s var(--ease)}
.idea:hover{border-color:var(--color-accent);color:var(--color-accent-text);background:var(--color-paper)}
.tpl-new .text{width:100%;max-width:380px;height:40px;margin-top:12px;font-size:15px}
.tpl-new .choices{max-width:380px}
.row.erpform{display:block}
.erpform label{display:block;cursor:default}
.row .ctl .link+.link{margin-left:8px}
.erpform label b{display:block;font-weight:600;font-size:15px}
.erpform label small,.erpform>small{display:block;color:var(--color-muted);font-size:13.5px;line-height:1.45;margin-top:2px}
.erpform>small{margin-top:10px;max-width:60ch}
.erpline{display:flex;gap:8px;margin-top:10px;flex-wrap:wrap}
.erpline .text{flex:1;min-width:220px;width:auto;height:40px;font-size:15px}
.tpl-err{margin:10px 0 0;color:var(--color-rec);font-size:13.5px;font-weight:600}
@media (max-width:760px){.tpl{grid-template-columns:minmax(0,1fr)}.tpl-list{flex-direction:row;overflow-x:auto;border-right:0;border-bottom:1px solid var(--color-line)}.tpl-list button{width:auto;white-space:nowrap}.addform{grid-template-columns:minmax(0,1fr)}}
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

/* Organization: a different room on purpose. Cool slate paper and a band that
   never goes away, so it's always clear this side is shared with the team. */
body.org{--color-paper:#eef1f5;--color-paper-2:#e3e8ef;--color-card:#f9fafc;--color-cloud:#d3dbe6;--color-ink:#0c1118;--color-ink-2:#384252;
  --color-muted:#5f6b7c;--color-faint:#95a0b0;--color-line:#dbe1e9;--color-line-2:#c6cfdb;--color-on-ink:#f9fafc;--color-side:oklch(94% 0.012 250 / .8);
  --color-accent:oklch(50% 0.12 230);--color-accent-text:oklch(44% 0.12 230);--color-focus:oklch(52% 0.12 230);--color-select:oklch(88% 0.05 230);--grain:.04}
@media (prefers-color-scheme:dark){body.org{--color-paper:#0f1318;--color-paper-2:#161c24;--color-card:#19212b;--color-cloud:#1d2631;--color-ink:#e9eef5;--color-ink-2:#c1cad6;
  --color-muted:#8c97a6;--color-faint:#5d6878;--color-line:#25303c;--color-line-2:#33404e;--color-on-ink:#0f1318;--color-side:oklch(18% 0.015 250 / .82);
  --color-accent:oklch(72% 0.11 230);--color-accent-text:oklch(78% 0.1 230);--color-focus:oklch(72% 0.11 230);--color-select:oklch(38% 0.07 230)}}
.orgband{display:none}
body.org .orgband{display:flex;position:sticky;top:0;z-index:4;align-items:center;gap:10px;padding:9px 24px;background:var(--color-ink);color:var(--color-on-ink);font:500 13px/1.35 var(--font-body)}
.orgband svg{width:16px;height:16px;flex:none}
.orgband b{font-weight:600}
body.org .tabbar{display:none}
main.orgwide .inner{max-width:1120px}
.nav .back{color:var(--color-muted)}
.nav .org-entry{margin-top:6px;border:1px dashed var(--color-line-2)}
/* Organizations, Slack-style: a square initial per org, a dropdown of them, and + to add one. */
.nav .av{flex:none;width:24px;height:24px;border-radius:7px;display:grid;place-items:center;background:var(--color-ink-2);color:var(--color-paper);font:700 12px/1 var(--font-body)}
.nav .chev{margin-left:auto;display:flex;transition:transform .3s var(--ease)}.nav [aria-expanded="true"] .chev{transform:rotate(180deg)}
.nav .orgpick{padding:8px 12px 8px 18px}.nav .orgpick .lbl{min-width:0}.nav .orgpick small{display:block;margin-top:2px;color:var(--color-faint);font-size:12px;font-weight:500}
.nav .orgpick .on{margin-left:auto;flex:none;width:8px;height:8px;border-radius:50%;background:var(--color-accent)}
.nav .ws{display:flex;gap:6px;align-items:center}.nav .ws .ws-cur{flex:1;min-width:0;font-weight:600;color:var(--color-ink)}
.nav .ws .ws-cur{gap:10px;padding-right:8px}.nav .ws .ws-cur .lbl{flex:1 1 auto;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.nav .ws .ws-add{flex:none;width:40px;justify-content:center;padding:10px 0;border:1px solid var(--color-line-2)}
.nav .orgmenu{margin:2px 0 6px;padding:4px;border-radius:14px;background:var(--color-card);box-shadow:inset 0 0 0 1px var(--color-line)}
body.folded .nav .ws{flex-direction:column}body.folded .nav .chev,body.folded .nav .orgpick .on{display:none}body.folded .nav .orgpick{padding:8px 0}
.rolegrid{width:100%;border-collapse:collapse}.rolegrid th,.rolegrid td{padding:10px 12px;text-align:center;border-bottom:1px solid var(--color-line,rgba(0,0,0,.08))}.rolegrid th{font-size:12px;font-weight:600;line-height:1.3;color:var(--color-muted)}
.rolegrid td:first-child,.rolegrid th:first-child{text-align:left}.rolegrid input[type=text]{width:100%;min-width:120px}.rolegrid input[type=checkbox]{width:18px;height:18px;accent-color:currentColor}
.orgstats{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:12px;margin-top:28px}
.orgstats .card{padding:16px 18px}.orgstats b{display:block;font:500 30px/1.1 var(--font-display)}.orgstats small{color:var(--color-muted)}
.rules{margin:0;padding:6px 20px 14px 38px;color:var(--color-ink-2)}.rules li{margin:8px 0}
.orggrid{display:grid;grid-template-columns:minmax(0,1.5fr) minmax(260px,1fr);gap:32px;align-items:start;margin-top:28px}
@media (max-width:1000px){.orggrid{grid-template-columns:minmax(0,1fr)}}
.tiers{display:flex;flex-direction:column;gap:26px}
.tier{position:relative;border:1.5px dashed transparent;border-radius:20px;padding:14px 12px 18px;text-align:center;transition:border-color .2s,background-color .2s}
.tier+.tier::before{content:'';position:absolute;top:-27px;left:50%;width:1.5px;height:26px;background:var(--color-line-2)}
.tier h3{margin:0 0 12px;font:600 11.5px/1 var(--font-body);letter-spacing:.08em;text-transform:uppercase;color:var(--color-muted)}
.tier h3 span{color:var(--color-faint);margin-left:4px}
.tier .row{display:flex;flex-wrap:wrap;justify-content:center;gap:10px;padding:0;border:0}
.tier .hint{color:var(--color-faint);font-size:13px;padding:8px}
body.dragging .can-drop{border-color:var(--color-line-2)}
.over{border-color:var(--color-accent)!important;background:color-mix(in oklch,var(--color-accent) 9%,transparent)!important}
.pcard{display:inline-flex;align-items:center;gap:10px;padding:6px 14px 6px 6px;border-radius:999px;background:var(--color-card);border:1px solid var(--color-line);
  box-shadow:var(--shadow);cursor:pointer;font:500 14px/1.2 var(--font-body);color:var(--color-ink);transition:transform .2s var(--ease),border-color .2s}
.pcard:hover{transform:translateY(-1px);border-color:var(--color-line-2)}
.pcard[draggable=true]{cursor:grab}
.pcard.me{border-color:var(--color-accent)}
.pcard.sel{outline:2px solid var(--color-accent);outline-offset:2px}
.pcard small{color:var(--color-muted);font-weight:400}
.pcard span{white-space:nowrap}
.pcard.add{color:var(--color-accent-text);box-shadow:none;border-style:dashed;padding:9px 14px}
.av{width:30px;height:30px;flex:none;border-radius:50%;display:inline-grid;place-items:center;font:600 12px/1 var(--font-body);color:#fff;background:hsl(var(--h) 42% 46%)}
.teams h2{margin:0 0 12px}
.team{border:1.5px solid var(--color-line);background:var(--color-card);border-radius:16px;padding:12px 14px;margin-bottom:12px;transition:border-color .2s,background-color .2s}
.team header{display:flex;align-items:center;justify-content:space-between;gap:8px}
.team header .link{font-weight:600;color:var(--color-ink);padding:0}
.team header small,.visible{color:var(--color-muted);font-size:12.5px}
.avs{display:flex;flex-wrap:wrap;gap:6px;margin:10px 0 6px}
.chip-av{display:inline-flex;align-items:center;gap:6px;padding:3px 6px 3px 3px;border-radius:999px;background:var(--color-paper-2);font-size:13px}
.chip-av .av{width:22px;height:22px;font-size:10px}
.chip-av button{border:0;background:none;color:var(--color-muted);cursor:pointer;padding:0 3px;font-size:15px;line-height:1}
.chip-av button:hover{color:var(--color-rec)}
.newproj{display:flex;gap:8px;margin-top:4px}
.newproj input{flex:1;min-width:0;border:1px solid var(--color-line-2);border-radius:999px;padding:9px 14px;background:var(--color-card)}
.pdetail{margin-top:28px}
.pdetail .head{display:flex;align-items:center;gap:14px;padding:18px 20px;border-bottom:1px solid var(--color-line)}
.pdetail .head .av{width:44px;height:44px;font-size:16px}
.pdetail .head b{font-size:17px}
.roles{display:flex;flex-wrap:wrap;gap:6px}
.roles button[aria-pressed=true]{background:var(--color-ink);color:var(--color-on-ink);border-color:var(--color-ink)}
.note-line{margin:16px 0 0;color:var(--color-muted);font-size:14px}
.shared{padding:14px 20px;border-top:1px solid var(--color-line)}
.shared:first-child{border-top:0}
.shared header{display:flex;align-items:baseline;gap:10px;flex-wrap:wrap}
.shared header .link{margin-left:auto}
.shared .body{margin-top:8px;color:var(--color-ink-2);font-size:14px}
.shared .body h1,.shared .body h2,.shared .body h3{font-size:15px;margin:12px 0 4px}
.invite{display:flex;gap:8px;align-items:center;margin-top:12px}
.invite code{flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;padding:9px 12px;border-radius:10px;background:var(--color-paper-2);font-size:12.5px}
</style></head><body>
<div class="clouds" aria-hidden="true"></div>
<aside class="side">
  <div class="brand"><span class="sp"><img alt="" width="40" height="40" src="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAFAAAABQCAYAAACOEfKtAAAABGdBTUEAALGPC/xhBQAAACBjSFJNAAB6JgAAgIQAAPoAAACA6AAAdTAAAOpgAAA6mAAAF3CculE8AAAARGVYSWZNTQAqAAAACAABh2kABAAAAAEAAAAaAAAAAAADoAEAAwAAAAEAAQAAoAIABAAAAAEAAABQoAMABAAAAAEAAABQAAAAADHgTE8AAAHLaVRYdFhNTDpjb20uYWRvYmUueG1wAAAAAAA8eDp4bXBtZXRhIHhtbG5zOng9ImFkb2JlOm5zOm1ldGEvIiB4OnhtcHRrPSJYTVAgQ29yZSA2LjAuMCI+CiAgIDxyZGY6UkRGIHhtbG5zOnJkZj0iaHR0cDovL3d3dy53My5vcmcvMTk5OS8wMi8yMi1yZGYtc3ludGF4LW5zIyI+CiAgICAgIDxyZGY6RGVzY3JpcHRpb24gcmRmOmFib3V0PSIiCiAgICAgICAgICAgIHhtbG5zOmV4aWY9Imh0dHA6Ly9ucy5hZG9iZS5jb20vZXhpZi8xLjAvIj4KICAgICAgICAgPGV4aWY6Q29sb3JTcGFjZT4xPC9leGlmOkNvbG9yU3BhY2U+CiAgICAgICAgIDxleGlmOlBpeGVsWERpbWVuc2lvbj4yNTY8L2V4aWY6UGl4ZWxYRGltZW5zaW9uPgogICAgICAgICA8ZXhpZjpQaXhlbFlEaW1lbnNpb24+MjU2PC9leGlmOlBpeGVsWURpbWVuc2lvbj4KICAgICAgPC9yZGY6RGVzY3JpcHRpb24+CiAgIDwvcmRmOlJERj4KPC94OnhtcG1ldGE+CuYattQAAA/3SURBVHgB7VwJcFRVFv29d2cnZCGQkIBsliKLQgQJmJFVZdgsBBxnBEEQ1FEBtVAH1BEVgUABIkIQFSgIUiMSFgWJiFsEKUB2VJYQyEo2kk6nlz/ndNIkNOn838knIvar+um/vHffveffd+99970fQfAVHwI+BHwI+BDwIeBDwIeAD4G/IgIqJYVOS0sztmvXLtzf3z9cpVKFg3aoVqsNxLk/DhOudQ6HQ6dWqzW41uJaqf5FFBto20HbCrpWXJtxlNpsthJcX8J5bmlpae7JkydzExMTy3FPkdJgAU6fPh0XGhp6j06ni8fRFgJEEDBwp8cv6XvqQ1REgmoiHvsBeOyrgoAC5Byr1XoKR/qlS5e+a9Wq1ZlqEt6feepUktKFCxduDQkJGQ/QEjUaTSiwIpP2qoPnSgMkyZNEBdfL1KCeBmCq7Hb7JQCZVlhYuKJ58+bHJNrX+lhd6906bs6aNUuNDieGhYWtN5lMIzBEOTzNaMJhweHjwHGjgQeWnDyRN/JYTp7JO2WgLJSJsrGiN8UrDUxJSdEMGjToZdi4cWCgAh1R426GQo3Uw0au3LZt25sjR46ULZdXAMJmTMSwnVGlcTeiljXkZaoAogmaOBs2fZlcQrJVljYvMDBwCsCzgPjNBh7xEikbZaSsigMYFBQ0ATYjCIRlq7dcJm6genbKSFnl8iRLA/FGYg0GQyKIUvtu9mKhrJRZjqCyADQajQkIVZqAIL3YzV4clJUyyxFULoDxsA83o92rFSPKCgDja33odlMSQE7P8Ebaod0fZ/tEUZJPN7kaemmnzJRdipAkY+3bt4/A9Izz2j8CQIZZ6pLLl52/UsIo+Jxz6nDKLkVTEkA/P79wEOPctrGHMEATjXPnJzX5W99+sZhzM/nAaVhjFJEyU3apziQBhD1gckAHQo0JIPvTLli4yG/u3HlhJ0+e0v/wYzqzOQSxMQpjQh1ll+pMkqEq7ysJtFRHVc85FKlFNg/1nVp2/PgJ4e05c5puSd0apNaoBWiDkJOdzXZs31hFXSV7nf1JAoi3EISjTiIyH6qQShKOHj2u6dChHQPWmhrNF6Q7fvy4sOS9pU1St2wNKioqUusNhkrE0D9mCAyhCCLrsm3N9rhUtlBmyi5FVVKzQIT2T4mi++/s2U3v69cvds+eb/1AUF9FVGOxWIT/zHwtaNADg2NXr1kbUlZWpkYw6wQP81PBoNeLmJ+KF7OyrHl5eWreQ6GHlFIAmgIX6GzjVZEjuxQDfAuSrlyaK1G3f/8BzfLlyaHlFot6XUpKcGLivZfQTnf58mXH2HGPt9ix8yt/gob46ypy6J88qF6a8UoEEs54bhCbNWtu7dOnd+lDw4eWdOjQoaZZEAWGPCoVQbOnpGwwrV2/PnjBvHnZcXGxjCK8iiTkyC4JIDp1acpVgnl3oVJ/9MknwQBLbQJAmzZ9HtQsMtI2berU/GenToskeMjLeSRJjSssLCAoQlGRKFy8mKXdt2+vKTk5ObRnzx6l/fv1K+3Y8XZLWNMwGzRUe/jIEcOWrVsDdn+zJ8BcViYcOXJEHxfXEnlAlVcAojtJ2eUAKKeOR+HxQFVeXm7dt2+fCXaP2gQlEWnrQj/fnBqYnZ2tqws8F2E6EleBcReQCRc41Ldt2x64ffsXgaDB2YMDfanNZrPTaLMO+ywsKgL4KiZSvS2SsktWgMDON+9tzzXqq7NzcjQ5OblcTHLeJogULjMz03mP1/UppMdhz4LFI1VJSQkXqwS9vqbiOPuql8ORI7skgOCNderFAAVjgfdlsrLyosZfapJShcC5vwj2aTDohejoFgybvE2EkGFJfKrHhVKSXEtHg3BE1Gp11yJ4bV1F7zBsatasmfX2225jGs5b+yeLl+sNoOG306eFiRMnNSsouKRxDWFZnClQqaKiQhgwoP9lJEipSd5qoCwOJFVUFpXqShp4CB3GEu+oDhw4KDwxcVLUqV9/1buHJ9VNrs8ZbKIQGxtrfeapKQyXrgt45FxJADUHDx7UJa9cFdK+fbuKM2fO6D5DuFJQUKBpbPBo++BIxDnvvJUdFRVFQ1sfD0x8JIuSAOq2f/Gl//IVK0IYltDg6eFp6W3/iIJFc9V3333vN6B/vzwMBjJxXUBU0gaKreLirEgBOUMLI8KLxrZ5rhfl8saLEWs+POqR5kePHYMWioxtOM1h3FO/uMnVQY1fJTXQ1j2+O+es9uLi4kZ3GDVkcp4SRMyhBcxyAhDE+3Xr3r0sIiLcjhfrePGF6flNmzalV64zMoAXl1QwJQG0x8XGau7p2aNs0+ebAxvb7rkD6LpmHHi5tFT95Y4dAQ673WlSxoweVQwAWcVTWs3ZHCNIEkDJCi5GZP6KT0yYUIBhLDIGu1EKcaA2clrXqVOn8tsUjAuVBtCKyb1t6vPP5WGWAWdY5wiRxJftGY4oVUhv3NjHCuDY6FQaxlwVU0oCSMMMQy3qHhoxoiQyMoIbHustO9sGBATYu3fvVoYtaNfQ4fPa7l9TseqG2Vwu3NunT+noUQ8X4xY3RilSlAKQGRcV7Ix+ftJC47DhI2IyMy/oGjLXZZJ14MABJR8mr7gYHR0NrKpBJHgtWjS3xnfvZmY9qQLehPbt2lYsSJqfBefCuFCW9qEfSQ1QCkAd1lD9Ro1+JPqNN2eHZ5w/32DwmN979eUZ+REREdoFSfOyMB2zc2rGYoMziG7Rwrp2zerMHj3uRlbLLCDucz5z/8M23e66y7x2zZrzMTHRzubudTxdw3Y2FoCio02bthUhTZo4GDzXV/Noo5DLEzj5/3jVqszIyEjKZsbQs63++KNMzHAsfE5bcfT4CQO1b+OGlPPTpj6XT42kwtS0u9Ra2rzUzZsybrmlFbWuWo1JWYGikAaqbG3bthEG9u9fImdIufNNoZHq5xRaHDF8ePHGT1MyWrWKcwlMvCx0Tps3fZbx+LixBdBKGzS03M/P34FwSf3qKzNK0r7aefajD1eex25TKGilNpJuQkJCGaZ1DJ4VB49ySEbksB9zkbQcgbpSO9s1GRkZmsFDhsacP59Z5ejYxbWFmuIKsSikn5/J0atXr1JoSyG0zbX/kMNHBS0SQYwvmqjwV5Ofny/CwTjAlwa0bKDlUgQVFuGjDx36xYg2zEMKG1LWZfROSODY9xZAI5RhI17QNLT1WFwde6zgxQN7TEyM6t0572QhDnR4Cj/sECokpIndNdQslgphLIbZx6tWFgE8Csm4BWCJwtTpL4T36pMYl5b2NaZgyPJUZlWsCIKd4KX/9JM28b6+LWfOeo1RMUiK2NNSmXdk/y1jYqydEfdV0cSP8kVJAMmdpV/fvrbFixZeDA4OtrsPZ9okhBGFe9O//33YsKFFlgoLNFEltG7VGhqiInCu8EKdl5evScXC+qGDhwypW7YE4HnN9DW1U7Nly7aA9PS9ppRPPw2GVqrhYVUqSMSXQ+2b/OSk/KpcoCyvSwG8LUoDyP4tfx88uOJ/Gzdk9MbSo8seORyiAGEc/37m6QL8mh4ZM7pIo9E6vadG68TGTUjMZQ06Dl86Jbdn1WLq9Vg4UlcH7aK9MvgeP35cATT7MuB0vZTqRgqeyQGQmiFpK914snTs2FFcunhRFjWR2gBBnGsWUBOCUd6zRw/zA/cPLIantXVo176WlDuXeCupMjV15aJGR3asE7OwmgPfffDcIdpVjAIGP/AgvlAS8Wbqva+R9Ch7nUUSQNqVOil4fmhBMlO4Oz6+jLEY7Ty3a3ANGE0MNPzLli7N2rVr59nOnTtRS65itnIJFEhbygV//wBHVZb7qt6wxiwySNZCQ3FOuyvCpqrYlgvwQFYyjruKoNuFHNnlZGOuEsytD8nLiU9MKNi1a1cAYgsVPpET5s1PCouKapaFxXARXlTdIiqKL8hdUAc+p1C99OILud9++71p/ONjC2upU0GvnZOTo4UHL8PeGe3Zc+ew/eOiLjg4yIHFJDvGjTtdSX7dKkjKLjk0Ebi+DFc+AYT5NVJ9iv7duXMD33p7Tjg1g4VD7JbWrcuXLFmU1emOOwigpxCDnpejhM9rAwPPmCh17jjQfrB8hXHqtOmRCQm9zFtTN59DGxaP9rPysce/Jmj3cmTX3/RYAw/kDGGp+K8u+nxmnT5tWtFrs2bmINmKUWZzeslfDh82znr9DdfOV098EDjax9rAI23cV4E/bPfIyrIt++CDUA71oUOGIGEgMniuL3ikTT4lZffEuJNAFZHSKxf1O6EQ9qefmlK644vt5yZPfvISDL4z7f/N7m/8Z732ehieU9Nqhine9KTDJ1qOSU9Ojjp+4qTu7vju5f969B9FAFY6yyDRCwCUlF0OgMUgJNGV5GMSsGAy75j56it58d26leF7O35OICxe8l7os8893wRxHM0JdxhJ8lTVG+uZTp48pR45akyLXbvS/KKbN7fPRSBvMBr5MhrENGXGwdRXnUWSWYQQBaDgaQjVSbyWhzbEdSKmV+d3p+06szBp/kXGhstXJIcMGHh/7IrklYbc3Fzy5FoA4i+103W47huwXKpe8t77xiHDhsV8/fVuP6S8bMveX3oBGWcC58mm4pHsghUAp+x1NpB0Ivj47k54uLWIOshYg95qDU7YL4HS/bR3r3oG9v7h18i3jsVwW9cunc1du95pbtOmtTUoMAjbQjQihz3XNs6ePqP9ef9+E+r7/fbb74hgNELv3gll77z9VvatHTqwiwYPXdDgblpuVhqDaOBnEvVUJAHEJ08tw8PDP4MHZfymlCZW84PPTC0VFbZPVq8JWrduffCRY8eMiBedgbNOp8ciUPWWODogV04QmisgWDc/9s9HC8eMGV2MSRxdvBKaR97U6KsUo2EoPsQ+V83stWeSceCJEydyMHnPRVPuF1YeQHx3jHhQhVivHHFd0YGDB40//PCj6TC89LmMDG1JcUmlc8GrZoo/JjrGmcrCEqr5rq5dyzEyOKxZlAKPtJjlyaXsvKirSGogGyPluwjx0IM4lXTrdXUm4xn5IWB8sU5bxgSEq2CHF6MU2kPWY/zIQFcpswJSV4oR8W8qskpPX7nj4UTSibAdAsp02CdZYHvoR+5tgkFQ+KKc8R+djusAeBwBvM/nRPZ6gEfvyzWedNCXLHIB3FPlkWTVl+zVuwoEyXV417J+tdWUFQDukdNcFiAwpGeR20sDwcr9tHIo/3nrcK0ljTLLEUEWgCSE/S7L4ZkYWFYadTnU/3x1NJSRssplXTaA/L8qiIuWwD4ourtJLqONUI/7uA2UkbLK7U82gCS4c+fOFZh3JqMjbhO7mTSRKW0jZaOMcsFjPa9A2LBhA3N4e7p06VKGGUBXHFircHrG6+INvRGknnWpQEaESqX4CGh+UlLSgilTpngV69Y7NOG/BvH966fKgLSeL6+yme+fjzUIvqsb/xX//d3VCPiufAj4EPAh4EPAh4APAR8CPgT+Kgj8H1vKt/7AwIMVAAAAAElFTkSuQmCC"></span><span class="mark">nikxel</span>
    <button type="button" class="fold" id="fold" aria-label="Collapse sidebar" title="Collapse sidebar"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M15 18l-6-6 6-6"/></svg></button></div>
  <nav class="nav" id="nav" aria-label="Sections"></nav>
  <div class="side-foot" id="foot"></div>
</aside>
<main id="main"><div class="orgband" role="note"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="9" cy="8" r="3.5"/><path d="M2.5 20a6.5 6.5 0 0 1 13 0"/><path d="M16 4.5a3.5 3.5 0 0 1 0 7M18 14a6.5 6.5 0 0 1 3.5 6"/></svg><span><b>Organization</b><span id="orgname"></span> · what’s here is shared with your team. Your own Nikxel stays on this computer.</span></div><div class="tabbar" id="tabbar" role="tablist" aria-label="Open summaries" hidden></div><div class="inner" id="inner"><div><h1 class="display">Nikxel</h1><p class="lead">Your settings, one moment…</p></div></div></main>
<script>
(function () {
'use strict';
var reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;
var SECTIONS = [['home', 'Home'], ['chat', 'Chat'], ['library', 'Library'], ['tasks', 'Tasks'], ['automations', 'Automations'], ['people', 'People'], ['activity', 'Activity'], ['whatsnew', 'What’s new'], null, ['you', 'You'], ['meetings', 'Recording & notes'], ['whatsapp', 'WhatsApp'], ['connections', 'Connections'], ['advanced', 'Advanced']];
var ICON = {
  home: '<path d="M3 11l9-8 9 8"/><path d="M5 10v10h14V10"/>',
  chat: '<path d="M21 12a8 8 0 0 1-11.6 7.1L4 20l1-4.6A8 8 0 1 1 21 12z"/>',
  library: '<path d="M4 4h6a2 2 0 0 1 2 2v14a2 2 0 0 0-2-2H4z"/><path d="M20 4h-6a2 2 0 0 0-2 2v14a2 2 0 0 1 2-2h6z"/>',
  tasks: '<rect x="3" y="3" width="18" height="18" rx="4"/><path d="M8 12l3 3 5-6"/>',
  people: '<circle cx="9" cy="8" r="3.5"/><path d="M2.5 20a6.5 6.5 0 0 1 13 0"/><path d="M16 4.5a3.5 3.5 0 0 1 0 7M18 14a6.5 6.5 0 0 1 3.5 6"/>',
  activity: '<path d="M3 12h4l3-8 4 16 3-8h4"/>',
  whatsnew: '<path d="M12 3l1.9 5.1L19 10l-5.1 1.9L12 17l-1.9-5.1L5 10l5.1-1.9z"/><path d="M19 15l.8 2.2L22 18l-2.2.8L19 21l-.8-2.2L16 18l2.2-.8z"/>',
  automations: '<path d="M13 2L4 14h7l-1 8 9-12h-7z"/>',
  you: '<circle cx="12" cy="8" r="4"/><path d="M4 21a8 8 0 0 1 16 0"/>',
  meetings: '<rect x="9" y="2" width="6" height="12" rx="3"/><path d="M5 10a7 7 0 0 0 14 0M12 17v5"/>',
  whatsapp: '<path d="M21 12a9 9 0 0 1-13.3 7.9L3 21l1.2-4.5A9 9 0 1 1 21 12z"/><path d="M9 9.5c0 3 2.5 5.5 5.5 5.5"/>',
  connections: '<path d="M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1"/><path d="M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1"/>',
  org: '<path d="M3 21h18M5 21V7l7-4 7 4v14"/><path d="M9 21v-5h6v5M9 10h.01M15 10h.01M9 13.5h.01M15 13.5h.01"/>',
  chart: '<rect x="9" y="3" width="6" height="5" rx="1.5"/><rect x="3" y="16" width="6" height="5" rx="1.5"/><rect x="15" y="16" width="6" height="5" rx="1.5"/><path d="M12 8v4M6 16v-4h12v4"/>',
  projects: '<path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/>',
  roles: '<path d="M12 3l7 3v5c0 4.5-3 8.5-7 10-4-1.5-7-5.5-7-10V6z"/><path d="M9 12l2 2 4-4"/>',
  shared: '<path d="M4 12v7a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-7"/><path d="M16 6l-4-4-4 4M12 2v13"/>',
  back: '<path d="M15 18l-6-6 6-6"/>',
  plus: '<path d="M12 5v14M5 12h14"/>',
  chev: '<path d="M6 9l6 6 6-6"/>',
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
var pickFor = null; // the automation whose "Run on…" list is open
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

// --- ERP connection ----------------------------------------------------------------
// Typed here, signed in in a window that opens on that address. erpDraft keeps
// what's typed across state pushes; erpChange shows the form while connected.
var erpDraft = null, erpChange = false;
function erpHost(u) { return String(u || '').replace(/^[a-z]+:\/\//i, '').replace(/\/.*$/, ''); }
function erpRows(e) {
  var help = 'Your company’s ERP. I read its people and tasks, and make tasks when you ask.';
  if (e.waiting) {
    return row('Waiting for you to sign in', 'A window opened on ' + esc(erpHost(e.url)) + '. Sign in there the way you always do; it closes by itself once you’re in.',
      '<span class="chip">Signing in</span><button type="button" class="btn" data-erp="cancel">Cancel</button>');
  }
  if (e.connected && !erpChange) {
    return row('Connected to ' + esc(erpHost(e.url)), help,
      chip(true) + '<button type="button" class="link" data-erp="change">Change</button><button type="button" class="link" data-erp="disconnect">Disconnect</button>');
  }
  var value = erpDraft != null ? erpDraft : (e.url || '');
  return row(e.connected ? 'Connect a different ERP' : 'Connect your ERP', help, e.connected ? '<button type="button" class="link" data-erp="keep">Keep ' + esc(erpHost(e.url)) + '</button>' : chip(false)) +
    '<div class="row stack erpform"><label for="erpurl"><b>Its web address</b><small>The one you open in your browser to log in, like erp.yourcompany.com.</small></label>' +
    '<div class="erpline"><input class="text" id="erpurl" type="url" inputmode="url" autocomplete="url" spellcheck="false" placeholder="erp.yourcompany.com" value="' + esc(value) + '">' +
    '<button type="button" class="btn primary" data-erp="connect">Open sign-in</button></div>' +
    (e.problem ? '<p class="tpl-err" role="alert">' + esc(e.problem) + '</p>' : '') +
    '<small>A window opens on that address. Sign in there; I keep the login and close the window. Nothing in your ERP changes until you ask me to make a task.</small></div>';
}
function erpClick(t) {
  var op = t.dataset.erp;
  if (op === 'change') { erpChange = true; erpDraft = null; return show(current, false); }
  if (op === 'keep') { erpChange = false; erpDraft = null; return show(current, false); }
  if (op === 'connect') {
    var v = document.getElementById('erpurl').value.trim();
    if (!v) { document.getElementById('erpurl').focus(); return; }
    erpDraft = v; erpChange = false;
    return post({ type: 'erp', op: 'connect', url: v });
  }
  post({ type: 'erp', op: op });
}
document.addEventListener('input', function (e) { if (e.target.id === 'erpurl') erpDraft = e.target.value; });

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
var DAYSETS = [['once', 'Once, on a day'], ['daily', 'Every day'], ['weekdays', 'Weekdays'], ['mon', 'Mondays'], ['tue', 'Tuesdays'], ['wed', 'Wednesdays'], ['thu', 'Thursdays'], ['fri', 'Fridays'], ['sat', 'Saturdays'], ['sun', 'Sundays']];
function draftCard() {
  var d = draft;
  return '<section class="group" data-in id="draft"><h2>' + (d.id ? 'Edit automation' : 'New automation') + '</h2><div class="card draft">' +
    '<label>Name<input class="text" data-draft="name" value="' + esc(d.name) + '" autocomplete="off"></label>' +
    '<label>When<span class="when"><select data-draft="trigger">' + TRIGGERS.map(function (t) { return '<option value="' + t[0] + '"' + (t[0] === d.trigger ? ' selected' : '') + '>' + t[1] + '</option>'; }).join('') + '</select>' +
      (d.trigger === 'schedule' ? '<select data-draft="days">' + DAYSETS.map(function (t) { return '<option value="' + t[0] + '"' + (t[0] === d.days ? ' selected' : '') + '>' + t[1] + '</option>'; }).join('') + '</select>' +
        (d.days === 'once' ? '<input class="text" type="date" data-draft="date" value="' + esc(d.date) + '" style="width:160px">' : '') +
        '<input class="text" type="time" data-draft="time" value="' + esc(d.time) + '" style="width:120px">' : '') + '</span></label>' +
    (d.trigger === 'schedule' && d.days === 'once' ? '<p class="visible" style="margin:0">Temporary: it runs once, then switches itself off. If your computer is asleep then, it runs when you’re back.</p>' : '') +
    '<label>What I should do<textarea data-draft="instruction" spellcheck="false">' + esc(d.instruction) + '</textarea></label>' +
    '<div class="label-like">Files it follows<p class="visible" style="margin:2px 0 8px">A template or format to follow every time, like your SOP format. Drop it here or attach it.</p>' +
      '<div class="atts" style="margin:0 0 8px">' + attsHTML(d.files || [], 'draft') + '</div><button type="button" class="btn" data-draftattach>Attach a file</button></div>' +
    '<div class="actions"><button type="button" class="btn primary" data-autosave>Save automation</button><button type="button" class="btn" data-autocancel>Cancel</button></div></div></section>';
}
// "Run on…": an automation for meetings (or days, weeks) run on one you pick, e.g. a client call it skipped.
var RUN_ON = { meeting: 'meetings', day: 'daily', week: 'weekly' };
function runOnHTML(a, s) {
  var list = s.library.filter(function (e) { return e.kind === RUN_ON[a.trigger]; }).slice(0, 40);
  return '<div class="meta"><select data-autorunon="' + esc(a.id) + '" aria-label="Run it on"><option value="">' + (list.length ? 'Pick one to run it on…' : 'Nothing to run it on yet') + '</option>' +
    list.map(function (e) { return '<option value="' + esc(e.id) + '">' + esc(e.date.slice(0, 10) + ' · ' + e.title) + '</option>'; }).join('') + '</select>' +
    '<span class="visible">It runs even if it would have skipped this one.</span></div>';
}
function redrawAutomations() { if (current === 'automations' && !S.active && !S.editor) show('automations', false); }
function openDraft(a) {
  var tmr = new Date(Date.now() + 864e5), ymd = tmr.getFullYear() + '-' + ('0' + (tmr.getMonth() + 1)).slice(-2) + '-' + ('0' + tmr.getDate()).slice(-2);
  draft = { id: a.id || '', name: a.name, trigger: a.trigger, time: a.time || '09:00', days: a.date ? 'once' : a.days || 'daily', date: a.date || ymd, instruction: a.instruction, files: (a.files || []).slice() };
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
        '<div class="atts" id="atts">' + attsHTML(chatFiles, 'chat') + '</div>' +
        '<form class="field" id="chatf"><button type="button" class="icon" data-chat="attach" aria-label="Attach a document or image" title="Attach a document or image (or drop one here)"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 5v14M5 12h14"/></svg></button>' +
        '<input id="ci" placeholder="Ask anything…" autocomplete="off" spellcheck="false" aria-label="Message" value="' + esc(chatDraft) + '">' +
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
        '<div class="meta"><span class="chip">' + esc(a.when) + '</span>' + (a.date ? '<span class="chip">' + (a.done ? 'Done, switched off' : 'Temporary') + '</span>' : '') +
          (a.files || []).map(function (f) { return '<span class="chip">📎 ' + esc(f.name) + '</span>'; }).join('') + (on ? '<span class="busy"><span class="dots"><i></i><i></i><i></i></span>Running…</span>' : '') + '</div>' +
        (pickFor === a.id ? runOnHTML(a, s) : '') + '</div>' +
        '<div class="ctl">' + '<button type="button" class="link" data-autorun="' + esc(a.id) + '"' + (on ? ' disabled' : '') + '>Run now</button>' +
        (RUN_ON[a.trigger] ? '<button type="button" class="link" data-autopick="' + esc(a.id) + '"' + (on ? ' disabled' : '') + '>Run on…</button>' : '') +
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
        (r.file ? '<button type="button" class="link" data-open="' + esc(r.file) + '">Open summary</button>' : '') +
        (r.text && !r.skipped ? '<button type="button" class="link" data-copyrun="' + s.automationRuns.indexOf(r) + '">Copy</button>' : '') + '</header>' +
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

  whatsnew: function (s) {
    var rel = s.whatsNew || [], unseen = s.whatsNewUnseen || [];
    return '<div data-in><h1 class="display">What’s new</h1><p class="lead">What each update added. Show me walks you through one again.</p></div>' +
      (rel.length ? rel.map(function (r) {
        var tour = featureSteps([r.id]).length;
        return '<section class="group" data-in><h2>' + esc(dayName(r.id)) + (unseen.indexOf(r.id) >= 0 ? ' <span class="chip ok">New</span>' : '') + '</h2><div class="card">' +
          r.items.map(function (it) { return '<div class="row stack"><div><b>' + esc(it.title) + '</b><div class="wnb">' + md(it.body) + '</div></div></div>'; }).join('') + '</div>' +
          (tour ? '<p style="margin:12px 0 0"><button type="button" class="btn" data-wn="' + esc(r.id) + '">Show me</button></p>' : '') + '</section>';
      }).join('') : '<p class="lead" data-in style="margin-top:24px">Nothing listed yet.</p>');
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
        row('Change “' + esc(tpl) + '”', 'Pick its sections, length and tone, or write it in your own words.', link('Edit…', 'editTemplate')) +
        row('More templates', 'One per kind of meeting: client calls, design reviews, the board.', link('New…', 'newTemplate'))) +
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
        conn('Team dashboard', 'Send your day and your meeting minutes to your team.', st.dashboard, 'connectDashboard')) +
      group('ERP', erpRows(s.erp || {})) +
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
var tourAt = -1, tourEls = null, tourSteps = TOUR, tourEnd = null, tourFrom = null;
// steps: [selector, title, text, section to open first]; onEnd runs when it's finished or skipped.
function startTour(steps, onEnd) {
  if (tourAt >= 0) return;
  tourSteps = steps || TOUR;
  tourEnd = onEnd || function () { post({ type: 'tourDone' }); };
  tourFrom = current;
  tourEls = { block: document.createElement('div'), hole: document.createElement('div'), tip: document.createElement('div') };
  tourEls.block.className = 'tour-block'; tourEls.hole.className = 'tour-hole'; tourEls.tip.className = 'tour-tip';
  tourEls.tip.setAttribute('role', 'dialog');
  document.body.append(tourEls.block, tourEls.hole, tourEls.tip);
  tourAt = 0; showTourStep();
}
// A feature tour opens each section it talks about (the organization's too), then points at it.
function showTourStep() {
  var to = tourSteps[tourAt][3];
  if (to === 'meeting') {
    // Inside a summary: the window opens the newest meeting and its page shows this step; nx.tourResume carries on.
    [tourEls.block, tourEls.hole, tourEls.tip].forEach(function (e) { e.hidden = true; });
    var raw = tourSteps[tourAt][4] || {};
    return post({ type: 'tourMeeting', title: raw.title, text: raw.text, n: tourAt + 1, of: tourSteps.length, last: tourAt === tourSteps.length - 1 });
  }
  [tourEls.block, tourEls.hole, tourEls.tip].forEach(function (e) { e.hidden = false; });
  // An open summary covers the page: going to the step's section closes it.
  if (to && (to !== current || (S && S.active))) {
    try { goTo(to); } catch (e) { /* a page that can't draw doesn't stop the tour: its sidebar entry is still there */ }
    setTimeout(placeTourStep, 90);
  } else placeTourStep();
}
function placeTourStep() {
  if (!tourEls) return;
  var step = tourSteps[tourAt], el = document.querySelector(step[0]);
  if (!el) { tourAt++; return tourAt < tourSteps.length ? showTourStep() : endTour(); }
  // A sidebar scrolled down (the organizations list open) hides the top entries: bring it into view first.
  el.scrollIntoView({ block: 'nearest' });
  var r = el.getBoundingClientRect(), pad = 6;
  Object.assign(tourEls.hole.style, { left: r.left - pad + 'px', top: r.top - pad + 'px', width: r.width + pad * 2 + 'px', height: r.height + pad * 2 + 'px' });
  var last = tourAt === tourSteps.length - 1;
  // A pen-stroke arrow from the note back to what it's about.
  tourEls.tip.innerHTML = '<svg class="tour-arrow" viewBox="0 0 58 44" fill="none" aria-hidden="true"><g stroke="currentColor" stroke-width="3.4" stroke-linecap="round" stroke-linejoin="round">' +
    '<path d="M56 30 C 44 40, 26 38, 14 26 S 6 14, 4 12"/><path class="head" d="M3 24 L 3 11 L 16 10"/></g></svg>' +
    '<b>' + step[1] + '</b><p>' + step[2] + '</p><div class="row2"><span class="count">' + (tourAt + 1) + ' of ' + tourSteps.length + '</span>' +
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
  // A feature tour hands you back where you were.
  if (tourSteps !== TOUR && tourFrom && tourFrom !== current) goTo(tourFrom);
  var done = tourEnd; tourEnd = null;
  if (done) done();
}

// --- what's new --------------------------------------------------------------------
// The tour of the given updates (WHATSNEW.md), oldest first: a step for each `tour:` line.
function featureSteps(ids) {
  var out = [];
  (S && S.whatsNew || []).filter(function (r) { return ids.indexOf(r.id) >= 0; }).reverse().forEach(function (r) {
    r.items.forEach(function (it) {
      (it.tour || []).forEach(function (t) {
        // "meeting": a step shown inside the newest meeting summary, not on a sidebar entry.
        out.push(['#nav [data-section="' + t.section + '"]', esc(t.title), esc(String(t.text).replace(/\*\*/g, '')), t.section,
          { title: t.title, text: String(t.text).replace(/\*\*/g, '') }]);
      });
    });
  });
  return out;
}
function seenWhatsNew() { post({ type: 'whatsNewSeen' }); }
// Once per update: the first time the window opens after it, after the beginner tour if that's still due.
var featureTourChecked = false;
function maybeFeatureTour() {
  if (featureTourChecked || !S || S.tour || tourAt >= 0) return;
  var ids = S.whatsNewUnseen || [];
  featureTourChecked = true;
  var steps = featureSteps(ids);
  if (steps.length) setTimeout(function () { if (!S.editor && !T) startTour(steps, seenWhatsNew); }, reduce ? 200 : 1400);
}
function markNew() {
  var b = nav.querySelector('[data-section="whatsnew"]');
  if (b) b.classList.toggle('new', !!(S && S.whatsNewUnseen && S.whatsNewUnseen.length));
}
function dayName(id) {
  var d = new Date(String(id).slice(0, 10) + 'T12:00:00'); // "2026-11-27.2", a second update that day, shows as the date
  return isNaN(d) ? id : d.toLocaleDateString(undefined, { day: 'numeric', month: 'long', year: 'numeric' });
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
var chatFiles = []; // attached for the next message: {id, name}, or {reading: name} while it's read
var chatLog = [], chatDraft = '', chatBusy = false, chatListening = false, chatSources = null, chatSeq = 0, chatPending = {};
var SUGGEST = ['What did I agree to in today’s meetings?', 'Who’s waiting on me on WhatsApp?', 'What did I work on this week?', 'Anything urgent in my inbox?'];
function chatAsk(type, text, extra) {
  return new Promise(function (r) { var id = ++chatSeq; chatPending[id] = r; post(Object.assign({ type: type, id: id, text: text || '' }, extra)); });
}
function logHTML() {
  if (!chatLog.length) return '<div class="hello"><div class="sp">' + sprite(0) + '</div><p>Ask me about the last two weeks: meetings, days, notes, projects, WhatsApp and Gmail. I can draft emails and make ERP tasks too.</p>' +
    '<div class="suggest">' + SUGGEST.map(function (q) { return '<button type="button" data-chat="suggest">' + esc(q) + '</button>'; }).join('') + '</div></div>';
  return chatLog.map(function (m) {
    if (m.pending) return '<div class="msg bot"><span class="dots"><i></i><i></i><i></i></span><span class="hint">' + esc(m.pending) + '</span></div>';
    return '<div class="msg ' + m.who + '">' + (m.who === 'bot' ? md(m.text) : esc(m.text)) +
      (m.files && m.files.length ? '<span class="files">📎 ' + m.files.map(esc).join(', ') + '</span>' : '') + '</div>';
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
  var ready = chatFiles.length && !chatFiles.some(function (f) { return f.reading; });
  go.disabled = chatBusy || chatListening || (!ci.value.trim() && !ready) || chatFiles.some(function (f) { return f.reading; });
}
function chatRun(text) {
  var files = chatFiles.filter(function (f) { return f.id; });
  chatFiles = []; drawAtts();
  chatLog.push({ who: 'me', text: text, files: files.map(function (f) { return f.name; }) });
  var wait = { pending: files.length ? 'reading what you attached…' : 'thinking…' };
  chatLog.push(wait); chatBusy = true; drawLog();
  chatAsk('chat', text, { files: files.map(function (f) { return f.id; }) }).then(function (r) {
    chatLog[chatLog.indexOf(wait)] = { who: 'bot', text: r.text };
    chatBusy = false;
    var ci = document.getElementById('ci');
    if (r.error && ci && !ci.value) { ci.value = chatDraft = text; }   // keep the question to try again
    drawLog();
    if (ci) ci.focus();
  });
}
// --- files for Nikxel to read (dropped, or the + button): read on this computer, never uploaded ---
function attsHTML(list, where) {
  return list.map(function (f, i) {
    return '<span class="att' + (f.reading ? ' reading' : '') + '" title="' + esc(f.name || f.reading) + '">📎 <span>' + esc(f.reading ? 'Reading ' + f.reading + '…' : f.name) + '</span>' +
      (f.reading ? '' : '<button type="button" data-unattach="' + where + ':' + i + '" aria-label="Remove ' + esc(f.name) + '">×</button>') + '</span>';
  }).join('');
}
function drawAtts() { var el = document.getElementById('atts'); if (el) el.innerHTML = attsHTML(chatFiles, 'chat'); syncChat(); }
// `into`: the chat's list or the automation draft's. Each file is read natively: {id, name} or {error}.
function attachResults(into, results, redraw) {
  (results || []).forEach(function (r) {
    if (r.error) { if (into === chatFiles) { chatLog.push({ who: 'bot', text: r.error }); drawLog(); } else makeError = r.error; }
    else into.push({ id: r.id, name: r.name });
  });
  redraw();
}
function attachDropped(fileList, into, redraw) {
  [].forEach.call(fileList, function (file) {
    var slot = { reading: file.name }; into.push(slot); redraw();
    var done = function (r) { into.splice(into.indexOf(slot), 1); attachResults(into, [r], redraw); };
    if (file.size > 15e6) return done({ error: file.name + ' is over 15 MB.' });
    var fr = new FileReader();
    fr.onload = function () { chatAsk('attachAdd', '', { name: file.name, data: String(fr.result).split(',')[1] || '' }).then(done); };
    fr.onerror = function () { done({ error: 'Couldn’t open ' + file.name + '.' }); };
    fr.readAsDataURL(file);
  });
}
// Files dropped anywhere in the window go to the chat, or to the automation being edited; never opened as a page.
var dragDepth = 0;
function dropTarget() { return current === 'chat' && !(S && (S.active || S.editor)) ? 'chat' : current === 'automations' && draft ? 'draft' : null; }
document.addEventListener('dragenter', function (e) { if (e.dataTransfer && [].indexOf.call(e.dataTransfer.types, 'Files') >= 0 && dropTarget()) { dragDepth++; document.body.classList.add('dropping'); } });
document.addEventListener('dragleave', function () { if (dragDepth && --dragDepth === 0) document.body.classList.remove('dropping'); });
document.addEventListener('dragover', function (e) { e.preventDefault(); });
document.addEventListener('drop', function (e) {
  e.preventDefault(); dragDepth = 0; document.body.classList.remove('dropping');
  var files = e.dataTransfer && e.dataTransfer.files, to = dropTarget();
  if (!files || !files.length || !to) return;
  if (to === 'chat') attachDropped(files, chatFiles, drawAtts);
  else { draft.files = draft.files || []; attachDropped(files, draft.files, redrawAutomations); }
});

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

// --- organization -----------------------------------------------------------------
// The shared side, in its own room (body.org). Everything here is read live from
// the team's server through this computer's pairing (post 'org' → nikxel-api);
// nothing of the team's is kept on disk, and nothing leaves without a click.
var ORG_SECTIONS = [['org-home', 'Overview', 'org'], ['org-chart', 'Org chart', 'chart'], ['org-projects', 'Projects', 'projects'], ['org-roles', 'Roles', 'roles'], ['org-shared', 'Shared by me', 'shared'], ['org-connection', 'Organizations', 'connections']];
// The org's roles, from the server (the owner can add and change them); these are the defaults until they load.
var TIERS = [['owner', 'Owner'], ['cofounder', 'Co-founder'], ['admin', 'Admin'], ['member', 'Member']];
var ROLE_NAME = { owner: 'Owner', cofounder: 'Co-founder', admin: 'Admin', member: 'Member' };
var PERM_NAME = [['invite', 'Invite people'], ['people', 'Change roles, remove people'], ['all_projects', 'See every project'], ['day_summaries', 'Read teammates’ days'], ['chat_all', 'Every project in chat']];
var O = { erp: null, loaded: false, loading: false, error: '', org: null, me: null, members: [], projects: [], shared: null, sel: null, open: null, invite: null, note: '', newProj: '' };
var dragId = null;

function inOrg() { return typeof current === 'string' && current.indexOf('org-') === 0; }
function orgCall(method, path, body) {
  return new Promise(function (r) { var id = ++chatSeq; chatPending[id] = r; post({ type: 'org', id: id, method: method, path: path, body: body || null }); });
}
function ok(r) { return r && r.status >= 200 && r.status < 300; }
function orgErr(r) {
  if (!r || !r.status) return 'Couldn’t reach your organization. Check your internet, then try again.';
  if (r.status === 401) return 'This computer isn’t connected to your organization any more. Connect it again under Connection.';
  if (r.status === 403) return 'Your role can’t do that.';
  return (r.data && r.data.error) || 'The server said ' + r.status + '.';
}
function orgRedraw() { if (inOrg() && !(S && S.editor)) show(current, false); }
function orgFetch() {
  return Promise.all([orgCall('GET', '/api/members'), orgCall('GET', '/api/projects'), orgCall('GET', '/api/shared/mine'), orgCall('GET', '/api/roles'), orgCall('GET', '/api/me/orgs')]).then(function (x) {
    O.orgs = ok(x[4]) ? x[4].data : [];
    O.members = ok(x[0]) ? x[0].data : []; O.projects = ok(x[1]) ? x[1].data : []; O.shared = ok(x[2]) ? x[2].data : null;
    if (ok(x[3])) { O.roles = x[3].data; TIERS = O.roles.map(function (r) { return [r.key, r.name]; }); ROLE_NAME = {}; O.roles.forEach(function (r) { ROLE_NAME[r.key] = r.name; }); }
    if (O.open) return orgCall('GET', '/api/projects/' + encodeURIComponent(O.open.project.id)).then(function (r) { O.open = ok(r) ? r.data : null; });
  });
}
function orgLoad() {
  if (O.loading) return;
  O.loading = true; O.error = '';
  orgCall('GET', '/api/org').then(function (r) {
    if (!ok(r)) { O.error = orgErr(r); return; }
    O.org = r.data.org; O.me = r.data.me;
    if (!O.org) { O.error = 'Your account isn’t in an organization yet. Ask an admin for an invite.'; return; }
    document.getElementById('orgname').textContent = ' · ' + O.org.name;
    return orgFetch();
  }).then(function () { O.loading = false; O.loaded = true; orgRedraw(); });
}
// One change, then everything read again so the chart shows what the server now holds.
function orgDo(call, done) {
  O.note = 'Saving…'; orgRedraw();
  return call.then(function (r) {
    O.note = ok(r) ? done : orgErr(r);
    return orgFetch();
  }).then(orgRedraw);
}

function can(perm) { return !!O.me && (O.me.role === 'owner' || (O.me.perms || []).indexOf(perm) >= 0); }
function permsOf(key) { var r = (O.roles || []).filter(function (x) { return x.key === key; })[0]; return r ? r.perms : []; }
// Nobody hands out more than they have: a role you can give or touch is one whose permissions are all yours.
function covers(key) { return permsOf(key).every(can); }
function roleName(key) { return ROLE_NAME[key] || 'Member'; }
function aRole(key) { var n = roleName(key); return (/^[aeiou]/i.test(n) ? 'an ' : 'a ') + n.toLowerCase(); }
function member(id) { return O.members.filter(function (m) { return m.user_id === id; })[0]; }
function proj(id) { return O.projects.filter(function (p) { return p.id === id; })[0]; }
function nameOf(m) { return (m && (m.name || m.email)) || 'Someone'; }
function first(n) { return String(n || '').split(/\s+/)[0]; }
// The server enforces all of this too; here it only decides what can be dragged where.
function canMove(p, to) {
  if (!can('people') || !p || p.role === 'owner' || to === 'owner' || p.role === to || p.user_id === O.me.user_id) return false;
  return covers(to) && covers(p.role);
}
function canRemove(p) { return can('people') && p.role !== 'owner' && p.user_id !== O.me.user_id && covers(p.role); }
function onTeam(pr, id) { return pr.members.some(function (m) { return m.user_id === id; }); }
function canEditTeam(pr) { return can('all_projects') || onTeam(pr, O.me.user_id); }
function inviteRoles() { return !can('invite') ? [] : TIERS.slice(1).map(function (t) { return t[0]; }).filter(covers); }
function initials(n) { var w = String(n || '?').trim().split(/\s+/); return ((w[0] || '?')[0] + (w.length > 1 ? w[w.length - 1][0] : '')).toUpperCase(); }
// Spread by the golden angle, so ids that differ by one letter still get far-apart colours.
function hue(s) { var h = 0; s = String(s || ''); for (var i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) % 9973; return Math.round(h * 137.508) % 360; }
function av(id, name) { return '<span class="av" style="--h:' + hue(id) + '" aria-hidden="true">' + esc(initials(name)) + '</span>'; }
function day(d) { return when({ date: d + ' 00:00', kind: 'daily' }); }
function visibleTo(pr) { return 'Visible to the ' + pr.members.length + ' ' + (pr.members.length === 1 ? 'person' : 'people') + ' on it, and roles that see every project'; }

function orgHead(title, lead) { return '<div data-in><h1 class="display">' + title + '</h1>' + (lead ? '<p class="lead">' + lead + '</p>' : '') + '</div>' + (O.note ? '<p class="note-line" role="status">' + esc(O.note) + '</p>' : ''); }
// Every org page goes through here: not connected, loading, or the server said no.
function orgGate(title, body) {
  if (!S.status.dashboard) return orgHead(title, 'Connect this computer to your team’s organization to share meeting minutes into projects and send your day. Nothing is shared until you choose to.') +
    group('Not connected',
      row('Sign in with Google', 'Also connects Gmail and Calendar to Nikxel on this computer. Your mail and calendar stay here; your organization only learns your name and email.',
        '<button type="button" class="btn primary" data-org="signin"' + (O.signing ? ' disabled' : '') + '>' + (O.signing ? 'Finish in your browser…' : 'Sign in with Google') + '</button>') +
      row('Or use a pairing code', 'From your organization’s dashboard.', btn('Enter code…', 'connectDashboard'))) +
    group('Not in an organization yet?',
      row('Join with an invite link', 'Paste the link your admin sent you, then sign in with Google.',
        '<form class="newproj" id="orgjoin"><input placeholder="Invite link" autocomplete="off" aria-label="Invite link"><button class="btn"' + (O.signing ? ' disabled' : '') + '>Join</button></form>') +
      row('Start a new organization', 'You’ll be its owner. Invite your team after, and hand ownership to someone else any time.',
        '<form class="newproj" id="orgnew"><input placeholder="Company name" maxlength="80" autocomplete="off" aria-label="Company name"><button class="btn"' + (O.signing ? ' disabled' : '') + '>Start</button></form>'));
  if (!O.loaded) { setTimeout(orgLoad); return orgHead(title, '') + '<p class="busy" data-in><span class="dots"><i></i><i></i><i></i></span>Reading your organization…</p>'; }
  if (O.error) return orgHead(title, '') + '<div class="banner" data-in><p>' + esc(O.error) + '</p><button type="button" class="btn" data-org="reload">Try again</button></div>';
  return body();
}

function personCard(m) {
  var me = m.user_id === O.me.user_id;
  return '<button type="button" class="pcard' + (me ? ' me' : '') + (O.sel === m.user_id ? ' sel' : '') + '" data-org="person" data-id="' + esc(m.user_id) + '" draggable="true">' +
    av(m.user_id, nameOf(m)) + '<span>' + esc(nameOf(m)) + (me ? ' <small>(you)</small>' : '') + '</span></button>';
}
function teamCard(pr) {
  var edit = canEditTeam(pr);
  return '<div class="team" data-team="' + esc(pr.id) + '"><header><button type="button" class="link" data-org="openproj" data-id="' + esc(pr.id) + '">' + esc(pr.name) + '</button><small>' + pr.members.length + '</small></header>' +
    '<div class="avs">' + (pr.members.map(function (m) {
      return '<span class="chip-av">' + av(m.user_id, m.name) + esc(first(m.name) || 'Someone') +
        (edit ? '<button type="button" data-org="unteam" data-team="' + esc(pr.id) + '" data-id="' + esc(m.user_id) + '" aria-label="Take ' + esc(m.name) + ' off ' + esc(pr.name) + '">×</button>' : '') + '</span>';
    }).join('') || '<small class="visible">Nobody yet</small>') + '</div><p class="visible" style="margin:0">' + visibleTo(pr) + '</p></div>';
}
// Your ERP projects: the ones with a task assigned to you, or one you assigned. Shown before anything is sent.
function erpImport() {
  var have = O.projects.map(function (p) { return p.name.toLowerCase(); });
  var e = O.erp, fresh = e && e.names ? e.names.filter(function (n) { return have.indexOf(n.toLowerCase()) < 0; }) : [];
  return '<section class="group" data-in><h2>From your ERP</h2><div class="card">' + (!e
    ? row('Bring in your ERP projects', 'The projects where you have a task, or gave someone one. You see the list before anything is sent.', '<button type="button" class="btn" data-org="erpread"' + (S.status.erp ? '' : ' disabled title="Connect your ERP first"') + '>Find them</button>')
    : e.busy ? '<p class="busy"><span class="dots"><i></i><i></i><i></i></span>Reading your ERP tasks…</p>'
    : e.error ? row(esc(e.error), '', '<button type="button" class="btn" data-org="erpread">Try again</button>')
    : !fresh.length ? row('You’re up to date', 'Every ERP project you work on is already here.', '<button type="button" class="link" data-org="erpclose">Done</button>')
    : '<p class="visible" style="margin:12px 16px 4px">These names go to ' + esc(O.org.name) + ', with you on each. Untick any to leave out.</p>' +
      fresh.map(function (n) { return row(esc(n), '', '<input type="checkbox" data-erp checked value="' + esc(n) + '" aria-label="' + esc(n) + '" style="width:20px;height:20px;accent-color:currentColor">'); }).join('') +
      row('', '', '<button type="button" class="link" data-org="erpclose">Cancel</button><button type="button" class="btn primary" data-org="erpsend">Add them</button>')) + '</div></section>';
}
function newProjectForm() {
  return '<form class="newproj" id="newproj"><input id="np" placeholder="New project name" value="' + esc(O.newProj) + '" maxlength="80" autocomplete="off" aria-label="New project name"><button class="btn">Create</button></form>';
}
function inviteBox() {
  var i = O.invite;
  return '<div class="banner" data-in><div style="flex:1;min-width:0"><b>Invite link for ' + esc(aRole(i.role)) + '</b>' +
    '<div class="invite"><code>' + esc(i.url || i.token) + '</code><button type="button" class="btn" data-org="copyinvite">Copy</button></div>' +
    '<small class="visible">' + (i.url ? 'Send it to them. In Nikxel they paste it under Organization → Join with an invite link, sign in with Google, and join as ' + esc(aRole(i.role)) + '.' : 'Your server has no dashboard address set (APP_URL), so this is the raw invite code.') + '</small></div>' +
    '<button type="button" class="link" data-org="closeinvite">Done</button></div>';
}
function personPanel() {
  var m = member(O.sel);
  if (!m) return '';
  var roles = TIERS.slice(1).map(function (t) {
    var on = m.role === t[0], able = on || canMove(m, t[0]);
    return '<button type="button" class="btn" aria-pressed="' + on + '" data-org="role" data-id="' + esc(m.user_id) + '" data-role="' + esc(t[0]) + '"' + (able ? '' : ' disabled') + '>' + esc(t[1]) + '</button>';
  }).join('');
  var teams = O.projects.map(function (pr) {
    var on = onTeam(pr, m.user_id);
    return row(esc(pr.name), on ? 'On this project' : '', canEditTeam(pr) ? '<button type="button" class="switch" role="switch" aria-checked="' + on + '" aria-label="' + esc(pr.name) + '" data-org="' + (on ? 'unteam' : 'team') + '" data-team="' + esc(pr.id) + '" data-id="' + esc(m.user_id) + '"></button>' : (on ? chip(true, 'On it') : ''));
  }).join('');
  return '<section class="group pdetail" data-in><div class="card"><div class="head">' + av(m.user_id, nameOf(m)) + '<div style="flex:1"><b>' + esc(nameOf(m)) + '</b><br><small class="visible">' + (m.email ? esc(m.email) + ' · ' : '') + esc(roleName(m.role)) + '</small></div>' +
    '<button type="button" class="link" data-org="unsel">Close</button></div>' +
    (m.role === 'owner' ? row('Role', 'The owner’s role is fixed.', chip(true, 'Owner')) : row('Role', can('people') ? 'What they can see and manage. Set what each role can do under Roles.' : '', '<div class="roles">' + roles + '</div>')) +
    (teams || row('Projects', 'No projects yet.', '')) +
    (O.me.role === 'owner' && m.user_id !== O.me.user_id ? row('Make ' + esc(first(nameOf(m))) + ' the owner', 'They take over ' + esc(O.org.name) + '. You stay on as a co-founder.', '<button type="button" class="btn" data-org="owner" data-id="' + esc(m.user_id) + '">Make owner</button>') : '') +
    (canRemove(m) ? row('Remove from ' + esc(O.org.name), 'They lose access to every project at once. What they shared stays.', '<button type="button" class="btn" data-org="remove" data-id="' + esc(m.user_id) + '">Remove</button>') : '') +
    '</div></section>';
}
function sharedMeeting(pid, x, mine) {
  return '<div class="shared"><header><b>' + esc(x.title) + '</b><small class="visible">' + esc(x.name || (mine ? 'You' : 'Someone')) + ' · ' + day(x.date) + '</small>' +
    (mine || can('all_projects') ? '<button type="button" class="link" data-org="unshare" data-proj="' + esc(pid) + '" data-id="' + esc(x.id || x.meeting_id) + '">Unshare</button>' : '') + '</header>' +
    (x.body ? '<details class="body"><summary>Read</summary>' + md(x.body) + '</details>' : '') + '</div>';
}

VIEWS['org-home'] = function () {
  return orgGate('Organization', function () {
    var mine = O.projects.filter(function (p) { return onTeam(p, O.me.user_id); });
    var sh = O.shared || { meetings: [], days: [] };
    return orgHead(esc(O.org.name), 'You’re ' + (O.me.role === 'owner' ? 'the owner' : esc(aRole(O.me.role))) + ' here. This side of Nikxel is shared: what you see comes from your team, and what you send here leaves your computer.') +
      '<div class="orgstats" data-in><div class="card"><b>' + O.members.length + '</b><small>people</small></div><div class="card"><b>' + mine.length + '</b><small>your projects</small></div><div class="card"><b>' + (sh.meetings.length + sh.days.length) + '</b><small>things you’ve shared</small></div></div>' +
      '<section class="group" data-in><h2>What can leave your computer</h2><div class="card"><ul class="rules">' +
        '<li>A meeting’s minutes, without the client summary, to one project, when you click Send.</li>' +
        '<li>Your day’s work summary, after you cross out anything you’d rather keep.</li>' +
        '<li>Never your recordings, transcripts, WhatsApp, email or what you do on this computer.</li>' +
        '<li>Anything you sent can be unshared from <b>Shared by me</b>.</li></ul></div></section>' +
      group('Your projects', mine.map(function (p) { return row(esc(p.name), visibleTo(p), '<button type="button" class="link" data-org="openproj" data-id="' + esc(p.id) + '">Open</button>'); }).join('') || '<p class="empty">You’re not on a project yet.</p>');
  });
};
VIEWS['org-chart'] = function () {
  return orgGate('Org chart', function () {
    var tiers = TIERS.map(function (t) {
      var ppl = O.members.filter(function (m) { return m.role === t[0]; });
      var add = inviteRoles().indexOf(t[0]) >= 0 ? '<button type="button" class="pcard add" data-org="invite" data-role="' + esc(t[0]) + '">+ Invite</button>' : '';
      if (!ppl.length && !add) return '';
      return '<div class="tier" data-tier="' + esc(t[0]) + '" data-in><h3>' + esc(t[1]) + '<span>' + ppl.length + '</span></h3><div class="row">' +
        (ppl.map(personCard).join('') || '<span class="hint">' + (can('people') ? 'Drag someone here' : 'Nobody yet') + '</span>') + add + '</div></div>';
    }).join('');
    return orgHead('Org chart', can('people')
        ? 'Drag people between levels to change their role, and onto a project to add them. Click anyone for the details.'
        : 'Who’s who in ' + esc(O.org.name) + ', and the projects you’re on. Drag a teammate onto one of your projects to add them.') +
      (O.invite ? inviteBox() : '') +
      '<div class="orggrid"><div class="tiers">' + tiers + '</div><div class="teams" data-in><h2>Projects</h2>' + (O.projects.map(teamCard).join('') || '<p class="visible">No projects yet.</p>') + newProjectForm() + '</div></div>' +
      personPanel();
  });
};
VIEWS['org-projects'] = function () {
  return orgGate('Projects', function () {
    if (O.open) {
      var p = O.open.project, meetings = [];
      O.open.days.forEach(function (d) { d.meetings.forEach(function (m) { meetings.push(Object.assign({ date: d.date }, m)); }); });
      return '<p data-in style="margin:0 0 12px"><button type="button" class="link" data-org="closeproj">← All projects</button></p>' + orgHead(esc(p.name), esc(p.description || '')) +
        '<p class="visible" data-in>' + visibleTo(p) + '</p>' +
        group('People', '<div class="avs" style="padding:12px 16px">' + p.members.map(function (m) { return '<span class="chip-av">' + av(m.user_id, m.name) + esc(m.name || 'Someone') + '</span>'; }).join('') + '</div>') +
        '<section class="group" data-in><h2>Shared minutes</h2><div class="card">' + (meetings.map(function (m) { return sharedMeeting(p.id, m, m.user_id === O.me.user_id); }).join('') || '<p class="empty">Nothing shared yet. After a meeting, send its minutes here from the summary.</p>') + '</div></section>';
    }
    return orgHead('Projects', can('all_projects') ? 'Every project in ' + esc(O.org.name) + '. Open one to see what’s been shared into it.' : 'The projects you’re on. Open one to see what your teammates shared.') +
      '<section class="group" data-in><div class="card">' + (O.projects.map(function (p) {
        return row(esc(p.name), visibleTo(p) + (p.last_activity ? ' · last shared ' + day(p.last_activity) : ''), '<button type="button" class="link" data-org="openproj" data-id="' + esc(p.id) + '">Open</button>');
      }).join('') || '<p class="empty">No projects yet.</p>') + '</div></section>' +
      '<section class="group" data-in><h2>New project</h2>' + newProjectForm() + '</section>' + erpImport();
  });
};
VIEWS['org-roles'] = function () {
  return orgGate('Roles', function () {
    var mine = O.me.role === 'owner', roles = O.roles || [];
    var head = '<tr><th scope="col">Role</th>' + PERM_NAME.map(function (p) { return '<th scope="col">' + p[1] + '</th>'; }).join('') + '<th scope="col">People</th>' + (mine ? '<th></th>' : '') + '</tr>';
    var body = roles.map(function (r) {
      var edit = mine && !r.fixed, f = 'role-' + r.key;
      return '<tr><td>' + (edit ? '<input type="text" form="' + esc(f) + '" name="name" value="' + esc(r.name) + '" maxlength="40" aria-label="Role name">' : '<b>' + esc(r.name) + '</b>' + (r.fixed ? '<br><small class="visible">can do everything</small>' : '')) + '</td>' +
        PERM_NAME.map(function (p) { var on = r.perms.indexOf(p[0]) >= 0; return '<td>' + (edit ? '<input type="checkbox" form="' + esc(f) + '" name="' + p[0] + '"' + (on ? ' checked' : '') + ' aria-label="' + esc(r.name) + ': ' + p[1] + '">' : (on ? '✓' : '–')) + '</td>'; }).join('') +
        '<td>' + r.people + '</td>' + (mine ? '<td style="white-space:nowrap">' + (edit ? '<form id="' + esc(f) + '" style="display:inline"><button class="btn">Save</button></form> <button type="button" class="link" data-org="delrole" data-id="' + esc(r.key) + '"' + (r.people ? ' disabled title="Move its people to another role first"' : '') + '>Delete</button>' : '') + '</td>' : '') + '</tr>';
    }).join('');
    return orgHead('Roles', mine ? 'What each role in ' + esc(O.org.name) + ' can do. Tick, rename, or add your own; changes apply right away. Nobody can give a role more than their own role has.'
        : 'What each role in ' + esc(O.org.name) + ' can do. Only the owner changes these.') +
      '<section class="group" data-in><div class="card" style="overflow-x:auto"><table class="rolegrid">' + head + body + '</table></div></section>' +
      (mine ? '<section class="group" data-in><h2>New role</h2><form class="newproj" id="newrole"><input placeholder="Role name, like Project lead" maxlength="40" autocomplete="off" aria-label="New role name"><button class="btn">Add</button></form>' +
        '<p class="visible">It starts with nothing ticked. Tick what it can do above, then move people into it from the Org chart.</p></section>' : '');
  });
};
VIEWS['org-shared'] = function () {
  return orgGate('Shared by me', function () {
    var sh = O.shared || { meetings: [], days: [] };
    return orgHead('Shared by me', 'Everything this account has sent to ' + esc(O.org.name) + '. Unshare anything and it’s deleted from the server.') +
      '<section class="group" data-in><h2>Meeting minutes</h2><div class="card">' + (sh.meetings.map(function (m) {
        return '<div class="shared"><header><b>' + esc(m.title) + '</b><small class="visible">to ' + esc(m.project_name) + ' · ' + day(m.date) + '</small><button type="button" class="link" data-org="unshare" data-proj="' + esc(m.project_id) + '" data-id="' + esc(m.meeting_id) + '">Unshare</button></header></div>';
      }).join('') || '<p class="empty">No minutes shared.</p>') + '</div></section>' +
      '<section class="group" data-in><h2>Day summaries</h2><div class="card">' + (sh.days.map(function (d) {
        return '<div class="shared"><header><b>' + day(d.date) + '</b><small class="visible">seen by roles that can read teammates’ days</small><button type="button" class="link" data-org="unday" data-id="' + esc(d.date) + '">Delete</button></header></div>';
      }).join('') || '<p class="empty">No days sent.</p>') + '</div></section>';
  });
};
VIEWS['org-connection'] = function () {
  return orgGate('Connection', function () {
    return orgHead('Organizations', 'Every organization you’re in, like Slack workspaces. Each has its own people, roles and projects; this computer works in one at a time, and what you send goes only to that one.') +
      group('Your organizations', (O.orgs || []).map(function (o) {
          return row(esc(o.name), esc(o.role_name), o.active ? chip(true, 'This computer') : '<button type="button" class="btn" data-orgpick="' + esc(o.id) + '"' + (O.signing ? ' disabled' : '') + '>Switch</button>');
        }).join('') +
        row('Add an organization', 'Start a new one, or join one with an invite link. You stay in these too.', '<button type="button" class="btn" data-section="org-new">Add…</button>')) +
      group('This computer', row('Organization', esc(O.org.name), O.me.role === 'owner'
          ? '<form class="newproj" id="orgname-form"><input value="' + esc(O.org.name) + '" maxlength="80" autocomplete="off" aria-label="Organization name"><button class="btn">Rename</button></form>' : chip(true)) + row('You', esc(nameOf(O.me)) + (O.me.email ? ' · ' + esc(O.me.email) : ''), chip(true, esc(roleName(O.me.role)))) +
        row('Disconnect this computer', 'Stops sharing from here. You stay in the organization and can connect again.', '<button type="button" class="btn" data-org="disconnect">Disconnect</button>')) +
      (O.me.role === 'owner' ? '' : group('Leave', row('Leave ' + esc(O.org.name), 'You lose access to its projects. Choose whether what you shared stays for the team.',
        '<button type="button" class="btn" data-org="leave">Leave, keep what I shared</button><button type="button" class="btn" data-org="leaveall">Leave and delete it</button>')));
  });
};

// The + beside the organization's name: start one, or join one with an invite link.
VIEWS['org-new'] = function () {
  return orgGate('Add an organization', function () {
    return orgHead('Add an organization', 'Like adding a Slack workspace: it sits beside ' + esc(O.org.name) + ' with its own people, roles and projects, and this computer switches to it. Switch back from the name at the top of the sidebar.') +
      group('Start a new one', row('Organization name', 'You’ll be its owner. Invite your team after.',
        '<form class="newproj" id="orgnew"><input placeholder="Company name" maxlength="80" autocomplete="off" aria-label="Company name" autofocus><button class="btn primary"' + (O.signing ? ' disabled' : '') + '>Start</button></form>')) +
      group('Join one', row('Invite link', 'Paste the link its admin sent you.',
        '<form class="newproj" id="orgjoin"><input placeholder="Invite link" autocomplete="off" aria-label="Invite link"><button class="btn"' + (O.signing ? ' disabled' : '') + '>Join</button></form>'));
  });
};

function orgClick(t) {
  var a = t.dataset.org, id = t.dataset.id;
  if (a === 'signin') {
    O.signing = true; O.note = 'Sign in with your work Google account in the browser window that opened.'; orgRedraw();
    return chatAsk('orgSignIn').then(function (r) { O.signing = false; O.loaded = false; O.note = r && r.error ? r.error : ''; orgRedraw(); });
  }
  if (a === 'owner') { var w = member(id); if (!confirm('Make ' + nameOf(w) + ' the owner of ' + O.org.name + '? You become a co-founder, and only they can undo this.')) return; O.sel = null;
    return orgCall('POST', '/api/org/owner', { user_id: id }).then(function (r) { O.note = ok(r) ? nameOf(w) + ' is now the owner.' : orgErr(r); O.loaded = false; orgRedraw(); }); }
  if (a === 'erpread') { O.erp = { busy: true }; orgRedraw(); return chatAsk('erpMyProjects').then(function (r) { O.erp = r || { error: 'No answer from the ERP.' }; orgRedraw(); }); }
  if (a === 'delrole') { if (!confirm('Delete the ' + roleName(id) + ' role?')) return; return orgDo(orgCall('DELETE', '/api/roles/' + encodeURIComponent(id)), 'Deleted ' + roleName(id) + '.'); }
  if (a === 'erpclose') { O.erp = null; return orgRedraw(); }
  if (a === 'erpsend') {
    var names = [].slice.call(document.querySelectorAll('input[data-erp]:checked')).map(function (x) { return x.value; });
    if (!names.length) { O.erp = null; return orgRedraw(); }
    O.note = 'Saving…'; orgRedraw();
    return orgCall('POST', '/api/projects/import', { names: names }).then(function (r) {
      var d = ok(r) ? r.data : null;
      O.note = !d ? orgErr(r) : ['Added ' + (d.added.length + d.joined.length) + ' project' + (d.added.length + d.joined.length === 1 ? '' : 's') + '.']
        .concat(d.ask.length ? ['Already in ' + O.org.name + ', ask someone on it to add you: ' + d.ask.join(', ') + '.'] : []).join(' ');
      O.erp = null; return orgFetch();
    }).then(orgRedraw);
  }
  if (a === 'reload') { O.loaded = false; O.error = ''; O.note = ''; return orgRedraw(); }
  if (a === 'person') { O.sel = O.sel === id ? null : id; return orgRedraw(); }
  if (a === 'unsel') { O.sel = null; return orgRedraw(); }
  if (a === 'role') { var m = member(id); if (m.role === t.dataset.role) return; return orgDo(orgCall('PATCH', '/api/members/' + encodeURIComponent(id), { role: t.dataset.role }), nameOf(m) + ' is now ' + aRole(t.dataset.role) + '.'); }
  if (a === 'remove') { var r = member(id); if (!confirm('Remove ' + nameOf(r) + ' from ' + O.org.name + '? They lose access to every project at once.')) return; O.sel = null; return orgDo(orgCall('DELETE', '/api/members/' + encodeURIComponent(id)), nameOf(r) + ' was removed.'); }
  if (a === 'team') return orgDo(orgCall('PUT', '/api/projects/' + encodeURIComponent(t.dataset.team) + '/members/' + encodeURIComponent(id)), nameOf(member(id)) + ' added to ' + proj(t.dataset.team).name + '.');
  if (a === 'unteam') return orgDo(orgCall('DELETE', '/api/projects/' + encodeURIComponent(t.dataset.team) + '/members/' + encodeURIComponent(id)), 'Taken off ' + proj(t.dataset.team).name + '.');
  if (a === 'invite') return orgCall('POST', '/api/invites', { role: t.dataset.role }).then(function (r) { O.note = ok(r) ? '' : orgErr(r); O.invite = ok(r) ? { role: t.dataset.role, token: r.data.token, url: r.data.url } : null; orgRedraw(); });
  if (a === 'copyinvite') { post({ type: 'copyText', text: O.invite.url || O.invite.token }); O.note = 'Invite link copied.'; return orgRedraw(); }
  if (a === 'closeinvite') { O.invite = null; return orgRedraw(); }
  if (a === 'openproj') { if (current !== 'org-projects') { current = 'org-projects'; post({ type: 'section', id: current }); }
    O.open = { project: proj(id) || { id: id, name: '', members: [] }, days: [] }; O.note = 'Loading…'; orgRedraw();
    return orgCall('GET', '/api/projects/' + encodeURIComponent(id)).then(function (r) { O.note = ok(r) ? '' : orgErr(r); O.open = ok(r) ? r.data : null; orgRedraw(); }); }
  if (a === 'closeproj') { O.open = null; return orgRedraw(); }
  if (a === 'unshare') { if (!confirm('Unshare this? It’s deleted from the server for everyone on the project.')) return; return orgDo(orgCall('DELETE', '/api/projects/' + encodeURIComponent(t.dataset.proj) + '/meetings/' + encodeURIComponent(id)), 'Unshared.'); }
  if (a === 'unday') { if (!confirm('Delete your day summary for ' + day(id) + ' from the server?')) return; return orgDo(orgCall('DELETE', '/api/summaries/mine/' + id), 'Deleted.'); }
  if (a === 'disconnect') { if (!confirm('Disconnect this computer from ' + O.org.name + '? Nothing more is shared from here until you connect again.')) return; O.loaded = false; return post({ type: 'orgDisconnect' }); }
  if (a === 'leave' || a === 'leaveall') {
    var all = a === 'leaveall';
    if (!confirm('Leave ' + O.org.name + (all ? ' and delete everything you shared to it?' : '? What you shared stays for the team.'))) return;
    return orgCall('POST', '/api/org/leave', { delete_shared: all }).then(function (r) {
      if (!ok(r)) { O.note = orgErr(r); return orgRedraw(); }
      if (r.data && r.data.moved) return orgSwitched({}); // still in another org: this computer moved there
      O.loaded = false; post({ type: 'orgDisconnect' });
    });
  }
}
// This computer is now in another organization: everything is read again from there.
function orgSwitched(r) {
  O.signing = false; O.note = r && r.error ? r.error : '';
  if (!O.note) { O.loaded = false; O.open = null; O.sel = null; O.invite = null; O.erp = null; O.orgs = null; O.orgsAsked = false; }
  if (!O.note && current !== 'org-home') return goTo('org-home');
  orgRedraw();
}
function orgSubmit(form) {
  var v = form.querySelector('input') && form.querySelector('input').value.trim();
  if (form.id === 'orgnew' || form.id === 'orgjoin') {
    if (!v || O.signing) return true;
    var extra = form.id === 'orgnew' ? { orgName: v } : { invite: (v.match(/join=([0-9a-f]+)/) || [])[1] || v };
    if (S.status.dashboard) { O.signing = true; O.note = 'Switching…'; orgRedraw(); chatAsk('orgSwitch', '', extra).then(orgSwitched); return true; } // already connected: no new sign-in
    O.signing = true; O.note = 'Sign in with your work Google account in the browser window that opened.'; orgRedraw();
    chatAsk('orgSignIn', '', extra).then(function (r) { O.signing = false; O.loaded = false; O.note = r && r.error ? r.error : ''; orgRedraw(); });
    return true;
  }
  if (form.id === 'newrole') {
    if (v) orgDo(orgCall('POST', '/api/roles', { name: v, perms: [] }), 'Added ' + v + '. Tick what it can do.');
    return true;
  }
  if (form.id.indexOf('role-') === 0) {
    var key = form.id.slice(5), name = '', perms = [];
    [].forEach.call(document.querySelectorAll('[form="' + form.id + '"]'), function (e) { if (e.name === 'name') name = e.value.trim(); else if (e.checked) perms.push(e.name); });
    orgDo(orgCall('PATCH', '/api/roles/' + encodeURIComponent(key), { name: name, perms: perms }), 'Saved ' + (name || 'the role') + '.');
    return true;
  }
  if (form.id === 'orgname-form') {
    if (v && v !== O.org.name) orgCall('PATCH', '/api/org', { name: v }).then(function (r) { O.note = ok(r) ? 'Renamed.' : orgErr(r); O.loaded = false; orgRedraw(); });
    return true;
  }
  if (form.id !== 'newproj') return false;
  var name = v;
  if (!name) return true;
  O.newProj = '';
  orgDo(orgCall('POST', '/api/projects', { name: name }), 'Created ' + name + '. You’re on it; drag people onto it to add them.');
  return true;
}

// Drag a person onto a level (their role) or a project (add them). Only places
// the rules allow light up; the same choices are in each person's panel for
// anyone not using a mouse.
function dropZone(el) { return el && el.closest ? (el.closest('.tier[data-tier]') || el.closest('.team[data-team]')) : null; }
function allowed(z) {
  var p = member(dragId);
  if (!p || !z) return false;
  if (z.dataset.tier) return canMove(p, z.dataset.tier);
  var pr = proj(z.dataset.team);
  return !!pr && canEditTeam(pr) && !onTeam(pr, p.user_id);
}
function clearDrops() { document.querySelectorAll('.over,.can-drop').forEach(function (x) { x.classList.remove('over', 'can-drop'); }); }
document.addEventListener('dragstart', function (e) {
  var c = e.target.closest && e.target.closest('.pcard[data-id]');
  if (!c || !inOrg()) return;
  dragId = c.dataset.id;
  e.dataTransfer.setData('text/plain', dragId); e.dataTransfer.effectAllowed = 'move';
  document.body.classList.add('dragging');
  document.querySelectorAll('.tier[data-tier],.team[data-team]').forEach(function (z) { if (allowed(z)) z.classList.add('can-drop'); });
});
document.addEventListener('dragend', function () { dragId = null; document.body.classList.remove('dragging'); clearDrops(); });
document.addEventListener('dragover', function (e) {
  if (!dragId) return;
  var z = dropZone(e.target);
  document.querySelectorAll('.over').forEach(function (x) { if (x !== z) x.classList.remove('over'); });
  if (z && allowed(z)) { e.preventDefault(); e.dataTransfer.dropEffect = 'move'; z.classList.add('over'); }
});
document.addEventListener('drop', function (e) {
  var z = dropZone(e.target), p = member(dragId);
  if (!dragId || !allowed(z)) return;
  e.preventDefault(); clearDrops();
  if (z.dataset.tier) orgDo(orgCall('PATCH', '/api/members/' + encodeURIComponent(p.user_id), { role: z.dataset.tier }), nameOf(p) + ' is now ' + aRole(z.dataset.tier) + '.');
  else orgDo(orgCall('PUT', '/api/projects/' + encodeURIComponent(z.dataset.team) + '/members/' + encodeURIComponent(p.user_id)), nameOf(p) + ' added to ' + proj(z.dataset.team).name + '.');
});

// --- drawing ---------------------------------------------------------------------
// Two sidebars: yours, and the organization's, which replaces it while you're in there.
var navMode = null, orgMenu = null; // orgMenu: the org dropdown is open (null: its default, open outside, closed inside)
function drawNav() {
  var org = inOrg(), orgs = orgList();
  var open = orgMenu == null ? !org : orgMenu;
  var key = [org, open, JSON.stringify(orgs)].join('|');
  if (navMode === key) return;
  navMode = key;
  document.body.classList.toggle('org', org);
  var here = orgs.filter(function (o) { return o.active; })[0];
  nav.innerHTML = org
    ? '<button type="button" class="back" data-section="home" title="Back to my Nikxel">' + icon('back') + '<span class="lbl">Back to my Nikxel</span></button>' +
      (here ? '<div class="ws"><button type="button" class="ws-cur" data-orgmenu aria-expanded="' + open + '" title="Switch organization">' + avatar(here) + '<span class="lbl">' + esc(here.name) + '</span>' + '<span class="chev">' + icon('chev') + '</span>' + '</button>' +
          '<button type="button" class="ws-add" data-section="org-new" title="Add an organization" aria-label="Add an organization">' + icon('plus') + '</button></div>' +
          (open ? orgMenuHTML(orgs) : '')
        : '<div class="label">Organization</div>') +
      ORG_SECTIONS.map(function (x) { return '<button type="button" data-section="' + x[0] + '" title="' + x[1] + '">' + icon(x[2]) + '<span class="lbl">' + x[1] + '</span></button>'; }).join('')
    : SECTIONS.map(function (x) {
        return x ? '<button type="button" data-section="' + x[0] + '" title="' + x[1] + '">' + icon(x[0]) + '<span class="lbl">' + x[1] + '</span></button>' : '<div class="label">Settings</div>';
      }).join('') + '<div class="label">Shared</div>' + (orgs.length // data-section is for the tour's pointer; data-orgmenu wins on click
        ? '<button type="button" class="org-entry" data-orgmenu data-section="org-home" aria-expanded="' + open + '" title="Organizations">' + icon('org') + '<span class="lbl">Organizations</span>' + '<span class="chev">' + icon('chev') + '</span>' + '</button>' + (open ? orgMenuHTML(orgs) : '')
        : '<button type="button" class="org-entry" data-section="org-home" title="Organization">' + icon('org') + '<span class="lbl">Organization</span></button>');
}
// The orgs this account is in (read once per connection, again after a switch); [] when not connected.
function orgList() {
  if (!S || !S.status.dashboard) { O.orgs = null; O.orgsAsked = false; return []; }
  if (!O.orgs && !O.orgsAsked) {
    O.orgsAsked = true;
    orgCall('GET', '/api/me/orgs').then(function (r) { O.orgs = ok(r) ? r.data : []; markNav(); });
  }
  return O.orgs || [];
}
function avatar(o) { return '<span class="av" aria-hidden="true">' + esc((o.name.trim()[0] || '?').toUpperCase()) + '</span>'; }
function orgMenuHTML(orgs) {
  return '<div class="orgmenu">' + orgs.map(function (o) {
      return '<button type="button" class="orgpick" data-orgpick="' + esc(o.id) + '" title="' + esc(o.name) + '"' + (o.active ? ' aria-current="true"' : '') + '>' + avatar(o) +
        '<span class="lbl">' + esc(o.name) + '<small>' + esc(o.role_name) + '</small></span>' + (o.active ? '<span class="on" aria-label="This computer"></span>' : '') + '</button>';
    }).join('') +
    '<button type="button" class="orgpick" data-section="org-new" title="Add an organization">' + icon('plus') + '<span class="lbl">Add an organization</span></button></div>';
}
// Into one of your organizations, Slack-style: the active one opens; another is switched to first.
function orgPick(id) {
  var o = (O.orgs || []).filter(function (x) { return x.id === id; })[0];
  if (inOrg()) orgMenu = false;
  var open = function () { navMode = null; if (current === 'org-home') { orgRedraw(); markNav(); } else goTo('org-home'); };
  if (!o || o.active) return open();
  O.signing = true;
  return chatAsk('orgSwitch', '', { org: id }).then(function (r) {
    O.signing = false;
    if (r && r.error) { O.note = r.error; return open(); }
    O.orgs.forEach(function (x) { x.active = x.id === id; });
    O.note = ''; O.loaded = false; O.loading = false; O.open = null; O.sel = null; O.invite = null; O.erp = null;
    open();
  });
}
function markNav() {
  drawNav();
  var at = S && S.active ? null : current;
  nav.querySelectorAll('button').forEach(function (b) {
    if (b.dataset.section === at) b.setAttribute('aria-current', 'page'); else b.removeAttribute('aria-current');
  });
  markNew();
}
function render() {
  main.classList.toggle('reading', !!S.active && !inOrg());
  main.classList.toggle('orgwide', current === 'org-chart');
  main.classList.toggle('chatting', !S.active && current === 'chat');
  drawTabs(S);
  if (inOrg()) return VIEWS[current](S);   // the org side never shows your tabs or files
  return S.active ? '' : VIEWS[current](S);
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
  // Updates with nothing to tour are seen once they've been read here.
  if (section === 'whatsnew' && S && (S.whatsNewUnseen || []).length && !featureSteps(S.whatsNewUnseen).length) seenWhatsNew();
  if (old && animateIn && !reduce && !S.active) {
    // Pinned where it sat: taken out of the flow, it would otherwise jump to the column's padding edge.
    old.style.top = old.offsetTop + 'px'; old.style.left = old.offsetLeft + 'px'; old.style.width = old.offsetWidth + 'px';
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

// --- dialogs: summary templates, and plain text files --------------------------------
// Both open over the window, never in another app. The template dialog keeps
// its own draft (T) and reloads it only when the app says the file changed
// (rev): opened, created or reset. Every other state push leaves it alone.
var T = null, E = null, dlgEl = null;
var X_ICON = '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M4 4l8 8M12 4l-8 8" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/></svg>';
// The built-in structure, in order. Summary is always written.
var TPL_SECTIONS = ['Speakers', 'Per-Speaker Highlights', 'Decisions', 'Blockers & Risks', 'Open Questions', 'Action Items', 'Follow-Up Meetings', 'Agent Prompts'];
var TPL_LENGTH = {
  short: 'Keep it short: the summary in three sentences at most, and one line per point everywhere else.',
  long: 'Go into detail: a full paragraph for the summary, and the reasoning and numbers behind each point.'
};
var TPL_TONE = {
  plain: 'Write in plain, everyday words. No jargon.',
  formal: 'Keep the tone formal, ready to send to a client.',
  friendly: 'Keep the tone warm and friendly.'
};
var TPL_IDEAS = [
  'Put the Action Items right after the Summary.',
  'Write owners as first names only.',
  'Give every action item a due date, or say it has none.',
  'Quote decisions in the words they were made in.',
  'Leave out small talk and anything off-topic.',
  'End with a one-line next step for each person.'
];

// A template file → what the simple editor shows. The # notes at the top stay
// as they are; recognised instructions become controls; the rest is "Anything else".
function tplParse(text) {
  var lines = String(text || '').replace(/\r/g, '').split('\n'), head = [];
  while (lines.length && (/^\s*#/.test(lines[0]) || !lines[0].trim())) head.push(lines.shift());
  var m = { head: head.join('\n').replace(/\s+$/, ''), drop: [], length: '', tone: '', add: [], own: [] };
  lines.join('\n').split(/\n\s*\n/).forEach(function (p) {
    p = p.trim();
    if (!p) return;
    var d = /^Drop the (.+?) section(?: entirely)?\.$/.exec(p), a = /^Add a "## ([^"\n]+)" section(?:: ([^\n]+?))?\.$/.exec(p);
    var sec = d && TPL_SECTIONS.filter(function (x) { return x.toLowerCase() === d[1].toLowerCase(); })[0];
    if (sec) { if (m.drop.indexOf(sec) < 0) m.drop.push(sec); return; }
    for (var k in TPL_LENGTH) if (TPL_LENGTH[k] === p) { m.length = k; return; }
    for (k in TPL_TONE) if (TPL_TONE[k] === p) { m.tone = k; return; }
    if (a) { m.add.push({ name: a[1], what: a[2] || '' }); return; }
    m.own.push(p);
  });
  m.own = m.own.join('\n\n');
  return m;
}
function tplCompose(m) {
  var parts = [];
  if (m.own.trim()) parts.push(m.own.trim());
  TPL_SECTIONS.forEach(function (x) { if (m.drop.indexOf(x) >= 0) parts.push('Drop the ' + x + ' section.'); });
  if (m.length) parts.push(TPL_LENGTH[m.length]);
  if (m.tone) parts.push(TPL_TONE[m.tone]);
  m.add.forEach(function (a) { parts.push('Add a "## ' + a.name + '" section' + (a.what ? ': ' + a.what.replace(/[.\s]+$/, '') : '') + '.'); });
  return (m.head ? m.head + '\n\n' : '') + parts.join('\n\n') + '\n';
}
function tplEdit(f) { var m = tplParse(T.draft); f(m); T.draft = tplCompose(m); }
function tplDirty() { return T && !T.creating && T.draft !== T.orig; }

function tplListHTML() {
  return S.templates.map(function (t) {
    return '<button type="button" data-tpl="open" data-slug="' + esc(t.id) + '"' + (T && !T.creating && t.id === T.slug ? ' aria-current="true"' : '') + '>' + esc(t.name) +
      (t.id === S.summaryTemplate ? '<small>In use</small>' : '') + '</button>';
  }).join('') + '<button type="button" class="tpl-add" data-tpl="new">+ New template</button>';
}
function tplNewHTML() {
  var from = [['', 'Blank']].concat(pairs(S.templates));
  return '<div class="tpl-new"><div class="tpl-top"><div><h3>New template</h3><p>Name it after the kind of meeting: Client calls, Design review, Board.</p></div></div>' +
    '<input class="text" id="tplname" placeholder="Template name" autocomplete="off" value="' + esc(T.newName || '') + '">' +
    (T.error ? '<p class="tpl-err" role="alert">' + esc(T.error) + '</p>' : '') +
    '<div class="tpl-block"><b>Start from</b><small>Copy one you already have, then change what’s different.</small><div class="choices" role="radiogroup">' +
    from.map(function (o) {
      return '<button type="button" class="choice" role="radio" data-tplcopy="' + esc(o[0]) + '" aria-checked="' + ((T.copy || '') === o[0]) + '"><span class="radio"></span>' + esc(o[1]) + '</button>';
    }).join('') + '</div></div></div>';
}
function tplSimpleHTML(m) {
  function segs(kind, opts, v) {
    return '<div class="seg" role="radiogroup">' + opts.map(function (o) {
      return '<button type="button" role="radio" data-tpl' + kind + '="' + o[0] + '" aria-checked="' + (v === o[0]) + '">' + o[1] + '</button>';
    }).join('') + '</div>';
  }
  var own = m.own;
  return '<div class="tpl-block"><b>Sections</b><small>Untick what you don’t need. The summary at the top is always there.</small><div class="togs">' +
    '<span class="tog fixed" aria-pressed="true">Summary</span>' +
    TPL_SECTIONS.map(function (x) { return '<button type="button" class="tog" data-tplsec="' + esc(x) + '" aria-pressed="' + (m.drop.indexOf(x) < 0) + '">' + esc(x) + '</button>'; }).join('') + '</div></div>' +
    '<div class="tpl-block"><b>Length</b>' + segs('len', [['', 'As it is'], ['short', 'Shorter'], ['long', 'More detail']], m.length) + '</div>' +
    '<div class="tpl-block"><b>Tone</b>' + segs('tone', [['', 'As it is'], ['plain', 'Plain'], ['formal', 'Formal'], ['friendly', 'Friendly']], m.tone) + '</div>' +
    '<div class="tpl-block"><b>Sections of your own</b><small>A heading, and what goes under it.</small>' +
    (m.add.length ? '<div class="adds">' + m.add.map(function (a, i) {
      return '<div class="add"><div><b>' + esc(a.name) + '</b>' + (a.what ? '<span>' + esc(a.what) + '</span>' : '') + '</div><button type="button" class="dlg-x" data-tpldel="' + i + '" aria-label="Remove ' + esc(a.name) + '">' + X_ICON + '</button></div>';
    }).join('') + '</div>' : '') +
    '<div class="addform"><input class="text" id="tpladdname" placeholder="Heading, like Budget" autocomplete="off"><input class="text" id="tpladdwhat" placeholder="What goes in it, like every cost mentioned" autocomplete="off"><button type="button" class="btn" data-tpl="add">Add</button></div></div>' +
    '<div class="tpl-block"><b>Anything else</b><small>Plain instructions, the way you’d tell a person.</small>' +
    '<textarea id="tplown" placeholder="Write owners as first names only.">' + esc(own) + '</textarea>' +
    '<div class="ideas-row">' + TPL_IDEAS.filter(function (x) { return own.indexOf(x) < 0; }).map(function (x) {
      return '<button type="button" class="idea" data-tplidea="' + esc(x) + '">+ ' + esc(x) + '</button>';
    }).join('') + '</div></div>';
}
function tplMainHTML() {
  if (T.creating) return tplNewHTML();
  var name = (S.templates.filter(function (t) { return t.id === T.slug; })[0] || {}).name || T.name;
  var inUse = S.summaryTemplate === T.slug;
  return '<div class="tpl-top"><div><h3>' + esc(name) + '</h3><p>' + (inUse ? 'Your meeting summaries use this template.' : 'Not in use. Save and use it, or keep it for later.') + '</p></div>' +
    '<div class="seg" role="radiogroup" aria-label="How to edit"><button type="button" role="radio" data-tplmode="simple" aria-checked="' + (T.mode === 'simple') + '">Choose</button>' +
    '<button type="button" role="radio" data-tplmode="write" aria-checked="' + (T.mode === 'write') + '">Write it</button></div></div>' +
    (T.mode === 'write'
      ? '<div class="tpl-block"><small>The whole template in your own words, one instruction per line. Lines starting with # are notes to you; I skip them.</small><textarea class="file" id="tplraw" spellcheck="false">' + esc(T.draft) + '</textarea></div>'
      : tplSimpleHTML(tplParse(T.draft))) +
    '<p class="tpl-block" style="margin-top:20px"><small>Takes effect from your next recording. Names, decisions and numbers still come only from what was said.</small></p>';
}
function tplFootHTML() {
  if (T.confirm) {
    return '<span class="grow warn">' + esc(T.confirm.text) + '</span>' +
      '<button type="button" class="btn" data-tpl="no">' + esc(T.confirm.no || 'Cancel') + '</button><button type="button" class="btn primary" data-tpl="yes">' + esc(T.confirm.yes) + '</button>';
  }
  if (T.creating) {
    return '<span class="grow"></span><button type="button" class="btn" data-tpl="back">Cancel</button><button type="button" class="btn primary" data-tpl="create">Create template</button>';
  }
  var inUse = S.summaryTemplate === T.slug;
  return '<span class="grow">' + (T.shipped ? '<button type="button" class="link" data-tpl="reset">Reset to built-in</button>' : '<button type="button" class="link" data-tpl="delete">Delete template</button>') + '</span>' +
    '<button type="button" class="btn" data-tpl="cancel">Cancel</button>' +
    (inUse ? '' : '<button type="button" class="btn" data-tpl="saveuse">Save and use</button>') +
    '<button type="button" class="btn primary" data-tpl="save">Save</button>';
}

function dlgOpen(html, small) {
  var fresh = !dlgEl;
  if (fresh) {
    dlgEl = document.createElement('div');
    document.body.appendChild(dlgEl);
  }
  var keep = dlgEl.querySelector('.tpl-main'), top = keep ? keep.scrollTop : 0;
  dlgEl.innerHTML = '<div class="dlg-scrim"' + (fresh ? '' : ' style="animation:none"') + '></div><div class="dlg-wrap"><div class="dlg' + (small ? ' small' : '') + '" role="dialog" aria-modal="true" aria-labelledby="dlg-t"' + (fresh ? '' : ' style="animation:none"') + '>' + html + '</div></div>';
  var main2 = dlgEl.querySelector('.tpl-main'); if (main2) main2.scrollTop = top;
  return fresh;
}
function dlgClose() { if (dlgEl) { dlgEl.remove(); dlgEl = null; } }
function drawTemplate(focus) {
  var fresh = dlgOpen('<header class="dlg-head"><div><h2 id="dlg-t">Summary templates</h2><p>How your meeting minutes are written.</p></div><button type="button" class="dlg-x" data-tpl="cancel" aria-label="Close">' + X_ICON + '</button></header>' +
    '<div class="tpl"><nav class="tpl-list" aria-label="Templates">' + tplListHTML() + '</nav><section class="tpl-main">' + tplMainHTML() + '</section></div>' +
    '<footer class="dlg-foot">' + tplFootHTML() + '</footer>');
  var f = focus && dlgEl.querySelector(focus);
  if (f) f.focus();
  else if (fresh) { var c = dlgEl.querySelector('#tplname') || dlgEl.querySelector('[aria-current]'); if (c) c.focus(); }
}
function drawFileEditor() {
  var fresh = dlgOpen('<header class="dlg-head"><div><h2 id="dlg-t">' + esc(E.title) + '</h2><p>' + esc(E.help) + '</p></div><button type="button" class="dlg-x" data-act="closeFile" aria-label="Close">' + X_ICON + '</button></header>' +
    '<div class="dlg-body"><textarea class="file" id="filetext" spellcheck="false">' + esc(E.text) + '</textarea></div>' +
    '<footer class="dlg-foot"><span class="grow">⌘S saves.</span><button type="button" class="btn" data-act="closeFile">Cancel</button><button type="button" class="btn primary" data-savefile>Save</button></footer>', true);
  if (fresh) document.getElementById('filetext').focus();
}
// Called on every state push.
function syncDialogs() {
  var te = S.templateEditor;
  if (te) {
    E = null;
    if (!T || T.rev !== te.rev) {
      T = { slug: te.slug, name: te.name, shipped: te.shipped, rev: te.rev, draft: te.text, orig: te.text, mode: T ? T.mode : 'simple', creating: te.creating, error: '', back: !te.creating };
      return drawTemplate();
    }
    if (te.error !== T.error) { T.error = te.error; return drawTemplate('#tplname'); }
    var list = dlgEl && dlgEl.querySelector('.tpl-list');
    if (list) list.innerHTML = tplListHTML();   // "In use" may have moved; the draft stays as it is
    return;
  }
  if (T) { T = null; dlgClose(); }
  if (S.editor && !E) { E = S.editor; return drawFileEditor(); }
  if (!S.editor && E) { E = null; dlgClose(); }
}
function tplAsk(text, yes, then) { T.confirm = { text: text, yes: yes, then: then }; drawTemplate(); }
function tplLeave(then) {
  if (tplDirty()) return tplAsk('Your changes to “' + T.name + '” aren’t saved.', 'Discard changes', then);
  then();
}
function tplSave(use) { post({ type: 'template', op: 'save', slug: T.slug, text: T.draft, use: !!use }); }
function tplAddSection() {
  var n = document.getElementById('tpladdname'), w = document.getElementById('tpladdwhat');
  var name = n.value.replace(/["#\n]/g, '').trim();
  if (!name) { n.focus(); return; }
  tplEdit(function (m) { m.add.push({ name: name, what: w.value.replace(/\n/g, ' ').trim() }); });
  drawTemplate('#tpladdname');
}
function tplClick(t) {
  var op = t.dataset.tpl;
  if (t.dataset.tplmode) { T.mode = t.dataset.tplmode; return drawTemplate(); }
  if (t.dataset.tplsec) {
    var x = t.dataset.tplsec;
    tplEdit(function (m) { var i = m.drop.indexOf(x); if (i >= 0) m.drop.splice(i, 1); else m.drop.push(x); });
    return drawTemplate();
  }
  if (t.hasAttribute('data-tpllen')) { tplEdit(function (m) { m.length = t.dataset.tpllen; }); return drawTemplate(); }
  if (t.hasAttribute('data-tpltone')) { tplEdit(function (m) { m.tone = t.dataset.tpltone; }); return drawTemplate(); }
  if (t.dataset.tpldel) { tplEdit(function (m) { m.add.splice(+t.dataset.tpldel, 1); }); return drawTemplate(); }
  if (t.dataset.tplidea) {
    var idea = t.dataset.tplidea;
    tplEdit(function (m) { m.own = (m.own.trim() ? m.own.trim() + '\n\n' : '') + idea; });
    return drawTemplate();
  }
  if (t.hasAttribute('data-tplcopy')) { T.copy = t.dataset.tplcopy; return drawTemplate(); }
  switch (op) {
    case 'open':
      if (!T.creating && t.dataset.slug === T.slug) return;
      return tplLeave(function () { post({ type: 'template', op: 'open', slug: t.dataset.slug }); });
    case 'new':
      return tplLeave(function () { T.creating = true; T.confirm = null; T.error = ''; T.newName = ''; T.copy = ''; drawTemplate('#tplname'); });
    case 'back':
      if (!T.back) return post({ type: 'template', op: 'close' });
      T.creating = false; T.error = ''; return drawTemplate();
    case 'create':
      T.newName = document.getElementById('tplname').value;
      return post({ type: 'template', op: 'new', name: T.newName, copy: T.copy || '' });
    case 'add': return tplAddSection();
    case 'save': return tplSave(false);
    case 'saveuse': return tplSave(true);
    case 'cancel': return tplLeave(function () { post({ type: 'template', op: 'close' }); });
    case 'reset':
      return tplAsk('Put back the built-in “' + T.name + '”? What you wrote in it goes.', 'Reset', function () { post({ type: 'template', op: 'reset', slug: T.slug }); });
    case 'delete':
      return tplAsk('Delete “' + T.name + '”? Summaries using it go back to Default.', 'Delete', function () { post({ type: 'template', op: 'delete', slug: T.slug }); });
    case 'yes': var then = T.confirm.then; T.confirm = null; drawTemplate(); return then();
    case 'no': T.confirm = null; return drawTemplate();
  }
}
document.addEventListener('input', function (e) {
  if (!T) return;
  if (e.target.id === 'tplown') { var v = e.target.value; tplEdit(function (m) { m.own = v; }); }
  else if (e.target.id === 'tplraw') T.draft = e.target.value;
});

window.nx = {
  state: function (s) {
    var was = S;
    S = s;
    drawFoot(s);
    if (!was) {
      document.body.classList.toggle('folded', !!s.sideCollapsed);
      if (s.tour) setTimeout(function () { if (!S.active && !S.editor && !T) startTour(); }, reduce ? 200 : 1400);
      maybeFeatureTour();
      show(s.section || 'home', !reduce);
      return syncDialogs();
    }
    if (s.tour && !was.tour) startTour();   // replayed from Advanced
    if (!s.tour && was.tour) maybeFeatureTour();
    document.body.classList.toggle('folded', !!s.sideCollapsed);
    syncDialogs();
    if (was.active !== s.active) return show(current, !s.active);
    patch();
  },
  frames: function (r) { rows = r || []; paintSprites(); },
  go: function (section) { if (S) goTo(section); },
  tourResume: function (skip) { if (!tourEls) return; if (skip || tourAt >= tourSteps.length - 1) return endTour(); tourAt++; showTourStep(); },
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
  // Into the organization: read it fresh each time, it's never kept.
  if (section.indexOf('org-') === 0 && !inOrg()) { O.loaded = false; O.loading = false; O.sel = null; O.open = null; O.invite = null; O.note = ''; }
  if (S && S.active) { current = section; post({ type: 'action', name: 'closeSummary' }); return; }   // the state push redraws
  show(section, true);
}
document.addEventListener('click', function (e) {
  var tb = e.target.closest('[data-tour]');
  if (tb) {
    if (tb.dataset.tour === 'next' && tourAt < tourSteps.length - 1) { tourAt++; showTourStep(); } else endTour();
    return;
  }
  var x = e.target.closest('[data-closetab]');
  if (x) { e.stopPropagation(); post({ type: 'closeTab', id: x.dataset.closetab }); return; }
  var t = e.target.closest('button');
  if (!t || t.disabled) return;
  if (T && t.closest('.dlg')) { tplClick(t); return; }
  if (t.dataset.erp) { erpClick(t); return; }
  if (t.dataset.org) { orgClick(t); return; }
  if (t.hasAttribute('data-orgmenu')) {
    orgMenu = t.getAttribute('aria-expanded') !== 'true'; markNav();
    var menu = nav.querySelector('.orgmenu'); if (menu) menu.scrollIntoView({ block: 'nearest', behavior: reduce ? 'auto' : 'smooth' }); // it opens at the bottom of a short window
    return;
  }
  if (t.dataset.orgpick) { orgPick(t.dataset.orgpick); return; }
  if (t.dataset.wn) { var steps = featureSteps([t.dataset.wn]); if (steps.length) startTour(steps, seenWhatsNew); return; }
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
  if (t.dataset.chat === 'attach') { chatAsk('attachPick').then(function (r) { attachResults(chatFiles, r, drawAtts); }); return; }
  if (t.dataset.unattach) {
    var u = t.dataset.unattach.split(':'), list = u[0] === 'chat' ? chatFiles : (draft && draft.files) || [];
    list.splice(+u[1], 1); if (u[0] === 'chat') drawAtts(); else redrawAutomations(); return;
  }
  if (t.hasAttribute('data-draftattach')) { draft.files = draft.files || []; chatAsk('attachPick').then(function (r) { attachResults(draft.files, r, redrawAutomations); }); return; }
  if (t.dataset.autopick) { pickFor = pickFor === t.dataset.autopick ? null : t.dataset.autopick; redrawAutomations(); return; }
  if (t.dataset.copyrun) { post({ type: 'copyText', text: S.automationRuns[+t.dataset.copyrun].text }); t.textContent = 'Copied'; return; }
  if (t.dataset.chat === 'send') return;   // the form's submit sends
  if (t.dataset.act === 'chatNew') {
    chatLog = []; chatDraft = ''; chatFiles = []; chatSources = null; chatBusy = chatListening = false; chatPending = {};
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
    var once = draft.trigger === 'schedule' && draft.days === 'once';
    if ((draft.files || []).some(function (f) { return f.reading; })) return;
    post({ type: 'autoSave', a: Object.assign({}, draft, { days: once ? 'daily' : draft.days, date: once ? draft.date : null, files: (draft.files || []).map(function (f) { return f.id; }) }) }); draft = null; redrawAutomations(); return;
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
  if (orgSubmit(e.target)) { e.preventDefault(); return; }
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
  if (!text && chatFiles.some(function (f) { return f.id; })) text = 'Read what I attached and tell me in a line what it is.';
  if (!text || chatBusy || chatListening || chatFiles.some(function (f) { return f.reading; })) return;
  ci.value = chatDraft = '';
  chatRun(text);
});
document.addEventListener('input', function (e) {
  if (e.target.dataset && e.target.dataset.draft && draft) { draft[e.target.dataset.draft] = e.target.value; return; }
  if (e.target.id === 'mk') { makeText = e.target.value; return; }
  if (e.target.id === 'np') { O.newProj = e.target.value; return; }
  if (e.target.id === 'ci') { chatDraft = e.target.value; syncChat(); return; }
  if (e.target.id !== 'q') return;
  libQuery = e.target.value;
  document.getElementById('list').innerHTML = libraryList(S);
  searchSoon();
});
document.addEventListener('change', function (e) {
  var t = e.target;
  if (t.dataset && t.dataset.autorunon && t.value) { post({ type: 'autoRun', id: t.dataset.autorunon, file: t.value }); pickFor = null; redrawAutomations(); return; }
  if (t.dataset && t.dataset.draft && draft) { draft[t.dataset.draft] = t.value; if (t.dataset.draft === 'trigger' || t.dataset.draft === 'days') redrawAutomations(); return; }
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
  if (T && e.key === 'Escape') { e.preventDefault(); if (T.confirm) { T.confirm = null; drawTemplate(); } else tplClick({ dataset: { tpl: T.creating ? 'back' : 'cancel' } }); return; }
  if (T && e.key === 's' && e.metaKey) { e.preventDefault(); if (!T.creating) tplSave(false); return; }
  if (e.key === 'Enter' && e.target.id === 'erpurl') { e.preventDefault(); erpClick({ dataset: { erp: 'connect' } }); return; }
  if (T && e.key === 'Enter' && e.target.id === 'tplname') { e.preventDefault(); tplClick({ dataset: { tpl: 'create' } }); return; }
  if (T && e.key === 'Enter' && (e.target.id === 'tpladdname' || e.target.id === 'tpladdwhat')) { e.preventDefault(); tplAddSection(); return; }
  if (E && e.key === 'Escape') { e.preventDefault(); post({ type: 'closeFile' }); return; }
  if (e.key === 's' && e.metaKey && S && S.editor) { e.preventDefault(); post({ type: 'saveFile', text: document.getElementById('filetext').value }); return; }
  if (e.key === 'Enter' && e.target.classList && e.target.classList.contains('text')) e.target.blur();
});
})();
</script>
</body></html>
"""#
}
