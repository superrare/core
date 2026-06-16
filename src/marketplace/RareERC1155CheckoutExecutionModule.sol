// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import {IERC1155} from "openzeppelin-contracts/token/ERC1155/IERC1155.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {ERC165Checker} from "openzeppelin-contracts/utils/introspection/ERC165Checker.sol";

import {IRareERC1155} from "../token/ERC1155/IRareERC1155.sol";
import {MarketConfigV2} from "../v2/utils/MarketConfigV2.sol";
import {IERC1155ApprovalManager} from "../v2/approver/ERC1155/IERC1155ApprovalManager.sol";
import {IRareERC1155CheckoutExecutionModule} from "./IRareERC1155CheckoutExecutionModule.sol";
import {RareERC1155ExecutionModuleBase} from "./RareERC1155ExecutionModuleBase.sol";
import {RareERC1155MarketplacePayments} from "./RareERC1155MarketplacePayments.sol";

/// @author SuperRare Labs Inc.
/// @title RareERC1155CheckoutExecutionModule
/// @notice Delegatecall-only multi-item checkout execution module for the ERC1155 marketplace.
/// @dev Direct calls revert because this contract has no standalone marketplace state or escrow. It must run through
/// `RareERC1155Marketplace` so `address(this)`, `msg.sender`, `msg.value`, and storage all resolve to the marketplace proxy.
contract RareERC1155CheckoutExecutionModule is IRareERC1155CheckoutExecutionModule, RareERC1155ExecutionModuleBase {
    using RareERC1155MarketplacePayments for MarketConfigV2.Config;

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

    function checkout(
        address _recipient,
        CheckoutItem[] calldata _items
    ) external payable onlyDelegateCall returns (CheckoutExecution memory execution) {
        _validateRecipient(_recipient);
        _validateCheckoutSize(_items.length);

        execution.items = new CheckoutItemResult[](_items.length);
        MarketplaceStorage storage $ = _marketplaceStorage();
        CheckoutDirectSaleMintAggregate[] memory directSaleMintAggregates = new CheckoutDirectSaleMintAggregate[](
            _items.length
        );
        uint256 directSaleMintAggregateCount = 0;
        uint256 remainingEth = msg.value;
        for (uint256 i = 0; i < _items.length; ) {
            (CheckoutItemResult memory result, bool filled, uint256 newRemainingEth) = _processCheckoutItem(
                $,
                _items[i],
                i,
                remainingEth,
                _recipient,
                directSaleMintAggregates,
                directSaleMintAggregateCount
            );
            if (filled) {
                remainingEth = newRemainingEth;
                _recordCheckoutDirectSaleMintTx(
                    $,
                    _items[i],
                    _recipient,
                    directSaleMintAggregates,
                    directSaleMintAggregateCount
                );
                directSaleMintAggregateCount = _recordCheckoutDirectSaleMint(
                    directSaleMintAggregates,
                    directSaleMintAggregateCount,
                    _items[i]
                );
                execution.summary.filledCount += 1;
                if (_items[i].currencyAddress == address(0)) execution.summary.ethSpent += result.totalPaid;
            } else {
                execution.summary.skippedCount += 1;
            }

            execution.items[i] = result;
            _emitCheckoutItemProcessed(result, _recipient);

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
            _recipient,
            execution.summary.filledCount,
            execution.summary.skippedCount,
            execution.summary.ethSpent,
            execution.summary.ethRefunded
        );
    }

    function executeCheckoutItem(
        CheckoutItem calldata _item,
        uint256 _remainingEth,
        address _recipient,
        address _seller,
        uint256 _grossAmount,
        uint256 _marketplaceFee,
        address payable[] calldata _splitRecipients,
        uint8[] calldata _splitRatios
    ) external payable onlyDelegateCall returns (uint256 totalPaid, uint256 newRemainingEth) {
        if (_item.itemKind == uint8(CheckoutItemKind.DIRECT_SALE_MINT)) {
            return
                _executeCheckoutDirectSaleMint(
                    _item,
                    _remainingEth,
                    _recipient,
                    _seller,
                    _grossAmount,
                    _marketplaceFee,
                    _splitRecipients,
                    _splitRatios
                );
        }
        if (_item.itemKind == uint8(CheckoutItemKind.LISTING_BUY)) {
            return
                _executeCheckoutListingBuy(
                    _item,
                    _remainingEth,
                    _recipient,
                    _seller,
                    _grossAmount,
                    _marketplaceFee,
                    _splitRecipients,
                    _splitRatios
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
        _seller;
        MarketplaceStorage storage $ = _marketplaceStorage();
        if (_item.itemKind == uint8(CheckoutItemKind.DIRECT_SALE_MINT)) {
            $.marketConfig.payoutPrimary(
                _item.contractAddress,
                _item.currencyAddress,
                _grossAmount,
                _marketplaceFee,
                _splitRecipients,
                _splitRatios
            );
            return;
        }
        if (_item.itemKind == uint8(CheckoutItemKind.LISTING_BUY)) {
            $.marketConfig.payoutSecondary(
                _item.contractAddress,
                _item.tokenId,
                _item.currencyAddress,
                _grossAmount,
                _marketplaceFee,
                _splitRecipients,
                _splitRatios
            );
            return;
        }

        revert UnsupportedCheckoutItemKind(_item.itemKind);
    }

    function _processCheckoutItem(
        MarketplaceStorage storage $,
        CheckoutItem calldata _item,
        uint256 _itemIndex,
        uint256 _remainingEth,
        address _recipient,
        CheckoutDirectSaleMintAggregate[] memory _directSaleMintAggregates,
        uint256 _directSaleMintAggregateCount
    ) internal returns (CheckoutItemResult memory result, bool filled, uint256 newRemainingEth) {
        result = _baseCheckoutItemResult(_itemIndex, _item);
        newRemainingEth = _remainingEth;

        bool directSaleMintTxAlreadyRecorded = _checkoutDirectSaleMintAggregateQuantity(
            _directSaleMintAggregates,
            _directSaleMintAggregateCount,
            _item.contractAddress,
            _item.tokenId
        ) != 0;
        (bool valid, bytes memory failureData, CheckoutFillContext memory context) = _validateCheckoutItem(
            $,
            _item,
            _recipient,
            directSaleMintTxAlreadyRecorded
        );
        if (context.seller != address(0)) result.seller = context.seller;
        if (!valid) {
            _setCheckoutItemFailure(result, CheckoutFailureStage.VALIDATION, failureData);
            return (result, false, newRemainingEth);
        }

        bytes memory aggregateFailureData = _checkoutDirectSaleMintAggregateFailureData(
            _item,
            _directSaleMintAggregates,
            _directSaleMintAggregateCount,
            context.maxMints
        );
        if (aggregateFailureData.length != 0) {
            _setCheckoutItemFailure(result, CheckoutFailureStage.VALIDATION, aggregateFailureData);
            return (result, false, newRemainingEth);
        }

        (bool success, bytes memory data) = $.checkoutExecutionModule.delegatecall(
            _checkoutItemCallData(_item, _remainingEth, _recipient, context)
        );
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
        address _recipient,
        CheckoutFillContext memory _context
    ) internal pure returns (bytes memory) {
        return
            abi.encodeWithSelector(
                IRareERC1155CheckoutExecutionModule.executeCheckoutItem.selector,
                _item,
                _remainingEth,
                _recipient,
                _context.seller,
                _context.grossAmount,
                _context.marketplaceFee,
                _context.splitRecipients,
                _context.splitRatios
            );
    }

    function _executeCheckoutDirectSaleMint(
        CheckoutItem calldata _item,
        uint256 _remainingEth,
        address _recipient,
        address _seller,
        uint256 _grossAmount,
        uint256 _marketplaceFee,
        address payable[] calldata _splitRecipients,
        uint8[] calldata _splitRatios
    ) internal returns (uint256 totalPaid, uint256 newRemainingEth) {
        newRemainingEth = _remainingEth;
        MarketplaceStorage storage $ = _marketplaceStorage();

        totalPaid = _grossAmount + _marketplaceFee;
        bytes memory paymentFailureData = _checkoutPaymentFailureData(
            $.marketConfig,
            _item.currencyAddress,
            totalPaid,
            _remainingEth
        );
        if (paymentFailureData.length != 0) {
            revert CheckoutItemExecutionFailed(CheckoutFailureStage.PAYMENT_COLLECTION, paymentFailureData);
        }

        bool mintLimitEnabled = $.tokenMintLimit[_item.contractAddress][_item.tokenId] > 0;
        if (mintLimitEnabled) {
            $.tokenMintsPerAddress[_item.contractAddress][_item.tokenId][_recipient] += _item.quantity;
        }

        if (_item.currencyAddress == address(0)) {
            newRemainingEth = _remainingEth - totalPaid;
        } else {
            _collectCheckoutErc20($.marketConfig, _item.currencyAddress, totalPaid);
        }

        _checkoutMintBatchToWithBalanceCheck(
            _item.contractAddress,
            _recipient,
            _singleUintArray(_item.tokenId),
            _singleUintArray(_item.quantity)
        );

        if (_grossAmount != 0) {
            _executeCheckoutPayout($, _item, _seller, _grossAmount, _marketplaceFee, _splitRecipients, _splitRatios);
        }

        emit MintDirectSale(
            _item.contractAddress,
            _item.tokenId,
            msg.sender,
            _recipient,
            _seller,
            _item.quantity,
            _item.currencyAddress,
            _item.price
        );
    }

    function _executeCheckoutListingBuy(
        CheckoutItem calldata _item,
        uint256 _remainingEth,
        address _recipient,
        address _seller,
        uint256 _grossAmount,
        uint256 _marketplaceFee,
        address payable[] calldata _splitRecipients,
        uint8[] calldata _splitRatios
    ) internal returns (uint256 totalPaid, uint256 newRemainingEth) {
        newRemainingEth = _remainingEth;
        MarketplaceStorage storage $ = _marketplaceStorage();

        totalPaid = _grossAmount + _marketplaceFee;
        bytes memory paymentFailureData = _checkoutPaymentFailureData(
            $.marketConfig,
            _item.currencyAddress,
            totalPaid,
            _remainingEth
        );
        if (paymentFailureData.length != 0) {
            revert CheckoutItemExecutionFailed(CheckoutFailureStage.PAYMENT_COLLECTION, paymentFailureData);
        }

        if (_item.currencyAddress == address(0)) {
            newRemainingEth = _remainingEth - totalPaid;
        } else {
            _collectCheckoutErc20($.marketConfig, _item.currencyAddress, totalPaid);
        }

        SalePrice storage salePrice = $.salePrices[_item.contractAddress][_item.tokenId][_seller];
        salePrice.quantity -= _item.quantity;
        if (salePrice.quantity == 0) {
            delete $.salePrices[_item.contractAddress][_item.tokenId][_seller];
        }

        _checkoutSafeTransferFrom(
            $.erc1155ApprovalManager,
            _item.contractAddress,
            _seller,
            _recipient,
            _item.tokenId,
            _item.quantity
        );

        _executeCheckoutPayout($, _item, _seller, _grossAmount, _marketplaceFee, _splitRecipients, _splitRatios);

        emit Sold(
            _seller,
            msg.sender,
            _item.contractAddress,
            _recipient,
            _item.tokenId,
            _item.currencyAddress,
            _item.price,
            _item.quantity
        );
    }

    function _validateCheckoutItem(
        MarketplaceStorage storage $,
        CheckoutItem calldata _item,
        address _recipient,
        bool _directSaleMintTxAlreadyRecorded
    ) internal view returns (bool valid, bytes memory failureData, CheckoutFillContext memory context) {
        if (_item.itemKind == uint8(CheckoutItemKind.DIRECT_SALE_MINT)) {
            return _validateCheckoutDirectSaleMint($, _item, _recipient, _directSaleMintTxAlreadyRecorded);
        }
        if (_item.itemKind == uint8(CheckoutItemKind.LISTING_BUY)) {
            return _validateCheckoutListingBuy($, _item, _recipient);
        }

        return (false, abi.encodeWithSelector(UnsupportedCheckoutItemKind.selector, _item.itemKind), context);
    }

    function _validateCheckoutDirectSaleMint(
        MarketplaceStorage storage $,
        CheckoutItem calldata _item,
        address _recipient,
        bool _txLimitAlreadyConsumed
    ) internal view returns (bool valid, bytes memory failureData, CheckoutFillContext memory context) {
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
            _recipient,
            _item.tokenId,
            _item.price,
            _item.quantity,
            _item.proof,
            ContractHasNoOwner.selector,
            _txLimitAlreadyConsumed
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
                    _recipient,
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

    function _validateCheckoutListingBuy(
        MarketplaceStorage storage $,
        CheckoutItem calldata _item,
        address _recipient
    ) internal view returns (bool valid, bytes memory failureData, CheckoutFillContext memory context) {
        context.seller = _item.seller;
        if (msg.sender == _item.seller || _recipient == _item.seller) {
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
            $,
            _item.contractAddress,
            _item.seller,
            _item.currencyAddress,
            _item.tokenId,
            _item.price,
            _item.quantity
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
        (bool success, bytes memory data) = $.checkoutExecutionModule.delegatecall(
            abi.encodeWithSelector(
                IRareERC1155CheckoutExecutionModule.executeCheckoutPayout.selector,
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

    function _baseCheckoutItemResult(
        uint256 _itemIndex,
        CheckoutItem calldata _item
    ) internal pure returns (CheckoutItemResult memory result) {
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

    function _emitCheckoutItemProcessed(CheckoutItemResult memory _result, address _recipient) internal {
        emit CheckoutItemProcessed(
            _result.itemIndex,
            _result.itemKind,
            _result.contractAddress,
            msg.sender,
            _recipient,
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

    function _checkoutExecutionFailure(
        bytes memory _revertData
    ) internal pure returns (CheckoutFailureStage stage, bytes memory failureData) {
        (
            bool decoded,
            CheckoutFailureStage decodedStage,
            bytes memory decodedFailureData
        ) = _decodeCheckoutItemExecutionFailed(_revertData);
        if (decoded) return (decodedStage, decodedFailureData);
        return (CheckoutFailureStage.UNKNOWN, _revertData);
    }

    function _decodeCheckoutItemExecutionFailed(
        bytes memory _revertData
    ) internal pure returns (bool decoded, CheckoutFailureStage stage, bytes memory failureData) {
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
        if (stageValue > uint256(uint8(CheckoutFailureStage.UNKNOWN)) || failureDataOffset != 64) {
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
            _directSaleMintAggregates,
            _directSaleMintAggregateCount,
            _item.contractAddress,
            _item.tokenId
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
        for (uint256 i = 0; i < _directSaleMintAggregateCount; ) {
            if (
                _directSaleMintAggregates[i].contractAddress == _contractAddress &&
                _directSaleMintAggregates[i].tokenId == _tokenId
            ) {
                return _directSaleMintAggregates[i].quantity;
            }

            unchecked {
                ++i;
            }
        }

        return 0;
    }

    function _recordCheckoutDirectSaleMintTx(
        MarketplaceStorage storage $,
        CheckoutItem calldata _item,
        address _recipient,
        CheckoutDirectSaleMintAggregate[] memory _directSaleMintAggregates,
        uint256 _directSaleMintAggregateCount
    ) internal {
        if (_item.itemKind != uint8(CheckoutItemKind.DIRECT_SALE_MINT)) return;
        if ($.tokenTxLimit[_item.contractAddress][_item.tokenId] == 0) return;
        if (
            _checkoutDirectSaleMintAggregateQuantity(
                _directSaleMintAggregates,
                _directSaleMintAggregateCount,
                _item.contractAddress,
                _item.tokenId
            ) != 0
        ) {
            return;
        }

        $.tokenTxsPerAddress[_item.contractAddress][_item.tokenId][_recipient] += 1;
    }

    function _recordCheckoutDirectSaleMint(
        CheckoutDirectSaleMintAggregate[] memory _directSaleMintAggregates,
        uint256 _directSaleMintAggregateCount,
        CheckoutItem calldata _item
    ) internal pure returns (uint256) {
        if (_item.itemKind != uint8(CheckoutItemKind.DIRECT_SALE_MINT)) {
            return _directSaleMintAggregateCount;
        }

        for (uint256 i = 0; i < _directSaleMintAggregateCount; ) {
            if (
                _directSaleMintAggregates[i].contractAddress == _item.contractAddress &&
                _directSaleMintAggregates[i].tokenId == _item.tokenId
            ) {
                _directSaleMintAggregates[i].quantity += _item.quantity;
                return _directSaleMintAggregateCount;
            }

            unchecked {
                ++i;
            }
        }

        _directSaleMintAggregates[_directSaleMintAggregateCount] = CheckoutDirectSaleMintAggregate({
            contractAddress: _item.contractAddress,
            tokenId: _item.tokenId,
            quantity: _item.quantity
        });
        return _directSaleMintAggregateCount + 1;
    }

    function _checkoutCurrencyApproved(
        MarketConfigV2.Config storage _config,
        address _currencyAddress
    ) internal view returns (bool) {
        if (_currencyAddress == address(0)) return true;

        try _config.approvedTokenRegistry.isApprovedToken(_currencyAddress) returns (bool approved) {
            return approved;
        } catch {
            return false;
        }
    }

    function _checkoutValidErc1155Contract(address _contractAddress) internal view returns (bool) {
        return
            _contractAddress.code.length != 0 &&
            ERC165Checker.supportsInterface(_contractAddress, type(IERC1155).interfaceId);
    }

    function _checkoutPaymentFailureData(
        MarketConfigV2.Config storage _config,
        address _currencyAddress,
        uint256 _amount,
        uint256 _remainingEth
    ) internal view returns (bytes memory failureData) {
        if (_amount == 0) return "";
        if (_currencyAddress == address(0)) {
            if (_remainingEth >= _amount) return "";
            return abi.encodeWithSelector(InsufficientCheckoutETH.selector, _amount, _remainingEth);
        }

        IERC20 erc20 = IERC20(_currencyAddress);
        try erc20.balanceOf(msg.sender) returns (uint256 balance) {
            if (balance < _amount) {
                return abi.encodeWithSelector(InsufficientCheckoutERC20Balance.selector, _currencyAddress, _amount, balance);
            }
        } catch {
            return abi.encodeWithSelector(InsufficientCheckoutERC20Balance.selector, _currencyAddress, _amount, 0);
        }

        try erc20.allowance(msg.sender, address(_config.erc20ApprovalManager)) returns (uint256 allowance) {
            if (allowance < _amount) {
                return
                    abi.encodeWithSelector(InsufficientCheckoutERC20Allowance.selector, _currencyAddress, _amount, allowance);
            }
        } catch {
            return abi.encodeWithSelector(InsufficientCheckoutERC20Allowance.selector, _currencyAddress, _amount, 0);
        }

        return "";
    }

    function _collectCheckoutErc20(
        MarketConfigV2.Config storage _config,
        address _currencyAddress,
        uint256 _amount
    ) internal {
        if (_amount == 0) return;

        IERC20 erc20 = IERC20(_currencyAddress);
        uint256 balanceBefore;
        try erc20.balanceOf(address(this)) returns (uint256 balance) {
            balanceBefore = balance;
        } catch (bytes memory revertData) {
            revert CheckoutItemExecutionFailed(CheckoutFailureStage.PAYMENT_COLLECTION, revertData);
        }

        try _config.erc20ApprovalManager.transferFrom(_currencyAddress, msg.sender, address(this), _amount) {} catch (
            bytes memory revertData
        ) {
            revert CheckoutItemExecutionFailed(CheckoutFailureStage.PAYMENT_COLLECTION, revertData);
        }

        uint256 balanceAfter;
        try erc20.balanceOf(address(this)) returns (uint256 balance) {
            balanceAfter = balance;
        } catch (bytes memory revertData) {
            revert CheckoutItemExecutionFailed(CheckoutFailureStage.PAYMENT_COLLECTION, revertData);
        }

        uint256 receivedAmount = balanceAfter >= balanceBefore ? balanceAfter - balanceBefore : 0;
        if (receivedAmount != _amount) {
            revert CheckoutItemExecutionFailed(
                CheckoutFailureStage.PAYMENT_COLLECTION,
                abi.encodeWithSelector(ERC20FeeOnTransferUnsupported.selector, _currencyAddress, _amount, receivedAmount)
            );
        }
    }

    function _checkoutSafeTransferFrom(
        IERC1155ApprovalManager _erc1155ApprovalManager,
        address _contractAddress,
        address _seller,
        address _buyer,
        uint256 _tokenId,
        uint256 _amount
    ) internal {
        IERC1155 erc1155 = IERC1155(_contractAddress);
        uint256 sellerBalanceBefore;
        try erc1155.balanceOf(_seller, _tokenId) returns (uint256 balance) {
            sellerBalanceBefore = balance;
        } catch (bytes memory revertData) {
            revert CheckoutItemExecutionFailed(CheckoutFailureStage.TRANSFER, revertData);
        }
        if (sellerBalanceBefore < _amount) {
            revert CheckoutItemExecutionFailed(
                CheckoutFailureStage.TRANSFER,
                abi.encodeWithSelector(
                    InsufficientTokenBalance.selector,
                    _seller,
                    _contractAddress,
                    _tokenId,
                    _amount,
                    sellerBalanceBefore
                )
            );
        }

        uint256 buyerBalanceBefore;
        try erc1155.balanceOf(_buyer, _tokenId) returns (uint256 balance) {
            buyerBalanceBefore = balance;
        } catch (bytes memory revertData) {
            revert CheckoutItemExecutionFailed(CheckoutFailureStage.TRANSFER, revertData);
        }

        try _erc1155ApprovalManager.safeTransferFrom(_contractAddress, _seller, _buyer, _tokenId, _amount, "") {} catch (
            bytes memory revertData
        ) {
            revert CheckoutItemExecutionFailed(CheckoutFailureStage.TRANSFER, revertData);
        }

        uint256 sellerBalanceAfter;
        try erc1155.balanceOf(_seller, _tokenId) returns (uint256 balance) {
            sellerBalanceAfter = balance;
        } catch (bytes memory revertData) {
            revert CheckoutItemExecutionFailed(CheckoutFailureStage.TRANSFER, revertData);
        }

        uint256 buyerBalanceAfter;
        try erc1155.balanceOf(_buyer, _tokenId) returns (uint256 balance) {
            buyerBalanceAfter = balance;
        } catch (bytes memory revertData) {
            revert CheckoutItemExecutionFailed(CheckoutFailureStage.TRANSFER, revertData);
        }

        if (sellerBalanceAfter != sellerBalanceBefore - _amount || buyerBalanceAfter != buyerBalanceBefore + _amount) {
            revert CheckoutItemExecutionFailed(
                CheckoutFailureStage.TRANSFER,
                abi.encodeWithSelector(InvalidERC1155Transfer.selector, _contractAddress, _tokenId, _seller, _buyer, _amount)
            );
        }
    }

    function _checkoutMintBatchToWithBalanceCheck(
        address _contractAddress,
        address _buyer,
        uint256[] memory _tokenIds,
        uint256[] memory _amounts
    ) internal {
        IERC1155 erc1155 = IERC1155(_contractAddress);
        address[] memory balanceAccounts = _balanceAccounts(_buyer, _tokenIds.length);
        uint256[] memory balancesBeforeMint;

        try erc1155.balanceOfBatch(balanceAccounts, _tokenIds) returns (uint256[] memory balances) {
            balancesBeforeMint = balances;
        } catch (bytes memory revertData) {
            revert CheckoutItemExecutionFailed(CheckoutFailureStage.MINT, revertData);
        }

        try IRareERC1155(_contractAddress).mintBatchTo(_buyer, _tokenIds, _amounts) {} catch (bytes memory revertData) {
            revert CheckoutItemExecutionFailed(CheckoutFailureStage.MINT, revertData);
        }

        uint256[] memory balancesAfterMint;
        try erc1155.balanceOfBatch(balanceAccounts, _tokenIds) returns (uint256[] memory balances) {
            balancesAfterMint = balances;
        } catch (bytes memory revertData) {
            revert CheckoutItemExecutionFailed(CheckoutFailureStage.MINT, revertData);
        }

        for (uint256 i = 0; i < _tokenIds.length; ) {
            if (balancesAfterMint[i] != balancesBeforeMint[i] + _amounts[i]) {
                revert CheckoutItemExecutionFailed(
                    CheckoutFailureStage.MINT,
                    abi.encodeWithSelector(InvalidERC1155Mint.selector, _contractAddress, _tokenIds[i], _buyer, _amounts[i])
                );
            }

            unchecked {
                ++i;
            }
        }
    }

    function _balanceAccounts(address _account, uint256 _length) internal pure returns (address[] memory accounts) {
        accounts = new address[](_length);
        for (uint256 i = 0; i < _length; ) {
            accounts[i] = _account;

            unchecked {
                ++i;
            }
        }
    }
}
