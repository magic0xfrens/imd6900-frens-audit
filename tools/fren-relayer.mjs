#!/usr/bin/env node
// The frens relayer: gets each mint's frens built by the IMD swarm and revealed.
//
// For every open request on IMD6900Frens it
//   1. builds the request's job (tools/fren-job.mjs: five agents, only the traits its tier may take, nothing sold out),
//      gets IMD's quote, and pays it from the frens contract itself: the keeper sends approveJob, which approves exactly
//      this 0.50 $IMD Permit2 payment and IMD's quote approval for it, and IMD checks both through the contract's
//      ERC-1271 isValidSignature (the contract holds no key);
//   2. waits for the job; when it completes, reads the agents' card (artifacts/5-final/fren.json, its hash checked
//      against IMD's record) and takes, for each fren the request paid for (1 to 10, one job), the agents' own if the
//      contract would mint it for the request's tier, else a runner-up, else the nearest free variation, and
//   3. signs the reveal voucher (EIP-712, the contract's relayer key) and serves it: GET /voucher/<requestId>; anyone
//      sends it and the frens reveal (in parts for big requests);
//   4. pushes the floor: each mint buys its share into IMD6900 itself, stopping before it moves the price half the
//      pool's fee; what's left (and ETH from fees and royalties) this pushes, one buy a block. Anyone could; the arb
//      vault then closes the gap the buys open between the pools.
//
// The frens are minted at once; a job that fails or never lands reveals nothing and refunds nothing. Someone (a holder,
// usually) pays another job with retryJob, and the next pass posts it.
//
//   node tools/fren-relayer.mjs             run: watch, post jobs, sign vouchers, serve them
//   node tools/fren-relayer.mjs --once      one pass, then exit
//   node tools/fren-relayer.mjs --dry       one pass that builds and quotes jobs but signs and sends nothing
//   node tools/fren-relayer.mjs --status    print what it knows
//   --fork: on a local fork, stops after approveJob (IMD can't settle a payment from a contract mainnet doesn't have)
//
// Env: FRENS (the contract), ETH_RPC_URL, IMD_API (https://api.imd.fun), IMD_PAID_TOKEN (64 hex: names its orders),
//      KEEPER_KEY (the contract's keeper: sends approveJob, needs gas ETH), RELAYER_KEY (the contract's relayer: signs
//      vouchers, holds nothing), KEEPER_RPC (https://rpc.mevblocker.io: its transactions stay private), STATE_FILE (~/.config/imd/fren-relayer.json), PORT (8787; 0 = don't serve),
//      EVERY (30 seconds), INDEXER. Keys are never printed.
import { createHash, randomBytes } from "node:crypto";
import { mkdirSync, readFileSync, renameSync, writeFileSync, existsSync } from "node:fs";
import { createServer } from "node:http";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import {
  createPublicClient, createWalletClient, getAddress, hashTypedData, http, keccak256, toBytes, isAddressEqual,
} from "viem";
import { mainnet } from "viem/chains";
import { privateKeyToAccount } from "viem/accounts";
import { buildJob, readRules, readCard, traitsOf, comboOf, TRAITS, CARD, INDEXER } from "./fren-job.mjs";

const argv = process.argv.slice(2);
const flag = (k) => argv.includes(`--${k}`);
const ONCE = flag("once") || flag("dry"), DRY = flag("dry"), FORK = flag("fork");
const die = (m) => { console.error(m); process.exit(1); };
const log = (...a) => console.log(new Date().toISOString().slice(0, 19), ...a);

const FRENS = getAddress(process.env.FRENS || die("set FRENS to the IMD6900Frens address"));
const RPC = process.env.ETH_RPC_URL || "https://ethereum-rpc.publicnode.com";
const API = (process.env.IMD_API || "https://api.imd.fun").replace(/\/$/, "");
const STATE_FILE = process.env.STATE_FILE || join(homedir(), ".config/imd/fren-relayer.json");
const PORT = Number(process.env.PORT ?? 8787);
const EVERY = Number(process.env.EVERY || 30) * 1000;
const X402_PROXY = "0x402085c248EeA27D92E8b30b2C58ed07f9E20001";
const PERMIT2 = "0x000000000022D473030F116dDEE9F6B43aC78BA3";
const JOB_PRICE = 500000000000000000n;
const NO_KEY_SIG = "0x" + "00".repeat(65); // the contract ignores the bytes; some schemas want 65
const VOUCHER_DAYS = 7; // a voucher's life; re-signed when less than a day is left
const PART = 30; // frens per reveal transaction (~4.3M gas)

const pub = createPublicClient({ chain: mainnet, transport: http(RPC), batch: { multicall: true } });
const keyed = (name) => {
  const k = process.env[name] || "";
  if (!/^(0x)?[0-9a-fA-F]{64}$/.test(k)) return null;
  return privateKeyToAccount(k.startsWith("0x") ? k : `0x${k}`);
};
const keeper = keyed("KEEPER_KEY"), relayer = keyed("RELAYER_KEY");
// the keeper's transactions go to a private RPC: a floor buy seen in the public mempool could be sandwiched
const SEND_RPC = FORK ? RPC : process.env.KEEPER_RPC || "https://rpc.mevblocker.io";
const keeperWallet = keeper && createWalletClient({ account: keeper, chain: mainnet, transport: http(SEND_RPC) });

// ── the contract ────────────────────────────────────────────────────────────
const u = (name) => ({ name, type: "uint256" });
const QUOTE = { type: "tuple", components: [
  { name: "resource", type: "string" }, { name: "requesterScopeHash", type: "bytes32" }, { name: "quoteId", type: "string" },
  { name: "quoteHash", type: "bytes32" }, { name: "paymentHash", type: "bytes32" }, { name: "action", type: "string" }, u("expiresAt"),
] };
const ABI = [
  { type: "function", name: "nextRequestId", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "comboOf", stateMutability: "view", inputs: [{ type: "uint256" }], outputs: [{ type: "uint24" }] },
  { type: "function", name: "keeper", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { type: "function", name: "relayer", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { type: "function", name: "imd", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { type: "function", name: "imdPayTo", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { type: "function", name: "requests", stateMutability: "view", inputs: [{ type: "uint256" }], outputs: [
    { name: "minter", type: "address" }, { name: "tier", type: "uint8" }, { name: "lowTier", type: "bool" }, { name: "jobApproved", type: "bool" },
    { name: "count", type: "uint8" }, { name: "revealed", type: "uint8" }, { name: "jobs", type: "uint8" }, { name: "firstToken", type: "uint32" },
    { name: "jobDeadline", type: "uint40" }, u("jobNonce")] },
  { type: "function", name: "openLowTier", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "tierOf", stateMutability: "view", inputs: [{ type: "address" }], outputs: [{ type: "uint8" }] },
  { type: "function", name: "check", stateMutability: "view", inputs: [{ type: "uint24" }, { type: "uint8" }], outputs: [{ type: "uint8" }] },
  { type: "function", name: "voucherDigest", stateMutability: "view", inputs: [u("requestId"), { type: "uint24[]" }, { type: "string" }, { type: "bytes32" }, u("deadline")], outputs: [{ type: "bytes32" }] },
  { type: "function", name: "approveJob", stateMutability: "nonpayable", inputs: [u("requestId"), u("nonce"), u("deadline"), QUOTE], outputs: [{ type: "bytes32" }, { type: "bytes32" }] },
  ...["floorImd", "maxImdPerBuy", "maxEthPerBuy", "lastFloorBuyBlock", "buyDelayBlocks"].map((name) => ({ type: "function", name, stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] })),
  { type: "function", name: "buyFloor", stateMutability: "nonpayable", inputs: [u("minOut")], outputs: [] },
  { type: "function", name: "buyFloorWithEth", stateMutability: "nonpayable", inputs: [u("ethIn"), u("minOut")], outputs: [] },
  { type: "function", name: "unwrapWeth", stateMutability: "nonpayable", inputs: [], outputs: [u("amount")] },
];
const WETH = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2";
const read = (functionName, args = []) => pub.readContract({ address: FRENS, abi: ABI, functionName, args });
/** Whether IMD took the contract's payment with this Permit2 nonce */
const spent = async (nonce) => {
  const word = await pub.readContract({
    address: PERMIT2, functionName: "nonceBitmap", args: [FRENS, BigInt(nonce) >> 8n],
    abi: [{ type: "function", name: "nonceBitmap", stateMutability: "view", inputs: [{ type: "address" }, { type: "uint256" }], outputs: [{ type: "uint256" }] }],
  });
  return (word >> (BigInt(nonce) & 255n)) & 1n ? true : false;
};

// ── state: one JSON file, written whole ─────────────────────────────────────
let state = existsSync(STATE_FILE) ? JSON.parse(readFileSync(STATE_FILE, "utf8")) : { frens: FRENS, cursor: 1, requests: {} };
if (state.frens !== FRENS) die(`${STATE_FILE} belongs to ${state.frens}; set STATE_FILE for ${FRENS}`);
const save = () => {
  mkdirSync(dirname(STATE_FILE), { recursive: true });
  writeFileSync(STATE_FILE + ".tmp", JSON.stringify(state, null, 1));
  renameSync(STATE_FILE + ".tmp", STATE_FILE);
};
const entry = (id) => (state.requests[id] ??= { status: "new" });
const note = (id, patch) => { Object.assign(entry(id), patch, { updatedAt: new Date().toISOString() }); save(); };

// ── IMD's canonical JSON and hash (as tools/post-imd-job.mjs, checked against live challenges) ─────
const canon = (v) => {
  if (v === null) return "null";
  switch (typeof v) {
    case "boolean": return v ? "true" : "false";
    case "number":
      if (!Number.isInteger(v)) throw new Error("cannot canonicalize a non-integer number");
      return JSON.stringify(v === 0 ? 0 : v);
    case "string": return JSON.stringify(v);
    case "object":
      if (Array.isArray(v)) return `[${v.map(canon).join(",")}]`;
      return `{${Object.keys(v).sort().map((k) => {
        if (v[k] === undefined) throw new Error(`cannot canonicalize undefined at ${k}`);
        return `${JSON.stringify(k)}:${canon(v[k])}`;
      }).join(",")}}`;
    default: throw new Error(`cannot canonicalize a ${typeof v}`);
  }
};
const hashOf = (v) => createHash("sha256").update(Buffer.from(canon(v), "utf8")).digest("hex");
const sha256 = (b) => createHash("sha256").update(b).digest("hex");

const token = process.env.IMD_PAID_TOKEN ?? "";
const auth = { Authorization: `Bearer ${token}` };
const api = async (path, init = {}) => {
  const r = await fetch(`${API}${path}`, { ...init, headers: { ...auth, ...(init.headers ?? {}) }, signal: AbortSignal.timeout(30_000) });
  return { status: r.status, ok: r.ok, headers: r.headers, body: await r.json().catch(() => ({})) };
};
// one stable requestKey per request: a restart quotes the same order rather than a second one
const requestKey = (id, attempt = 1) => {
  const h = sha256(`imd6900-frens:${FRENS.toLowerCase()}:${id}${attempt > 1 ? `:${attempt}` : ""}`);
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-5${h.slice(13, 16)}-a${h.slice(17, 20)}-${h.slice(20, 32)}`;
};

// ── 1. post a request's job, paid by the contract ───────────────────────────
async function postJob(id, r, ctx) {
  const rules = await readRules(pub, FRENS);
  const input = buildJob({ request: id, tier: r.tier, count: r.count, rules });
  const body = { requestKey: requestKey(id, entry(id).attempt ?? 1), action: "job.open", input };
  const q = await api("/requests/quote", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });
  if (!q.ok) throw new Error(`quote refused: HTTP ${q.status} ${JSON.stringify(q.body).slice(0, 300)}`);
  const order = q.body.order;
  note(id, { status: "quoted", orderId: order.id });
  log(`#${id}: quoted order ${order.id} (tier ${r.tier}, ${r.count} fren${r.count > 1 ? "s" : ""})`);
  if (DRY) return;

  const c = await api(`/requests/${order.id}/submit`, { method: "POST" });
  const ch = c.body;
  if (c.status !== 402) throw new Error(`expected the 402 payment challenge, got HTTP ${c.status}`);
  // the challenge must be this order, this work, this credential, and exactly 0.50 $IMD to IMD's payee
  const offer = ch.accepts?.[0], cq = ch.quote ?? {}, qp = cq.payment ?? {};
  const { quoteHash, ...quoteRest } = cq;
  const refuse = (what) => { throw new Error(`payment details changed (${what}); nothing approved`); };
  if (canon(cq) !== canon(order.quote)) refuse("quote");
  if (quoteHash !== hashOf({ domain: "identitymd.paid-action-quote", ...quoteRest })) refuse("quote hash");
  if (hashOf(ch.input) !== cq.inputHash) refuse("work");
  const scope = hashOf({ domain: "identitymd.paid-requester", scope: `paid-client:${hashOf({ domain: "identitymd.paid-http-client", token })}` });
  if (ch.requesterScopeHash !== scope) refuse("credential");
  if (ch.x402Version !== 2 || ch.accepts?.length !== 1 || !offer || offer.scheme !== "exact" || offer.network !== "eip155:1") refuse("version");
  if (offer.network !== qp.network || !isAddressEqual(offer.asset, qp.asset) || !isAddressEqual(offer.payTo, qp.payTo) || offer.amount !== qp.amount) refuse("advertised price");
  if (BigInt(offer.amount) !== JOB_PRICE || !isAddressEqual(offer.asset, ctx.imd) || !isAddressEqual(offer.payTo, ctx.imdPayTo)) {
    refuse(`price or payee: ${offer.amount} of ${offer.asset} to ${offer.payTo}; the contract pays ${JOB_PRICE} of ${ctx.imd} to ${ctx.imdPayTo}`);
  }

  // the payment the contract will "sign": the x402 exact scheme's Permit2 transfer, from the contract
  const now = Math.floor(Date.now() / 1000);
  const left = cq.expiresAt - now - 30;
  if (left < 90) throw new Error("the quote is too close to expiry");
  const nonce = BigInt("0x" + randomBytes(32).toString("hex"));
  const deadline = now + Math.min(offer.maxTimeoutSeconds, left, 3000);
  const permit2Authorization = {
    from: FRENS,
    permitted: { token: getAddress(offer.asset), amount: offer.amount },
    spender: X402_PROXY,
    nonce: nonce.toString(),
    deadline: String(deadline),
    witness: { to: getAddress(offer.payTo), validAfter: "0" },
  };
  const payment = JSON.parse(JSON.stringify({ x402Version: 2, payload: { signature: NO_KEY_SIG, permit2Authorization }, resource: ch.resource, accepted: offer }));
  const permitDigest = hashTypedData({
    domain: { name: "Permit2", chainId: 1, verifyingContract: PERMIT2 },
    primaryType: "PermitWitnessTransferFrom",
    types: {
      PermitWitnessTransferFrom: [{ name: "permitted", type: "TokenPermissions" }, { name: "spender", type: "address" }, u("nonce"), u("deadline"), { name: "witness", type: "Witness" }],
      TokenPermissions: [{ name: "token", type: "address" }, { name: "amount", type: "uint256" }],
      Witness: [{ name: "to", type: "address" }, { name: "validAfter", type: "uint256" }],
    },
    message: { permitted: { token: getAddress(offer.asset), amount: JOB_PRICE }, spender: X402_PROXY, nonce, deadline: BigInt(deadline), witness: { to: getAddress(offer.payTo), validAfter: 0n } },
  });
  const quote = {
    resource: ch.resourceUrl, requesterScopeHash: `0x${ch.requesterScopeHash}`, quoteId: cq.id, quoteHash: `0x${cq.quoteHash}`,
    paymentHash: `0x${hashOf(payment)}`, action: cq.action, expiresAt: BigInt(cq.expiresAt),
  };
  const quoteDigest = hashTypedData({
    domain: { name: "IdentityMD Paid Action", version: "1", chainId: 1 },
    primaryType: "QuoteApproval",
    types: { QuoteApproval: [
      { name: "resource", type: "string" }, { name: "requesterScopeHash", type: "bytes32" }, { name: "quoteId", type: "string" },
      { name: "quoteHash", type: "bytes32" }, { name: "paymentHash", type: "bytes32" }, { name: "action", type: "string" },
      { name: "asset", type: "address" }, { name: "amount", type: "uint256" }, { name: "payTo", type: "address" }, u("expiresAt"),
    ] },
    message: { ...quote, asset: getAddress(qp.asset), amount: BigInt(qp.amount), payTo: getAddress(qp.payTo) },
  });

  // approve it on chain (the keeper's one power), then hand IMD the payment. The payment is kept first, so a restart
  // after approveJob can still hand over this same payment (never a second one).
  if (!keeperWallet) throw new Error("KEEPER_KEY is not set");
  const sim = await pub.simulateContract({ account: keeper, address: FRENS, abi: ABI, functionName: "approveJob", args: [BigInt(id), nonce, BigInt(deadline), quote] });
  // what the contract would approve must be exactly the payment x402 and IMD expect
  if (sim.result[0] !== permitDigest) throw new Error("the contract's Permit2 digest differs from x402's: not approving");
  if (sim.result[1] !== quoteDigest) throw new Error("the contract's quote approval digest differs from IMD's: not approving");
  note(id, { status: "approving", payment, quoteExpiresAt: cq.expiresAt, jobNonce: nonce.toString(), jobDeadline: deadline });
  const hash = await keeperWallet.writeContract(sim.request);
  note(id, { approveTx: hash });
  const receipt = await pub.waitForTransactionReceipt({ hash, timeout: 180_000 });
  if (receipt.status !== "success") throw new Error(`approveJob reverted: ${hash}`);
  log(`#${id}: approveJob mined (${hash})`);
  if (FORK) { note(id, { status: "approved-on-fork" }); return; }
  await submit(id);
}

/** Hands IMD the approved payment (the contract's "signatures" are its approvals: the bytes are ignored) */
async function submit(id) {
  const e = entry(id);
  if (e.quoteExpiresAt - Math.floor(Date.now() / 1000) < 10) {
    note(id, { status: "failed", why: "the quote expired before the payment was handed over (close() refunds the 0.50 once its permit lapses)" });
    return;
  }
  let paid;
  for (const quoteSignature of ["0x", NO_KEY_SIG]) {
    paid = await api(`/requests/${order.id}/submit`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "payment-signature": Buffer.from(JSON.stringify(e.payment), "utf8").toString("base64") },
      body: JSON.stringify({ quoteSignature }),
    });
    if (paid.status === 200 || paid.status === 202 || !/signature/i.test(JSON.stringify(paid.body))) break;
  }
  if (paid.status >= 400 && paid.status < 500) {
    note(id, { status: "failed", why: `payment refused: HTTP ${paid.status} ${JSON.stringify(paid.body).slice(0, 300)}` });
    return;
  }
  if (paid.status !== 200 && paid.status !== 202) throw new Error(`payment not taken yet: HTTP ${paid.status}`);
  note(id, { status: "submitted" });
  log(`#${id}: payment submitted (HTTP ${paid.status})`);
}

/** Whether IMD has settled the order and admitted the job yet */
async function admission(id) {
  const e = entry(id);
  {
    const st = (await api(`/requests/${e.orderId}`)).body;
    if (st.status === "admitted") {
      const res = st.admission?.result ?? {};
      if (res.kind === "refused" || !res.jobId) { note(id, { status: "failed", why: `admitted but refused: ${JSON.stringify(res.problems ?? res).slice(0, 300)}` }); return; }
      note(id, { status: "posted", jobId: res.jobId });
      log(`#${id}: job ${res.jobId} https://explorer.imd.fun/jobs/${res.jobId}`);
      return;
    }
    if (["payment_failed", "expired"].includes(st.status)) { note(id, { status: "failed", why: `order ${st.status}` }); return; }
  }
  // still pending: the next pass looks again
}

// ── 2-3. read a finished job, pick what can mint, sign the voucher ──────────
const FAILED_STATES = ["failed", "cancelled", "canceled", "expired", "refused", "rejected"];

async function checkJob(id, r, ctx) {
  const e = entry(id);
  const res = (await api(`/jobs/${e.jobId}/result`)).body;
  if (FAILED_STATES.includes(res.state)) { note(id, { status: "failed", why: `job ${res.state}` }); log(`#${id}: job ${res.state}, no fren`); return; }
  if (res.state !== "completed" || !res.complete) return;
  const file = (res.files ?? []).find((f) => f.path === CARD);
  if (!file) { note(id, { status: "failed", why: `the job completed without ${CARD}` }); return; }
  const raw = Buffer.from(await (await fetch(file.url, { signal: AbortSignal.timeout(30_000) })).arrayBuffer());
  if (sha256(raw) !== file.hash) throw new Error(`the card's bytes don't match IMD's hash ${file.hash}`);
  let card;
  try { card = readCard(raw.toString("utf8"), id); } catch (err) { note(id, { status: "failed", why: `unreadable card: ${err.message}` }); return; }

  // frens a part of an earlier voucher already revealed keep their place; this job's fill the rest
  const done = await Promise.all(Array.from({ length: r.revealed }, (_, i) => read("comboOf", [BigInt(r.firstToken + i)])));
  const [rules, openLowTier] = await Promise.all([readRules(pub, FRENS).then((x) => x.rules), read("openLowTier")]);
  const rest = { ...r, count: r.count - r.revealed };
  const picked = await pickMany({ ...card, frens: card.frens.slice(0, rest.count) }, rest, rules, Number(openLowTier), reservedBy(id));
  if (!picked) { note(id, { status: "unrevealable", why: `couldn't find ${rest.count} frens from the agents' (or near them) that can reveal for this tier` }); return; }
  const kept = done.map((c) => ({ combo: Number(c), name: "", bio: "", from: "revealed" }));
  await sign(id, r, ctx, [...kept, ...picked], `0x${file.hash}`, card.alternates);
}

/** Signs (or re-signs) the request's voucher for these frens and keeps it to serve */
async function sign(id, r, ctx, picked, outputHash, alternates) {
  const e = entry(id);
  const combos = picked.map((p) => p.combo);
  const deadline = BigInt(Math.floor(Date.now() / 1000) + VOUCHER_DAYS * 86400);
  const message = { requestId: BigInt(id), combos, jobId: keccak256(toBytes(e.jobId)), outputHash, deadline };
  const typed = {
    domain: { name: "IMD6900 Frens", version: "2", chainId: 1, verifyingContract: FRENS },
    primaryType: "FrenVoucher",
    types: { FrenVoucher: [u("requestId"), { name: "combos", type: "uint24[]" }, { name: "jobId", type: "bytes32" }, { name: "outputHash", type: "bytes32" }, u("deadline")] },
    message,
  };
  if (hashTypedData(typed) !== await read("voucherDigest", [BigInt(id), combos, e.jobId, outputHash, deadline])) throw new Error("the contract's voucher digest differs: not signing");
  const swapped = picked.filter((p) => p.from !== "agents").length;
  if (DRY) { log(`#${id}: would sign ${combos.map((c) => "0x" + c.toString(16)).join(", ")}`); return; }
  if (!relayer) throw new Error("RELAYER_KEY is not set");
  const sig = await relayer.signTypedData(typed);
  // a reveal part stays under a transaction's gas cap (~4.3M gas for 30 frens)
  const parts = [];
  for (let n = Math.min(r.revealed + PART, r.count); ; n = Math.min(n + PART, r.count)) { parts.push(n); if (n === r.count) break; }
  const again = (e.version ?? 0) > 0;
  note(id, {
    status: "ready", combos, outputHash, alternates, version: (e.version ?? 0) + 1,
    voucher: { requestId: id, combos, jobId: e.jobId, outputHash, deadline: deadline.toString(), sig, revealed: r.revealed, upTo: parts },
    frens: picked.map((p) => ({ combo: p.combo, name: p.name, bio: p.bio, traits: named(p.combo), image: `${INDEXER}/fren/0x${p.combo.toString(16)}.png`, from: p.from })),
  });
  log(`#${id}: voucher ${again ? "re-signed" : "signed"} for ${combos.length} fren${combos.length > 1 ? "s" : ""}${swapped ? ` (${swapped} from runner-ups or the nearest free fren)` : ""}`);
}

/**
 * A ready request not fully revealed: if a fren it hasn't revealed yet got taken (or its trait sold out) since the voucher
 * was signed, swap it for a runner-up or the nearest free one and re-sign. The frens already minted stay as they are.
 */
async function refresh(id, r, ctx) {
  const e = entry(id);
  const from = r.revealed;
  const [rules, openLowTier] = await Promise.all([readRules(pub, FRENS).then((x) => x.rules), read("openLowTier")]);
  const rest = e.frens.slice(from);
  const picked = await pickMany({ frens: rest, alternates: (e.alternates ?? []).filter((c) => !e.combos.includes(c)) }, { ...r, count: r.count - from }, rules, Number(openLowTier), reservedBy(id));
  const lapsing = Number(e.voucher?.deadline ?? 0) - Math.floor(Date.now() / 1000) < 86400;
  if (picked && !lapsing && picked.every((p, i) => p.combo === rest[i].combo)) return; // all still reveal, voucher fresh
  if (!picked) { log(`#${id}: some of its unminted frens can't mint now, and nothing near them can`); return; }
  await sign(id, r, ctx, [...e.frens.slice(0, from), ...picked.map((p, i) => ({ ...p, from: p.combo === rest[i].combo ? rest[i].from : p.from }))], e.outputHash, e.alternates);
}

/** Frens promised in this relayer's other vouchers not revealed yet: another request doesn't get them */
const reservedBy = (id) => new Set(Object.entries(state.requests).flatMap(([k, e]) => (k !== String(id) && e.status === "ready" ? e.combos ?? [] : [])));

const named = (combo) => Object.fromEntries(TRAITS.map(([k, , names]) => [k, names[traitsOf(combo)[k]]]));

/**
 * The request's frens, one per fren it paid for: each the agents' own if the contract would mint it, else one of their
 * runner-ups, else the nearest free variation of it (another item, then shirt). Within the batch every fren is
 * different, none is one promised in another voucher not revealed yet, rare values aren't given out more than they have
 * left, and the pepes held for low-tier requests stay held. Null when it can't fill them all.
 */
async function pickMany(card, req, rules, openLowTier, reserved = new Set()) {
  const used = new Map();
  const chosen = [];
  // pepes held for low-tier requests: a low-tier request's own come free as it claims (it claims in one part: ≤ 6)
  // a low-tier request's own frens come off openLowTier as they reveal (it reveals in one part: <= 6)
  const heldForOthers = req.lowTier ? Math.max(0, openLowTier - req.count) : openLowTier;
  const pool = [...card.alternates];
  const fits = (c) => {
    if (chosen.some((p) => p.combo === c) || reserved.has(c)) return false;
    const t = traitsOf(c);
    for (let i = 0; i < TRAITS.length; i++) {
      const v = t[TRAITS[i][0]], r = rules[i][v];
      if (!r || r.minted + (used.get(`${i}:${v}`) ?? 0) >= r.cap) return false;
    }
    if (t.character === 0 && rules[0][0].minted + (used.get("0:0") ?? 0) + heldForOthers >= rules[0][0].cap) return false;
    return true;
  };
  const mints = async (list) => {
    const local = list.filter(fits);
    for (let i = 0; i < local.length; i += 20) { // in order, 20 checks at a time: the first that mints wins
      const part = local.slice(i, i + 20);
      const codes = await Promise.all(part.map((c) => read("check", [c, req.tier])));
      const ok = part.find((_, j) => Number(codes[j]) === 0);
      if (ok !== undefined) return ok;
    }
    return null;
  };
  // the nearest free variations: one trait changed (item, shirt, background, face, eye, coat), then item and
  // background together; character and hat stay the agents'. check() rules out what the tier can't take.
  const values = (k) => TRAITS.find(([key]) => key === k)[2].map((_, v) => v);
  const near = (c) => {
    const t = traitsOf(c);
    const one = ["item", "shirt", "background", "face", "eye", "coat"].flatMap((k) => values(k).map((v) => comboOf({ ...t, [k]: v })));
    const two = values("item").flatMap((i) => values("background").map((b) => comboOf({ ...t, item: i, background: b })));
    return [...new Set([...one, ...two])].filter((x) => x !== c);
  };
  const take = (combo, f, from) => {
    chosen.push({ combo, name: f?.name ?? "", bio: f?.bio ?? "", from });
    const t = traitsOf(combo);
    TRAITS.forEach(([k], i) => used.set(`${i}:${t[k]}`, (used.get(`${i}:${t[k]}`) ?? 0) + 1));
    const j = pool.indexOf(combo);
    if (j >= 0) pool.splice(j, 1);
  };
  const frens = card.frens.slice(0, req.count);
  for (const f of frens) {
    let c = f.combo !== null ? await mints([f.combo]) : null;
    if (c !== null) { take(c, f, "agents"); continue; }
    if ((c = await mints(pool)) !== null) { take(c, f, "runner-up"); continue; }
    if (f.combo !== null && (c = await mints(near(f.combo))) !== null) { take(c, f, "nearby"); continue; }
    return null;
  }
  // the agents gave fewer frens than were paid for: runner-ups, then variations of what's chosen
  while (chosen.length < req.count) {
    let c = await mints(pool);
    for (let i = 0; c === null && i < chosen.length; i++) c = await mints(near(chosen[i].combo));
    if (c === null) return null;
    take(c, null, card.alternates.includes(c) ? "runner-up" : "nearby");
  }
  return chosen;
}

// ── a pass over the requests ────────────────────────────────────────────────
async function pass() {
  const [next, imd, imdPayTo, k, rl] = await Promise.all(["nextRequestId", "imd", "imdPayTo", "keeper", "relayer"].map((f) => read(f)));
  if (keeper && !isAddressEqual(k, keeper.address)) die(`KEEPER_KEY is ${keeper.address}; the contract's keeper is ${k}`);
  if (relayer && !isAddressEqual(rl, relayer.address)) die(`RELAYER_KEY is ${relayer.address}; the contract's relayer is ${rl}`);
  const ctx = { imd, imdPayTo };
  const now = Number((await pub.getBlock()).timestamp); // the chain's time: what the contract compares deadlines with
  for (let id = state.cursor; id < Number(next); id++) {
    const r = await read("requests", [BigInt(id)]);
    const req = {
      minter: r[0], tier: Number(r[1]), lowTier: r[2], jobApproved: r[3], count: Number(r[4]), revealed: Number(r[5]),
      jobs: Number(r[6]), firstToken: Number(r[7]), jobDeadline: Number(r[8]), jobNonce: r[9],
    };
    const e = entry(id);
    try {
      if (req.revealed === req.count) {
        if (e.status !== "revealed") note(id, { status: "revealed" });
      } else {
        // a job can go when one is paid for, or when the last approved payment lapsed and IMD never took it
        // (approveJob undoes it and uses its money again: nobody pays twice for a payment that didn't happen)
        const lapsed = req.jobApproved && req.jobDeadline < now && !(await spent(req.jobNonce));
        const canGo = req.jobs > 0 || lapsed;
        if (["failed", "unrevealable", "needs-retry"].includes(e.status)) {
          // the last job didn't land: a paid retry, or a payment that never happened, starts the next attempt
          if (canGo) note(id, { status: "new", attempt: (e.attempt ?? 1) + 1, jobId: undefined, orderId: undefined, voucher: undefined, why: undefined });
          else if (e.status === "failed") note(id, { status: "needs-retry" });
        } else if (e.status === "new" || e.status === "quoted") {
          if (canGo) await postJob(id, req, ctx);
        } else if (e.status === "submitted") {
          await admission(id);
        } else if (e.status === "approving") {
          // a restart between approveJob and handing over the payment: hand over that same one if it was approved
          if (req.jobApproved && req.jobNonce === BigInt(e.jobNonce)) await submit(id);
          else note(id, { status: "failed", why: "approveJob never landed" });
        } else if (e.status === "posted") {
          await checkJob(id, req, ctx);
        } else if (e.status === "ready") {
          await refresh(id, req, ctx);
        }
      }
      if (entry(id).errors) note(id, { errors: 0 });
    } catch (err) {
      // a network hiccup (IMD's API, the RPC) is no reason to give up on someone's frens: try again next pass, and
      // only after 10 in a row call it failed (a paid retry starts over). What is final is marked where it's found.
      const errors = (entry(id).errors ?? 0) + 1;
      log(`#${id}: ${err.shortMessage || err.message}${errors > 1 ? ` (${errors} in a row)` : ""}`);
      note(id, errors >= 10 ? { status: "failed", why: err.message, errors } : { lastError: err.message, errors });
    }
  }
  // the cursor moves past requests that are settled for good
  while (state.cursor < Number(next) && entry(state.cursor).status === "revealed") state.cursor++;
  save();
  try { await floorBuy(); } catch (err) { log(`floor buy: ${err.shortMessage || err.message}`); }
}

// ── 4. the floor: mints buy their share into IMD6900 themselves; this pushes what still waits ──
// Each buy stops once it moved the price by half the pool's fee (FrenSwapper), so it's safe for anyone to call, with
// no minimum out; one buy a block. ETH from fees and royalties goes ETH -> $IMD -> IMD6900 the same way.
async function floorBuy() {
  if (!keeperWallet || DRY) return;
  const weth = await pub.readContract({ address: WETH, abi: [{ type: "function", name: "balanceOf", stateMutability: "view", inputs: [{ type: "address" }], outputs: [{ type: "uint256" }] }], functionName: "balanceOf", args: [FRENS] });
  if (weth > 10n ** 15n) await sendKeeper("unwrapWeth", [], "royalties in WETH unwrapped");
  const [waiting, eth, ethCap, last, delay, block] = await Promise.all([
    read("floorImd"), pub.getBalance({ address: FRENS }), read("maxEthPerBuy"), read("lastFloorBuyBlock"), read("buyDelayBlocks"), pub.getBlockNumber(),
  ]);
  if (block < last + delay) return; // one buy a block
  if (waiting >= 10n ** 16n) return sendKeeper("buyFloor", [0n], `floor: ${Number(waiting) / 1e18} $IMD waiting, pushed`);
  if (eth >= 10n ** 15n) return sendKeeper("buyFloorWithEth", [eth < ethCap ? eth : ethCap, 0n], `floor: ${Number(eth) / 1e18} ETH from fees, pushed`);
}

async function sendKeeper(functionName, args, what) {
  const sim = await pub.simulateContract({ account: keeper, address: FRENS, abi: ABI, functionName, args });
  const hash = await keeperWallet.writeContract(sim.request);
  const receipt = await pub.waitForTransactionReceipt({ hash, timeout: 180_000 });
  log(receipt.status === "success" ? `${what} (${hash})` : `${functionName} reverted: ${hash}`);
}

// ── the vouchers, served ────────────────────────────────────────────────────
function serve() {
  createServer((req, res) => {
    const send = (code, body) => {
      res.writeHead(code, { "content-type": "application/json", "access-control-allow-origin": "*", "cache-control": "no-store" });
      res.end(JSON.stringify(body));
    };
    const m = /^\/voucher\/(\d+)$/.exec(req.url.split("?")[0]);
    if (m) {
      const e = state.requests[m[1]];
      if (!e) return send(404, { requestId: Number(m[1]), status: "unknown" });
      return send(e.voucher ? 200 : 404, { requestId: Number(m[1]), status: e.status, jobId: e.jobId ?? null, why: e.why ?? null, voucher: e.voucher ?? null, frens: e.frens ?? null });
    }
    if (req.url === "/requests") return send(200, Object.fromEntries(Object.entries(state.requests).map(([id, e]) => [id, { status: e.status, jobId: e.jobId ?? null, combos: e.combos ?? null }])));
    if (req.url === "/health") return send(200, { ok: true, frens: FRENS, cursor: state.cursor });
    send(404, { error: "/voucher/<requestId>, /requests, /health" });
  }).listen(PORT, () => log(`serving vouchers on :${PORT}`));
}

if (flag("status")) {
  console.log(JSON.stringify(state, null, 1));
  process.exit(0);
}
if (!/^[0-9a-f]{64}$/.test(token)) die("set IMD_PAID_TOKEN to 64 lowercase hex (openssl rand -hex 32) and keep it");
if (!DRY && (!keeper || !relayer)) die("set KEEPER_KEY and RELAYER_KEY (or use --dry)");
log(`relayer for ${FRENS}: keeper ${keeper?.address ?? "-"}, relayer ${relayer?.address ?? "-"}, state ${STATE_FILE}`);
if (ONCE) {
  await pass();
  process.exit(0);
}
if (PORT) serve();
for (;;) {
  try { await pass(); } catch (err) { log(`pass failed: ${err.message}`); }
  await new Promise((res) => setTimeout(res, EVERY));
}
