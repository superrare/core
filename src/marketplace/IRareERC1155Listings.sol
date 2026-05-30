// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {MarketConfigV2} from "../v2/utils/MarketConfigV2.sol";

/// @author SuperRare Labs Inc.
/// @title IRareERC1155Listings
/// @notice Interface for RARE Protocol ERC1155 primary mint sales and ERC1155 fixed-price secondary sales.
/// @dev Primary sales are configured per `(collection, tokenId)`. Secondary listings are approval-based and keyed by `(collection, tokenId, seller)`.
/// Secondary listings remain fillable until sold, cancelled, expired, or made invalid by seller balance,
/// ERC1155 approval, or currency policy.
interface IRareERC1155Listings {
    /// @notice Primary payout data captured before an external collection mint.
    /// @dev Used by implementations to preserve payout inputs across external calls.
    struct PrimaryPayoutContext {
        /// @notice Token id being minted.
        uint256 tokenId;
        /// @notice Gross sale amount before marketplace fee or platform commission.
        uint256 grossAmount;
        /// @notice Buyer-paid marketplace fee calculated for `grossAmount`.
        uint256 marketplaceFee;
        /// @notice Primary seller that receives proceeds after marketplace and platform fees.
        address seller;
        /// @notice Recipients that split seller proceeds.
        address payable[] splitRecipients;
        /// @notice Percentages corresponding to `splitRecipients`.
        uint8[] splitRatios;
    }

    /// @notice Secondary payout data captured before a listing is decremented or deleted.
    /// @dev Used by implementations to preserve payout inputs across external calls and storage mutation.
    struct SecondaryPayoutContext {
        /// @notice Token id being purchased.
        uint256 tokenId;
        /// @notice Gross sale amount before marketplace fee or royalties.
        uint256 grossAmount;
        /// @notice Buyer-paid marketplace fee calculated for `grossAmount`.
        uint256 marketplaceFee;
        /// @notice Recipients that split seller proceeds.
        address payable[] splitRecipients;
        /// @notice Percentages corresponding to `splitRecipients`.
        uint8[] splitRatios;
    }

    /// @notice Primary mint sale configuration for a collection token id.
    struct DirectSaleConfig {
        /// @notice Seller/creator that owns the primary sale and receives sale proceeds.
        address seller;
        /// @notice Currency used for the sale. Zero address indicates ETH.
        address currencyAddress;
        /// @notice Unit price per ERC1155 token.
        uint256 price;
        /// @notice Timestamp when minting may begin.
        uint256 startTime;
        /// @notice Max quantity allowed per mint transaction. Zero means unlimited per transaction.
        uint256 maxMints;
        /// @notice Recipients that split seller proceeds after seller-side fee deductions.
        address payable[] splitRecipients;
        /// @notice Percentages corresponding to `splitRecipients`. Must total 100.
        uint8[] splitRatios;
    }

    /// @notice Merkle allowlist configuration for a token id.
    struct AllowListConfig {
        /// @notice Merkle root for allowed minters. Zero root disables allowlist enforcement.
        bytes32 root;
        /// @notice Timestamp when allowlist enforcement expires.
        uint256 endTimestamp;
    }

    /// @notice Secondary fixed-price listing for an ERC1155 token id.
    /// @dev `expirationTime == 0` means no expiration. Nonzero expiration timestamps are exclusive end times.
    /// Listings persist until filled, cancelled, expired, or invalidated by balance, approval, or currency approval changes.
    struct SalePrice {
        /// @notice Currency accepted by the seller. Zero address indicates ETH.
        address currencyAddress;
        /// @notice Unit price per ERC1155 token.
        uint256 price;
        /// @notice Remaining quantity available for purchase. Allows for partial fills.
        uint256 quantity;
        /// @notice Timestamp when the listing can no longer be filled. Zero means no expiration.
        uint256 expirationTime;
        /// @notice Recipients that split seller proceeds after seller-side fee deductions.
        address payable[] splitRecipients;
        /// @notice Percentages corresponding to `splitRecipients`. Must total 100.
        uint8[] splitRatios;
    }

    /// @notice Primary sale setup input for one token id in a batch.
    struct DirectSaleRequest {
        /// @notice Token id to configure.
        uint256 tokenId;
        /// @notice Unit price per ERC1155 token.
        uint256 price;
        /// @notice Timestamp when minting may begin.
        uint256 startTime;
        /// @notice Max quantity allowed per mint transaction. Zero means unlimited per transaction.
        uint256 maxMints;
    }

    /// @notice Primary mint input for one token id in a batch.
    struct MintRequest {
        /// @notice Token id to mint.
        uint256 tokenId;
        /// @notice Unit price expected by the buyer.
        uint256 price;
        /// @notice Quantity to mint.
        uint256 quantity;
        /// @notice Merkle proof for active allowlist sales.
        bytes32[] proof;
    }

    /// @notice Allowlist setup input for one token id in a batch.
    struct AllowListConfigRequest {
        /// @notice Token id controlled by the allowlist.
        uint256 tokenId;
        /// @notice Merkle root for allowed minters. Zero root disables allowlist enforcement.
        bytes32 root;
        /// @notice Timestamp when allowlist enforcement expires.
        uint256 endTimestamp;
    }

    /// @notice Limit setup input for one token id in a batch.
    struct TokenLimitRequest {
        /// @notice Token id controlled by the limit.
        uint256 tokenId;
        /// @notice New limit value. Zero disables the limit.
        uint256 limit;
    }

    /// @notice Secondary listing setup input for one token id in a batch.
    struct SalePriceRequest {
        /// @notice Token id to list.
        uint256 tokenId;
        /// @notice Unit price per ERC1155 token.
        uint256 price;
        /// @notice Quantity listed.
        uint256 quantity;
        /// @notice Timestamp when the listing can no longer be filled. Zero means no expiration.
        uint256 expirationTime;
    }

    /// @notice Secondary buy input for one token id in a batch.
    struct BuyRequest {
        /// @notice Token id to buy.
        uint256 tokenId;
        /// @notice Unit price expected by the buyer.
        uint256 price;
        /// @notice Quantity to buy.
        uint256 quantity;
    }

    /// @notice Emitted when a creator configures a primary mint sale.
    /// @param contractAddress ERC1155 collection address.
    /// @param tokenId Token id sold by the primary sale.
    /// @param seller Creator/seller that receives sale proceeds.
    /// @param currency Sale currency. Zero address indicates ETH.
    /// @param price Unit price per token.
    /// @param startTime Timestamp when minting may begin.
    /// @param maxMints Max quantity per transaction. Zero means unlimited.
    /// @param splitRecipients Recipients that split seller proceeds.
    /// @param splitRatios Percentages for `splitRecipients`.
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

    /// @notice Emitted when a buyer mints through a primary sale.
    /// @param contractAddress ERC1155 collection address.
    /// @param tokenId Minted token id.
    /// @param buyer Address that paid for and received the mint.
    /// @param seller Creator/seller that received proceeds.
    /// @param quantity Quantity minted.
    /// @param currency Sale currency. Zero address indicates ETH.
    /// @param price Unit price paid.
    event MintDirectSale(
        address indexed contractAddress,
        uint256 indexed tokenId,
        address indexed buyer,
        address seller,
        uint256 quantity,
        address currency,
        uint256 price
    );

    /// @notice Emitted when a token allowlist config is set.
    /// @param contractAddress ERC1155 collection address.
    /// @param tokenId Token id controlled by the allowlist.
    /// @param root Merkle root for allowlisted buyers.
    /// @param endTimestamp Timestamp when allowlist enforcement expires.
    event SetTokenAllowListConfig(
        address indexed contractAddress, uint256 indexed tokenId, bytes32 root, uint256 endTimestamp
    );

    /// @notice Emitted when a per-address mint limit is set for a token id.
    /// @param contractAddress ERC1155 collection address.
    /// @param tokenId Token id controlled by the limit.
    /// @param limit Max quantity each address may mint while the limit is enabled. Zero disables the limit.
    event TokenMintLimitSet(address indexed contractAddress, uint256 indexed tokenId, uint256 limit);

    /// @notice Emitted when a per-address transaction limit is set for a token id.
    /// @param contractAddress ERC1155 collection address.
    /// @param tokenId Token id controlled by the limit.
    /// @param limit Max mint transactions each address may submit while the limit is enabled. Zero disables the limit.
    event TokenTxLimitSet(address indexed contractAddress, uint256 indexed tokenId, uint256 limit);

    /// @notice Emitted when a seller creates or replaces a secondary fixed-price listing.
    /// @param seller Seller that owns the listed ERC1155 balance.
    /// @param contractAddress ERC1155 collection address.
    /// @param tokenId Listed token id.
    /// @param currency Listing currency. Zero address indicates ETH.
    /// @param price Unit price per token.
    /// @param quantity Quantity listed.
    /// @param expirationTime Timestamp when the listing can no longer be filled. Zero means no expiration.
    /// @param splitRecipients Recipients that split seller proceeds.
    /// @param splitRatios Percentages for `splitRecipients`.
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

    /// @notice Emitted when a seller cancels a secondary listing.
    /// @param seller Seller that cancelled the listing.
    /// @param contractAddress ERC1155 collection address.
    /// @param tokenId Token id whose listing was cancelled.
    event SalePriceCancelled(address indexed seller, address indexed contractAddress, uint256 indexed tokenId);

    /// @notice Emitted when a buyer fills a secondary fixed-price listing.
    /// @param seller Seller that transferred the ERC1155 tokens.
    /// @param buyer Buyer that paid and received the ERC1155 tokens.
    /// @param contractAddress ERC1155 collection address.
    /// @param tokenId Purchased token id.
    /// @param currency Purchase currency. Zero address indicates ETH.
    /// @param price Unit price paid.
    /// @param quantity Quantity purchased.
    event Sold(
        address indexed seller,
        address indexed buyer,
        address indexed contractAddress,
        uint256 tokenId,
        address currency,
        uint256 price,
        uint256 quantity
    );

    /// @notice Emitted when an owner updates a critical marketplace dependency.
    /// @param field Config field that was updated.
    /// @param dependency New dependency address.
    event MarketplaceDependencyUpdated(bytes32 indexed field, address indexed dependency);

    /// @notice Emitted when an owner updates marketplace pause state.
    /// @param isPaused True when marketplace writes are paused.
    event ContractPausedUpdated(bool isPaused);

    /// @notice Reverted when a write function is called while the marketplace is paused.
    error ContractPaused();

    /// @notice Reverted when a batch operation receives no items.
    error EmptyBatch();

    /// @notice Reverted when a batch exceeds the supported item count.
    /// @param supplied Number of items supplied.
    /// @param max Maximum supported item count.
    error BatchSizeExceeded(uint256 supplied, uint256 max);

    /// @notice Reverted when token ids are not strictly ascending.
    /// @param index Index of the token id that is not greater than the previous token id.
    /// @param previousTokenId Token id at `index - 1`.
    /// @param tokenId Token id at `index`.
    error TokenIdsNotStrictlyAscending(uint256 index, uint256 previousTokenId, uint256 tokenId);

    /// @notice Reverted when a caller is not the owner of a collection.
    /// @param _contractAddress Collection address whose owner was checked.
    /// @param _account Account that failed the owner check.
    error NotContractOwner(address _contractAddress, address _account);

    /// @notice Reverted when a token id has not been created on a collection.
    /// @param _contractAddress Collection address.
    /// @param _tokenId Missing token id.
    error TokenNotFound(address _contractAddress, uint256 _tokenId);

    /// @notice Reverted when a primary mint is attempted before sale configuration exists.
    /// @param _contractAddress Collection address.
    /// @param _tokenId Token id missing a primary sale config.
    error DirectSaleNotConfigured(address _contractAddress, uint256 _tokenId);

    /// @notice Reverted when a quantity argument is zero.
    error QuantityCannotBeZero();

    /// @notice Reverted when a mint would exceed a buyer's per-address mint limit for a token id.
    /// @param _contractAddress Collection address.
    /// @param _tokenId Token id being minted.
    /// @param _account Buyer account.
    /// @param _requestedQuantity Requested mint quantity.
    /// @param _mintedQuantity Quantity already minted by the account.
    /// @param _limit Configured mint limit.
    error MintLimitExceeded(
        address _contractAddress,
        uint256 _tokenId,
        address _account,
        uint256 _requestedQuantity,
        uint256 _mintedQuantity,
        uint256 _limit
    );

    /// @notice Reverted when a mint would exceed a buyer's per-address transaction limit for a token id.
    /// @param _contractAddress Collection address.
    /// @param _tokenId Token id being minted.
    /// @param _account Buyer account.
    /// @param _usedTransactions Transactions already used by the account.
    /// @param _limit Configured transaction limit.
    error TransactionLimitExceeded(
        address _contractAddress, uint256 _tokenId, address _account, uint256 _usedTransactions, uint256 _limit
    );

    /// @notice Reverted when a mint quantity exceeds the sale's per-transaction max.
    /// @param _requestedQuantity Requested mint quantity.
    /// @param _maxMints Configured max quantity per transaction.
    error MaxMintExceeded(uint256 _requestedQuantity, uint256 _maxMints);

    /// @notice Reverted when a primary mint is attempted before the start time.
    /// @param _startTime Configured sale start timestamp.
    error SaleNotStarted(uint256 _startTime);

    /// @notice Reverted when a currency is neither ETH nor approved by the token registry.
    /// @param _currencyAddress Currency that failed approval.
    error CurrencyNotApproved(address _currencyAddress);

    /// @notice Reverted when an ETH purchase sends the wrong `msg.value`.
    /// @param _requiredAmount Amount required by the marketplace.
    /// @param _suppliedAmount Amount supplied as `msg.value`.
    error IncorrectETHAmount(uint256 _requiredAmount, uint256 _suppliedAmount);

    /// @notice Reverted when ETH is supplied for an ERC20 purchase.
    error MsgValueUnsupportedForERC20();

    /// @notice Reverted when an ERC20 transfer receives less or more than expected.
    /// @param _currencyAddress ERC20 token address.
    /// @param _expectedAmount Amount expected by the marketplace.
    /// @param _receivedAmount Amount actually received by the marketplace.
    error ERC20FeeOnTransferUnsupported(address _currencyAddress, uint256 _expectedAmount, uint256 _receivedAmount);

    /// @notice Reverted when a caller-supplied price does not match the configured price.
    /// @param _suppliedPrice Price supplied by the caller.
    /// @param _configuredPrice Price stored in marketplace configuration.
    error PriceMismatch(uint256 _suppliedPrice, uint256 _configuredPrice);

    /// @notice Reverted when a caller-supplied currency does not match the configured currency.
    /// @param _suppliedCurrency Currency supplied by the caller.
    /// @param _configuredCurrency Currency stored in marketplace configuration.
    error CurrencyMismatch(address _suppliedCurrency, address _configuredCurrency);

    /// @notice Reverted when a free mint includes ETH.
    error MsgValueMustBeZero();

    /// @notice Reverted when a secondary listing price is zero.
    error SalePriceCannotBeZero();

    /// @notice Reverted when a secondary listing expiration is nonzero and not in the future.
    /// @param _expirationTime Expiration supplied for the listing.
    /// @param _currentTime Current block timestamp.
    error SalePriceExpirationInvalid(uint256 _expirationTime, uint256 _currentTime);

    /// @notice Reverted when a secondary collection is not a deployed ERC1155 contract.
    /// @param _contractAddress Collection address that failed validation.
    error InvalidERC1155Contract(address _contractAddress);

    /// @notice Reverted when a buyer tries to fill their own secondary listing.
    /// @param _seller Seller whose listing was targeted.
    error SelfPurchaseUnsupported(address _seller);

    /// @notice Reverted when a seller does not have enough ERC1155 balance for a listing or purchase.
    /// @param _account Account whose balance was checked.
    /// @param _contractAddress ERC1155 collection address.
    /// @param _tokenId Token id whose balance was checked.
    /// @param _requestedQuantity Quantity required by the operation.
    /// @param _availableQuantity Quantity available at check time.
    error InsufficientTokenBalance(
        address _account,
        address _contractAddress,
        uint256 _tokenId,
        uint256 _requestedQuantity,
        uint256 _availableQuantity
    );

    /// @notice Reverted when the marketplace is not approved to transfer a seller's ERC1155 tokens.
    /// @param _account ERC1155 owner that must approve the marketplace.
    /// @param _contractAddress ERC1155 collection address.
    error MarketplaceNotApproved(address _account, address _contractAddress);

    /// @notice Reverted when no secondary listing exists for a seller and token id.
    /// @param _contractAddress ERC1155 collection address.
    /// @param _tokenId Token id requested.
    /// @param _seller Seller whose listing was requested.
    error SalePriceDoesNotExist(address _contractAddress, uint256 _tokenId, address _seller);

    /// @notice Reverted when a buyer tries to fill an expired secondary listing.
    /// @param _contractAddress ERC1155 collection address.
    /// @param _tokenId Token id requested.
    /// @param _seller Seller whose listing was requested.
    /// @param _expirationTime Stored listing expiration timestamp.
    error SalePriceExpired(address _contractAddress, uint256 _tokenId, address _seller, uint256 _expirationTime);

    /// @notice Reverted when a purchase quantity exceeds listed quantity.
    /// @param _requestedQuantity Quantity requested by the buyer.
    /// @param _availableQuantity Quantity currently listed.
    error QuantityExceedsSalePriceQuantity(uint256 _requestedQuantity, uint256 _availableQuantity);

    /// @notice Reverted when an ERC1155 transfer completes without exact seller and buyer balance deltas.
    /// @param _contractAddress ERC1155 collection address.
    /// @param _tokenId Token id transferred.
    /// @param _seller Seller whose balance should decrease.
    /// @param _buyer Buyer whose balance should increase.
    /// @param _quantity Quantity that should be transferred.
    error InvalidERC1155Transfer(
        address _contractAddress, uint256 _tokenId, address _seller, address _buyer, uint256 _quantity
    );

    /// @notice Reverted when royalties returned by the royalty engine exceed sale proceeds.
    /// @param _royalties Total royalties returned by the royalty engine.
    /// @param _saleAmount Gross sale amount before royalty deduction.
    error RoyaltiesExceedSaleAmount(uint256 _royalties, uint256 _saleAmount);

    /// @notice Reverted when the staking fee exceeds the buyer-paid marketplace fee.
    /// @param _marketplaceFee Total marketplace fee collected from the buyer.
    /// @param _stakingFee Staking portion requested by staking settings.
    error StakingFeeExceedsMarketplaceFee(uint256 _marketplaceFee, uint256 _stakingFee);

    /// @notice Reverted when primary platform commission exceeds 100%.
    /// @param _platformCommission Supplied primary platform commission percentage.
    /// @param _maxPlatformCommission Maximum supported platform commission percentage.
    error PlatformCommissionExceeded(uint256 _platformCommission, uint256 _maxPlatformCommission);

    /// @notice Reverted when a sale config has no split recipients.
    error SplitRecipientsRequired();

    /// @notice Reverted when a sale config has more split recipients than supported.
    /// @param _recipientsLength Supplied recipient count.
    /// @param _maxRecipients Maximum supported recipient count.
    error SplitRecipientsExceededMax(uint256 _recipientsLength, uint256 _maxRecipients);

    /// @notice Reverted when split recipient and ratio arrays have different lengths.
    /// @param _recipientsLength Supplied recipient count.
    /// @param _ratiosLength Supplied ratio count.
    error SplitLengthMismatch(uint256 _recipientsLength, uint256 _ratiosLength);

    /// @notice Reverted when a split recipient is the zero address.
    /// @param _index Index of the invalid split recipient.
    error SplitRecipientCannotBeZero(uint256 _index);

    /// @notice Reverted when a split ratio is zero.
    /// @param _index Index of the invalid split ratio.
    error SplitRatioCannotBeZero(uint256 _index);

    /// @notice Reverted when split ratios do not total 100.
    /// @param _totalRatio Supplied ratio total.
    /// @param _requiredTotal Required ratio total.
    error SplitTotalInvalid(uint256 _totalRatio, uint256 _requiredTotal);

    /// @notice Reverted when ETH payout through the Payments contract fails.
    /// @param _revertData Raw revert data returned by the failed payout call.
    error PayoutFailed(bytes _revertData);

    /// @notice Reverted when payout recipients and amounts have different lengths.
    /// @param _recipientsLength Number of payout recipients supplied.
    /// @param _amountsLength Number of payout amounts supplied.
    error PayoutLengthMismatch(uint256 _recipientsLength, uint256 _amountsLength);

    /// @notice Reverted when payout amounts do not sum to the expected batch amount.
    /// @param _expectedAmount Amount expected to be paid by the batch.
    /// @param _actualAmount Sum of supplied payout amounts.
    error PayoutTotalMismatch(uint256 _expectedAmount, uint256 _actualAmount);

    /// @notice Reverted when a buyer is not included in an active allowlist.
    /// @param _account Buyer account that failed allowlist verification.
    error AddressNotAllowlisted(address _account);

    /// @notice Reverted when ownership cannot be read from a collection.
    /// @param _contractAddress Contract that did not expose a valid `owner()`.
    error ContractHasNoOwner(address _contractAddress);

    /// @notice Reverted when an approval manager address is zero.
    error ApprovalManagerCannotBeZero();

    /// @notice Reverted when a required market config dependency address is zero.
    /// @param _field Name of the dependency field that was zero.
    error MarketConfigAddressCannotBeZero(bytes32 _field);

    /// @notice Initializes the UUPS marketplace implementation behind a proxy.
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
    ) external;

    /// @notice Maximum number of token ids accepted by public batch operations.
    /// @return Maximum supported batch item count.
    function MAX_BATCH_SIZE() external pure returns (uint256);

    /// @notice Configures or replaces primary mint sales for token ids.
    /// @dev Request token ids must be strictly ascending. A one-token sale is represented by a one-item batch.
    /// @param _contractAddress ERC1155 collection address.
    /// @param _currencyAddress Sale currency. Zero address indicates ETH.
    /// @param _requests Sale configs to apply.
    /// @param _splitRecipients Recipients that split seller proceeds.
    /// @param _splitRatios Percentages for `splitRecipients`, totaling 100.
    function prepareMintDirectSales(
        address _contractAddress,
        address _currencyAddress,
        DirectSaleRequest[] calldata _requests,
        address payable[] calldata _splitRecipients,
        uint8[] calldata _splitRatios
    ) external;

    /// @notice Mints tokens from configured primary sales.
    /// @dev Request token ids must be strictly ascending. Each token id included in a batch consumes one
    /// transaction against that token's tx limit when the token tx limit is enabled.
    /// @param _contractAddress ERC1155 collection address.
    /// @param _currencyAddress Currency expected by the buyer.
    /// @param _requests Mint requests to execute.
    function mintDirectSaleBatch(address _contractAddress, address _currencyAddress, MintRequest[] calldata _requests)
        external
        payable;

    /// @notice Sets token id allowlist configurations.
    /// @dev Request token ids must be strictly ascending.
    /// @param _contractAddress ERC1155 collection address.
    /// @param _requests Allowlist configs to apply.
    function setTokenAllowListConfigs(address _contractAddress, AllowListConfigRequest[] calldata _requests) external;

    /// @notice Sets the max quantity each address may mint for token ids while the limit is enabled.
    /// @dev Request token ids must be strictly ascending.
    /// @param _contractAddress ERC1155 collection address.
    /// @param _requests Mint limits to apply. Zero disables a token id's limit and disabled periods are not counted.
    function setTokenMintLimits(address _contractAddress, TokenLimitRequest[] calldata _requests) external;

    /// @notice Sets the max number of mint transactions each address may submit for token ids while the limit is enabled.
    /// @dev Request token ids must be strictly ascending.
    /// @param _contractAddress ERC1155 collection address.
    /// @param _requests Transaction limits to apply. Zero disables a token id's limit and disabled periods are not counted.
    function setTokenTxLimits(address _contractAddress, TokenLimitRequest[] calldata _requests) external;

    /// @notice Creates or replaces secondary fixed-price listings.
    /// @dev Request token ids must be strictly ascending. `expirationTime == 0` means no expiration.
    /// Listings can be cancelled by the seller with `cancelSalePrices`.
    /// @param _contractAddress ERC1155 collection address.
    /// @param _currencyAddress Listing currency. Zero address indicates ETH.
    /// @param _requests Listing configs to apply.
    /// @param _splitRecipients Recipients that split seller proceeds.
    /// @param _splitRatios Percentages for `splitRecipients`, totaling 100.
    function setSalePrices(
        address _contractAddress,
        address _currencyAddress,
        SalePriceRequest[] calldata _requests,
        address payable[] calldata _splitRecipients,
        uint8[] calldata _splitRatios
    ) external;

    /// @notice Cancels the caller's secondary listings for token ids.
    /// @dev Token ids must be strictly ascending.
    /// @param _contractAddress ERC1155 collection address.
    /// @param _tokenIds Listed token ids.
    function cancelSalePrices(address _contractAddress, uint256[] calldata _tokenIds) external;

    /// @notice Buys tokens from a seller's secondary fixed-price listings.
    /// @dev Request token ids must be strictly ascending. A one-token buy is represented by a one-item batch.
    /// @param _contractAddress ERC1155 collection address.
    /// @param _seller Seller whose listing is being filled.
    /// @param _currencyAddress Currency expected by the buyer.
    /// @param _requests Buy requests to execute.
    function buyBatch(
        address _contractAddress,
        address _seller,
        address _currencyAddress,
        BuyRequest[] calldata _requests
    ) external payable;

    /// @notice Returns the primary mint sale config for a token id.
    /// @param _contractAddress ERC1155 collection address.
    /// @param _tokenId Token id to inspect.
    /// @return Primary sale config for the token id.
    function getDirectSaleConfig(address _contractAddress, uint256 _tokenId)
        external
        view
        returns (DirectSaleConfig memory);

    /// @notice Returns the allowlist config for a token id.
    /// @param _contractAddress ERC1155 collection address.
    /// @param _tokenId Token id to inspect.
    /// @return Allowlist config for the token id.
    function getTokenAllowListConfig(address _contractAddress, uint256 _tokenId)
        external
        view
        returns (AllowListConfig memory);

    /// @notice Returns the per-address mint quantity limit for a token id.
    /// @param _contractAddress ERC1155 collection address.
    /// @param _tokenId Token id to inspect.
    /// @return Mint quantity limit. Zero means disabled/unlimited.
    function getTokenMintLimit(address _contractAddress, uint256 _tokenId) external view returns (uint256);

    /// @notice Returns quantity minted by an address for a token id while the mint limit was enabled.
    /// @param _contractAddress ERC1155 collection address.
    /// @param _tokenId Token id to inspect.
    /// @param _address Address whose minted quantity is returned.
    /// @return Quantity minted by `_address` during enabled mint-limit periods.
    function getTokenMintsPerAddress(address _contractAddress, uint256 _tokenId, address _address)
        external
        view
        returns (uint256);

    /// @notice Returns the per-address transaction limit for a token id.
    /// @param _contractAddress ERC1155 collection address.
    /// @param _tokenId Token id to inspect.
    /// @return Transaction limit. Zero means disabled/unlimited.
    function getTokenTxLimit(address _contractAddress, uint256 _tokenId) external view returns (uint256);

    /// @notice Returns mint transactions used by an address for a token id while the tx limit was enabled.
    /// @param _contractAddress ERC1155 collection address.
    /// @param _tokenId Token id to inspect.
    /// @param _address Address whose transaction count is returned.
    /// @return Number of mint transactions used by `_address` during enabled tx-limit periods.
    function getTokenTxsPerAddress(address _contractAddress, uint256 _tokenId, address _address)
        external
        view
        returns (uint256);

    /// @notice Returns a seller's secondary fixed-price listing.
    /// @param _contractAddress ERC1155 collection address.
    /// @param _tokenId Token id to inspect.
    /// @param _seller Seller whose listing is returned.
    /// @return Secondary fixed-price listing for the seller and token id.
    function getSalePrice(address _contractAddress, uint256 _tokenId, address _seller)
        external
        view
        returns (SalePrice memory);

    /// @notice Returns the marketplace dependency configuration.
    /// @return Current market config struct.
    function getMarketConfig() external view returns (MarketConfigV2.Config memory);

    /// @notice Returns the ERC1155 approval manager used for secondary transfers.
    /// @return Current ERC1155 approval manager address.
    function getERC1155ApprovalManager() external view returns (address);

    /// @notice Returns whether marketplace writes are paused.
    /// @return True when paused.
    function isPaused() external view returns (bool);

    /// @notice Updates the network beneficiary address.
    /// @param _networkBeneficiary New network beneficiary.
    function setNetworkBeneficiary(address _networkBeneficiary) external;

    /// @notice Updates the marketplace settings contract address.
    /// @param _marketplaceSettings New marketplace settings contract.
    function setMarketplaceSettings(address _marketplaceSettings) external;

    /// @notice Updates the space operator registry address.
    /// @param _spaceOperatorRegistry New space operator registry contract.
    function setSpaceOperatorRegistry(address _spaceOperatorRegistry) external;

    /// @notice Updates the royalty engine address.
    /// @param _royaltyEngine New royalty engine contract.
    function setRoyaltyEngine(address _royaltyEngine) external;

    /// @notice Updates the Payments contract address used for ETH fan-out.
    /// @param _payments New payments contract.
    function setPayments(address _payments) external;

    /// @notice Updates the approved token registry address.
    /// @param _approvedTokenRegistry New approved token registry contract.
    function setApprovedTokenRegistry(address _approvedTokenRegistry) external;

    /// @notice Updates the staking settings address.
    /// @param _stakingSettings New staking settings contract.
    function setStakingSettings(address _stakingSettings) external;

    /// @notice Updates the staking registry address.
    /// @param _stakingRegistry New staking registry contract.
    function setStakingRegistry(address _stakingRegistry) external;

    /// @notice Updates the ERC20 approval manager address.
    /// @param _erc20ApprovalManager New ERC20 approval manager contract.
    function setERC20ApprovalManager(address _erc20ApprovalManager) external;

    /// @notice Updates the ERC721 approval manager address retained by the shared V2 market config.
    /// @param _erc721ApprovalManager New ERC721 approval manager contract.
    function setERC721ApprovalManager(address _erc721ApprovalManager) external;

    /// @notice Updates the ERC1155 approval manager address.
    /// @param _erc1155ApprovalManager New ERC1155 approval manager contract.
    function setERC1155ApprovalManager(address _erc1155ApprovalManager) external;

    /// @notice Pauses or unpauses marketplace write operations.
    /// @param _isPaused New pause state.
    function setContractPaused(bool _isPaused) external;
}
