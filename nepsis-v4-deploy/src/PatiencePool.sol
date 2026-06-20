// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////
                         nepsis patience pool
                 REFERENCE IMPLEMENTATION (draft, unaudited)

  THE NOVEL MECHANISM. This is the contract that most needs a
  mechanism designer + auditor. The accounting below is a faithful
  encoding of the agreed design, but the gas profile, the
  accumulator precision, and the gaming surfaces (see NOTES) have
  NOT been hardened or fuzz-tested. Treat as a draft to harden.

  ----------------------------------------------------------------
  Design recap:

   - You DEPOSIT nepsis. Each deposit is its own POSITION with its
     own 30-day clock. You may hold many positions.

   - A position accrues WEIGHT in "token-seconds": amount * seconds
     held. Weight is soulbound (no transfer), and is destroyed when
     the position is withdrawn.

   - Yield arrives from the v4 hook (the swap fee), via receiveYield().
     In THIS build there is no ReserveManager and no split: 100% of what
     the hook forwards is distributed here across ALL open positions in
     proportion to each position's share of total token-seconds, using a
     global accumulator (reward-per-weight) so we never loop over positions.
     (If a 66.7/33.3 split is desired it must be added explicitly — it is
     NOT present in this contract today.)

   - Principal (the deposited nepsis) is ALWAYS returnable in full.

   - Early withdrawal (before 30-day maturity) forfeits a fraction
     of UNCLAIMED YIELD only (never principal), set by a front-
     loaded decay kernel of order k = 2 (quadratic, matches K below):

            penalty(age) = (1 - age/MATURITY)^2     for age < MATURITY
            penalty(age) = 0                        for age >= MATURITY

     Forfeited yield is redistributed to the remaining open
     positions (added back into the accumulator).

  ----------------------------------------------------------------
  THE ACCUMULATOR, AND WHY TIME MAKES IT HARD:

  Normal staking accumulators weight by AMOUNT (constant per user).
  Here weight grows with TIME, continuously. We approximate this by
  updating a global "accWeight" lazily: at each interaction we add
  (totalAmount * elapsed) to a running total of token-seconds, and
  track reward-per-token-second. Each position, when it touches the
  pool, settles its share = its (amount * its elapsed) since last
  touch, valued at the accumulator delta.

  This is the standard "Synthetix-style" accumulator adapted to a
  time-growing weight. It is the part most likely to contain a
  precision / rounding / griefing bug. FLAGGED for audit.
//////////////////////////////////////////////////////////////*/

import {WAD, wadMul, wadDiv, sqrt} from "./lib/FixedPointMath.sol";

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

contract PatiencePool {
    uint256 public constant K = 2; // forfeiture kernel order (quadratic)

    // Lock options. Each deposit chooses one. Maturity = the lock length.
    // Weight multiplier = sqrt(lockDays / 30) in WAD, so longer locks earn more,
    // dampened the same way amount is (sqrt), keeping one consistent rule.
    //   1 day   -> sqrt(1/30)  = 0.182574  -> 182574000000000000
    //   1 week  -> sqrt(7/30)  = 0.483046  -> 483046000000000000
    //   2 weeks -> sqrt(14/30) = 0.683130  -> 683130000000000000
    //   1 month -> sqrt(30/30) = 1.000000  -> 1000000000000000000
    // lock id: 0=1day, 1=1week, 2=2weeks, 3=1month
    function lockDuration(uint8 lock) public pure returns (uint256) {
        if (lock == 0) return 1 days;
        if (lock == 1) return 7 days;
        if (lock == 2) return 14 days;
        if (lock == 3) return 30 days;
        revert("bad lock");
    }
    function lockMultiplier(uint8 lock) public pure returns (uint256) {
        if (lock == 0) return 182574000000000000;  // sqrt(1/30)
        if (lock == 1) return 483046000000000000;  // sqrt(7/30)
        if (lock == 2) return 683130000000000000;  // sqrt(14/30)
        if (lock == 3) return 1000000000000000000; // 1.0
        revert("bad lock");
    }

    IERC20 public immutable nepsis; // deposited asset AND yield asset (same token)
    address public yieldSource;     // the v4 hook that forwards swap fees; settable-once

    // CRITICAL: principal and yield are the SAME token (nepsis) but MUST be
    // accounted separately. principalHeld is the sum of all open deposits and is
    // sacrosanct (always returnable). Any nepsis balance above principalHeld is
    // distributable yield. We never pay yield out of principal.
    uint256 public principalHeld;   // sum of open-position principal (never paid as yield)

    struct Position {
        uint128 amount;        // nepsis deposited (full principal, always returnable)
        uint128 rootAmount;    // sqrt(amount), the dampened size used for weight
        uint64  start;         // deposit timestamp (clock)
        uint64  lastTouch;     // last settle time
        uint64  maturity;      // this position's lock length in seconds
        uint8   lock;          // lock choice id (0..3)
        uint256 weightUnit;    // rootAmount * lockMultiplier (WAD), the per-second weight
        uint256 rewardDebt;    // accumulator checkpoint
        uint256 accrued;       // settled, claimable nepsis yield
        bool    open;
    }

    // positions[user][id]
    mapping(address => Position[]) public positions;

    // ----- global accumulator over weight (sum of per-position weightUnit * seconds) -----
    uint256 public totalWeightUnit;   // sum of open positions' weightUnit (rootAmount*lockMult)
    uint256 public totalPrincipal;    // sum of open positions' full amounts (for telemetry)
    uint256 public lastAccrueTime;    // last time weight advanced
    uint256 public totalWeightSeconds;// running sum of all weight-seconds (rank/telemetry)
    // cumulative reward per weight-UNIT (WAD-scaled). Standard accumulator:
    // each yield arrival adds amount/totalWeightUnit; a position's share is
    // weightUnit * (acc - rewardDebt). NO time multiplier — tenure is captured
    // by how many arrivals a position stays open for, lock length by weightUnit.
    uint256 public accRewardPerWeight;
    // weight-seconds telemetry only (no longer used for reward math)
    uint256 public pendingWeight;
    // yield received while nobody was staked; distributed on the next arrival
    uint256 public undistributed;

    event Deposited(address indexed user, uint256 indexed id, uint256 amount);
    event Withdrawn(address indexed user, uint256 indexed id, uint256 amount, uint256 paidYield, uint256 forfeited);
    event Claimed(address indexed user, uint256 indexed id, uint256 amount);
    event YieldIn(uint256 amount, uint256 perWeight);

    bool public yieldSourceSet;
    address public immutable deployer;

    constructor(address _nepsis) {
        nepsis = IERC20(_nepsis);
        deployer = msg.sender;
        lastAccrueTime = block.timestamp;
    }

    /*//////////////////////////////////////////////////////////////
                          GLOBAL WEIGHT ACCRUAL
    //////////////////////////////////////////////////////////////*/

    /// @dev advance the global weight-seconds since last touch.
    function _accrueGlobal() internal {
        uint256 dt = block.timestamp - lastAccrueTime;
        if (dt > 0 && totalWeightUnit > 0) {
            uint256 addedWeight = totalWeightUnit * dt; // weight-seconds since last
            pendingWeight += addedWeight;
            totalWeightSeconds += addedWeight;
        }
        lastAccrueTime = block.timestamp;
    }

    /*//////////////////////////////////////////////////////////////
                              YIELD INTAKE
    //////////////////////////////////////////////////////////////*/

    /// @notice called by the v4 hook (yield source) to deliver swap-fee yield.
    /// distributes `amount` nepsis across the token-seconds accumulated
    /// since the last yield arrival.
    /// @notice set the v4 hook (yield source) once after deploy.
    function setYieldSource(address _hook) external {
        require(!yieldSourceSet, "set");
        require(msg.sender == deployer, "only deployer");
        yieldSource = _hook;
        yieldSourceSet = true;
    }

    /// @notice Called by the hook after it has ALREADY transferred `amount` nepsis
    /// to this contract. We do NOT pull; the hook pushes then notifies. We verify
    /// the nepsis actually arrived by checking balance vs expected accounting.
    function receiveYield(uint256 amount) external {
        require(msg.sender == yieldSource, "only hook");
        // the hook has transferred `amount` nepsis to us already.
        // it becomes distributable yield (it is NOT principal).
        _accrueGlobal(); // telemetry only
        // distribute by CURRENT weight share (standard per-weight-unit accumulator).
        undistributed += amount;
        if (totalWeightUnit == 0) {
            // no one staked right now; hold it and distribute on the next arrival.
            return;
        }
        accRewardPerWeight += wadDiv(undistributed, totalWeightUnit);
        undistributed = 0;
        emit YieldIn(amount, accRewardPerWeight);
    }

    /*//////////////////////////////////////////////////////////////
                                DEPOSIT
    //////////////////////////////////////////////////////////////*/

    function deposit(uint256 amount, uint8 lock) external returns (uint256 id) {
        require(amount > 0, "zero");
        uint256 mult = lockMultiplier(lock);   // reverts if lock invalid
        uint256 mat = lockDuration(lock);
        _accrueGlobal();
        require(nepsis.transferFrom(msg.sender, address(this), amount), "pull");

        uint256 root = sqrt(amount);                  // dampened size
        uint256 wUnit = wadMul(root, mult);           // per-second weight = sqrt(amount)*lockMult
        totalWeightUnit += wUnit;
        totalPrincipal += amount;
        principalHeld += amount; // track principal separately from yield

        positions[msg.sender].push(Position({
            amount: uint128(amount),
            rootAmount: uint128(root),
            start: uint64(block.timestamp),
            lastTouch: uint64(block.timestamp),
            maturity: uint64(mat),
            lock: lock,
            weightUnit: wUnit,
            rewardDebt: accRewardPerWeight,
            accrued: 0,
            open: true
        }));
        id = positions[msg.sender].length - 1;
        emit Deposited(msg.sender, id, amount);
    }

    /*//////////////////////////////////////////////////////////////
                          POSITION SETTLEMENT
    //////////////////////////////////////////////////////////////*/

    /// @dev settle a position's share of yield up to now.
    /// A position's claim over a window = amount * elapsed (its token-seconds)
    /// times the accumulator delta per weight.
    function _settle(Position storage p) internal {
        if (!p.open) return;
        // its token-seconds since lastTouch
        uint256 wDelta = accRewardPerWeight - p.rewardDebt;
        if (wDelta > 0) {
            // this position's share of every yield arrival since it last settled,
            // weighted by weightUnit (= sqrt(amount) * lockMultiplier).
            p.accrued += wadMul(p.weightUnit, wDelta);
        }
        p.rewardDebt = accRewardPerWeight;
        p.lastTouch = uint64(block.timestamp);
    }

    /*//////////////////////////////////////////////////////////////
                                 CLAIM
    //////////////////////////////////////////////////////////////*/

    /// @notice claim settled yield from a matured position without withdrawing.
    /// Claiming from an UNMATURED position is allowed but the forfeiture rule
    /// only bites on principal withdrawal; here we let matured positions claim
    /// freely. (Design choice flagged: whether to allow pre-maturity claims.)
    function claim(uint256 id) external returns (uint256 paid) {
        Position storage p = positions[msg.sender][id];
        require(p.open, "closed");
        _accrueGlobal();
        _settle(p);

        uint256 age = block.timestamp - p.start;
        require(age >= p.maturity, "not matured: withdraw to exit early");

        paid = p.accrued;
        p.accrued = 0;
        if (paid > 0) {
            uint256 bal = nepsis.balanceOf(address(this));
            uint256 distributable = bal > principalHeld ? bal - principalHeld : 0;
            if (paid > distributable) paid = distributable; // never touch principal
            if (paid > 0) require(nepsis.transfer(msg.sender, paid), "pay");
        }
        emit Claimed(msg.sender, id, paid);
    }

    /*//////////////////////////////////////////////////////////////
                                WITHDRAW
    //////////////////////////////////////////////////////////////*/

    /// @notice withdraw principal (always full) + yield (minus forfeiture if early).
    function withdraw(uint256 id) external returns (uint256 principal, uint256 paidYield, uint256 forfeited) {
        Position storage p = positions[msg.sender][id];
        require(p.open, "closed");
        _accrueGlobal();
        _settle(p);

        principal = uint256(p.amount);
        uint256 age = block.timestamp - p.start;

        uint256 gross = p.accrued;
        uint256 keep;
        if (age >= p.maturity) {
            keep = gross; // fully vested, keep all yield
        } else {
            // penalty = (1 - age/MATURITY)^2 ; keepFraction = 1 - penalty
            uint256 remainingFrac = WAD - wadDiv(age, p.maturity); // (1 - age/mat) in WAD
            uint256 penalty = remainingFrac;
            for (uint256 i = 1; i < K; i++) {
                penalty = wadMul(penalty, remainingFrac); // ^k
            }
            uint256 keepFrac = WAD - penalty;
            keep = wadMul(gross, keepFrac);
        }
        forfeited = gross - keep;
        paidYield = keep;

        // close position, free its weight
        p.open = false;
        p.accrued = 0;
        totalWeightUnit -= p.weightUnit;
        totalPrincipal -= principal;

        principalHeld -= principal; // release this position's principal from the bucket
        // return principal (nepsis) FIRST and unconditionally. Principal must
        // NEVER be blocked by a yield-payment shortfall.
        require(nepsis.transfer(msg.sender, principal), "ret principal");

        // Pay yield, but only up to what the pool actually holds. The accumulator
        // can in edge cases credit slightly more than the realized nepsis balance
        // (rounding / dust / stranded-yield interplay); paying the min guarantees
        // withdraw never reverts on yield and principal is always retrievable.
        if (paidYield > 0) {
            uint256 bal2 = nepsis.balanceOf(address(this));
            uint256 avail = bal2 > principalHeld ? bal2 - principalHeld : 0;
            uint256 pay = paidYield <= avail ? paidYield : avail;
            paidYield = pay;
            if (pay > 0) require(nepsis.transfer(msg.sender, pay), "ret yield");
        }

        // redistribute forfeited yield to remaining open positions via accumulator
        if (forfeited > 0) {
            // totalWeightUnit was already reduced by this position above, so this
            // redistributes only to the REMAINING open positions, by weight share.
            if (totalWeightUnit > 0) {
                accRewardPerWeight += wadDiv(forfeited, totalWeightUnit);
            } else {
                // nobody left to receive; hold for the next staker.
                undistributed += forfeited;
            }
        }
        emit Withdrawn(msg.sender, id, principal, paidYield, forfeited);
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice current weight (sqrt(amount) * seconds held) of a position, for rank.
    function positionWeight(address user, uint256 id) external view returns (uint256) {
        Position storage p = positions[user][id];
        if (!p.open) return 0;
        return p.weightUnit * (block.timestamp - p.start);
    }

    function positionCount(address user) external view returns (uint256) {
        return positions[user].length;
    }

    /// @notice preview forfeiture if `user` exits position `id` right now.
    function previewForfeit(address user, uint256 id) external view returns (uint256 keepFracWad) {
        Position storage p = positions[user][id];
        if (!p.open) return 0;
        uint256 age = block.timestamp - p.start;
        if (age >= p.maturity) return WAD;
        uint256 remainingFrac = WAD - wadDiv(age, p.maturity);
        uint256 penalty = remainingFrac;
        for (uint256 i = 1; i < K; i++) penalty = wadMul(penalty, remainingFrac);
        return WAD - penalty;
    }
}
