// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import {Ownable} from "openzeppelin-contracts/access/Ownable.sol";
import {Clones} from "openzeppelin-contracts/proxy/Clones.sol";

import {IRareERC1155ContractFactory} from "./IRareERC1155ContractFactory.sol";
import {RareERC1155} from "./RareERC1155.sol";

/// @author SuperRare Labs Inc.
/// @title RareERC1155ContractFactory
/// @notice Clone factory for RARE Protocol ERC1155 collections.
/// @dev Deploys EIP-1167 minimal proxies initialized with the caller as collection owner.
contract RareERC1155ContractFactory is IRareERC1155ContractFactory, Ownable {
    address public override rareERC1155;
    address public override defaultMinter;

    /// @notice Deploys the initial ERC1155 implementation used for clones.
    constructor() {
        // Deployment operation: create the clone implementation controlled by the factory owner.
        rareERC1155 = address(new RareERC1155());
    }

    /// @inheritdoc IRareERC1155ContractFactory
    function setRareERC1155(address _rareERC1155) external onlyOwner {
        // Atomic guard: clone implementation cannot be the zero address.
        if (_rareERC1155 == address(0)) revert ZeroAddressUnsupported();

        // State write: future clones use the new implementation.
        rareERC1155 = _rareERC1155;
        emit RareERC1155Updated(_rareERC1155);
    }

    /// @inheritdoc IRareERC1155ContractFactory
    function setDefaultMinter(address _defaultMinter) external onlyOwner {
        // State write: future clones inherit this minter approval during initialization.
        defaultMinter = _defaultMinter;
        emit DefaultMinterUpdated(_defaultMinter);
    }

    /// @inheritdoc IRareERC1155ContractFactory
    function createRareERC1155Contract(string calldata _name, string calldata _symbol, string calldata _baseURI)
        external
        returns (address)
    {
        // Clone operation: deploy a minimal proxy that delegates to the current implementation.
        address clone = Clones.clone(rareERC1155);

        // Initialization call: set clone metadata, owner, and optional default minter.
        RareERC1155(clone).init(_name, _symbol, _baseURI, msg.sender, defaultMinter);

        emit RareERC1155ContractCreated(clone, msg.sender);

        return clone;
    }
}
