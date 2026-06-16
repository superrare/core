// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import {IRareERC1155MarketplaceTypes} from "./IRareERC1155MarketplaceTypes.sol";

/// @author SuperRare Labs Inc.
/// @title IRareERC1155TradeExecutionModule
/// @notice Direct trade entrypoints executed through `RareERC1155Marketplace` delegatecalls.
interface IRareERC1155TradeExecutionModule is IRareERC1155MarketplaceTypes {
    /// @notice Mints tokens from configured primary sales.
    /// @dev Intended for delegatecall from the marketplace proxy. Direct calls to the module implementation revert.
    function mintDirectSaleBatch(
        address _contractAddress,
        address _currencyAddress,
        address _recipient,
        MintRequest[] calldata _requests
    ) external payable;

    /// @notice Buys tokens from a seller's secondary fixed-price listings.
    /// @dev Intended for delegatecall from the marketplace proxy. Direct calls to the module implementation revert.
    function buyBatch(
        address _contractAddress,
        address _seller,
        address _currencyAddress,
        address _recipient,
        BuyRequest[] calldata _requests
    ) external payable;

    /// @notice Accepts all or part of an ERC1155 token offer.
    /// @dev Intended for delegatecall from the marketplace proxy. Direct calls to the module implementation revert.
    function acceptOffer(
        address _contractAddress,
        uint256 _tokenId,
        address _buyer,
        address _currencyAddress,
        uint256 _price,
        uint256 _quantity,
        address payable[] calldata _splitRecipients,
        uint8[] calldata _splitRatios
    ) external;
}
