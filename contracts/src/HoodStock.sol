// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// Robinhood Chain stock tokens are ERC-20s carrying the ERC-8056 scaled-amount
/// extension. A dividend does not change anyone's balance: it raises a
/// multiplier, so one token comes to stand for more than one share while
/// `balanceOf` reports the number it always did.
///
/// For value, this is already handled. The Chainlink feed for a stock token
/// returns the price of one token, multiplier included, so `balanceOf` times the
/// feed price is right and applying the multiplier on top of it counts the
/// dividend twice. Use `toShares` to say how many shares a position stands for,
/// never to convert a balance before pricing it.
///
/// The parts with no plain-ERC-20 equivalent are the ones worth designing
/// around: these tokens announce the next dividend before it lands, and they can
/// be paused.
interface IHoodStock {
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function decimals() external view returns (uint8);
    /// How many shares one token stands for, 1e18 based.
    function uiMultiplier() external view returns (uint256);
    /// The multiplier that takes over at `effectiveAt`.
    function newUIMultiplier() external view returns (uint256);
    function effectiveAt() external view returns (uint256);
    function tokenPaused() external view returns (bool);
    function oraclePaused() external view returns (bool);
}

library HoodStock {
    uint256 internal constant ONE = 1e18;

    error TokenIsPaused(address token);

    /// True when the token carries a multiplier at all. Plain ERC-20s do not,
    /// so every read below has to survive the call reverting.
    function isHoodStock(address token) internal view returns (bool) {
        (bool ok, bytes memory ret) =
            token.staticcall(abi.encodeWithSelector(IHoodStock.uiMultiplier.selector));
        return ok && ret.length == 32;
    }

    /// Shares one token stands for. A plain ERC-20 answers 1.0, so callers can
    /// use this unconditionally.
    function multiplier(address token) internal view returns (uint256) {
        (bool ok, bytes memory ret) =
            token.staticcall(abi.encodeWithSelector(IHoodStock.uiMultiplier.selector));
        if (!ok || ret.length != 32) return ONE;
        uint256 m = abi.decode(ret, (uint256));
        return m == 0 ? ONE : m;
    }

    /// The same amount counted in shares rather than tokens. This is a display
    /// conversion. Do not pair it with a feed price, which already includes the
    /// multiplier.
    function toShares(address token, uint256 amount) internal view returns (uint256) {
        return (amount * multiplier(token)) / ONE;
    }

    /// An account's position counted in shares. For its value, take `balanceOf`
    /// times the feed price and leave the multiplier out of it.
    function shareBalanceOf(address token, address account) internal view returns (uint256) {
        return toShares(token, IHoodStock(token).balanceOf(account));
    }

    /// A dividend that has been announced but has not landed yet, as a fraction
    /// of the current multiplier, 1e18 based. Zero when nothing is pending.
    function pendingDividend(address token) internal view returns (uint256 growth, uint256 at) {
        (bool ok, bytes memory ret) =
            token.staticcall(abi.encodeWithSelector(IHoodStock.newUIMultiplier.selector));
        if (!ok || ret.length != 32) return (0, 0);
        uint256 next = abi.decode(ret, (uint256));
        uint256 now_ = multiplier(token);
        if (next <= now_) return (0, 0);

        (ok, ret) = token.staticcall(abi.encodeWithSelector(IHoodStock.effectiveAt.selector));
        at = (ok && ret.length == 32) ? abi.decode(ret, (uint256)) : 0;
        if (at != 0 && at <= block.timestamp) return (0, 0);
        growth = ((next - now_) * ONE) / now_;
    }

    /// A paused stock token cannot be moved, so a payout that promises one is a
    /// promise that cannot be kept. Callers check before accepting a deposit.
    function requireMovable(address token) internal view {
        (bool ok, bytes memory ret) =
            token.staticcall(abi.encodeWithSelector(IHoodStock.tokenPaused.selector));
        if (ok && ret.length == 32 && abi.decode(ret, (bool))) revert TokenIsPaused(token);
    }
}
