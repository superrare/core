// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

/// @notice V5 calls needed to register and validate an ERC-721 collection.
interface ICreatorTokenTransferValidator {
    function setTokenTypeOfCollection(address collection, uint16 tokenType) external;

    function validateTransfer(address caller, address from, address to, uint256 tokenId) external view;
}
