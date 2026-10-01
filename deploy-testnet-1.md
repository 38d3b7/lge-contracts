# Deploy + verify the LGE on Arc testnet

Audience: senior dev replicating the 2026-10-01 deployment by hand. Every step
below is the one that actually worked; each "watch out" is a real failure hit
during the first pass.

Resulting deployment (what you should end up with, or what you will redeploy):

| Contract | Address |
|---|---|
| LGEManager | `0x0aa1421add6b810a0d99541fb13501948bdcdb7a` |
| LGECalculationsLibrary | `0x23f7ab13a4aBc7670E40B663872f2A976bF3ea96` |
| HookMinerWrapper | `0x9787190430d32c70c2787af01353a6193cf8ef51` |

Arc v4 infrastructure (official Uniswap deployment, not ours to deploy):
PoolManager `0x8366a39CC670B4001A1121B8F6A443A643e40951`,
PositionManager `0x6049c9a0e26405C0985f9E3685C87d0aE917f82B`,
Permit2 `0x000000000022D473030F116dDEE9F6B43aC78BA3`.

## 0. Arc facts that will bite you if skipped

- Chain ID **5042002**, RPC `https://rpc.testnet.arc.io`, explorer
  `https://explorer.testnet.arc.io` (hosted Blockscout).
- **Gas is paid in native USDC, 18 decimals.** The ERC-20 *view* of USDC at
  `0x3600000000000000000000000000000000000000` is **6 decimals**. Never mix
  the two when computing values.
- **Gas floor: 20 gwei.** Every broadcast needs
  `--gas-price 20000000000 --priority-gas-price 1000000000` or it sits
  forever.
- `address(0)` transfers revert (native token is a system contract).
- Block time ~0.5 s. The LGE window is `STREAM_BLOCKS = 3600` blocks
  (~30 min). (README says 5,000 — stale.)
- The public RPC intermittently answers **heavy `eth_call` with `-32003`
  ("Transaction creation failed")** — notably `HookMinerWrapper.find` whenever
  the salt search needs many iterations. It is deterministic per input, so
  retries do not help. **Mine salts off-chain** (pure keccak256 loop, mask
  `0x3fff`); the manager re-validates flags on-chain anyway. Light reads
  occasionally flake too — retry those.
- Faucet: https://faucet.circle.com (Arc testnet USDC). A few USDC is plenty;
  a full infra deploy is ~0.05 USDC and a whole smoke cycle ~0.01.

## 1. Toolchain

```bash
foundryup            # forge/cast
svm install 0.8.28   # or let foundry auto-detect, but see §4
node >= 22           # for the e2e script
```

`lge-contracts/.env` (gitignored — create by hand):

```
PRIVATE_KEY=0x...            # funded deployer key
POOL_MANAGER=0x8366a39CC670B4001A1121B8F6A443A643e40951
POSITION_MANAGER=0x6049c9a0e26405C0985f9E3685C87d0aE917f82B
PERMIT2=0x000000000022D473030F116dDEE9F6B43aC78BA3
BLOCKSCOUT_API_KEY=...       # https://dev.blockscout.com — needed in §6
```

## 2. Deploy the contracts

Two stages. **Order matters**: LGEManager embeds `LGEHook` creation bytecode at
compile time, and the hook calls `LGECalculationsLibrary`, so the library
address must exist *before* the manager is built.

Stage A — library (no link needed):

```bash
cd lge-contracts
forge create src/libraries/LGECalculationsLibrary.sol:LGECalculationsLibrary \
  --rpc-url arc_testnet --broadcast --private-key $PRIVATE_KEY \
  --gas-price 20000000000 --priority-gas-price 1000000000
# record the address -> LIB
```

Stage B — relink the build against that address, then deploy:

```bash
export FOUNDRY_LIBRARIES="src/libraries/LGECalculationsLibrary.sol:LGECalculationsLibrary:$LIB"
forge build          # via_ir + optimizer are on in foundry.toml; LGEManager
                     # exceeds the 24KB limit without them
forge script script/Deploy.s.sol --rpc-url arc_testnet --broadcast \
  --gas-price 20000000000 --priority-gas-price 1000000000
# prints HookMinerWrapper + LGEManager addresses
```

`FOUNDRY_LIBRARIES` discipline (this cost real time):

- **Set** for any build whose artifacts you deploy or copy bytecode from.
- **Unset** for `forge test` — local Anvil has no code at the linked address
  and every test that touches the hook reverts.
- `forge test` **clobbers `out/`**. Never copy bytecode from `out/` after a
  test run; rebuild first.

## 3. Sanity-check the deployment

```bash
cast call $MANAGER "FLAGS()(uint160)" --rpc-url arc_testnet   # 8832 (0x2280)
cast call $MANAGER "poolManager()(address)" --rpc-url arc_testnet
```

## 4. Compiler-version discipline (the subtle one)

The existing on-chain contracts were compiled by **solc 0.8.28** (foundry
auto-detect at deploy time). A fresh build today auto-detects **0.8.26** and
produces *different* bytecode — for `LGEToken` the codegen differs in the body,
for `LGEHook` only the metadata hash differs. Either way the CREATE2 init-code
hash changes, so:

- Any salt mined against a 0.8.26 build is **invalid** for a manager built
  with 0.8.28 → `deployToken` reverts `HookAddressNotValid(address)`.
- Blockscout verification mismatches until you select the exact compiler.

Rule: **whatever solc compiles the deploy build is the only source of truth.**
Check the trailing metadata of what you deployed (`...736f6c6343 00081c` =
0.8.28, `00081a` = 0.8.26) and pin `solc = "0.8.28"` in `foundry.toml` if you
want reproducibility instead of auto-detect roulette.

## 5. Wire the frontend

In `lge-frontend`:

1. `.env` (see `.env.sample`): set the six `*_ARC_TESTNET` addresses
   (manager, library, hook miner, pool manager, position manager, permit2).
2. Bytecode constants — `src/config/contracts/bytecode/LGEHookBytecode.ts`
   (`LGE_HOOK_BYTECODE_ARC_TESTNET`) and `LGETokenBytecode.ts`
   (`LGE_TOKEN_BYTECODE_ARC_TESTNET`) must be extracted **from the same build
   that produced the deployed manager**, with `FOUNDRY_LIBRARIES` set:

   ```bash
   jq -r .bytecode.object out/LGEHook.sol/LGEHook.json     # -> hook const
   jq -r .bytecode.object out/LGEToken.sol/LGEToken.json   # -> token const
   ```

   Stale copies here are exactly how the first pass broke (§4). There is no
   automated freshness gate yet — eyeball the metadata tail against the
   manager's embedded bytecode before committing.
3. `npm run build` (strict TS) must pass.
4. Note for the UI task: `useHookMiner` currently mines via `eth_call` to
   `HookMinerWrapper.find` — on Arc this fails non-deterministically (§0).
   It needs replacing with local mining (pure JS keccak loop, mask `0x3fff`,
   `getCreate2Address`, then a `getCode` emptiness check). The e2e script
   (§7) contains a working implementation to lift.

## 6. Verify on Blockscout

`forge verify-contract` does **not** resolve the `foundry.toml` `[etherscan]`
entry for the blockscout verifier ("No verifier URL specified") — pass
`--verifier-url` explicitly:

```bash
forge verify-contract $ADDR src/.../X.sol:X \
  --verifier blockscout \
  --verifier-url "https://explorer.testnet.arc.io/api?apikey=$BLOCKSCOUT_API_KEY" \
  --chain 5042002
```

If the compiler/settings dance mismatches (it will, for the existing
deployment — see README "Verification note"), fall back to the v2 API:
`POST /api/v2/smart-contracts/{addr}/verification/via/standard-input` as
**multipart/form-data** with `files[0]` = standard-json input, `?apikey=`
param, and a browser User-Agent (Cloudflare 403s python urllib). Compile the
standard-json locally with the svm 0.8.28 binary and **byte-compare against
the on-chain creation bytecode before submitting** (local creation code must
be an exact prefix; constructor args are the tail). For the existing
deployment: library = 0.8.28, no via_ir/optimizer; manager = 0.8.28, via_ir +
optimizer 200 runs + library link. For a *fresh* deploy from current
`foundry.toml`, everything is via_ir + optimizer 200 — much simpler.

## 7. Smoke-test the lifecycle

`script/SmokeLGE.s.sol` is env-driven (`SMOKE_ACTION` =
create/deposit/claim/withdraw/status). Always with the library link and gas
flags:

```bash
export FOUNDRY_LIBRARIES="src/libraries/LGECalculationsLibrary.sol:LGECalculationsLibrary:$LIB"
SMOKE_ACTION=create LGE_MANAGER=$MANAGER POOL_MANAGER=... POSITION_MANAGER=... PERMIT2=... \
  DEPLOYER=$ADDR TOKEN_NAME=Test TOKEN_SYMBOL=TST \
  forge script script/SmokeLGE.s.sol --rpc-url arc_testnet --broadcast \
  --private-key $PRIVATE_KEY --gas-price 20000000000 --priority-gas-price 1000000000
```

Full cycle: create campaign A → `deposit` partial → create campaign B →
deposit B to cap (`FILL_CAP=1`; this initializes the pool and mints the LP
position to the hook) → `claim` B (LP NFT reaches the depositor) → wait out
A's window (3,600 blocks ≈ 30 min; `SMOKE_ACTION=status HOOK=...` shows
`STREAM_END`) → `withdraw` A (asserts the full refund leaves the hook).

A complete headless lifecycle test (fresh user wallet, both campaigns, price
rise assertion, refund assertion) also exists as `e2e.mjs` — ask for it; it
should be committed somewhere durable rather than live in `/tmp`.

## 8. Failure-mode cheat sheet

| Symptom | Cause | Fix |
|---|---|---|
| `deployToken` reverts `HookAddressNotValid` | bytecode consts / build from a different solc than the manager's build | §4, redo §5.2 from the deploy build |
| `eth_call` to `find` → `-32003` | RPC execution cap on long salt searches | mine off-chain (§0) |
| `forge verify-contract`: "No verifier URL specified" | foundry doesn't resolve `[etherscan]` for blockscout | pass `--verifier-url` (§6) |
| Verification "mismatch" | solc 0.8.26 vs 0.8.28, or via_ir/optimizer mismatch | §4/§6 settings |
| `forge script` deploy of LGEManager fails size check | via_ir/optimizer off | they're on in foundry.toml; don't strip them |
| `forge test` reverts everywhere | `FOUNDRY_LIBRARIES` still set | unset it for tests (§2) |
| Broadcast tx pending forever | below Arc's 20 gwei floor | §0 gas flags |
| Copied bytecode doesn't match on-chain | copied from `out/` after `forge test` clobbered it | rebuild with link, re-extract (§2) |
