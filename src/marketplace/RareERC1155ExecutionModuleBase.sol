// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import {Math} from "openzeppelin-contracts/utils/math/Math.sol";

import {RareERC1155MarketplaceStorage} from "./RareERC1155MarketplaceStorage.sol";

/// @author SuperRare Labs Inc.
/// @title RareERC1155ExecutionModuleBase
/// @notice Shared validation helpers for delegatecall-only ERC1155 marketplace execution modules.
/// @dev Storage invariant: execution modules must remain storage-less except for immutables. Any persistent state added
/// to a module would be written into the marketplace proxy during delegatecall; add persistent fields to the ERC-7201
/// `MarketplaceStorage` namespace instead.
abstract contract RareERC1155ExecutionModuleBase is RareERC1155MarketplaceStorage {
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

    modifier onlyDelegateCall() {
        _onlyDelegateCall();
        _;
    }

    function _onlyDelegateCall() internal view {
        if (address(this) == SELF) revert DirectModuleCallUnsupported();
    }

    function _mintFailureData(
        bytes4 _reason,
        MarketplaceStorage storage $,
        address _contractAddress,
        address _currencyAddress,
        address _recipient,
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
            return abi.encodeWithSelector(AddressNotAllowlisted.selector, _recipient);
        }
        if (_reason == QuantityCannotBeZero.selector) return abi.encodeWithSelector(QuantityCannotBeZero.selector);
        if (_reason == MintLimitExceeded.selector) {
            uint256 mintLimit = $.tokenMintLimit[_contractAddress][_tokenId];
            uint256 currentMints = $.tokenMintsPerAddress[_contractAddress][_tokenId][_recipient];
            return
                abi.encodeWithSelector(
                    MintLimitExceeded.selector,
                    _contractAddress,
                    _tokenId,
                    _recipient,
                    _quantity,
                    currentMints,
                    mintLimit
                );
        }
        if (_reason == TransactionLimitExceeded.selector) {
            uint256 txLimit = $.tokenTxLimit[_contractAddress][_tokenId];
            uint256 currentTxs = $.tokenTxsPerAddress[_contractAddress][_tokenId][_recipient];
            return
                abi.encodeWithSelector(
                    TransactionLimitExceeded.selector,
                    _contractAddress,
                    _tokenId,
                    _recipient,
                    currentTxs,
                    txLimit
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
            return
                abi.encodeWithSelector(
                    SalePriceExpired.selector,
                    _contractAddress,
                    _tokenId,
                    _seller,
                    salePrice.expirationTime
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

    function _checkContractOwner(
        address _contractAddress,
        address _account
    ) internal view returns (bool readable, bool isOwner) {
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
            ContractHasNoOwner.selector,
            false
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
            $,
            _contractAddress,
            _seller,
            _currencyAddress,
            _request.tokenId,
            _request.price,
            _request.quantity
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
        bytes4 _ownerLookupFailureReason,
        bool _skipTxLimitCheck
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

        if (!_skipTxLimitCheck) {
            uint256 txLimit = $.tokenTxLimit[_contractAddress][_tokenId];
            uint256 currentTxs = $.tokenTxsPerAddress[_contractAddress][_tokenId][_buyer];
            if (txLimit != 0 && currentTxs + 1 > txLimit) {
                return (false, TransactionLimitExceeded.selector, payoutContext);
            }
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

    function _allocateOfferFees(Offer storage _offer, uint256 _quantity) internal returns (uint256 marketplaceFee) {
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
}
