// TinyHand in the browser: the toy pointer on a stick, held from below a "screen"
// element, that follows the mouse, taps with a thock and draws ink that fades.
// It mirrors the Mac app: the grip leans right of the cursor and follows lazily,
// the stick stretches so the fingertip lands on the cursor, the shadow tucks in
// while pressed, and a toolbar switches pointers. With no mouse (or on touch) it
// plays a short scripted demo over elements marked data-target.
//
//   TinyHandDemo.mount(document.querySelector('.screen'), { base: '' })
(function () {
  const HANDS = [
    { id: 'lavender', name: 'Lavender toy', src: 'assets/hands/lavender.png', w: 250, h: 380, tip: [67.7, 19.9], wrist: [120.2, 363.2], stick: ['#e8eaed', '#a7acb2', '#6e737a'] },
    { id: 'glove', name: 'Cursor glove', src: 'assets/hands/glove.png', w: 317, h: 380, tip: [137.5, 19.5], wrist: [175.7, 363.1], stick: ['#3a3a3e', '#121214', '#000000'], shadow: 0.5 },
    { id: 'coral', name: 'Coral vinyl', src: 'assets/hands/coral.png', w: 323, h: 380, tip: [106.4, 20.2], wrist: [157.1, 363.3], stick: ['#ffffff', '#e7e3df', '#c9c3bd'] },
    { id: 'plush', name: 'Plush', src: 'assets/hands/plush.png', w: 309, h: 380, tip: [112.0, 20.4], wrist: [146.2, 362.9], stick: ['#f1dcb6', '#d6b383', '#a9824f'] },
    { id: 'robot', name: 'Robot', src: 'assets/hands/robot.png', w: 350, h: 380, tip: [120.9, 20.3], wrist: [183.4, 363.3], stick: ['#e2e5e8', '#b6bbc1', '#7d838a'] },
  ];
  const PURPLE = '#8754f2';
  const RED = '#ff2a1f';
  const FADE_AFTER = 3000;
  const FADE_FOR = 600;

  const css = `
  .th-canvas { position: absolute; inset: 0; width: 100%; height: 100%; pointer-events: none; z-index: 5; }
  .th-live { cursor: none; user-select: none; -webkit-user-select: none; touch-action: pan-y; }
  .th-live * { cursor: none !important; }
  .th-toolbar { position: absolute; left: 50%; bottom: 14px; transform: translateX(-50%); z-index: 4;
    display: flex; align-items: center; gap: 4px; padding: 6px 8px; border-radius: 16px;
    background: rgba(40, 40, 44, 0.86); backdrop-filter: blur(14px); -webkit-backdrop-filter: blur(14px);
    box-shadow: 0 8px 24px rgba(0, 0, 0, 0.22); }
  .th-toolbar button { all: unset; box-sizing: border-box; width: 38px; height: 38px; border-radius: 10px;
    display: grid; place-items: center; transition: background .15s ease; }
  .th-toolbar button:hover, .th-toolbar button:focus-visible { background: rgba(255, 255, 255, 0.1); }
  .th-toolbar button[aria-pressed="true"] { background: rgba(255, 255, 255, 0.2); }
  .th-toolbar img { width: 30px; height: 30px; object-fit: contain; pointer-events: none; }
  .th-toolbar .th-sep { width: 1px; height: 22px; background: rgba(255, 255, 255, 0.18); margin: 0 4px; }
  .th-laser-dot { width: 11px; height: 11px; border-radius: 50%; background: ${RED};
    box-shadow: 0 0 0 3px rgba(255, 42, 31, .25), 0 0 12px 4px rgba(255, 42, 31, .45); position: relative; }
  .th-laser-dot::after { content: ""; position: absolute; inset: 3px; border-radius: 50%; background: #ffdcd5; }
  .th-toolbar svg { width: 18px; height: 18px; fill: rgba(255, 255, 255, 0.85); }
  @media (max-width: 520px) { .th-toolbar button { width: 32px; height: 32px; } .th-toolbar img { width: 25px; height: 25px; } }
  `;

  function injectStyle() {
    if (document.getElementById('th-style')) {
      return;
    }
    const s = document.createElement('style');
    s.id = 'th-style';
    s.textContent = css;
    document.head.appendChild(s);
  }

  const SPEAKER_ON = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 9h4l5-4v14l-5-4H4z"/><path d="M16.5 8.5a5 5 0 0 1 0 7" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" style="stroke:rgba(255,255,255,.85)"/><path d="M19 6a8.5 8.5 0 0 1 0 12" fill="none" stroke-width="2" stroke-linecap="round" style="stroke:rgba(255,255,255,.85)"/></svg>';
  const SPEAKER_OFF = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 9h4l5-4v14l-5-4H4z"/><path d="M17 9l5 6M22 9l-5 6" fill="none" stroke-width="2" stroke-linecap="round" style="stroke:rgba(255,255,255,.85)"/></svg>';

  function mount(stage, options) {
    const opts = Object.assign({ base: '', sound: 'assets/tap.wav', toolbar: true, autoplay: true, start: 'lavender' }, options || {});
    injectStyle();
    if (getComputedStyle(stage).position === 'static') {
      stage.style.position = 'relative';
    }
    const canvas = document.createElement('canvas');
    canvas.className = 'th-canvas';
    stage.appendChild(canvas);
    const ctx = canvas.getContext('2d');

    const images = {};
    HANDS.forEach(h => {
      const img = new Image();
      img.src = opts.base + h.src;
      images[h.id] = img;
    });

    let style = HANDS.some(h => h.id === opts.start) ? opts.start : 'lavender';
    let soundOn = { hands: true, laser: false };
    let W = 0, H = 0, dpr = 1;
    let cursor = null;          // where the fingertip is, in stage px
    let gripX = null;
    let held = false;
    let pressAmount = 0;
    let lastReal = 0;           // last real mouse activity
    let downAt = null;
    let current = null;         // stroke being drawn
    const strokes = [];
    let audio = null, buffer = null;
    const reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

    function resize() {
      const r = stage.getBoundingClientRect();
      dpr = Math.min(window.devicePixelRatio || 1, 2);
      W = r.width; H = r.height;
      canvas.width = Math.round(W * dpr);
      canvas.height = Math.round(H * dpr);
    }
    resize();
    if (window.ResizeObserver) {
      new ResizeObserver(resize).observe(stage);
    }

    // Sound: decoded on the first real interaction (browsers require one).
    function ensureAudio() {
      if (audio) {
        return;
      }
      try {
        audio = new (window.AudioContext || window.webkitAudioContext)();
        fetch(opts.base + opts.sound).then(r => r.arrayBuffer()).then(b => audio.decodeAudioData(b)).then(d => { buffer = d; }).catch(() => {});
      } catch (e) {}
    }
    function thock() {
      const on = style === 'laser' ? soundOn.laser : soundOn.hands;
      if (!on || !audio || !buffer) {
        return;
      }
      const src = audio.createBufferSource();
      src.buffer = buffer;
      src.connect(audio.destination);
      src.start();
    }

    // Toolbar, like the app's: pointers, laser, sound.
    let toolbar = null, soundBtn = null;
    if (opts.toolbar) {
      toolbar = document.createElement('div');
      toolbar.className = 'th-toolbar';
      const ids = HANDS.map(h => h.id).concat(['laser']);
      ids.forEach(id => {
        const b = document.createElement('button');
        b.type = 'button';
        b.dataset.style = id;
        const hand = HANDS.find(h => h.id === id);
        b.setAttribute('aria-label', hand ? hand.name : 'Laser dot');
        b.title = hand ? hand.name : 'Laser dot';
        b.innerHTML = hand ? `<img src="${opts.base + hand.src}" alt="">` : '<span class="th-laser-dot"></span>';
        b.addEventListener('click', () => setStyle(id));
        toolbar.appendChild(b);
      });
      const sep = document.createElement('span');
      sep.className = 'th-sep';
      toolbar.appendChild(sep);
      soundBtn = document.createElement('button');
      soundBtn.type = 'button';
      soundBtn.addEventListener('click', () => {
        ensureAudio();
        if (style === 'laser') {
          soundOn.laser = !soundOn.laser;
        } else {
          soundOn.hands = !soundOn.hands;
        }
        syncToolbar();
      });
      toolbar.appendChild(soundBtn);
      stage.appendChild(toolbar);
    }
    function syncToolbar() {
      if (!toolbar) {
        return;
      }
      toolbar.querySelectorAll('button[data-style]').forEach(b => b.setAttribute('aria-pressed', String(b.dataset.style === style)));
      const on = style === 'laser' ? soundOn.laser : soundOn.hands;
      soundBtn.innerHTML = on ? SPEAKER_ON : SPEAKER_OFF;
      soundBtn.setAttribute('aria-label', on ? 'Mute the tap sound' : 'Turn the tap sound on');
      soundBtn.title = soundBtn.getAttribute('aria-label');
    }
    function setStyle(id) {
      style = id;
      syncToolbar();
      stage.dispatchEvent(new CustomEvent('th-style', { detail: id }));
    }
    syncToolbar();

    // Real mouse input.
    function local(e) {
      const r = stage.getBoundingClientRect();
      return { x: e.clientX - r.left, y: e.clientY - r.top };
    }
    function onToolbar(e) {
      return toolbar && toolbar.contains(e.target);
    }
    stage.addEventListener('pointermove', e => {
      if (e.pointerType !== 'mouse') {
        return;
      }
      lastReal = performance.now();
      stage.classList.add('th-live');
      cursor = local(e);
      if (downAt && !onToolbar(e)) {
        extend(cursor);
      }
    });
    stage.addEventListener('pointerleave', e => {
      if (e.pointerType !== 'mouse') {
        return;
      }
      stage.classList.remove('th-live');
      release();
      cursor = null;
      lastReal = 0;
    });
    stage.addEventListener('pointerdown', e => {
      if (e.pointerType !== 'mouse' || onToolbar(e)) {
        return;
      }
      e.preventDefault();
      ensureAudio();
      lastReal = performance.now();
      cursor = local(e);
      press(cursor);
    });
    window.addEventListener('pointerup', e => {
      if (e.pointerType === 'mouse') {
        release();
      }
    });
    stage.addEventListener('click', e => {
      if (!onToolbar(e) && stage.classList.contains('th-live')) {
        e.preventDefault(); // taps are cosmetic, like in the app
      }
    }, true);

    function press(p) {
      held = true;
      pressAmount = 1;
      downAt = { x: p.x, y: p.y };
      thock();
    }
    function extend(p) {
      if (!current) {
        if (Math.hypot(p.x - downAt.x, p.y - downAt.y) < 4) {
          return;
        }
        current = { pts: [downAt], color: style === 'laser' ? RED : PURPLE, ended: 0 };
        strokes.push(current);
      }
      const last = current.pts[current.pts.length - 1];
      if (Math.hypot(p.x - last.x, p.y - last.y) >= 1.5) {
        current.pts.push({ x: p.x, y: p.y });
      }
    }
    function release() {
      held = false;
      downAt = null;
      if (current) {
        current.ended = performance.now();
        current = null;
      }
    }

    // Scripted demo, for touch screens and idle visitors.
    const demo = { t: 0, steps: [], i: 0, from: null };
    function targets() {
      const r = stage.getBoundingClientRect();
      return Array.from(stage.querySelectorAll('[data-target]')).map(el => {
        const b = el.getBoundingClientRect();
        return { x: b.left - r.left, y: b.top - r.top, w: b.width, h: b.height, kind: el.dataset.target };
      }).filter(t => t.w > 0);
    }
    function planDemo() {
      const ts = targets();
      const steps = [];
      const circle = ts.find(t => t.kind === 'circle');
      const tap = ts.find(t => t.kind === 'tap');
      const point = ts.find(t => t.kind === 'point');
      if (point) {
        steps.push({ to: { x: point.x + point.w * 0.5, y: point.y + point.h * 0.55 }, dur: 1100 }, { wait: 700 });
      }
      if (circle) {
        const cx = circle.x + circle.w / 2, cy = circle.y + circle.h / 2;
        const rx = circle.w / 2 + 14, ry = circle.h / 2 + 10;
        const a0 = -Math.PI * 0.85;
        steps.push({ to: { x: cx + rx * Math.cos(a0), y: cy + ry * Math.sin(a0) }, dur: 900 }, { down: true },
          { circle: { cx, cy, rx, ry, a0 }, dur: 1300 }, { up: true }, { wait: 900 });
      }
      if (tap) {
        steps.push({ to: { x: tap.x + tap.w * 0.5, y: tap.y + tap.h * 0.5 }, dur: 900 }, { down: true }, { wait: 140 }, { up: true }, { wait: 300 },
          { down: true }, { wait: 120 }, { up: true }, { wait: 1200 });
      }
      if (!steps.length) {
        steps.push({ to: { x: W * 0.45, y: H * 0.4 }, dur: 1200 }, { wait: 1500 });
      }
      demo.steps = steps;
      demo.i = 0;
      demo.t = 0;
      demo.from = cursor || { x: W * 0.7, y: H * 0.85 };
    }
    function demoActive(now) {
      return opts.autoplay && !reduce && (now - lastReal > 2500);
    }
    function stepDemo(dt) {
      if (!demo.steps.length) {
        planDemo();
      }
      const s = demo.steps[demo.i];
      demo.t += dt;
      const ease = t => t < 0.5 ? 2 * t * t : 1 - Math.pow(-2 * t + 2, 2) / 2;
      let done = true;
      if (s.to) {
        const k = Math.min(1, demo.t / s.dur);
        const e = ease(k);
        cursor = { x: demo.from.x + (s.to.x - demo.from.x) * e, y: demo.from.y + (s.to.y - demo.from.y) * e };
        done = k >= 1;
      } else if (s.circle) {
        const k = Math.min(1, demo.t / s.dur);
        const a = s.circle.a0 + ease(k) * Math.PI * 2.08;
        cursor = { x: s.circle.cx + s.circle.rx * Math.cos(a), y: s.circle.cy + s.circle.ry * Math.sin(a) };
        extend(cursor);
        done = k >= 1;
      } else if (s.wait) {
        done = demo.t >= s.wait;
      } else if (s.down) {
        press(cursor);
      } else if (s.up) {
        release();
      }
      if (done) {
        demo.i += 1;
        demo.t = 0;
        demo.from = cursor;
        if (demo.i >= demo.steps.length) {
          planDemo();
        }
      }
    }

    // Drawing.
    function drawInk(now) {
      const width = Math.max(3, Math.min(6, H * 0.008));
      for (let i = strokes.length - 1; i >= 0; i--) {
        const s = strokes[i];
        let alpha = 1;
        if (s.ended) {
          const age = now - s.ended - FADE_AFTER;
          if (age > FADE_FOR) {
            strokes.splice(i, 1);
            continue;
          }
          alpha = age > 0 ? 1 - age / FADE_FOR : 1;
        }
        const p = s.pts;
        ctx.save();
        ctx.globalAlpha = alpha;
        ctx.strokeStyle = s.color;
        ctx.lineWidth = width;
        ctx.lineCap = 'round';
        ctx.lineJoin = 'round';
        ctx.shadowColor = 'rgba(0,0,0,0.16)';
        ctx.shadowBlur = 2;
        ctx.shadowOffsetX = 1;
        ctx.shadowOffsetY = 1.5;
        ctx.beginPath();
        ctx.moveTo(p[0].x, p[0].y);
        for (let k = 1; k < p.length; k++) {
          const m = { x: (p[k - 1].x + p[k].x) / 2, y: (p[k - 1].y + p[k].y) / 2 };
          ctx.quadraticCurveTo(p[k - 1].x, p[k - 1].y, m.x, m.y);
        }
        if (p.length > 1) {
          ctx.lineTo(p[p.length - 1].x, p[p.length - 1].y);
        }
        ctx.stroke();
        ctx.restore();
      }
    }

    function drawLaser() {
      const r = Math.max(4, Math.min(7, H * 0.009)) * (1 + 0.2 * pressAmount);
      ctx.save();
      ctx.shadowColor = RED;
      ctx.shadowBlur = r * (2.4 + pressAmount);
      ctx.fillStyle = RED;
      ctx.beginPath();
      ctx.arc(cursor.x, cursor.y, r, 0, Math.PI * 2);
      ctx.fill();
      ctx.shadowBlur = 0;
      ctx.fillStyle = '#ffdcd5';
      ctx.beginPath();
      ctx.arc(cursor.x, cursor.y, r * 0.45, 0, Math.PI * 2);
      ctx.fill();
      ctx.restore();
    }

    function drawHand(dt) {
      const hand = HANDS.find(h => h.id === style);
      const img = images[style];
      if (!img.complete || !img.naturalWidth) {
        return;
      }
      const handH = Math.max(64, Math.min(124, H * 0.19)) * (1 - 0.06 * pressAmount);
      const s = handH / hand.h;
      const targetX = Math.min(Math.max(cursor.x + 0.18 * W, W * 0.15), W * 1.05);
      gripX = gripX == null ? targetX : gripX + (targetX - gripX) * Math.min(1, dt * 0.0096);
      const grip = { x: gripX, y: H + H * 0.35 };
      const aScr = Math.atan2(cursor.y - grip.y, cursor.x - grip.x);
      const aImg = Math.atan2(hand.tip[1] - hand.wrist[1], hand.tip[0] - hand.wrist[0]);
      const rot = aScr - aImg;
      const dx = (hand.wrist[0] - hand.tip[0]) * s, dy = (hand.wrist[1] - hand.tip[1]) * s;
      const wrist = { x: cursor.x + dx * Math.cos(rot) - dy * Math.sin(rot), y: cursor.y + dx * Math.sin(rot) + dy * Math.cos(rot) };

      const lift = Math.max(6, H * 0.04) * (1 - 0.95 * pressAmount);
      const strength = hand.shadow || 1;
      ctx.save();
      ctx.shadowColor = `rgba(0,0,0,${(0.26 + 0.16 * pressAmount) * strength})`;
      ctx.shadowBlur = Math.max(1, lift * 0.7) + 4 * pressAmount;
      ctx.shadowOffsetX = lift * 0.6;
      ctx.shadowOffsetY = lift;

      // The stick: a cylinder shaded across its width.
      const sw = Math.max(4, handH * 0.07);
      const nx = -(wrist.y - grip.y), ny = wrist.x - grip.x;
      const nl = Math.hypot(nx, ny) || 1;
      const mx = (wrist.x + grip.x) / 2, my = (wrist.y + grip.y) / 2;
      const g = ctx.createLinearGradient(mx - nx / nl * sw / 2, my - ny / nl * sw / 2, mx + nx / nl * sw / 2, my + ny / nl * sw / 2);
      g.addColorStop(0, hand.stick[2]);
      g.addColorStop(0.35, hand.stick[1]);
      g.addColorStop(0.55, hand.stick[0]);
      g.addColorStop(1, hand.stick[2]);
      ctx.strokeStyle = g;
      ctx.lineWidth = sw;
      ctx.lineCap = 'round';
      ctx.beginPath();
      ctx.moveTo(grip.x, grip.y);
      ctx.lineTo(wrist.x, wrist.y);
      ctx.stroke();

      ctx.translate(cursor.x, cursor.y);
      ctx.rotate(rot);
      ctx.drawImage(img, -hand.tip[0] * s, -hand.tip[1] * s, hand.w * s, hand.h * s);
      ctx.restore();
    }

    let last = performance.now();
    let lastFrame = 0;
    function frame(now) {
      lastFrame = performance.now();
      const dt = Math.min(64, now - last);
      last = now;
      if (!held) {
        pressAmount += (0 - pressAmount) * Math.min(1, dt * 0.022);
      }
      const auto = demoActive(now);
      if (auto) {
        stepDemo(dt);
      } else if (demo.steps.length) {
        if (held && !lastReal) {
          release();
        }
        demo.steps = [];
      }
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      ctx.clearRect(0, 0, W, H);
      drawInk(now);
      if (cursor) {
        if (style === 'laser') {
          drawLaser();
        } else {
          drawHand(dt);
        }
      }
      requestAnimationFrame(frame);
    }
    if (reduce) {
      const t = targets().find(x => x.kind === 'point');
      cursor = t ? { x: t.x + t.w * 0.5, y: t.y + t.h * 0.55 } : { x: W * 0.5, y: H * 0.45 };
    }
    requestAnimationFrame(frame);
    // Some environments never deliver animation frames (headless renders, some
    // embeds); keep drawing on a timer there. Real browsers stay on rAF.
    setInterval(() => {
      if (!document.hidden && performance.now() - lastFrame > 250) {
        const now = performance.now();
        const dt = Math.min(64, now - last);
        last = now;
        if (!held) {
          pressAmount += (0 - pressAmount) * Math.min(1, dt * 0.022);
        }
        if (demoActive(now)) {
          stepDemo(dt);
        }
        ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
        ctx.clearRect(0, 0, W, H);
        drawInk(now);
        if (cursor) {
          if (style === 'laser') {
            drawLaser();
          } else {
            drawHand(dt);
          }
        }
      }
    }, 33);

    return { setStyle, hands: HANDS };
  }

  window.TinyHandDemo = { mount, hands: HANDS };
})();
