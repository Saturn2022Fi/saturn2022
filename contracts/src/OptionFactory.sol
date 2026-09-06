// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {OptionHouse} from "./OptionHouse.sol";
import {CoveredCallVault} from "./CoveredCallVault.sol";
import {VolOracle} from "./VolOracle.sol";

/// An options market on any feed, opened by anyone.
///
/// The house prices from a feed's publish threshold and its ring of update
/// times, and the oracle now measures both from the feed alone. So nothing
/// about listing a market needs a person: name the token and the feed that
/// prices it, and this contract registers the feed if nobody has, lists the
/// market in the house it owns, and stands up a covered-call vault for it,
/// run by the same keeper as every other vault here. From that block on,
/// anyone holding a whole token can put it in the vault or write against it
/// directly, and anyone can buy what is written.
///
/// What this cannot check is that the token is the asset the feed prices.
/// The chain has no registry of that. A market opened with a feed for one
/// thing and a token for another prices real options on a token nobody
/// wants, and the only defence is that nobody has to buy them. The site
/// lists a market once that pairing has been looked at.
contract OptionFactory {
    OptionHouse public immutable house;
    VolOracle public immutable oracle;
    /// Who runs the vaults: writes and settles, never withdraws. Rotated by
    /// the steward if the key it lives on ever has to change.
    address public keeper;
    address public immutable steward;
    /// Same markup as every market the house was launched with.
    uint16 public constant MARKUP = 3000;

    CoveredCallVault[] public vaults;              // index is the market id
    mapping(address => bool) public opened;        // one market per feed

    event Opened(uint32 indexed market, address indexed stock, address indexed feed, address vault, int256 deviation);
    event Rekeyed(address keeper);

    error AlreadyOpen();
    error NotSteward();

    constructor(address usdc, VolOracle oracle_, address keeper_) {
        house = new OptionHouse(usdc, new OptionHouse.Market[](0));
        oracle = oracle_;
        keeper = keeper_;
        steward = msg.sender;
    }

    /// Open the market for `stock`, priced by `feed`. Registers the feed with
    /// the oracle if it is not yet, so a cold feed costs the caller that walk.
    function open(address stock, address feed) external returns (uint32 id, CoveredCallVault vault) {
        if (opened[feed]) revert AlreadyOpen();
        opened[feed] = true;
        int256 d = oracle.deviation(feed);
        if (d == 0) {
            oracle.register(feed);
            d = oracle.deviation(feed);
        }
        id = house.list(stock, feed, int64(d), MARKUP);
        string memory sym = IERC20Metadata(stock).symbol();
        vault = new CoveredCallVault(
            house, id, address(0), string.concat("Saturn ", sym, " Covered Call"), string.concat("s", sym)
        );
        vault.setKeeper(keeper);
        vaults.push(vault);
        emit Opened(id, stock, feed, address(vault), d);
    }

    function vaultCount() external view returns (uint256) { return vaults.length; }

    /// Move every vault, and every future one, to a new keeper.
    function rekey(address k) external {
        if (msg.sender != steward) revert NotSteward();
        keeper = k;
        for (uint256 i = 0; i < vaults.length; i++) vaults[i].setKeeper(k);
        emit Rekeyed(k);
    }
}
