/// The first-run tour's pointer card (CoachTour.swift loads it into a small
/// transparent window beside what it points at): a card on the Nikxel window's
/// paper and an arrow, bobbing toward the avatar, the menu bar icon or the
/// tray. Shared with the Windows app (windows/scripts/copy-static.js).
///
/// Native → page: nx.show({dir, at, title, text, step, total, primary, platform}).
/// `dir` is where the target is ("up", "down", "left", "right"), `at` how far
/// along that edge the arrow points, in px. Page → native: {type:"next"},
/// {type:"skip"}, {type:"size", w, h} so the window fits the card.
enum CoachPage {
    static let html = #"""
<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Nikxel tour</title>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Fraunces:opsz,wght@9..144,600&family=Public+Sans:wght@400;500;600&display=swap">
<style>
:root{--paper:#fdfcf8;--ink:#0a0a0a;--ink-2:#45423b;--muted:#73706a;--line:#e3e0d6;--accent:oklch(47% 0.13 255);--ease:cubic-bezier(.16,1,.3,1)}
*{box-sizing:border-box}
html,body{margin:0;background:transparent;overflow:hidden;-webkit-user-select:none;user-select:none;cursor:default;font:14.5px/1.5 'Public Sans',-apple-system,'Segoe UI',sans-serif;color:var(--ink)}
#wrap{display:inline-flex;align-items:center;padding:6px;opacity:0;transform:translateY(6px);transition:opacity .5s var(--ease),transform .5s var(--ease)}
#wrap.on{opacity:1;transform:none}
#wrap.up{flex-direction:column;align-items:flex-start}
#wrap.down{flex-direction:column-reverse;align-items:flex-start}
#wrap.left{flex-direction:row}
#wrap.right{flex-direction:row-reverse}
.arrow{flex:none;width:84px;height:84px;color:var(--accent);position:relative}
.arrow svg{width:84px;height:84px;overflow:visible;filter:drop-shadow(0 1px 1.5px rgba(0,0,0,.25))}
/* Drawn in like a pen stroke, once per card. */
.arrow path{stroke-dasharray:160;stroke-dashoffset:160;animation:draw .7s var(--ease) .15s forwards}
.arrow path.head{animation-delay:.6s}
@keyframes draw{to{stroke-dashoffset:0}}
.up .arrow svg{animation:bob-up 1.2s ease-in-out infinite}
.down .arrow svg{transform:rotate(180deg);animation:bob-down 1.2s ease-in-out infinite}
.left .arrow svg{transform:rotate(-90deg);animation:bob-left 1.2s ease-in-out infinite}
.right .arrow svg{transform:rotate(90deg);animation:bob-right 1.2s ease-in-out infinite}
@keyframes bob-up{50%{transform:translateY(-6px)}}
@keyframes bob-down{0%,100%{transform:rotate(180deg)}50%{transform:rotate(180deg) translateY(-6px)}}
@keyframes bob-left{0%,100%{transform:rotate(-90deg)}50%{transform:rotate(-90deg) translateY(-6px)}}
@keyframes bob-right{0%,100%{transform:rotate(90deg)}50%{transform:rotate(90deg) translateY(-6px)}}
.card{width:320px;padding:16px 18px 14px;border-radius:16px;background:var(--paper);border:1px solid var(--line);
  box-shadow:0 1px 2px rgba(0,0,0,.06),0 16px 36px -14px rgba(40,30,10,.38)}
.card b.t{display:block;font:600 18px/1.25 'Fraunces',Georgia,serif;letter-spacing:-.01em;margin-bottom:6px}
.card p{margin:0 0 6px;color:var(--ink-2)}
.card p:last-of-type{margin-bottom:0}
.card kbd{font:600 12px 'Public Sans',sans-serif;padding:1px 6px;border:1px solid var(--line);border-bottom-width:2px;border-radius:5px;background:#fff}
.row{display:flex;align-items:center;gap:10px;margin-top:14px}
.dots{display:flex;gap:5px;margin-right:auto}
.dots i{width:6px;height:6px;border-radius:50%;background:var(--line)}
.dots i.on{background:var(--accent)}
button{font:600 13.5px 'Public Sans',sans-serif;border-radius:999px;padding:8px 14px;cursor:pointer;border:1px solid transparent}
.next{background:var(--ink);color:#fff}
.skip{background:transparent;color:var(--muted);padding:8px 6px}
.skip:hover{color:var(--ink)}
@media (prefers-reduced-motion:reduce){.arrow svg{animation:none!important}.arrow path{animation:none;stroke-dashoffset:0}#wrap{transition:none}}
</style></head><body>
<div id="wrap"><div class="arrow" id="arrow"><svg viewBox="0 0 84 84" fill="none" aria-hidden="true">
<!-- A pen stroke: a long curve up to the tip at the top centre, an open head, and a little wobble. -->
<defs><filter id="pen" x="-20%" y="-20%" width="140%" height="140%"><feTurbulence type="fractalNoise" baseFrequency=".045" numOctaves="2" seed="7"/><feDisplacementMap in="SourceGraphic" scale="2.6"/></filter></defs>
<g filter="url(#pen)" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round">
<path d="M24 82 C 6 62, 12 36, 30 24 S 44 10, 42 5" stroke-width="4.2"/>
<path class="head" d="M30 13 L 42 4 L 51 16" stroke-width="4.2"/>
</g></svg></div>
<div class="card" role="dialog" aria-live="polite"><b class="t" id="title"></b><div id="text"></div>
<div class="row"><span class="dots" id="dots"></span><button type="button" class="skip" id="skip">Skip tour</button><button type="button" class="next" id="next">Next</button></div></div></div>
<script>
(function () {
var wrap = document.getElementById('wrap'), arrow = document.getElementById('arrow'), shown = '';
function post(m) { webkit.messageHandlers.nx.postMessage(m); }
window.nx = {
  show: function (s) {
    // Same card, moved (it follows a window): no fade-in again.
    var same = shown === s.title + '|' + s.dir;
    shown = s.title + '|' + s.dir;
    wrap.className = s.dir + (same ? ' on' : '');
    document.getElementById('title').textContent = s.title;
    document.getElementById('text').innerHTML = s.text;   // the tour's own copy, with <b> and <kbd>
    document.getElementById('next').textContent = s.primary || 'Next';
    document.getElementById('skip').style.display = s.step + 1 >= s.total ? 'none' : '';
    var dots = '';
    for (var i = 0; i < s.total; i++) dots += '<i' + (i === s.step ? ' class="on"' : '') + '></i>';
    document.getElementById('dots').innerHTML = dots;
    // The arrow sits along its edge where the target is.
    var horizontal = s.dir === 'up' || s.dir === 'down';
    // The tip is the middle of the arrow's top edge, which turns to face the target.
    arrow.style.marginLeft = horizontal ? Math.max(0, s.at - 48) + 'px' : '';
    arrow.style.marginTop = horizontal ? '' : Math.max(0, s.at - 48) + 'px';
    // Draw it in again on each new card.
    if (!same) arrow.querySelectorAll('path').forEach(function (p) { p.style.animation = 'none'; void p.getBoundingClientRect(); p.style.animation = ''; });
    arrow.style.alignSelf = horizontal ? 'flex-start' : 'flex-start';
    requestAnimationFrame(function () {
      post({ type: 'size', w: wrap.offsetWidth, h: wrap.offsetHeight });
      wrap.classList.add('on');
    });
  }
};
document.getElementById('next').onclick = function () { post({ type: 'next' }); };
document.getElementById('skip').onclick = function () { post({ type: 'skip' }); };
document.addEventListener('keydown', function (e) {
  if (e.key === 'Escape') post({ type: 'skip' });
  if (e.key === 'Enter') post({ type: 'next' });
});
})();
</script></body></html>
"""#
}
