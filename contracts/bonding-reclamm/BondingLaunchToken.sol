// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @notice The token a BondingReClamm launch sells: a plain, fixed-supply ERC20 (18 decimals).
 * @dev No owner, no mint, no burn hooks, no fees. The whole supply is minted once, to the factory, which puts all of it
 * into the pool in the same transaction. So every launch token in circulation was bought from the curve, and the curve
 * always holds enough quote to buy each of them back (see BondingReClammPoolFactory).
 */
contract BondingLaunchToken is ERC20 {
    constructor(string memory name, string memory symbol, uint256 supply, address recipient) ERC20(name, symbol) {
        _mint(recipient, supply);
    }
}
