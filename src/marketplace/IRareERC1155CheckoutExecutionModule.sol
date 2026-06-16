// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import {IRareERC1155MarketplaceTypes} from "./IRareERC1155MarketplaceTypes.sol";

/// @author SuperRare Labs Inc.
/// @title IRareERC1155CheckoutExecutionModule
/// @notice Checkout entrypoints executed through `RareERC1155Marketplace` delegatecalls.
interface IRareERC1155CheckoutExecutionModule is IRareERC1155MarketplaceTypes {
    /// @notice Executes a payer cart of direct-sale mints and secondary fixed-price listing purchases.
    /// @dev Intended for delegatecall from the marketplace proxy. Direct calls to the module implementation revert.
    function checkout(
        address _recipient,
        CheckoutItem[] calldata _items
    ) external payable returns (CheckoutExecution memory);

    /// @notice Executes one already validated checkout item through a nested delegatecall rollback boundary.
    /// @dev Module-only entrypoint; the marketplace proxy does not expose this selector.
    function executeCheckoutItem(
        CheckoutItem calldata _item,
        uint256 _remainingEth,
        address _recipient,
        address _seller,
        uint256 _grossAmount,
        uint256 _marketplaceFee,
        address payable[] calldata _splitRecipients,
        uint8[] calldata _splitRatios
    ) external payable returns (uint256 totalPaid, uint256 newRemainingEth);

    /// @notice Executes payout for a checkout item through a nested rollback boundary.
    /// @dev Module-only entrypoint; the marketplace proxy does not expose this selector.
    function executeCheckoutPayout(
        CheckoutItem calldata _item,
        address _seller,
        uint256 _grossAmount,
        uint256 _marketplaceFee,
        address payable[] calldata _splitRecipients,
        uint8[] calldata _splitRatios
    ) external payable;
}
