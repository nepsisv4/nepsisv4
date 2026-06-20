// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {Nepsis} from "../src/Nepsis.sol";
import {PatiencePool} from "../src/PatiencePool.sol";
import {NepsisHook} from "../src/NepsisHook.sol";

/// @notice Step 1-5 of the launch: deploy token + pool, mine a hook address with
/// the correct permission bits, deploy the hook to it via CREATE2, wire the pool's
/// yield source to the hook. NOTHING here touches Uniswap yet (no pool init, no
/// liquidity) — that is script/InitializeAndMint.s.sol, run only after this and
/// after you have tested on a testnet.
///
/// YOU run this with YOUR key:
///   forge script script/Deploy.s.sol:Deploy --rpc-url sepolia --broadcast --verify
/// The deployer key is read from the PRIVATE_KEY env var — it stays on your machine.
contract Deploy is Script {
    // CREATE2 Deterministic Deployer Proxy — same address on every chain.
    // forge's `new C{salt: s}()` routes through this, and HookMiner must mine
    // against this exact deployer or the resulting address won't match.
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function _poolManager() internal view returns (address pm) {
        if (block.chainid == 1) return 0x000000000004444c5dc75cB358380D2e3dE08A90;       // Ethereum
        if (block.chainid == 11155111) return 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543; // Sepolia
        revert("PoolManager address not set for this chainid — add it from docs.uniswap.org/contracts/v4/deployments");
    }

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        // Fixed supply: override with env SUPPLY (in whole tokens) if set, else 1B.
        uint256 wholeTokens = vm.envOr("SUPPLY", uint256(1_000_000_000));
        uint256 supply = wholeTokens * 1e18;

        address pm = _poolManager();

        vm.startBroadcast(pk);

        // 1. Token — entire fixed supply minted to you.
        Nepsis nepsis = new Nepsis(supply, deployer);

        // 2. Patience pool (nepsis is both the deposited and the yield asset).
        PatiencePool pool = new PatiencePool(address(nepsis));

        // 3. Mine a salt whose CREATE2 address encodes ALL FOUR permission bits
        //    (beforeSwap + afterSwap + both return-delta flags). Changing the
        //    permissions vs the buy-only version changes the required address,
        //    so this re-mines automatically.
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG
            | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        bytes memory ctorArgs = abi.encode(
            IPoolManager(pm),
            address(pool),
            Currency.wrap(address(nepsis))
        );
        (address hookAddr, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(NepsisHook).creationCode, ctorArgs);

        // 4. Deploy the hook to the mined address (the {salt:} form uses CREATE2_DEPLOYER).
        NepsisHook hook = new NepsisHook{salt: salt}(
            IPoolManager(pm),
            address(pool),
            Currency.wrap(address(nepsis))
        );
        require(address(hook) == hookAddr, "hook address mismatch — re-mine");

        // 5. Wire the pool's yield source to the hook (set-once on PatiencePool).
        pool.setYieldSource(address(hook));

        vm.stopBroadcast();

        console2.log("chainid        ", block.chainid);
        console2.log("deployer       ", deployer);
        console2.log("Nepsis (token) ", address(nepsis));
        console2.log("PatiencePool   ", address(pool));
        console2.log("NepsisHook     ", address(hook));
        console2.log("PoolManager    ", pm);
        console2.log("-> Save these. InitializeAndMint reads NEPSIS / HOOK from env.");
    }
}
