/* Fernlet — fernlet.com
   Progressive enhancement ONLY. Every element this touches is already
   rendered in the HTML; with JS disabled the page is complete and readable.
   No cookies, no storage, no network requests. */
(function () {
  "use strict";

  /* ── Nav: collapse on scroll down, return on scroll up ── */
  var nav = document.getElementById("nav");
  if (nav) {
    var lastY = 0, ticking = false;
    var apply = function () {
      var y = window.scrollY || document.documentElement.scrollTop || 0;
      nav.classList.toggle("compact", y > 40);
      if (y > 180 && y > lastY + 4) nav.classList.add("hidden");
      else if (y < lastY - 4 || y <= 180) nav.classList.remove("hidden");
      lastY = y;
      ticking = false;
    };
    window.addEventListener("scroll", function () {
      if (!ticking) { ticking = true; window.requestAnimationFrame(apply); }
    }, { passive: true });
  }

  /* ── Companion state ──
     The companion is the app's own pixel painter, rendered to SVG (assets/companion/, by
     Scripts/render-site-companion.sh): a resting frame, an in-breath frame and the "settled"
     face a poke shows. Colours are CompanionState's. */
  var STATES = {
    thriving: { color: "#5E844D", label: "Thriving" },
    okay:     { color: "#D2973B", label: "Okay" },
    tired:    { color: "#B67073", label: "Tired" },
    resting:  { color: "#5C6B78", label: "Resting" },
    sick:     { color: "#B9543D", label: "Sick" }
  };
  var current = "thriving";

  var stateLabel = document.getElementById("statelabel");
  var chips = document.getElementById("statechips");
  var sprite = document.getElementById("sprite");
  var spriteBreath = document.getElementById("spritebreath");

  function frame(key, suffix) { return "assets/companion/" + key + suffix + ".svg"; }

  function setState(key) {
    var s = STATES[key];
    if (!s) return;
    current = key;
    document.documentElement.style.setProperty("--state", s.color);
    if (stateLabel) stateLabel.textContent = s.label;
    if (sprite) sprite.src = frame(key, "");
    if (spriteBreath) spriteBreath.src = frame(key, "-breath");
    if (chips) {
      Array.prototype.forEach.call(chips.children, function (b) {
        b.classList.toggle("on", b.dataset.state === key);
      });
    }
  }

  if (chips) {
    chips.addEventListener("click", function (e) {
      var b = e.target.closest("button[data-state]");
      if (b) setState(b.dataset.state);
    });
  }

  /* ── Poke the companion ── */
  var BUBBLES = [
    "Slept a little better last night.",
    "We uncovered a new corner of the park.",
    "I've been out in the sun a lot lately.",
    "Had some iron-rich meals this week — felt good.",
    "A bit tired today. That's okay.",
    "Someone said hello in person yesterday.",
    "Drank more water than usual. Nice."
  ];
  // A pixel heart, the status plate's own shape.
  var HEART = '<svg width="27" height="24" viewBox="0 0 9 8" shape-rendering="crispEdges"><path fill="#5A1E14" d="M1 0h3v1H1zM5 0h3v1H5zM0 1h9v3H0zM1 4h7v1H1zM2 5h5v1H2zM3 6h3v1H3zM4 7h1v1H4z"/><path fill="#D9453B" d="M2 1h1v1H2zM6 1h1v1H6zM1 2h7v2H1zM2 4h5v1H2zM3 5h3v1H3zM4 6h1v1H4z"/></svg>';

  var pet = document.getElementById("pet");
  var heartBox = document.getElementById("hearts");
  var bubble = document.getElementById("bubble");
  var bubbleIdx = 0, settleTimer = null;

  if (pet) {
    pet.addEventListener("click", function () {
      pet.classList.add("poked");
      setTimeout(function () { pet.classList.remove("poked"); }, 260);

      // The settled face: happy-arc eyes and a blush, then back to the day's face.
      clearTimeout(settleTimer);
      pet.classList.add("settled");
      if (sprite) sprite.src = frame(current, "-settled");
      settleTimer = setTimeout(function () {
        pet.classList.remove("settled");
        if (sprite) sprite.src = frame(current, "");
      }, 1400);

      if (bubble) {
        bubbleIdx = (bubbleIdx + 1) % BUBBLES.length;
        var p = bubble.querySelector("p");
        if (p) p.textContent = BUBBLES[bubbleIdx];
      }

      if (heartBox) {
        [22, 48, 74].forEach(function (left, i) {
          var d = document.createElement("div");
          d.innerHTML = HEART;
          var svg = d.firstChild;
          svg.style.left = left + "%";
          svg.style.animationDelay = (i * 110) + "ms";
          heartBox.appendChild(svg);
          setTimeout(function () { svg.remove(); }, 1900);
        });
      }
    });
  }

  /* ── App screen tabs ── */
  var tabs = document.getElementById("screentabs");
  if (tabs) {
    tabs.addEventListener("click", function (e) {
      var b = e.target.closest("button[data-tab]");
      if (!b) return;
      Array.prototype.forEach.call(tabs.children, function (x) {
        x.classList.toggle("on", x === b);
      });
      document.querySelectorAll(".screen").forEach(function (s) {
        s.hidden = s.dataset.screen !== b.dataset.tab;
      });
    });
  }

  /* ── Friend mesh walkthrough ── */
  var stage = document.getElementById("meshstage");
  var meshBtn = document.getElementById("meshbtn");
  var meshStatus = document.getElementById("meshstatus");
  var meshLinks = document.getElementById("links");
  var meshVibes = document.querySelectorAll(".vibe");
  var meshDwell = document.getElementById("dwell");
  var meshArc = document.getElementById("dwellarc");
  var meshMinis = document.querySelectorAll(".mini");
  var REST = { l: "translateX(-22px)", c: "translateY(16px)", r: "translateX(22px)" };
  var CLOSE = { l: "translateX(10px)", c: "translateY(0)", r: "translateX(-10px)" };
  var STEPS = [
    "Three phones in one room. Nothing is connected, nothing is advertising.",
    "Radios notice each other — no distance yet, no data, no identity shared.",
    "Holding at 15 cm. The dwell is the consent: 0.8 seconds of stillness.",
    "Committed. The mesh is device-to-device — signed, encrypted, ephemeral. No server was touched."
  ];
  var step = 0, timers = [];

  function render() {
    if (!stage) return;
    stage.classList.toggle("together", step >= 1);
    stage.classList.toggle("dwelling", step === 2);
    stage.classList.toggle("linked", step >= 3);

    // Driven from JS rather than the class cascade so the demo behaves
    // identically everywhere. The CSS rules remain the no-JS baseline.
    var together = step >= 1;
    meshMinis.forEach(function (m) {
      var slot = m.getAttribute("data-slot");
      m.style.transform = (together ? CLOSE : REST)[slot] || "";
    });
    if (meshLinks) meshLinks.style.width = together ? "168px" : "232px";
    if (meshDwell) meshDwell.style.opacity = step === 2 ? "1" : "0";
    if (meshArc) meshArc.style.strokeDashoffset = step === 2 ? "0" : "189";

    var vis = step >= 3 ? "1" : "0";
    if (meshLinks) meshLinks.style.opacity = vis;
    meshVibes.forEach(function (v) { v.style.opacity = vis; });
    if (meshStatus) meshStatus.textContent = STEPS[step];
    if (meshBtn) {
      meshBtn.textContent = step === 0 ? "Bring them together" : step >= 3 ? "Start over" : "Holding…";
    }
  }

  if (meshBtn) {
    meshBtn.addEventListener("click", function () {
      timers.forEach(clearTimeout);
      timers = [];
      if (step >= 3) { step = 0; render(); return; }
      step = 1; render();
      timers.push(setTimeout(function () { step = 2; render(); }, 650));
      timers.push(setTimeout(function () { step = 3; render(); }, 1950));
    });
  }

  /* ── Encrypted-backup toggle ── */
  var sw = document.getElementById("backupswitch");
  var swState = document.getElementById("backupstate");
  var swNote = document.getElementById("backupnote");
  var NOTE_OFF = "Cycle data never leaves the phone unless you deliberately turn this on — a separate, clearly-warned opt-in, not part of ordinary iCloud sync.";
  var NOTE_ON = "Encrypted on your device with AES-256-GCM before upload, so Apple stores only unreadable ciphertext. The key lives in your iCloud Keychain — lose access to it everywhere and this data is gone for good. The app tells you that before you switch it on.";

  if (sw) {
    sw.addEventListener("click", function () {
      var on = sw.getAttribute("aria-checked") !== "true";
      sw.setAttribute("aria-checked", String(on));
      if (swState) swState.textContent = on ? "on — encrypted before it leaves" : "off by default";
      if (swNote) { swNote.textContent = on ? NOTE_ON : NOTE_OFF; swNote.classList.toggle("on", on); }
    });
  }

  setState("thriving");
  render();
})();
