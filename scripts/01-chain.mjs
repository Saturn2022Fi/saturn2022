// How fast the chain runs, and what a transaction on it actually costs.
//
// Both matter for design and neither is guessed here. Block time is measured
// across a real span rather than taken from a docs page, and the fee figures
// are the fees people actually paid, read out of receipts.

import { rpc, pool, hex, num, table } from "./rpc.mjs";

const SPAN = 20_000;      // blocks to measure the interval across
const SAMPLE = 60;        // blocks to pull receipts from
const STRIDE = 300;

const head = num(await rpc("eth_blockNumber"));
const a = await rpc("eth_getBlockByNumber", [hex(head - SPAN), false]);
const b = await rpc("eth_getBlockByNumber", [hex(head), false]);
const seconds = (num(b.timestamp) - num(a.timestamp)) / SPAN;

console.log(`chain id      ${num(await rpc("eth_chainId"))}`);
console.log(`head          ${head.toLocaleString()}`);
console.log(`block time    ${seconds.toFixed(4)} s   (${(1 / seconds).toFixed(1)} blocks per second)`);
console.log(`              measured across ${SPAN.toLocaleString()} blocks, not read off a docs page`);

const blocks = Array.from({ length: SAMPLE }, (_, i) => head - 30 - i * STRIDE);
const receipts = (await pool(blocks, (n) => rpc("eth_getBlockReceipts", [hex(n)]), 8)).flat();

const fees = [];
let failed = 0;
for (const r of receipts) {
  const gas = BigInt(r.gasUsed);
  if (gas === 0n) continue;
  fees.push(gas * BigInt(r.effectiveGasPrice));
  if (r.status === "0x0") failed++;
}
fees.sort((x, y) => (x < y ? -1 : x > y ? 1 : 0));

// Priced in ETH terms; the wei figure is the part that does not go stale.
const ETH = Number(process.env.ETH_USD ?? 2463.19);
const usd = (wei) => (Number(wei) / 1e18) * ETH;
const median = fees[Math.floor(fees.length / 2)];
const mean = fees.reduce((s, f) => s + f, 0n) / BigInt(fees.length);

console.log();
console.log(`transactions  ${receipts.length.toLocaleString()} across ${SAMPLE} blocks`);
console.log(`reverted      ${failed} of ${receipts.length}  (${((failed / receipts.length) * 100).toFixed(1)}%)`);
console.log();
console.log(table([
  { fee: "median", wei: median.toString(), usd: `$${usd(median).toFixed(6)}` },
  { fee: "mean", wei: mean.toString(), usd: `$${usd(mean).toFixed(6)}` },
  { fee: "cheapest", wei: fees[0].toString(), usd: `$${usd(fees[0]).toFixed(6)}` },
  { fee: "dearest", wei: fees.at(-1).toString(), usd: `$${usd(fees.at(-1)).toFixed(6)}` },
]));
console.log(`\nETH taken as $${ETH}. Override with ETH_USD to reprice.`);

// The figure that decides whether a design can afford to run on a timer.
const perTick = Number(median) / 1e18 * ETH;
console.log();
console.log("what a heartbeat would cost, at the median fee:");
console.log(table([
  { rate: "every block", perDay: `$${(perTick / seconds * 86400).toLocaleString(undefined, { maximumFractionDigits: 0 })}` },
  { rate: "once a second", perDay: `$${(perTick * 86400).toLocaleString(undefined, { maximumFractionDigits: 0 })}` },
  { rate: "once a minute", perDay: `$${(perTick * 1440).toFixed(2)}` },
  { rate: "once an hour", perDay: `$${(perTick * 24).toFixed(2)}` },
]));
