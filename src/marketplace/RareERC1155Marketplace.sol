// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {IERC1155} from "openzeppelin-contracts/token/ERC1155/IERC1155.sol";
import {ERC165Checker} from "openzeppelin-contracts/utils/introspection/ERC165Checker.sol";
import {OwnableUpgradeable} from "openzeppelin-contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "openzeppelin-contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardUpgradeable} from "openzeppelin-contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable} from "openzeppelin-contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";

import {MarketConfigV2} from "../v2/utils/MarketConfigV2.sol";
import {IRareERC1155} from "../token/ERC1155/IRareERC1155.sol";
import {IRareERC1155Marketplace} from "./IRareERC1155Marketplace.sol";
import {IERC1155ApprovalManager} from "../v2/approver/ERC1155/IERC1155ApprovalManager.sol";

/// @author SuperRare Labs Inc.
/// @title RareERC1155Marketplace
/// @notice Primary mint sales for RARE Protocol ERC1155 tokens and fixed-price resale listings for ERC1155 tokens.
/// @dev UUPS-upgradeable marketplace that keeps ERC1155 sale semantics separate from ERC721 marketplace logic.
contract RareERC1155Marketplace is
    Initializable,
    IRareERC1155Marketplace,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;
    using MarketConfigV2 for MarketConfigV2.Config;

    /// @notice RARE Protocol marketplace dependency bundle.
    MarketConfigV2.Config private marketConfig;

    /// @notice ERC1155 transfer manager approved by sellers and callable by this marketplace.
    IERC1155ApprovalManager private erc1155ApprovalManager;

    /// @notice Market config field label for zero-address validation.
    bytes32 private constant NETWORK_BENEFICIARY_FIELD = "NETWORK_BENEFICIARY";

    /// @notice Market config field label for zero-address validation.
    bytes32 private constant MARKETPLACE_SETTINGS_FIELD = "MARKETPLACE_SETTINGS";

    /// @notice Market config field label for zero-address validation.
    bytes32 private constant SPACE_OPERATOR_REGISTRY_FIELD = "SPACE_OPERATOR_REGISTRY";

    /// @notice Market config field label for zero-address validation.
    bytes32 private constant ROYALTY_ENGINE_FIELD = "ROYALTY_ENGINE";

    /// @notice Market config field label for zero-address validation.
    bytes32 private constant PAYMENTS_FIELD = "PAYMENTS";

    /// @notice Market config field label for zero-address validation.
    bytes32 private constant APPROVED_TOKEN_REGISTRY_FIELD = "APPROVED_TOKEN_REGISTRY";

    /// @notice Market config field label for zero-address validation.
    bytes32 private constant STAKING_SETTINGS_FIELD = "STAKING_SETTINGS";

    /// @notice Market config field label for zero-address validation.
    bytes32 private constant STAKING_REGISTRY_FIELD = "STAKING_REGISTRY";

    /// @notice Market config field label for ERC20 approval manager updates.
    bytes32 private constant ERC20_APPROVAL_MANAGER_FIELD = "ERC20_APPROVAL_MANAGER";

    /// @notice Market config field label for ERC721 approval manager updates.
    bytes32 private constant ERC721_APPROVAL_MANAGER_FIELD = "ERC721_APPROVAL_MANAGER";

    /// @notice Config field label for ERC1155 approval manager updates.
    bytes32 private constant ERC1155_APPROVAL_MANAGER_FIELD = "ERC1155_APPROVAL_MANAGER";

    /// @notice Primary mint sale configuration by collection and token id.
    mapping(address => mapping(uint256 => IRareERC1155Marketplace.DirectSaleConfig)) private directSaleConfigs;

    /// @notice Allowlist configuration by collection and token id.
    mapping(address => mapping(uint256 => IRareERC1155Marketplace.AllowListConfig)) private tokenAllowlistRoots;

    /// @notice Per-address mint quantity limit by collection and token id.
    mapping(address => mapping(uint256 => uint256)) private tokenMintLimit;

    /// @notice Quantity minted per buyer by collection and token id.
    mapping(address => mapping(uint256 => mapping(address => uint256))) private tokenMintsPerAddress;

    /// @notice Per-address mint transaction limit by collection and token id.
    mapping(address => mapping(uint256 => uint256)) private tokenTxLimit;

    /// @notice Mint transaction count per buyer by collection and token id.
    mapping(address => mapping(uint256 => mapping(address => uint256))) private tokenTxsPerAddress;

    /// @notice Secondary fixed-price listings by collection, token id, and seller.
    /// @dev Listings intentionally do not carry expiry timestamps or seller-wide nonces.
    /// Sellers cancel standing offers explicitly, and buys revalidate balance, approval, currency, price, and quantity.
    mapping(address => mapping(uint256 => mapping(address => IRareERC1155Marketplace.SalePrice))) private salePrices;

    /// @notice Whether marketplace value-moving and listing-creation operations are paused.
    bool private paused;

    /// @notice Ensures marketplace actions that create listings or move value are not paused.
    modifier notPaused() {
        // Atomic guard: pause state blocks marketplace writes before any mutation or transfer.
        if (paused) revert ContractPaused();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the UUPS marketplace implementation behind a proxy.
    /// @dev Stores the market config dependency bundle and initializes inherited upgradeability modules.
    /// @param _networkBeneficiary Address receiving network marketplace fees.
    /// @param _marketplaceSettings Marketplace settings contract.
    /// @param _spaceOperatorRegistry Space operator registry contract.
    /// @param _royaltyEngine Royalty engine contract.
    /// @param _payments Payments contract used for ETH fan-out.
    /// @param _approvedTokenRegistry Registry of approved ERC20 currencies.
    /// @param _stakingSettings Staking fee settings contract.
    /// @param _stakingRegistry Staking registry contract.
    /// @param _erc20ApprovalManager ERC20 transfer manager for buyer currency approvals.
    /// @param _erc721ApprovalManager ERC721 transfer manager kept in shared V2 market config.
    /// @param _erc1155ApprovalManager ERC1155 transfer manager for seller token approvals.
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
        address _erc1155ApprovalManager
    ) external initializer {
        // Atomic guards: required config dependencies must be concrete before they are stored.
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

        // State write: persist all marketplace dependency addresses in the shared config struct.
        marketConfig = MarketConfigV2.generateMarketConfig(
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
        erc1155ApprovalManager = IERC1155ApprovalManager(_erc1155ApprovalManager);

        // Initializer calls: set up ownership, reentrancy guard, and UUPS storage for the proxy.
        __Ownable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
    }

    /// @notice Authorizes UUPS implementation upgrades.
    /// @dev Restricted to the marketplace owner by `onlyOwner`.
    /// @param _newImplementation New implementation address requested by the proxy upgrade flow.
    function _authorizeUpgrade(address _newImplementation) internal view override onlyOwner {
        // Authorization hook: the presence of onlyOwner is the atomic upgrade permission check.
        _newImplementation;
    }

    /// @inheritdoc IRareERC1155Marketplace
    function prepareMintDirectSale(
        address _contractAddress,
        uint256 _tokenId,
        address _currencyAddress,
        uint256 _price,
        uint256 _startTime,
        uint256 _maxMints,
        address payable[] calldata _splitRecipients,
        uint8[] calldata _splitRatios
    ) external notPaused {
        // Atomic ownership check: only the collection owner can configure primary mint sales.
        if (!_isContractOwner(_contractAddress, msg.sender)) {
            revert NotContractOwner(_contractAddress, msg.sender);
        }

        // Atomic config checks: sale currency and seller split configuration must be valid before storage writes.
        _checkIfCurrencyIsApproved(_currencyAddress);
        _checkSplits(_splitRecipients, _splitRatios);

        _revertIfTokenNotFound(_contractAddress, _tokenId);

        // State write: replace the primary sale config for this collection and token id.
        directSaleConfigs[_contractAddress][_tokenId] = IRareERC1155Marketplace.DirectSaleConfig(
            msg.sender, _currencyAddress, _price, _startTime, _maxMints, _splitRecipients, _splitRatios
        );

        emit PrepareMintDirectSale(
            _contractAddress,
            _tokenId,
            msg.sender,
            _currencyAddress,
            _price,
            _startTime,
            _maxMints,
            _splitRecipients,
            _splitRatios
        );
    }

    /// @inheritdoc IRareERC1155Marketplace
    function mintDirectSale(
        address _contractAddress,
        uint256 _tokenId,
        address _currencyAddress,
        uint256 _price,
        uint256 _quantity,
        bytes32[] calldata _proof
    ) external payable nonReentrant notPaused {
        // Storage read: copy primary sale config for consistent validation and payout inputs.
        IRareERC1155Marketplace.DirectSaleConfig memory directSaleConfig = directSaleConfigs[_contractAddress][_tokenId];

        // Atomic guards: ensure sale existence, current seller ownership, allowlist membership, and non-zero quantity.
        if (directSaleConfig.seller == address(0)) revert DirectSaleNotConfigured(_contractAddress, _tokenId);
        if (!_isContractOwner(_contractAddress, directSaleConfig.seller)) {
            revert NotContractOwner(_contractAddress, directSaleConfig.seller);
        }
        _enforceTokenAllowList(_contractAddress, _tokenId, msg.sender, _proof);

        if (_quantity == 0) revert QuantityCannotBeZero();

        // Atomic mint-limit check: validate requested quantity against buyer's enabled-period mint count.
        uint256 mintLimit = tokenMintLimit[_contractAddress][_tokenId];
        uint256 currentMints = tokenMintsPerAddress[_contractAddress][_tokenId][msg.sender];
        if (mintLimit != 0 && currentMints + _quantity > mintLimit) {
            revert MintLimitExceeded(_contractAddress, _tokenId, msg.sender, _quantity, currentMints, mintLimit);
        }

        // Atomic tx-limit check: validate this transaction against buyer's enabled-period transaction count.
        uint256 txLimit = tokenTxLimit[_contractAddress][_tokenId];
        uint256 currentTxs = tokenTxsPerAddress[_contractAddress][_tokenId][msg.sender];
        if (txLimit != 0 && currentTxs + 1 > txLimit) {
            revert TransactionLimitExceeded(_contractAddress, _tokenId, msg.sender, currentTxs, txLimit);
        }

        // Atomic sale-parameter checks: buyer-supplied price and currency must match the stored config.
        if (directSaleConfig.maxMints != 0 && _quantity > directSaleConfig.maxMints) {
            revert MaxMintExceeded(_quantity, directSaleConfig.maxMints);
        }
        if (directSaleConfig.startTime > block.timestamp) revert SaleNotStarted(directSaleConfig.startTime);
        if (_price != directSaleConfig.price) revert PriceMismatch(_price, directSaleConfig.price);
        _checkIfCurrencyIsApproved(_currencyAddress);
        if (directSaleConfig.currencyAddress != _currencyAddress) {
            revert CurrencyMismatch(_currencyAddress, directSaleConfig.currencyAddress);
        }

        // Price calculation: unit price multiplied by ERC1155 quantity before fee calculation.
        uint256 totalPrice = _quantity * _price;

        if (directSaleConfig.price == 0) {
            // Atomic free-mint guard: free mints must not leave ETH stuck in the marketplace.
            if (msg.value != 0) revert MsgValueMustBeZero();
        } else {
            // Payment pull: collect sale amount plus marketplace fee before minting.
            _checkAmountAndTransfer(
                _currencyAddress, totalPrice + marketConfig.marketplaceSettings.calculateMarketplaceFee(totalPrice)
            );
        }

        if (tokenMintLimit[_contractAddress][_tokenId] > 0) {
            // State write: record quantity minted while this token's mint limit is enabled.
            tokenMintsPerAddress[_contractAddress][_tokenId][msg.sender] += _quantity;
        }

        if (tokenTxLimit[_contractAddress][_tokenId] > 0) {
            // State write: record this mint transaction while this token's tx limit is enabled.
            tokenTxsPerAddress[_contractAddress][_tokenId][msg.sender] += 1;
        }

        // External mint: collection must have approved this marketplace as minter.
        IRareERC1155(_contractAddress).mintTo(msg.sender, _tokenId, _quantity);

        if (directSaleConfig.price != 0) {
            // Payout fan-out: distribute collected primary sale funds after successful mint.
            _payoutPrimary(
                _contractAddress,
                _currencyAddress,
                totalPrice,
                directSaleConfig.seller,
                directSaleConfig.splitRecipients,
                directSaleConfig.splitRatios
            );
        }

        emit MintDirectSale(
            _contractAddress, _tokenId, msg.sender, directSaleConfig.seller, _quantity, _currencyAddress, _price
        );
    }

    /// @inheritdoc IRareERC1155Marketplace
    function setTokenAllowListConfig(bytes32 _root, uint256 _endTimestamp, address _contractAddress, uint256 _tokenId)
        external
    {
        // Atomic ownership check: only the collection owner can change token allowlist settings.
        if (!_isContractOwner(_contractAddress, msg.sender)) revert NotContractOwner(_contractAddress, msg.sender);
        _revertIfTokenNotFound(_contractAddress, _tokenId);

        // State write: replace allowlist root and expiry for the token id.
        tokenAllowlistRoots[_contractAddress][_tokenId] = IRareERC1155Marketplace.AllowListConfig(_root, _endTimestamp);
        emit SetTokenAllowListConfig(_contractAddress, _tokenId, _root, _endTimestamp);
    }

    /// @inheritdoc IRareERC1155Marketplace
    function setTokenMintLimit(address _contractAddress, uint256 _tokenId, uint256 _limit) external {
        // Atomic ownership check: only the collection owner can change mint limits.
        if (!_isContractOwner(_contractAddress, msg.sender)) revert NotContractOwner(_contractAddress, msg.sender);
        _revertIfTokenNotFound(_contractAddress, _tokenId);

        // State write: replace per-address quantity limit for the token id.
        tokenMintLimit[_contractAddress][_tokenId] = _limit;
        emit TokenMintLimitSet(_contractAddress, _tokenId, _limit);
    }

    /// @inheritdoc IRareERC1155Marketplace
    function setTokenTxLimit(address _contractAddress, uint256 _tokenId, uint256 _limit) external {
        // Atomic ownership check: only the collection owner can change transaction limits.
        if (!_isContractOwner(_contractAddress, msg.sender)) revert NotContractOwner(_contractAddress, msg.sender);
        _revertIfTokenNotFound(_contractAddress, _tokenId);

        // State write: replace per-address transaction limit for the token id.
        tokenTxLimit[_contractAddress][_tokenId] = _limit;
        emit TokenTxLimitSet(_contractAddress, _tokenId, _limit);
    }

    /// @inheritdoc IRareERC1155Marketplace
    function setSalePrice(
        address _contractAddress,
        uint256 _tokenId,
        address _currencyAddress,
        uint256 _price,
        uint256 _quantity,
        address payable[] calldata _splitRecipients,
        uint8[] calldata _splitRatios
    ) external notPaused {
        // Atomic config checks: listing currency, split recipients, price, and quantity must be valid.
        _checkIfCurrencyIsApproved(_currencyAddress);
        _checkSplits(_splitRecipients, _splitRatios);
        _validateERC1155Contract(_contractAddress);
        if (_price == 0) revert SalePriceCannotBeZero();
        if (_quantity == 0) revert QuantityCannotBeZero();

        // External reads: verify seller balance and transfer approval at list time.
        IERC1155 erc1155 = IERC1155(_contractAddress);
        uint256 sellerBalance = erc1155.balanceOf(msg.sender, _tokenId);
        if (sellerBalance < _quantity) {
            revert InsufficientTokenBalance(msg.sender, _contractAddress, _tokenId, _quantity, sellerBalance);
        }
        if (!erc1155.isApprovedForAll(msg.sender, address(erc1155ApprovalManager))) {
            revert MarketplaceNotApproved(msg.sender, _contractAddress);
        }

        // State write: create or replace seller's approval-based fixed-price listing.
        salePrices[_contractAddress][_tokenId][msg.sender] =
            IRareERC1155Marketplace.SalePrice(_currencyAddress, _price, _quantity, _splitRecipients, _splitRatios);

        emit SalePriceSet(
            msg.sender, _contractAddress, _tokenId, _currencyAddress, _price, _quantity, _splitRecipients, _splitRatios
        );
    }

    /// @inheritdoc IRareERC1155Marketplace
    function cancelSalePrice(address _contractAddress, uint256 _tokenId) external {
        if (salePrices[_contractAddress][_tokenId][msg.sender].quantity == 0) {
            return;
        }

        // State delete: remove caller's active listing for this collection and token id.
        delete salePrices[_contractAddress][_tokenId][msg.sender];

        emit SalePriceCancelled(msg.sender, _contractAddress, _tokenId);
    }

    /// @inheritdoc IRareERC1155Marketplace
    function buy(
        address _contractAddress,
        uint256 _tokenId,
        address _seller,
        address _currencyAddress,
        uint256 _price,
        uint256 _quantity
    ) external payable nonReentrant notPaused {
        // Atomic guard: secondary fills must buy at least one token.
        if (_quantity == 0) revert QuantityCannotBeZero();
        if (msg.sender == _seller) revert SelfPurchaseUnsupported(_seller);

        // Atomic currency check: rejected currencies cannot be used even for stale listings.
        _checkIfCurrencyIsApproved(_currencyAddress);
        _validateERC1155Contract(_contractAddress);

        // Storage pointer: mutate seller listing quantity only after all buy-time checks pass.
        IRareERC1155Marketplace.SalePrice storage salePrice = salePrices[_contractAddress][_tokenId][_seller];

        // Atomic listing checks: listing must exist and match buyer-supplied terms.
        if (salePrice.quantity == 0) revert SalePriceDoesNotExist(_contractAddress, _tokenId, _seller);
        if (salePrice.currencyAddress != _currencyAddress) {
            revert CurrencyMismatch(_currencyAddress, salePrice.currencyAddress);
        }
        if (salePrice.price != _price) revert PriceMismatch(_price, salePrice.price);
        if (salePrice.quantity < _quantity) revert QuantityExceedsSalePriceQuantity(_quantity, salePrice.quantity);

        // External reads: recheck seller balance and approval at buy time because listings are not escrowed.
        IERC1155 erc1155 = IERC1155(_contractAddress);
        uint256 sellerBalance = erc1155.balanceOf(_seller, _tokenId);
        if (sellerBalance < _quantity) {
            revert InsufficientTokenBalance(_seller, _contractAddress, _tokenId, _quantity, sellerBalance);
        }
        if (!erc1155.isApprovedForAll(_seller, address(erc1155ApprovalManager))) {
            revert MarketplaceNotApproved(_seller, _contractAddress);
        }

        // Payment pull: collect sale amount plus marketplace fee before moving the ERC1155.
        uint256 totalPrice = _quantity * _price;
        _checkAmountAndTransfer(
            _currencyAddress, totalPrice + marketConfig.marketplaceSettings.calculateMarketplaceFee(totalPrice)
        );

        // State write: decrement listed quantity before the external ERC1155 transfer.
        salePrice.quantity -= _quantity;

        // Memory copies: preserve split data before possibly deleting the listing.
        address payable[] memory splitRecipients = salePrice.splitRecipients;
        uint8[] memory splitRatios = salePrice.splitRatios;
        if (salePrice.quantity == 0) {
            // State delete: clear listing storage once the final listed quantity is sold.
            delete salePrices[_contractAddress][_tokenId][_seller];
        }

        // Balance snapshots: used to reject non-standard ERC1155 transfers that do not move the exact quantity.
        uint256 sellerBalanceBeforeTransfer = erc1155.balanceOf(_seller, _tokenId);
        uint256 buyerBalanceBeforeTransfer = erc1155.balanceOf(msg.sender, _tokenId);
        if (sellerBalanceBeforeTransfer < _quantity) {
            revert InsufficientTokenBalance(_seller, _contractAddress, _tokenId, _quantity, sellerBalanceBeforeTransfer);
        }

        // External transfer: move ERC1155 tokens through the approved transfer manager.
        erc1155ApprovalManager.safeTransferFrom(_contractAddress, _seller, msg.sender, _tokenId, _quantity, "");

        if (
            erc1155.balanceOf(_seller, _tokenId) != sellerBalanceBeforeTransfer - _quantity
                || erc1155.balanceOf(msg.sender, _tokenId) != buyerBalanceBeforeTransfer + _quantity
        ) {
            revert InvalidERC1155Transfer(_contractAddress, _tokenId, _seller, msg.sender, _quantity);
        }

        // Payout fan-out: distribute collected secondary sale funds after token transfer.
        _payoutSecondary(
            _contractAddress, _tokenId, _currencyAddress, totalPrice, _seller, splitRecipients, splitRatios
        );

        emit Sold(_seller, msg.sender, _contractAddress, _tokenId, _currencyAddress, _price, _quantity);
    }

    /// @notice Returns the primary mint sale config for a token id.
    /// @param _contractAddress ERC1155 collection address.
    /// @param _tokenId Token id to inspect.
    /// @return Primary sale config for the token id.
    function getDirectSaleConfig(address _contractAddress, uint256 _tokenId)
        external
        view
        returns (IRareERC1155Marketplace.DirectSaleConfig memory)
    {
        return directSaleConfigs[_contractAddress][_tokenId];
    }

    /// @notice Returns the allowlist config for a token id.
    /// @param _contractAddress ERC1155 collection address.
    /// @param _tokenId Token id to inspect.
    /// @return Allowlist config for the token id.
    function getTokenAllowListConfig(address _contractAddress, uint256 _tokenId)
        external
        view
        returns (IRareERC1155Marketplace.AllowListConfig memory)
    {
        return tokenAllowlistRoots[_contractAddress][_tokenId];
    }

    /// @notice Returns the per-address mint quantity limit for a token id.
    /// @param _contractAddress ERC1155 collection address.
    /// @param _tokenId Token id to inspect.
    /// @return Mint quantity limit. Zero means unlimited.
    function getTokenMintLimit(address _contractAddress, uint256 _tokenId) external view returns (uint256) {
        return tokenMintLimit[_contractAddress][_tokenId];
    }

    /// @notice Returns quantity minted by an address for a token id.
    /// @param _contractAddress ERC1155 collection address.
    /// @param _tokenId Token id to inspect.
    /// @param _address Address whose minted quantity is returned.
    /// @return Quantity minted by `_address`.
    function getTokenMintsPerAddress(address _contractAddress, uint256 _tokenId, address _address)
        external
        view
        returns (uint256)
    {
        return tokenMintsPerAddress[_contractAddress][_tokenId][_address];
    }

    /// @notice Returns the per-address transaction limit for a token id.
    /// @param _contractAddress ERC1155 collection address.
    /// @param _tokenId Token id to inspect.
    /// @return Transaction limit. Zero means unlimited.
    function getTokenTxLimit(address _contractAddress, uint256 _tokenId) external view returns (uint256) {
        return tokenTxLimit[_contractAddress][_tokenId];
    }

    /// @notice Returns mint transactions used by an address for a token id.
    /// @param _contractAddress ERC1155 collection address.
    /// @param _tokenId Token id to inspect.
    /// @param _address Address whose transaction count is returned.
    /// @return Number of mint transactions used by `_address`.
    function getTokenTxsPerAddress(address _contractAddress, uint256 _tokenId, address _address)
        external
        view
        returns (uint256)
    {
        return tokenTxsPerAddress[_contractAddress][_tokenId][_address];
    }

    /// @notice Returns a seller's secondary fixed-price listing.
    /// @param _contractAddress ERC1155 collection address.
    /// @param _tokenId Token id to inspect.
    /// @param _seller Seller whose listing is returned.
    /// @return Secondary fixed-price listing for the seller and token id.
    function getSalePrice(address _contractAddress, uint256 _tokenId, address _seller)
        external
        view
        returns (IRareERC1155Marketplace.SalePrice memory)
    {
        return salePrices[_contractAddress][_tokenId][_seller];
    }

    /// @notice Returns the marketplace dependency configuration.
    /// @return Current market config struct.
    function getMarketConfig() external view returns (MarketConfigV2.Config memory) {
        return marketConfig;
    }

    /// @notice Returns the ERC1155 approval manager used for secondary transfers.
    /// @return Current ERC1155 approval manager address.
    function getERC1155ApprovalManager() external view returns (address) {
        return address(erc1155ApprovalManager);
    }

    /// @notice Returns whether marketplace writes are paused.
    /// @return True when paused.
    function isPaused() external view returns (bool) {
        return paused;
    }

    /// @notice Updates the network beneficiary address.
    /// @param _networkBeneficiary New network beneficiary.
    function setNetworkBeneficiary(address _networkBeneficiary) external onlyOwner {
        // Atomic guard: network beneficiary must remain payable by marketplace fee flows.
        _validateMarketConfigAddress(_networkBeneficiary, NETWORK_BENEFICIARY_FIELD);

        // State write: delegate config mutation to the shared MarketConfig library.
        marketConfig.updateNetworkBeneficiary(_networkBeneficiary);

        emit MarketplaceDependencyUpdated(NETWORK_BENEFICIARY_FIELD, _networkBeneficiary);
    }

    /// @notice Updates the marketplace settings contract address.
    /// @param _marketplaceSettings New marketplace settings contract.
    function setMarketplaceSettings(address _marketplaceSettings) external onlyOwner {
        // Atomic guard: marketplace fee calculations must retain a concrete settings contract.
        _validateMarketConfigAddress(_marketplaceSettings, MARKETPLACE_SETTINGS_FIELD);

        // State write: delegate config mutation to the shared MarketConfig library.
        marketConfig.updateMarketplaceSettings(_marketplaceSettings);

        emit MarketplaceDependencyUpdated(MARKETPLACE_SETTINGS_FIELD, _marketplaceSettings);
    }

    /// @notice Updates the space operator registry address.
    /// @param _spaceOperatorRegistry New space operator registry contract.
    function setSpaceOperatorRegistry(address _spaceOperatorRegistry) external onlyOwner {
        // Atomic guard: primary platform-fee resolution must retain a concrete registry.
        _validateMarketConfigAddress(_spaceOperatorRegistry, SPACE_OPERATOR_REGISTRY_FIELD);

        // State write: delegate config mutation to the shared MarketConfig library.
        marketConfig.updateSpaceOperatorRegistry(_spaceOperatorRegistry);

        emit MarketplaceDependencyUpdated(SPACE_OPERATOR_REGISTRY_FIELD, _spaceOperatorRegistry);
    }

    /// @notice Updates the royalty engine address.
    /// @param _royaltyEngine New royalty engine contract.
    function setRoyaltyEngine(address _royaltyEngine) external onlyOwner {
        // Atomic guard: secondary royalty resolution must retain a concrete engine.
        _validateMarketConfigAddress(_royaltyEngine, ROYALTY_ENGINE_FIELD);

        // State write: delegate config mutation to the shared MarketConfig library.
        marketConfig.updateRoyaltyEngine(_royaltyEngine);

        emit MarketplaceDependencyUpdated(ROYALTY_ENGINE_FIELD, _royaltyEngine);
    }

    /// @notice Updates the Payments contract address used for ETH fan-out.
    /// @param _payments New payments contract.
    function setPayments(address _payments) external onlyOwner {
        // Atomic guard: ETH payout fan-out must retain a concrete Payments contract.
        _validateMarketConfigAddress(_payments, PAYMENTS_FIELD);

        // State write: delegate config mutation to the shared MarketConfig library.
        marketConfig.updatePayments(_payments);

        emit MarketplaceDependencyUpdated(PAYMENTS_FIELD, _payments);
    }

    /// @notice Updates the approved token registry address.
    /// @param _approvedTokenRegistry New approved token registry contract.
    function setApprovedTokenRegistry(address _approvedTokenRegistry) external onlyOwner {
        // Atomic guard: currency approval checks must retain a concrete registry.
        _validateMarketConfigAddress(_approvedTokenRegistry, APPROVED_TOKEN_REGISTRY_FIELD);

        // State write: delegate config mutation to the shared MarketConfig library.
        marketConfig.updateApprovedTokenRegistry(_approvedTokenRegistry);

        emit MarketplaceDependencyUpdated(APPROVED_TOKEN_REGISTRY_FIELD, _approvedTokenRegistry);
    }

    /// @notice Updates the staking settings address.
    /// @param _stakingSettings New staking settings contract.
    function setStakingSettings(address _stakingSettings) external onlyOwner {
        // Atomic guard: marketplace fee split math must retain concrete settings.
        _validateMarketConfigAddress(_stakingSettings, STAKING_SETTINGS_FIELD);

        // State write: delegate config mutation to the shared MarketConfig library.
        marketConfig.updateStakingSettings(_stakingSettings);

        emit MarketplaceDependencyUpdated(STAKING_SETTINGS_FIELD, _stakingSettings);
    }

    /// @notice Updates the staking registry address.
    /// @param _stakingRegistry New staking registry contract.
    function setStakingRegistry(address _stakingRegistry) external onlyOwner {
        // Atomic guard: marketplace fee split recipients must retain a concrete registry.
        _validateMarketConfigAddress(_stakingRegistry, STAKING_REGISTRY_FIELD);

        // State write: delegate config mutation to the shared MarketConfig library.
        marketConfig.updateStakingRegistry(_stakingRegistry);

        emit MarketplaceDependencyUpdated(STAKING_REGISTRY_FIELD, _stakingRegistry);
    }

    /// @notice Updates the ERC20 approval manager address.
    /// @param _erc20ApprovalManager New ERC20 approval manager contract.
    function setERC20ApprovalManager(address _erc20ApprovalManager) external onlyOwner {
        // Atomic guard: ERC20 purchases must retain a concrete transfer manager.
        _validateApprovalManager(_erc20ApprovalManager);

        // State write: delegate config mutation to the shared MarketConfig library.
        marketConfig.updateERC20ApprovalManager(_erc20ApprovalManager);

        emit MarketplaceDependencyUpdated(ERC20_APPROVAL_MANAGER_FIELD, _erc20ApprovalManager);
    }

    /// @notice Updates the ERC721 approval manager address retained by the shared V2 market config.
    /// @param _erc721ApprovalManager New ERC721 approval manager contract.
    function setERC721ApprovalManager(address _erc721ApprovalManager) external onlyOwner {
        // Atomic guard: shared V2 config must retain a concrete ERC721 approval manager.
        _validateApprovalManager(_erc721ApprovalManager);

        // State write: delegate config mutation to the shared MarketConfig library.
        marketConfig.updateERC721ApprovalManager(_erc721ApprovalManager);

        emit MarketplaceDependencyUpdated(ERC721_APPROVAL_MANAGER_FIELD, _erc721ApprovalManager);
    }

    /// @notice Updates the ERC1155 approval manager address.
    /// @param _erc1155ApprovalManager New ERC1155 approval manager contract.
    function setERC1155ApprovalManager(address _erc1155ApprovalManager) external onlyOwner {
        // Atomic guard: secondary ERC1155 transfers must retain a concrete approval manager.
        _validateApprovalManager(_erc1155ApprovalManager);

        // State write: replace the manager used for seller approval checks and transfers.
        erc1155ApprovalManager = IERC1155ApprovalManager(_erc1155ApprovalManager);

        emit MarketplaceDependencyUpdated(ERC1155_APPROVAL_MANAGER_FIELD, _erc1155ApprovalManager);
    }

    /// @notice Pauses or unpauses marketplace write operations.
    /// @param _isPaused New pause state.
    function setContractPaused(bool _isPaused) external onlyOwner {
        // State write: set pause flag consumed by the notPaused modifier.
        paused = _isPaused;

        emit ContractPausedUpdated(_isPaused);
    }

    /// @notice Distributes proceeds for a primary mint sale.
    /// @dev Marketplace fee is paid on top by the buyer; platform fee is deducted from seller proceeds.
    /// @param _contractAddress ERC1155 collection address.
    /// @param _currencyAddress Currency being paid. Zero address indicates ETH.
    /// @param _amount Gross sale amount before platform fee.
    /// @param _seller Primary sale seller.
    /// @param _splitRecipients Seller proceed recipients.
    /// @param _splitRatios Seller proceed split ratios.
    function _payoutPrimary(
        address _contractAddress,
        address _currencyAddress,
        uint256 _amount,
        address _seller,
        address payable[] memory _splitRecipients,
        uint8[] memory _splitRatios
    ) internal {
        // Accounting state: track seller proceeds remaining after primary platform commission.
        uint256 remainingAmount = _amount;

        // Payout operation: distribute the buyer-paid marketplace fee through the configured fee split.
        _payoutMarketplaceFee(_currencyAddress, _amount, _seller);

        // External reads: choose primary commission from approved space operator or marketplace settings.
        uint256 platformCommission = marketConfig.spaceOperatorRegistry.isApprovedSpaceOperator(_seller)
            ? marketConfig.spaceOperatorRegistry.getPlatformCommission(_seller)
            : marketConfig.marketplaceSettings.getERC721ContractPrimarySaleFeePercentage(_contractAddress);
        if (platformCommission > 100) {
            revert PlatformCommissionExceeded(platformCommission, 100);
        }

        // Accounting operation: convert commission percentage to an amount.
        uint256 platformFee = (_amount * platformCommission) / 100;
        if (platformFee > 0) {
            // Accounting state: remove platform fee from seller proceeds before split payout.
            remainingAmount -= platformFee;

            // Memory setup: represent single-recipient platform fee as a payout batch.
            address payable[] memory platformRecipients = new address payable[](1);
            platformRecipients[0] = payable(marketConfig.networkBeneficiary);
            uint256[] memory platformAmounts = new uint256[](1);
            platformAmounts[0] = platformFee;

            // Payout operation: send primary platform fee to the network beneficiary.
            _performPayouts(_currencyAddress, platformFee, platformRecipients, platformAmounts);
        }

        // Payout operation: split remaining seller proceeds across configured recipients.
        _payoutSplits(_currencyAddress, remainingAmount, _splitRecipients, _splitRatios);
    }

    /// @notice Distributes proceeds for a secondary fixed-price sale.
    /// @dev Marketplace fee is paid on top by the buyer; royalties are deducted from seller proceeds.
    /// @param _contractAddress ERC1155 collection address.
    /// @param _tokenId Sold token id.
    /// @param _currencyAddress Currency being paid. Zero address indicates ETH.
    /// @param _amount Gross sale amount before royalty deduction.
    /// @param _seller Secondary seller.
    /// @param _splitRecipients Seller proceed recipients.
    /// @param _splitRatios Seller proceed split ratios.
    function _payoutSecondary(
        address _contractAddress,
        uint256 _tokenId,
        address _currencyAddress,
        uint256 _amount,
        address _seller,
        address payable[] memory _splitRecipients,
        uint8[] memory _splitRatios
    ) internal {
        // Accounting state: track seller proceeds remaining after royalties.
        uint256 remainingAmount = _amount;

        // Payout operation: distribute the buyer-paid marketplace fee through the configured fee split.
        _payoutMarketplaceFee(_currencyAddress, _amount, _seller);

        // External read: resolve royalties through the configured royalty engine.
        (address payable[] memory receivers, uint256[] memory royalties) =
            marketConfig.royaltyEngine.getRoyalty(_contractAddress, _tokenId, _amount);

        // Accounting operation: aggregate royalty amounts before paying them.
        uint256 totalRoyalties = 0;
        for (uint256 i = 0; i < royalties.length; i++) {
            totalRoyalties += royalties[i];
        }

        // Atomic guard: royalties cannot consume more than gross sale amount.
        if (totalRoyalties > remainingAmount) revert RoyaltiesExceedSaleAmount(totalRoyalties, remainingAmount);

        if (totalRoyalties > 0) {
            // Accounting state: remove royalty amount from seller proceeds before split payout.
            remainingAmount -= totalRoyalties;

            // Payout operation: send royalties to royalty engine recipients.
            _performPayouts(_currencyAddress, totalRoyalties, receivers, royalties);
        }

        // Payout operation: split remaining seller proceeds across configured recipients.
        _payoutSplits(_currencyAddress, remainingAmount, _splitRecipients, _splitRatios);
    }

    /// @notice Distributes marketplace fee between network beneficiary and seller staking rewards.
    /// @param _currencyAddress Currency being paid. Zero address indicates ETH.
    /// @param _amount Gross sale amount used for fee calculation.
    /// @param _seller Seller whose staking reward accumulator may receive staking fees.
    function _payoutMarketplaceFee(address _currencyAddress, uint256 _amount, address _seller) internal {
        // External read: calculate buyer-paid marketplace fee for the sale amount.
        uint256 marketplaceFee = marketConfig.marketplaceSettings.calculateMarketplaceFee(_amount);

        // External read: calculate staking fee from staking settings and send the collected remainder to network.
        uint256 stakingFee = marketConfig.stakingSettings.calculateStakingFee(_amount);
        if (stakingFee > marketplaceFee) {
            revert StakingFeeExceedsMarketplaceFee(marketplaceFee, stakingFee);
        }

        if (marketplaceFee == 0) {
            return;
        }

        // Memory setup: recipient 0 is network, recipient 1 is seller staking reward accumulator or network fallback.
        address payable[] memory recipients = new address payable[](2);
        recipients[0] = payable(marketConfig.networkBeneficiary);
        recipients[1] = payable(marketConfig.stakingRegistry.getRewardAccumulatorAddressForUser(_seller));
        recipients[1] = recipients[1] == address(0) ? payable(marketConfig.networkBeneficiary) : recipients[1];

        // Memory setup: distribute the buyer-paid marketplace fee between network and staking recipients.
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = marketplaceFee - stakingFee;
        amounts[1] = stakingFee;

        // Payout operation: distribute the marketplace fee batch.
        _performPayouts(_currencyAddress, marketplaceFee, recipients, amounts);
    }

    /// @notice Validates that a currency is ETH or an approved ERC20.
    /// @param _currencyAddress Currency to validate. Zero address indicates ETH.
    function _checkIfCurrencyIsApproved(address _currencyAddress) internal view {
        // External read: non-ETH currencies must be approved by the token registry.
        if (_currencyAddress != address(0) && !marketConfig.approvedTokenRegistry.isApprovedToken(_currencyAddress)) {
            revert CurrencyNotApproved(_currencyAddress);
        }
    }

    /// @notice Validates that a secondary collection is a deployed ERC1155 contract.
    /// @param _contractAddress ERC1155 collection address.
    function _validateERC1155Contract(address _contractAddress) internal view {
        if (
            _contractAddress.code.length == 0
                || !ERC165Checker.supportsInterface(_contractAddress, type(IERC1155).interfaceId)
        ) {
            revert InvalidERC1155Contract(_contractAddress);
        }
    }

    /// @notice Reverts when a Rare ERC1155 token id has not been created.
    /// @param _contractAddress Rare ERC1155 collection address.
    /// @param _tokenId Token id to validate.
    function _revertIfTokenNotFound(address _contractAddress, uint256 _tokenId) internal view {
        // External read: created Rare ERC1155 token ids always have a non-zero configured max supply.
        if (IRareERC1155(_contractAddress).maxSupplyForToken(_tokenId) == 0) {
            revert TokenNotFound(_contractAddress, _tokenId);
        }
    }

    /// @notice Validates payment amount and pulls ERC20 funds when needed.
    /// @dev For ETH payments, funds are already present in `msg.value`; for ERC20 payments, this function transfers tokens in.
    /// @param _currencyAddress Currency to collect. Zero address indicates ETH.
    /// @param _amount Total amount to collect, including any buyer-paid marketplace fee.
    function _checkAmountAndTransfer(address _currencyAddress, uint256 _amount) internal {
        if (_currencyAddress == address(0)) {
            // Atomic ETH check: exact value is required so no ETH is left over or underpaid.
            if (msg.value != _amount) revert IncorrectETHAmount(_amount, msg.value);
            return;
        }

        // Atomic ERC20 check: ERC20 purchases cannot also send ETH.
        if (msg.value != 0) revert MsgValueUnsupportedForERC20();

        IERC20 erc20 = IERC20(_currencyAddress);

        // Balance snapshot: used to reject fee-on-transfer or rebasing behavior during transfer.
        uint256 balanceBefore = erc20.balanceOf(address(this));

        // External transfer: pull exact payment amount through the approved ERC20 transfer manager.
        marketConfig.erc20ApprovalManager.transferFrom(_currencyAddress, msg.sender, address(this), _amount);

        // Atomic transfer check: marketplace must receive the exact amount requested.
        uint256 receivedAmount = erc20.balanceOf(address(this)) - balanceBefore;
        if (receivedAmount != _amount) {
            revert ERC20FeeOnTransferUnsupported(_currencyAddress, _amount, receivedAmount);
        }
    }

    /// @notice Validates seller split recipients and ratios.
    /// @param _splitRecipients Addresses that receive seller proceeds.
    /// @param _splitRatios Percentages corresponding to `_splitRecipients`.
    function _checkSplits(address payable[] calldata _splitRecipients, uint8[] calldata _splitRatios) internal pure {
        // Atomic split checks: every sale needs 1-5 recipients and matching ratio data.
        if (_splitRecipients.length == 0) revert SplitRecipientsRequired();
        if (_splitRecipients.length > 5) revert SplitRecipientsExceededMax(_splitRecipients.length, 5);
        if (_splitRecipients.length != _splitRatios.length) {
            revert SplitLengthMismatch(_splitRecipients.length, _splitRatios.length);
        }

        // Accounting operation: ratios must total exactly 100 percent.
        uint256 totalRatio = 0;
        for (uint256 i = 0; i < _splitRatios.length; i++) {
            if (_splitRecipients[i] == address(0)) revert SplitRecipientCannotBeZero(i);
            if (_splitRatios[i] == 0) revert SplitRatioCannotBeZero(i);
            totalRatio += _splitRatios[i];
        }

        if (totalRatio != 100) revert SplitTotalInvalid(totalRatio, 100);
    }

    /// @notice Splits seller proceeds across configured recipients.
    /// @param _currencyAddress Currency to pay. Zero address indicates ETH.
    /// @param _amount Total seller proceeds to split.
    /// @param _splitRecipients Addresses that receive seller proceeds.
    /// @param _splitRatios Percentages corresponding to `_splitRecipients`.
    function _payoutSplits(
        address _currencyAddress,
        uint256 _amount,
        address payable[] memory _splitRecipients,
        uint8[] memory _splitRatios
    ) internal {
        // Atomic guard: payout split arrays must remain paired.
        if (_splitRecipients.length != _splitRatios.length) {
            revert SplitLengthMismatch(_splitRecipients.length, _splitRatios.length);
        }

        // Memory setup: convert split percentages into absolute payout amounts.
        uint256[] memory amounts = new uint256[](_splitRecipients.length);
        uint256 remainingPayout = _amount;

        for (uint256 i = 0; i < _splitRecipients.length; i++) {
            if (i == _splitRecipients.length - 1) {
                // Accounting operation: assign rounding dust to the final recipient so the full amount is paid.
                amounts[i] = remainingPayout;
            } else {
                // Accounting operation: integer division rounds intermediate recipients down.
                amounts[i] = (_amount * _splitRatios[i]) / 100;
                remainingPayout -= amounts[i];
            }
        }

        // Payout operation: send the full split amount to recipients.
        _performPayouts(_currencyAddress, _amount, _splitRecipients, amounts);
    }

    /// @notice Pays recipients in ETH or ERC20.
    /// @dev ETH payouts are delegated to the Payments contract; ERC20 payouts transfer from marketplace balance directly.
    /// @param _currencyAddress Currency to pay. Zero address indicates ETH.
    /// @param _amount Total amount paid through this batch.
    /// @param _recipients Addresses receiving funds.
    /// @param _amounts Amount per recipient.
    function _performPayouts(
        address _currencyAddress,
        uint256 _amount,
        address payable[] memory _recipients,
        uint256[] memory _amounts
    ) internal {
        // Atomic guard: recipients and amount arrays must be paired before any payout transfer.
        if (_recipients.length != _amounts.length) {
            revert PayoutLengthMismatch(_recipients.length, _amounts.length);
        }

        // Accounting operation: validate the batch pays exactly the amount it claims to pay.
        uint256 totalAmount = 0;
        for (uint256 i = 0; i < _amounts.length; i++) {
            totalAmount += _amounts[i];
        }
        if (totalAmount != _amount) revert PayoutTotalMismatch(_amount, totalAmount);

        if (_currencyAddress == address(0)) {
            // External call: send ETH to Payments so it can fan out to each recipient.
            (bool success, bytes memory data) = address(marketConfig.payments).call{value: _amount}(
                abi.encodeWithSelector(marketConfig.payments.payout.selector, _recipients, _amounts)
            );

            // Atomic payout check: bubble raw failure data through a named marketplace error.
            if (!success) revert PayoutFailed(data);
            return;
        }

        IERC20 erc20 = IERC20(_currencyAddress);
        for (uint256 i = 0; i < _recipients.length; i++) {
            // External transfer: pay each ERC20 recipient from marketplace balance.
            erc20.safeTransfer(_recipients[i], _amounts[i]);
        }
    }

    /// @notice Validates a required market config dependency address.
    /// @param _address Address to validate.
    /// @param _field Field label used in the named error.
    function _validateMarketConfigAddress(address _address, bytes32 _field) internal pure {
        // Atomic guard: zero config dependencies are rejected before storage writes or external calls.
        if (_address == address(0)) revert MarketConfigAddressCannotBeZero(_field);
    }

    /// @notice Validates an approval manager address.
    /// @param _approvalManager Approval manager address to validate.
    function _validateApprovalManager(address _approvalManager) internal pure {
        // Atomic guard: approval manager dependencies are required for ERC20 pulls and ERC1155 transfers.
        if (_approvalManager == address(0)) revert ApprovalManagerCannotBeZero();
    }

    /// @notice Enforces an active Merkle allowlist for a primary sale.
    /// @param _contractAddress ERC1155 collection address.
    /// @param _tokenId Token id being minted.
    /// @param _address Buyer address to verify.
    /// @param _proof Merkle proof supplied by the buyer.
    function _enforceTokenAllowList(
        address _contractAddress,
        uint256 _tokenId,
        address _address,
        bytes32[] calldata _proof
    ) internal view {
        // Storage read: load allowlist config for the token id.
        IRareERC1155Marketplace.AllowListConfig memory allowListConfig = tokenAllowlistRoots[_contractAddress][_tokenId];

        if (allowListConfig.root == bytes32(0) || block.timestamp >= allowListConfig.endTimestamp) {
            return;
        }

        // Atomic proof check: active allowlists require the buyer leaf to resolve to the stored root.
        if (!_verifyProof(keccak256(abi.encodePacked(_address)), allowListConfig.root, _proof)) {
            revert AddressNotAllowlisted(_address);
        }
    }

    /// @notice Verifies a sorted Merkle proof.
    /// @param _leaf Leaf to prove.
    /// @param _root Expected Merkle root.
    /// @param _proof Proof siblings from leaf to root.
    /// @return True when the proof resolves to `_root`.
    function _verifyProof(bytes32 _leaf, bytes32 _root, bytes32[] calldata _proof) internal pure returns (bool) {
        // Memory state: iteratively fold proof siblings into the current hash.
        bytes32 currentHash = _leaf;

        for (uint256 i = 0; i < _proof.length; i++) {
            // Hash operation: combine the current node with the next proof sibling in sorted order.
            currentHash = _parentHash(currentHash, _proof[i]);
        }

        return currentHash == _root;
    }

    /// @notice Computes a sorted Merkle parent hash.
    /// @param a First child hash.
    /// @param b Second child hash.
    /// @return Parent hash for the two children.
    function _parentHash(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a <= b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    /// @notice Checks whether an account owns a collection through an `owner()` staticcall.
    /// @param _contractAddress Contract exposing an `owner()` function.
    /// @param _account Account to compare against the returned owner.
    /// @return True when `_account` is the collection owner.
    function _isContractOwner(address _contractAddress, address _account) internal view returns (bool) {
        // External staticcall: support Ownable-compatible collections without requiring a shared interface.
        (bool success, bytes memory data) = _contractAddress.staticcall(abi.encodeWithSignature("owner()"));

        // Atomic ownership-read check: owner() must return a full address word.
        if (!success || data.length < 32) revert ContractHasNoOwner(_contractAddress);
        return abi.decode(data, (address)) == _account;
    }
}
