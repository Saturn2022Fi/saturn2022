// The estimator against the truth, computed from the same rounds.
//
// The comparison that matters is not against a quoted implied volatility, which
// prices the future and carries a risk premium besides. It is against the
// realized volatility of the very same price path: if counting timestamps
// recovers what the prices themselves say, the method works, and any remaining
// distance to an option market is economics rather than error.
//
// Three estimators run over each feed's history:
//
//   realized   the textbook figure, sum of squared log returns, annualized by
//              the span. This is the target.
//   weighted   each squared return divided by its own interval. The obvious
//              thing to do with irregular samples, and wrong here, because the
//              sampling is triggered by the returns themselves.
//   passage    Cho and Frees (1988): d * sqrt(year / mean interval), where d is
//              the feed's publish threshold. Reads no prices at all.
//
//   node scripts/09-validate.mjs [maxGapHours]

import { readFileSync } from "node:fs";
import { table } from "./rpc.mjs";

const YEAR = 365.25 * 24 * 3600;
const MAX_GAP = Number(process.argv[2] ?? 6) * 3600;

const data = JSON.parse(readFileSync(new URL("../out/rounds.json", import.meta.url)));

/// A feed's own history is not always in one unit.
///
/// The S&P feed's earliest rounds answer at eighteen decimals where every later
/// round answers at eight, so read straight through they show a price of
/// seventy-three billion dollars falling to seven hundred, and a realized
/// volatility of 7,812%. It is a real property of the data rather than a bug in
/// the reading, and any consumer walking round history will meet it.
///
/// Rounds more than a factor of a hundred away from the feed's median price are
/// dropped as a different unit, and how many were dropped is reported rather
/// than quietly absorbed.
function scrub(rounds) {
  const prices = rounds.map((r) => r[1]).sort((a, b) => a - b);
  const mid = prices[Math.floor(prices.length / 2)];
  const kept = rounds.filter((r) => r[1] > mid / 100 && r[1] < mid * 100);
  return { kept, dropped: rounds.length - kept.length };
}

const rows = [];
let totalDropped = 0;
for (const [ticker, { rounds: raw }] of Object.entries(data)) {
  const { kept: rounds, dropped } = scrub(raw);
  totalDropped += dropped;
  if (dropped) console.log(`note: ${ticker} dropped ${dropped} round(s) published in a different unit`);
  if (rounds.length < 30) continue;

  const rets = [], gaps = [], active = [];
  for (let i = 1; i < rounds.length; i++) {
    const dt = rounds[i][0] - rounds[i - 1][0];
    if (dt <= 0) continue;
    rets.push(Math.log(rounds[i][1] / rounds[i - 1][1]));
    gaps.push(dt);
    active.push(Math.min(dt, MAX_GAP));
  }
  const n = rets.length;
  const activeTotal = active.reduce((s, g) => s + g, 0);

  // realized: the prices' own answer, over the time the market was open
  const sumSq = rets.reduce((s, r) => s + r * r, 0);
  const realized = Math.sqrt((sumSq / activeTotal) * YEAR);

  // weighted: the plausible mistake
  const weighted = Math.sqrt((rets.reduce((s, r, i) => s + (r * r) / active[i], 0) / n) * YEAR);

  // passage: threshold and timestamps only, no prices
  //
  // d is the feed's publish threshold, and it has to be inferred, which is the
  // one place prices enter and the one place bias can. A round appears once the
  // move has *passed* d, so every observed move is d plus an overshoot: the
  // median absolute return reads high. A low quantile sits nearer the barrier
  // itself, because the moves that only just triggered a publish are the ones
  // that overshot least. Both are computed so the difference is visible rather
  // than assumed.
  const absSorted = rets.map(Math.abs).sort((a, b) => a - b);
  const q = (f) => absSorted[Math.floor(absSorted.length * f)];
  const dMed = q(0.5);
  const dLow = q(0.1);
  const meanDt = activeTotal / n;
  const passage = dMed * Math.sqrt(YEAR / meanDt);
  const passageLow = dLow * Math.sqrt(YEAR / meanDt);

  rows.push({
    ticker,
    rounds: n + 1,
    dropped,
    days: ((rounds.at(-1)[0] - rounds[0][0]) / 86400).toFixed(0),
    "d med %": (dMed * 100).toFixed(4),
    "d p10 %": (dLow * 100).toFixed(4),
    "realized %": (realized * 100).toFixed(1),
    "passage %": (passage * 100).toFixed(1),
    "pass/real": (passage / realized).toFixed(3),
    "p10/real": (passageLow / realized).toFixed(3),
    "weighted %": (weighted * 100).toFixed(0),
    "wtd/real": (weighted / realized).toFixed(1),
  });
}

rows.sort((a, b) => Number(a["realized %"]) - Number(b["realized %"]));
console.log(table(rows));

const ratios = rows.map((r) => Number(r["pass/real"]));
const low = rows.map((r) => Number(r["p10/real"]));
const wr = rows.map((r) => Number(r["wtd/real"]));
const mean = (a) => a.reduce((s, x) => s + x, 0) / a.length;
const sd = (a) => Math.sqrt(mean(a.map((x) => (x - mean(a)) ** 2)));
const med = (a) => [...a].sort((x, y) => x - y)[Math.floor(a.length / 2)];

console.log(`\npassage / realized   mean ${mean(ratios).toFixed(3)}  median ${med(ratios).toFixed(3)}  sd ${sd(ratios).toFixed(3)}  cv ${(sd(ratios) / mean(ratios)).toFixed(3)}`);
console.log(`with d at p10        mean ${mean(low).toFixed(3)}  median ${med(low).toFixed(3)}  sd ${sd(low).toFixed(3)}  cv ${(sd(low) / mean(low)).toFixed(3)}`);
console.log(`\nThe coefficient of variation is what decides this. A ratio that is stable`);
console.log(`across assets is a constant to divide out; one that wanders is not.`);
console.log(`weighted / realized  mean ${mean(wr).toFixed(1)}x  ${wr.filter((x) => x > 2).length} of ${wr.length} feeds off by more than 2x`);
console.log(`\nAgreement, not accuracy, is the claim: the passage estimator reads no prices,`);
console.log(`so a stable ratio to the realized figure is the thing worth having.`);
