#  nepsis v4 — deploy runbook (you run every on-chain step yourself)

This project is a build-ready Foundry scaffold for launching the nepsis ERC-20 + a
Uniswap v4 hook with **one-sided nepsis liquidity** paired against **native ETH**.
You hold the keys and sign every transaction. Nothing here deploys on its own.

Every import path and signature in `src/NepsisHook.sol`, `script/*.s.sol`, and
`test/NepsisHook.t.sol` was checked against the live Uniswap v4 source (v4-core,
v4-periphery, and OpenZeppelin/uniswap-hooks) — but it has **not been compiled or
run** here. Step 2 (`forge build`) and Step 4 (`forge test`) are how you confirm it,
and they are not optional.

---

## What this hook does (2/2, all in nepsis)
- **2% on every buy and every sell, always taken in nepsis, 100% forwarded to the
  PatiencePool** so the pool stays single-asset. nepsis is taxed wherever it sits in
  the swap: via `afterSwap` when it's the unspecified currency (exact-input buys,
  exact-output sells) and via `beforeSwap` when it's the specified currency
  (exact-input sells, exact-output buys). The two callbacks are mutually exclusive
  per swap, so nothing is double-charged. Exact-output buys add the 2% on top of the
  requested output (exact-output guarantees the buyer's amount, so the fee can't be
  carved out of it).
- Every import path and signature was checked against the live v4 source, and the
  sign conventions mirror OpenZeppelin's audited `BaseHookFee` (unspecified side) and
  `BaseAsyncSwap` (specified-side `take` + `toBeforeSwapDelta`).

## ⚠️ The risk you signed up for
The `beforeSwap` branch is what makes sells taxable in nepsis, and it is also what
can brick sells. The hook is **immutable** once the pool exists. If that branch
reverts, **sells revert and the token is unsellable** — indistinguishable from a
honeypot, unpatchable, relaunch-only. This is why Step 4 (the four-quadrant test)
and the audit below are non-negotiable, and why the audit must be done by someone who
specifically knows the v4 `beforeSwap` specified-delta convention.

## What I could NOT do from here, by design
- Run `forge` (the binary host isn't reachable in my sandbox).
- Hold your key, deploy, initialize, or add liquidity. Those are Steps 3, 5, 6.

---

## 0. Prereqs
```bash
# Foundry
curl -L https://foundry.paradigm.xyz | bash && foundryup
```
You'll need an RPC URL (Alchemy/Infura/your node) and a funded deployer key.

## 1. Install the v4 libraries
```bash
cd nepsis-v4-deploy
forge init --force --no-git .          # only if forge complains about project layout
forge install foundry-rs/forge-std
forge install Uniswap/v4-core
forge install Uniswap/v4-periphery
forge install OpenZeppelin/uniswap-hooks
forge remappings > /dev/null           # sanity: confirms remappings.txt resolves
```

## 2. Build (first real correctness gate)
```bash
forge build
```
If anything fails to compile, it'll be a version drift in your installed v4 vs the
clone I checked against — fix the import/signature it names, don't work around it.

## 3. Set env (key stays local; never commit it)
```bash
export PRIVATE_KEY=0x...              # your deployer
export SEPOLIA_RPC_URL=https://...
export ETH_RPC_URL=https://...
export ETHERSCAN_API_KEY=...
export SUPPLY=1000000000              # whole tokens, optional (default 1e9)
```

## 4. Test on v4's harness (second correctness gate — must be green)
```bash
forge test -vvv
```
The four tests prove every order type (exact-in/out buy AND sell) doesn't revert
AND delivers ~2% in nepsis to the PatiencePool. If any sell test reverts, the
beforeSwap accounting is wrong — stop, do not deploy, that's an unsellable token.

## 5. Deploy token + pool + hook to **Sepolia first**
```bash
forge script script/Deploy.s.sol:Deploy --rpc-url sepolia --broadcast --verify
```
Record the printed `Nepsis`, `PatiencePool`, `NepsisHook` addresses.

## 6. Pick your ticks, then initialize + seed one-sided liquidity (Sepolia)
Convert your launch & floor prices (nepsis per 1 ETH; both 18 decimals) to ticks:
```js
// node
const tick = p => Math.floor(Math.log(p) / Math.log(1.0001));
const align = (t, s) => Math.floor(t / s) * s;
const SPACING = 60;
console.log("START_TICK", align(tick(/*nepsis per ETH at launch*/ 1_000_000), SPACING)); // cheapest nepsis
console.log("TICK_LOWER", align(tick(/*nepsis per ETH at floor */   100_000), SPACING)); // most expensive
```
`START_TICK` is the top of the range (== tickUpper) and where the pool opens, so the
position is 100% nepsis. `TICK_LOWER` is the floor. `START_TICK > TICK_LOWER`.
```bash
export NEPSIS=0x...            # from step 5
export HOOK=0x...             # from step 5
export START_TICK=...          # tickUpper / launch
export TICK_LOWER=...
export NEPSIS_LIQUIDITY=...    # whole nepsis tokens to seed the pool
export FEE=3000                # LP fee tier; TICK_SPACING default 60
forge script script/InitializeAndMint.s.sol:InitializeAndMint --rpc-url sepolia --broadcast
```

## 7. Actually exercise it on Sepolia
- Buy nepsis with ETH on the pool; confirm the swap lands and the PatiencePool
  nepsis balance rises by ~2% of your output.
- Deposit into the PatiencePool, advance time, confirm yield accrues and principal
  returns in full. Run `node test/fuzz_v4pool.js` from the original package too.

## 8. THEN, and only then
- Get a **v4-literate security audit** of `NepsisHook.sol`, with explicit focus on the
  **beforeSwap specified-delta path** (the sell-side), plus type-cast overflow, the
  exact-in/out quadrant logic, reentrancy via take→transfer→receiveYield, and the
  permission bits matching the mined address. The hook is immutable once the pool
  exists and sits in the sell path — a revert here makes the token unsellable.
- Also have the PatiencePool reviewed — its own header flags the accumulator
  precision/gaming surface as un-hardened, and the draft has a `K`-vs-comment
  mismatch (constant `K = 2` while the prose describes `k = 5`). Decide which is
  intended before launch.
- Re-run Steps 5-7 on **mainnet**, once.

---

### Mainnet addresses baked into the scripts (from docs.uniswap.org/contracts/v4/deployments)
| | Ethereum (1) | Sepolia (11155111) |
|---|---|---|
| PoolManager | `0x000000000004444c5dc75cB358380D2e3dE08A90` | `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543` |
| PositionManager | `0xbd216513d74c8Cf14cF4747E6AaA6420FF64ee9E` | `0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4` |
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` | `0x000000000022D473030F116dDEE9F6B43aC78BA3` |

Confirm these against the official page yourself before mainnet — a wrong
PoolManager sends value nowhere.
