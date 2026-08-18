// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import {ICart} from "./ICart.sol";

/// @notice Delegate-called payment executor used by Cart.
/// @dev The executor never owns funds or state. Cart delegate-calls it so all token custody,
///      `msg.sender`, `msg.value`, and ERC-7201 storage remain in the Cart proxy.
interface ICartPayments {
    struct AssetSnapshot {
        address token;
        uint256 cartBalance;
        uint256 routerBalance;
    }

    struct PaymentState {
        AssetSnapshot[] assetSnapshots;
        uint256 inputBaseline;
        uint256 nativeBaseline;
        uint256 routerNativeBaseline;
    }

    function begin(
        ICart.PurchaseOrder calldata order,
        ICart.OrderLine[] calldata lines,
        ICart.PayoutRoute calldata route
    ) external payable returns (PaymentState memory state);

    function finish(
        bytes32 orderId,
        address paymentCurrency,
        ICart.OrderLine[] calldata lines,
        PaymentState calldata state
    ) external payable;
}
