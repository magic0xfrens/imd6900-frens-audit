#!/usr/bin/env node
// The IMD job that builds a request's frens (1 to 69): five agents in a relay, one layer each (background; character
// and face; eye lens; coat and shirt; hat and item) for every fren, each seeing the frens so far, the last one putting
// the layers together and naming them.
// Only what the minter's tier may take and what is not sold out is offered (read from IMD6900Frens' trait rules), so
// whatever the agents build can be claimed. The pictures come from our indexer (indexer/src/api/frens.ts on the perps
// branch), drawn exactly as FrenRenderer draws them. The relayer (tools/fren-relayer.mjs) builds each request's job
// with buildJob and reads its answer with readCard.
//
//   node tools/fren-job.mjs --request 12 --frens 0x…              request 12's job, its tier and the rules from the chain
//   node tools/fren-job.mjs --request 12 --tier 2 --launch-rules   the same from the launch rules, nothing minted (no chain)
//   node tools/fren-job.mjs … --out jobs/fren-12.json              write it where tools/post-imd-job.mjs reads bodies
//   node tools/fren-job.mjs --test --tier 3 --launch-rules --out jobs/fren-relay-test.json   a test job: mints nothing
//   … --count 69                                                     a request for 69 frens (one job builds them all)
//
// Env: INDEXER (https://indexer-production-c5f2.up.railway.app), ETH_RPC_URL (https://ethereum-rpc.publicnode.com)
import { writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

export const INDEXER = (process.env.INDEXER || "https://indexer-production-c5f2.up.railway.app").replace(/\/$/, "");

/** The traits in combo order: key, bit shift, value names (as FrenRenderer names them) */
export const TRAITS = [
  ["character", 0, ["Cyborg Pepe", "Mumu", "Bobo"]],
  ["face", 2, ["Classic", "Happy", "Angry", "Feels Bad", "Grinding", "Chill", "Grumpy", "Giga Happy", "Cooked", "Comfy", "Special", "Scientist", "Laser Eyes"]],
  ["eye", 6, ["Green", "Red", "Cyan", "Gold"]],
  ["coat", 8, ["White", "Black", "Gold"]],
  ["shirt", 10, ["Blue", "Red", "Green", "Black", "Orange", "Purple"]],
  ["hat", 13, ["None", "Mumu Hat", "Bobo Hat"]],
  ["background", 15, ["Matrix Green", "Matrix Red", "Matrix Gold", "Machine Wall", "Machine Wall Dark", "Machine Wall Lit", "Machine Wall II", "Terminal", "Circuit Board", "Lab Goo"]],
  ["item", 19, ["None", "Flask", "Ray Gun", "Magnet", "Magnifier", "Dynamite", "Extinguisher", "Bomb", "10 Paddle", "0 Paddle", "Drink", "Wrench", "Green Lightsaber", "Red Lightsaber", "Light Bulb", "Bunsen Burner"]],
];
const KEYS = TRAITS.map(([k]) => k);
const SUPPLY = 2222;

export function comboOf(t) {
  let c = 0;
  for (const [k, shift, names] of TRAITS) {
    const v = t[k];
    if (!Number.isInteger(v) || v < 0 || v >= names.length) throw new Error(`${k} must be 0-${names.length - 1}, not ${JSON.stringify(v)}`);
    c += v * 2 ** shift;
  }
  return c;
}

export function traitsOf(combo) {
  return Object.fromEntries(TRAITS.map(([k, shift, names], i) => [k, Math.floor(combo / 2 ** shift) % 2 ** [2, 4, 2, 2, 3, 2, 4, 4][i]]));
}

/** The launch rules (script/frens/DeployFrens.s.sol sets the same), nothing minted: rules[trait][value] and pairs */
export function launchRules() {
  const fill = (n, cap, minTier) => Array.from({ length: n }, () => ({ cap, minted: 0, minTier }));
  const r = TRAITS.map(([, , names]) => fill(names.length, SUPPLY, 0));
  r[0] = [{ cap: 1598, minted: 0, minTier: 0 }, { cap: 312, minted: 0, minTier: 2 }, { cap: 312, minted: 0, minTier: 2 }];
  r[1][12] = { cap: 56, minted: 0, minTier: 3 };
  r[2][3] = { cap: 222, minted: 0, minTier: 1 };
  r[3][2] = { cap: 103, minted: 0, minTier: 1 };
  r[5] = [{ cap: SUPPLY, minted: 0, minTier: 0 }, ...fill(2, 266, 1)];
  r[7] = [{ cap: SUPPLY, minted: 0, minTier: 0 }, ...fill(15, 140, 1)];
  for (const i of [1, 3, 4, 10, 11, 14]) r[7][i].minTier = 0;
  r[7][12] = r[7][13] = { cap: 56, minted: 0, minTier: 3 };
  const pairs = [{ traitA: 0, valueA: 1, traitB: 3, valueB: 2, minTier: 3 }, { traitA: 0, valueA: 2, traitB: 3, valueB: 2, minTier: 3 }];
  return { rules: r, pairs };
}

const FRENS_ABI = [
  { type: "function", name: "ruleOf", stateMutability: "view", inputs: [{ type: "uint8" }, { type: "uint8" }],
    outputs: [{ type: "tuple", components: [{ name: "cap", type: "uint16" }, { name: "minted", type: "uint16" }, { name: "minTier", type: "uint8" }] }] },
  { type: "function", name: "pairRules", stateMutability: "view", inputs: [],
    outputs: [{ type: "tuple[]", components: ["traitA", "valueA", "traitB", "valueB", "minTier"].map((name) => ({ name, type: "uint8" })) }] },
];

/** The rules as they stand on chain: caps, how many minted, the tier each value needs, and the pair rules */
export async function readRules(pub, frens) {
  const calls = TRAITS.flatMap(([, , names], t) => names.map((_, v) => ({ address: frens, abi: FRENS_ABI, functionName: "ruleOf", args: [t, v] })));
  const [out, pairs] = await Promise.all([pub.multicall({ contracts: calls, allowFailure: false }), pub.readContract({ address: frens, abi: FRENS_ABI, functionName: "pairRules" })]);
  let i = 0;
  const rules = TRAITS.map(([, , names]) => names.map(() => {
    const r = out[i++];
    return { cap: Number(r.cap), minted: Number(r.minted), minTier: Number(r.minTier) };
  }));
  return { rules, pairs: pairs.map((p) => Object.fromEntries(Object.entries(p).map(([k, v]) => [k, Number(v)]))) };
}

/** What a tier may take of a trait now: [value, name, how many left (null when plentiful)] */
function options(rules, tier, t) {
  return TRAITS[t][2].flatMap((name, v) => {
    const r = rules[t][v];
    if (r.minTier > tier || r.minted >= r.cap) return [];
    return [[v, name, r.cap < SUPPLY ? r.cap - r.minted : null]];
  });
}
const list = (opts) => opts.map(([v, name, left]) => `${v} ${name}${left === null ? "" : ` (${left} left)`}`).join(", ");

// The five steps: the traits each decides, its folder, what it is told
const STEPS = [
  { key: "background", dir: "artifacts/1-background", traits: ["background"], what: "the background, where the fren lives" },
  { key: "character", dir: "artifacts/2-character", traits: ["character", "face"], what: "who the fren is: the character and its face (the expression; every character has all 13)" },
  { key: "lens", dir: "artifacts/3-lens", traits: ["eye"], what: "the colour of the cyborg eye lens" },
  { key: "coat", dir: "artifacts/4-coat", traits: ["coat", "shirt"], what: "the lab coat and the shirt under it" },
  { key: "final", dir: "artifacts/5-final", traits: ["hat", "item"], what: "the hat and the item held in the right hand; then you finish the fren" },
];
export const CARD = "artifacts/5-final/fren.json";

/**
 * The job body for one request: one job, its 1 to 69 frens built side by side.
 * @param request the request id on IMD6900Frens
 * @param tier    the minter's tier at request (0-3)
 * @param count   how many frens the request paid for (1-69)
 * @param rules   { rules, pairs } from readRules or launchRules
 * @param test    a test of the relay: no request behind it, nothing minted
 */
export function buildJob({ request, tier, count = 1, rules: { rules, pairs }, indexer = INDEXER, test = false }) {
  if (!(count >= 1 && count <= 69)) throw new Error("count must be 1 to 69");
  const I = indexer, many = count > 1, sheet = count > 10; // over ten, one sheet of them all instead of a file each
  const them = many ? `the ${count} frens` : "the fren";
  const start = Object.fromEntries(KEYS.map((k) => [k, 0]));
  const dna = `A FREN is 8 numbers: ${KEYS.join(", ")}. Its combo, the one number the chain draws, = character + face*4 + eye*64 + coat*256 + shirt*1024 + hat*8192 + background*32768 + item*524288. Our art server draws any combo exactly as the chain will: ${I}/fren/<combo>.png (the fren, 672x672), ${I}/fren/<combo>/<background|character|coat|hat|item>.png (one layer on see-through, same size), ${I}/fren/<combo>.json (its traits by name). A combo can be decimal or 0x hex.`;
  // pairs this tier may not take though it may take each half, told to the steps that choose either half
  const offered = (t, v) => options(rules, tier, t).some(([x]) => x === v);
  const forbidden = pairs.filter((p) => p.minTier > tier && offered(p.traitA, p.valueA) && offered(p.traitB, p.valueB)).map((p) => ({
    keys: [KEYS[p.traitA], KEYS[p.traitB]],
    text: `${KEYS[p.traitA]} ${p.valueA} (${TRAITS[p.traitA][2][p.valueA]}) with ${KEYS[p.traitB]} ${p.valueB} (${TRAITS[p.traitB][2][p.valueB]})`,
  }));
  const eight = "{<all 8 numbers>}";
  const list8 = many ? `[${eight}, … ${count} of them, fren 1 first]` : `[${eight}]`;

  const steps = STEPS.map((s, i) => {
    const first = i === 0, last = i === STEPS.length - 1;
    const so = first
      ? `You go first. ${many ? `Each of the ${count} frens starts` : "The fren starts"} as ${JSON.stringify(start)} (combo 0: a classic cyborg pepe); you change the background.`
      : `Read artifacts/${STEPS[i - 1].dir.slice(10)}/pick.json from step ${i}: its "frens" are ${them} so far (every layer before yours chosen, the rest still 0). Fetch each at ${I}/fren/<combo>.png before you choose.`;
    const opts = s.traits.map((k) => {
      const t = KEYS.indexOf(k);
      const o = options(rules, tier, t);
      if (!o.length) throw new Error(`nothing left to offer for ${k} at tier ${tier}`);
      return `${k[0].toUpperCase() + k.slice(1)}: ${list(o)}.`;
    });
    const notes = [];
    if (s.traits.includes("hat")) notes.push("Hats fit only the cyborg pepe: a mumu or bobo keeps hat 0.");
    const pairNotes = forbidden.filter((f) => f.keys.some((k) => s.traits.includes(k))).map((f) => f.text);
    if (pairNotes.length) notes.push(`Not allowed together for this minter: ${pairNotes.join("; ")}.`);
    if (many) notes.push(`A value with "left" can't be given to more of the ${count} than it has left.`);
    if (sheet) notes.push("With this many, a small script helps: it can compute each combo from its 8 numbers and fetch the pictures.");
    const out = last
      ? [
          many
            ? `Every one of the ${count} frens must be different from the others in at least one number.`
            : "",
          sheet
            ? `Then put each fren together yourself: download its final combo's layers at ?scale=2 (${I}/fren/<combo>/<layer>.png?scale=2: background, character, coat, then hat and item if it has them, 168x168 each) and stack them bottom to top with plain alpha compositing, no resampling; each must match ${I}/fren/<combo>.png?scale=2 pixel for pixel. Lay all ${count} out as one sheet, ${s.dir}/frens.png: rows of 10, fren 1 top left, no gaps. Give each a short name and a one-line bio that fits what the five of you made.`
            : `Then put each fren together yourself: download its final combo's layers (background, character, coat, then hat and item if it has them) and stack them bottom to top with plain alpha compositing, same size, no resampling, into ${s.dir}/fren-<n>.png (n = 1${many ? ` to ${count}` : ""}); each must match ${I}/fren/<combo>.png pixel for pixel. Give each a short name and a one-line bio that fits what the five of you made.`,
          `In case another mint takes one of these exact frens first, also give ${Math.max(2, Math.min(10, Math.ceil(count / 4)))} runner-ups that differ from one of them only in the hat, item or shirt (from the options offered in this job).`,
          `Write ${CARD}: {"request": ${request}, "frens": [{"traits": ${eight}, "name": "<name>", "bio": "<one line>"}${many ? `, … ${count} of them, fren 1 first` : ""}], "alternates": [${eight}, …], "picks": [<one per step: {"layer", "values", "why"}>]}.`,
        ].filter(Boolean).join(" ")
      : `Compare the options on ${them} (change your number in a combo, fetch the picture) and choose by taste${many ? ", fren by fren" : ""}. Save the picture of fren 1 so far as ${s.dir}/fren.png and write ${s.dir}/pick.json: {"frens": ${list8} (yours included), "why": "<one sentence>"}.`;
    return {
      key: s.key,
      dependsOn: first ? [] : [STEPS[i - 1].key],
      skill: "create-image",
      paths: [s.dir],
      outputs: last
        ? [
            ...(sheet
              ? [{ name: "frens", path: `${s.dir}/frens.png`, mediaType: "image/png" }]
              : Array.from({ length: count }, (_, n) => ({ name: `fren-${n + 1}`, path: `${s.dir}/fren-${n + 1}.png`, mediaType: "image/png" }))),
            { name: "card", path: CARD, mediaType: "application/json" },
          ]
        : [{ name: "pick", path: `${s.dir}/pick.json`, mediaType: "application/json" }, { name: "fren", path: `${s.dir}/fren.png`, mediaType: "image/png" }],
      objective: [
        `Step ${i + 1} of 5 in a relay: five agents build ${many ? `${count} IMD6900 frens` : "an IMD6900 fren"} (mint request #${request}), one layer each, each seeing what the agents before chose.`,
        so, dna, `YOUR LAYER, for ${many ? `each of the ${count} frens` : "the fren"}: ${s.what}. Only these can be minted for this minter:`, ...opts, ...notes, out,
      ].join(" "),
    };
  });

  const what = test
    ? `TEST RELAY: nothing is minted from this job; it tests the relay exactly as a mint runs it, for a tier ${tier} minter.`
    : `This job is mint request #${request}: ${count === 1 ? "one fren was" : `${count} frens were`} minted, unrevealed, and what the minter's bag held (tier ${tier} of 3) decides which traits are offered. When the job is done, the relayer reads ${CARD}, checks ${them} on chain and signs a voucher, and ${many ? "they reveal" : "it reveals"} on chain exactly as built here.`;
  const objective = `Five agents build ${many ? `${count} IMD6900 frens` : "one IMD6900 fren"}, layer by layer: background; character and face; eye lens; coat and shirt; hat and item. IMD6900 Frens are 2222 pixel-art cyborg pepes, with rare mumus and bobos, drawn fully on chain on Ethereum (imd6900.pages.dev). ${what} Each step: read the earlier steps' pick.json, choose your layer by taste from the options offered, keep every pick inside them.`;
  return { objective, shape: "dag", steps, github: false };
}

/** The agents' words as plain text: no markup reaches the site */
const plain = (v) => String(v ?? "").replace(/[<>"'&`\\]/g, "").replace(/[\u0000-\u001f]/g, " ").trim();

/** A finished job's answer: its frens (best first, as combos with names) and runner-ups (throws when none parse) */
export function readCard(text, request) {
  const card = JSON.parse(text);
  if (card.request !== undefined && Number(card.request) !== Number(request)) throw new Error(`the card is for request ${card.request}`);
  const asCombo = (t) => { try { return comboOf(t ?? {}); } catch { return null; } };
  const frens = (Array.isArray(card.frens) ? card.frens : [{ traits: card.traits, name: card.name, bio: card.bio }])
    .map((f) => ({ combo: asCombo(f?.traits), name: plain(f?.name).slice(0, 64), bio: plain(f?.bio).slice(0, 200) }));
  const alternates = (Array.isArray(card.alternates) ? card.alternates : []).map(asCombo).filter((c) => c !== null);
  if (!frens.some((f) => f.combo !== null)) throw new Error("the card has no valid frens");
  return { frens, alternates };
}

// ── CLI ─────────────────────────────────────────────────────────────────────
if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  const argv = process.argv.slice(2);
  const opt = (k) => { const i = argv.indexOf(`--${k}`); return i >= 0 ? argv[i + 1] : undefined; };
  const die = (m) => { console.error(m); process.exit(1); };
  const test = argv.includes("--test");
  const request = test ? 0 : Number(opt("request"));
  if (!test && (!Number.isInteger(request) || request < 1)) die("--request <id> (or --test) is required");
  let tier = opt("tier") === undefined ? undefined : Number(opt("tier"));
  let rules;
  if (argv.includes("--launch-rules")) {
    rules = launchRules();
    if (!(tier >= 0 && tier <= 3)) die("--tier 0-3 is required with --launch-rules");
  } else {
    const frens = opt("frens") || process.env.FRENS;
    if (!/^0x[0-9a-fA-F]{40}$/.test(frens || "")) die("--frens <address> (or FRENS), or --launch-rules --tier N");
    const viem = await import("viem"), { mainnet } = await import("viem/chains");
    const pub = viem.createPublicClient({ chain: mainnet, transport: viem.http(process.env.ETH_RPC_URL || "https://ethereum-rpc.publicnode.com") });
    rules = await readRules(pub, frens);
    if (tier === undefined) {
      const r = await pub.readContract({ address: frens, abi: [{ type: "function", name: "requests", stateMutability: "view", inputs: [{ type: "uint256" }], outputs: [{ type: "address" }, { type: "uint8" }] }], functionName: "requests", args: [BigInt(request)] }).catch(() => null);
      tier = r ? Number(r[1]) : die(`can't read request ${request}'s tier: pass --tier`);
    }
  }
  const count = Number(opt("count") ?? 1);
  const body = buildJob({ request, tier, count, rules, test });
  const json = JSON.stringify(body, null, 2);
  const size = Buffer.byteLength(JSON.stringify({ requestKey: "x".repeat(36), action: "job.open", input: body }));
  if (opt("out")) writeFileSync(opt("out"), json + "\n");
  console.log(json);
  console.error(`request ${request}, tier ${tier}, ${count} fren(s): ${body.steps.length} steps, quote body ${size} bytes of 16384, objectives ${[body.objective, ...body.steps.map((s) => s.objective)].map((o) => o.length).join("/")} characters (8000 each at most)`);
  if (size > 16384) die("too big for IMD's 16 KiB quote body");
}
