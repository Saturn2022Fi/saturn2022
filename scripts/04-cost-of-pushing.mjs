// What it costs to hand assets to every holder by sending them.
//
// Point this at any contract that pays holders by transfer and it reads the
// receipts of a full round: how many transfers went out, how much gas they
// burned, and what that came to. The pattern is common and the cost is rarely
// looked at, because the gas leaves the treasury rather than the payout line.
//
//   node scripts/04-cost-of-pushing.mjs 0x<distributor> [windowBlocks]
//
// The cost grows with the holder count while the payout does not, so a project
// that succeeds at gathering holders pays more to reach each one.

import { rpc, pool, hex, num, big, table, getLogsChunked } from "./rpc.mjs";

const target = (process.argv[2] ?? "").toLowerCase();
if (!/^0x[0-9a-f]{40}$/.test(target)) {
  console.error("usage: node scripts/04-cost-of-pushing.mjs 0x<distributor> [windowBlocks]");
  process.exit(1);
}
const WINDOW = Number(process.argv[3] ?? 40_000);    // about an hour at 0.1 s blocks
const TRANSFER = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef";
const ETH = Number(process.env.ETH_USD ?? 2463.19);

const head = num(await rpc("eth_blockNumber"));
const from = head - WINDOW;

// Every transfer this address sent, whatever the asset.
const sent = await getLogsChunked(
  { topics: [TRANSFER, "0x" + target.slice(2).padStart(64, "0")] },
  from,
  head
);

if (!sent.length) {
  console.log("no transfers out of that address in the window; try a wider one");
  process.exit(0);
}

const blocks = [...new Set(sent.map((l) => num(l.blockNumber)))];
const receipts = (await pool(blocks, (n) => rpc("eth_getBlockReceipts", [hex(n)]), 8)).flat();

let gas = 0n, fee = 0n, txs = 0, logs = 0;
for (const r of receipts) {
  if ((r.to ?? "").toLowerCase() !== target) continue;
  txs++;
  gas += BigInt(r.gasUsed);
  fee += BigInt(r.gasUsed) * BigInt(r.effectiveGasPrice);
  logs += (r.logs ?? []).length;
}

const recipients = new Set(sent.map((l) => l.topics[2])).size;
const assets = new Set(sent.map((l) => l.address.toLowerCase())).size;
const usd = Number(fee) / 1e18 * ETH;

console.log(table([
  { measured: "window", value: `${WINDOW.toLocaleString()} blocks (~${((WINDOW * 0.1007) / 60).toFixed(0)} min)` },
  { measured: "transfers sent", value: sent.length.toLocaleString() },
  { measured: "distinct recipients", value: recipients.toLocaleString() },
  { measured: "distinct assets", value: assets.toLocaleString() },
  { measured: "transactions", value: txs.toLocaleString() },
  { measured: "event logs written", value: logs.toLocaleString() },
  { measured: "gas burned", value: gas.toLocaleString() },
  { measured: "cost", value: `$${usd.toFixed(2)}` },
]));

console.log();
console.log(`per recipient reached : $${(usd / Math.max(recipients, 1)).toFixed(5)}`);
console.log(`per day at this rate  : $${((usd * 1440) / ((WINDOW * 0.1007) / 60)).toFixed(2)}`);
console.log(`per year              : $${((usd * 525600) / ((WINDOW * 0.1007) / 60)).toLocaleString(undefined, { maximumFractionDigits: 0 })}`);
console.log();
console.log("Compare against scripts/05-cost-of-not-pushing.mjs, which does the");
console.log("same job with one storage write and no transfers at all.");
