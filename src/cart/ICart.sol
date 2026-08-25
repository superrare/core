// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

interface ICart {
    /// @dev Numeric values become part of the signed EIP-712 payload after production deployment.
    enum FulfillmentKind {
        /// @dev The line has no NFT fulfillment.
        NONE,
        /// @dev The item is fulfilled outside the blockchain.
        OFF_CHAIN,
        /// @dev Transfer one existing ERC-721 token from the seller.
        ERC721_TRANSFER,
        /// @dev Transfer ERC-1155 units from the seller.
        ERC1155_TRANSFER,
        /// @dev Mint one ERC-721 token per requested unit.
        ERC721_MINT_TO,
        /// @dev Mint ERC-1155 units to the recipient.
        ERC1155_MINT_TO,
        /// @dev A listing-less fixed currency conversion fulfilled by the order-wide payment route.
        CURRENCY_SWAP
    }

    enum FailureStage {
        /// @dev Cart could not receive the payment.
        FUNDING,
        /// @dev A currency route failed or returned too little.
        ROUTING,
        /// @dev A payout failed or returned too little.
        PAYOUT,
        /// @dev Favorable route execution could not be paid to the protocol.
        SPREAD
    }

    struct Listing {
        /// @dev A seller-chosen identity for this listing instance. Re-listing returned inventory
        /// with the same terms requires a fresh listingId.
        bytes32 listingId;
        /// @dev Seller that owns the listing and signs its root.
        address seller;
        /// @dev Product identity that must match the order line.
        bytes32 sku;
        /// @dev Transfer, mint, or off-chain fulfillment behavior.
        FulfillmentKind fulfillmentKind;
        /// @dev NFT contract used for on-chain fulfillment. Zero for off-chain listings.
        address tokenContract;
        /// @dev Existing NFT id. Minted ERC-721 listings use zero because mint returns the id.
        uint256 tokenId;
        /// @dev Currency that the seller receives for this listing.
        address settlementCurrency;
        /// @dev Lowest accepted total price per unit.
        uint256 minimumUnitPrice;
        /// @dev Zero means the Listing is uncapped; positive values authorize a finite quantity.
        uint256 availableQuantity;
        /// @dev Address that receives the listing payment.
        address paymentRecipient;
    }

    struct OrderLine {
        /// @dev Product identity used by the signed order.
        bytes32 sku;
        /// @dev EIP-712 digest of the listing, or zero for a fee or Currency Swap line.
        bytes32 listingHash;
        /// @dev Explicit fulfillment classification used for settlement and reconciliation.
        FulfillmentKind fulfillmentKind;
        /// @dev Number of units in this line.
        uint256 quantity;
        /// @dev Currency that the line recipient receives.
        address settlementCurrency;
        /// @dev Total signed amount for this line.
        uint256 amount;
        /// @dev Address that receives this line's payment.
        address paymentRecipient;
    }

    struct PayoutRoute {
        /// @dev The complete Universal Router command plan for the order.
        bytes commands;
        /// @dev ABI-encoded input for each command, in the same order as `commands`.
        bytes[] inputs;
        /// @dev Native ETH forwarded from Cart to Universal Router for this plan.
        uint256 routerValue;
    }

    struct FulfillmentAction {
        /// @dev Index of the order line that this action fulfills.
        uint256 lineIndex;
        /// @dev Number of NFT units to transfer or mint.
        uint256 quantity;
        /// @dev Address that receives the NFT units.
        address recipient;
    }

    struct PurchaseOrder {
        /// @dev Unique id that prevents replay.
        bytes32 orderId;
        /// @dev Currency that the payer supplies. Zero means native currency.
        address paymentCurrency;
        /// @dev Last timestamp at which Cart may execute the order.
        uint256 deadline;
        /// @dev Exact amount collected from the transaction caller for the fixed platform quote.
        uint256 paymentAmount;
        /// @dev Hash of the complete OrderLine array.
        bytes32 orderLinesHash;
        /// @dev Hash of the complete order-wide PayoutRoute.
        bytes32 payoutRouteHash;
        /// @dev Hash of the complete FulfillmentAction array.
        bytes32 fulfillmentActionsHash;
    }

    /// @notice A seller-signed Merkle commitment to one or more Listing leaves.
    /// @dev A singleton Listing uses a one-leaf root and an empty proof. The root owns the
    ///      seller's nonce/deadline lifecycle; each Listing is identified by its EIP-712 digest.
    struct ListingRoot {
        bytes32 listingsRoot;
        uint256 nonce;
        uint256 deadline;
    }

    /// @notice Seller Merkle witnesses used by purchase execution.
    /// @dev Listing roots are reusable across independent purchases. The caller supplies each
    ///      selected Listing and its seller authorization proof.
    struct ListingPurchaseAuthorization {
        ListingRoot[] listingRoots;
        bytes[] listingRootSignatures;
        uint256[] listingRootIndexes;
        bytes32[][] listingProofs;
    }

    /// @notice Execution pulls the platform-signed `paymentAmount` from the caller. Native ETH
    ///      also requires the caller to provide the matching `msg.value`.

    event PlatformSignerUpdated(address indexed oldSigner, address indexed newSigner);
    event ContractPausedUpdated(bool paused);
    event ProtocolRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event ProtocolSpreadCaptured(
        bytes32 indexed orderId, address indexed currency, address indexed recipient, uint256 amount
    );
    event ListingRootCancelled(address indexed seller, bytes32 indexed rootDigest);
    event ListingCancelled(address indexed seller, bytes32 indexed listingDigest);
    event ListingNonceInvalidated(address indexed seller, uint256 nonce);
    event PurchaseExecuted(
        bytes32 indexed orderId, address indexed payer, address indexed paymentCurrency, uint256 paymentAmount
    );

    /// @notice Reports the payment and fulfillment result for one order line.
    event OrderLineSettled(
        bytes32 indexed orderId,
        uint256 indexed lineIndex,
        bytes32 indexed sku,
        bytes32 listingHash,
        uint256 quantity,
        address settlementCurrency,
        uint256 amount,
        address paymentRecipient,
        FulfillmentKind fulfillmentKind
    );

    /// @notice Reports one transfer or mint call made for an order line.
    event FulfillmentActionExecuted(
        bytes32 indexed orderId,
        uint256 indexed lineIndex,
        uint256 indexed actionIndex,
        FulfillmentKind fulfillmentKind,
        address target,
        address recipient,
        uint256 quantity,
        uint256 tokenId,
        uint256 unitIndex
    );

    error AlreadyExecuted(bytes32 orderId);
    error ContractPaused();
    error DeadlineExpired(uint256 deadline, uint256 timestamp);
    error DuplicateListingHash(bytes32 listingHash);
    /// @param listingIndex Position of a supplied Listing that no Order Line references.
    error ExtraListing(uint256 listingIndex);
    error InvalidArrayLength();
    error InvalidFulfillmentAction(uint256 actionIndex);
    error InvalidFulfillmentResult(uint256 lineIndex, uint256 actionIndex, bytes result);
    error InvalidFulfillmentActionsHash();
    error InvalidListing();
    error InvalidListingNonce(uint256 expected, uint256 actual);
    error InvalidListingRoot();
    error CancelledListingRoot(bytes32 rootDigest);
    error CancelledListing(bytes32 listingDigest);
    error InvalidMerkleProof(bytes32 root, bytes32 leaf);
    error MerkleProofTooDeep(uint256 listingIndex, uint256 depth);
    error InvalidRootIndex(uint256 index);
    error InvalidOrderId();
    error InvalidOrderLinesHash();
    error InvalidPayoutRouteHash();
    error AllowanceNotCleared(address token, address spender);
    error PreexistingAllowance(address token, address spender, uint256 amount);
    error PreexistingBalanceConsumed(address token, uint256 baseline, uint256 current);
    error UnexpectedCartBalance(address token, uint256 baseline, uint256 current);
    /// @param signer Platform signer or ListingRoot seller whose authorization did not verify.
    error InvalidSignature(address signer, bytes32 digest);
    error ListingNotFound(bytes32 listingHash);
    error ListingQuantityExceeded(bytes32 listingDigest, uint256 available, uint256 requested);
    error ListingTermsMismatch(uint256 lineIndex);
    error MaxFulfillmentOperationsExceeded();
    error NativeValueMismatch();
    error RouteValueWithoutCommands();
    error RouteTooManyCommands(uint256 count);
    error RouteTooManyInputs(uint256 count);
    error OrderLineFailed(uint256 lineIndex, FailureStage stage, bytes reason);
    error FulfillmentActionFailed(uint256 lineIndex, uint256 actionIndex, bytes reason);

    function initialize(
        address owner_,
        address platformSigner_,
        address universalRouter_,
        address permit2_,
        address weth_
    ) external;

    /// @notice Executes a Purchase Order with one order-wide payment route.
    function executePurchase(
        PurchaseOrder calldata order,
        OrderLine[] calldata lines,
        Listing[] calldata listings,
        ListingPurchaseAuthorization calldata authorization,
        PayoutRoute calldata route,
        FulfillmentAction[] calldata actions,
        bytes calldata platformSignature
    ) external payable;

    /// @notice Cancels one seller root digest for future purchases.
    function cancelListingRoot(bytes32 rootDigest) external;
    /// @notice Cancels one seller listing digest for future purchases.
    function cancelListing(bytes32 listingDigest) external;
    /// @notice Invalidates all seller listing roots that use an older nonce.
    function invalidateListingNonce() external;
    /// @notice Changes the signer allowed to authorize purchase orders.
    function setPlatformSigner(address newSigner) external;
    /// @notice Pauses or resumes new purchase execution.
    function setPaused(bool paused) external;
    /// @notice Changes the recipient of favorable route output surplus.
    function setProtocolRecipient(address recipient) external;

    /// @notice EIP-712 domain separator clients hash Listings and Purchase Orders against.
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    /// @notice Returns the account that signs purchase orders.
    function platformSigner() external view returns (address);
    /// @notice Returns the Universal Router used for currency routes.
    function universalRouter() external view returns (address);
    /// @notice Returns the Permit2 contract used for temporary approvals.
    function permit2() external view returns (address);
    /// @notice Returns the WETH contract used for native currency.
    function weth() external view returns (address);
    /// @notice Returns the recipient of favorable route output surplus.
    function protocolRecipient() external view returns (address);
    /// @notice Returns true when new purchase execution is paused.
    function paused() external view returns (bool);
    /// @notice Returns true when an order id has already been executed.
    function executedOrderIds(bytes32 orderId) external view returns (bool);
    /// @notice Cumulative quantity fulfilled for a Listing. Uncapped Listings do not use this value as a limit.
    function filledQuantity(bytes32 listingDigest) external view returns (uint256);
    /// @notice Returns the current seller nonce for listing roots.
    function listingNonces(address seller) external view returns (uint256);
    /// @notice Returns true when the seller cancelled a listing root.
    function cancelledListingRoots(address seller, bytes32 rootDigest) external view returns (bool);
    /// @notice Returns true when the seller cancelled one listing.
    function cancelledListings(address seller, bytes32 listingDigest) external view returns (bool);
}
