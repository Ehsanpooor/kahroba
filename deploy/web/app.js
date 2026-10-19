// Splendor — the download page's motion. No libraries: one scroll loop
// (requestAnimationFrame) drives parallax, the word-by-word story, the pinned
// "how to play" steps, the gallery's focus and the drifting portraits;
// IntersectionObserver reveals the rest. Calm when the reader asks for it.
(() => {
  const calm = matchMedia("(prefers-reduced-motion: reduce)").matches;
  const $ = (s, r = document) => r.querySelector(s);
  const $$ = (s, r = document) => [...r.querySelectorAll(s)];
  const vh = () => window.innerHeight;

  // -------------------------------------------------------------- reveals
  const io = new IntersectionObserver((list) => {
    for (const e of list) {
      if (e.isIntersecting) {
        e.target.classList.add("in");
        io.unobserve(e.target);
      }
    }
  }, { rootMargin: "0px 0px -12% 0px", threshold: 0.12 });
  $$(".reveal").forEach((el) => io.observe(el));

  // -------------------------------------------------------------- the story, one word at a time
  const words = $("[data-words]");
  let wordEls = [];
  if (words) {
    const text = words.textContent.trim().split(/\s+/);
    words.innerHTML = text.map((w) => `<span class="w">${w}</span>`).join(" ");
    wordEls = $$(".w", words);
  }

  // -------------------------------------------------------------- top bar and dock
  const topbar = $("#topbar");
  const dock = $("#dock");
  const hero = $("#hero");
  const final = $("#final");

  // -------------------------------------------------------------- how to play (pinned)
  const how = $("#how");
  const scenes = $$(".scene", how);
  const steps = $$(".step", how);
  const dots = $$(".how__dots i", how);
  const counter = $("[data-count]", how);
  let stepNow = -1;
  let counted = false;

  function setStep(i) {
    if (i === stepNow) return;
    stepNow = i;
    scenes.forEach((s, k) => s.classList.toggle("on", k === i));
    steps.forEach((s, k) => s.classList.toggle("on", k === i));
    dots.forEach((d, k) => d.classList.toggle("on", k <= i));
    if (i === 3 && !counted) countUp();
    if (navigator.vibrate && !calm && i >= 0) navigator.vibrate(8); // a tiny tick on phones
  }

  function countUp() {
    counted = true;
    const to = +counter.dataset.count;
    if (calm) { counter.textContent = to; return; }
    const t0 = performance.now();
    const tick = (t) => {
      const k = Math.min((t - t0) / 1100, 1);
      counter.textContent = Math.round(to * (1 - Math.pow(1 - k, 3)));
      if (k < 1) requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
  }

  // -------------------------------------------------------------- gallery
  const track = $("#galtrack");
  const slides = $$(".slide", track);
  const gdots = $("#galdots");
  slides.forEach(() => gdots.appendChild(document.createElement("i")));
  const gdotEls = $$("i", gdots);

  function galleryFocus() {
    const box = track.getBoundingClientRect();
    const mid = box.left + box.width / 2;
    let best = 0, bestD = Infinity;
    slides.forEach((s, k) => {
      const r = s.getBoundingClientRect();
      const d = Math.abs(r.left + r.width / 2 - mid);
      if (d < bestD) { bestD = d; best = k; }
      if (!calm) {
        const f = Math.min(d / box.width, 1);
        s.style.transform = `scale(${1 - f * 0.12}) rotateY(${(r.left + r.width / 2 - mid) / box.width * -10}deg)`;
        s.style.opacity = 1 - f * 0.5;
      }
    });
    gdotEls.forEach((d, k) => d.classList.toggle("on", k === best));
  }
  track.addEventListener("scroll", () => requestAnimationFrame(galleryFocus), { passive: true });
  track.style.perspective = "1200px";

  // -------------------------------------------------------------- the five gems' orbit
  const orbit = $("#orbit");
  const ogems = $$(".og", orbit);
  const oname = $(".orbit__name", orbit);
  const NAMES = ["الماس", "یاقوت کبود", "زمرد", "یاقوت سرخ", "عقیق"];
  let frontNow = -1;

  function orbitFrame(h) {
    const r = orbit.getBoundingClientRect();
    if (r.bottom < 0 || r.top > h) return;
    const p = calm ? 0 : Math.min(Math.max(-r.top / (orbit.offsetHeight - h), 0), 1);
    const turn = p * Math.PI * 2 * 1.2 + Math.PI / 2;  // one and a bit turns across the section
    const rx = Math.min(innerWidth * 0.36, 300);
    const ry = Math.min(h * 0.22, 190);
    let front = 0, best = -2;
    ogems.forEach((g, k) => {
      const a = turn + (k / ogems.length) * Math.PI * 2;
      const depth = Math.sin(a);  // 1 = nearest
      const x = Math.cos(a) * rx;
      const y = depth * ry * 0.55 - ry * 0.1;
      const s = 0.55 + (depth + 1) * 0.42;
      g.style.transform = `translate3d(${x.toFixed(1)}px, ${y.toFixed(1)}px, 0) scale(${s.toFixed(3)}) rotate(${(a * 40).toFixed(1)}deg)`;
      g.style.zIndex = String(Math.round((depth + 1) * 10));
      g.style.filter = `drop-shadow(0 24px 30px rgba(0,0,0,.7)) blur(${((1 - depth) * 1.6).toFixed(2)}px) brightness(${(0.55 + (depth + 1) * 0.3).toFixed(2)})`;
      if (depth > best) { best = depth; front = k; }
    });
    if (front !== frontNow) {
      frontNow = front;
      oname.innerHTML = `<span>${NAMES[front]}</span>`;
    }
  }

  // -------------------------------------------------------------- the scroll loop
  const parallax = $$("[data-speed]");
  const rows = $$("[data-drift]");
  const seal = $("[data-spin]");
  let ticking = false;

  function frame() {
    ticking = false;
    const y = window.scrollY;
    const h = vh();

    // the bars: shown once the hero is behind you, the dock hides at the end
    const past = y > hero.offsetHeight * 0.75;
    topbar.classList.toggle("on", past);
    const finalTop = final.getBoundingClientRect().top;
    dock.classList.toggle("on", past && finalTop > h * 0.6);

    if (!calm) {
      for (const el of parallax) {
        const r = el.getBoundingClientRect();
        if (r.bottom < -200 || r.top > h + 200) continue;
        const centre = r.top + r.height / 2 - h / 2;
        el.style.transform = `translate3d(0, ${(-centre * +el.dataset.speed).toFixed(1)}px, 0)`;
      }
      for (const row of rows) {
        const r = row.getBoundingClientRect();
        if (r.bottom < 0 || r.top > h) continue;
        const k = (h - r.top) / (h + r.height);
        row.style.transform = `translate3d(${(+row.dataset.drift * (k - 0.5) * 320).toFixed(1)}px, 0, 0)`;
      }
      if (seal) {
        const r = seal.getBoundingClientRect();
        if (r.top < h && r.bottom > 0) seal.style.transform = `rotate(${((h - r.top) / h * 40 - 20).toFixed(1)}deg)`;
      }
    }

    orbitFrame(h);

    // the story lights up word by word as it crosses the screen
    if (wordEls.length) {
      const r = words.getBoundingClientRect();
      const k = Math.min(Math.max((h * 0.85 - r.top) / (r.height + h * 0.35), 0), 1);
      const n = calm ? wordEls.length : Math.round(k * wordEls.length);
      wordEls.forEach((w, i) => w.classList.toggle("on", i < n));
    }

    // how to play: four steps across the pinned section
    const hr = how.getBoundingClientRect();
    const span = how.offsetHeight - h;
    const p = Math.min(Math.max(-hr.top / span, 0), 0.999);
    if (hr.top < h && hr.bottom > 0) setStep(Math.floor(p * 4));
  }

  function onScroll() {
    if (!ticking) { ticking = true; requestAnimationFrame(frame); }
  }
  addEventListener("scroll", onScroll, { passive: true });
  addEventListener("resize", onScroll);
  frame();
  galleryFocus();

  // -------------------------------------------------------------- download: a small thank-you
  $$('a[href$=".apk"]').forEach((a) => a.addEventListener("click", () => {
    if (navigator.vibrate && !calm) navigator.vibrate([12, 40, 12]);
  }));
})();
