// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";

import {CartStorage} from "./CartStorage.sol";
import {ICart} from "./ICart.sol";
import {ICartPayments} from "./ICartPayments.sol";
import {ICartRoutePolicy} from "./ICartRoutePolicy.sol";
import {IPermit2Cart} from "./IPermit2Cart.sol";

interface IWETHCartPayments is IERC20 {
    // Wrap native currency into WETH.
    function deposit() external payable;
    // Unwrap WETH into native currency.
    function withdraw(uint256 amount) external;
}

/// @title SuperRare Cart Payments
/// @notice Delegate-called funding, routing, payout, and protocol-spread implementation for Cart.
/// @dev This contract is intentionally stateless. Cart delegate-calls it so the proxy remains the
///      sole owner of funds and storage while payment bytecode stays outside Cart's EIP-170 limit.
contract CartPayments is CartStorage, ICartPayments {
    using SafeERC20 for IERC20;

    error DirectCallNotAllowed();
    event ProtocolSpreadCaptured(
        bytes32 indexed orderId, address indexed currency, address indexed recipient, uint256 amount
    );

    uint256 private constant NO_GROUP = type(uint256).max;

    // The route policy is fixed in the implementation and shared by every delegate call.
    ICartRoutePolicy private immutable ROUTE_POLICY;
    // The implementation address proves that a call came through delegatecall.
    address private immutable SELF;

    struct Payout {
        // Token used for this payout. Native currency uses WETH internally.
        address token;
        // Address that receives the payout.
        address recipient;
        // Total amount for this token and recipient pair.
        uint256 amount;
        // First line that created this payout. Used for error reporting.
        uint256 lineIndex;
        // True when the recipient must receive native currency instead of an ERC-20.
        bool native;
    }

    constructor(address routePolicy_) {
        // Store the route policy in immutable implementation code.
        ROUTE_POLICY = ICartRoutePolicy(routePolicy_);
        // Save this implementation address for the delegate-call guard.
        SELF = address(this);
    }

    modifier onlyDelegateCall() {
        // In a delegate call, address(this) is Cart and differs from SELF.
        if (address(this) == SELF) revert DirectCallNotAllowed();
        // Run the protected function in Cart's storage and balance context.
        _;
    }

    function begin(
        ICart.PurchaseOrder calldata order,
        ICart.OrderLine[] calldata lines,
        ICart.PayoutRoute calldata route
    ) external payable onlyDelegateCall returns (PaymentState memory state) {
        // Validate the complete order-wide plan before taking funds or calling the router.
        (ICartRoutePolicy.Summary memory summary, address[] memory settlementTokens) =
            _validateRoute(order.paymentCurrency, lines, route);

        uint256 requiredInput = summary.inputAmount;
        address inputToken = _currencyToken(order.paymentCurrency, _cartConfig().weth);
        for (uint256 i = 0; i < lines.length; ++i) {
            if (_currencyToken(lines[i].settlementCurrency, _cartConfig().weth) == inputToken) {
                requiredInput += lines[i].amount;
            }
        }
        if (order.paymentAmount < requiredInput) {
            revert ICart.OrderLineFailed(0, ICart.FailureStage.ROUTING, abi.encode(order.paymentAmount, requiredInput));
        }

        // Record Cart's native balance without the value sent for this call.
        state.nativeBaseline = address(this).balance - msg.value;
        address router = _cartConfig().universalRouter;
        // Record the router's native balance before routing starts.
        state.routerNativeBaseline = router.balance;
        // Record token balances that must remain safe during settlement.
        state.assetSnapshots = _snapshotAssets(settlementTokens);
        // Pull or wrap the caller's payment and record the pre-payment balance.
        state.inputBaseline = _fundPayment(order, order.paymentAmount);
        // Execute the one atomic plan and capture favorable output for the protocol.
        _executeRoute(order.orderId, order.paymentCurrency, lines, route, summary);
    }

    function finish(
        bytes32 orderId,
        address paymentCurrency,
        ICart.OrderLine[] calldata lines,
        PaymentState calldata state
    ) external payable onlyDelegateCall {
        // Combine equal payouts and send the final amounts to each recipient.
        _payLines(lines);
        // Capture unused input as part of the fixed quote's protocol spread.
        _captureInputSpread(orderId, paymentCurrency, state.inputBaseline);
        // Confirm that Cart and the router did not keep unexpected assets.
        _verifySettlementBalances(state.assetSnapshots, state.nativeBaseline, state.routerNativeBaseline);
    }

    function _validateRoute(
        address paymentCurrency,
        ICart.OrderLine[] calldata lines,
        ICart.PayoutRoute calldata route
    ) private view returns (ICartRoutePolicy.Summary memory summary, address[] memory settlementTokens) {
        // Use WETH as the internal token for native currency.
        address wrappedNative = _cartConfig().weth;
        address inputToken = _currencyToken(paymentCurrency, wrappedNative);
        address[] memory expectedOutputs = new address[](lines.length);
        uint256 outputCount;
        for (uint256 i = 0; i < lines.length; ++i) {
            // Convert this line's settlement currency to its internal token address.
            address outputToken = _currencyToken(lines[i].settlementCurrency, wrappedNative);
            if (inputToken == outputToken) {
                continue;
            }
            bool seen;
            for (uint256 j = 0; j < outputCount; ++j) {
                if (expectedOutputs[j] == outputToken) {
                    seen = true;
                    break;
                }
            }
            if (!seen) expectedOutputs[outputCount++] = outputToken;
        }
        if (outputCount == 0) {
            if (route.commands.length != 0 || route.inputs.length != 0) revert ICart.RouteUnexpected(0);
        } else if (route.commands.length == 0) {
            // A currency change requires a route, but direct lines may coexist with it.
            for (uint256 i = 0; i < lines.length; ++i) {
                if (inputToken != _currencyToken(lines[i].settlementCurrency, wrappedNative)) {
                    revert ICart.RouteRequired(i);
                }
            }
        } else {
            assembly {
                mstore(expectedOutputs, outputCount)
            }
            try ROUTE_POLICY.validate(route.commands, route.inputs, inputToken, expectedOutputs) returns (
                ICartRoutePolicy.Summary memory validated
            ) {
                summary = validated;
            } catch (bytes memory reason) {
                revert ICart.OrderLineFailed(0, ICart.FailureStage.ROUTING, reason);
            }
        }

        // Allocate enough space for the payment token and every line settlement token.
        settlementTokens = new address[](1 + lines.length);
        // Add the input token and remove duplicate token entries as lines are processed.
        uint256 count = _recordToken(settlementTokens, 0, inputToken);
        for (uint256 i = 0; i < lines.length; ++i) {
            count = _recordToken(settlementTokens, count, _currencyToken(lines[i].settlementCurrency, wrappedNative));
        }
        /// @solidity memory-safe-assembly
        assembly {
            // Shrink the array to the number of unique tokens that were recorded.
            mstore(settlementTokens, count)
        }
    }

    function _executeRoute(
        bytes32 orderId,
        address paymentCurrency,
        ICart.OrderLine[] calldata lines,
        ICart.PayoutRoute calldata route,
        ICartRoutePolicy.Summary memory summary
    ) private {
        address wrappedNative = _cartConfig().weth;
        address inputToken = _currencyToken(paymentCurrency, wrappedNative);
        uint256 totalInput = summary.inputAmount;
        if (totalInput == 0) return;
        // Permit2 stores the allowance as uint160, so reject values that do not fit.
        if (totalInput > type(uint160).max) {
            revert ICart.OrderLineFailed(0, ICart.FailureStage.ROUTING, abi.encode(totalInput));
        }

        CartStorage.Config storage config = _cartConfig();
        // Give Permit2 and the Universal Router one temporary allowance for all routes.
        IERC20(inputToken).forceApprove(config.permit2, totalInput);
        IPermit2Cart(config.permit2)
            .approve(inputToken, config.universalRouter, uint160(totalInput), uint48(block.timestamp + 1 hours));

        address[] memory outputTokens = new address[](lines.length);
        uint256[] memory outputBaselines = new uint256[](lines.length);
        uint256 outputCount;
        for (uint256 i = 0; i < lines.length; ++i) {
            address outputToken = _currencyToken(lines[i].settlementCurrency, wrappedNative);
            if (outputToken == inputToken) continue;
            bool first = true;
            for (uint256 j = 0; j < outputCount; ++j) {
                if (outputTokens[j] == outputToken) {
                    first = false;
                    break;
                }
            }
            if (first) {
                outputTokens[outputCount] = outputToken;
                outputBaselines[outputCount++] = IERC20(outputToken).balanceOf(address(this));
            }
        }

        uint256 firstLine;
        while (
            firstLine < lines.length && inputToken == _currencyToken(lines[firstLine].settlementCurrency, wrappedNative)
        ) {
            ++firstLine;
        }
        _executeUniversalRouter(firstLine, route.commands, route.inputs);

        // Check each required output token against the aggregate balance delta. Any surplus is
        // protocol-owned; line payouts remain exactly equal to their signed amounts.
        for (uint256 i = 0; i < outputCount; ++i) {
            address outputToken = outputTokens[i];
            uint256 required;
            for (uint256 j = 0; j < lines.length; ++j) {
                if (_currencyToken(lines[j].settlementCurrency, wrappedNative) == outputToken) {
                    required += lines[j].amount;
                }
            }
            uint256 current = IERC20(outputToken).balanceOf(address(this));
            uint256 received = current - outputBaselines[i];
            if (received < required) {
                revert ICart.OrderLineFailed(i, ICart.FailureStage.ROUTING, abi.encode(received, required));
            }
            uint256 surplus = received - required;
            if (surplus != 0) {
                address recipient = _cartConfig().protocolRecipient;
                _transferExact(outputToken, recipient, surplus, i);
                emit ProtocolSpreadCaptured(orderId, outputToken, recipient, surplus);
            }
        }

        // Remove the shared approvals after every route has finished.
        IERC20(inputToken).forceApprove(config.permit2, 0);
        IPermit2Cart(config.permit2).approve(inputToken, config.universalRouter, 0, 0);
        // Confirm that neither Cart nor Permit2 can spend the input token anymore.
        _assertAllowancesCleared(inputToken, config.permit2, config.universalRouter);
    }

    function _executeUniversalRouter(uint256 lineIndex, bytes memory commands, bytes[] memory inputs) private {
        CartStorage.Config storage config = _cartConfig();
        // Encode the route with the current block timestamp as its deadline.
        bytes memory data = abi.encodeWithSignature("execute(bytes,bytes[],uint256)", commands, inputs, block.timestamp);
        // Call the router from Cart's context so the router uses Cart's approvals and balances.
        (bool success, bytes memory reason) = config.universalRouter.call(data);
        // Return the router's failure data as a line-specific Cart error.
        if (!success) revert ICart.OrderLineFailed(lineIndex, ICart.FailureStage.ROUTING, reason);
    }

    function _fundPayment(ICart.PurchaseOrder calldata order, uint256 amount) private returns (uint256 baseline) {
        address wrappedNative = _cartConfig().weth;
        if (order.paymentCurrency == address(0)) {
            // Native payment must equal the signed fixed quote exactly.
            if (msg.value != amount) revert ICart.NativeValueMismatch();
            // Record Cart's existing WETH balance before wrapping the payment.
            baseline = IWETHCartPayments(wrappedNative).balanceOf(address(this));
            // Wrap the caller's native payment so routes can use an ERC-20 token.
            IWETHCartPayments(wrappedNative).deposit{value: msg.value}();
        } else {
            // ERC-20 payment must not include a native value transfer.
            if (msg.value != 0) revert ICart.NativeValueMismatch();
            // Record Cart's existing payment-token balance.
            baseline = IERC20(order.paymentCurrency).balanceOf(address(this));
            // Pull the signed fixed quote from the caller.
            IERC20(order.paymentCurrency).safeTransferFrom(msg.sender, address(this), amount);
            // Reject fee-on-transfer behavior because the full amount is required.
            uint256 received = IERC20(order.paymentCurrency).balanceOf(address(this)) - baseline;
            if (received != amount) {
                revert ICart.OrderLineFailed(0, ICart.FailureStage.FUNDING, abi.encode(amount, received));
            }
        }
    }

    function _payLines(ICart.OrderLine[] calldata lines) private {
        address wrappedNative = _cartConfig().weth;
        // Store one payout for each unique token, recipient, and native-currency mode.
        Payout[] memory payouts = new Payout[](lines.length);
        uint256 count;
        for (uint256 i = 0; i < lines.length; ++i) {
            // Convert native currency to WETH for grouping and balance tracking.
            bool native = lines[i].settlementCurrency == address(0);
            address token = _currencyToken(lines[i].settlementCurrency, wrappedNative);
            uint256 payoutIndex = NO_GROUP;
            for (uint256 j = 0; j < count; ++j) {
                // Reuse an existing payout when the token and recipient match.
                if (
                    payouts[j].token == token && payouts[j].recipient == lines[i].paymentRecipient
                        && payouts[j].native == native
                ) {
                    payoutIndex = j;
                    break;
                }
            }
            if (payoutIndex == NO_GROUP) {
                // Create a payout record and keep this line for error reporting.
                payoutIndex = count++;
                payouts[payoutIndex] = Payout({
                    token: token, recipient: lines[i].paymentRecipient, amount: 0, lineIndex: i, native: native
                });
            }
            // Add this line's exact fixed-quote obligation to the combined payout amount.
            payouts[payoutIndex].amount += lines[i].amount;
        }

        for (uint256 i = 0; i < count; ++i) {
            Payout memory payout = payouts[i];
            if (payout.native) {
                // Unwrap WETH before sending a native-currency payout.
                IWETHCartPayments(wrappedNative).withdraw(payout.amount);
                // Send the combined native payout to its recipient.
                (bool success,) = payout.recipient.call{value: payout.amount}("");
                if (!success) revert ICart.OrderLineFailed(payout.lineIndex, ICart.FailureStage.PAYOUT, "");
            } else {
                // Send the combined ERC-20 payout and verify the full amount arrived.
                _transferExact(payout.token, payout.recipient, payout.amount, payout.lineIndex);
            }
        }
    }

    function _captureInputSpread(bytes32 orderId, address paymentCurrency, uint256 baseline) private {
        address wrappedNative = _cartConfig().weth;
        // Read the remaining input-token balance after routes and payouts.
        uint256 current = IERC20(_currencyToken(paymentCurrency, wrappedNative)).balanceOf(address(this));
        if (current < baseline) {
            // Do not consume a balance that existed before this payment.
            revert ICart.PreexistingBalanceConsumed(paymentCurrency, baseline, current);
        }
        // There is no spread when only the pre-payment balance remains.
        if (current == baseline) return;
        uint256 spread = current - baseline;
        address recipient = _cartConfig().protocolRecipient;
        if (paymentCurrency == address(0)) {
            // Unwrap and send unused native input to the protocol.
            IWETHCartPayments(wrappedNative).withdraw(spread);
            (bool success,) = recipient.call{value: spread}("");
            if (!success) revert ICart.OrderLineFailed(0, ICart.FailureStage.SPREAD, "");
        } else {
            _transferExact(paymentCurrency, recipient, spread, 0);
        }
        emit ProtocolSpreadCaptured(orderId, paymentCurrency, recipient, spread);
    }

    function _transferExact(address token, address recipient, uint256 amount, uint256 lineIndex) private {
        // Record the recipient balance before the transfer.
        uint256 beforeBalance = IERC20(token).balanceOf(recipient);
        // Use SafeERC20 for tokens with different return-value behavior.
        IERC20(token).safeTransfer(recipient, amount);
        // Require the recipient balance to increase by the full amount.
        uint256 received = IERC20(token).balanceOf(recipient) - beforeBalance;
        if (received != amount) {
            revert ICart.OrderLineFailed(lineIndex, ICart.FailureStage.PAYOUT, abi.encode(amount, received));
        }
    }

    function _snapshotAssets(address[] memory tokens) private view returns (AssetSnapshot[] memory snapshots) {
        address router = _cartConfig().universalRouter;
        // Create one snapshot for every tracked settlement token.
        snapshots = new AssetSnapshot[](tokens.length);
        for (uint256 i = 0; i < tokens.length; ++i) {
            // Record Cart and router balances before any payment operation.
            snapshots[i] = AssetSnapshot({
                token: tokens[i],
                cartBalance: IERC20(tokens[i]).balanceOf(address(this)),
                routerBalance: IERC20(tokens[i]).balanceOf(router)
            });
        }
    }

    function _verifySettlementBalances(
        AssetSnapshot[] calldata snapshots,
        uint256 nativeBaseline,
        uint256 routerNativeBaseline
    ) private view {
        address router = _cartConfig().universalRouter;
        // Cart must return to its starting native balance.
        uint256 nativeCurrent = address(this).balance;
        if (nativeCurrent != nativeBaseline) {
            revert ICart.UnexpectedCartBalance(address(0), nativeBaseline, nativeCurrent);
        }
        // The router may spend native currency but must not gain any.
        uint256 routerNativeCurrent = router.balance;
        if (routerNativeCurrent > routerNativeBaseline) {
            revert ICart.UnexpectedRouterBalance(address(0), routerNativeBaseline, routerNativeCurrent);
        }
        for (uint256 i = 0; i < snapshots.length; ++i) {
            AssetSnapshot calldata snapshot = snapshots[i];
            // Cart must return to its starting balance for every tracked token.
            uint256 cartCurrent = IERC20(snapshot.token).balanceOf(address(this));
            if (cartCurrent != snapshot.cartBalance) {
                revert ICart.UnexpectedCartBalance(snapshot.token, snapshot.cartBalance, cartCurrent);
            }
            // The router may spend a tracked token but must not gain any.
            uint256 routerCurrent = IERC20(snapshot.token).balanceOf(router);
            if (routerCurrent > snapshot.routerBalance) {
                revert ICart.UnexpectedRouterBalance(snapshot.token, snapshot.routerBalance, routerCurrent);
            }
        }
    }

    function _assertAllowancesCleared(address token, address permit2, address router) private view {
        // Confirm that Cart no longer approved Permit2 to pull the input token.
        if (IERC20(token).allowance(address(this), permit2) != 0) {
            revert ICart.AllowanceNotCleared(token, permit2);
        }
        // Confirm that Permit2 no longer approved the router to pull the input token.
        (uint160 permitAmount,,) = IPermit2Cart(permit2).allowance(address(this), token, router);
        if (permitAmount != 0) revert ICart.AllowanceNotCleared(token, router);
    }

    function _recordToken(address[] memory tokens, uint256 count, address token) private pure returns (uint256) {
        for (uint256 i = 0; i < count; ++i) {
            // Do not add the same token more than once.
            if (tokens[i] == token) return count;
        }
        // Append a token that is not in the list.
        tokens[count] = token;
        return count + 1;
    }

    function _currencyToken(address currency, address wrappedNative) private pure returns (address) {
        // Use WETH as the internal token for native currency.
        return currency == address(0) ? wrappedNative : currency;
    }
}
