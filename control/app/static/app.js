// Refresh the status block in place: every 15 s, every 3 s while an action runs.
(function () {
  const box = document.getElementById("status");
  if (!box) return;
  let timer = null;
  function schedule() {
    clearTimeout(timer);
    const busy = box.querySelector("[data-busy='1']");
    timer = setTimeout(tick, busy ? 3000 : 15000);
  }
  async function tick() {
    if (!document.hidden) {
      try {
        const r = await fetch(box.dataset.src, { credentials: "same-origin", cache: "no-store" });
        if (r.status === 401) { location.reload(); return; }
        if (r.ok) box.innerHTML = await r.text();
      } catch (e) { /* offline for a moment; try again */ }
    }
    schedule();
  }
  document.addEventListener("visibilitychange", () => { if (!document.hidden) tick(); });
  schedule();
})();

// Wallet card: copy buttons, and "Add to MetaMask" when a wallet is injected.
(function () {
  document.addEventListener("click", async (ev) => {
    const btn = ev.target.closest("button.copy");
    if (!btn) return;
    try {
      await navigator.clipboard.writeText(btn.dataset.copy);
      const old = btn.textContent; btn.textContent = "Copied"; setTimeout(() => { btn.textContent = old; }, 1200);
    } catch (e) { btn.textContent = "Select and copy"; }
  });
  const add = document.getElementById("add-wallet");
  const msg = document.getElementById("wallet-msg");
  if (!add || !window.ethereum) return;
  add.hidden = false;
  add.addEventListener("click", async () => {
    const d = add.dataset;
    try {
      await window.ethereum.request({ method: "wallet_addEthereumChain", params: [{
        chainId: d.chainId, chainName: d.name, rpcUrls: [d.rpc],
        nativeCurrency: { name: d.symbol, symbol: d.symbol, decimals: Number(d.decimals) },
        blockExplorerUrls: [d.explorer],
      }] });
      msg.textContent = "Done. Check the network in your wallet.";
    } catch (e) {
      msg.textContent = (e && e.message) ? e.message : "The wallet didn't add it. Enter the settings above by hand.";
    }
  });
})();

// Console page: follow the node's logs (read-only) and keep sync status on top.
(function () {
  const root = document.getElementById("console");
  if (!root) return;
  const out = document.getElementById("console-out");
  const filter = document.getElementById("console-filter");
  const pauseBtn = document.getElementById("console-pause");
  const stateEl = document.getElementById("console-state");
  const syncEl = document.getElementById("console-sync");
  const SYNC = /sync|import|snap|heal|forkchoice|download|checkpoint|backfill|head|peer|pivot|chain/i;
  const MAX = 500;
  let tab = localStorage.getItem("console-tab") || root.dataset.tabs.split(",")[0];
  let seq = 0, paused = false, lines = [];
  try { filter.checked = localStorage.getItem("console-filter") === "1"; } catch (e) {}

  function level(line) {
    if (/\b(ERROR|CRIT|FATAL)\b|level=(error|fatal)/i.test(line)) return "err";
    if (/\bWARN\b|level=warn/i.test(line)) return "warn";
    return "";
  }
  function render() {
    const atBottom = out.scrollHeight - out.scrollTop - out.clientHeight < 40;
    const frag = document.createDocumentFragment();
    for (const l of lines) {
      if (filter.checked && !SYNC.test(l)) continue;
      const div = document.createElement("div");
      div.textContent = l;               // never innerHTML: log text is untrusted
      const lv = level(l); if (lv) div.className = lv;
      frag.appendChild(div);
    }
    out.replaceChildren(frag);
    if (atBottom) out.scrollTop = out.scrollHeight;
  }
  async function poll() {
    if (!paused && !document.hidden) {
      try {
        const r = await fetch(`/console/${tab}.json?after=${seq}`, { credentials: "same-origin", cache: "no-store" });
        if (r.status === 401) { location.href = "/login"; return; }
        const d = await r.json();
        if (d.missing) {
          stateEl.textContent = "Log helper not running (re-run ./control/install.sh on the node).";
        } else {
          if (d.reset) lines = [];
          if (d.lines.length) { lines = lines.concat(d.lines).slice(-MAX); render(); }
          seq = d.seq;
          stateEl.textContent = d.age > 30 ? `no new lines for ${d.age}s` : "live";
        }
      } catch (e) { stateEl.textContent = "reconnecting…"; }
    }
    setTimeout(poll, 3000);
  }
  async function pollSync() {
    try {
      const r = await fetch("/api/status", { credentials: "same-origin", cache: "no-store" });
      if (r.ok) {
        const s = await r.json(), el = s.el || {}, cl = s.cl || {};
        const n = (x) => (x == null ? "—" : Number(x).toLocaleString());
        let t;
        if (!el.up) t = "go-pulse not answering";
        else if (el.syncing) {
          t = `Syncing: block ${n(el.current)} of ${n(el.highest)} (${(el.percent || 0).toFixed(1)}%)`;
          if (s.eta_hours != null) t += ` · ETA ~${s.eta_hours < 1 ? "<1" : Math.round(s.eta_hours)} h`;
        } else t = `Synced at block ${n(el.current)}`;
        t += ` · ${n(el.peers)} go-pulse / ${n(cl.peers)} Prysm peers`;
        syncEl.textContent = t;
        syncEl.className = "console-sync " + (!el.up ? "bad" : el.syncing ? "" : "good");
      }
    } catch (e) { /* try again */ }
    setTimeout(pollSync, 10000);
  }
  function select(name) {
    tab = name; seq = 0; lines = []; out.replaceChildren();
    try { localStorage.setItem("console-tab", name); } catch (e) {}
    for (const b of root.querySelectorAll(".tab")) b.classList.toggle("active", b.dataset.tab === name);
  }
  root.addEventListener("click", (ev) => { const b = ev.target.closest(".tab"); if (b) { select(b.dataset.tab); poll(); } });
  filter.addEventListener("change", () => { try { localStorage.setItem("console-filter", filter.checked ? "1" : "0"); } catch (e) {} render(); });
  pauseBtn.addEventListener("click", () => { paused = !paused; pauseBtn.textContent = paused ? "Resume" : "Pause"; stateEl.textContent = paused ? "paused" : ""; });
  select(tab); poll(); pollSync();
})();
