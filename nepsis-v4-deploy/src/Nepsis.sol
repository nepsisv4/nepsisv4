// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title nepsis
/// @notice A clean, standard ERC-20. No tax, no owner, no special powers.
/// All fee logic lives in the Uniswap v4 hook attached to the pool, NOT here.
/// Fixed supply minted once at deployment to the deployer, who seeds the
/// Uniswap v4 pool (one-sided) and distributes as desired.
contract Nepsis {
    string public constant name = "nepsis";
    string public constant symbol = "nepsis";
    uint8  public constant decimals = 18;

    uint256 public immutable totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(uint256 _supply, address _mintTo) {
        totalSupply = _supply;
        balanceOf[_mintTo] = _supply;
        emit Transfer(address(0), _mintTo, _supply);
    }

    function transfer(address to, uint256 v) external returns (bool) {
        return _transfer(msg.sender, to, v);
    }

    function transferFrom(address from, address to, uint256 v) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) {
            require(a >= v, "allowance");
            allowance[from][msg.sender] = a - v;
        }
        return _transfer(from, to, v);
    }

    function approve(address s, uint256 v) external returns (bool) {
        allowance[msg.sender][s] = v;
        emit Approval(msg.sender, s, v);
        return true;
    }

    function _transfer(address from, address to, uint256 v) internal returns (bool) {
        require(balanceOf[from] >= v, "balance");
        require(to != address(0), "zero");
        unchecked { balanceOf[from] -= v; balanceOf[to] += v; }
        emit Transfer(from, to, v);
        return true;
    }
}
