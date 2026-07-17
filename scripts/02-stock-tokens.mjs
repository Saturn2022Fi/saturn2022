// What a Robinhood Chain stock token is, underneath.
//
// An ERC-20 with the ERC-8056 scaled-amount extension. A dividend does not move
// anyone's balance: it raises a multiplier, so one token comes to stand for more
// than one share while `balanceOf` reports the number it always did.
//
// The multiplier is for counting shares, not for pricing. The Chainlink feed
// already returns the multiplier-adjusted price of one token, so balance times
// feed price is right and applying the multiplier again counts the dividend
// twice.

import { rpc, call, SEL, num, big, decodeString, fmt18, table } from "./rpc.mjs";
import { STOCKS } from "./tokens.mjs";

const ONE = 10n ** 18n;

async function maybe(to, sel) {
  try { return await call(to, sel); } catch { return null; }
}

const rows = [];
for (const [ticker, addr] of Object.entries(STOCKS)) {
  const [m, nm, at, tp, op] = await Promise.all([
    maybe(addr, SEL.uiMultiplier),
    maybe(addr, SEL.newUIMultiplier),
    maybe(addr, SEL.effectiveAt),
    maybe(addr, SEL.tokenPaused),
    maybe(addr, SEL.oraclePaused),
  ]);
  if (m === null) { rows.push({ ticker, note: "no multiplier: not a stock token at this address" }); continue; }

  const mult = big(m);
  const paidOut = mult > ONE ? `+${(Number(mult - ONE) / 1e18 * 100).toFixed(4)}%` : "none yet";
  const pending = big(nm ?? m) > mult;
  rows.push({
    ticker,
    uiMultiplier: fmt18(mult, 18),
    "dividends so far": paidOut,
    "next one pending": pending ? `yes, at ${num(at)}` : "no",
    paused: big(tp ?? "0x0") ? "TOKEN PAUSED" : (big(op ?? "0x0") ? "oracle paused" : "no"),
  });
}
console.log(table(rows));

// The same fact, shown rather than described, on whichever token has paid most.
const withDiv = rows.filter((r) => r.uiMultiplier && r["dividends so far"] !== "none yet");
if (withDiv.length) {
  const t = withDiv.sort((a, b) => Number(b.uiMultiplier) - Number(a.uiMultiplier))[0].ticker;
  const addr = STOCKS[t];
  const supply = big(await call(addr, SEL.totalSupply));
  const supplyUI = big(await call(addr, SEL.totalSupplyUI));
  const gap = supplyUI - supply;
  console.log(`\nwhat the gap looks like on ${t}:`);
  console.log(table([
    { reads: "totalSupply()", answer: fmt18(supply), meaning: "tokens in existence" },
    { reads: "totalSupplyUI()", answer: fmt18(supplyUI), meaning: "shares they stand for" },
    { reads: "the difference", answer: fmt18(gap), meaning: "shares a plain ERC-20 read cannot see" },
  ]));
  console.log(`\nOne token stands for ${((Number(gap) / Number(supply)) * 100).toFixed(4)}% more than one share on ${t} today,`);
  console.log(`and more again after every dividend that follows. The feed price already`);
  console.log(`carries that; multiply by the multiplier as well and you count it twice.`);
}
