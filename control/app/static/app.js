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
