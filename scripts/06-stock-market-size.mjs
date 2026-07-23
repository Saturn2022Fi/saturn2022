// How many people actually touch stocks on this chain, and for how much.
//
// The quote rail is easy to find and easy to over-read: it settles a few
// hundred thousand dollars a day across a few dozen addresses, which looks like
// a market nobody uses. The pools tell a different story, so both are counted
// here rather than one standing in for the whole.

import { rpc, call, hex, num, big, pool as par, getLogsChunked, table } from "./rpc.mjs";
import { STOCKS, CORE } from "./tokens.mjs";

const TRANSFER = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef";
const WINDOW = Number(process.argv[2] ?? 18_000);      // about half an hour
const head = num(await rpc("eth_blockNumber"));
const minutes = (WINDOW * 0.1007) / 60;

// Prices come from each token's Chainlink feed, which already carries the
// dividend multiplier, so a token count can be priced directly.
const FEEDS = {
  NVDA: "0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15",
  AAPL: "0x6B22A786bAa607d76728168703a39Ea9C99f2cD0",
  SPCX: "0xB265810950ba6c5C0Ff821c9963014a56fD8Bffb",
  TSLA: "0x4A1166a659A55625345e9515b32adECea5547C38",
  MSFT: "0x45C3C877C15E6BA2EBB19eA114Ea508d14C1Af2E",
  AMZN: "0xD5a1508ceD74c084eBf3cBe853e2C968fB2a651C",
  GOOGL: "0xF6f373a037c30F0e5010d854385cA89185AE638b",
  META: "0x7C38C00C30BEe9378381E7B6135d7283356D71b1",
  ORCL: "0x0e6a64a2B58A6693a531E6c555f3A5d042eEA844",
  PLTR: "0x820ABedFF239034956B7A9d2F0a331f9F075eB4c",
  INTC: "0x3f390C5C24628Ac7C489515402235FeAD71D1913",
  CRWV: "0xe1b3aABCAFAd1c94708dc1367dcfF8Aa4407487C",
  AMD: "0x943A29E7ae51A4798823ca9eEd2ed533B2A22C72",
  MU: "0x425EEFdCf05ed6526C3cE61Af99429A228a6d596",
  SNDK: "0xfb133Fa4B7b385802B693a293606682Df47109A3",
  USAR: "0x451B1295aA84FD6d6b58af1a5002eA1b1A1913A0",
  SPY: "0x319724394D3A0e3669269846abE664Cd621f9f6A",
};

const picked = Object.keys(FEEDS).filter((t) => STOCKS[t]);
const rows = [];
const everyone = new Set();
let totalUsd = 0, totalTransfers = 0;

for (const t of picked) {
  const [logs, fp] = await Promise.all([
    getLogsChunked({ address: STOCKS[t], topics: [TRANSFER] }, head - WINDOW, head),
    call(FEEDS[t], "0xfeaf968c").then((l) => Number(BigInt("0x" + l.slice(2).match(/.{64}/g)[1])) / 1e8),
  ]);
  const parties = new Set();
  let moved = 0n;
  for (const l of logs) {
    parties.add("0x" + l.topics[1].slice(26));
    parties.add("0x" + l.topics[2].slice(26));
    moved += big(l.data === "0x" ? "0x0" : l.data);
  }
  for (const p of parties) everyone.add(p);
  const usd = (Number(moved) / 1e18) * fp;
  totalUsd += usd; totalTransfers += logs.length;
  rows.push({ ticker: t, price: `$${fp.toFixed(2)}`, transfers: logs.length,
              addresses: parties.size, moved: `$${usd.toLocaleString(undefined, { maximumFractionDigits: 0 })}` });
}

console.log(`window ${WINDOW.toLocaleString()} blocks, about ${minutes.toFixed(0)} minutes\n`);
console.log(table(rows.sort((a, b) => b.transfers - a.transfers)));
const scale = 1440 / minutes;
console.log(`\ntotals in the window : ${totalTransfers.toLocaleString()} transfers, ${everyone.size.toLocaleString()} addresses, $${totalUsd.toLocaleString(undefined, { maximumFractionDigits: 0 })} moved`);
console.log(`same rate over a day : ${(totalTransfers * scale).toLocaleString(undefined, { maximumFractionDigits: 0 })} transfers, $${(totalUsd * scale).toLocaleString(undefined, { maximumFractionDigits: 0 })} moved`);
console.log(`\nMoved is gross: a swap through a pool is two transfers of the same`);
console.log(`stock in and out, so this counts flow rather than net buying.`);
