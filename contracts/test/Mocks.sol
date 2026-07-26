// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// A Robinhood Chain stock token: balances never move on a dividend, the
/// multiplier does, and the next one is announced before it lands.
contract MockHoodStock is ERC20 {
    uint256 public uiMultiplier = 1e18;
    uint256 public newUIMultiplier = 1e18;
    uint256 public effectiveAt;
    bool public tokenPaused;
    bool public oraclePaused;

    constructor(string memory n, string memory s) ERC20(n, s) {
        _mint(msg.sender, 1_000_000e18);
    }

    function balanceOfUI(address a) external view returns (uint256) {
        return (balanceOf(a) * uiMultiplier) / 1e18;
    }

    function announceDividend(uint256 next, uint256 at) external {
        newUIMultiplier = next;
        effectiveAt = at;
    }

    function payDividend(uint256 next) external {
        uiMultiplier = next;
        newUIMultiplier = next;
        effectiveAt = block.timestamp;
    }

    function setPaused(bool v) external { tokenPaused = v; }
    function mintTo(address to, uint256 v) external { _mint(to, v); }
}

/// A plain ERC-20, to prove the library does not assume it is on a stock token.
contract MockPlain is ERC20 {
    constructor() ERC20("Plain", "PLN") { _mint(msg.sender, 1_000_000e18); }
    function mintTo(address to, uint256 v) external { _mint(to, v); }
}
