const statusEl = document.getElementById("status");
const tbodyEl = document.getElementById("tbody");
const refreshBtn = document.getElementById("refreshBtn");
const lastRefreshedEl = document.getElementById("lastRefreshed");
const highlightEl = document.getElementById("highlight");

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
  if (tbodyEl) tbodyEl.textContent = "";
}

function absVal(n) {
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

function makeTd(text, className) {
  const td = document.createElement("td");
  if (className) td.className = className;
  td.textContent = text ?? "";
  return td;
}

function addRow(item) {
  if (!tbodyEl) return;

  const tr = document.createElement("tr");

  const pct = Number(item.PercentChange);
  const pctClass = pct >= 0 ? "pos" : "neg";

  const tdDate = makeTd(item.Date ?? "");
  const tdTicker = makeTd(item.Ticker ?? "", "mono");
  const tdPct = makeTd(fmtPct(pct), pctClass);
  const tdClose = makeTd(fmtPrice(item.ClosingPrice), "right");

  // Strong color cue (optional)
  tdPct.style.color = pct >= 0 ? "#2ee59d" : "#ff5c7a";

  tr.appendChild(tdDate);
  tr.appendChild(tdTicker);
  tr.appendChild(tdPct);
  tr.appendChild(tdClose);

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
    if (key === "pct") return mul * (absVal(a.PercentChange) - absVal(b.PercentChange));

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
  const icons = Array.from(document.querySelectorAll(".sortIcon"));
  icons.forEach((el) => el.classList.remove("asc", "desc"));

  const active = document.querySelector(`.sortIcon[data-icon="${sortState.key}"]`);
  if (active) active.classList.add(sortState.dir === "asc" ? "asc" : "desc");
}

function updateHighlight(data) {
  highlightKey = null;

  if (!highlightEl) return;
  highlightEl.textContent = "";

  if (!Array.isArray(data) || data.length === 0) return;

  // Biggest absolute move in the window
  let best = data[0];
  let bestAbs = absVal(best.PercentChange);

  for (const item of data) {
    const v = absVal(item.PercentChange);
    if (v > bestAbs) {
      best = item;
      bestAbs = v;
    }
  }

  const pct = Number(best.PercentChange);
  const dir = pct >= 0 ? "up" : "down";
  highlightKey = makeRowKey(best);

  // Build highlight UI without innerHTML
  const prefix = document.createTextNode("Biggest move in this window: ");
  const tickerSpan = document.createElement("span");
  tickerSpan.className = "mono";
  tickerSpan.textContent = best.Ticker ?? "";

  const middle = document.createTextNode(` ${fmtPct(pct)} (${dir}) on `);

  const dateSpan = document.createElement("span");
  dateSpan.className = "mono";
  dateSpan.textContent = best.Date ?? "";

  highlightEl.appendChild(prefix);
  highlightEl.appendChild(tickerSpan);
  highlightEl.appendChild(middle);
  highlightEl.appendChild(dateSpan);
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
      renderTable();
    });
  });
}

async function load() {
  const base = window.APP_CONFIG?.API_BASE_URL;

  if (!base || base === "REPLACE_ME") {
    setStatus("Config error: API URL not set (Terraform should set it).");
    return;
  }

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

    updateHighlight(lastData);
    updateSortIcons();
    renderTable();
    setLoadedRangeStatus(lastData);
  } catch (err) {
    setStatus(`Error: ${err.message}`);
  }
}

if (refreshBtn) refreshBtn.addEventListener("click", load);

wireHeaderSorting();
load();
