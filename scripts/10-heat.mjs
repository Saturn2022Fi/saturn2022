// The seller's blind spot, measured.
//
// The option house prices with a long-window volatility (290 rounds). That is
// the right anchor for a fair, hard-to-game number, but it is slow: when a feed
// starts updating faster than its own baseline, the market is heating and the
// long window has not caught up yet. A writer selling at the long-window price
// in that moment is handing the difference away.
//
// The signal costs nothing new. The publish threshold d is a feed constant, so
// short-window vol / long-window vol is just sqrt(longMeanGap / shortMeanGap):
// how much faster the last few rounds arrived than the baseline. Call it heat.
//
// The test: at each round, compute heat from the PAST only, then measure the
// REALIZED move over the next H rounds. If high heat precedes bigger forward
// moves, the signal tells a writer when the long-window price is too low.
//
//   node scripts/10-heat.mjs
import { readFileSync } from "node:fs";
import { table } from "./rpc.mjs";

const YEAR = 365.25 * 24 * 3600;
const MAX_GAP = 6 * 3600;
const SHORT = 12;     // rounds in the fast window
const LONG = 60;      // rounds in the baseline window
const FWD = 12;       // rounds ahead we measure the real move over

const data = JSON.parse(readFileSync(new URL("../out/rounds.json", import.meta.url)));

// same unit scrub as 09-validate
function scrub(rounds) {
  const prices = rounds.map((r) => r[1]).sort((a, b) => a - b);
  const mid = prices[Math.floor(prices.length / 2)];
  return rounds.filter((r) => r[1] > mid / 100 && r[1] < mid * 100);
}

const gap = (a, b) => Math.min(Math.max(b - a, 1), MAX_GAP);

// realized vol (textbook) over a slice of rounds, annualized by active time
function realized(slice) {
  let sumSq = 0, active = 0;
  for (let i = 1; i < slice.length; i++) {
    const r = Math.log(slice[i][1] / slice[i - 1][1]);
    sumSq += r * r;
    active += gap(slice[i - 1][0], slice[i][0]);
  }
  if (active <= 0) return 0;
  return Math.sqrt((sumSq / active) * YEAR);
}

// mean active gap over a slice
function meanGap(slice) {
  let active = 0, n = 0;
  for (let i = 1; i < slice.length; i++) { active += gap(slice[i - 1][0], slice[i][0]); n++; }
  return n ? active / n : 0;
}

const rows = [];
const pooled = [];   // {heat, fwd, base} across all feeds, for the buckets

for (const [ticker, { rounds: raw }] of Object.entries(data)) {
  const r = scrub(raw);
  if (r.length < LONG + FWD + 2) continue;

  let fired = 0, missWhenHot = 0, hotN = 0, missWhenCalm = 0, calmN = 0;

  for (let i = LONG; i + FWD < r.length; i++) {
    const longSlice = r.slice(i - LONG, i);
    const shortSlice = r.slice(i - SHORT, i);
    const gL = meanGap(longSlice), gS = meanGap(shortSlice);
    if (gL <= 0 || gS <= 0) continue;
    const heat = Math.sqrt(gL / gS);          // short vol / long vol via timing alone

    const base = realized(longSlice);          // ~what the long-window price charges
    const fwd = realized(r.slice(i, i + FWD));  // what actually happened next
    if (base <= 0) continue;
    pooled.push({ heat, fwd, base });

    const hot = heat >= 1.3;
    if (hot) { hotN++; missWhenHot += Math.max(fwd - base, 0); fired++; }
    else { calmN++; missWhenCalm += Math.max(fwd - base, 0); }
  }

  if (hotN + calmN < 20) continue;
  rows.push({
    ticker,
    obs: hotN + calmN,
    "hot %": ((100 * hotN) / (hotN + calmN)).toFixed(0),
    "underprice when hot": ((missWhenHot / Math.max(hotN, 1)) * 100).toFixed(1) + "%",
    "underprice when calm": ((missWhenCalm / Math.max(calmN, 1)) * 100).toFixed(1) + "%",
  });
}

rows.sort((a, b) => parseFloat(b["underprice when hot"]) - parseFloat(a["underprice when hot"]));
console.log(table(rows));

// pooled buckets: does forward move rise with heat, while the charged base does not?
const buckets = [
  ["heat < 1.0 (cooling)", (h) => h < 1.0],
  ["1.0-1.3 (steady)", (h) => h >= 1.0 && h < 1.3],
  ["1.3-1.8 (warming)", (h) => h >= 1.3 && h < 1.8],
  ["heat >= 1.8 (hot)", (h) => h >= 1.8],
];
const brows = buckets.map(([label, f]) => {
  const g = pooled.filter((p) => f(p.heat));
  const m = (sel) => g.length ? g.reduce((s, p) => s + sel(p), 0) / g.length : 0;
  return {
    "heat bucket": label,
    n: g.length,
    "charged (long vol)": (m((p) => p.base) * 100).toFixed(1) + "%",
    "actual next move": (m((p) => p.fwd) * 100).toFixed(1) + "%",
    "gap the writer eats": (m((p) => Math.max(p.fwd - p.base, 0)) * 100).toFixed(1) + "%",
  };
});
console.log("\nPooled across every feed, split by how hot the tape was at the write moment:\n");
console.log(table(brows));
console.log(`\nSHORT ${SHORT} / LONG ${LONG} rounds, forward ${FWD} rounds. Heat = sqrt(longGap/shortGap),`);
console.log(`read from timestamps alone. If 'actual next move' climbs across the buckets while`);
console.log(`'charged' stays flat, the long-window price is systematically low exactly when it`);
console.log(`matters, and heat names the moment before it happens.`);
