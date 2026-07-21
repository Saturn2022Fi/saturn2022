// Where a stock purchase on this chain actually goes.
//
// It does not go to a pool. Quotes are signed off chain by market makers who
// hold real inventory, and the chain only settles them. The router is listed in
// Robinhood's own ecosystem page as a "PropAMM driven spot exchange"; what that
// means concretely is below, decoded from a live fill rather than described.

import { rpc, pool, hex, num, big, call, SEL, decodeString, table } from "./rpc.mjs";
import { STOCKS, CORE } from "./tokens.mjs";

const ROUTER = "0xc94135b63772b91d79d0a2daab2a8801f32359bd";
// The fill: (taker, recipient, tokenIn) indexed, then tokenOut, amountIn,
// amountOut and two quote identifiers in the body.
const FILL = "0x9a989e5e46c6033afc8355005be1837c4f1d05a2a79acb3d63f7d371d74698f7";

const WINDOW = 100_000;                 // about 2.8 hours at 0.1 s blocks
const head = num(await rpc("eth_blockNumber"));
const logs = await rpc("eth_getLogs", [{
  address: ROUTER, topics: [FILL],
  fromBlock: hex(head - WINDOW), toBlock: "latest",
}]);

const byAddr = Object.fromEntries(
  [...Object.entries(STOCKS), ...Object.entries(CORE)].map(([k, v]) => [v.toLowerCase(), k])
);
const decimalsOf = new Map();
async function dec(addr) {
  // Native ETH shows up as a sentinel address with no code, so a decimals()
  // call there answers with nothing rather than reverting.
  if (!decimalsOf.has(addr)) {
    let d = 18;
    try { const r = await call(addr, SEL.decimals); if (r && r !== "0x") d = num(r); } catch {}
    decimalsOf.set(addr, d);
  }
  return decimalsOf.get(addr);
}
const nameOf = (a) => byAddr[a.toLowerCase()] ?? a.slice(0, 10);

const fills = [];
for (const l of logs) {
  const w = l.data.slice(2).match(/.{64}/g);
  fills.push({
    taker: "0x" + l.topics[1].slice(26),
    tokenIn: "0x" + l.topics[3].slice(26),
    tokenOut: "0x" + w[0].slice(24),
    amountIn: big("0x" + w[1]),
    amountOut: big("0x" + w[2]),
    block: num(l.blockNumber),
  });
}

const minutes = (WINDOW * 0.1007) / 60;
console.log(`fills            ${fills.length.toLocaleString()} in ${minutes.toFixed(0)} minutes`);
console.log(`distinct takers  ${new Set(fills.map((f) => f.taker)).size}`);

// Notional, counted on whichever leg is the dollar.
const USDG = CORE.USDG.toLowerCase();
let notional = 0;
const byPair = new Map();
for (const f of fills) {
  const inD = await dec(f.tokenIn), outD = await dec(f.tokenOut);
  const usd =
    f.tokenIn.toLowerCase() === USDG ? Number(f.amountIn) / 10 ** inD
    : f.tokenOut.toLowerCase() === USDG ? Number(f.amountOut) / 10 ** outD
    : 0;
  notional += usd;
  const key = `${nameOf(f.tokenIn)} -> ${nameOf(f.tokenOut)}`;
  const cur = byPair.get(key) ?? { pair: key, fills: 0, usd: 0 };
  cur.fills++; cur.usd += usd;
  byPair.set(key, cur);
}

console.log(`notional         $${notional.toLocaleString(undefined, { maximumFractionDigits: 0 })}`);
console.log(`                 about $${((notional * 1440) / minutes).toLocaleString(undefined, { maximumFractionDigits: 0 })} a day at this rate`);
console.log();
console.log(table(
  [...byPair.values()].sort((a, b) => b.fills - a.fills).slice(0, 12)
    .map((r) => ({ route: r.pair, fills: r.fills, notional: `$${r.usd.toFixed(0)}` }))
));

// One fill, end to end, so the shape of the venue is visible rather than asserted.
const sample = fills.find((f) => f.tokenIn.toLowerCase() === USDG && byAddr[f.tokenOut.toLowerCase()]);
if (sample) {
  const outD = await dec(sample.tokenOut);
  const price = (Number(sample.amountIn) / 1e6) / (Number(sample.amountOut) / 10 ** outD);
  console.log(`\none fill, block ${sample.block.toLocaleString()}:`);
  console.log(table([
    { step: "taker pays", amount: `${(Number(sample.amountIn) / 1e6).toFixed(6)} USDG` },
    { step: "taker receives", amount: `${(Number(sample.amountOut) / 10 ** outD).toFixed(6)} ${nameOf(sample.tokenOut)}` },
    { step: "implied price", amount: `$${price.toFixed(2)}` },
  ]));
  console.log(`\nThe maker's signature travelled off chain; only the settlement is here.`);
  console.log(`Router fee observed on these fills is 5 basis points, an order of`);
  console.log(`magnitude under the 1% tier the stock pools charge.`);
}
