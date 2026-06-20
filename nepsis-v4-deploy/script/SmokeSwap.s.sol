// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

interface IERC20Min {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// @notice Run this AFTER Deploy + InitializeAndMint on Sepolia. It does ONE real
/// buy (ETH -> nepsis) and ONE real sell (nepsis -> ETH) through Uniswap's deployed
/// PoolSwapTest router, and prints how much nepsis the PatiencePool gained on each.
/// If both numbers are > 0, the 2/2 fee is working end-to-end on a live network.
/// If the SELL reverts, the beforeSwap path is wrong — stop, do not go to mainnet.
///
/// forge script script/SmokeSwap.s.sol:SmokeSwap --rpc-url sepolia --broadcast
///
/// Env: NEPSIS, HOOK, PPOOL (PatiencePool), FEE (default 3000), TICK_SPACING (default 60),
///      BUY_ETH (wei, default 0.001 ETH), SELL_NEPSIS (whole tokens, default 100), PRIVATE_KEY.
contract SmokeSwap is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address nepsis = vm.envAddress("NEPSIS");
        address hook = vm.envAddress("HOOK");
        address ppool = vm.envAddress("PPOOL");
        uint24 fee = uint24(vm.envOr("FEE", uint256(3000)));
        int24 tickSpacing = int24(vm.envOr("TICK_SPACING", uint256(60)));
        uint256 buyEth = vm.envOr("BUY_ETH", uint256(0.001 ether));
        uint256 sellNepsis = vm.envOr("SELL_NEPSIS", uint256(100)) * 1e18;

        require(block.chainid == 11155111, "run this on Sepolia first");
        PoolSwapTest router = PoolSwapTest(0x9b6B46e2c869aa39918Db7f52f5557Fe577B6eEE); // Sepolia

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(nepsis),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(hook)
        });
        PoolSwapTest.TestSettings memory ts = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        vm.startBroadcast(pk);

        // ---- BUY: exact-input ETH -> nepsis ----
        uint256 poolBeforeBuy = IERC20Min(nepsis).balanceOf(ppool);
        router.swap{value: buyEth}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -int256(buyEth), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            ts, ""
        );
        uint256 buyFee = IERC20Min(nepsis).balanceOf(ppool) - poolBeforeBuy;

        // ---- SELL: exact-input nepsis -> ETH (the beforeSwap path) ----
        IERC20Min(nepsis).approve(address(router), type(uint256).max);
        uint256 poolBeforeSell = IERC20Min(nepsis).balanceOf(ppool);
        router.swap(
            key,
            SwapParams({zeroForOne: false, amountSpecified: -int256(sellNepsis), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}),
            ts, ""
        );
        uint256 sellFee = IERC20Min(nepsis).balanceOf(ppool) - poolBeforeSell;

        vm.stopBroadcast();

        console2.log("BUY  fee to PatiencePool (nepsis):", buyFee);
        console2.log("SELL fee to PatiencePool (nepsis):", sellFee);
        require(buyFee > 0, "BUY did not feed the pool");
        require(sellFee > 0, "SELL did not feed the pool (beforeSwap broken)");
        console2.log("OK: 2/2 fee working live on Sepolia.");
    }
}
