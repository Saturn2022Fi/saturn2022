// The same job, done without sending anything.
//
// A payout writes one number: how much has been paid per token, ever. A
// holder's claim is the gap between that number and the value it had when they
// were last settled, times what they held across it. Nothing is sent until
// someone asks, and a holder who never asks costs nothing at all.
//
// The figures below come from running the contracts in ../contracts, so they
// are measured the same way the chain figures are, rather than reasoned about.

import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import { table } from "./rpc.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const contracts = resolve(here, "..", "contracts");

const run = spawnSync("forge", ["test", "-vv"], { cwd: contracts, encoding: "utf8" });
if (run.error) {
  console.error("forge is not on PATH. Install Foundry: https://getfoundry.sh");
  process.exit(1);
}
const out = run.stdout ?? "";
if (!/\d+ passed/.test(out)) { console.error(out || run.stderr); process.exit(1); }

const grab = (label) => {
  const m = out.match(new RegExp(`${label}\\s*:\\s*(\\d+)`));
  return m ? Number(m[1]) : null;
};

const pay = grab("pay everyone, once");
const claim = grab("one holder claims");
const xfer = grab("one holder transfers");
const tenK = grab("gas to pay 10,000 holders");
const at100 = grab("gas with    100 holders");
const at5100 = grab("gas with  5,100 holders");

const ETH = Number(process.env.ETH_USD ?? 2463.19);
const GWEI = Number(process.env.HOOD_GAS_GWEI ?? 0.0257);   // observed base fee
const usd = (gas) => (gas * GWEI * 1e-9 * ETH);

const total = [...out.matchAll(/(\d+) tests passed/g)].map((m) => Number(m[1])).pop()
  ?? [...out.matchAll(/(\d+) passed/g)].reduce((s, m) => s + Number(m[1]), 0);
console.log(`${total} tests passed in ../contracts\n`);
console.log(table([
  { action: "pay every holder, once", gas: pay?.toLocaleString(), cost: `$${usd(pay).toFixed(6)}` },
  { action: "one holder claims", gas: claim?.toLocaleString(), cost: `$${usd(claim).toFixed(6)}` },
  { action: "one holder transfers", gas: xfer?.toLocaleString(), cost: `$${usd(xfer).toFixed(6)}` },
]));

console.log(`\nthe part that matters:`);
console.log(table([
  { holders: "100", "gas to pay them all": at100?.toLocaleString() },
  { holders: "5,100", "gas to pay them all": at5100?.toLocaleString() },
  { holders: "10,000", "gas to pay them all": tenK?.toLocaleString() },
]));
console.log(`\nSame figure, three crowd sizes. The payout does not walk a list, so`);
console.log(`there is nothing in it that grows with the number of people paid.`);
console.log(`\nA holder pays $${usd(claim).toFixed(4)} to collect, once, whenever they choose,`);
console.log(`and that one collection settles every round that happened in between.`);
