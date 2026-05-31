// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import {IERC1155} from "openzeppelin-contracts/token/ERC1155/IERC1155.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {ERC165Checker} from "openzeppelin-contracts/utils/introspection/ERC165Checker.sol";

import {IRareERC1155} from "../token/ERC1155/IRareERC1155.sol";
import {MarketConfigV2} from "../v2/utils/MarketConfigV2.sol";
import {IRareERC1155Settlement} from "./IRareERC1155Settlement.sol";
import {RareERC1155MarketplacePayments} from "./RareERC1155MarketplacePayments.sol";
import {RareERC1155MarketplaceStorage} from "./RareERC1155MarketplaceStorage.sol";

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
        address payable[] splitRecipients;
        uint8[] splitRatios;
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

        IRareERC1155(_contractAddress).mintBatchTo(msg.sender, tokenIds, amounts);

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
            payoutContexts[i] = _validateSecondaryBuyRequest(_contractAddress, _seller, _currencyAddress, _requests[i]);

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
        returns (CheckoutSummary memory summary)
    {
        _validateBatchSize(_items.length);

        uint256 remainingEth = msg.value;
        for (uint256 i = 0; i < _items.length;) {
            (bool filled, bytes4 reason, uint256 totalPaid, uint256 newRemainingEth) =
                _checkoutItem(i, _items[i], remainingEth);

            if (filled) {
                remainingEth = newRemainingEth;
                summary.filledCount += 1;
                if (_items[i].currencyAddress == address(0)) {
                    summary.ethSpent += totalPaid;
                }
            } else {
                summary.skippedCount += 1;
                emit CheckoutItemSkipped(i, _items[i].itemKind, _items[i].contractAddress, _items[i].tokenId, reason);
            }

            unchecked {
                ++i;
            }
        }

        if (summary.filledCount == 0) revert CheckoutRequiresSuccessfulFill();

        summary.ethRefunded = remainingEth;
        if (remainingEth != 0) {
            _marketplaceStorage().marketConfig.refund(address(0), payable(msg.sender), remainingEth);
        }

        emit CheckoutCompleted(
            msg.sender, summary.filledCount, summary.skippedCount, summary.ethSpent, summary.ethRefunded
        );
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

    function _checkoutItem(uint256 _itemIndex, CheckoutItem calldata _item, uint256 _remainingEth)
        internal
        returns (bool filled, bytes4 reason, uint256 totalPaid, uint256 newRemainingEth)
    {
        if (_item.itemKind == uint8(CheckoutItemKind.DIRECT_SALE_MINT)) {
            return _checkoutDirectSaleMint(_itemIndex, _item, _remainingEth);
        }
        if (_item.itemKind == uint8(CheckoutItemKind.LISTING_BUY)) {
            return _checkoutListingBuy(_itemIndex, _item, _remainingEth);
        }

        return (false, UnsupportedCheckoutItemKind.selector, 0, _remainingEth);
    }

    function _checkoutDirectSaleMint(uint256 _itemIndex, CheckoutItem calldata _item, uint256 _remainingEth)
        internal
        returns (bool filled, bytes4 reason, uint256 totalPaid, uint256 newRemainingEth)
    {
        newRemainingEth = _remainingEth;
        MarketplaceStorage storage $ = _marketplaceStorage();

        if (!_checkoutCurrencyApproved($.marketConfig, _item.currencyAddress)) {
            return (false, CurrencyNotApproved.selector, 0, _remainingEth);
        }

        (bool valid, bytes4 skipReason, CheckoutFillContext memory context) = _validateCheckoutDirectSaleMint($, _item);
        if (!valid) {
            return (false, skipReason, 0, _remainingEth);
        }

        totalPaid = context.grossAmount + context.marketplaceFee;
        reason = _validateCheckoutPayment($.marketConfig, _item.currencyAddress, totalPaid, _remainingEth);
        if (reason != bytes4(0)) {
            return (false, reason, 0, _remainingEth);
        }

        if (_item.currencyAddress == address(0)) {
            newRemainingEth = _remainingEth - totalPaid;
        } else {
            _collectCheckoutErc20($.marketConfig, _item.currencyAddress, totalPaid);
        }

        if ($.tokenMintLimit[_item.contractAddress][_item.tokenId] > 0) {
            $.tokenMintsPerAddress[_item.contractAddress][_item.tokenId][msg.sender] += _item.quantity;
        }
        if ($.tokenTxLimit[_item.contractAddress][_item.tokenId] > 0) {
            $.tokenTxsPerAddress[_item.contractAddress][_item.tokenId][msg.sender] += 1;
        }

        IRareERC1155(_item.contractAddress)
            .mintBatchTo(msg.sender, _singleUintArray(_item.tokenId), _singleUintArray(_item.quantity));

        if (context.grossAmount != 0) {
            $.marketConfig
                .payoutPrimary(
                    _item.contractAddress,
                    _item.currencyAddress,
                    context.grossAmount,
                    context.marketplaceFee,
                    context.seller,
                    context.splitRecipients,
                    context.splitRatios
                );
        }

        emit MintDirectSale(
            _item.contractAddress,
            _item.tokenId,
            msg.sender,
            context.seller,
            _item.quantity,
            _item.currencyAddress,
            _item.price
        );
        emit CheckoutItemFilled(
            _itemIndex,
            _item.itemKind,
            _item.contractAddress,
            _item.tokenId,
            context.seller,
            _item.currencyAddress,
            _item.price,
            _item.quantity,
            totalPaid
        );

        return (true, bytes4(0), totalPaid, newRemainingEth);
    }

    function _checkoutListingBuy(uint256 _itemIndex, CheckoutItem calldata _item, uint256 _remainingEth)
        internal
        returns (bool filled, bytes4 reason, uint256 totalPaid, uint256 newRemainingEth)
    {
        newRemainingEth = _remainingEth;
        MarketplaceStorage storage $ = _marketplaceStorage();

        if (!_checkoutCurrencyApproved($.marketConfig, _item.currencyAddress)) {
            return (false, CurrencyNotApproved.selector, 0, _remainingEth);
        }

        (bool valid, bytes4 skipReason, CheckoutFillContext memory context) = _validateCheckoutListingBuy($, _item);
        if (!valid) {
            return (false, skipReason, 0, _remainingEth);
        }

        totalPaid = context.grossAmount + context.marketplaceFee;
        reason = _validateCheckoutPayment($.marketConfig, _item.currencyAddress, totalPaid, _remainingEth);
        if (reason != bytes4(0)) {
            return (false, reason, 0, _remainingEth);
        }

        if (_item.currencyAddress == address(0)) {
            newRemainingEth = _remainingEth - totalPaid;
        } else {
            _collectCheckoutErc20($.marketConfig, _item.currencyAddress, totalPaid);
        }

        SalePrice storage salePrice = $.salePrices[_item.contractAddress][_item.tokenId][_item.seller];
        salePrice.quantity -= _item.quantity;
        if (salePrice.quantity == 0) {
            delete $.salePrices[_item.contractAddress][_item.tokenId][_item.seller];
        }

        _safeTransferFrom(_item.contractAddress, _item.seller, msg.sender, _item.tokenId, _item.quantity);

        $.marketConfig
            .payoutSecondary(
                _item.contractAddress,
                _item.tokenId,
                _item.currencyAddress,
                context.grossAmount,
                context.marketplaceFee,
                _item.seller,
                context.splitRecipients,
                context.splitRatios
            );

        emit Sold(
            _item.seller,
            msg.sender,
            _item.contractAddress,
            _item.tokenId,
            _item.currencyAddress,
            _item.price,
            _item.quantity
        );
        emit CheckoutItemFilled(
            _itemIndex,
            _item.itemKind,
            _item.contractAddress,
            _item.tokenId,
            _item.seller,
            _item.currencyAddress,
            _item.price,
            _item.quantity,
            totalPaid
        );

        return (true, bytes4(0), totalPaid, newRemainingEth);
    }

    function _validateCheckoutDirectSaleMint(MarketplaceStorage storage $, CheckoutItem calldata _item)
        internal
        view
        returns (bool valid, bytes4 reason, CheckoutFillContext memory context)
    {
        DirectSaleConfig memory directSaleConfig = $.directSaleConfigs[_item.contractAddress][_item.tokenId];
        if (directSaleConfig.seller == address(0)) return (false, DirectSaleNotConfigured.selector, context);
        if (_item.seller != directSaleConfig.seller) return (false, CheckoutSellerMismatch.selector, context);
        if (!_checkoutIsContractOwner(_item.contractAddress, directSaleConfig.seller)) {
            return (false, NotContractOwner.selector, context);
        }
        if (!_checkoutAllowlisted(_item.contractAddress, _item.tokenId, msg.sender, _item.proof)) {
            return (false, AddressNotAllowlisted.selector, context);
        }
        if (_item.quantity == 0) return (false, QuantityCannotBeZero.selector, context);

        uint256 mintLimit = $.tokenMintLimit[_item.contractAddress][_item.tokenId];
        uint256 currentMints = $.tokenMintsPerAddress[_item.contractAddress][_item.tokenId][msg.sender];
        if (mintLimit != 0 && currentMints + _item.quantity > mintLimit) {
            return (false, MintLimitExceeded.selector, context);
        }

        uint256 txLimit = $.tokenTxLimit[_item.contractAddress][_item.tokenId];
        uint256 currentTxs = $.tokenTxsPerAddress[_item.contractAddress][_item.tokenId][msg.sender];
        if (txLimit != 0 && currentTxs + 1 > txLimit) {
            return (false, TransactionLimitExceeded.selector, context);
        }

        if (directSaleConfig.maxMints != 0 && _item.quantity > directSaleConfig.maxMints) {
            return (false, MaxMintExceeded.selector, context);
        }
        if (directSaleConfig.startTime > block.timestamp) return (false, SaleNotStarted.selector, context);
        if (_item.price != directSaleConfig.price) return (false, PriceMismatch.selector, context);
        if (directSaleConfig.currencyAddress != _item.currencyAddress) {
            return (false, CurrencyMismatch.selector, context);
        }

        context = CheckoutFillContext({
            seller: directSaleConfig.seller,
            grossAmount: _item.quantity * _item.price,
            marketplaceFee: 0,
            splitRecipients: directSaleConfig.splitRecipients,
            splitRatios: directSaleConfig.splitRatios
        });
        if (context.grossAmount != 0) {
            context.marketplaceFee = $.marketConfig.marketplaceSettings.calculateMarketplaceFee(context.grossAmount);
        }

        return (true, bytes4(0), context);
    }

    function _validateCheckoutListingBuy(MarketplaceStorage storage $, CheckoutItem calldata _item)
        internal
        view
        returns (bool valid, bytes4 reason, CheckoutFillContext memory context)
    {
        if (msg.sender == _item.seller) return (false, SelfPurchaseUnsupported.selector, context);
        if (!_checkoutValidErc1155Contract(_item.contractAddress)) {
            return (false, InvalidERC1155Contract.selector, context);
        }
        if (_item.quantity == 0) return (false, QuantityCannotBeZero.selector, context);

        SalePrice storage salePrice = $.salePrices[_item.contractAddress][_item.tokenId][_item.seller];
        if (salePrice.quantity == 0) return (false, SalePriceDoesNotExist.selector, context);
        if (salePrice.expirationTime != 0 && salePrice.expirationTime <= block.timestamp) {
            return (false, SalePriceExpired.selector, context);
        }
        if (salePrice.currencyAddress != _item.currencyAddress) return (false, CurrencyMismatch.selector, context);
        if (salePrice.price != _item.price) return (false, PriceMismatch.selector, context);
        if (salePrice.quantity < _item.quantity) return (false, QuantityExceedsSalePriceQuantity.selector, context);

        IERC1155 erc1155 = IERC1155(_item.contractAddress);
        try erc1155.isApprovedForAll(_item.seller, address($.erc1155ApprovalManager)) returns (bool isApproved) {
            if (!isApproved) return (false, MarketplaceNotApproved.selector, context);
        } catch {
            return (false, MarketplaceNotApproved.selector, context);
        }

        try erc1155.balanceOf(_item.seller, _item.tokenId) returns (uint256 sellerBalance) {
            if (sellerBalance < _item.quantity) return (false, InsufficientTokenBalance.selector, context);
        } catch {
            return (false, InsufficientTokenBalance.selector, context);
        }

        context = CheckoutFillContext({
            seller: _item.seller,
            grossAmount: _item.quantity * _item.price,
            marketplaceFee: $.marketConfig.marketplaceSettings.calculateMarketplaceFee(_item.quantity * _item.price),
            splitRecipients: salePrice.splitRecipients,
            splitRatios: salePrice.splitRatios
        });

        return (true, bytes4(0), context);
    }

    function _validateCheckoutPayment(
        MarketConfigV2.Config storage _config,
        address _currencyAddress,
        uint256 _amount,
        uint256 _remainingEth
    ) internal view returns (bytes4 reason) {
        if (_amount == 0) return bytes4(0);
        if (_currencyAddress == address(0)) {
            return _remainingEth >= _amount ? bytes4(0) : InsufficientCheckoutETH.selector;
        }

        IERC20 erc20 = IERC20(_currencyAddress);
        try erc20.balanceOf(msg.sender) returns (uint256 balance) {
            if (balance < _amount) return InsufficientCheckoutERC20Balance.selector;
        } catch {
            return InsufficientCheckoutERC20Balance.selector;
        }

        try erc20.allowance(msg.sender, address(_config.erc20ApprovalManager)) returns (uint256 allowance) {
            if (allowance < _amount) return InsufficientCheckoutERC20Allowance.selector;
        } catch {
            return InsufficientCheckoutERC20Allowance.selector;
        }

        return bytes4(0);
    }

    function _collectCheckoutErc20(MarketConfigV2.Config storage _config, address _currencyAddress, uint256 _amount)
        internal
    {
        if (_amount == 0) return;

        IERC20 erc20 = IERC20(_currencyAddress);
        uint256 balanceBefore = erc20.balanceOf(address(this));

        _config.erc20ApprovalManager.transferFrom(_currencyAddress, msg.sender, address(this), _amount);

        uint256 receivedAmount = erc20.balanceOf(address(this)) - balanceBefore;
        if (receivedAmount != _amount) {
            revert ERC20FeeOnTransferUnsupported(_currencyAddress, _amount, receivedAmount);
        }
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

    function _checkoutIsContractOwner(address _contractAddress, address _account) internal view returns (bool) {
        (bool success, bytes memory data) = _contractAddress.staticcall(abi.encodeWithSignature("owner()"));
        return success && data.length >= 32 && abi.decode(data, (address)) == _account;
    }

    function _checkoutAllowlisted(
        address _contractAddress,
        uint256 _tokenId,
        address _account,
        bytes32[] calldata _proof
    ) internal view returns (bool) {
        AllowListConfig memory allowListConfig = _marketplaceStorage().tokenAllowlistRoots[_contractAddress][_tokenId];
        if (allowListConfig.root == bytes32(0) || block.timestamp >= allowListConfig.endTimestamp) return true;
        return _verifyProof(keccak256(abi.encodePacked(_account)), allowListConfig.root, _proof);
    }

    function _singleUintArray(uint256 _value) internal pure returns (uint256[] memory values) {
        values = new uint256[](1);
        values[0] = _value;
    }

    function _validateMintDirectSaleRequest(
        address _contractAddress,
        address _currencyAddress,
        address _buyer,
        MintRequest calldata _request
    ) internal view returns (PrimaryPayoutContext memory payoutContext) {
        MarketplaceStorage storage $ = _marketplaceStorage();
        uint256 tokenId = _request.tokenId;
        uint256 quantity = _request.quantity;
        DirectSaleConfig memory directSaleConfig = $.directSaleConfigs[_contractAddress][tokenId];

        if (directSaleConfig.seller == address(0)) revert DirectSaleNotConfigured(_contractAddress, tokenId);
        if (!_isContractOwner(_contractAddress, directSaleConfig.seller)) {
            revert NotContractOwner(_contractAddress, directSaleConfig.seller);
        }
        _enforceTokenAllowList(_contractAddress, tokenId, _buyer, _request.proof);
        if (quantity == 0) revert QuantityCannotBeZero();

        uint256 mintLimit = $.tokenMintLimit[_contractAddress][tokenId];
        uint256 currentMints = $.tokenMintsPerAddress[_contractAddress][tokenId][_buyer];
        if (mintLimit != 0 && currentMints + quantity > mintLimit) {
            revert MintLimitExceeded(_contractAddress, tokenId, _buyer, quantity, currentMints, mintLimit);
        }

        uint256 txLimit = $.tokenTxLimit[_contractAddress][tokenId];
        uint256 currentTxs = $.tokenTxsPerAddress[_contractAddress][tokenId][_buyer];
        if (txLimit != 0 && currentTxs + 1 > txLimit) {
            revert TransactionLimitExceeded(_contractAddress, tokenId, _buyer, currentTxs, txLimit);
        }

        if (directSaleConfig.maxMints != 0 && quantity > directSaleConfig.maxMints) {
            revert MaxMintExceeded(quantity, directSaleConfig.maxMints);
        }
        if (directSaleConfig.startTime > block.timestamp) revert SaleNotStarted(directSaleConfig.startTime);
        if (_request.price != directSaleConfig.price) revert PriceMismatch(_request.price, directSaleConfig.price);
        if (directSaleConfig.currencyAddress != _currencyAddress) {
            revert CurrencyMismatch(_currencyAddress, directSaleConfig.currencyAddress);
        }

        payoutContext = PrimaryPayoutContext({
            tokenId: tokenId,
            grossAmount: quantity * _request.price,
            marketplaceFee: 0,
            seller: directSaleConfig.seller,
            splitRecipients: directSaleConfig.splitRecipients,
            splitRatios: directSaleConfig.splitRatios
        });
    }

    function _validateSecondaryBuyRequest(
        address _contractAddress,
        address _seller,
        address _currencyAddress,
        BuyRequest calldata _request
    ) internal view returns (SecondaryPayoutContext memory payoutContext) {
        uint256 tokenId = _request.tokenId;
        uint256 quantity = _request.quantity;
        if (quantity == 0) revert QuantityCannotBeZero();

        SalePrice storage salePrice = _marketplaceStorage().salePrices[_contractAddress][tokenId][_seller];
        if (salePrice.quantity == 0) revert SalePriceDoesNotExist(_contractAddress, tokenId, _seller);
        if (salePrice.expirationTime != 0 && salePrice.expirationTime <= block.timestamp) {
            revert SalePriceExpired(_contractAddress, tokenId, _seller, salePrice.expirationTime);
        }
        if (salePrice.currencyAddress != _currencyAddress) {
            revert CurrencyMismatch(_currencyAddress, salePrice.currencyAddress);
        }
        if (salePrice.price != _request.price) revert PriceMismatch(_request.price, salePrice.price);
        if (salePrice.quantity < quantity) revert QuantityExceedsSalePriceQuantity(quantity, salePrice.quantity);

        payoutContext = SecondaryPayoutContext({
            tokenId: tokenId,
            grossAmount: quantity * _request.price,
            marketplaceFee: 0,
            splitRecipients: salePrice.splitRecipients,
            splitRatios: salePrice.splitRatios
        });
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
            delete _offer.marketplaceFeeRemaining;
            delete _offer.expirationTime;
            return marketplaceFee;
        }

        marketplaceFee = (_offer.marketplaceFeeRemaining * _quantity) / remainingQuantity;
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

    function _enforceTokenAllowList(
        address _contractAddress,
        uint256 _tokenId,
        address _address,
        bytes32[] calldata _proof
    ) internal view {
        AllowListConfig memory allowListConfig = _marketplaceStorage().tokenAllowlistRoots[_contractAddress][_tokenId];
        if (allowListConfig.root == bytes32(0) || block.timestamp >= allowListConfig.endTimestamp) return;

        if (!_verifyProof(keccak256(abi.encodePacked(_address)), allowListConfig.root, _proof)) {
            revert AddressNotAllowlisted(_address);
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
