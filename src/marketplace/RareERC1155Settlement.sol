// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import {IERC1155} from "openzeppelin-contracts/token/ERC1155/IERC1155.sol";
import {ERC165Checker} from "openzeppelin-contracts/utils/introspection/ERC165Checker.sol";
import {Math} from "openzeppelin-contracts/utils/math/Math.sol";

import {IRareERC1155} from "../token/ERC1155/IRareERC1155.sol";
import {MarketConfigV2} from "../v2/utils/MarketConfigV2.sol";
import {IRareERC1155Settlement} from "./IRareERC1155Settlement.sol";
import {RareERC1155MarketplacePayments} from "./RareERC1155MarketplacePayments.sol";
import {RareERC1155MarketplaceStorage} from "./RareERC1155MarketplaceStorage.sol";
import {RareERC1155SettlementCheckoutUtils} from "./RareERC1155SettlementCheckoutUtils.sol";

/// @author SuperRare Labs Inc.
/// @title RareERC1155Settlement
/// @notice Delegatecall-only settlement module for the ERC1155 marketplace.
/// @dev Direct calls revert because this contract has no standalone marketplace state or escrow. It must run through
/// `RareERC1155Marketplace` so `address(this)`, `msg.sender`, `msg.value`, and storage all resolve to the marketplace proxy.
contract RareERC1155Settlement is IRareERC1155Settlement, RareERC1155MarketplaceStorage {
    using RareERC1155MarketplacePayments for MarketConfigV2.Config;

    address private immutable SELF = address(this);

    struct PrimaryPayoutContext {
        uint256 tokenId;
        uint256 grossAmount;
        uint256 marketplaceFee;
        uint256 maxMints;
        address seller;
        address payable[] splitRecipients;
        uint8[] splitRatios;
    }

    struct SecondaryPayoutContext {
        uint256 tokenId;
        uint256 grossAmount;
        uint256 marketplaceFee;
        address payable[] splitRecipients;
        uint8[] splitRatios;
    }

    struct AcceptOfferInput {
        address contractAddress;
        uint256 tokenId;
        address buyer;
        address currencyAddress;
        uint256 price;
        uint256 quantity;
    }

    struct CheckoutFillContext {
        address seller;
        uint256 grossAmount;
        uint256 marketplaceFee;
        uint256 maxMints;
        address payable[] splitRecipients;
        uint8[] splitRatios;
    }

    struct CheckoutDirectSaleMintAggregate {
        address contractAddress;
        uint256 tokenId;
        uint256 quantity;
    }

    modifier onlyDelegateCall() {
        _onlyDelegateCall();
        _;
    }

    function _onlyDelegateCall() internal view {
        if (address(this) == SELF) revert DirectSettlementCallUnsupported();
    }

    function mintDirectSaleBatch(address _contractAddress, address _currencyAddress, MintRequest[] calldata _requests)
        external
        payable
        onlyDelegateCall
    {
        _validateMintRequests(_requests);
        MarketplaceStorage storage $ = _marketplaceStorage();
        $.marketConfig.checkIfCurrencyIsApproved(_currencyAddress);
        _validateERC1155Contract(_contractAddress);

        uint256 requestCount = _requests.length;
        uint256[] memory tokenIds = new uint256[](requestCount);
        uint256[] memory amounts = new uint256[](requestCount);
        PrimaryPayoutContext[] memory payoutContexts = new PrimaryPayoutContext[](requestCount);
        uint256 buyerTotal = 0;

        for (uint256 i = 0; i < requestCount;) {
            payoutContexts[i] =
                _validateMintDirectSaleRequest(_contractAddress, _currencyAddress, msg.sender, _requests[i]);
            if (payoutContexts[i].grossAmount != 0) {
                payoutContexts[i].marketplaceFee =
                    $.marketConfig.marketplaceSettings.calculateMarketplaceFee(payoutContexts[i].grossAmount);
                buyerTotal += payoutContexts[i].grossAmount + payoutContexts[i].marketplaceFee;
            }

            tokenIds[i] = payoutContexts[i].tokenId;
            amounts[i] = _requests[i].quantity;

            unchecked {
                ++i;
            }
        }

        $.marketConfig.checkBatchPayment(_currencyAddress, buyerTotal);

        for (uint256 i = 0; i < requestCount;) {
            uint256 tokenId = _requests[i].tokenId;

            if ($.tokenMintLimit[_contractAddress][tokenId] > 0) {
                $.tokenMintsPerAddress[_contractAddress][tokenId][msg.sender] += _requests[i].quantity;
            }

            if ($.tokenTxLimit[_contractAddress][tokenId] > 0) {
                $.tokenTxsPerAddress[_contractAddress][tokenId][msg.sender] += 1;
            }

            unchecked {
                ++i;
            }
        }

        _mintBatchToWithBalanceCheck(_contractAddress, msg.sender, tokenIds, amounts);

        for (uint256 i = 0; i < requestCount;) {
            if (payoutContexts[i].grossAmount != 0) {
                $.marketConfig
                    .payoutPrimary(
                        _contractAddress,
                        _currencyAddress,
                        payoutContexts[i].grossAmount,
                        payoutContexts[i].marketplaceFee,
                        payoutContexts[i].seller,
                        payoutContexts[i].splitRecipients,
                        payoutContexts[i].splitRatios
                    );
            }

            emit MintDirectSale(
                _contractAddress,
                payoutContexts[i].tokenId,
                msg.sender,
                payoutContexts[i].seller,
                _requests[i].quantity,
                _currencyAddress,
                _requests[i].price
            );

            unchecked {
                ++i;
            }
        }
    }

    function buyBatch(
        address _contractAddress,
        address _seller,
        address _currencyAddress,
        BuyRequest[] calldata _requests
    ) external payable onlyDelegateCall {
        _validateBuyRequests(_requests);
        if (msg.sender == _seller) revert SelfPurchaseUnsupported(_seller);

        MarketplaceStorage storage $ = _marketplaceStorage();
        $.marketConfig.checkIfCurrencyIsApproved(_currencyAddress);
        _validateERC1155Contract(_contractAddress);

        IERC1155 erc1155 = IERC1155(_contractAddress);
        if (!erc1155.isApprovedForAll(_seller, address($.erc1155ApprovalManager))) {
            revert MarketplaceNotApproved(_seller, _contractAddress);
        }

        uint256 requestCount = _requests.length;
        uint256[] memory tokenIds = new uint256[](requestCount);
        uint256[] memory amounts = new uint256[](requestCount);
        SecondaryPayoutContext[] memory payoutContexts = new SecondaryPayoutContext[](requestCount);
        uint256 buyerTotal = 0;

        for (uint256 i = 0; i < requestCount;) {
            payoutContexts[i] =
                _validateSecondaryBuyRequest($, _contractAddress, _seller, _currencyAddress, _requests[i]);

            tokenIds[i] = _requests[i].tokenId;
            amounts[i] = _requests[i].quantity;

            uint256 sellerBalance = erc1155.balanceOf(_seller, tokenIds[i]);
            if (sellerBalance < amounts[i]) {
                revert InsufficientTokenBalance(_seller, _contractAddress, tokenIds[i], amounts[i], sellerBalance);
            }

            payoutContexts[i].marketplaceFee =
                $.marketConfig.marketplaceSettings.calculateMarketplaceFee(payoutContexts[i].grossAmount);
            buyerTotal += payoutContexts[i].grossAmount + payoutContexts[i].marketplaceFee;

            unchecked {
                ++i;
            }
        }

        $.marketConfig.checkBatchPayment(_currencyAddress, buyerTotal);

        for (uint256 i = 0; i < requestCount;) {
            SalePrice storage salePrice = $.salePrices[_contractAddress][_requests[i].tokenId][_seller];
            salePrice.quantity -= _requests[i].quantity;
            if (salePrice.quantity == 0) {
                delete $.salePrices[_contractAddress][_requests[i].tokenId][_seller];
            }

            unchecked {
                ++i;
            }
        }

        _safeBatchTransferFrom(_contractAddress, _seller, msg.sender, tokenIds, amounts);

        for (uint256 i = 0; i < requestCount;) {
            $.marketConfig
                .payoutSecondary(
                    _contractAddress,
                    payoutContexts[i].tokenId,
                    _currencyAddress,
                    payoutContexts[i].grossAmount,
                    payoutContexts[i].marketplaceFee,
                    _seller,
                    payoutContexts[i].splitRecipients,
                    payoutContexts[i].splitRatios
                );

            emit Sold(
                _seller,
                msg.sender,
                _contractAddress,
                payoutContexts[i].tokenId,
                _currencyAddress,
                _requests[i].price,
                _requests[i].quantity
            );

            unchecked {
                ++i;
            }
        }
    }

    function acceptOffer(
        address _contractAddress,
        uint256 _tokenId,
        address _buyer,
        address _currencyAddress,
        uint256 _price,
        uint256 _quantity,
        address payable[] calldata _splitRecipients,
        uint8[] calldata _splitRatios
    ) external onlyDelegateCall {
        AcceptOfferInput memory input = AcceptOfferInput({
            contractAddress: _contractAddress,
            tokenId: _tokenId,
            buyer: _buyer,
            currencyAddress: _currencyAddress,
            price: _price,
            quantity: _quantity
        });
        _acceptOffer(input, _splitRecipients, _splitRatios);
    }

    function checkout(CheckoutItem[] calldata _items)
        external
        payable
        onlyDelegateCall
        returns (CheckoutExecution memory execution)
    {
        _validateCheckoutSize(_items.length);

        execution.items = new CheckoutItemResult[](_items.length);
        MarketplaceStorage storage $ = _marketplaceStorage();
        CheckoutDirectSaleMintAggregate[] memory directSaleMintAggregates =
            new CheckoutDirectSaleMintAggregate[](_items.length);
        uint256 directSaleMintAggregateCount = 0;
        uint256 remainingEth = msg.value;
        for (uint256 i = 0; i < _items.length;) {
            (CheckoutItemResult memory result, bool filled, uint256 newRemainingEth) = _processCheckoutItem(
                $, _items[i], i, remainingEth, directSaleMintAggregates, directSaleMintAggregateCount
            );
            if (filled) {
                remainingEth = newRemainingEth;
                directSaleMintAggregateCount =
                    _recordCheckoutDirectSaleMint(directSaleMintAggregates, directSaleMintAggregateCount, _items[i]);
                execution.summary.filledCount += 1;
                if (_items[i].currencyAddress == address(0)) execution.summary.ethSpent += result.totalPaid;
            } else {
                execution.summary.skippedCount += 1;
            }

            execution.items[i] = result;
            _emitCheckoutItemProcessed(result);

            unchecked {
                ++i;
            }
        }

        execution.summary.ethRefunded = remainingEth;
        if (remainingEth != 0) {
            $.marketConfig.refund(address(0), payable(msg.sender), remainingEth);
        }

        emit CheckoutCompleted(
            msg.sender,
            execution.summary.filledCount,
            execution.summary.skippedCount,
            execution.summary.ethSpent,
            execution.summary.ethRefunded
        );
    }

    function _processCheckoutItem(
        MarketplaceStorage storage $,
        CheckoutItem calldata _item,
        uint256 _itemIndex,
        uint256 _remainingEth,
        CheckoutDirectSaleMintAggregate[] memory _directSaleMintAggregates,
        uint256 _directSaleMintAggregateCount
    ) internal returns (CheckoutItemResult memory result, bool filled, uint256 newRemainingEth) {
        result = _baseCheckoutItemResult(_itemIndex, _item);
        newRemainingEth = _remainingEth;

        (bool valid, bytes memory failureData, CheckoutFillContext memory context) = _validateCheckoutItem($, _item);
        if (context.seller != address(0)) result.seller = context.seller;
        if (!valid) {
            _setCheckoutItemFailure(result, CheckoutFailureStage.VALIDATION, failureData);
            return (result, false, newRemainingEth);
        }

        bytes memory aggregateFailureData = _checkoutDirectSaleMintAggregateFailureData(
            _item, _directSaleMintAggregates, _directSaleMintAggregateCount, context.maxMints
        );
        if (aggregateFailureData.length != 0) {
            _setCheckoutItemFailure(result, CheckoutFailureStage.VALIDATION, aggregateFailureData);
            return (result, false, newRemainingEth);
        }

        (bool success, bytes memory data) =
            $.settlement.delegatecall(_checkoutItemCallData(_item, _remainingEth, context));
        if (!success) {
            (CheckoutFailureStage stage, bytes memory executionFailureData) = _checkoutExecutionFailure(data);
            _setCheckoutItemFailure(result, stage, executionFailureData);
            return (result, false, newRemainingEth);
        }

        (uint256 totalPaid, uint256 nextRemainingEth) = abi.decode(data, (uint256, uint256));
        result.filled = true;
        result.totalPaid = totalPaid;
        return (result, true, nextRemainingEth);
    }

    function _checkoutItemCallData(
        CheckoutItem calldata _item,
        uint256 _remainingEth,
        CheckoutFillContext memory _context
    ) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(
            IRareERC1155Settlement.executeCheckoutItem.selector,
            _item,
            _remainingEth,
            _context.seller,
            _context.grossAmount,
            _context.marketplaceFee,
            _context.splitRecipients,
            _context.splitRatios
        );
    }

    function executeCheckoutItem(
        CheckoutItem calldata _item,
        uint256 _remainingEth,
        address _seller,
        uint256 _grossAmount,
        uint256 _marketplaceFee,
        address payable[] calldata _splitRecipients,
        uint8[] calldata _splitRatios
    ) external payable onlyDelegateCall returns (uint256 totalPaid, uint256 newRemainingEth) {
        if (_item.itemKind == uint8(CheckoutItemKind.DIRECT_SALE_MINT)) {
            return _executeCheckoutDirectSaleMint(
                _item, _remainingEth, _seller, _grossAmount, _marketplaceFee, _splitRecipients, _splitRatios
            );
        }
        if (_item.itemKind == uint8(CheckoutItemKind.LISTING_BUY)) {
            return _executeCheckoutListingBuy(
                _item, _remainingEth, _seller, _grossAmount, _marketplaceFee, _splitRecipients, _splitRatios
            );
        }

        revert CheckoutItemExecutionFailed(
            CheckoutFailureStage.VALIDATION,
            abi.encodeWithSelector(UnsupportedCheckoutItemKind.selector, _item.itemKind)
        );
    }

    function executeCheckoutPayout(
        CheckoutItem calldata _item,
        address _seller,
        uint256 _grossAmount,
        uint256 _marketplaceFee,
        address payable[] calldata _splitRecipients,
        uint8[] calldata _splitRatios
    ) external payable onlyDelegateCall {
        MarketplaceStorage storage $ = _marketplaceStorage();
        if (_item.itemKind == uint8(CheckoutItemKind.DIRECT_SALE_MINT)) {
            $.marketConfig
                .payoutPrimary(
                    _item.contractAddress,
                    _item.currencyAddress,
                    _grossAmount,
                    _marketplaceFee,
                    _seller,
                    _splitRecipients,
                    _splitRatios
                );
            return;
        }
        if (_item.itemKind == uint8(CheckoutItemKind.LISTING_BUY)) {
            $.marketConfig
                .payoutSecondary(
                    _item.contractAddress,
                    _item.tokenId,
                    _item.currencyAddress,
                    _grossAmount,
                    _marketplaceFee,
                    _seller,
                    _splitRecipients,
                    _splitRatios
                );
            return;
        }

        revert UnsupportedCheckoutItemKind(_item.itemKind);
    }

    function _acceptOffer(
        AcceptOfferInput memory _input,
        address payable[] calldata _splitRecipients,
        uint8[] calldata _splitRatios
    ) internal {
        if (msg.sender == _input.buyer) {
            revert SelfOfferAcceptanceUnsupported(_input.buyer);
        }
        _validateERC1155Contract(_input.contractAddress);
        _marketplaceStorage().marketConfig.checkIfCurrencyIsApproved(_input.currencyAddress);
        RareERC1155MarketplacePayments.checkSplits(_splitRecipients, _splitRatios);
        if (_input.quantity == 0) revert QuantityCannotBeZero();

        (uint256 grossAmount, uint256 marketplaceFee) = _validateAndApplyOfferFill(_input);

        MarketplaceStorage storage $ = _marketplaceStorage();
        IERC1155 erc1155 = IERC1155(_input.contractAddress);
        if (!erc1155.isApprovedForAll(msg.sender, address($.erc1155ApprovalManager))) {
            revert MarketplaceNotApproved(msg.sender, _input.contractAddress);
        }

        _safeTransferFrom(_input.contractAddress, msg.sender, _input.buyer, _input.tokenId, _input.quantity);

        $.marketConfig
            .payoutSecondary(
                _input.contractAddress,
                _input.tokenId,
                _input.currencyAddress,
                grossAmount,
                marketplaceFee,
                msg.sender,
                _splitRecipients,
                _splitRatios
            );

        emit OfferAccepted(
            msg.sender,
            _input.buyer,
            _input.contractAddress,
            _input.tokenId,
            _input.currencyAddress,
            _input.price,
            _input.quantity
        );
    }

    function _executeCheckoutDirectSaleMint(
        CheckoutItem calldata _item,
        uint256 _remainingEth,
        address _seller,
        uint256 _grossAmount,
        uint256 _marketplaceFee,
        address payable[] calldata _splitRecipients,
        uint8[] calldata _splitRatios
    ) internal returns (uint256 totalPaid, uint256 newRemainingEth) {
        newRemainingEth = _remainingEth;
        MarketplaceStorage storage $ = _marketplaceStorage();

        totalPaid = _grossAmount + _marketplaceFee;
        bytes memory paymentFailureData = RareERC1155SettlementCheckoutUtils.checkoutPaymentFailureData(
            $.marketConfig, _item.currencyAddress, totalPaid, _remainingEth
        );
        if (paymentFailureData.length != 0) {
            revert CheckoutItemExecutionFailed(CheckoutFailureStage.PAYMENT_COLLECTION, paymentFailureData);
        }

        bool mintLimitEnabled = $.tokenMintLimit[_item.contractAddress][_item.tokenId] > 0;
        bool txLimitEnabled = $.tokenTxLimit[_item.contractAddress][_item.tokenId] > 0;
        if (mintLimitEnabled) {
            $.tokenMintsPerAddress[_item.contractAddress][_item.tokenId][msg.sender] += _item.quantity;
        }
        if (txLimitEnabled) {
            $.tokenTxsPerAddress[_item.contractAddress][_item.tokenId][msg.sender] += 1;
        }

        if (_item.currencyAddress == address(0)) {
            newRemainingEth = _remainingEth - totalPaid;
        } else {
            RareERC1155SettlementCheckoutUtils.collectCheckoutErc20($.marketConfig, _item.currencyAddress, totalPaid);
        }

        RareERC1155SettlementCheckoutUtils.checkoutMintBatchToWithBalanceCheck(
            _item.contractAddress, msg.sender, _singleUintArray(_item.tokenId), _singleUintArray(_item.quantity)
        );

        if (_grossAmount != 0) {
            _executeCheckoutPayout($, _item, _seller, _grossAmount, _marketplaceFee, _splitRecipients, _splitRatios);
        }

        emit MintDirectSale(
            _item.contractAddress,
            _item.tokenId,
            msg.sender,
            _seller,
            _item.quantity,
            _item.currencyAddress,
            _item.price
        );
    }

    function _executeCheckoutListingBuy(
        CheckoutItem calldata _item,
        uint256 _remainingEth,
        address _seller,
        uint256 _grossAmount,
        uint256 _marketplaceFee,
        address payable[] calldata _splitRecipients,
        uint8[] calldata _splitRatios
    ) internal returns (uint256 totalPaid, uint256 newRemainingEth) {
        newRemainingEth = _remainingEth;
        MarketplaceStorage storage $ = _marketplaceStorage();

        totalPaid = _grossAmount + _marketplaceFee;
        bytes memory paymentFailureData = RareERC1155SettlementCheckoutUtils.checkoutPaymentFailureData(
            $.marketConfig, _item.currencyAddress, totalPaid, _remainingEth
        );
        if (paymentFailureData.length != 0) {
            revert CheckoutItemExecutionFailed(CheckoutFailureStage.PAYMENT_COLLECTION, paymentFailureData);
        }

        if (_item.currencyAddress == address(0)) {
            newRemainingEth = _remainingEth - totalPaid;
        } else {
            RareERC1155SettlementCheckoutUtils.collectCheckoutErc20($.marketConfig, _item.currencyAddress, totalPaid);
        }

        SalePrice storage salePrice = $.salePrices[_item.contractAddress][_item.tokenId][_seller];
        salePrice.quantity -= _item.quantity;
        if (salePrice.quantity == 0) {
            delete $.salePrices[_item.contractAddress][_item.tokenId][_seller];
        }

        RareERC1155SettlementCheckoutUtils.checkoutSafeTransferFrom(
            $.erc1155ApprovalManager, _item.contractAddress, _seller, msg.sender, _item.tokenId, _item.quantity
        );

        _executeCheckoutPayout($, _item, _seller, _grossAmount, _marketplaceFee, _splitRecipients, _splitRatios);

        emit Sold(
            _seller,
            msg.sender,
            _item.contractAddress,
            _item.tokenId,
            _item.currencyAddress,
            _item.price,
            _item.quantity
        );
    }

    function _validateCheckoutItem(MarketplaceStorage storage $, CheckoutItem calldata _item)
        internal
        view
        returns (bool valid, bytes memory failureData, CheckoutFillContext memory context)
    {
        if (_item.itemKind == uint8(CheckoutItemKind.DIRECT_SALE_MINT)) {
            return _validateCheckoutDirectSaleMint($, _item);
        }
        if (_item.itemKind == uint8(CheckoutItemKind.LISTING_BUY)) {
            return _validateCheckoutListingBuy($, _item);
        }

        return (false, abi.encodeWithSelector(UnsupportedCheckoutItemKind.selector, _item.itemKind), context);
    }

    function _validateCheckoutDirectSaleMint(MarketplaceStorage storage $, CheckoutItem calldata _item)
        internal
        view
        returns (bool valid, bytes memory failureData, CheckoutFillContext memory context)
    {
        if (!_checkoutCurrencyApproved($.marketConfig, _item.currencyAddress)) {
            return (false, abi.encodeWithSelector(CurrencyNotApproved.selector, _item.currencyAddress), context);
        }
        if (!_checkoutValidErc1155Contract(_item.contractAddress)) {
            return (false, abi.encodeWithSelector(InvalidERC1155Contract.selector, _item.contractAddress), context);
        }

        (bool requestValid, bytes4 reason, PrimaryPayoutContext memory payoutContext) = _checkMintDirectSaleRequest(
            $,
            _item.contractAddress,
            _item.currencyAddress,
            msg.sender,
            _item.tokenId,
            _item.price,
            _item.quantity,
            _item.proof,
            ContractHasNoOwner.selector
        );
        context.seller = payoutContext.seller;
        if (!requestValid) {
            return (
                false,
                _mintFailureData(
                    reason,
                    $,
                    _item.contractAddress,
                    _item.currencyAddress,
                    msg.sender,
                    _item.tokenId,
                    _item.price,
                    _item.quantity
                ),
                context
            );
        }

        context.grossAmount = payoutContext.grossAmount;
        if (context.grossAmount != 0) {
            context.marketplaceFee = $.marketConfig.marketplaceSettings.calculateMarketplaceFee(context.grossAmount);
        }
        context.splitRecipients = payoutContext.splitRecipients;
        context.splitRatios = payoutContext.splitRatios;
        context.maxMints = payoutContext.maxMints;

        return (true, "", context);
    }

    function _validateCheckoutListingBuy(MarketplaceStorage storage $, CheckoutItem calldata _item)
        internal
        view
        returns (bool valid, bytes memory failureData, CheckoutFillContext memory context)
    {
        context.seller = _item.seller;
        if (msg.sender == _item.seller) {
            return (false, abi.encodeWithSelector(SelfPurchaseUnsupported.selector, _item.seller), context);
        }
        if (!_checkoutCurrencyApproved($.marketConfig, _item.currencyAddress)) {
            return (false, abi.encodeWithSelector(CurrencyNotApproved.selector, _item.currencyAddress), context);
        }
        if (!_checkoutValidErc1155Contract(_item.contractAddress)) {
            return (false, abi.encodeWithSelector(InvalidERC1155Contract.selector, _item.contractAddress), context);
        }

        SecondaryPayoutContext memory payoutContext;
        bytes4 reason;
        (valid, reason, payoutContext) = _checkSecondaryBuyRequest(
            $, _item.contractAddress, _item.seller, _item.currencyAddress, _item.tokenId, _item.price, _item.quantity
        );
        if (!valid) {
            return (
                false,
                _secondaryFailureData(
                    reason,
                    $,
                    _item.contractAddress,
                    _item.seller,
                    _item.currencyAddress,
                    _item.tokenId,
                    _item.price,
                    _item.quantity
                ),
                context
            );
        }

        IERC1155 erc1155 = IERC1155(_item.contractAddress);
        try erc1155.isApprovedForAll(_item.seller, address($.erc1155ApprovalManager)) returns (bool isApproved) {
            if (!isApproved) {
                return (
                    false,
                    abi.encodeWithSelector(MarketplaceNotApproved.selector, _item.seller, _item.contractAddress),
                    context
                );
            }
        } catch {
            return (
                false,
                abi.encodeWithSelector(MarketplaceNotApproved.selector, _item.seller, _item.contractAddress),
                context
            );
        }

        try erc1155.balanceOf(_item.seller, _item.tokenId) returns (uint256 sellerBalance) {
            if (sellerBalance < _item.quantity) {
                return (
                    false,
                    abi.encodeWithSelector(
                        InsufficientTokenBalance.selector,
                        _item.seller,
                        _item.contractAddress,
                        _item.tokenId,
                        _item.quantity,
                        sellerBalance
                    ),
                    context
                );
            }
        } catch {
            return (
                false,
                abi.encodeWithSelector(
                    InsufficientTokenBalance.selector,
                    _item.seller,
                    _item.contractAddress,
                    _item.tokenId,
                    _item.quantity,
                    0
                ),
                context
            );
        }

        context.grossAmount = payoutContext.grossAmount;
        context.marketplaceFee = $.marketConfig.marketplaceSettings.calculateMarketplaceFee(payoutContext.grossAmount);
        context.splitRecipients = payoutContext.splitRecipients;
        context.splitRatios = payoutContext.splitRatios;

        return (true, "", context);
    }

    function _executeCheckoutPayout(
        MarketplaceStorage storage $,
        CheckoutItem calldata _item,
        address _seller,
        uint256 _grossAmount,
        uint256 _marketplaceFee,
        address payable[] calldata _splitRecipients,
        uint8[] calldata _splitRatios
    ) internal {
        (bool success, bytes memory data) = $.settlement
            .delegatecall(
                abi.encodeWithSelector(
                    IRareERC1155Settlement.executeCheckoutPayout.selector,
                    _item,
                    _seller,
                    _grossAmount,
                    _marketplaceFee,
                    _splitRecipients,
                    _splitRatios
                )
            );
        if (!success) revert CheckoutItemExecutionFailed(CheckoutFailureStage.PAYOUT, data);
    }

    function _baseCheckoutItemResult(uint256 _itemIndex, CheckoutItem calldata _item)
        internal
        pure
        returns (CheckoutItemResult memory result)
    {
        result = CheckoutItemResult({
            itemIndex: _itemIndex,
            itemKind: _item.itemKind,
            contractAddress: _item.contractAddress,
            tokenId: _item.tokenId,
            seller: _item.seller,
            currencyAddress: _item.currencyAddress,
            price: _item.price,
            quantity: _item.quantity,
            filled: false,
            failureStage: CheckoutFailureStage.NONE,
            reason: bytes4(0),
            failureData: new bytes(0),
            totalPaid: 0
        });
    }

    function _setCheckoutItemFailure(
        CheckoutItemResult memory _result,
        CheckoutFailureStage _stage,
        bytes memory _failureData
    ) internal pure {
        _result.failureStage = _stage;
        _result.reason = _revertSelector(_failureData);
        _result.failureData = _failureData;
    }

    function _emitCheckoutItemProcessed(CheckoutItemResult memory _result) internal {
        emit CheckoutItemProcessed(
            _result.itemIndex,
            _result.itemKind,
            _result.contractAddress,
            _result.tokenId,
            _result.seller,
            _result.currencyAddress,
            _result.price,
            _result.quantity,
            _result.filled,
            _result.failureStage,
            _result.reason,
            _result.failureData,
            _result.totalPaid
        );
    }

    function _checkoutExecutionFailure(bytes memory _revertData)
        internal
        pure
        returns (CheckoutFailureStage stage, bytes memory failureData)
    {
        (bool decoded, CheckoutFailureStage decodedStage, bytes memory decodedFailureData) =
            _decodeCheckoutItemExecutionFailed(_revertData);
        if (decoded) return (decodedStage, decodedFailureData);
        return (CheckoutFailureStage.PAYOUT, _revertData);
    }

    function _decodeCheckoutItemExecutionFailed(bytes memory _revertData)
        internal
        pure
        returns (bool decoded, CheckoutFailureStage stage, bytes memory failureData)
    {
        // CheckoutItemExecutionFailed(CheckoutFailureStage,bytes):
        // selector | stage | offset | bytes length | bytes data
        if (_revertSelector(_revertData) != CheckoutItemExecutionFailed.selector || _revertData.length < 100) {
            return (false, CheckoutFailureStage.NONE, "");
        }

        uint256 stageValue;
        uint256 failureDataOffset;
        uint256 failureDataLength;
        assembly {
            stageValue := mload(add(_revertData, 36))
            failureDataOffset := mload(add(_revertData, 68))
            failureDataLength := mload(add(_revertData, 100))
        }
        if (stageValue > uint256(uint8(CheckoutFailureStage.PAYOUT)) || failureDataOffset != 64) {
            return (false, CheckoutFailureStage.NONE, "");
        }

        if (failureDataLength > _revertData.length - 100) return (false, CheckoutFailureStage.NONE, "");

        assembly {
            failureData := add(_revertData, 100)
        }
        return (true, CheckoutFailureStage(stageValue), failureData);
    }

    function _checkoutDirectSaleMintAggregateFailureData(
        CheckoutItem calldata _item,
        CheckoutDirectSaleMintAggregate[] memory _directSaleMintAggregates,
        uint256 _directSaleMintAggregateCount,
        uint256 _maxMints
    ) internal pure returns (bytes memory) {
        if (_item.itemKind != uint8(CheckoutItemKind.DIRECT_SALE_MINT) || _maxMints == 0) return "";

        uint256 filledQuantity = _checkoutDirectSaleMintAggregateQuantity(
            _directSaleMintAggregates, _directSaleMintAggregateCount, _item.contractAddress, _item.tokenId
        );
        uint256 aggregateQuantity = filledQuantity + _item.quantity;
        if (aggregateQuantity <= _maxMints) return "";

        return abi.encodeWithSelector(MaxMintExceeded.selector, aggregateQuantity, _maxMints);
    }

    function _checkoutDirectSaleMintAggregateQuantity(
        CheckoutDirectSaleMintAggregate[] memory _directSaleMintAggregates,
        uint256 _directSaleMintAggregateCount,
        address _contractAddress,
        uint256 _tokenId
    ) internal pure returns (uint256) {
        for (uint256 i = 0; i < _directSaleMintAggregateCount;) {
            if (
                _directSaleMintAggregates[i].contractAddress == _contractAddress
                    && _directSaleMintAggregates[i].tokenId == _tokenId
            ) {
                return _directSaleMintAggregates[i].quantity;
            }

            unchecked {
                ++i;
            }
        }

        return 0;
    }

    function _recordCheckoutDirectSaleMint(
        CheckoutDirectSaleMintAggregate[] memory _directSaleMintAggregates,
        uint256 _directSaleMintAggregateCount,
        CheckoutItem calldata _item
    ) internal pure returns (uint256) {
        if (_item.itemKind != uint8(CheckoutItemKind.DIRECT_SALE_MINT)) {
            return _directSaleMintAggregateCount;
        }

        for (uint256 i = 0; i < _directSaleMintAggregateCount;) {
            if (
                _directSaleMintAggregates[i].contractAddress == _item.contractAddress
                    && _directSaleMintAggregates[i].tokenId == _item.tokenId
            ) {
                _directSaleMintAggregates[i].quantity += _item.quantity;
                return _directSaleMintAggregateCount;
            }

            unchecked {
                ++i;
            }
        }

        _directSaleMintAggregates[_directSaleMintAggregateCount] = CheckoutDirectSaleMintAggregate({
            contractAddress: _item.contractAddress, tokenId: _item.tokenId, quantity: _item.quantity
        });
        return _directSaleMintAggregateCount + 1;
    }

    function _mintFailureData(
        bytes4 _reason,
        MarketplaceStorage storage $,
        address _contractAddress,
        address _currencyAddress,
        address _buyer,
        uint256 _tokenId,
        uint256 _price,
        uint256 _quantity
    ) internal view returns (bytes memory) {
        DirectSaleConfig storage directSaleConfig = $.directSaleConfigs[_contractAddress][_tokenId];

        if (_reason == DirectSaleNotConfigured.selector) {
            return abi.encodeWithSelector(DirectSaleNotConfigured.selector, _contractAddress, _tokenId);
        }
        if (_reason == ContractHasNoOwner.selector) {
            return abi.encodeWithSelector(ContractHasNoOwner.selector, _contractAddress);
        }
        if (_reason == NotContractOwner.selector) {
            return abi.encodeWithSelector(NotContractOwner.selector, _contractAddress, directSaleConfig.seller);
        }
        if (_reason == AddressNotAllowlisted.selector) {
            return abi.encodeWithSelector(AddressNotAllowlisted.selector, _buyer);
        }
        if (_reason == QuantityCannotBeZero.selector) return abi.encodeWithSelector(QuantityCannotBeZero.selector);
        if (_reason == MintLimitExceeded.selector) {
            uint256 mintLimit = $.tokenMintLimit[_contractAddress][_tokenId];
            uint256 currentMints = $.tokenMintsPerAddress[_contractAddress][_tokenId][_buyer];
            return abi.encodeWithSelector(
                MintLimitExceeded.selector, _contractAddress, _tokenId, _buyer, _quantity, currentMints, mintLimit
            );
        }
        if (_reason == TransactionLimitExceeded.selector) {
            uint256 txLimit = $.tokenTxLimit[_contractAddress][_tokenId];
            uint256 currentTxs = $.tokenTxsPerAddress[_contractAddress][_tokenId][_buyer];
            return abi.encodeWithSelector(
                TransactionLimitExceeded.selector, _contractAddress, _tokenId, _buyer, currentTxs, txLimit
            );
        }
        if (_reason == MaxMintExceeded.selector) {
            return abi.encodeWithSelector(MaxMintExceeded.selector, _quantity, directSaleConfig.maxMints);
        }
        if (_reason == SaleNotStarted.selector) {
            return abi.encodeWithSelector(SaleNotStarted.selector, directSaleConfig.startTime);
        }
        if (_reason == PriceMismatch.selector) {
            return abi.encodeWithSelector(PriceMismatch.selector, _price, directSaleConfig.price);
        }
        if (_reason == CurrencyMismatch.selector) {
            return abi.encodeWithSelector(CurrencyMismatch.selector, _currencyAddress, directSaleConfig.currencyAddress);
        }

        return "";
    }

    function _secondaryFailureData(
        bytes4 _reason,
        MarketplaceStorage storage $,
        address _contractAddress,
        address _seller,
        address _currencyAddress,
        uint256 _tokenId,
        uint256 _price,
        uint256 _quantity
    ) internal view returns (bytes memory) {
        SalePrice storage salePrice = $.salePrices[_contractAddress][_tokenId][_seller];

        if (_reason == QuantityCannotBeZero.selector) return abi.encodeWithSelector(QuantityCannotBeZero.selector);
        if (_reason == SalePriceDoesNotExist.selector) {
            return abi.encodeWithSelector(SalePriceDoesNotExist.selector, _contractAddress, _tokenId, _seller);
        }
        if (_reason == SalePriceExpired.selector) {
            return abi.encodeWithSelector(
                SalePriceExpired.selector, _contractAddress, _tokenId, _seller, salePrice.expirationTime
            );
        }
        if (_reason == CurrencyMismatch.selector) {
            return abi.encodeWithSelector(CurrencyMismatch.selector, _currencyAddress, salePrice.currencyAddress);
        }
        if (_reason == PriceMismatch.selector) {
            return abi.encodeWithSelector(PriceMismatch.selector, _price, salePrice.price);
        }
        if (_reason == QuantityExceedsSalePriceQuantity.selector) {
            return abi.encodeWithSelector(QuantityExceedsSalePriceQuantity.selector, _quantity, salePrice.quantity);
        }

        return "";
    }

    function _checkoutCurrencyApproved(MarketConfigV2.Config storage _config, address _currencyAddress)
        internal
        view
        returns (bool)
    {
        if (_currencyAddress == address(0)) return true;

        try _config.approvedTokenRegistry.isApprovedToken(_currencyAddress) returns (bool approved) {
            return approved;
        } catch {
            return false;
        }
    }

    function _checkoutValidErc1155Contract(address _contractAddress) internal view returns (bool) {
        return _contractAddress.code.length != 0
            && ERC165Checker.supportsInterface(_contractAddress, type(IERC1155).interfaceId);
    }

    function _checkContractOwner(address _contractAddress, address _account)
        internal
        view
        returns (bool readable, bool isOwner)
    {
        (bool success, bytes memory data) = _contractAddress.staticcall(abi.encodeWithSignature("owner()"));
        if (!success || data.length < 32) return (false, false);
        return (true, abi.decode(data, (address)) == _account);
    }

    function _checkTokenAllowList(
        MarketplaceStorage storage $,
        address _contractAddress,
        uint256 _tokenId,
        address _account,
        bytes32[] calldata _proof
    ) internal view returns (bool) {
        AllowListConfig memory allowListConfig = $.tokenAllowlistRoots[_contractAddress][_tokenId];
        if (allowListConfig.root == bytes32(0) || block.timestamp >= allowListConfig.endTimestamp) return true;
        return _verifyProof(keccak256(abi.encodePacked(_account)), allowListConfig.root, _proof);
    }

    function _singleUintArray(uint256 _value) internal pure returns (uint256[] memory values) {
        values = new uint256[](1);
        values[0] = _value;
    }

    function _revertSelector(bytes memory _revertData) internal pure returns (bytes4 selector) {
        if (_revertData.length < 4) return bytes4(0);

        assembly {
            selector := mload(add(_revertData, 32))
        }
    }

    function _revertBytes(bytes memory _revertData) internal pure {
        assembly {
            revert(add(_revertData, 32), mload(_revertData))
        }
    }

    function _validateMintDirectSaleRequest(
        address _contractAddress,
        address _currencyAddress,
        address _buyer,
        MintRequest calldata _request
    ) internal view returns (PrimaryPayoutContext memory payoutContext) {
        MarketplaceStorage storage $ = _marketplaceStorage();
        (bool valid, bytes4 reason, PrimaryPayoutContext memory checkedContext) = _checkMintDirectSaleRequest(
            $,
            _contractAddress,
            _currencyAddress,
            _buyer,
            _request.tokenId,
            _request.price,
            _request.quantity,
            _request.proof,
            ContractHasNoOwner.selector
        );
        if (!valid) _revertMintDirectSaleRequest(reason, $, _contractAddress, _currencyAddress, _buyer, _request);
        return checkedContext;
    }

    function _validateSecondaryBuyRequest(
        MarketplaceStorage storage $,
        address _contractAddress,
        address _seller,
        address _currencyAddress,
        BuyRequest calldata _request
    ) internal view returns (SecondaryPayoutContext memory payoutContext) {
        (bool valid, bytes4 reason, SecondaryPayoutContext memory checkedContext) = _checkSecondaryBuyRequest(
            $, _contractAddress, _seller, _currencyAddress, _request.tokenId, _request.price, _request.quantity
        );
        if (!valid) _revertSecondaryBuyRequest(reason, $, _contractAddress, _seller, _currencyAddress, _request);
        return checkedContext;
    }

    function _checkMintDirectSaleRequest(
        MarketplaceStorage storage $,
        address _contractAddress,
        address _currencyAddress,
        address _buyer,
        uint256 _tokenId,
        uint256 _price,
        uint256 _quantity,
        bytes32[] calldata _proof,
        bytes4 _ownerLookupFailureReason
    ) internal view returns (bool valid, bytes4 reason, PrimaryPayoutContext memory payoutContext) {
        DirectSaleConfig memory directSaleConfig = $.directSaleConfigs[_contractAddress][_tokenId];
        payoutContext.tokenId = _tokenId;
        payoutContext.seller = directSaleConfig.seller;
        payoutContext.maxMints = directSaleConfig.maxMints;

        if (directSaleConfig.seller == address(0)) return (false, DirectSaleNotConfigured.selector, payoutContext);

        (bool ownerReadable, bool isOwner) = _checkContractOwner(_contractAddress, directSaleConfig.seller);
        if (!ownerReadable) return (false, _ownerLookupFailureReason, payoutContext);
        if (!isOwner) return (false, NotContractOwner.selector, payoutContext);
        if (!_checkTokenAllowList($, _contractAddress, _tokenId, _buyer, _proof)) {
            return (false, AddressNotAllowlisted.selector, payoutContext);
        }
        if (_quantity == 0) return (false, QuantityCannotBeZero.selector, payoutContext);

        uint256 mintLimit = $.tokenMintLimit[_contractAddress][_tokenId];
        uint256 currentMints = $.tokenMintsPerAddress[_contractAddress][_tokenId][_buyer];
        if (mintLimit != 0 && currentMints + _quantity > mintLimit) {
            return (false, MintLimitExceeded.selector, payoutContext);
        }

        uint256 txLimit = $.tokenTxLimit[_contractAddress][_tokenId];
        uint256 currentTxs = $.tokenTxsPerAddress[_contractAddress][_tokenId][_buyer];
        if (txLimit != 0 && currentTxs + 1 > txLimit) {
            return (false, TransactionLimitExceeded.selector, payoutContext);
        }

        if (directSaleConfig.maxMints != 0 && _quantity > directSaleConfig.maxMints) {
            return (false, MaxMintExceeded.selector, payoutContext);
        }
        if (directSaleConfig.startTime > block.timestamp) return (false, SaleNotStarted.selector, payoutContext);
        if (_price != directSaleConfig.price) return (false, PriceMismatch.selector, payoutContext);
        if (directSaleConfig.currencyAddress != _currencyAddress) {
            return (false, CurrencyMismatch.selector, payoutContext);
        }

        payoutContext.grossAmount = _quantity * _price;
        payoutContext.splitRecipients = directSaleConfig.splitRecipients;
        payoutContext.splitRatios = directSaleConfig.splitRatios;

        return (true, bytes4(0), payoutContext);
    }

    function _checkSecondaryBuyRequest(
        MarketplaceStorage storage $,
        address _contractAddress,
        address _seller,
        address _currencyAddress,
        uint256 _tokenId,
        uint256 _price,
        uint256 _quantity
    ) internal view returns (bool valid, bytes4 reason, SecondaryPayoutContext memory payoutContext) {
        payoutContext.tokenId = _tokenId;
        if (_quantity == 0) return (false, QuantityCannotBeZero.selector, payoutContext);

        SalePrice storage salePrice = $.salePrices[_contractAddress][_tokenId][_seller];
        if (salePrice.quantity == 0) return (false, SalePriceDoesNotExist.selector, payoutContext);
        if (salePrice.expirationTime != 0 && salePrice.expirationTime <= block.timestamp) {
            return (false, SalePriceExpired.selector, payoutContext);
        }
        if (salePrice.currencyAddress != _currencyAddress) return (false, CurrencyMismatch.selector, payoutContext);
        if (salePrice.price != _price) return (false, PriceMismatch.selector, payoutContext);
        if (salePrice.quantity < _quantity) {
            return (false, QuantityExceedsSalePriceQuantity.selector, payoutContext);
        }

        payoutContext.grossAmount = _quantity * _price;
        payoutContext.splitRecipients = salePrice.splitRecipients;
        payoutContext.splitRatios = salePrice.splitRatios;

        return (true, bytes4(0), payoutContext);
    }

    function _revertMintDirectSaleRequest(
        bytes4 _reason,
        MarketplaceStorage storage $,
        address _contractAddress,
        address _currencyAddress,
        address _buyer,
        MintRequest calldata _request
    ) internal view {
        _revertBytes(
            _mintFailureData(
                _reason,
                $,
                _contractAddress,
                _currencyAddress,
                _buyer,
                _request.tokenId,
                _request.price,
                _request.quantity
            )
        );
    }

    function _revertSecondaryBuyRequest(
        bytes4 _reason,
        MarketplaceStorage storage $,
        address _contractAddress,
        address _seller,
        address _currencyAddress,
        BuyRequest calldata _request
    ) internal view {
        _revertBytes(
            _secondaryFailureData(
                _reason,
                $,
                _contractAddress,
                _seller,
                _currencyAddress,
                _request.tokenId,
                _request.price,
                _request.quantity
            )
        );
    }

    function _validateAndApplyOfferFill(AcceptOfferInput memory _input)
        internal
        returns (uint256 grossAmount, uint256 marketplaceFee)
    {
        Offer storage offer = _marketplaceStorage()
        .offers[_input.contractAddress][_input.tokenId][_input.buyer][_input.currencyAddress];

        if (offer.quantity == 0) {
            revert OfferDoesNotExist(_input.contractAddress, _input.tokenId, _input.buyer, _input.currencyAddress);
        }
        if (offer.expirationTime != 0 && offer.expirationTime <= block.timestamp) {
            revert OfferExpired(
                _input.contractAddress, _input.tokenId, _input.buyer, _input.currencyAddress, offer.expirationTime
            );
        }
        if (offer.currencyAddress != _input.currencyAddress) {
            revert CurrencyMismatch(_input.currencyAddress, offer.currencyAddress);
        }
        if (offer.price != _input.price) revert PriceMismatch(_input.price, offer.price);
        if (_input.quantity > offer.quantity) revert QuantityExceedsOfferQuantity(_input.quantity, offer.quantity);

        grossAmount = _input.price * _input.quantity;
        marketplaceFee = _allocateMarketplaceFee(offer, _input.quantity);
    }

    function _allocateMarketplaceFee(Offer storage _offer, uint256 _quantity)
        internal
        returns (uint256 marketplaceFee)
    {
        uint256 remainingQuantity = _offer.quantity;
        if (_quantity == remainingQuantity) {
            marketplaceFee = _offer.marketplaceFeeRemaining;
            delete _offer.currencyAddress;
            delete _offer.price;
            delete _offer.quantity;
            delete _offer.initialQuantity;
            delete _offer.marketplaceFeeRemaining;
            delete _offer.marketplaceFeeTotal;
            delete _offer.expirationTime;
            return marketplaceFee;
        }

        uint256 marketplaceFeeTotal = _offer.marketplaceFeeTotal;
        uint256 initialQuantity = _offer.initialQuantity;
        uint256 filledQuantityBefore = initialQuantity - remainingQuantity;
        uint256 filledQuantityAfter = filledQuantityBefore + _quantity;
        uint256 marketplaceFeePaidBefore = marketplaceFeeTotal - _offer.marketplaceFeeRemaining;
        uint256 marketplaceFeeDueAfter = Math.mulDiv(marketplaceFeeTotal, filledQuantityAfter, initialQuantity);

        marketplaceFee = marketplaceFeeDueAfter - marketplaceFeePaidBefore;
        _offer.quantity = remainingQuantity - _quantity;
        _offer.marketplaceFeeRemaining -= marketplaceFee;
    }

    function _safeTransferFrom(
        address _contractAddress,
        address _seller,
        address _buyer,
        uint256 _tokenId,
        uint256 _amount
    ) internal {
        IERC1155 erc1155 = IERC1155(_contractAddress);
        uint256 sellerBalanceBefore = erc1155.balanceOf(_seller, _tokenId);
        if (sellerBalanceBefore < _amount) {
            revert InsufficientTokenBalance(_seller, _contractAddress, _tokenId, _amount, sellerBalanceBefore);
        }
        uint256 buyerBalanceBefore = erc1155.balanceOf(_buyer, _tokenId);

        _marketplaceStorage().erc1155ApprovalManager
            .safeTransferFrom(_contractAddress, _seller, _buyer, _tokenId, _amount, "");

        uint256 sellerBalanceAfter = erc1155.balanceOf(_seller, _tokenId);
        uint256 buyerBalanceAfter = erc1155.balanceOf(_buyer, _tokenId);
        if (sellerBalanceAfter != sellerBalanceBefore - _amount || buyerBalanceAfter != buyerBalanceBefore + _amount) {
            revert InvalidERC1155Transfer(_contractAddress, _tokenId, _seller, _buyer, _amount);
        }
    }

    function _safeBatchTransferFrom(
        address _contractAddress,
        address _seller,
        address _buyer,
        uint256[] memory _tokenIds,
        uint256[] memory _amounts
    ) internal {
        IERC1155 erc1155 = IERC1155(_contractAddress);
        uint256 requestCount = _tokenIds.length;
        address[] memory balanceAccounts = new address[](requestCount * 2);
        uint256[] memory balanceTokenIds = new uint256[](requestCount * 2);

        for (uint256 i = 0; i < requestCount;) {
            uint256 balanceIndex = i * 2;
            balanceAccounts[balanceIndex] = _seller;
            balanceAccounts[balanceIndex + 1] = _buyer;
            balanceTokenIds[balanceIndex] = _tokenIds[i];
            balanceTokenIds[balanceIndex + 1] = _tokenIds[i];

            unchecked {
                ++i;
            }
        }

        uint256[] memory balancesBeforeTransfer = erc1155.balanceOfBatch(balanceAccounts, balanceTokenIds);
        for (uint256 i = 0; i < requestCount;) {
            uint256 sellerBalanceIndex = i * 2;
            if (balancesBeforeTransfer[sellerBalanceIndex] < _amounts[i]) {
                revert InsufficientTokenBalance(
                    _seller, _contractAddress, _tokenIds[i], _amounts[i], balancesBeforeTransfer[sellerBalanceIndex]
                );
            }

            unchecked {
                ++i;
            }
        }

        _marketplaceStorage().erc1155ApprovalManager
            .safeBatchTransferFrom(_contractAddress, _seller, _buyer, _tokenIds, _amounts, "");

        uint256[] memory balancesAfterTransfer = erc1155.balanceOfBatch(balanceAccounts, balanceTokenIds);
        for (uint256 i = 0; i < requestCount;) {
            uint256 balanceIndex = i * 2;
            if (
                balancesAfterTransfer[balanceIndex] != balancesBeforeTransfer[balanceIndex] - _amounts[i]
                    || balancesAfterTransfer[balanceIndex + 1] != balancesBeforeTransfer[balanceIndex + 1] + _amounts[i]
            ) {
                revert InvalidERC1155Transfer(_contractAddress, _tokenIds[i], _seller, _buyer, _amounts[i]);
            }

            unchecked {
                ++i;
            }
        }
    }

    function _mintBatchToWithBalanceCheck(
        address _contractAddress,
        address _buyer,
        uint256[] memory _tokenIds,
        uint256[] memory _amounts
    ) internal {
        IERC1155 erc1155 = IERC1155(_contractAddress);
        address[] memory balanceAccounts = _balanceAccounts(_buyer, _tokenIds.length);
        uint256[] memory balancesBeforeMint = erc1155.balanceOfBatch(balanceAccounts, _tokenIds);

        IRareERC1155(_contractAddress).mintBatchTo(_buyer, _tokenIds, _amounts);

        uint256[] memory balancesAfterMint = erc1155.balanceOfBatch(balanceAccounts, _tokenIds);
        _validateMintBalanceDeltas(_contractAddress, _buyer, _tokenIds, _amounts, balancesBeforeMint, balancesAfterMint);
    }

    function _balanceAccounts(address _account, uint256 _length) internal pure returns (address[] memory accounts) {
        accounts = new address[](_length);
        for (uint256 i = 0; i < _length;) {
            accounts[i] = _account;

            unchecked {
                ++i;
            }
        }
    }

    function _validateMintBalanceDeltas(
        address _contractAddress,
        address _buyer,
        uint256[] memory _tokenIds,
        uint256[] memory _amounts,
        uint256[] memory _balancesBeforeMint,
        uint256[] memory _balancesAfterMint
    ) internal pure {
        for (uint256 i = 0; i < _tokenIds.length;) {
            if (_balancesAfterMint[i] != _balancesBeforeMint[i] + _amounts[i]) {
                revert InvalidERC1155Mint(_contractAddress, _tokenIds[i], _buyer, _amounts[i]);
            }

            unchecked {
                ++i;
            }
        }
    }

    function _validateMintRequests(MintRequest[] calldata _requests) internal pure {
        _validateBatchSize(_requests.length);
        for (uint256 i = 1; i < _requests.length; i++) {
            _validateStrictAscending(i, _requests[i - 1].tokenId, _requests[i].tokenId);
        }
    }

    function _validateBuyRequests(BuyRequest[] calldata _requests) internal pure {
        _validateBatchSize(_requests.length);
        for (uint256 i = 1; i < _requests.length; i++) {
            _validateStrictAscending(i, _requests[i - 1].tokenId, _requests[i].tokenId);
        }
    }
}
