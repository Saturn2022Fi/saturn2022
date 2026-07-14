// The whole toolkit. No dependencies, no keys, no account: every figure in this
// repository comes from public reads against a public endpoint, so anyone can
// run these and get the same numbers.

export const RPC = process.env.HOOD_RPC ?? "https://rpc.mainnet.chain.robinhood.com";
export const CHAIN_ID = 4663;

let id = 0;

export async function rpc(method, params = []) {
  const res = await fetch(RPC, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: ++id, method, params }),
  });
  const body = await res.json();
  if (body.error) throw new Error(`${method}: ${body.error.message}`);
  return body.result;
}

/** Several calls at once. The endpoint is fast but not infinitely parallel. */
export async function pool(items, worker, width = 8) {
  const out = new Array(items.length);
  let next = 0;
  await Promise.all(
    Array.from({ length: Math.min(width, items.length) }, async () => {
      while (true) {
        const i = next++;
        if (i >= items.length) return;
        out[i] = await worker(items[i], i);
      }
    })
  );
  return out;
}

export const hex = (n) => "0x" + BigInt(n).toString(16);
export const num = (h) => Number(BigInt(h));
export const big = (h) => BigInt(h);

/** eth_call against a signature, with no ABI library involved. */
export async function call(to, selector, argsHex = "", block = "latest") {
  return rpc("eth_call", [{ to, data: selector + argsHex }, block]);
}

export const SEL = {
  name: "0x06fdde03",
  symbol: "0x95d89b41",
  decimals: "0x313ce567",
  totalSupply: "0x18160ddd",
  balanceOf: "0x70a08231",
  // Robinhood Chain stock tokens carry these on top of ERC-20.
  uiMultiplier: "0xa60bf13d",
  balanceOfUI: "0x437a9958",
  totalSupplyUI: "0x9bea6429",
  newUIMultiplier: "0xdc767007",
  effectiveAt: "0x97a4064f",
  tokenPaused: "0x86c75e74",
  oraclePaused: "0x7706ba52",
  terms: "0xd5025625",
  uid: "0xf514ce36",
};

export const pad = (addr) => addr.toLowerCase().replace("0x", "").padStart(64, "0");

export function decodeString(hexData) {
  const h = hexData.slice(2);
  if (h.length < 128) return "";
  const len = parseInt(h.slice(64, 128), 16);
  return Buffer.from(h.slice(128, 128 + len * 2), "hex").toString("utf8");
}

/** 1e18 fixed point, printed with as many places as asked for. */
export function fmt18(v, places = 6) {
  const s = BigInt(v).toString().padStart(19, "0");
  const whole = s.slice(0, -18);
  const frac = s.slice(-18).slice(0, places);
  return `${whole}.${frac}`;
}

export function table(rows) {
  if (!rows.length) return "";
  const keys = Object.keys(rows[0]);
  const w = keys.map((k) => Math.max(k.length, ...rows.map((r) => String(r[k] ?? "").length)));
  const line = (cells) => cells.map((c, i) => String(c ?? "").padEnd(w[i])).join("  ");
  return [line(keys), line(w.map((n) => "-".repeat(n))), ...rows.map((r) => line(keys.map((k) => r[k])))].join("\n");
}
