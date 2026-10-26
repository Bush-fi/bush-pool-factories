// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice ERC-7572: contract-level metadata (a JSON file with the name, description, image and links).
interface IERC7572 {
    /// @notice The contract's metadata changed (here: emitted once, when the token is deployed).
    event ContractURIUpdated();

    /// @notice The URI of the contract's metadata JSON.
    function contractURI() external view returns (string memory);
}

/**
 * @notice The token a RukusLaunch launch sells: a plain, fixed-supply ERC20 (18 decimals), with its metadata URI.
 * @dev No owner, no mint, no burn hooks, no fees. The whole supply is minted once, to the factory, which puts all of it
 * into the pool in the same transaction. So every launch token in circulation was bought from the curve, and the curve
 * always holds enough quote to buy each of them back (see RukusLaunchPoolFactory).
 *
 * The metadata URI (ERC-7572 `contractURI`, typically `ipfs://...` pointing at a JSON with the image, description and
 * links) is set once, at deployment, and nothing can change it, as with pump.fun: buyers know the image and description
 * can't be swapped after they buy. A content-addressed URI (IPFS, Arweave) also fixes the content behind it.
 */
contract RukusLaunchToken is ERC20, IERC7572 {
    string private _contractURI;

    constructor(
        string memory name,
        string memory symbol,
        uint256 supply,
        address recipient,
        string memory metadataURI
    ) ERC20(name, symbol) {
        _contractURI = metadataURI;
        _mint(recipient, supply);
        emit ContractURIUpdated();
    }

    /// @inheritdoc IERC7572
    function contractURI() external view returns (string memory) {
        return _contractURI;
    }
}
