// The dataset behind the claim: every round every listed feed has published.
//
// A deviation-threshold oracle publishes when the price has moved a fixed step
// and not before, which makes its update times a record of how fast the price
// has been moving. This pulls that record in full, so the estimator can be
// checked against the realized volatility computed from the very same rounds
// rather than against a number quoted somewhere else.
//
//   node scripts/08-dataset.mjs [roundsPerFeed]   → out/rounds.json

import { rpc, call, pool } from "./rpc.mjs";
import { writeFileSync, mkdirSync } from "node:fs";

const LATEST = "0xfeaf968c";
const ROUND = "0x9a6fc8f5";
const WANT = Number(process.argv[2] ?? 100000);

const FEEDS = {
  SPCX: "0xB265810950ba6c5C0Ff821c9963014a56fD8Bffb",
  NVDA: "0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15",
  TSLA: "0x4A1166a659A55625345e9515b32adECea5547C38",
  AAPL: "0x6B22A786bAa607d76728168703a39Ea9C99f2cD0",
  MSFT: "0x45C3C877C15E6BA2EBB19eA114Ea508d14C1Af2E",
  META: "0x7C38C00C30BEe9378381E7B6135d7283356D71b1",
  GOOGL: "0xF6f373a037c30F0e5010d854385cA89185AE638b",
  AMZN: "0xD5a1508ceD74c084eBf3cBe853e2C968fB2a651C",
  MU: "0x425EEFdCf05ed6526C3cE61Af99429A228a6d596",
  PLTR: "0x820ABedFF239034956B7A9d2F0a331f9F075eB4c",
  AMD: "0x943A29E7ae51A4798823ca9eEd2ed533B2A22C72",
  INTC: "0x3f390C5C24628Ac7C489515402235FeAD71D1913",
  ORCL: "0x0e6a64a2B58A6693a531E6c555f3A5d042eEA844",
  SNDK: "0xfb133Fa4B7b385802B693a293606682Df47109A3",
  CRWV: "0xe1b3aABCAFAd1c94708dc1367dcfF8Aa4407487C",
  USAR: "0x451B1295aA84FD6d6b58af1a5002eA1b1A1913A0",
  SPY: "0x319724394D3A0e3669269846abE664Cd621f9f6A",
  SLV: "0x209b73908e92Ae021826eD79609845451Ecba2ce",
};

const w = (h) => h.slice(2).match(/.{64}/g);
const signed = (h) => { const v = BigInt("0x" + h); return v >= 1n << 255n ? v - (1n << 256n) : v; };

const out = {};
for (const [ticker, feed] of Object.entries(FEEDS)) {
  const L = w(await call(feed, LATEST));
  const latestId = BigInt("0x" + L[0]);
  const phase = latestId >> 64n;
  const n = latestId - (phase << 64n);              // rounds in this phase
  const take = n < BigInt(WANT) ? n : BigInt(WANT);
  const first = n - take + 1n;

  const ids = [];
  for (let r = first; r <= n; r++) ids.push((phase << 64n) + r);

  const rows = (await pool(ids, async (id) => {
    try {
      const r = w(await call(feed, ROUND, id.toString(16).padStart(64, "0")));
      const p = Number(signed(r[1])) / 1e8;
      const t = Number(BigInt("0x" + r[3]));
      return p > 0 && t > 0 ? [t, p] : null;
    } catch { return null; }
  }, 16)).filter(Boolean).sort((a, b) => a[0] - b[0]);

  out[ticker] = { feed, phase: Number(phase), rounds: rows };
  const days = rows.length > 1 ? (rows.at(-1)[0] - rows[0][0]) / 86400 : 0;
  console.log(`${ticker.padEnd(6)} ${String(rows.length).padStart(5)} rounds over ${days.toFixed(1).padStart(5)} days`);
}

mkdirSync(new URL("../out/", import.meta.url), { recursive: true });
const path = new URL("../out/rounds.json", import.meta.url);
writeFileSync(path, JSON.stringify(out));
console.log(`\nwritten to out/rounds.json`);
