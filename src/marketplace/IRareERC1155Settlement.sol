// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import {IRareERC1155MarketplaceTypes} from "./IRareERC1155MarketplaceTypes.sol";

/// @author SuperRare Labs Inc.
/// @title IRareERC1155Settlement
/// @notice Settlement entrypoints executed through `RareERC1155Marketplace` delegatecalls.
interface IRareERC1155Settlement is IRareERC1155MarketplaceTypes {
    /// @notice Mints tokens from configured primary sales.
    /// @dev Intended for delegatecall from the marketplace proxy. Direct calls to the settlement implementation revert.
    function mintDirectSaleBatch(address _contractAddress, address _currencyAddress, MintRequest[] calldata _requests)
        external
        payable;

    /// @notice Buys tokens from a seller's secondary fixed-price listings.
    /// @dev Intended for delegatecall from the marketplace proxy. Direct calls to the settlement implementation revert.
    function buyBatch(
        address _contractAddress,
        address _seller,
        address _currencyAddress,
        BuyRequest[] calldata _requests
    ) external payable;

    /// @notice Accepts all or part of an ERC1155 token offer.
    /// @dev Intended for delegatecall from the marketplace proxy. Direct calls to the settlement implementation revert.
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

    /// @notice Executes a buyer cart of direct-sale mints and secondary fixed-price listing purchases.
    /// @dev Intended for delegatecall from the marketplace proxy. Direct calls to the settlement implementation revert.
    function checkout(CheckoutItem[] calldata _items) external payable returns (CheckoutExecution memory);

    /// @notice Executes one already validated checkout item through a nested delegatecall rollback boundary.
    /// @dev Settlement-only entrypoint; the marketplace proxy does not expose this selector.
    function executeCheckoutItem(
        CheckoutItem calldata _item,
        uint256 _remainingEth,
        address _seller,
        uint256 _grossAmount,
        uint256 _marketplaceFee,
        address payable[] calldata _splitRecipients,
        uint8[] calldata _splitRatios
    ) external payable returns (uint256 totalPaid, uint256 newRemainingEth);

    /// @notice Executes payout for a checkout item through a nested rollback boundary.
    /// @dev Settlement-only entrypoint; the marketplace proxy does not expose this selector.
    function executeCheckoutPayout(
        CheckoutItem calldata _item,
        address _seller,
        uint256 _grossAmount,
        uint256 _marketplaceFee,
        address payable[] calldata _splitRecipients,
        uint8[] calldata _splitRatios
    ) external payable;
}
