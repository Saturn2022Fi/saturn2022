// Each feed's publish threshold, measured from its own rounds.
//
// The volatility estimator scales linearly with this number, so borrowing one
// feed's threshold for another skews that asset's options by the ratio of the
// two thresholds, systematically, in a direction an informed buyer can farm.
// The threshold is not documented per feed, but it does not need to be: it is
// the median move between consecutive rounds, and the rounds are on chain.

import { rpc, call, pool, table } from "./rpc.mjs";

const FEEDS = {
  NVDA: "0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15",
  SPCX: "0xB265810950ba6c5C0Ff821c9963014a56fD8Bffb",
  AAPL: "0x6B22A786bAa607d76728168703a39Ea9C99f2cD0",
  MSFT: "0x45C3C877C15E6BA2EBB19eA114Ea508d14C1Af2E",
  TSLA: "0x4A1166a659A55625345e9515b32adECea5547C38",
  AMZN: "0xD5a1508ceD74c084eBf3cBe853e2C968fB2a651C",
  GOOGL: "0xF6f373a037c30F0e5010d854385cA89185AE638b",
  META: "0x7C38C00C30BEe9378381E7B6135d7283356D71b1",
  AMD: "0x943A29E7ae51A4798823ca9eEd2ed533B2A22C72",
  INTC: "0x3f390C5C24628Ac7C489515402235FeAD71D1913",
  MU: "0x425EEFdCf05ed6526C3cE61Af99429A228a6d596",
  ORCL: "0x0e6a64a2B58A6693a531E6c555f3A5d042eEA844",
  PLTR: "0x820ABedFF239034956B7A9d2F0a331f9F075eB4c",
  SNDK: "0xfb133Fa4B7b385802B693a293606682Df47109A3",
  CRWV: "0xe1b3aABCAFAd1c94708dc1367dcfF8Aa4407487C",
  USAR: "0x451B1295aA84FD6d6b58af1a5002eA1b1A1913A0",
  SPY: "0x319724394D3A0e3669269846abE664Cd621f9f6A",
};

const LATEST = "0xfeaf968c";   // latestRoundData()
const ROUND = "0x9a6fc8f5";    // getRoundData(uint80)
const N = 60;                  // rounds per feed

function words(hex) { return hex.slice(2).match(/.{64}/g); }
function signed(h) { const v = BigInt("0x" + h); return v >= 1n << 255n ? v - (1n << 256n) : v; }

const rows = [];
for (const [ticker, feed] of Object.entries(FEEDS)) {
  const latest = words(await call(feed, LATEST));
  const latestId = BigInt("0x" + latest[0]);
  const ids = Array.from({ length: N }, (_, i) => latestId - BigInt(N - 1 - i));
  const rounds = (await pool(ids, async (id) => {
    try {
      const w = words(await call(feed, ROUND, id.toString(16).padStart(64, "0")));
      return { p: Number(signed(w[1])) / 1e8, t: Number(BigInt("0x" + w[3])) };
    } catch { return null; }
  }, 12)).filter((r) => r && r.p > 0 && r.t > 0);

  const moves = [];
  for (let i = 1; i < rounds.length; i++) {
    const m = Math.abs(Math.log(rounds[i].p / rounds[i - 1].p));
    if (m > 0) moves.push(m);
  }
  moves.sort((a, b) => a - b);
  const med = moves[Math.floor(moves.length / 2)] ?? 0;
  rows.push({
    ticker,
    rounds: rounds.length,
    "median move": (med * 100).toFixed(4) + "%",
    "deviation (1e18)": Math.round(med * 1e18).toString(),
  });
}

console.log(table(rows));
console.log("\nThe estimator scales linearly with this figure. A market deployed with a");
console.log("borrowed threshold misprices by the ratio of the real one to the borrowed one.");
