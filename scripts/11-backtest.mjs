// Does the vault actually earn? The premium against the upside it gives away.
//
// The vol comparisons in 10-heat are proxies. This is the economics itself:
// at every round in every feed's history, write a covered call exactly the way
// the house would price it (spot from the round, vol from the long window,
// strike 110%, Black-Scholes, a markup on top), then walk forward to expiry
// and hand over max(P - K, 0). Sum what the writer collected against what the
// writer gave away, per markup, per tenor.
//
// Assumes every written call gets bought, which is the neutral case: a real
// buyer picks their moments, so live results can only be worse than this by
// the buyer's skill, and the markup that merely breaks even here is a floor,
// not a target.
//
//   node scripts/11-backtest.mjs
import { readFileSync } from "node:fs";
import { table } from "./rpc.mjs";

const YEAR = 365.25 * 24 * 3600;
const MAX_GAP = 6 * 3600;
const LONG = 60;                    // rounds behind the vol estimate
const STRIKE = 1.10;                // the board's default, 110% of spot
const TENORS = [[ "1 day", 86400 ], ["3 days", 3 * 86400 ], ["7 days", 7 * 86400 ]];
const MARKUPS = [0, 1000, 2000, 3000, 5000];   // bps

const data = JSON.parse(readFileSync(new URL("../out/rounds.json", import.meta.url)));

function scrub(rounds) {
  const p = rounds.map((r) => r[1]).sort((a, b) => a - b);
  const mid = p[p.length >> 1];
  return rounds.filter((r) => r[1] > mid / 100 && r[1] < mid * 100);
}
const gap = (a, b) => Math.min(Math.max(b - a, 1), MAX_GAP);

// the long-window vol, same shape the chain charges (realized ~= calibrated passage)
function longVol(slice) {
  let q = 0, t = 0;
  for (let i = 1; i < slice.length; i++) {
    const r = Math.log(slice[i][1] / slice[i - 1][1]);
    q += r * r; t += gap(slice[i - 1][0], slice[i][0]);
  }
  return t > 0 ? Math.sqrt((q / t) * YEAR) : 0;
}

// N(x), Abramowitz-Stegun, plenty for cents
function cdf(x) {
  const t = 1 / (1 + 0.2316419 * Math.abs(x));
  const d = 0.3989422804014327 * Math.exp(-x * x / 2);
  let p = d * t * (0.31938153 + t * (-0.356563782 + t * (1.781477937 + t * (-1.821255978 + t * 1.330274429))));
  return x >= 0 ? 1 - p : p;
}
function bsCall(S, K, T, sigma) {
  if (T <= 0 || sigma <= 0) return Math.max(S - K, 0);
  const v = sigma * Math.sqrt(T);
  const d1 = (Math.log(S / K) + (sigma * sigma / 2) * T) / v;
  return S * cdf(d1) - K * cdf(d1 - v);
}

for (const [label, TEN] of TENORS) {
  const rows = [];
  const pooled = Object.fromEntries(MARKUPS.map((m) => [m, { prem: 0, give: 0, n: 0, wins: 0 }]));

  for (const [ticker, { rounds: raw }] of Object.entries(data)) {
    const r = scrub(raw);
    if (r.length < LONG + 10) continue;
    const agg = Object.fromEntries(MARKUPS.map((m) => [m, { prem: 0, give: 0, n: 0, wins: 0 }]));

    for (let i = LONG; i < r.length; i++) {
      const [t0, S] = r[i];
      // settlement: the last round at or before expiry, exactly like settle()
      let j = i;
      while (j + 1 < r.length && r[j + 1][0] <= t0 + TEN) j++;
      if (j === i || r[j][0] < t0 + TEN * 0.5) continue;   // not enough forward data
      const P = r[j][1];
      const sigma = longVol(r.slice(i - LONG, i));
      if (sigma <= 0) continue;
      const K = S * STRIKE;
      // T in years, active-time: charge the model for the time the market could move
      let activeT = 0;
      for (let k = i + 1; k <= j; k++) activeT += gap(r[k - 1][0], r[k][0]);
      const fair = bsCall(S, K, activeT / YEAR, sigma);
      const upside = Math.max(P - K, 0);
      for (const m of MARKUPS) {
        const premium = fair * (1 + m / 10_000);
        const a = agg[m];
        a.prem += premium / S; a.give += upside / S; a.n++;   // normalized per share
        if (premium >= upside) a.wins++;
      }
    }

    if (agg[0].n < 20) continue;
    for (const m of MARKUPS) {
      const a = agg[m], p = pooled[m];
      p.prem += a.prem; p.give += a.give; p.n += a.n; p.wins += a.wins;
    }
    const a0 = agg[0], a2 = agg[2000];
    rows.push({
      ticker, writes: a0.n,
      "P&L @0% (bps/share)": ((a0.prem - a0.give) / a0.n * 10_000).toFixed(1),
      "P&L @20%": ((a2.prem - a2.give) / a2.n * 10_000).toFixed(1),
      "win% @20": ((100 * a2.wins) / a2.n).toFixed(0),
    });
  }

  console.log(`\n=== tenor ${label}, strike 110% ===`);
  rows.sort((x, y) => Number(x["P&L @0% (bps/share)"]) - Number(y["P&L @0% (bps/share)"]));
  console.log(table(rows));
  console.log("pooled, per markup:");
  const prows = MARKUPS.map((m) => {
    const p = pooled[m];
    return {
      markup: (m / 100).toFixed(0) + "%",
      writes: p.n,
      "premiums (bps/share)": (p.prem / p.n * 10_000).toFixed(1),
      "upside given (bps)": (p.give / p.n * 10_000).toFixed(1),
      "net (bps/share)": ((p.prem - p.give) / p.n * 10_000).toFixed(1),
      "share of writes that win": ((100 * p.wins) / p.n).toFixed(0) + "%",
    };
  });
  console.log(table(prows));
}
console.log(`\nEvery write is assumed sold, overlapping windows are correlated samples, and`);
console.log(`the history is short. Ranks and signs are the finding; the third digit is not.`);
