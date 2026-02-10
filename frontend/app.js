const apiUrlEl = document.getElementById("apiUrl");
const statusEl = document.getElementById("status");
const tbodyEl = document.getElementById("tbody");
const refreshBtn = document.getElementById("refreshBtn");
const lastRefreshedEl = document.getElementById("lastRefreshed");
const highlightEl = document.getElementById("highlight");

const toggleDebugBtn = document.getElementById("toggleDebugBtn");
const debugPanel = document.getElementById("debugPanel");

const headerBtns = Array.from(document.querySelectorAll(".thBtn"));

let lastData = []; // raw data from API
let sortState = { key: "date", dir: "desc" }; // default: Date newest -> oldest
let highlightKey = null; // "YYYY-MM-DD|TICKER"

function fmtPct(n) {
  const num = Number(n);
  if (!Number.isFinite(num)) return "";
  const sign = num > 0 ? "+" : "";
  return `${sign}${num.toFixed(3)}%`;
}

function fmtPrice(n) {
  const num = Number(n);
  if (!Number.isFinite(num)) return "";
  return `$${num.toFixed(2)}`;
}

function setStatus(msg) {
  if (statusEl) statusEl.textContent = msg;
}

function clearTable() {
  if (tbodyEl) tbodyEl.innerHTML = "";
}

function abs(n) {
  const num = Number(n);
  return Number.isFinite(num) ? Math.abs(num) : -Infinity;
}

function dateKey(s) {
  // YYYY-MM-DD sorts lexicographically
  return String(s ?? "");
}

function makeRowKey(item) {
  return `${item?.Date ?? ""}|${item?.Ticker ?? ""}`;
}

function addRow(item) {
  if (!tbodyEl) return;

  const tr = document.createElement("tr");

  const pct = Number(item.PercentChange);
  const pctClass = pct >= 0 ? "pos" : "neg";

  tr.innerHTML = `
    <td>${item.Date ?? ""}</td>
    <td class="mono">${item.Ticker ?? ""}</td>
    <td class="${pctClass}">${fmtPct(pct)}</td>
    <td class="right">${fmtPrice(item.ClosingPrice)}</td>
  `;

  // Strong color cue
  const pctTd = tr.children[2];
  if (pctTd) pctTd.style.color = pct >= 0 ? "#2ee59d" : "#ff5c7a";

  // Highlight the biggest-move row
  if (highlightKey && makeRowKey(item) === highlightKey) {
    tr.classList.add("tr-highlight");
  }

  tbodyEl.appendChild(tr);
}

function sortData(data, key, dir) {
  const arr = [...data];
  const mul = dir === "asc" ? 1 : -1;

  arr.sort((a, b) => {
    if (key === "date") return mul * dateKey(a.Date).localeCompare(dateKey(b.Date));
    if (key === "ticker") return mul * String(a.Ticker ?? "").localeCompare(String(b.Ticker ?? ""));

    // Sort % by absolute magnitude, not signed value
    if (key === "pct") return mul * (abs(a.PercentChange) - abs(b.PercentChange));

    if (key === "close") return mul * (Number(a.ClosingPrice) - Number(b.ClosingPrice));
    return 0;
  });

  return arr;
}

function renderTable() {
  clearTable();
  const sorted = sortData(lastData, sortState.key, sortState.dir);
  sorted.forEach(addRow);
}

function updateSortIcons() {
  // Reset all icons, then set the active one
  const icons = Array.from(document.querySelectorAll(".sortIcon"));
  icons.forEach((el) => el.classList.remove("asc", "desc"));

  const active = document.querySelector(`.sortIcon[data-icon="${sortState.key}"]`);
  if (active) {
    active.classList.add(sortState.dir === "asc" ? "asc" : "desc");
  }
}

function updateHighlight(data) {
  highlightKey = null;

  if (!highlightEl) return;
  if (!Array.isArray(data) || data.length === 0) {
    highlightEl.textContent = "";
    return;
  }

  // Biggest absolute move in the window
  let best = data[0];
  let bestAbs = abs(best.PercentChange);

  for (const item of data) {
    const v = abs(item.PercentChange);
    if (v > bestAbs) {
      best = item;
      bestAbs = v;
    }
  }

  const pct = Number(best.PercentChange);
  const dir = pct >= 0 ? "up" : "down";
  highlightKey = makeRowKey(best);

  highlightEl.innerHTML = `Biggest move in this window: <span class="mono">${best.Ticker}</span> ${fmtPct(
    pct
  )} (${dir}) on <span class="mono">${best.Date}</span>`;
}

function updateLastRefreshed() {
  if (!lastRefreshedEl) return;

  const now = new Date();

  const pt = new Intl.DateTimeFormat("en-US", {
    timeZone: "America/Los_Angeles",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hour12: true,
  }).format(now);

  const et = new Intl.DateTimeFormat("en-US", {
    timeZone: "America/New_York",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hour12: true,
  }).format(now);

  lastRefreshedEl.textContent = `${pt} PT  |  ${et} ET`;
}

function setLoadedRangeStatus(data) {
  if (!Array.isArray(data) || data.length === 0) {
    setStatus("No data yet. (Ingestion may not have run for enough days.)");
    return;
  }

  let oldest = data[0].Date;
  let newest = data[0].Date;

  for (const item of data) {
    const d = item.Date;
    if (dateKey(d) < dateKey(oldest)) oldest = d;
    if (dateKey(d) > dateKey(newest)) newest = d;
  }

  setStatus(`Loaded Last 7 Full Trading Days -- from ${oldest} to ${newest}`);
}

function wireHeaderSorting() {
  headerBtns.forEach((btn) => {
    btn.addEventListener("click", () => {
      const key = btn.getAttribute("data-sort");
      if (!key) return;

      if (sortState.key === key) {
        sortState.dir = sortState.dir === "asc" ? "desc" : "asc";
      } else {
        sortState.key = key;
        sortState.dir = "desc";
      }

      updateSortIcons();
      // Re-render only; do NOT recompute highlight/window
      renderTable();
    });
  });
}

async function load() {
  const base = window.APP_CONFIG?.API_BASE_URL;

  if (!base || base === "REPLACE_ME") {
    setStatus("Config error: API URL not set (Terraform should set it).");
    if (apiUrlEl) apiUrlEl.textContent = "";
    return;
  }

  if (apiUrlEl) apiUrlEl.textContent = `${base}/movers`;

  setStatus("Loading…");
  clearTable();

  try {
    const res = await fetch(`${base}/movers`, { method: "GET" });
    if (!res.ok) {
      const txt = await res.text();
      throw new Error(`HTTP ${res.status}: ${txt}`);
    }

    const data = await res.json();
    if (!Array.isArray(data)) throw new Error("Unexpected response: not an array");

    lastData = data;

    updateLastRefreshed();

    if (data.length === 0) {
      setLoadedRangeStatus(data);
      if (highlightEl) highlightEl.textContent = "";
      return;
    }

    // Recompute highlight for the *window*, then render (which uses highlightKey)
    updateHighlight(lastData);

    updateSortIcons();
    renderTable();
    setLoadedRangeStatus(lastData);
  } catch (err) {
    setStatus(`Error: ${err.message}`);
  }
}

// Wire events only if the elements exist
if (refreshBtn) refreshBtn.addEventListener("click", load);

if (toggleDebugBtn && debugPanel) {
  toggleDebugBtn.addEventListener("click", () => {
    debugPanel.classList.toggle("hidden");
  });
}

wireHeaderSorting();
load();
