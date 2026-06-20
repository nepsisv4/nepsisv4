// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";

interface IPositionManager {
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;
}

interface IAllowanceTransfer {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

interface IERC20Min {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// @notice Step 6-7: initialize the nepsis/ETH v4 pool and seed it with ONE-SIDED
/// nepsis liquidity (no ETH from you). Run AFTER Deploy.s.sol and AFTER you have
/// rehearsed the whole flow on a testnet.
///
/// Why this is one-sided and how the price moves:
///   Native ETH is address(0), always the lowest address, so ETH = currency0 and
///   nepsis = currency1. A concentrated position is 100% currency1 (nepsis) only
///   when the current tick is at/above the top of its range. So we initialize the
///   pool AT the top tick (nepsis at its cheapest) and place the range BELOW it.
///   Buyers swap ETH -> nepsis, pushing the tick DOWN through the range: your
///   nepsis sells off, ETH accumulates in the pool, and nepsis gets more expensive
///   in ETH terms as it goes. You deposit only nepsis; buyers bring the ETH.
///
/// Picking ticks (do this off-chain, then pass them in):
///   price P (in tick terms) = currency1/currency0 = nepsis per 1 ETH.
///   Both tokens are 18 decimals here, so no decimal scaling.
///   tick = floor( ln(P) / ln(1.0001) ), then round to a multiple of TICK_SPACING.
///   START_TICK (== tickUpper) should encode your LAUNCH price (nepsis cheapest);
///   TICK_LOWER should encode your FLOOR price (nepsis most expensive).
///   START_TICK > TICK_LOWER. Quick JS in the runbook does the conversion.
///
/// Env in: NEPSIS, HOOK, START_TICK, TICK_LOWER, NEPSIS_LIQUIDITY (whole tokens),
///         FEE (LP fee, e.g. 3000), TICK_SPACING (e.g. 60), PRIVATE_KEY.
contract InitializeAndMint is Script {
    function _addrs() internal view returns (address pm, address posm, address permit2) {
        if (block.chainid == 1) {
            return (
                0x000000000004444c5dc75cB358380D2e3dE08A90, // PoolManager
                0xbd216513d74c8Cf14cF4747E6AaA6420FF64ee9E, // PositionManager
                0x000000000022D473030F116dDEE9F6B43aC78BA3  // Permit2
            );
        }
        if (block.chainid == 11155111) {
            return (
                0xE03A1074c86CFeDd5C142C4F04F1a1536e203543, // PoolManager (Sepolia)
                0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4, // PositionManager (Sepolia)
                0x000000000022D473030F116dDEE9F6B43aC78BA3  // Permit2
            );
        }
        revert("addresses not set for this chainid");
    }

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);

        address nepsis = vm.envAddress("NEPSIS");
        address hook = vm.envAddress("HOOK");
        int24 startTick = int24(vm.envInt("START_TICK"));   // == tickUpper
        int24 tickLower = int24(vm.envInt("TICK_LOWER"));
        uint24 fee = uint24(vm.envOr("FEE", uint256(3000)));
        int24 tickSpacing = int24(vm.envOr("TICK_SPACING", uint256(60)));
        uint256 nepsisAmount = vm.envUint("NEPSIS_LIQUIDITY") * 1e18;

        require(tickLower < startTick, "tickLower must be below startTick");
        require(startTick % tickSpacing == 0 && tickLower % tickSpacing == 0, "ticks must align to spacing");

        (address pmAddr, address posmAddr, address permit2) = _addrs();

        // ETH = currency0 (address 0), nepsis = currency1.
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(nepsis),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(hook)
        });

        // Initialize at the top tick => position is 100% nepsis (one-sided).
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(startTick);

        // Liquidity from a pure nepsis (currency1) amount across [tickLower, startTick].
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(startTick);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount1(sqrtLower, sqrtUpper, nepsisAmount);
        require(liquidity > 0, "zero liquidity — check amount/ticks");

        // MINT_POSITION then SETTLE_PAIR. amount0Max (ETH) = 0 since one-sided;
        // amount1Max set to the nepsis we intend to provide (+1 wei rounding slack).
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(key, tickLower, startTick, liquidity, uint128(0), uint128(nepsisAmount + 1), me, bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1);
        bytes memory unlockData = abi.encode(actions, params);

        vm.startBroadcast(pk);

        // a) initialize the pool with this hook in the key.
        IPoolManager(pmAddr).initialize(key, sqrtPriceX96);

        // b) approvals: nepsis -> Permit2 (ERC20), then Permit2 -> PositionManager.
        IERC20Min(nepsis).approve(permit2, type(uint256).max);
        IAllowanceTransfer(permit2).approve(nepsis, posmAddr, uint160(nepsisAmount + 1), uint48(block.timestamp + 3600));

        // c) mint the one-sided position. value = 0 (no ETH deposited).
        IPositionManager(posmAddr).modifyLiquidities{value: 0}(unlockData, block.timestamp + 3600);

        vm.stopBroadcast();

        console2.log("Pool initialized + one-sided nepsis liquidity minted.");
        console2.log("startTick (tickUpper)", int256(startTick));
        console2.log("tickLower            ", int256(tickLower));
        console2.log("liquidity            ", uint256(liquidity));
        console2.log("nepsis provided      ", nepsisAmount);
    }
}
