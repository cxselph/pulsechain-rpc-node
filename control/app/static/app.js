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
