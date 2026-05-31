// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

/// @author SuperRare Labs Inc.
/// @title IRareERC1155MarketplaceTypes
/// @notice Shared structs, events, and errors for the ERC1155 marketplace.
interface IRareERC1155MarketplaceTypes {
    /// @notice Primary mint sale configuration for a collection token id.
    struct DirectSaleConfig {
        address seller;
        address currencyAddress;
        uint256 price;
        uint256 startTime;
        uint256 maxMints;
        address payable[] splitRecipients;
        uint8[] splitRatios;
    }

    /// @notice Merkle allowlist configuration for a token id.
    struct AllowListConfig {
        bytes32 root;
        uint256 endTimestamp;
    }

    /// @notice Secondary fixed-price listing for an ERC1155 token id.
    /// @dev `expirationTime == 0` means no expiration. Listings allow partial fills.
    struct SalePrice {
        address currencyAddress;
        uint256 price;
        uint256 quantity;
        uint256 expirationTime;
        address payable[] splitRecipients;
        uint8[] splitRatios;
    }

    /// @notice Token-level ERC1155 offer state.
    /// @dev Offers are escrowed and keyed by `(collection, tokenId, buyer, currency)`.
    struct Offer {
        address currencyAddress;
        uint256 price;
        uint256 quantity;
        uint256 marketplaceFeeRemaining;
        uint256 expirationTime;
    }

    /// @notice Primary sale setup input for one token id in a batch.
    struct DirectSaleRequest {
        uint256 tokenId;
        uint256 price;
        uint256 startTime;
        uint256 maxMints;
    }

    /// @notice Primary mint input for one token id in a batch.
    struct MintRequest {
        uint256 tokenId;
        uint256 price;
        uint256 quantity;
        bytes32[] proof;
    }

    /// @notice Allowlist setup input for one token id in a batch.
    struct AllowListConfigRequest {
        uint256 tokenId;
        bytes32 root;
        uint256 endTimestamp;
    }

    /// @notice Limit setup input for one token id in a batch.
    struct TokenLimitRequest {
        uint256 tokenId;
        uint256 limit;
    }

    /// @notice Secondary listing setup input for one token id in a batch.
    struct SalePriceRequest {
        uint256 tokenId;
        uint256 price;
        uint256 quantity;
        uint256 expirationTime;
    }

    /// @notice Secondary buy input for one token id in a batch.
    struct BuyRequest {
        uint256 tokenId;
        uint256 price;
        uint256 quantity;
    }

    enum CheckoutItemKind {
        DIRECT_SALE_MINT,
        LISTING_BUY
    }

    /// @notice Buyer cart item for primary mint sales and secondary fixed-price listings.
    /// @dev `itemKind` uses `CheckoutItemKind` values and is kept as uint8 so unknown future kinds can be skipped.
    struct CheckoutItem {
        uint8 itemKind;
        address contractAddress;
        address seller;
        address currencyAddress;
        uint256 tokenId;
        uint256 price;
        uint256 quantity;
        bytes32[] proof;
    }

    struct CheckoutSummary {
        uint256 filledCount;
        uint256 skippedCount;
        uint256 ethSpent;
        uint256 ethRefunded;
    }

    event MarketplaceDependencyUpdated(bytes32 indexed field, address indexed dependency);
    event ContractPausedUpdated(bool isPaused);

    event PrepareMintDirectSale(
        address indexed contractAddress,
        uint256 indexed tokenId,
        address indexed seller,
        address currency,
        uint256 price,
        uint256 startTime,
        uint256 maxMints,
        address payable[] splitRecipients,
        uint8[] splitRatios
    );

    event MintDirectSale(
        address indexed contractAddress,
        uint256 indexed tokenId,
        address indexed buyer,
        address seller,
        uint256 quantity,
        address currency,
        uint256 price
    );

    event SetTokenAllowListConfig(
        address indexed contractAddress, uint256 indexed tokenId, bytes32 root, uint256 endTimestamp
    );

    event TokenMintLimitSet(address indexed contractAddress, uint256 indexed tokenId, uint256 limit);
    event TokenTxLimitSet(address indexed contractAddress, uint256 indexed tokenId, uint256 limit);

    event SalePriceSet(
        address indexed seller,
        address indexed contractAddress,
        uint256 indexed tokenId,
        address currency,
        uint256 price,
        uint256 quantity,
        uint256 expirationTime,
        address payable[] splitRecipients,
        uint8[] splitRatios
    );

    event SalePriceCancelled(address indexed seller, address indexed contractAddress, uint256 indexed tokenId);

    event Sold(
        address indexed seller,
        address indexed buyer,
        address indexed contractAddress,
        uint256 tokenId,
        address currency,
        uint256 price,
        uint256 quantity
    );

    event OfferMade(
        address indexed buyer,
        address indexed contractAddress,
        uint256 indexed tokenId,
        address currency,
        uint256 price,
        uint256 quantity,
        uint256 marketplaceFee,
        uint256 expirationTime
    );

    event OfferCancelled(
        address indexed buyer,
        address indexed contractAddress,
        uint256 indexed tokenId,
        address currency,
        uint256 price,
        uint256 quantity,
        uint256 marketplaceFeeRemaining
    );

    event OfferAccepted(
        address indexed seller,
        address indexed buyer,
        address indexed contractAddress,
        uint256 tokenId,
        address currency,
        uint256 price,
        uint256 quantity
    );

    event CheckoutItemFilled(
        uint256 indexed itemIndex,
        uint8 indexed itemKind,
        address indexed contractAddress,
        uint256 tokenId,
        address seller,
        address currency,
        uint256 price,
        uint256 quantity,
        uint256 totalPaid
    );

    event CheckoutItemSkipped(
        uint256 indexed itemIndex,
        uint8 indexed itemKind,
        address indexed contractAddress,
        uint256 tokenId,
        bytes4 reason
    );

    event CheckoutCompleted(
        address indexed buyer, uint256 filledCount, uint256 skippedCount, uint256 ethSpent, uint256 ethRefunded
    );

    error ContractPaused();
    error EmptyBatch();
    error BatchSizeExceeded(uint256 supplied, uint256 max);
    error TokenIdsNotStrictlyAscending(uint256 index, uint256 previousTokenId, uint256 tokenId);
    error NotContractOwner(address _contractAddress, address _account);
    error TokenNotFound(address _contractAddress, uint256 _tokenId);
    error DirectSaleNotConfigured(address _contractAddress, uint256 _tokenId);
    error QuantityCannotBeZero();
    error MintLimitExceeded(
        address _contractAddress,
        uint256 _tokenId,
        address _account,
        uint256 _requestedQuantity,
        uint256 _mintedQuantity,
        uint256 _limit
    );
    error TransactionLimitExceeded(
        address _contractAddress, uint256 _tokenId, address _account, uint256 _usedTransactions, uint256 _limit
    );
    error MaxMintExceeded(uint256 _requestedQuantity, uint256 _maxMints);
    error SaleNotStarted(uint256 _startTime);
    error PriceMismatch(uint256 _suppliedPrice, uint256 _configuredPrice);
    error CurrencyMismatch(address _suppliedCurrency, address _configuredCurrency);
    error SalePriceCannotBeZero();
    error SalePriceExpirationInvalid(uint256 _expirationTime, uint256 _currentTime);
    error InvalidERC1155Contract(address _contractAddress);
    error SelfPurchaseUnsupported(address _seller);
    error InsufficientTokenBalance(
        address _account,
        address _contractAddress,
        uint256 _tokenId,
        uint256 _requestedQuantity,
        uint256 _availableQuantity
    );
    error MarketplaceNotApproved(address _account, address _contractAddress);
    error SalePriceDoesNotExist(address _contractAddress, uint256 _tokenId, address _seller);
    error SalePriceExpired(address _contractAddress, uint256 _tokenId, address _seller, uint256 _expirationTime);
    error QuantityExceedsSalePriceQuantity(uint256 _requestedQuantity, uint256 _availableQuantity);
    error InvalidERC1155Transfer(
        address _contractAddress, uint256 _tokenId, address _seller, address _buyer, uint256 _quantity
    );
    error AddressNotAllowlisted(address _account);
    error ContractHasNoOwner(address _contractAddress);
    error ApprovalManagerCannotBeZero();
    error MarketConfigAddressCannotBeZero(bytes32 _field);
    error SettlementCannotBeZero();
    error DirectSettlementCallUnsupported();
    error SettlementDelegateCallFailed(bytes _revertData);
    error UnsupportedCheckoutItemKind(uint8 _itemKind);
    error CheckoutRequiresSuccessfulFill();
    error CheckoutSellerMismatch(address _suppliedSeller, address _configuredSeller);
    error InsufficientCheckoutETH(uint256 _requiredAmount, uint256 _availableAmount);
    error InsufficientCheckoutERC20Balance(address _currencyAddress, uint256 _requiredAmount, uint256 _availableAmount);
    error InsufficientCheckoutERC20Allowance(
        address _currencyAddress, uint256 _requiredAmount, uint256 _availableAmount
    );
    error OfferPriceCannotBeZero();
    error OfferExpirationInvalid(uint256 _expirationTime, uint256 _currentTime);
    error SelfOfferAcceptanceUnsupported(address _buyer);
    error OfferDoesNotExist(address _contractAddress, uint256 _tokenId, address _buyer, address _currencyAddress);
    error OfferExpired(
        address _contractAddress, uint256 _tokenId, address _buyer, address _currencyAddress, uint256 _expirationTime
    );
    error QuantityExceedsOfferQuantity(uint256 _requestedQuantity, uint256 _availableQuantity);

    error CurrencyNotApproved(address _currencyAddress);
    error IncorrectETHAmount(uint256 _requiredAmount, uint256 _suppliedAmount);
    error MsgValueUnsupportedForERC20();
    error ERC20FeeOnTransferUnsupported(address _currencyAddress, uint256 _expectedAmount, uint256 _receivedAmount);
    error MsgValueMustBeZero();
    error RoyaltiesExceedSaleAmount(uint256 _royalties, uint256 _saleAmount);
    error StakingFeeExceedsMarketplaceFee(uint256 _marketplaceFee, uint256 _stakingFee);
    error PlatformCommissionExceeded(uint256 _platformCommission, uint256 _maxPlatformCommission);
    error SplitRecipientsRequired();
    error SplitRecipientsExceededMax(uint256 _recipientsLength, uint256 _maxRecipients);
    error SplitLengthMismatch(uint256 _recipientsLength, uint256 _ratiosLength);
    error SplitRecipientCannotBeZero(uint256 _index);
    error SplitRatioCannotBeZero(uint256 _index);
    error SplitTotalInvalid(uint256 _totalRatio, uint256 _requiredTotal);
    error PayoutFailed(bytes _revertData);
    error RefundFailed(bytes _revertData);
    error PayoutLengthMismatch(uint256 _recipientsLength, uint256 _amountsLength);
    error PayoutTotalMismatch(uint256 _expectedAmount, uint256 _actualAmount);
}
