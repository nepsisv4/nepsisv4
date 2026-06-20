// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/*//////////////////////////////////////////////////////////////
                    NepsisHook (Uniswap v4) — TRUE 2/2

  2% fee, ALWAYS taken in nepsis, on BOTH buys and sells, forwarded 100% to the
  PatiencePool so the pool stays single-asset. Verified against the live v4 API
  (June 2026 clone of Uniswap/v4-core, Uniswap/v4-periphery, OpenZeppelin/uniswap-hooks).

  ------------------------------------------------------------------
  WHY THIS NEEDS BOTH beforeSwap AND afterSwap (the thing you decided to take on):

  v4's afterSwap return-delta can ONLY adjust the swap's *unspecified* currency.
  Its beforeSwap return-delta can ONLY adjust the *specified* currency. Whether
  nepsis is "specified" or "unspecified" depends on direction AND exact-in/out.
  Pool is ETH (currency0, native address(0)) / nepsis (currency1).

     quadrant                     | nepsis is | taxed in
     -----------------------------+-----------+-----------
     exact-input  buy  (ETH->NEP) | unspecified | afterSwap   (skim 2% of nepsis OUTPUT)
     exact-output sell (NEP->ETH) | unspecified | afterSwap   (skim 2% of nepsis INPUT)
     exact-input  sell (NEP->ETH) | specified   | beforeSwap  (skim 2% of nepsis INPUT)
     exact-output buy  (ETH->NEP) | specified   | beforeSwap  (add 2% nepsis on top of OUTPUT)

  The two callbacks are mutually exclusive per swap (nepsis is either specified OR
  unspecified, never both), so there is no double charge.

  afterSwap branch mirrors OpenZeppelin BaseHookFee. beforeSwap branch mirrors
  OpenZeppelin BaseAsyncSwap's take()+toBeforeSwapDelta(positive,0) settlement.

  ------------------------------------------------------------------
  ⚠️ THE RISK YOU ACCEPTED — READ BEFORE MAINNET:
  This hook is IMMUTABLE once the pool is created and it sits in the SELL path.
  If the beforeSwap specified-delta accounting is wrong in a way that reverts,
  SELLS REVERT — the token becomes unsellable and reads as a honeypot, with no
  patch possible (only a new pool). OpenZeppelin's audited fee primitive
  deliberately stays on the afterSwap/unspecified side for exactly this reason.
  So this file MUST:
    - compile against YOUR installed v4 version (forge build),
    - pass the FOUR-QUADRANT test in test/NepsisHook.t.sol (asserts ~2% reaches
      the PatiencePool on every order type AND that none revert),
    - and get a v4-literate audit that specifically reviews the beforeSwap
      specified-delta path, type-cast overflow, and reentrancy via
      take -> transfer -> receiveYield.

  Note on exact-output BUYS: the 2% is added ON TOP of the requested output
  (the buyer pays for output + fee), because exact-output guarantees the buyer
  receives exactly what they asked for; the fee cannot be carved out of a fixed
  output without breaking that guarantee. This is a deliberate, documented choice.
//////////////////////////////////////////////////////////////*/

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";

interface IPatienceSink {
    function receiveYield(uint256 amount) external;
}

contract NepsisHook is BaseHook {
    using SafeCast for uint256;

    address public immutable patiencePool;
    Currency public immutable nepsis;

    uint24 public constant FEE_PIPS = 20_000;   // 2.00%
    uint24 public constant PIPS_DENOM = 1_000_000;

    constructor(IPoolManager _pm, address _patiencePool, Currency _nepsis)
        BaseHook(_pm)
    {
        patiencePool = _patiencePool;
        nepsis = _nepsis;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,                 // tax the SPECIFIED-nepsis quadrants
            afterSwap: true,                  // tax the UNSPECIFIED-nepsis quadrants
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @dev True when nepsis is the SPECIFIED currency of this swap.
    /// v4 rule: specified is currency0 iff (amountSpecified < 0) == zeroForOne.
    function _nepsisIsSpecified(PoolKey calldata key, SwapParams calldata p) internal view returns (bool) {
        bool specifiedIsCurrency0 = (p.amountSpecified < 0) == p.zeroForOne;
        bool nepsisIsCurrency0 = (key.currency0 == nepsis);
        return specifiedIsCurrency0 == nepsisIsCurrency0;
    }

    function _forward(uint256 fee) internal {
        // Pull real nepsis from the PoolManager to this hook, then push to the pool.
        poolManager.take(nepsis, address(this), fee);
        nepsis.transfer(patiencePool, fee);
        IPatienceSink(patiencePool).receiveYield(fee);
    }

    // ---- SPECIFIED-nepsis quadrants: exact-input sell, exact-output buy ----
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (!_nepsisIsSpecified(key, params)) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        uint256 specifiedAbs = params.amountSpecified < 0
            ? uint256(-params.amountSpecified)
            : uint256(params.amountSpecified);

        uint256 fee = FullMath.mulDiv(specifiedAbs, FEE_PIPS, PIPS_DENOM);
        if (fee == 0) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        _forward(fee);

        // Positive specified delta: for exact-input it shrinks the amount swapped
        // (input fee skimmed); for exact-output it adds the fee on top. v4 computes
        // amountToSwap = amountSpecified + hookDeltaSpecified and reverts if that
        // would flip exact-in/out, so fee <= specifiedAbs by construction (2% < 100%).
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(fee.toInt128(), 0), 0);
    }

    // ---- UNSPECIFIED-nepsis quadrants: exact-input buy, exact-output sell ----
    function _afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        if (_nepsisIsSpecified(key, params)) {
            // beforeSwap already handled it; do nothing here (no double charge).
            return (IHooks.afterSwap.selector, int128(0));
        }

        // Unspecified amount: if specified is currency0, unspecified is currency1, else currency0.
        bool specifiedIsCurrency0 = (params.amountSpecified < 0) == params.zeroForOne;
        int128 unspecified = specifiedIsCurrency0 ? delta.amount1() : delta.amount0();
        if (unspecified == 0) return (IHooks.afterSwap.selector, int128(0));
        if (unspecified < 0) unspecified = -unspecified;

        uint256 fee = FullMath.mulDiv(uint256(uint128(unspecified)), FEE_PIPS, PIPS_DENOM);
        if (fee == 0) return (IHooks.afterSwap.selector, int128(0));

        _forward(fee);

        // Positive => hook keeps `fee` of the unspecified (nepsis) currency.
        return (IHooks.afterSwap.selector, fee.toInt128());
    }
}
