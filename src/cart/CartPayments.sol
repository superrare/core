// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import {Math} from "openzeppelin-contracts/utils/math/Math.sol";

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

    event ListingSplitPaid(
        bytes32 indexed orderId,
        uint256 indexed lineIndex,
        bytes32 indexed listingDigest,
        address currency,
        address recipient,
        uint256 amount
    );

    event ProtocolSpreadCaptured(
        bytes32 indexed orderId, address indexed currency, address indexed recipient, uint256 amount
    );

    // Bound failure diagnostics without copying arbitrary receiver return data.
    uint256 private constant MAX_NATIVE_REVERT_BYTES = 2048;
    uint256 private constant NO_GROUP = type(uint256).max;

    ICartRoutePolicy private immutable ROUTE_POLICY;
    address private immutable SELF;

    struct Payout {
        // Preserve the signed currency: zero is ETH, while WETH remains a distinct payout.
        address currency;
        address recipient;
        uint256 amount;
        uint256 lineIndex;
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
        // Validate the route before collecting the currencies whose balances must be preserved.
        address[] memory routeAssets = _validateRoute(route);
        address[] memory settlementTokens = _settlementTokens(order.paymentCurrency, lines, routeAssets);

        // Snapshot preexisting custody before collecting the caller's payment.
        state.nativeBaseline = address(this).balance - msg.value;
        state.assetSnapshots = _snapshotAssets(settlementTokens);
        // Existing approvals cannot be borrowed by this purchase.
        if (order.paymentCurrency != address(0)) {
            _assertNoPreexistingApprovals(order.paymentCurrency, _cartConfig().permit2, _cartConfig().universalRouter);
        }
        // Collect the fixed quote, run its signed route, then require enough incremental assets.
        _fundPayment(order, route);
        _executeRoute(order, route, settlementTokens);
        _verifySolvency(lines, state.assetSnapshots, state.nativeBaseline);
    }

    function finish(
        bytes32 orderId,
        address paymentCurrency,
        address spreadRecipient,
        ICart.OrderLine[] calldata lines,
        ICart.Listing[] calldata listings,
        uint256[] calldata lineListing,
        PaymentState calldata state
    ) external payable onlyDelegateCall {
        // Convert incremental ETH/WETH into the exact forms required by the signed payouts.
        _prepareNativeFamily(lines, state.assetSnapshots, state.nativeBaseline);
        // Pay each recipient once per exact currency, retaining first-line failure attribution.
        _payLines(orderId, lines, listings, lineListing);
        // Deliver favorable execution variance to the signed recipient and restore every custody baseline.
        _captureSupportedSpread(orderId, spreadRecipient, state);
        _verifyFinalBaselines(state);
        if (paymentCurrency != address(0)) {
            _assertAllowancesCleared(paymentCurrency, _cartConfig().permit2, _cartConfig().universalRouter);
        }
    }

    function _validateRoute(ICart.PayoutRoute calldata route) private view returns (address[] memory assets) {
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
            try ROUTE_POLICY.validate(route.commands, route.inputs) returns (address[] memory tokens) {
                assets = tokens;
            }
            catch (bytes memory reason) {
                revert ICart.OrderLineFailed(0, ICart.FailureStage.ROUTING, reason);
            }
        }
    }

    function _settlementTokens(address paymentCurrency, ICart.OrderLine[] calldata lines, address[] memory routeAssets)
        private
        view
        returns (address[] memory tokens)
    {
        // Track settlement and route endpoint assets. WETH is always tracked
        // because native ETH and WETH share solvency while retaining distinct payout forms.
        tokens = new address[](lines.length + 2 + routeAssets.length);
        uint256 count = _recordToken(tokens, 0, _cartConfig().weth);
        if (paymentCurrency != address(0)) count = _recordToken(tokens, count, paymentCurrency);
        for (uint256 i = 0; i < lines.length; ++i) {
            if (lines[i].settlementCurrency != address(0)) {
                count = _recordToken(tokens, count, lines[i].settlementCurrency);
            }
        }
        for (uint256 i; i < routeAssets.length; ++i) {
            if (routeAssets[i] != address(0)) count = _recordToken(tokens, count, routeAssets[i]);
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
        // A zero-total order still validates and fulfills, but needs no token transfer or approval.
        if (order.paymentAmount == 0) return;
        uint256 beforeBalance = IERC20(order.paymentCurrency).balanceOf(address(this));
        IERC20(order.paymentCurrency).safeTransferFrom(msg.sender, address(this), order.paymentAmount);
        uint256 received = IERC20(order.paymentCurrency).balanceOf(address(this)) - beforeBalance;
        if (received != order.paymentAmount) {
            revert ICart.OrderLineFailed(0, ICart.FailureStage.FUNDING, abi.encode(order.paymentAmount, received));
        }
    }

    function _executeRoute(
        ICart.PurchaseOrder calldata order,
        ICart.PayoutRoute calldata route,
        address[] memory tokens
    ) private {
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

        // A shared router may already hold funds. This purchase must not add to those balances.
        uint256 nativeBefore = config.universalRouter.balance;
        uint256[] memory balances = new uint256[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            balances[i] = IERC20(tokens[i]).balanceOf(config.universalRouter);
        }
        bytes memory data =
            abi.encodeWithSignature("execute(bytes,bytes[],uint256)", route.commands, route.inputs, order.deadline);
        (bool success, bytes memory reason) = config.universalRouter.call{value: route.routerValue}(data);
        if (!success) revert ICart.OrderLineFailed(0, ICart.FailureStage.ROUTING, reason);

        if (config.universalRouter.balance > nativeBefore) {
            revert ICart.OrderLineFailed(
                0,
                ICart.FailureStage.ROUTING,
                abi.encodeWithSelector(
                    ICartRoutePolicy.RouterBalanceIncreased.selector,
                    address(0),
                    nativeBefore,
                    config.universalRouter.balance
                )
            );
        }
        for (uint256 i; i < tokens.length; ++i) {
            uint256 afterBalance = IERC20(tokens[i]).balanceOf(config.universalRouter);
            if (afterBalance > balances[i]) {
                revert ICart.OrderLineFailed(
                    0,
                    ICart.FailureStage.ROUTING,
                    abi.encodeWithSelector(
                        ICartRoutePolicy.RouterBalanceIncreased.selector, tokens[i], balances[i], afterBalance
                    )
                );
            }
        }

        // Revoke both approval layers before fulfillment.
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
        (uint256 requiredNative, uint256 requiredWeth) = _nativeRequirements(lines, wrappedNative);

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
        (uint256 requiredNative, uint256 requiredWeth) = _nativeRequirements(lines, wrappedNative);

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

    function _nativeRequirements(ICart.OrderLine[] calldata lines, address wrappedNative)
        private
        pure
        returns (uint256 requiredNative, uint256 requiredWeth)
    {
        // Sum each representation independently; solvency pools them but payouts keep them distinct.
        for (uint256 i = 0; i < lines.length; ++i) {
            if (lines[i].settlementCurrency == address(0)) requiredNative += lines[i].amount;
            if (lines[i].settlementCurrency == wrappedNative) requiredWeth += lines[i].amount;
        }
    }

    function _payLines(
        bytes32 orderId,
        ICart.OrderLine[] calldata lines,
        ICart.Listing[] calldata listings,
        uint256[] calldata lineListing
    ) private {
        uint256 capacity;
        for (uint256 i; i < lines.length; ++i) {
            uint256 index = lineListing[i];
            uint256 length = index == NO_GROUP ? 0 : listings[index].splits.length;
            capacity += length == 0 ? 1 : length;
        }
        Payout[] memory payouts = new Payout[](capacity);
        // Keep at most half the buckets occupied. Buckets hold payout index + 1;
        // the separate payout array retains first-seen transfer/failure order.
        uint256 tableSize = 2;
        while (tableSize < capacity * 2) tableSize <<= 1;
        uint256[] memory slots = new uint256[](tableSize);
        uint256 count;
        for (uint256 i; i < lines.length; ++i) {
            if (lines[i].amount == 0) continue;
            uint256 index = lineListing[i];
            if (index == NO_GROUP || listings[index].splits.length == 0) {
                count = _addPayout(
                    payouts, slots, count, lines[i].settlementCurrency, lines[i].paymentRecipient, lines[i].amount, i
                );
                continue;
            }
            count = _allocateLine(orderId, lines[i], listings[index].splits, payouts, slots, count, i);
        }

        for (uint256 i = 0; i < count; ++i) {
            Payout memory payout = payouts[i];
            if (payout.currency == address(0)) {
                _transferNative(payout.recipient, payout.amount, payout.lineIndex, ICart.FailureStage.PAYOUT);
            } else {
                _transferExact(payout.currency, payout.recipient, payout.amount, payout.lineIndex, ICart.FailureStage.PAYOUT);
            }
        }
    }

    function _allocateLine(
        bytes32 orderId,
        ICart.OrderLine calldata line,
        ICart.Split[] calldata splits,
        Payout[] memory payouts,
        uint256[] memory slots,
        uint256 count,
        uint256 lineIndex
    ) private returns (uint256) {
        uint256 remainder = line.amount;
        for (uint256 j = 1; j < splits.length; ++j) {
            uint256 amount = Math.mulDiv(line.amount, splits[j].basisPoints, 10_000);
            remainder -= amount;
            count = _addPayout(payouts, slots, count, line.settlementCurrency, splits[j].recipient, amount, lineIndex);
            emit ListingSplitPaid(
                orderId, lineIndex, line.listingDigest, line.settlementCurrency, splits[j].recipient, amount
            );
        }
        count = _addPayout(payouts, slots, count, line.settlementCurrency, splits[0].recipient, remainder, lineIndex);
        emit ListingSplitPaid(
            orderId, lineIndex, line.listingDigest, line.settlementCurrency, splits[0].recipient, remainder
        );
        return count;
    }

    function _addPayout(
        Payout[] memory payouts,
        uint256[] memory slots,
        uint256 count,
        address currency,
        address recipient,
        uint256 amount,
        uint256 lineIndex
    ) private pure returns (uint256) {
        if (amount == 0) return count;
        uint256 mask = slots.length - 1;
        uint256 slot = uint256(keccak256(abi.encode(currency, recipient))) & mask;
        while (slots[slot] != 0) {
            uint256 index = slots[slot] - 1;
            // Hash collisions must never combine different recipients or currencies.
            if (payouts[index].currency == currency && payouts[index].recipient == recipient) {
                payouts[index].amount += amount;
                return count;
            }
            slot = (slot + 1) & mask;
        }
        slots[slot] = count + 1;
        payouts[count] = Payout(currency, recipient, amount, lineIndex);
        return count + 1;
    }

    function _captureSupportedSpread(bytes32 orderId, address recipient, PaymentState calldata state) private {
        // Deliver every tracked surplus currency to the destination authorized by this order.
        for (uint256 i = 0; i < state.assetSnapshots.length; ++i) {
            ICartPayments.AssetSnapshot calldata snapshot = state.assetSnapshots[i];
            uint256 current = IERC20(snapshot.token).balanceOf(address(this));
            if (current < snapshot.cartBalance) {
                revert ICart.PreexistingBalanceConsumed(snapshot.token, snapshot.cartBalance, current);
            }
            uint256 spread = current - snapshot.cartBalance;
            if (spread != 0) {
                _transferExact(snapshot.token, recipient, spread, 0, ICart.FailureStage.SPREAD);
                emit ProtocolSpreadCaptured(orderId, snapshot.token, recipient, spread);
            }
        }

        uint256 nativeCurrent = address(this).balance;
        if (nativeCurrent < state.nativeBaseline) {
            revert ICart.PreexistingBalanceConsumed(address(0), state.nativeBaseline, nativeCurrent);
        }
        uint256 nativeSpread = nativeCurrent - state.nativeBaseline;
        if (nativeSpread != 0) {
            _transferNative(recipient, nativeSpread, 0, ICart.FailureStage.SPREAD);
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

    /// @dev Copy receiver revert data only on failure, bounded to protect diagnostic memory use.
    function _transferNative(address recipient, uint256 amount, uint256 lineIndex, ICart.FailureStage stage) private {
        bool success;
        assembly ("memory-safe") {
            success := call(gas(), recipient, amount, 0, 0, 0, 0)
        }
        if (!success) {
            uint256 length;
            assembly ("memory-safe") {
                length := returndatasize()
            }
            if (length > MAX_NATIVE_REVERT_BYTES) length = MAX_NATIVE_REVERT_BYTES;
            bytes memory reason = new bytes(length);
            assembly ("memory-safe") {
                returndatacopy(add(reason, 32), 0, length)
            }
            revert ICart.OrderLineFailed(lineIndex, stage, reason);
        }
    }

    /// @dev SafeERC20 failures bubble directly. Balance mismatches identify the settlement stage.
    function _transferExact(
        address token, address recipient, uint256 amount, uint256 lineIndex, ICart.FailureStage stage
    ) private {
        uint256 beforeBalance = IERC20(token).balanceOf(recipient);
        IERC20(token).safeTransfer(recipient, amount);
        uint256 received = IERC20(token).balanceOf(recipient) - beforeBalance;
        if (received != amount) {
            revert ICart.OrderLineFailed(lineIndex, stage, abi.encode(amount, received));
        }
    }
}
