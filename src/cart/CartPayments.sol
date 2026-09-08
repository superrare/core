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
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

/// @title SuperRare Cart Payments
/// @notice Delegate-called funding, routing, payout, and protocol-spread implementation for Cart.
/// @dev Universal Router owns route semantics. This executor only checks custody outcomes over the
///      supported currencies present in the signed order.
contract CartPayments is CartStorage, ICartPayments {
    using SafeERC20 for IERC20;

    error DirectCallNotAllowed();

    event ProtocolSpreadCaptured(
        bytes32 indexed orderId, address indexed currency, address indexed recipient, uint256 amount
    );

    uint256 private constant NO_GROUP = type(uint256).max;

    ICartRoutePolicy private immutable ROUTE_POLICY;
    address private immutable SELF;

    struct Payout {
        address token;
        address recipient;
        uint256 amount;
        uint256 lineIndex;
        bool native;
    }

    constructor(address routePolicy_) {
        ROUTE_POLICY = ICartRoutePolicy(routePolicy_);
        SELF = address(this);
    }

    modifier onlyDelegateCall() {
        if (address(this) == SELF) revert DirectCallNotAllowed();
        _;
    }

    function begin(
        ICart.PurchaseOrder calldata order,
        ICart.OrderLine[] calldata lines,
        ICart.PayoutRoute calldata route
    ) external payable onlyDelegateCall returns (PaymentState memory state) {
        address[] memory settlementTokens = _validateRoute(order.paymentCurrency, lines, route);

        state.nativeBaseline = address(this).balance - msg.value;
        state.assetSnapshots = _snapshotAssets(settlementTokens);
        if (order.paymentCurrency != address(0)) {
            _assertNoPreexistingApprovals(
                order.paymentCurrency, _cartConfig().permit2, _cartConfig().universalRouter
            );
        }
        _fundPayment(order, route);
        _executeRoute(order, route);
        _verifySolvency(lines, state.assetSnapshots, state.nativeBaseline);
    }

    function finish(
        bytes32 orderId,
        address paymentCurrency,
        ICart.OrderLine[] calldata lines,
        PaymentState calldata state
    ) external payable onlyDelegateCall {
        _prepareNativeFamily(lines, state.assetSnapshots, state.nativeBaseline);
        _payLines(lines);
        _captureSupportedSpread(orderId, state);
        _verifyFinalBaselines(state);
        if (paymentCurrency != address(0)) {
            _assertAllowancesCleared(paymentCurrency, _cartConfig().permit2, _cartConfig().universalRouter);
        }
    }

    function _validateRoute(
        address paymentCurrency,
        ICart.OrderLine[] calldata lines,
        ICart.PayoutRoute calldata route
    ) private view returns (address[] memory tokens) {
        if (route.commands.length == 0) {
            if (route.inputs.length != 0) {
                revert ICart.OrderLineFailed(
                    0,
                    ICart.FailureStage.ROUTING,
                    abi.encodeWithSelector(
                        ICartRoutePolicy.CommandInputLengthMismatch.selector, route.commands.length, route.inputs.length
                    )
                );
            }
            if (route.routerValue != 0) revert ICart.RouteValueWithoutCommands();
        } else {
            try ROUTE_POLICY.validate(route.commands, route.inputs) {}
            catch (bytes memory reason) {
                revert ICart.OrderLineFailed(0, ICart.FailureStage.ROUTING, reason);
            }
        }

        // The order defines the complete supported settlement universe. WETH is always tracked
        // because native ETH and WETH share solvency while retaining distinct payout forms.
        tokens = new address[](lines.length + 2);
        uint256 count = _recordToken(tokens, 0, _cartConfig().weth);
        if (paymentCurrency != address(0)) count = _recordToken(tokens, count, paymentCurrency);
        for (uint256 i = 0; i < lines.length; ++i) {
            if (lines[i].settlementCurrency != address(0)) {
                count = _recordToken(tokens, count, lines[i].settlementCurrency);
            }
        }
        assembly {
            mstore(tokens, count)
        }
    }

    function _fundPayment(ICart.PurchaseOrder calldata order, ICart.PayoutRoute calldata route) private {
        if (order.paymentCurrency == address(0)) {
            if (msg.value != order.paymentAmount || route.routerValue > order.paymentAmount) {
                revert ICart.NativeValueMismatch();
            }
            return;
        }

        if (msg.value != 0 || route.routerValue != 0) revert ICart.NativeValueMismatch();
        uint256 beforeBalance = IERC20(order.paymentCurrency).balanceOf(address(this));
        IERC20(order.paymentCurrency).safeTransferFrom(msg.sender, address(this), order.paymentAmount);
        uint256 received = IERC20(order.paymentCurrency).balanceOf(address(this)) - beforeBalance;
        if (received != order.paymentAmount) {
            revert ICart.OrderLineFailed(0, ICart.FailureStage.FUNDING, abi.encode(order.paymentAmount, received));
        }
    }

    function _executeRoute(ICart.PurchaseOrder calldata order, ICart.PayoutRoute calldata route) private {
        if (route.commands.length == 0) return;

        CartStorage.Config storage config = _cartConfig();
        if (order.paymentCurrency != address(0)) {
            if (order.paymentAmount > type(uint160).max) {
                revert ICart.OrderLineFailed(0, ICart.FailureStage.ROUTING, abi.encode(order.paymentAmount));
            }
            if (order.deadline > type(uint48).max) {
                revert ICart.OrderLineFailed(0, ICart.FailureStage.ROUTING, abi.encode(order.deadline));
            }
            IERC20(order.paymentCurrency).forceApprove(config.permit2, order.paymentAmount);
            IPermit2Cart(config.permit2)
                .approve(
                    order.paymentCurrency, config.universalRouter, uint160(order.paymentAmount), uint48(order.deadline)
                );
        }

        bytes memory data =
            abi.encodeWithSignature("execute(bytes,bytes[],uint256)", route.commands, route.inputs, order.deadline);
        (bool success, bytes memory reason) = config.universalRouter.call{value: route.routerValue}(data);
        if (!success) revert ICart.OrderLineFailed(0, ICart.FailureStage.ROUTING, reason);

        // Revoke both approval layers immediately after the opaque router call returns.
        if (order.paymentCurrency != address(0)) {
            IERC20(order.paymentCurrency).forceApprove(config.permit2, 0);
            IPermit2Cart(config.permit2).approve(order.paymentCurrency, config.universalRouter, 0, 0);
            _assertAllowancesCleared(order.paymentCurrency, config.permit2, config.universalRouter);
        }
    }

    function _verifySolvency(
        ICart.OrderLine[] calldata lines,
        ICartPayments.AssetSnapshot[] memory snapshots,
        uint256 nativeBaseline
    ) private view {
        address wrappedNative = _cartConfig().weth;
        uint256 requiredNative;
        uint256 requiredWeth;
        for (uint256 i = 0; i < lines.length; ++i) {
            if (lines[i].settlementCurrency == address(0)) requiredNative += lines[i].amount;
            if (lines[i].settlementCurrency == wrappedNative) requiredWeth += lines[i].amount;
        }

        uint256 currentNative = address(this).balance;
        if (currentNative < nativeBaseline) {
            revert ICart.PreexistingBalanceConsumed(address(0), nativeBaseline, currentNative);
        }
        uint256 wethBaseline = _snapshotBalance(snapshots, wrappedNative);
        uint256 currentWeth = IERC20(wrappedNative).balanceOf(address(this));
        if (currentWeth < wethBaseline) {
            revert ICart.PreexistingBalanceConsumed(wrappedNative, wethBaseline, currentWeth);
        }
        if (currentNative - nativeBaseline + currentWeth - wethBaseline < requiredNative + requiredWeth) {
            revert ICart.OrderLineFailed(
                0,
                ICart.FailureStage.ROUTING,
                abi.encode(currentNative - nativeBaseline + currentWeth - wethBaseline, requiredNative + requiredWeth)
            );
        }

        for (uint256 i = 0; i < snapshots.length; ++i) {
            address token = snapshots[i].token;
            if (token == wrappedNative) continue;
            uint256 current = IERC20(token).balanceOf(address(this));
            if (current < snapshots[i].cartBalance) {
                revert ICart.PreexistingBalanceConsumed(token, snapshots[i].cartBalance, current);
            }
            uint256 required = _requiredForToken(lines, token);
            if (current - snapshots[i].cartBalance < required) {
                revert ICart.OrderLineFailed(
                    _firstLineForToken(lines, token),
                    ICart.FailureStage.ROUTING,
                    abi.encode(current - snapshots[i].cartBalance, required)
                );
            }
        }
    }

    function _prepareNativeFamily(
        ICart.OrderLine[] calldata lines,
        ICartPayments.AssetSnapshot[] calldata snapshots,
        uint256 nativeBaseline
    ) private {
        address wrappedNative = _cartConfig().weth;
        uint256 requiredNative;
        uint256 requiredWeth;
        for (uint256 i = 0; i < lines.length; ++i) {
            if (lines[i].settlementCurrency == address(0)) requiredNative += lines[i].amount;
            if (lines[i].settlementCurrency == wrappedNative) requiredWeth += lines[i].amount;
        }

        uint256 currentNative = address(this).balance;
        uint256 currentWeth = IERC20(wrappedNative).balanceOf(address(this));
        uint256 nativeAvailable = currentNative - nativeBaseline;
        uint256 wethAvailable = currentWeth - _snapshotBalance(snapshots, wrappedNative);
        if (nativeAvailable < requiredNative) {
            IWETHCartPayments(wrappedNative).withdraw(requiredNative - nativeAvailable);
        } else if (wethAvailable < requiredWeth) {
            IWETHCartPayments(wrappedNative).deposit{value: requiredWeth - wethAvailable}();
        }
    }

    function _payLines(ICart.OrderLine[] calldata lines) private {
        address wrappedNative = _cartConfig().weth;
        Payout[] memory payouts = new Payout[](lines.length);
        uint256 count;
        for (uint256 i = 0; i < lines.length; ++i) {
            bool native = lines[i].settlementCurrency == address(0);
            address token = native ? wrappedNative : lines[i].settlementCurrency;
            uint256 payoutIndex = NO_GROUP;
            for (uint256 j = 0; j < count; ++j) {
                if (
                    payouts[j].token == token && payouts[j].recipient == lines[i].paymentRecipient
                        && payouts[j].native == native
                ) {
                    payoutIndex = j;
                    break;
                }
            }
            if (payoutIndex == NO_GROUP) {
                payoutIndex = count++;
                payouts[payoutIndex] = Payout({
                    token: token, recipient: lines[i].paymentRecipient, amount: 0, lineIndex: i, native: native
                });
            }
            payouts[payoutIndex].amount += lines[i].amount;
        }

        for (uint256 i = 0; i < count; ++i) {
            Payout memory payout = payouts[i];
            if (payout.native) {
                (bool success,) = payout.recipient.call{value: payout.amount}("");
                if (!success) revert ICart.OrderLineFailed(payout.lineIndex, ICart.FailureStage.PAYOUT, "");
            } else {
                _transferExact(payout.token, payout.recipient, payout.amount, payout.lineIndex);
            }
        }
    }

    function _captureSupportedSpread(bytes32 orderId, PaymentState calldata state) private {
        address recipient = _cartConfig().protocolRecipient;
        for (uint256 i = 0; i < state.assetSnapshots.length; ++i) {
            ICartPayments.AssetSnapshot calldata snapshot = state.assetSnapshots[i];
            uint256 current = IERC20(snapshot.token).balanceOf(address(this));
            if (current < snapshot.cartBalance) {
                revert ICart.PreexistingBalanceConsumed(snapshot.token, snapshot.cartBalance, current);
            }
            uint256 spread = current - snapshot.cartBalance;
            if (spread != 0) {
                _transferExact(snapshot.token, recipient, spread, 0);
                emit ProtocolSpreadCaptured(orderId, snapshot.token, recipient, spread);
            }
        }

        uint256 nativeCurrent = address(this).balance;
        if (nativeCurrent < state.nativeBaseline) {
            revert ICart.PreexistingBalanceConsumed(address(0), state.nativeBaseline, nativeCurrent);
        }
        uint256 nativeSpread = nativeCurrent - state.nativeBaseline;
        if (nativeSpread != 0) {
            (bool success,) = recipient.call{value: nativeSpread}("");
            if (!success) revert ICart.OrderLineFailed(0, ICart.FailureStage.SPREAD, "");
            emit ProtocolSpreadCaptured(orderId, address(0), recipient, nativeSpread);
        }
    }

    function _verifyFinalBaselines(PaymentState calldata state) private view {
        uint256 nativeCurrent = address(this).balance;
        if (nativeCurrent != state.nativeBaseline) {
            revert ICart.UnexpectedCartBalance(address(0), state.nativeBaseline, nativeCurrent);
        }
        for (uint256 i = 0; i < state.assetSnapshots.length; ++i) {
            ICartPayments.AssetSnapshot calldata snapshot = state.assetSnapshots[i];
            uint256 current = IERC20(snapshot.token).balanceOf(address(this));
            if (current != snapshot.cartBalance) {
                revert ICart.UnexpectedCartBalance(snapshot.token, snapshot.cartBalance, current);
            }
        }
    }

    function _assertAllowancesCleared(address token, address permit2, address router) private view {
        if (IERC20(token).allowance(address(this), permit2) != 0) {
            revert ICart.AllowanceNotCleared(token, permit2);
        }
        (uint160 permitAmount,,) = IPermit2Cart(permit2).allowance(address(this), token, router);
        if (permitAmount != 0) revert ICart.AllowanceNotCleared(token, router);
    }

    function _assertNoPreexistingApprovals(address token, address permit2, address router) private view {
        uint256 cartAllowance = IERC20(token).allowance(address(this), permit2);
        if (cartAllowance != 0) revert ICart.PreexistingAllowance(token, permit2, cartAllowance);
        (uint160 permitAmount,,) = IPermit2Cart(permit2).allowance(address(this), token, router);
        if (permitAmount != 0) revert ICart.PreexistingAllowance(token, router, permitAmount);
    }

    function _snapshotAssets(address[] memory tokens)
        private
        view
        returns (ICartPayments.AssetSnapshot[] memory snapshots)
    {
        snapshots = new ICartPayments.AssetSnapshot[](tokens.length);
        for (uint256 i = 0; i < tokens.length; ++i) {
            snapshots[i] = ICartPayments.AssetSnapshot({
                token: tokens[i], cartBalance: IERC20(tokens[i]).balanceOf(address(this))
            });
        }
    }

    function _requiredForToken(ICart.OrderLine[] calldata lines, address token)
        private
        pure
        returns (uint256 required)
    {
        for (uint256 i = 0; i < lines.length; ++i) {
            if (lines[i].settlementCurrency == token) required += lines[i].amount;
        }
    }

    function _firstLineForToken(ICart.OrderLine[] calldata lines, address token) private pure returns (uint256) {
        for (uint256 i = 0; i < lines.length; ++i) {
            if (lines[i].settlementCurrency == token) return i;
        }
        return 0;
    }

    function _snapshotBalance(ICartPayments.AssetSnapshot[] memory snapshots, address token)
        private
        pure
        returns (uint256)
    {
        for (uint256 i = 0; i < snapshots.length; ++i) {
            if (snapshots[i].token == token) return snapshots[i].cartBalance;
        }
        return 0;
    }

    function _recordToken(address[] memory tokens, uint256 count, address token) private pure returns (uint256) {
        for (uint256 i = 0; i < count; ++i) {
            if (tokens[i] == token) return count;
        }
        tokens[count] = token;
        return count + 1;
    }

    function _transferExact(address token, address recipient, uint256 amount, uint256 lineIndex) private {
        uint256 beforeBalance = IERC20(token).balanceOf(recipient);
        IERC20(token).safeTransfer(recipient, amount);
        uint256 received = IERC20(token).balanceOf(recipient) - beforeBalance;
        if (received != amount) {
            revert ICart.OrderLineFailed(lineIndex, ICart.FailureStage.PAYOUT, abi.encode(amount, received));
        }
    }
}
