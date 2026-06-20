// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////
                        FixedPointMath
                    REFERENCE IMPLEMENTATION

  WAD (1e18) fixed-point helpers, including exp and ln.

  expWad / lnWad are the canonical implementations from Solady
  (MIT), reproduced verbatim so the reference build compiles AND
  runs correctly. Same audited functions used widely in production.
  For deployment you may import solady's FixedPointMathLib directly.

  Verified: compiled and executed on an in-memory EVM in evm_test.js;
  outputs checked against the Python oracle (test/reference_oracle.py).
//////////////////////////////////////////////////////////////*/

uint256 constant WAD = 1e18;

function wadMul(uint256 a, uint256 b) pure returns (uint256) {
    return (a * b) / WAD;
}

function wadDiv(uint256 a, uint256 b) pure returns (uint256) {
    require(b != 0, "div by zero");
    return (a * WAD) / b;
}

/// @notice integer square root, floor(sqrt(x)). Dampens the amount component
/// of pool weight (weight = sqrt(amount) * time).
function sqrt(uint256 x) pure returns (uint256 z) {
    if (x == 0) return 0;
    z = (x + 1) / 2;
    uint256 y = x;
    while (z < y) {
        y = z;
        z = (x / z + z) / 2;
    }
    return y;
}

/// @notice e^x for signed WAD x. Canonical Solady expWad (MIT).
function expWadSigned(int256 x) pure returns (int256 r) {
    unchecked {
        if (x <= -41446531673892822313) return r;
        assembly {
            if iszero(slt(x, 135305999368893231589)) {
                mstore(0x00, 0xa37bfec9)
                revert(0x1c, 0x04)
            }
        }
        x = (x << 78) / 5 ** 18;
        int256 k = ((x << 96) / 54916777467707473351141471128 + 2 ** 95) >> 96;
        x = x - k * 54916777467707473351141471128;
        int256 y = x + 1346386616545796478920950773328;
        y = ((y * x) >> 96) + 57155421227552351082224309758442;
        int256 p = y + x - 94201549194550492254356042504812;
        p = ((p * y) >> 96) + 28719021644029726153956944680412240;
        p = p * x + (4385272521454847904659076985693276 << 96);
        int256 q = x - 2855989394907223263936484059900;
        q = ((q * x) >> 96) + 50020603652535783019961831881945;
        q = ((q * x) >> 96) - 533845033583426703283633433725380;
        q = ((q * x) >> 96) + 3604857256930695427073651918091429;
        q = ((q * x) >> 96) - 14423608567350463180887372962807573;
        q = ((q * x) >> 96) + 26449188498355588339934803723976023;
        assembly {
            r := sdiv(p, q)
        }
        r = int256(
            (uint256(r) * 3822833074963236453042738258902158003155416615667) >> uint256(195 - k)
        );
    }
}

/// @notice ln(x) for WAD x. Canonical Solady lnWad (MIT).
function lnWadSigned(int256 x) pure returns (int256 r) {
    assembly {
        r := shl(7, lt(0xffffffffffffffffffffffffffffffff, x))
        r := or(r, shl(6, lt(0xffffffffffffffff, shr(r, x))))
        r := or(r, shl(5, lt(0xffffffff, shr(r, x))))
        r := or(r, shl(4, lt(0xffff, shr(r, x))))
        r := or(r, shl(3, lt(0xff, shr(r, x))))
        if iszero(sgt(x, 0)) {
            mstore(0x00, 0x1615e638)
            revert(0x1c, 0x04)
        }
        r := xor(r, byte(and(0x1f, shr(shr(r, x), 0x8421084210842108cc6318c6db6d54be)),
            0xf8f9f9faf9fdfafbf9fdfcfdfafbfcfef9fafdfafcfcfbfefafafcfbffffffff))
        x := shr(159, shl(r, x))
        let p := sub(
            sar(96, mul(add(43456485725739037958740375743393,
            sar(96, mul(add(24828157081833163892658089445524,
            sar(96, mul(add(3273285459638523848632254066296,
                x), x))), x))), x)), 11111509109440967052023855526967)
        p := sub(sar(96, mul(p, x)), 45023709667254063763336534515857)
        p := sub(sar(96, mul(p, x)), 14706773417378608786704636184526)
        p := sub(mul(p, x), shl(96, 795164235651350426258249787498))
        let q := add(5573035233440673466300451813936, x)
        q := add(71694874799317883764090561454958, sar(96, mul(x, q)))
        q := add(283447036172924575727196451306956, sar(96, mul(x, q)))
        q := add(401686690394027663651624208769553, sar(96, mul(x, q)))
        q := add(204048457590392012362485061816622, sar(96, mul(x, q)))
        q := add(31853899698501571402653359427138, sar(96, mul(x, q)))
        q := add(909429971244387300277376558375, sar(96, mul(x, q)))
        p := sdiv(p, q)
        p := mul(1677202110996718588342820967067443963516166, p)
        p := add(mul(16597577552685614221487285958193947469193820559219878177908093499208371, sub(159, r)), p)
        p := add(600920179829731861736702779321621459595472258049074101567377883020018308, p)
        r := sar(174, p)
    }
}

/// @notice e^x for WAD x, clamped non-negative (curve only needs x>=0).
function wadExp(int256 x) pure returns (uint256) {
    int256 r = expWadSigned(x);
    return r < 0 ? 0 : uint256(r);
}

/// @notice ln(x) for WAD x (curve only passes x>=WAD, so result >=0).
function wadLn(uint256 xu) pure returns (int256) {
    return lnWadSigned(int256(xu));
}
