// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import {IERC1155} from "openzeppelin-contracts/token/ERC1155/IERC1155.sol";
import {OwnableUpgradeable} from "openzeppelin-contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "openzeppelin-contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable} from "openzeppelin-contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {MarketConfigV2} from "../v2/utils/MarketConfigV2.sol";
import {IERC1155ApprovalManager} from "../v2/approver/ERC1155/IERC1155ApprovalManager.sol";
import {IRareERC1155CheckoutExecutionModule} from "./IRareERC1155CheckoutExecutionModule.sol";
import {IRareERC1155Marketplace} from "./IRareERC1155Marketplace.sol";
import {IRareERC1155TradeExecutionModule} from "./IRareERC1155TradeExecutionModule.sol";
import {RareERC1155MarketplacePayments} from "./RareERC1155MarketplacePayments.sol";
import {RareERC1155MarketplaceStorage} from "./RareERC1155MarketplaceStorage.sol";

/// @author SuperRare Labs Inc.
/// @title RareERC1155Marketplace
/// @notice ERC1155 marketplace state, escrow, configuration, and execution module router.
/// @dev The marketplace is the UUPS proxy-facing contract and owns all marketplace storage. Trade and checkout
/// execution are routed through delegatecall so modules read and write the marketplace proxy's ERC-7201 namespace.
contract RareERC1155Marketplace is
    IRareERC1155Marketplace,
    RareERC1155MarketplaceStorage,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    using MarketConfigV2 for MarketConfigV2.Config;
    using RareERC1155MarketplacePayments for MarketConfigV2.Config;

    modifier notPaused() {
        _notPaused();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _networkBeneficiary,
        address _marketplaceSettings,
        address _spaceOperatorRegistry,
        address _royaltyEngine,
        address _payments,
        address _approvedTokenRegistry,
        address _stakingSettings,
        address _stakingRegistry,
        address _erc20ApprovalManager,
        address _erc721ApprovalManager,
        address _erc1155ApprovalManager,
        address _tradeExecutionModule,
        address _checkoutExecutionModule
    ) external initializer {
        _validateMarketConfigAddress(_networkBeneficiary, NETWORK_BENEFICIARY_FIELD);
        _validateMarketConfigAddress(_marketplaceSettings, MARKETPLACE_SETTINGS_FIELD);
        _validateMarketConfigAddress(_spaceOperatorRegistry, SPACE_OPERATOR_REGISTRY_FIELD);
        _validateMarketConfigAddress(_royaltyEngine, ROYALTY_ENGINE_FIELD);
        _validateMarketConfigAddress(_payments, PAYMENTS_FIELD);
        _validateMarketConfigAddress(_approvedTokenRegistry, APPROVED_TOKEN_REGISTRY_FIELD);
        _validateMarketConfigAddress(_stakingSettings, STAKING_SETTINGS_FIELD);
        _validateMarketConfigAddress(_stakingRegistry, STAKING_REGISTRY_FIELD);
        _validateApprovalManager(_erc20ApprovalManager);
        _validateApprovalManager(_erc721ApprovalManager);
        _validateApprovalManager(_erc1155ApprovalManager);
        _validateExecutionModule(_tradeExecutionModule);
        _validateExecutionModule(_checkoutExecutionModule);

        MarketplaceStorage storage $ = _marketplaceStorage();
        $.marketConfig = MarketConfigV2.generateMarketConfig(
            _networkBeneficiary,
            _marketplaceSettings,
            _spaceOperatorRegistry,
            _royaltyEngine,
            _payments,
            _approvedTokenRegistry,
            _stakingSettings,
            _stakingRegistry,
            _erc20ApprovalManager,
            _erc721ApprovalManager
        );
        $.erc1155ApprovalManager = IERC1155ApprovalManager(_erc1155ApprovalManager);
        $.tradeExecutionModule = _tradeExecutionModule;
        $.checkoutExecutionModule = _checkoutExecutionModule;

        __Ownable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
    }

    function _authorizeUpgrade(address _newImplementation) internal view override onlyOwner {
        _newImplementation;
    }

    function prepareMintDirectSales(
        address _contractAddress,
        address _currencyAddress,
        DirectSaleRequest[] calldata _requests,
        address payable[] calldata _splitRecipients,
        uint8[] calldata _splitRatios
    ) external nonReentrant notPaused {
        _validateERC1155Contract(_contractAddress);
        if (!_isContractOwner(_contractAddress, msg.sender)) {
            revert NotContractOwner(_contractAddress, msg.sender);
        }
        _validateDirectSaleRequests(_requests);
        _marketplaceStorage().marketConfig.checkIfCurrencyIsApproved(_currencyAddress);
        RareERC1155MarketplacePayments.checkSplits(_splitRecipients, _splitRatios);

        for (uint256 i = 0; i < _requests.length; i++) {
            uint256 tokenId = _requests[i].tokenId;
            _revertIfTokenNotFound(_contractAddress, tokenId);

            _marketplaceStorage().directSaleConfigs[_contractAddress][tokenId] = DirectSaleConfig({
                seller: msg.sender,
                currencyAddress: _currencyAddress,
                price: _requests[i].price,
                startTime: _requests[i].startTime,
                maxMints: _requests[i].maxMints,
                splitRecipients: _splitRecipients,
                splitRatios: _splitRatios
            });

            emit PrepareMintDirectSale(
                _contractAddress,
                tokenId,
                msg.sender,
                _currencyAddress,
                _requests[i].price,
                _requests[i].startTime,
                _requests[i].maxMints,
                _splitRecipients,
                _splitRatios
            );
        }
    }

    function cancelMintDirectSales(address _contractAddress, uint256[] calldata _tokenIds) external nonReentrant {
        if (!_isContractOwner(_contractAddress, msg.sender)) {
            revert NotContractOwner(_contractAddress, msg.sender);
        }
        _validateTokenIds(_tokenIds);

        MarketplaceStorage storage $ = _marketplaceStorage();
        for (uint256 i = 0; i < _tokenIds.length; i++) {
            uint256 tokenId = _tokenIds[i];
            if ($.directSaleConfigs[_contractAddress][tokenId].seller == address(0)) {
                continue;
            }

            delete $.directSaleConfigs[_contractAddress][tokenId];
            emit MintDirectSaleCancelled(_contractAddress, tokenId);
        }
    }

    function setTokenAllowListConfigs(address _contractAddress, AllowListConfigRequest[] calldata _requests)
        external
        nonReentrant
        notPaused
    {
        if (!_isContractOwner(_contractAddress, msg.sender)) {
            revert NotContractOwner(_contractAddress, msg.sender);
        }
        _validateAllowListConfigRequests(_requests);

        for (uint256 i = 0; i < _requests.length; i++) {
            uint256 tokenId = _requests[i].tokenId;
            bytes32 root = _requests[i].root;
            uint256 endTimestamp = _requests[i].endTimestamp;

            _revertIfTokenNotFound(_contractAddress, tokenId);
            if (root != bytes32(0) && endTimestamp <= block.timestamp) {
                revert AllowListEndTimestampInvalid(endTimestamp, block.timestamp);
            }

            _marketplaceStorage().tokenAllowlistRoots[_contractAddress][tokenId] =
                AllowListConfig({root: root, endTimestamp: endTimestamp});
            emit SetTokenAllowListConfig(_contractAddress, tokenId, root, endTimestamp);
        }
    }

    function setTokenMintLimits(address _contractAddress, TokenLimitRequest[] calldata _requests)
        external
        nonReentrant
        notPaused
    {
        if (!_isContractOwner(_contractAddress, msg.sender)) {
            revert NotContractOwner(_contractAddress, msg.sender);
        }
        _validateTokenLimitRequests(_requests);

        for (uint256 i = 0; i < _requests.length; i++) {
            uint256 tokenId = _requests[i].tokenId;
            _revertIfTokenNotFound(_contractAddress, tokenId);
            _marketplaceStorage().tokenMintLimit[_contractAddress][tokenId] = _requests[i].limit;
            emit TokenMintLimitSet(_contractAddress, tokenId, _requests[i].limit);
        }
    }

    function setTokenTxLimits(address _contractAddress, TokenLimitRequest[] calldata _requests)
        external
        nonReentrant
        notPaused
    {
        if (!_isContractOwner(_contractAddress, msg.sender)) {
            revert NotContractOwner(_contractAddress, msg.sender);
        }
        _validateTokenLimitRequests(_requests);

        for (uint256 i = 0; i < _requests.length; i++) {
            uint256 tokenId = _requests[i].tokenId;
            _revertIfTokenNotFound(_contractAddress, tokenId);
            _marketplaceStorage().tokenTxLimit[_contractAddress][tokenId] = _requests[i].limit;
            emit TokenTxLimitSet(_contractAddress, tokenId, _requests[i].limit);
        }
    }

    function setSalePrices(
        address _contractAddress,
        address _currencyAddress,
        SalePriceRequest[] calldata _requests,
        address payable[] calldata _splitRecipients,
        uint8[] calldata _splitRatios
    ) external nonReentrant notPaused {
        _validateSalePriceRequests(_requests);
        _marketplaceStorage().marketConfig.checkIfCurrencyIsApproved(_currencyAddress);
        RareERC1155MarketplacePayments.checkSplits(_splitRecipients, _splitRatios);
        _validateERC1155Contract(_contractAddress);

        IERC1155 erc1155 = IERC1155(_contractAddress);
        if (!erc1155.isApprovedForAll(msg.sender, address(_marketplaceStorage().erc1155ApprovalManager))) {
            revert MarketplaceNotApproved(msg.sender, _contractAddress);
        }

        for (uint256 i = 0; i < _requests.length; i++) {
            uint256 tokenId = _requests[i].tokenId;
            uint256 price = _requests[i].price;
            uint256 quantity = _requests[i].quantity;
            uint256 expirationTime = _requests[i].expirationTime;

            if (price == 0) revert SalePriceCannotBeZero();
            if (quantity == 0) revert QuantityCannotBeZero();
            if (expirationTime != 0 && expirationTime <= block.timestamp) {
                revert SalePriceExpirationInvalid(expirationTime, block.timestamp);
            }

            uint256 sellerBalance = erc1155.balanceOf(msg.sender, tokenId);
            if (sellerBalance < quantity) {
                revert InsufficientTokenBalance(msg.sender, _contractAddress, tokenId, quantity, sellerBalance);
            }

            _marketplaceStorage().salePrices[_contractAddress][tokenId][msg.sender] = SalePrice({
                currencyAddress: _currencyAddress,
                price: price,
                quantity: quantity,
                expirationTime: expirationTime,
                splitRecipients: _splitRecipients,
                splitRatios: _splitRatios
            });

            emit SalePriceSet(
                msg.sender,
                _contractAddress,
                tokenId,
                _currencyAddress,
                price,
                quantity,
                expirationTime,
                _splitRecipients,
                _splitRatios
            );
        }
    }

    function cancelSalePrices(address _contractAddress, uint256[] calldata _tokenIds) external nonReentrant {
        _validateTokenIds(_tokenIds);

        for (uint256 i = 0; i < _tokenIds.length; i++) {
            uint256 tokenId = _tokenIds[i];
            if (_marketplaceStorage().salePrices[_contractAddress][tokenId][msg.sender].quantity == 0) {
                continue;
            }

            delete _marketplaceStorage().salePrices[_contractAddress][tokenId][msg.sender];
            emit SalePriceCancelled(msg.sender, _contractAddress, tokenId);
        }
    }

    function makeOffer(
        address _contractAddress,
        uint256 _tokenId,
        address _currencyAddress,
        uint256 _price,
        uint256 _quantity,
        uint256 _expirationTime
    ) external payable nonReentrant notPaused {
        _validateERC1155Contract(_contractAddress);
        MarketplaceStorage storage $ = _marketplaceStorage();
        $.marketConfig.checkIfCurrencyIsApproved(_currencyAddress);
        if (_price == 0) revert OfferPriceCannotBeZero();
        if (_quantity == 0) revert QuantityCannotBeZero();
        if (_expirationTime != 0 && _expirationTime <= block.timestamp) {
            revert OfferExpirationInvalid(_expirationTime, block.timestamp);
        }

        uint256 grossAmount = _price * _quantity;
        uint256 marketplaceFee = $.marketConfig.marketplaceSettings.calculateMarketplaceFee(grossAmount);
        uint256 stakingFee = $.marketConfig.stakingSettings.calculateStakingFee(grossAmount);
        if (stakingFee > marketplaceFee) {
            revert StakingFeeExceedsMarketplaceFee(marketplaceFee, stakingFee);
        }
        $.marketConfig.checkAmountAndTransfer(_currencyAddress, grossAmount + marketplaceFee);

        Offer memory previousOffer = $.offers[_contractAddress][_tokenId][msg.sender][_currencyAddress];
        $.offers[_contractAddress][_tokenId][msg.sender][_currencyAddress] = Offer({
            currencyAddress: _currencyAddress,
            price: _price,
            quantity: _quantity,
            initialQuantity: _quantity,
            marketplaceFeeRemaining: marketplaceFee,
            marketplaceFeeTotal: marketplaceFee,
            stakingFeeRemaining: stakingFee,
            stakingFeeTotal: stakingFee,
            expirationTime: _expirationTime
        });

        emit OfferMade(
            msg.sender, _contractAddress, _tokenId, _currencyAddress, _price, _quantity, marketplaceFee, _expirationTime
        );

        $.marketConfig
            .refundRemainingOffer(
                _currencyAddress,
                msg.sender,
                previousOffer.price,
                previousOffer.quantity,
                previousOffer.marketplaceFeeRemaining
            );
    }

    function cancelOffer(address _contractAddress, uint256 _tokenId, address _currencyAddress) external nonReentrant {
        MarketplaceStorage storage $ = _marketplaceStorage();
        Offer memory offer = $.offers[_contractAddress][_tokenId][msg.sender][_currencyAddress];
        if (offer.quantity == 0) return;

        delete $.offers[_contractAddress][_tokenId][msg.sender][_currencyAddress];

        emit OfferCancelled(
            msg.sender,
            _contractAddress,
            _tokenId,
            _currencyAddress,
            offer.price,
            offer.quantity,
            offer.marketplaceFeeRemaining
        );

        $.marketConfig
            .refundRemainingOffer(
                _currencyAddress, msg.sender, offer.price, offer.quantity, offer.marketplaceFeeRemaining
            );
    }

    function mintDirectSaleBatch(address _contractAddress, address _currencyAddress, MintRequest[] calldata _requests)
        external
        payable
        nonReentrant
        notPaused
    {
        _delegateToModule(
            _marketplaceStorage().tradeExecutionModule,
            abi.encodeWithSelector(
                IRareERC1155TradeExecutionModule.mintDirectSaleBatch.selector,
                _contractAddress,
                _currencyAddress,
                _requests
            )
        );
    }

    function buyBatch(
        address _contractAddress,
        address _seller,
        address _currencyAddress,
        BuyRequest[] calldata _requests
    ) external payable nonReentrant notPaused {
        _delegateToModule(
            _marketplaceStorage().tradeExecutionModule,
            abi.encodeWithSelector(
                IRareERC1155TradeExecutionModule.buyBatch.selector,
                _contractAddress,
                _seller,
                _currencyAddress,
                _requests
            )
        );
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
    ) external nonReentrant notPaused {
        _delegateToModule(
            _marketplaceStorage().tradeExecutionModule,
            abi.encodeWithSelector(
                IRareERC1155TradeExecutionModule.acceptOffer.selector,
                _contractAddress,
                _tokenId,
                _buyer,
                _currencyAddress,
                _price,
                _quantity,
                _splitRecipients,
                _splitRatios
            )
        );
    }

    function checkout(CheckoutItem[] calldata _items)
        external
        payable
        nonReentrant
        notPaused
        returns (CheckoutExecution memory)
    {
        return abi.decode(
            _delegateToModule(
                _marketplaceStorage().checkoutExecutionModule,
                abi.encodeWithSelector(IRareERC1155CheckoutExecutionModule.checkout.selector, _items)
            ),
            (CheckoutExecution)
        );
    }

    function getDirectSaleConfig(address _contractAddress, uint256 _tokenId)
        external
        view
        returns (DirectSaleConfig memory)
    {
        return _marketplaceStorage().directSaleConfigs[_contractAddress][_tokenId];
    }

    function getTokenAllowListConfig(address _contractAddress, uint256 _tokenId)
        external
        view
        returns (AllowListConfig memory)
    {
        return _marketplaceStorage().tokenAllowlistRoots[_contractAddress][_tokenId];
    }

    function getTokenMintLimit(address _contractAddress, uint256 _tokenId) external view returns (uint256) {
        return _marketplaceStorage().tokenMintLimit[_contractAddress][_tokenId];
    }

    function getTokenMintsPerAddress(address _contractAddress, uint256 _tokenId, address _account)
        external
        view
        returns (uint256)
    {
        return _marketplaceStorage().tokenMintsPerAddress[_contractAddress][_tokenId][_account];
    }

    function getTokenTxLimit(address _contractAddress, uint256 _tokenId) external view returns (uint256) {
        return _marketplaceStorage().tokenTxLimit[_contractAddress][_tokenId];
    }

    function getTokenTxsPerAddress(address _contractAddress, uint256 _tokenId, address _account)
        external
        view
        returns (uint256)
    {
        return _marketplaceStorage().tokenTxsPerAddress[_contractAddress][_tokenId][_account];
    }

    function getSalePrice(address _contractAddress, uint256 _tokenId, address _seller)
        external
        view
        returns (SalePrice memory)
    {
        return _marketplaceStorage().salePrices[_contractAddress][_tokenId][_seller];
    }

    function getOffer(address _contractAddress, uint256 _tokenId, address _buyer, address _currencyAddress)
        external
        view
        returns (Offer memory)
    {
        return _marketplaceStorage().offers[_contractAddress][_tokenId][_buyer][_currencyAddress];
    }

    function getMarketConfig() external view returns (MarketConfigV2.Config memory) {
        return _marketplaceStorage().marketConfig;
    }

    function getERC1155ApprovalManager() external view returns (address) {
        return address(_marketplaceStorage().erc1155ApprovalManager);
    }

    function getTradeExecutionModule() external view returns (address) {
        return _marketplaceStorage().tradeExecutionModule;
    }

    function getCheckoutExecutionModule() external view returns (address) {
        return _marketplaceStorage().checkoutExecutionModule;
    }

    function isPaused() external view returns (bool) {
        return _marketplaceStorage().paused;
    }

    function setNetworkBeneficiary(address _networkBeneficiary) external onlyOwner {
        _validateMarketConfigAddress(_networkBeneficiary, NETWORK_BENEFICIARY_FIELD);
        _marketplaceStorage().marketConfig.updateNetworkBeneficiary(_networkBeneficiary);
        emit MarketplaceDependencyUpdated(NETWORK_BENEFICIARY_FIELD, _networkBeneficiary);
    }

    function setMarketplaceSettings(address _marketplaceSettings) external onlyOwner {
        _validateMarketConfigAddress(_marketplaceSettings, MARKETPLACE_SETTINGS_FIELD);
        _marketplaceStorage().marketConfig.updateMarketplaceSettings(_marketplaceSettings);
        emit MarketplaceDependencyUpdated(MARKETPLACE_SETTINGS_FIELD, _marketplaceSettings);
    }

    function setSpaceOperatorRegistry(address _spaceOperatorRegistry) external onlyOwner {
        _validateMarketConfigAddress(_spaceOperatorRegistry, SPACE_OPERATOR_REGISTRY_FIELD);
        _marketplaceStorage().marketConfig.updateSpaceOperatorRegistry(_spaceOperatorRegistry);
        emit MarketplaceDependencyUpdated(SPACE_OPERATOR_REGISTRY_FIELD, _spaceOperatorRegistry);
    }

    function setRoyaltyEngine(address _royaltyEngine) external onlyOwner {
        _validateMarketConfigAddress(_royaltyEngine, ROYALTY_ENGINE_FIELD);
        _marketplaceStorage().marketConfig.updateRoyaltyEngine(_royaltyEngine);
        emit MarketplaceDependencyUpdated(ROYALTY_ENGINE_FIELD, _royaltyEngine);
    }

    function setPayments(address _payments) external onlyOwner {
        _validateMarketConfigAddress(_payments, PAYMENTS_FIELD);
        _marketplaceStorage().marketConfig.updatePayments(_payments);
        emit MarketplaceDependencyUpdated(PAYMENTS_FIELD, _payments);
    }

    function setApprovedTokenRegistry(address _approvedTokenRegistry) external onlyOwner {
        _validateMarketConfigAddress(_approvedTokenRegistry, APPROVED_TOKEN_REGISTRY_FIELD);
        _marketplaceStorage().marketConfig.updateApprovedTokenRegistry(_approvedTokenRegistry);
        emit MarketplaceDependencyUpdated(APPROVED_TOKEN_REGISTRY_FIELD, _approvedTokenRegistry);
    }

    function setStakingSettings(address _stakingSettings) external onlyOwner {
        _validateMarketConfigAddress(_stakingSettings, STAKING_SETTINGS_FIELD);
        _marketplaceStorage().marketConfig.updateStakingSettings(_stakingSettings);
        emit MarketplaceDependencyUpdated(STAKING_SETTINGS_FIELD, _stakingSettings);
    }

    function setStakingRegistry(address _stakingRegistry) external onlyOwner {
        _validateMarketConfigAddress(_stakingRegistry, STAKING_REGISTRY_FIELD);
        _marketplaceStorage().marketConfig.updateStakingRegistry(_stakingRegistry);
        emit MarketplaceDependencyUpdated(STAKING_REGISTRY_FIELD, _stakingRegistry);
    }

    function setERC20ApprovalManager(address _erc20ApprovalManager) external onlyOwner {
        _validateApprovalManager(_erc20ApprovalManager);
        _marketplaceStorage().marketConfig.updateERC20ApprovalManager(_erc20ApprovalManager);
        emit MarketplaceDependencyUpdated(ERC20_APPROVAL_MANAGER_FIELD, _erc20ApprovalManager);
    }

    function setERC721ApprovalManager(address _erc721ApprovalManager) external onlyOwner {
        _validateApprovalManager(_erc721ApprovalManager);
        _marketplaceStorage().marketConfig.updateERC721ApprovalManager(_erc721ApprovalManager);
        emit MarketplaceDependencyUpdated(ERC721_APPROVAL_MANAGER_FIELD, _erc721ApprovalManager);
    }

    function setERC1155ApprovalManager(address _erc1155ApprovalManager) external onlyOwner {
        _validateApprovalManager(_erc1155ApprovalManager);
        _marketplaceStorage().erc1155ApprovalManager = IERC1155ApprovalManager(_erc1155ApprovalManager);
        emit MarketplaceDependencyUpdated(ERC1155_APPROVAL_MANAGER_FIELD, _erc1155ApprovalManager);
    }

    function setTradeExecutionModule(address _tradeExecutionModule) external onlyOwner {
        _validateExecutionModule(_tradeExecutionModule);
        _marketplaceStorage().tradeExecutionModule = _tradeExecutionModule;
        emit MarketplaceDependencyUpdated(TRADE_EXECUTION_MODULE_FIELD, _tradeExecutionModule);
    }

    function setCheckoutExecutionModule(address _checkoutExecutionModule) external onlyOwner {
        _validateExecutionModule(_checkoutExecutionModule);
        _marketplaceStorage().checkoutExecutionModule = _checkoutExecutionModule;
        emit MarketplaceDependencyUpdated(CHECKOUT_EXECUTION_MODULE_FIELD, _checkoutExecutionModule);
    }

    function setContractPaused(bool _isPaused) external onlyOwner {
        _marketplaceStorage().paused = _isPaused;
        emit ContractPausedUpdated(_isPaused);
    }

    function _delegateToModule(address _module, bytes memory _callData) private returns (bytes memory) {
        (bool success, bytes memory data) = _module.delegatecall(_callData);
        if (!success) {
            if (data.length == 0) revert ExecutionModuleDelegateCallFailed(data);
            assembly {
                revert(add(data, 32), mload(data))
            }
        }
        return data;
    }

    function _notPaused() internal view {
        if (_marketplaceStorage().paused) revert ContractPaused();
    }

    function _validateDirectSaleRequests(DirectSaleRequest[] calldata _requests) internal pure {
        _validateBatchSize(_requests.length);
        for (uint256 i = 1; i < _requests.length; i++) {
            _validateStrictAscending(i, _requests[i - 1].tokenId, _requests[i].tokenId);
        }
    }

    function _validateAllowListConfigRequests(AllowListConfigRequest[] calldata _requests) internal pure {
        _validateBatchSize(_requests.length);
        for (uint256 i = 1; i < _requests.length; i++) {
            _validateStrictAscending(i, _requests[i - 1].tokenId, _requests[i].tokenId);
        }
    }

    function _validateTokenLimitRequests(TokenLimitRequest[] calldata _requests) internal pure {
        _validateBatchSize(_requests.length);
        for (uint256 i = 1; i < _requests.length; i++) {
            _validateStrictAscending(i, _requests[i - 1].tokenId, _requests[i].tokenId);
        }
    }

    function _validateSalePriceRequests(SalePriceRequest[] calldata _requests) internal pure {
        _validateBatchSize(_requests.length);
        for (uint256 i = 1; i < _requests.length; i++) {
            _validateStrictAscending(i, _requests[i - 1].tokenId, _requests[i].tokenId);
        }
    }
}
