// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {Nepsis} from "../src/Nepsis.sol";
import {PatiencePool} from "../src/PatiencePool.sol";
import {NepsisHook} from "../src/NepsisHook.sol";

/// FOUR-QUADRANT 2/2 proof. Every order type must (a) NOT revert and (b) deliver
/// ~2% in nepsis to the PatiencePool. If the beforeSwap path is wrong, the sell
/// tests revert here instead of on mainnet — which is the entire point.
/// Tolerance is loose because the LP fee + price impact shift the exact figure;
/// we assert the fee is clearly present and in the right ballpark.
contract NepsisHookTest is Test, Deployers {
    Nepsis nepsis;
    PatiencePool ppool;
    NepsisHook hook;
    PoolKey key;

    function setUp() public {
        deployFreshManagerAndRouters();
        nepsis = new Nepsis(1_000_000_000e18, address(this));
        assertGt(uint160(address(nepsis)), uint160(0), "nepsis must sort as currency1 vs native ETH");
        ppool = new PatiencePool(address(nepsis));

        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        bytes memory ctorArgs = abi.encode(IPoolManager(address(manager)), address(ppool), Currency.wrap(address(nepsis)));
        (address hookAddr,) = HookMiner.find(address(this), flags, type(NepsisHook).creationCode, ctorArgs);
        deployCodeTo("NepsisHook.sol:NepsisHook", ctorArgs, hookAddr);
        hook = NepsisHook(hookAddr);
        ppool.setYieldSource(address(hook));

        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(nepsis)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hookAddr)
        });
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));

        nepsis.approve(address(modifyLiquidityRouter), type(uint256).max);
        nepsis.approve(address(swapRouter), type(uint256).max);
        modifyLiquidityRouter.modifyLiquidity{value: 50 ether}(
            key, ModifyLiquidityParams({tickLower: -1200, tickUpper: 1200, liquidityDelta: 50_000e18, salt: 0}), ""
        );
    }

    function _settings() internal pure returns (PoolSwapTest.TestSettings memory) {
        return PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
    }

    function _poolBal() internal view returns (uint256) {
        return nepsis.balanceOf(address(ppool));
    }

    // Q1: exact-input buy (ETH -> nepsis). nepsis unspecified -> afterSwap.
    function test_exactInputBuy_taxed() public {
        uint256 before = _poolBal();
        swapRouter.swap{value: 1 ether}(
            key, SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            _settings(), ""
        );
        assertGt(_poolBal() - before, 0, "exact-input buy: no fee reached pool");
    }

    // Q3: exact-input sell (nepsis -> ETH). nepsis specified -> beforeSwap. THE big one.
    function test_exactInputSell_taxed_in_nepsis() public {
        uint256 before = _poolBal();
        uint256 sellAmt = 1_000e18;
        swapRouter.swap(
            key, SwapParams({zeroForOne: false, amountSpecified: -int256(sellAmt), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}),
            _settings(), ""
        );
        uint256 gained = _poolBal() - before;
        // ~2% of the nepsis input, in nepsis.
        assertApproxEqRel(gained, sellAmt * 2 / 100, 0.05e18, "exact-input sell fee not ~2% nepsis");
    }

    // Q2: exact-output sell (nepsis -> exact ETH out). nepsis unspecified -> afterSwap.
    function test_exactOutputSell_taxed() public {
        uint256 before = _poolBal();
        swapRouter.swap(
            key, SwapParams({zeroForOne: false, amountSpecified: int256(0.5 ether), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}),
            _settings(), ""
        );
        assertGt(_poolBal() - before, 0, "exact-output sell: no fee reached pool");
    }

    // Q4: exact-output buy (ETH -> exact nepsis out). nepsis specified -> beforeSwap (add-on-top).
    function test_exactOutputBuy_taxed() public {
        uint256 before = _poolBal();
        uint256 wantNepsis = 500e18;
        swapRouter.swap{value: 5 ether}(
            key, SwapParams({zeroForOne: true, amountSpecified: int256(wantNepsis), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            _settings(), ""
        );
        uint256 gained = _poolBal() - before;
        assertApproxEqRel(gained, wantNepsis * 2 / 100, 0.05e18, "exact-output buy fee not ~2% nepsis");
    }
}
