// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import {ICart} from "./ICart.sol";

/// @notice Shared fulfillment classification and collection-owner checks for Cart and CartLens.
/// @dev Callers retain their validation order and translate failed checks into their own diagnostics.
library CartValidation {
    function isOnChainKind(ICart.FulfillmentKind kind) internal pure returns (bool) {
        // Identify the fulfillment kinds that call an NFT contract during settlement.
        return kind == ICart.FulfillmentKind.ERC721_TRANSFER || kind == ICart.FulfillmentKind.ERC1155_TRANSFER
            || kind == ICart.FulfillmentKind.ERC721_MINT_TO || kind == ICart.FulfillmentKind.ERC1155_MINT_TO;
    }

    function isMintKind(ICart.FulfillmentKind kind) internal pure returns (bool) {
        // Identify the fulfillment kinds that require the seller to own the collection.
        return kind == ICart.FulfillmentKind.ERC721_MINT_TO || kind == ICart.FulfillmentKind.ERC1155_MINT_TO;
    }

    function isContractOwner(address tokenContract, address expectedOwner) internal view returns (bool) {
        // Ask the collection to report its owner without allowing state changes.
        (bool success, bytes memory data) = tokenContract.staticcall(abi.encodeWithSignature("owner()"));
        // Failed calls and truncated ABI words cannot establish collection ownership.
        if (!success || data.length < 32) return false;

        // Read the first ABI word so malformed address padding can be rejected without risking an ABI-decoding revert.
        uint256 encodedOwner;
        assembly ("memory-safe") {
            encodedOwner := mload(add(data, 0x20))
        }
        // Accept only a canonically encoded address that matches the seller.
        return encodedOwner <= type(uint160).max && address(uint160(encodedOwner)) == expectedOwner;
    }
}
