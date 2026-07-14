// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import {IERC1155} from "openzeppelin-contracts/token/ERC1155/IERC1155.sol";

import {IRareERC1155} from "../token/ERC1155/IRareERC1155.sol";
import {MarketConfigV2} from "../v2/utils/MarketConfigV2.sol";
import {IRareERC1155TradeExecutionModule} from "./IRareERC1155TradeExecutionModule.sol";
import {RareERC1155ExecutionModuleBase} from "./RareERC1155ExecutionModuleBase.sol";
import {RareERC1155MarketplacePayments} from "./RareERC1155MarketplacePayments.sol";

/// @author SuperRare Labs Inc.
/// @title RareERC1155TradeExecutionModule
/// @notice Delegatecall-only direct trade execution module for the ERC1155 marketplace.
/// @dev Direct calls revert because this contract has no standalone marketplace state or escrow. It must run through
/// `RareERC1155Marketplace` so `address(this)`, `msg.sender`, `msg.value`, and storage all resolve to the marketplace proxy.
contract RareERC1155TradeExecutionModule is IRareERC1155TradeExecutionModule, RareERC1155ExecutionModuleBase {
    using RareERC1155MarketplacePayments for MarketConfigV2.Config;

    struct AcceptOfferInput {
        address contractAddress;
        uint256 tokenId;
        address buyer;
        address currencyAddress;
        uint256 price;
        uint256 quantity;
    }

    function mintDirectSaleBatch(
        address _contractAddress,
        address _currencyAddress,
        address _recipient,
        MintRequest[] calldata _requests
    ) external payable onlyDelegateCall {
        _validateRecipient(_recipient);
        _validateMintRequests(_requests);
        MarketplaceStorage storage $ = _marketplaceStorage();
        $.marketConfig.checkIfCurrencyIsApproved(_currencyAddress);
        _validateERC1155Contract(_contractAddress);

        uint256 requestCount = _requests.length;
        uint256[] memory tokenIds = new uint256[](requestCount);
        uint256[] memory amounts = new uint256[](requestCount);
        PrimaryPayoutContext[] memory payoutContexts = new PrimaryPayoutContext[](requestCount);
        uint256 buyerTotal = 0;

        for (uint256 i = 0; i < requestCount; ) {
            payoutContexts[i] = _validateMintDirectSaleRequest(_contractAddress, _currencyAddress, _recipient, _requests[i]);
            if (payoutContexts[i].grossAmount != 0) {
                payoutContexts[i].marketplaceFee = $.marketConfig.marketplaceSettings.calculateMarketplaceFee(
                    payoutContexts[i].grossAmount
                );
                buyerTotal += payoutContexts[i].grossAmount + payoutContexts[i].marketplaceFee;
            }

            tokenIds[i] = payoutContexts[i].tokenId;
            amounts[i] = _requests[i].quantity;

            unchecked {
                ++i;
            }
        }

        $.marketConfig.checkBatchPayment(_currencyAddress, buyerTotal);

        for (uint256 i = 0; i < requestCount; ) {
            uint256 tokenId = _requests[i].tokenId;

            if ($.tokenMintLimit[_contractAddress][tokenId] > 0) {
                $.tokenMintsPerAddress[_contractAddress][tokenId][_recipient] += _requests[i].quantity;
            }

            if ($.tokenTxLimit[_contractAddress][tokenId] > 0) {
                $.tokenTxsPerAddress[_contractAddress][tokenId][_recipient] += 1;
            }

            unchecked {
                ++i;
            }
        }

        _mintBatchToWithBalanceCheck(_contractAddress, _recipient, tokenIds, amounts);

        for (uint256 i = 0; i < requestCount; ) {
            if (payoutContexts[i].grossAmount != 0) {
                $.marketConfig.payoutPrimary(
                    _contractAddress,
                    _currencyAddress,
                    payoutContexts[i].grossAmount,
                    payoutContexts[i].marketplaceFee,
                    payoutContexts[i].splitRecipients,
                    payoutContexts[i].splitRatios
                );
            }

            emit MintDirectSale(
                _contractAddress,
                payoutContexts[i].tokenId,
                msg.sender,
                _recipient,
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
        address _recipient,
        BuyRequest[] calldata _requests
    ) external payable onlyDelegateCall {
        _validateRecipient(_recipient);
        _validateBuyRequests(_requests);
        if (msg.sender == _seller || _recipient == _seller) revert SelfPurchaseUnsupported(_seller);

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

        for (uint256 i = 0; i < requestCount; ) {
            payoutContexts[i] = _validateSecondaryBuyRequest($, _contractAddress, _seller, _currencyAddress, _requests[i]);

            tokenIds[i] = _requests[i].tokenId;
            amounts[i] = _requests[i].quantity;

            uint256 sellerBalance = erc1155.balanceOf(_seller, tokenIds[i]);
            if (sellerBalance < amounts[i]) {
                revert InsufficientTokenBalance(_seller, _contractAddress, tokenIds[i], amounts[i], sellerBalance);
            }

            payoutContexts[i].marketplaceFee = $.marketConfig.marketplaceSettings.calculateMarketplaceFee(
                payoutContexts[i].grossAmount
            );
            buyerTotal += payoutContexts[i].grossAmount + payoutContexts[i].marketplaceFee;

            unchecked {
                ++i;
            }
        }

        $.marketConfig.checkBatchPayment(_currencyAddress, buyerTotal);

        for (uint256 i = 0; i < requestCount; ) {
            SalePrice storage salePrice = $.salePrices[_contractAddress][_requests[i].tokenId][_seller];
            salePrice.quantity -= _requests[i].quantity;
            if (salePrice.quantity == 0) {
                delete $.salePrices[_contractAddress][_requests[i].tokenId][_seller];
            }

            unchecked {
                ++i;
            }
        }

        _safeBatchTransferFrom(_contractAddress, _seller, _recipient, tokenIds, amounts);

        for (uint256 i = 0; i < requestCount; ) {
            $.marketConfig.payoutSecondary(
                _contractAddress,
                payoutContexts[i].tokenId,
                _currencyAddress,
                payoutContexts[i].grossAmount,
                payoutContexts[i].marketplaceFee,
                payoutContexts[i].splitRecipients,
                payoutContexts[i].splitRatios
            );

            emit Sold(
                _seller,
                msg.sender,
                _contractAddress,
                _recipient,
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

        $.marketConfig.payoutSecondary(
            _input.contractAddress,
            _input.tokenId,
            _input.currencyAddress,
            grossAmount,
            marketplaceFee,
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

    function _validateAndApplyOfferFill(
        AcceptOfferInput memory _input
    ) internal returns (uint256 grossAmount, uint256 marketplaceFee) {
        Offer storage offer = _marketplaceStorage().offers[_input.contractAddress][_input.tokenId][_input.buyer][
            _input.currencyAddress
        ];

        if (offer.quantity == 0) {
            revert OfferDoesNotExist(_input.contractAddress, _input.tokenId, _input.buyer, _input.currencyAddress);
        }
        if (offer.expirationTime != 0 && offer.expirationTime <= block.timestamp) {
            revert OfferExpired(
                _input.contractAddress,
                _input.tokenId,
                _input.buyer,
                _input.currencyAddress,
                offer.expirationTime
            );
        }
        if (offer.currencyAddress != _input.currencyAddress) {
            revert CurrencyMismatch(_input.currencyAddress, offer.currencyAddress);
        }
        if (offer.price != _input.price) revert PriceMismatch(_input.price, offer.price);
        if (_input.quantity > offer.quantity) revert QuantityExceedsOfferQuantity(_input.quantity, offer.quantity);

        grossAmount = _input.price * _input.quantity;
        marketplaceFee = _allocateOfferFees(offer, _input.quantity);
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

        _marketplaceStorage().erc1155ApprovalManager.safeTransferFrom(
            _contractAddress,
            _seller,
            _buyer,
            _tokenId,
            _amount,
            ""
        );

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

        for (uint256 i = 0; i < requestCount; ) {
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
        for (uint256 i = 0; i < requestCount; ) {
            uint256 sellerBalanceIndex = i * 2;
            if (balancesBeforeTransfer[sellerBalanceIndex] < _amounts[i]) {
                revert InsufficientTokenBalance(
                    _seller,
                    _contractAddress,
                    _tokenIds[i],
                    _amounts[i],
                    balancesBeforeTransfer[sellerBalanceIndex]
                );
            }

            unchecked {
                ++i;
            }
        }

        _marketplaceStorage().erc1155ApprovalManager.safeBatchTransferFrom(
            _contractAddress,
            _seller,
            _buyer,
            _tokenIds,
            _amounts,
            ""
        );

        uint256[] memory balancesAfterTransfer = erc1155.balanceOfBatch(balanceAccounts, balanceTokenIds);
        for (uint256 i = 0; i < requestCount; ) {
            uint256 balanceIndex = i * 2;
            if (
                balancesAfterTransfer[balanceIndex] != balancesBeforeTransfer[balanceIndex] - _amounts[i] ||
                balancesAfterTransfer[balanceIndex + 1] != balancesBeforeTransfer[balanceIndex + 1] + _amounts[i]
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
        for (uint256 i = 0; i < _length; ) {
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
        for (uint256 i = 0; i < _tokenIds.length; ) {
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
