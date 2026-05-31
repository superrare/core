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
import {IRareERC1155Listings} from "./IRareERC1155Listings.sol";
import {IERC1155ApprovalManager} from "../v2/approver/ERC1155/IERC1155ApprovalManager.sol";

/// @author SuperRare Labs Inc.
/// @title RareERC1155Listings
/// @notice Primary mint sales for RARE Protocol ERC1155 tokens and fixed-price resale listings for ERC1155 tokens.
/// @dev UUPS-upgradeable marketplace that keeps ERC1155 sale semantics separate from ERC721 marketplace logic.
contract RareERC1155Listings is
    Initializable,
    IRareERC1155Listings,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;
    using MarketConfigV2 for MarketConfigV2.Config;

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

    /// @inheritdoc IRareERC1155Listings
    uint256 public constant MAX_BATCH_SIZE = 100;

    /// @notice ERC-7201 namespaced storage for the marketplace.
    /// @dev Pins all contract-owned state to a fixed hashed slot so it cannot collide with inherited
    /// upgradeable base contracts and can be extended in future upgrades without reserving storage gaps.
    /// @custom:storage-location erc7201:superrare.storage.RareERC1155Listings
    struct ListingsStorage {
        // --- config ---
        /// @notice RARE Protocol marketplace dependency bundle.
        MarketConfigV2.Config marketConfig;
        /// @notice ERC1155 transfer manager approved by sellers and callable by this marketplace.
        IERC1155ApprovalManager erc1155ApprovalManager;
        // --- Direct sales state ---
        /// @notice Primary mint sale configuration by collection and token id.
        mapping(address => mapping(uint256 => IRareERC1155Listings.DirectSaleConfig)) directSaleConfigs;
        /// @notice Allowlist configuration by collection and token id.
        mapping(address => mapping(uint256 => IRareERC1155Listings.AllowListConfig)) tokenAllowlistRoots;
        /// @notice Per-address mint quantity limit by collection and token id.
        mapping(address => mapping(uint256 => uint256)) tokenMintLimit;
        /// @notice Quantity minted per buyer by collection and token id.
        mapping(address => mapping(uint256 => mapping(address => uint256))) tokenMintsPerAddress;
        /// @notice Per-address mint transaction limit by collection and token id.
        mapping(address => mapping(uint256 => uint256)) tokenTxLimit;
        /// @notice Mint transaction count per buyer by collection and token id.
        mapping(address => mapping(uint256 => mapping(address => uint256))) tokenTxsPerAddress;
        // --- Secondary sales state ---
        /// @notice Secondary fixed-price listings by collection, token id, and seller.
        /// @dev `expirationTime == 0` means no expiration. Buys revalidate expiration, balance, approval, currency, price,
        /// and quantity.
        mapping(address => mapping(uint256 => mapping(address => IRareERC1155Listings.SalePrice))) salePrices;
        /// @notice Whether marketplace value-moving and listing-creation operations are paused.
        bool paused;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("superrare.storage.RareERC1155Listings")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant LISTINGS_STORAGE_LOCATION =
        0x094ebcede13e570fe473dc3b580b6f2befba2d2420d1e71f35699327bd0e1300;

    /// @notice Resolves the ERC-7201 namespaced storage pointer for this contract.
    /// @return $ Storage pointer to the `ListingsStorage` struct.
    function _listingsStorage() private pure returns (ListingsStorage storage $) {
        assembly {
            $.slot := LISTINGS_STORAGE_LOCATION
        }
    }

    /// @notice Ensures marketplace actions that create listings or move value are not paused.
    modifier notPaused() {
        // Atomic guard: pause state blocks marketplace writes before any mutation or transfer.
        if (_listingsStorage().paused) revert ContractPaused();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc IRareERC1155Listings
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
        ListingsStorage storage $ = _listingsStorage();
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

    /// @inheritdoc IRareERC1155Listings
    function prepareMintDirectSales(
        address _contractAddress,
        address _currencyAddress,
        IRareERC1155Listings.DirectSaleRequest[] calldata _requests,
        address payable[] calldata _splitRecipients,
        uint8[] calldata _splitRatios
    ) external nonReentrant notPaused {
        // Atomic ownership check: only the collection owner can configure primary mint sales.
        if (!_isContractOwner(_contractAddress, msg.sender)) {
            revert NotContractOwner(_contractAddress, msg.sender);
        }

        // Atomic config checks: batch shape, sale currency, and seller split config must be valid before storage writes.
        _validateDirectSaleRequests(_requests);
        _checkIfCurrencyIsApproved(_currencyAddress);
        _checkSplits(_splitRecipients, _splitRatios);

        for (uint256 i = 0; i < _requests.length; i++) {
            uint256 tokenId = _requests[i].tokenId;
            _revertIfTokenNotFound(_contractAddress, tokenId);

            // State write: replace the primary sale config for this collection and token id.
            _listingsStorage().directSaleConfigs[_contractAddress][tokenId] = IRareERC1155Listings.DirectSaleConfig(
                msg.sender,
                _currencyAddress,
                _requests[i].price,
                _requests[i].startTime,
                _requests[i].maxMints,
                _splitRecipients,
                _splitRatios
            );

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

    /// @inheritdoc IRareERC1155Listings
    function mintDirectSaleBatch(
        address _contractAddress,
        address _currencyAddress,
        IRareERC1155Listings.MintRequest[] calldata _requests
    ) external payable nonReentrant notPaused {
        _validateMintRequests(_requests);
        _checkIfCurrencyIsApproved(_currencyAddress);

        ListingsStorage storage $ = _listingsStorage();
        uint256 requestCount = _requests.length;
        uint256[] memory tokenIds = new uint256[](requestCount);
        uint256[] memory amounts = new uint256[](requestCount);
        IRareERC1155Listings.PrimaryPayoutContext[] memory payoutContexts =
            new IRareERC1155Listings.PrimaryPayoutContext[](requestCount);
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

        // Payment pull: collect aggregate sale amount plus per-line marketplace fees before minting.
        _checkBatchPayment(_currencyAddress, buyerTotal);

        for (uint256 i = 0; i < requestCount;) {
            uint256 tokenId = _requests[i].tokenId;

            if ($.tokenMintLimit[_contractAddress][tokenId] > 0) {
                // State write: record quantity minted while this token's mint limit is enabled.
                $.tokenMintsPerAddress[_contractAddress][tokenId][msg.sender] += _requests[i].quantity;
            }

            if ($.tokenTxLimit[_contractAddress][tokenId] > 0) {
                // State write: record this token id as one transaction while its tx limit is enabled.
                $.tokenTxsPerAddress[_contractAddress][tokenId][msg.sender] += 1;
            }

            unchecked {
                ++i;
            }
        }

        // External mint: collection must have approved this marketplace as minter.
        IRareERC1155(_contractAddress).mintBatchTo(msg.sender, tokenIds, amounts);

        for (uint256 i = 0; i < requestCount;) {
            // Payout fan-out: distribute collected primary sale funds after successful mint.
            if (payoutContexts[i].grossAmount != 0) {
                _payoutPrimary(
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

    /// @inheritdoc IRareERC1155Listings
    function setTokenAllowListConfigs(
        address _contractAddress,
        IRareERC1155Listings.AllowListConfigRequest[] calldata _requests
    ) external nonReentrant {
        // Atomic ownership check: only the collection owner can change token allowlist settings.
        if (!_isContractOwner(_contractAddress, msg.sender)) revert NotContractOwner(_contractAddress, msg.sender);
        _validateAllowListConfigRequests(_requests);

        for (uint256 i = 0; i < _requests.length; i++) {
            uint256 tokenId = _requests[i].tokenId;
            _revertIfTokenNotFound(_contractAddress, tokenId);

            // State write: replace allowlist root and expiry for the token id.
            _listingsStorage().tokenAllowlistRoots[_contractAddress][tokenId] =
                IRareERC1155Listings.AllowListConfig(_requests[i].root, _requests[i].endTimestamp);
            emit SetTokenAllowListConfig(_contractAddress, tokenId, _requests[i].root, _requests[i].endTimestamp);
        }
    }

    /// @inheritdoc IRareERC1155Listings
    function setTokenMintLimits(address _contractAddress, IRareERC1155Listings.TokenLimitRequest[] calldata _requests)
        external
        nonReentrant
    {
        // Atomic ownership check: only the collection owner can change mint limits.
        if (!_isContractOwner(_contractAddress, msg.sender)) revert NotContractOwner(_contractAddress, msg.sender);
        _validateTokenLimitRequests(_requests);

        for (uint256 i = 0; i < _requests.length; i++) {
            uint256 tokenId = _requests[i].tokenId;
            _revertIfTokenNotFound(_contractAddress, tokenId);

            // State write: replace per-address quantity limit for the token id.
            _listingsStorage().tokenMintLimit[_contractAddress][tokenId] = _requests[i].limit;
            emit TokenMintLimitSet(_contractAddress, tokenId, _requests[i].limit);
        }
    }

    /// @inheritdoc IRareERC1155Listings
    function setTokenTxLimits(address _contractAddress, IRareERC1155Listings.TokenLimitRequest[] calldata _requests)
        external
        nonReentrant
    {
        // Atomic ownership check: only the collection owner can change transaction limits.
        if (!_isContractOwner(_contractAddress, msg.sender)) revert NotContractOwner(_contractAddress, msg.sender);
        _validateTokenLimitRequests(_requests);

        for (uint256 i = 0; i < _requests.length; i++) {
            uint256 tokenId = _requests[i].tokenId;
            _revertIfTokenNotFound(_contractAddress, tokenId);

            // State write: replace per-address transaction limit for the token id.
            _listingsStorage().tokenTxLimit[_contractAddress][tokenId] = _requests[i].limit;
            emit TokenTxLimitSet(_contractAddress, tokenId, _requests[i].limit);
        }
    }

    /// @inheritdoc IRareERC1155Listings
    function setSalePrices(
        address _contractAddress,
        address _currencyAddress,
        IRareERC1155Listings.SalePriceRequest[] calldata _requests,
        address payable[] calldata _splitRecipients,
        uint8[] calldata _splitRatios
    ) external nonReentrant notPaused {
        // Atomic config checks: batch shape, listing currency, split recipients, price, quantity, and expiration must be valid.
        _validateSalePriceRequests(_requests);
        _checkIfCurrencyIsApproved(_currencyAddress);
        _checkSplits(_splitRecipients, _splitRatios);
        _validateERC1155Contract(_contractAddress);

        // External read: one collection-level transfer approval supports every token id in the batch.
        IERC1155 erc1155 = IERC1155(_contractAddress);
        if (!erc1155.isApprovedForAll(msg.sender, address(_listingsStorage().erc1155ApprovalManager))) {
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

            // External reads: verify seller balance at list time.
            uint256 sellerBalance = erc1155.balanceOf(msg.sender, tokenId);
            if (sellerBalance < quantity) {
                revert InsufficientTokenBalance(msg.sender, _contractAddress, tokenId, quantity, sellerBalance);
            }

            // State write: create or replace seller's approval-based fixed-price listing.
            _listingsStorage().salePrices[_contractAddress][tokenId][msg.sender] = IRareERC1155Listings.SalePrice(
                _currencyAddress, price, quantity, expirationTime, _splitRecipients, _splitRatios
            );

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

    /// @inheritdoc IRareERC1155Listings
    function cancelSalePrices(address _contractAddress, uint256[] calldata _tokenIds) external nonReentrant {
        _validateTokenIds(_tokenIds);

        for (uint256 i = 0; i < _tokenIds.length; i++) {
            uint256 tokenId = _tokenIds[i];
            ListingsStorage storage $ = _listingsStorage();
            if ($.salePrices[_contractAddress][tokenId][msg.sender].quantity == 0) {
                continue;
            }

            // State delete: remove caller's active listing for this collection and token id.
            delete $.salePrices[_contractAddress][tokenId][msg.sender];

            emit SalePriceCancelled(msg.sender, _contractAddress, tokenId);
        }
    }

    /// @inheritdoc IRareERC1155Listings
    function buyBatch(
        address _contractAddress,
        address _seller,
        address _currencyAddress,
        IRareERC1155Listings.BuyRequest[] calldata _requests
    ) external payable nonReentrant notPaused {
        _validateBuyRequests(_requests);
        if (msg.sender == _seller) revert SelfPurchaseUnsupported(_seller);

        // Atomic currency check: rejected currencies cannot be used even for stale listings.
        _checkIfCurrencyIsApproved(_currencyAddress);
        _validateERC1155Contract(_contractAddress);

        // External read: recheck seller approval at buy time because listings are not escrowed.
        ListingsStorage storage $ = _listingsStorage();
        IERC1155 erc1155 = IERC1155(_contractAddress);
        if (!erc1155.isApprovedForAll(_seller, address($.erc1155ApprovalManager))) {
            revert MarketplaceNotApproved(_seller, _contractAddress);
        }

        uint256 requestCount = _requests.length;
        uint256[] memory tokenIds = new uint256[](requestCount);
        uint256[] memory amounts = new uint256[](requestCount);
        address[] memory balanceAccounts = new address[](requestCount * 2);
        uint256[] memory balanceTokenIds = new uint256[](requestCount * 2);
        IRareERC1155Listings.SecondaryPayoutContext[] memory payoutContexts =
            new IRareERC1155Listings.SecondaryPayoutContext[](requestCount);
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

            uint256 balanceIndex = i * 2;
            balanceAccounts[balanceIndex] = _seller;
            balanceAccounts[balanceIndex + 1] = msg.sender;
            balanceTokenIds[balanceIndex] = tokenIds[i];
            balanceTokenIds[balanceIndex + 1] = tokenIds[i];

            unchecked {
                ++i;
            }
        }

        // Payment pull: collect aggregate sale amount plus per-line marketplace fees before moving the ERC1155 batch.
        _checkBatchPayment(_currencyAddress, buyerTotal);

        for (uint256 i = 0; i < requestCount;) {
            IRareERC1155Listings.SalePrice storage salePrice =
                $.salePrices[_contractAddress][_requests[i].tokenId][_seller];

            // State write: decrement listed quantity before the external ERC1155 batch transfer.
            salePrice.quantity -= _requests[i].quantity;
            if (salePrice.quantity == 0) {
                // State delete: clear listing storage once the final listed quantity is sold.
                delete $.salePrices[_contractAddress][_requests[i].tokenId][_seller];
            }

            unchecked {
                ++i;
            }
        }

        uint256[] memory balancesBeforeTransfer = erc1155.balanceOfBatch(balanceAccounts, balanceTokenIds);
        for (uint256 i = 0; i < requestCount;) {
            uint256 sellerBalanceIndex = i * 2;
            if (balancesBeforeTransfer[sellerBalanceIndex] < amounts[i]) {
                revert InsufficientTokenBalance(
                    _seller, _contractAddress, tokenIds[i], amounts[i], balancesBeforeTransfer[sellerBalanceIndex]
                );
            }

            unchecked {
                ++i;
            }
        }

        // External transfer: move ERC1155 tokens through the approved transfer manager.
        $.erc1155ApprovalManager.safeBatchTransferFrom(_contractAddress, _seller, msg.sender, tokenIds, amounts, "");

        uint256[] memory balancesAfterTransfer = erc1155.balanceOfBatch(balanceAccounts, balanceTokenIds);
        for (uint256 i = 0; i < requestCount;) {
            uint256 balanceIndex = i * 2;
            if (
                balancesAfterTransfer[balanceIndex] != balancesBeforeTransfer[balanceIndex] - amounts[i]
                    || balancesAfterTransfer[balanceIndex + 1] != balancesBeforeTransfer[balanceIndex + 1] + amounts[i]
            ) {
                revert InvalidERC1155Transfer(_contractAddress, tokenIds[i], _seller, msg.sender, amounts[i]);
            }

            unchecked {
                ++i;
            }
        }

        for (uint256 i = 0; i < requestCount;) {
            // Payout fan-out: distribute collected secondary sale funds after token transfer.
            _payoutSecondary(
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

    /// @inheritdoc IRareERC1155Listings
    function getDirectSaleConfig(address _contractAddress, uint256 _tokenId)
        external
        view
        returns (IRareERC1155Listings.DirectSaleConfig memory)
    {
        return _listingsStorage().directSaleConfigs[_contractAddress][_tokenId];
    }

    /// @inheritdoc IRareERC1155Listings
    function getTokenAllowListConfig(address _contractAddress, uint256 _tokenId)
        external
        view
        returns (IRareERC1155Listings.AllowListConfig memory)
    {
        return _listingsStorage().tokenAllowlistRoots[_contractAddress][_tokenId];
    }

    /// @inheritdoc IRareERC1155Listings
    function getTokenMintLimit(address _contractAddress, uint256 _tokenId) external view returns (uint256) {
        return _listingsStorage().tokenMintLimit[_contractAddress][_tokenId];
    }

    /// @inheritdoc IRareERC1155Listings
    function getTokenMintsPerAddress(address _contractAddress, uint256 _tokenId, address _address)
        external
        view
        returns (uint256)
    {
        return _listingsStorage().tokenMintsPerAddress[_contractAddress][_tokenId][_address];
    }

    /// @inheritdoc IRareERC1155Listings
    function getTokenTxLimit(address _contractAddress, uint256 _tokenId) external view returns (uint256) {
        return _listingsStorage().tokenTxLimit[_contractAddress][_tokenId];
    }

    /// @inheritdoc IRareERC1155Listings
    function getTokenTxsPerAddress(address _contractAddress, uint256 _tokenId, address _address)
        external
        view
        returns (uint256)
    {
        return _listingsStorage().tokenTxsPerAddress[_contractAddress][_tokenId][_address];
    }

    /// @inheritdoc IRareERC1155Listings
    function getSalePrice(address _contractAddress, uint256 _tokenId, address _seller)
        external
        view
        returns (IRareERC1155Listings.SalePrice memory)
    {
        return _listingsStorage().salePrices[_contractAddress][_tokenId][_seller];
    }

    /// @inheritdoc IRareERC1155Listings
    function getMarketConfig() external view returns (MarketConfigV2.Config memory) {
        return _listingsStorage().marketConfig;
    }

    /// @inheritdoc IRareERC1155Listings
    function getERC1155ApprovalManager() external view returns (address) {
        return address(_listingsStorage().erc1155ApprovalManager);
    }

    /// @inheritdoc IRareERC1155Listings
    function isPaused() external view returns (bool) {
        return _listingsStorage().paused;
    }

    /// @inheritdoc IRareERC1155Listings
    function setNetworkBeneficiary(address _networkBeneficiary) external onlyOwner {
        // Atomic guard: network beneficiary must remain payable by marketplace fee flows.
        _validateMarketConfigAddress(_networkBeneficiary, NETWORK_BENEFICIARY_FIELD);

        // State write: delegate config mutation to the shared MarketConfig library.
        _listingsStorage().marketConfig.updateNetworkBeneficiary(_networkBeneficiary);

        emit MarketplaceDependencyUpdated(NETWORK_BENEFICIARY_FIELD, _networkBeneficiary);
    }

    /// @inheritdoc IRareERC1155Listings
    function setMarketplaceSettings(address _marketplaceSettings) external onlyOwner {
        // Atomic guard: marketplace fee calculations must retain a concrete settings contract.
        _validateMarketConfigAddress(_marketplaceSettings, MARKETPLACE_SETTINGS_FIELD);

        // State write: delegate config mutation to the shared MarketConfig library.
        _listingsStorage().marketConfig.updateMarketplaceSettings(_marketplaceSettings);

        emit MarketplaceDependencyUpdated(MARKETPLACE_SETTINGS_FIELD, _marketplaceSettings);
    }

    /// @inheritdoc IRareERC1155Listings
    function setSpaceOperatorRegistry(address _spaceOperatorRegistry) external onlyOwner {
        // Atomic guard: primary platform-fee resolution must retain a concrete registry.
        _validateMarketConfigAddress(_spaceOperatorRegistry, SPACE_OPERATOR_REGISTRY_FIELD);

        // State write: delegate config mutation to the shared MarketConfig library.
        _listingsStorage().marketConfig.updateSpaceOperatorRegistry(_spaceOperatorRegistry);

        emit MarketplaceDependencyUpdated(SPACE_OPERATOR_REGISTRY_FIELD, _spaceOperatorRegistry);
    }

    /// @inheritdoc IRareERC1155Listings
    function setRoyaltyEngine(address _royaltyEngine) external onlyOwner {
        // Atomic guard: secondary royalty resolution must retain a concrete engine.
        _validateMarketConfigAddress(_royaltyEngine, ROYALTY_ENGINE_FIELD);

        // State write: delegate config mutation to the shared MarketConfig library.
        _listingsStorage().marketConfig.updateRoyaltyEngine(_royaltyEngine);

        emit MarketplaceDependencyUpdated(ROYALTY_ENGINE_FIELD, _royaltyEngine);
    }

    /// @inheritdoc IRareERC1155Listings
    function setPayments(address _payments) external onlyOwner {
        // Atomic guard: ETH payout fan-out must retain a concrete Payments contract.
        _validateMarketConfigAddress(_payments, PAYMENTS_FIELD);

        // State write: delegate config mutation to the shared MarketConfig library.
        _listingsStorage().marketConfig.updatePayments(_payments);

        emit MarketplaceDependencyUpdated(PAYMENTS_FIELD, _payments);
    }

    /// @inheritdoc IRareERC1155Listings
    function setApprovedTokenRegistry(address _approvedTokenRegistry) external onlyOwner {
        // Atomic guard: currency approval checks must retain a concrete registry.
        _validateMarketConfigAddress(_approvedTokenRegistry, APPROVED_TOKEN_REGISTRY_FIELD);

        // State write: delegate config mutation to the shared MarketConfig library.
        _listingsStorage().marketConfig.updateApprovedTokenRegistry(_approvedTokenRegistry);

        emit MarketplaceDependencyUpdated(APPROVED_TOKEN_REGISTRY_FIELD, _approvedTokenRegistry);
    }

    /// @inheritdoc IRareERC1155Listings
    function setStakingSettings(address _stakingSettings) external onlyOwner {
        // Atomic guard: marketplace fee split math must retain concrete settings.
        _validateMarketConfigAddress(_stakingSettings, STAKING_SETTINGS_FIELD);

        // State write: delegate config mutation to the shared MarketConfig library.
        _listingsStorage().marketConfig.updateStakingSettings(_stakingSettings);

        emit MarketplaceDependencyUpdated(STAKING_SETTINGS_FIELD, _stakingSettings);
    }

    /// @inheritdoc IRareERC1155Listings
    function setStakingRegistry(address _stakingRegistry) external onlyOwner {
        // Atomic guard: marketplace fee split recipients must retain a concrete registry.
        _validateMarketConfigAddress(_stakingRegistry, STAKING_REGISTRY_FIELD);

        // State write: delegate config mutation to the shared MarketConfig library.
        _listingsStorage().marketConfig.updateStakingRegistry(_stakingRegistry);

        emit MarketplaceDependencyUpdated(STAKING_REGISTRY_FIELD, _stakingRegistry);
    }

    /// @inheritdoc IRareERC1155Listings
    function setERC20ApprovalManager(address _erc20ApprovalManager) external onlyOwner {
        // Atomic guard: ERC20 purchases must retain a concrete transfer manager.
        _validateApprovalManager(_erc20ApprovalManager);

        // State write: delegate config mutation to the shared MarketConfig library.
        _listingsStorage().marketConfig.updateERC20ApprovalManager(_erc20ApprovalManager);

        emit MarketplaceDependencyUpdated(ERC20_APPROVAL_MANAGER_FIELD, _erc20ApprovalManager);
    }

    /// @inheritdoc IRareERC1155Listings
    function setERC721ApprovalManager(address _erc721ApprovalManager) external onlyOwner {
        // Atomic guard: shared V2 config must retain a concrete ERC721 approval manager.
        _validateApprovalManager(_erc721ApprovalManager);

        // State write: delegate config mutation to the shared MarketConfig library.
        _listingsStorage().marketConfig.updateERC721ApprovalManager(_erc721ApprovalManager);

        emit MarketplaceDependencyUpdated(ERC721_APPROVAL_MANAGER_FIELD, _erc721ApprovalManager);
    }

    /// @inheritdoc IRareERC1155Listings
    function setERC1155ApprovalManager(address _erc1155ApprovalManager) external onlyOwner {
        // Atomic guard: secondary ERC1155 transfers must retain a concrete approval manager.
        _validateApprovalManager(_erc1155ApprovalManager);

        // State write: replace the manager used for seller approval checks and transfers.
        _listingsStorage().erc1155ApprovalManager = IERC1155ApprovalManager(_erc1155ApprovalManager);

        emit MarketplaceDependencyUpdated(ERC1155_APPROVAL_MANAGER_FIELD, _erc1155ApprovalManager);
    }

    /// @inheritdoc IRareERC1155Listings
    function setContractPaused(bool _isPaused) external onlyOwner {
        // State write: set pause flag consumed by the notPaused modifier.
        _listingsStorage().paused = _isPaused;

        emit ContractPausedUpdated(_isPaused);
    }

    /// @notice Distributes proceeds for a primary mint sale.
    /// @dev Marketplace fee is paid on top by the buyer; platform fee is deducted from seller proceeds.
    /// @param _contractAddress ERC1155 collection address.
    /// @param _currencyAddress Currency being paid. Zero address indicates ETH.
    /// @param _amount Gross sale amount before platform fee.
    /// @param _marketplaceFee Buyer-paid marketplace fee already calculated for `_amount`.
    /// @param _seller Primary sale seller.
    /// @param _splitRecipients Seller proceed recipients.
    /// @param _splitRatios Seller proceed split ratios.
    function _payoutPrimary(
        address _contractAddress,
        address _currencyAddress,
        uint256 _amount,
        uint256 _marketplaceFee,
        address _seller,
        address payable[] memory _splitRecipients,
        uint8[] memory _splitRatios
    ) internal {
        // Accounting state: track seller proceeds remaining after primary platform commission.
        ListingsStorage storage $ = _listingsStorage();
        uint256 remainingAmount = _amount;

        // Payout operation: distribute the buyer-paid marketplace fee through the configured fee split.
        _payoutMarketplaceFee(_currencyAddress, _amount, _marketplaceFee, _seller);

        // External reads: choose primary commission from approved space operator or marketplace settings.
        uint256 platformCommission = $.marketConfig.spaceOperatorRegistry.isApprovedSpaceOperator(_seller)
            ? $.marketConfig.spaceOperatorRegistry.getPlatformCommission(_seller)
            : $.marketConfig.marketplaceSettings.getERC721ContractPrimarySaleFeePercentage(_contractAddress);
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
            platformRecipients[0] = payable($.marketConfig.networkBeneficiary);
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
    /// @param _marketplaceFee Buyer-paid marketplace fee already calculated for `_amount`.
    /// @param _seller Secondary seller.
    /// @param _splitRecipients Seller proceed recipients.
    /// @param _splitRatios Seller proceed split ratios.
    function _payoutSecondary(
        address _contractAddress,
        uint256 _tokenId,
        address _currencyAddress,
        uint256 _amount,
        uint256 _marketplaceFee,
        address _seller,
        address payable[] memory _splitRecipients,
        uint8[] memory _splitRatios
    ) internal {
        // Accounting state: track seller proceeds remaining after royalties.
        uint256 remainingAmount = _amount;

        // Payout operation: distribute the buyer-paid marketplace fee through the configured fee split.
        _payoutMarketplaceFee(_currencyAddress, _amount, _marketplaceFee, _seller);

        // External read: resolve royalties through the configured royalty engine.
        (address payable[] memory receivers, uint256[] memory royalties) =
            _listingsStorage().marketConfig.royaltyEngine.getRoyalty(_contractAddress, _tokenId, _amount);

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
    /// @param _marketplaceFee Buyer-paid marketplace fee already calculated for `_amount`.
    /// @param _seller Seller whose staking reward accumulator may receive staking fees.
    function _payoutMarketplaceFee(address _currencyAddress, uint256 _amount, uint256 _marketplaceFee, address _seller)
        internal
    {
        if (_marketplaceFee == 0) {
            return;
        }

        // External read: calculate staking fee from staking settings and send the collected remainder to network.
        ListingsStorage storage $ = _listingsStorage();
        uint256 stakingFee = $.marketConfig.stakingSettings.calculateStakingFee(_amount);
        if (stakingFee > _marketplaceFee) {
            revert StakingFeeExceedsMarketplaceFee(_marketplaceFee, stakingFee);
        }

        // Memory setup: recipient 0 is network, recipient 1 is seller staking reward accumulator or network fallback.
        address payable[] memory recipients = new address payable[](2);
        recipients[0] = payable($.marketConfig.networkBeneficiary);
        recipients[1] = payable($.marketConfig.stakingRegistry.getRewardAccumulatorAddressForUser(_seller));
        recipients[1] = recipients[1] == address(0) ? payable($.marketConfig.networkBeneficiary) : recipients[1];

        // Memory setup: distribute the buyer-paid marketplace fee between network and staking recipients.
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = _marketplaceFee - stakingFee;
        amounts[1] = stakingFee;

        // Payout operation: distribute the marketplace fee batch.
        _performPayouts(_currencyAddress, _marketplaceFee, recipients, amounts);
    }

    /// @notice Validates that a currency is ETH or an approved ERC20.
    /// @param _currencyAddress Currency to validate. Zero address indicates ETH.
    function _checkIfCurrencyIsApproved(address _currencyAddress) internal view {
        // External read: non-ETH currencies must be approved by the token registry.
        if (
            _currencyAddress != address(0)
                && !_listingsStorage().marketConfig.approvedTokenRegistry.isApprovedToken(_currencyAddress)
        ) {
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

    /// @notice Validates one primary mint request and snapshots payout state.
    /// @param _contractAddress ERC1155 collection address.
    /// @param _currencyAddress Currency expected by the buyer.
    /// @param _buyer Buyer executing the batch.
    /// @param _request Mint request to validate.
    /// @return payoutContext Payout data copied before the external batch mint.
    function _validateMintDirectSaleRequest(
        address _contractAddress,
        address _currencyAddress,
        address _buyer,
        IRareERC1155Listings.MintRequest calldata _request
    ) internal view returns (IRareERC1155Listings.PrimaryPayoutContext memory payoutContext) {
        ListingsStorage storage $ = _listingsStorage();
        uint256 tokenId = _request.tokenId;
        uint256 quantity = _request.quantity;
        IRareERC1155Listings.DirectSaleConfig memory directSaleConfig = $.directSaleConfigs[_contractAddress][tokenId];

        // Atomic guards: ensure sale existence, current seller ownership, allowlist membership, and non-zero quantity.
        if (directSaleConfig.seller == address(0)) revert DirectSaleNotConfigured(_contractAddress, tokenId);
        if (!_isContractOwner(_contractAddress, directSaleConfig.seller)) {
            revert NotContractOwner(_contractAddress, directSaleConfig.seller);
        }
        _enforceTokenAllowList(_contractAddress, tokenId, _buyer, _request.proof);
        if (quantity == 0) revert QuantityCannotBeZero();

        // Atomic mint-limit check: validate requested quantity against buyer's enabled-period mint count.
        uint256 mintLimit = $.tokenMintLimit[_contractAddress][tokenId];
        uint256 currentMints = $.tokenMintsPerAddress[_contractAddress][tokenId][_buyer];
        if (mintLimit != 0 && currentMints + quantity > mintLimit) {
            revert MintLimitExceeded(_contractAddress, tokenId, _buyer, quantity, currentMints, mintLimit);
        }

        // Atomic tx-limit check: each touched token id consumes one transaction when its tx limit is enabled.
        uint256 txLimit = $.tokenTxLimit[_contractAddress][tokenId];
        uint256 currentTxs = $.tokenTxsPerAddress[_contractAddress][tokenId][_buyer];
        if (txLimit != 0 && currentTxs + 1 > txLimit) {
            revert TransactionLimitExceeded(_contractAddress, tokenId, _buyer, currentTxs, txLimit);
        }

        // Atomic sale-parameter checks: buyer-supplied price and currency must match the stored config.
        if (directSaleConfig.maxMints != 0 && quantity > directSaleConfig.maxMints) {
            revert MaxMintExceeded(quantity, directSaleConfig.maxMints);
        }
        if (directSaleConfig.startTime > block.timestamp) revert SaleNotStarted(directSaleConfig.startTime);
        if (_request.price != directSaleConfig.price) revert PriceMismatch(_request.price, directSaleConfig.price);
        if (directSaleConfig.currencyAddress != _currencyAddress) {
            revert CurrencyMismatch(_currencyAddress, directSaleConfig.currencyAddress);
        }

        payoutContext = IRareERC1155Listings.PrimaryPayoutContext(
            tokenId,
            quantity * _request.price,
            0,
            directSaleConfig.seller,
            directSaleConfig.splitRecipients,
            directSaleConfig.splitRatios
        );
    }

    /// @notice Validates one secondary buy request and snapshots payout state.
    /// @param _contractAddress ERC1155 collection address.
    /// @param _seller Seller whose listing is being filled.
    /// @param _currencyAddress Currency expected by the buyer.
    /// @param _request Buy request to validate.
    /// @return payoutContext Payout data copied before listings may be decremented or deleted.
    function _validateSecondaryBuyRequest(
        address _contractAddress,
        address _seller,
        address _currencyAddress,
        IRareERC1155Listings.BuyRequest calldata _request
    ) internal view returns (IRareERC1155Listings.SecondaryPayoutContext memory payoutContext) {
        uint256 tokenId = _request.tokenId;
        uint256 quantity = _request.quantity;
        if (quantity == 0) revert QuantityCannotBeZero();

        // Storage pointer: mutate seller listing quantity only after all buy-time checks pass.
        IRareERC1155Listings.SalePrice storage salePrice =
            _listingsStorage().salePrices[_contractAddress][tokenId][_seller];

        // Atomic listing checks: listing must exist and match buyer-supplied terms.
        if (salePrice.quantity == 0) revert SalePriceDoesNotExist(_contractAddress, tokenId, _seller);
        if (salePrice.expirationTime != 0 && salePrice.expirationTime <= block.timestamp) {
            revert SalePriceExpired(_contractAddress, tokenId, _seller, salePrice.expirationTime);
        }
        if (salePrice.currencyAddress != _currencyAddress) {
            revert CurrencyMismatch(_currencyAddress, salePrice.currencyAddress);
        }
        if (salePrice.price != _request.price) revert PriceMismatch(_request.price, salePrice.price);
        if (salePrice.quantity < quantity) revert QuantityExceedsSalePriceQuantity(quantity, salePrice.quantity);

        payoutContext = IRareERC1155Listings.SecondaryPayoutContext(
            tokenId, quantity * _request.price, 0, salePrice.splitRecipients, salePrice.splitRatios
        );
    }

    /// @notice Validates plain token id batch shape and ordering.
    /// @param _tokenIds Token ids supplied by the caller.
    function _validateTokenIds(uint256[] calldata _tokenIds) internal pure {
        _validateBatchSize(_tokenIds.length);
        for (uint256 i = 1; i < _tokenIds.length; i++) {
            if (_tokenIds[i] <= _tokenIds[i - 1]) {
                revert TokenIdsNotStrictlyAscending(i, _tokenIds[i - 1], _tokenIds[i]);
            }
        }
    }

    /// @notice Validates primary sale config request batch shape and ordering.
    /// @param _requests Requests supplied by the caller.
    function _validateDirectSaleRequests(IRareERC1155Listings.DirectSaleRequest[] calldata _requests) internal pure {
        _validateBatchSize(_requests.length);
        for (uint256 i = 1; i < _requests.length; i++) {
            if (_requests[i].tokenId <= _requests[i - 1].tokenId) {
                revert TokenIdsNotStrictlyAscending(i, _requests[i - 1].tokenId, _requests[i].tokenId);
            }
        }
    }

    /// @notice Validates primary mint request batch shape and ordering.
    /// @param _requests Requests supplied by the caller.
    function _validateMintRequests(IRareERC1155Listings.MintRequest[] calldata _requests) internal pure {
        _validateBatchSize(_requests.length);
        for (uint256 i = 1; i < _requests.length; i++) {
            if (_requests[i].tokenId <= _requests[i - 1].tokenId) {
                revert TokenIdsNotStrictlyAscending(i, _requests[i - 1].tokenId, _requests[i].tokenId);
            }
        }
    }

    /// @notice Validates allowlist config request batch shape and ordering.
    /// @param _requests Requests supplied by the caller.
    function _validateAllowListConfigRequests(IRareERC1155Listings.AllowListConfigRequest[] calldata _requests)
        internal
        pure
    {
        _validateBatchSize(_requests.length);
        for (uint256 i = 1; i < _requests.length; i++) {
            if (_requests[i].tokenId <= _requests[i - 1].tokenId) {
                revert TokenIdsNotStrictlyAscending(i, _requests[i - 1].tokenId, _requests[i].tokenId);
            }
        }
    }

    /// @notice Validates token limit request batch shape and ordering.
    /// @param _requests Requests supplied by the caller.
    function _validateTokenLimitRequests(IRareERC1155Listings.TokenLimitRequest[] calldata _requests) internal pure {
        _validateBatchSize(_requests.length);
        for (uint256 i = 1; i < _requests.length; i++) {
            if (_requests[i].tokenId <= _requests[i - 1].tokenId) {
                revert TokenIdsNotStrictlyAscending(i, _requests[i - 1].tokenId, _requests[i].tokenId);
            }
        }
    }

    /// @notice Validates secondary listing request batch shape and ordering.
    /// @param _requests Requests supplied by the caller.
    function _validateSalePriceRequests(IRareERC1155Listings.SalePriceRequest[] calldata _requests) internal pure {
        _validateBatchSize(_requests.length);
        for (uint256 i = 1; i < _requests.length; i++) {
            if (_requests[i].tokenId <= _requests[i - 1].tokenId) {
                revert TokenIdsNotStrictlyAscending(i, _requests[i - 1].tokenId, _requests[i].tokenId);
            }
        }
    }

    /// @notice Validates secondary buy request batch shape and ordering.
    /// @param _requests Requests supplied by the caller.
    function _validateBuyRequests(IRareERC1155Listings.BuyRequest[] calldata _requests) internal pure {
        _validateBatchSize(_requests.length);
        for (uint256 i = 1; i < _requests.length; i++) {
            if (_requests[i].tokenId <= _requests[i - 1].tokenId) {
                revert TokenIdsNotStrictlyAscending(i, _requests[i - 1].tokenId, _requests[i].tokenId);
            }
        }
    }

    /// @notice Validates common batch size constraints.
    /// @param _length Number of batch items supplied by the caller.
    function _validateBatchSize(uint256 _length) internal pure {
        if (_length == 0) revert EmptyBatch();
        if (_length > MAX_BATCH_SIZE) revert BatchSizeExceeded(_length, MAX_BATCH_SIZE);
    }

    /// @notice Validates aggregate payment amount and pulls ERC20 funds when needed.
    /// @param _currencyAddress Currency to collect. Zero address indicates ETH.
    /// @param _amount Total amount to collect, including all buyer-paid marketplace fees.
    function _checkBatchPayment(address _currencyAddress, uint256 _amount) internal {
        if (_amount == 0) {
            // Atomic free-batch guard: free batches must not leave ETH stuck in the marketplace.
            if (msg.value != 0) revert MsgValueMustBeZero();
            return;
        }

        _checkAmountAndTransfer(_currencyAddress, _amount);
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
        _listingsStorage().marketConfig.erc20ApprovalManager
            .transferFrom(_currencyAddress, msg.sender, address(this), _amount);

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
            MarketConfigV2.Config storage marketConfig = _listingsStorage().marketConfig;
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
        IRareERC1155Listings.AllowListConfig memory allowListConfig =
            _listingsStorage().tokenAllowlistRoots[_contractAddress][_tokenId];

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
