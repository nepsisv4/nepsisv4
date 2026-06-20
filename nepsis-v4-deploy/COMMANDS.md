# Copy-paste path to live

## Option A — let CI compile + test for you (no local setup)
1. Push this folder to a GitHub repo.
2. Open the **Actions** tab. The `CI` workflow runs `forge build` + `forge test` automatically.
3. Green check = the hook compiles and all four buy/sell quadrants pass (fee reaches the pool, nothing reverts). Red = open the log; it names the failing test/line.

## Option B — run it locally
```bash
# 0. one-time: install Foundry
curl -L https://foundry.paradigm.xyz | bash && foundryup

# 1. from inside nepsis-v4-deploy/
forge install foundry-rs/forge-std --no-commit
forge install Uniswap/v4-core --no-commit
forge install Uniswap/v4-periphery --no-commit
forge install OpenZeppelin/uniswap-hooks --no-commit

# 2. compile (first real compile of the hook) + run the full test matrix
forge build
forge test -vvv
```
Do not continue past here until `forge test` is green. A failing SELL test = the
beforeSwap path reverts = an unsellable token. That's the whole reason for this gate.

## Then: Sepolia (testnet rehearsal with real transactions)
```bash
export PRIVATE_KEY=0x...            # a TEST wallet, funded with Sepolia ETH
export SEPOLIA_RPC_URL=https://...  # Alchemy/Infura Sepolia endpoint
export ETHERSCAN_API_KEY=...

# deploy token + pool + mined hook
forge script script/Deploy.s.sol:Deploy --rpc-url sepolia --broadcast --verify
# -> copy the printed Nepsis / PatiencePool / NepsisHook addresses

export NEPSIS=0x...        # from the deploy output
export HOOK=0x...
export PPOOL=0x...         # the PatiencePool address
export START_TICK=...      # launch tick (see RUNBOOK step 6 for the price->tick snippet)
export TICK_LOWER=...
export NEPSIS_LIQUIDITY=...# whole nepsis tokens to seed

# open the pool + seed one-sided nepsis liquidity
forge script script/InitializeAndMint.s.sol:InitializeAndMint --rpc-url sepolia --broadcast

# THE PROOF: one real buy + one real sell, prints fee that reached the pool
forge script script/SmokeSwap.s.sol:SmokeSwap --rpc-url sepolia --broadcast
```
If SmokeSwap prints two non-zero numbers and "OK: 2/2 fee working live", the system
works end to end on a live network.

## Before mainnet (the one gate you can't skip)
Get the `beforeSwap` sell path audited by someone who knows v4 hook delta conventions.
It's immutable once mainnet-live; a bug there makes sells revert with no fix.

## Mainnet (you run it, once)
Same three `forge script` commands with `--rpc-url mainnet` and your real key/RPC.
