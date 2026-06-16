// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import {MarketConfigV2} from "../v2/utils/MarketConfigV2.sol";
import {IRareERC1155MarketplaceTypes} from "./IRareERC1155MarketplaceTypes.sol";

/// @author SuperRare Labs Inc.
/// @title IRareERC1155Marketplace
/// @notice Interface for ERC1155 marketplace state creation, escrow, configuration, and execution module routing.
interface IRareERC1155Marketplace is IRareERC1155MarketplaceTypes {
    /// @notice Initializes the UUPS marketplace proxy.
    function initialize(
        address _networkBeneficiary,
        address _marketplaceSettings,
        address _royaltyEngine,
        address _payments,
        address _approvedTokenRegistry,
        address _erc20ApprovalManager,
        address _erc721ApprovalManager,
        address _erc1155ApprovalManager,
        address _tradeExecutionModule,
        address _checkoutExecutionModule
    ) external;

    /// @notice Configures or replaces primary mint sales for token ids.
    /// @dev Request token ids must be strictly ascending.
    function prepareMintDirectSales(
        address _contractAddress,
        address _currencyAddress,
        DirectSaleRequest[] calldata _requests,
        address payable[] calldata _splitRecipients,
        uint8[] calldata _splitRatios
    ) external;

    /// @notice Cancels configured primary mint sales for token ids.
    /// @dev Token ids must be strictly ascending.
    function cancelMintDirectSales(address _contractAddress, uint256[] calldata _tokenIds) external;

    /// @notice Sets token id allowlist configurations.
    /// @dev Request token ids must be strictly ascending.
    function setTokenAllowListConfigs(address _contractAddress, AllowListConfigRequest[] calldata _requests) external;

    /// @notice Sets max quantity each address may mint for token ids while a limit is enabled.
    /// @dev Request token ids must be strictly ascending.
    function setTokenMintLimits(address _contractAddress, TokenLimitRequest[] calldata _requests) external;

    /// @notice Sets max mint transactions each address may submit for token ids while a limit is enabled.
    /// @dev Request token ids must be strictly ascending.
    function setTokenTxLimits(address _contractAddress, TokenLimitRequest[] calldata _requests) external;

    /// @notice Creates or replaces secondary fixed-price listings.
    /// @dev Request token ids must be strictly ascending.
    function setSalePrices(
        address _contractAddress,
        address _currencyAddress,
        SalePriceRequest[] calldata _requests,
        address payable[] calldata _splitRecipients,
        uint8[] calldata _splitRatios
    ) external;

    /// @notice Cancels the caller's secondary listings for token ids.
    /// @dev Token ids must be strictly ascending.
    function cancelSalePrices(address _contractAddress, uint256[] calldata _tokenIds) external;

    /// @notice Creates or replaces a token-level ERC1155 offer.
    function makeOffer(
        address _contractAddress,
        uint256 _tokenId,
        address _currencyAddress,
        uint256 _price,
        uint256 _quantity,
        uint256 _expirationTime
    ) external payable;

    /// @notice Cancels the caller's offer for one token id and currency.
    function cancelOffer(address _contractAddress, uint256 _tokenId, address _currencyAddress) external;

    /// @notice Mints tokens from configured primary sales through the trade execution module.
    /// @dev `msg.sender` pays and `_recipient` receives the minted tokens.
    function mintDirectSaleBatch(
        address _contractAddress,
        address _currencyAddress,
        address _recipient,
        MintRequest[] calldata _requests
    ) external payable;

    /// @notice Buys tokens from a seller's secondary fixed-price listings through the trade execution module.
    /// @dev `msg.sender` pays and `_recipient` receives the purchased tokens.
    function buyBatch(
        address _contractAddress,
        address _seller,
        address _currencyAddress,
        address _recipient,
        BuyRequest[] calldata _requests
    ) external payable;

    /// @notice Accepts all or part of an ERC1155 token offer through the trade execution module.
    function acceptOffer(
        address _contractAddress,
        uint256 _tokenId,
        address _buyer,
        address _currencyAddress,
        uint256 _price,
        uint256 _quantity,
        address payable[] calldata _splitRecipients,
        uint8[] calldata _splitRatios
    ) external;

    /// @notice Executes a payer cart of direct-sale mints and secondary fixed-price listing purchases.
    /// @dev Best-effort execution returns one result per item. All-skipped checkouts complete successfully.
    function checkout(
        address _recipient,
        CheckoutItem[] calldata _items
    ) external payable returns (CheckoutExecution memory);

    function getDirectSaleConfig(
        address _contractAddress,
        uint256 _tokenId
    ) external view returns (DirectSaleConfig memory);

    function getTokenAllowListConfig(
        address _contractAddress,
        uint256 _tokenId
    ) external view returns (AllowListConfig memory);

    function getTokenMintLimit(address _contractAddress, uint256 _tokenId) external view returns (uint256);

    function getTokenMintsPerAddress(
        address _contractAddress,
        uint256 _tokenId,
        address _account
    ) external view returns (uint256);

    function getTokenTxLimit(address _contractAddress, uint256 _tokenId) external view returns (uint256);

    function getTokenTxsPerAddress(
        address _contractAddress,
        uint256 _tokenId,
        address _account
    ) external view returns (uint256);

    function getSalePrice(
        address _contractAddress,
        uint256 _tokenId,
        address _seller
    ) external view returns (SalePrice memory);

    function getOffer(
        address _contractAddress,
        uint256 _tokenId,
        address _buyer,
        address _currencyAddress
    ) external view returns (Offer memory);

    function getMarketConfig() external view returns (MarketConfigV2.Config memory);
    function getERC1155ApprovalManager() external view returns (address);
    function getTradeExecutionModule() external view returns (address);
    function getCheckoutExecutionModule() external view returns (address);
    function isPaused() external view returns (bool);

    function setNetworkBeneficiary(address _networkBeneficiary) external;
    function setMarketplaceSettings(address _marketplaceSettings) external;
    function setRoyaltyEngine(address _royaltyEngine) external;
    function setPayments(address _payments) external;
    function setApprovedTokenRegistry(address _approvedTokenRegistry) external;
    function setERC20ApprovalManager(address _erc20ApprovalManager) external;
    function setERC721ApprovalManager(address _erc721ApprovalManager) external;
    function setERC1155ApprovalManager(address _erc1155ApprovalManager) external;
    function setTradeExecutionModule(address _tradeExecutionModule) external;
    function setCheckoutExecutionModule(address _checkoutExecutionModule) external;
    function setContractPaused(bool _isPaused) external;
}
