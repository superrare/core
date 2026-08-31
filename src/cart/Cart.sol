// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import {SignatureChecker} from "openzeppelin-contracts/utils/cryptography/SignatureChecker.sol";
import {MerkleProof} from "openzeppelin-contracts/utils/cryptography/MerkleProof.sol";
import {EIP712Upgradeable} from "openzeppelin-contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {Initializable} from "openzeppelin-contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "openzeppelin-contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "openzeppelin-contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable} from "openzeppelin-contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {CartHashing} from "./CartHashing.sol";
import {CartPayments} from "./CartPayments.sol";
import {CartStorage} from "./CartStorage.sol";
import {ICart} from "./ICart.sol";
import {ICartPayments} from "./ICartPayments.sol";
import {ICartRoutePolicy} from "./ICartRoutePolicy.sol";

/// @title SuperRare Cart
/// @notice Platform-signed atomic settlement for on-chain and off-chain commerce.
/// @dev The proxy address is the stable EIP-712 verifying contract and NFT approval target.
contract Cart is
    ICart,
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    EIP712Upgradeable,
    UUPSUpgradeable,
    CartStorage
{
    string private constant EIP712_NAME = "SuperRare Cart";
    string private constant EIP712_VERSION = "1";

    uint256 private constant MAX_ORDER_LINES = 20;
    uint256 private constant MAX_FULFILLMENT_OPERATIONS = 20;
    // Keep proof processing bounded even when a caller supplies a malformed witness.
    uint256 private constant MAX_MERKLE_PROOF_DEPTH = 64;
    // Keep each route's command and input arrays bounded before hashing them.
    uint256 private constant MAX_ROUTE_COMMANDS = 32;

    /// @dev Marks an Order Line that references no Listing, such as shipping or platform compensation.
    uint256 private constant NO_LISTING = type(uint256).max;

    /// @notice Immutable route policy for this implementation.
    /// @dev Held outside storage so replacing the policy requires an audited implementation upgrade
    ///      rather than an administrative setter, per ADR 0001.
    ICartRoutePolicy public immutable routePolicy;
    CartPayments private immutable PAYMENT_EXECUTOR;

    constructor(address routePolicy_, address paymentExecutor_) {
        // Store the policy in the implementation bytecode. The proxy reads this same policy after an upgrade.
        routePolicy = ICartRoutePolicy(routePolicy_);
        PAYMENT_EXECUTOR = CartPayments(paymentExecutor_);
        // Block initialization on the implementation. Only the proxy may be initialized.
        _disableInitializers();
    }

    function initialize(
        address owner_,
        address platformSigner_,
        address universalRouter_,
        address permit2_,
        address weth_
    ) external override initializer {
        // Set up the inherited upgradeable modules in the proxy storage.
        __Ownable_init();
        __ReentrancyGuard_init();
        __EIP712_init(EIP712_NAME, EIP712_VERSION);
        __UUPSUpgradeable_init();
        // Give the configured owner permission to pause the contract and authorize upgrades.
        _transferOwnership(owner_);

        // Store the addresses that settlement uses for signatures, routing, and native currency.
        CartStorage.Config storage config = _cartConfig();
        config.platformSigner = platformSigner_;
        config.universalRouter = universalRouter_;
        config.permit2 = permit2_;
        config.weth = weth_;
        config.protocolRecipient = owner_;
    }

    function _authorizeUpgrade(address) internal view override onlyOwner {}

    function platformSigner() public view override returns (address) {
        return _cartConfig().platformSigner;
    }

    function universalRouter() public view override returns (address) {
        return _cartConfig().universalRouter;
    }

    function permit2() public view override returns (address) {
        return _cartConfig().permit2;
    }

    function weth() public view override returns (address) {
        return _cartConfig().weth;
    }

    function protocolRecipient() public view override returns (address) {
        return _cartConfig().protocolRecipient;
    }

    function setProtocolRecipient(address recipient) external override onlyOwner {
        require(recipient != address(0), "zero protocol recipient");
        CartStorage.Config storage config = _cartConfig();
        address oldRecipient = config.protocolRecipient;
        config.protocolRecipient = recipient;
        emit ProtocolRecipientUpdated(oldRecipient, recipient);
    }

    function paused() public view override returns (bool) {
        return _cartConfig().paused;
    }

    function executedOrderIds(bytes32 orderId) public view override returns (bool) {
        return _cartSettlement().executedOrderIds[orderId];
    }

    function filledQuantity(bytes32 listingDigest) public view override returns (uint256) {
        return _cartListings().filledQuantity[listingDigest];
    }

    function listingNonces(address seller) public view override returns (uint256) {
        return _cartListings().listingNonces[seller];
    }

    function cancelledListingRoots(address seller, bytes32 rootDigest) public view override returns (bool) {
        return _cartListings().cancelledListingRoots[seller][rootDigest];
    }

    function cancelledListings(address seller, bytes32 listingDigest) public view override returns (bool) {
        return _cartListings().cancelledListings[seller][listingDigest];
    }

    function executePurchase(
        PurchaseOrder calldata order,
        OrderLine[] calldata lines,
        Listing[] calldata listings,
        ListingPurchaseAuthorization calldata authorization,
        PayoutRoute calldata route,
        FulfillmentAction[] calldata actions,
        bytes calldata platformSignature
    ) external payable override nonReentrant {
        PayoutRoute memory routeCopy = route;
        _executePurchaseCore(
            order,
            lines,
            listings,
            authorization,
            routeCopy,
            CartHashing.hashPayoutRoute(route),
            actions,
            platformSignature
        );
    }

    function _executePurchaseCore(
        PurchaseOrder calldata order,
        OrderLine[] calldata lines,
        Listing[] calldata listings,
        ListingPurchaseAuthorization calldata authorization,
        PayoutRoute memory route,
        bytes32 routeHash,
        FulfillmentAction[] calldata actions,
        bytes calldata platformSignature
    ) private {
        // Reject a purchase before any external call or state change when the contract is paused.
        if (_cartConfig().paused) revert ContractPaused();
        // Require a unique order identifier and a live order deadline.
        if (order.orderId == bytes32(0)) revert InvalidOrderId();
        if (order.deadline < block.timestamp) revert DeadlineExpired(order.deadline, block.timestamp);
        // Marking an order as executed later prevents the same signed order from being used twice.
        if (_cartSettlement().executedOrderIds[order.orderId]) revert AlreadyExecuted(order.orderId);
        // Keep the number of lines bounded. The route is order-wide, not line-indexed.
        if (lines.length == 0 || lines.length > MAX_ORDER_LINES) {
            revert InvalidArrayLength();
        }
        // Every supplied listing must be referenced by at least one order line.
        if (listings.length > lines.length) revert InvalidArrayLength();
        // More roots than listings cannot authorize any additional listing.
        if (authorization.listingRoots.length > listings.length) revert InvalidArrayLength();
        // Every action costs at least one fulfillment operation; larger arrays cannot pass validation.
        if (actions.length > MAX_FULFILLMENT_OPERATIONS) revert InvalidArrayLength();
        // Require one signature for each root, one root index for each listing, and one proof for each listing.
        if (
            authorization.listingRoots.length != authorization.listingRootSignatures.length
                || authorization.listingRootIndexes.length != listings.length
        ) {
            revert InvalidArrayLength();
        }
        if (authorization.listingProofs.length != listings.length || order.paymentAmount == 0) {
            revert InvalidArrayLength();
        }
        // Reject oversized witnesses and route plans before hashing or external policy calls.
        for (uint256 i = 0; i < listings.length; ++i) {
            if (authorization.listingProofs[i].length > MAX_MERKLE_PROOF_DEPTH) {
                revert MerkleProofTooDeep(i, authorization.listingProofs[i].length);
            }
        }
        if (route.commands.length > MAX_ROUTE_COMMANDS) {
            revert RouteTooManyCommands(route.commands.length);
        }
        if (route.inputs.length > MAX_ROUTE_COMMANDS) {
            revert RouteTooManyInputs(route.inputs.length);
        }

        // Hash the order with this proxy as the EIP-712 verifying contract.
        bytes32 orderDigest = _hashTypedDataV4(CartHashing.hashOrderStruct(order));
        // Check that the signed order matches every supplied payload and the platform signature.
        _validateOrderHashes(order, lines, routeHash, actions, platformSignature, orderDigest);
        // Resolve each listing proof to a supplied listing and map each order line to that listing.
        (uint256[] memory lineListing, bytes32[] memory resolvedDigests) =
            _resolveRootListings(lines, listings, authorization);
        // Check listing terms, calculate requested quantities, and check available quantities.
        uint256[] memory listingRequested =
            _validateLineTerms(order.paymentCurrency, lines, listings, lineListing, resolvedDigests);
        // Check that fulfillment actions exactly cover the on-chain items in the order.
        _validateActions(lines, listings, lineListing, actions);
        // Consume the order and reserve listing quantity before external settlement calls.
        _cartSettlement().executedOrderIds[order.orderId] = true;
        _reserveListings(listings, resolvedDigests, listingRequested);

        // Fund and route through the standalone payment executor. The delegatecall preserves Cart
        // custody, storage, msg.sender, and msg.value while keeping payment bytecode out of Cart.
        ICartPayments.PaymentState memory paymentState = _beginPayment(order, lines, route);
        // Transfer or mint each on-chain item to its requested recipient.
        _executeFulfillment(order.orderId, listings, lineListing, actions);
        // Pay grouped recipients, capture protocol spread, and verify all settlement balances.
        _finishPayment(order.orderId, order.paymentCurrency, lines, paymentState);

        // Report the total amount spent and the amount returned to the caller.
        emit PurchaseExecuted(order.orderId, msg.sender, order.paymentCurrency, order.paymentAmount);
        // Report the result of each order line after all settlement work succeeds.
        _emitLineEvents(order.orderId, lines);
    }

    function cancelListingRoot(bytes32 rootDigest) external override nonReentrant {
        // A zero root digest cannot identify a real seller authorization.
        if (rootDigest == bytes32(0)) revert InvalidListingRoot();
        // Cancel only roots owned by the caller.
        _cartListings().cancelledListingRoots[msg.sender][rootDigest] = true;
        emit ListingRootCancelled(msg.sender, rootDigest);
    }

    function cancelListing(bytes32 listingDigest) external override nonReentrant {
        // A zero listing digest cannot identify a real listing.
        if (listingDigest == bytes32(0)) revert InvalidListing();
        // Cancel only listings owned by the caller.
        _cartListings().cancelledListings[msg.sender][listingDigest] = true;
        emit ListingCancelled(msg.sender, listingDigest);
    }

    function invalidateListingNonce() external override nonReentrant {
        // Read the caller's listing state from the Cart namespace.
        CartStorage.Listings storage listings = _cartListings();
        // Move the nonce forward so all older seller roots become invalid.
        listings.listingNonces[msg.sender] += 1;
        emit ListingNonceInvalidated(msg.sender, listings.listingNonces[msg.sender]);
    }

    function setPlatformSigner(address newSigner) external override onlyOwner {
        // Read the current signer so the update event contains both addresses.
        CartStorage.Config storage config = _cartConfig();
        address oldSigner = config.platformSigner;
        config.platformSigner = newSigner;
        emit PlatformSignerUpdated(oldSigner, newSigner);
    }

    function setPaused(bool value) external override onlyOwner {
        // Store the new pause state before announcing it.
        _cartConfig().paused = value;
        emit ContractPausedUpdated(value);
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function DOMAIN_SEPARATOR() external view override returns (bytes32) {
        return _domainSeparatorV4();
    }

    function _resolveRootListings(
        OrderLine[] calldata lines,
        Listing[] calldata listings,
        ListingPurchaseAuthorization calldata authorization
    ) private view returns (uint256[] memory lineListing, bytes32[] memory resolvedDigests) {
        // A purchase with no supplied listings cannot also supply listing roots.
        if (listings.length == 0 && authorization.listingRoots.length != 0) {
            revert InvalidListingRoot();
        }
        // Store the digest for each supplied listing and remember which roots were already checked.
        resolvedDigests = new bytes32[](listings.length);
        bool[] memory rootVerified = new bool[](authorization.listingRoots.length);
        address[] memory rootSellers = new address[](authorization.listingRoots.length);

        for (uint256 i = 0; i < listings.length; ++i) {
            // Select the root that authorizes this listing.
            uint256 rootIndex = authorization.listingRootIndexes[i];
            if (rootIndex >= authorization.listingRoots.length) revert InvalidRootIndex(rootIndex);
            ListingRoot calldata root = authorization.listingRoots[rootIndex];
            // Reject empty and expired seller roots.
            if (root.listingsRoot == bytes32(0)) revert InvalidListingRoot();
            if (root.deadline < block.timestamp) revert DeadlineExpired(root.deadline, block.timestamp);

            Listing calldata listing = listings[i];
            // Create the digest used by the seller cancellation map and the Merkle leaf.
            bytes32 digest = _hashTypedDataV4(CartHashing.hashListingStruct(listing));
            // Check the listing's own shape.
            _validateListing(listing);
            // A seller can cancel one listing without cancelling its entire root.
            if (_cartListings().cancelledListings[listing.seller][digest]) {
                revert CancelledListing(digest);
            }

            if (!rootVerified[rootIndex]) {
                // Check the seller's current nonce before accepting the root.
                uint256 currentNonce = _cartListings().listingNonces[listing.seller];
                if (root.nonce != currentNonce) revert InvalidListingNonce(currentNonce, root.nonce);
                // Hash and check the seller's signature over the root.
                bytes32 rootDigest = _hashTypedDataV4(CartHashing.hashListingRootStruct(root));
                if (_cartListings().cancelledListingRoots[listing.seller][rootDigest]) {
                    revert CancelledListingRoot(rootDigest);
                }
                _requireSignature(listing.seller, rootDigest, authorization.listingRootSignatures[rootIndex]);
                // Cache the result so several listings in one root do not repeat this signature check.
                rootVerified[rootIndex] = true;
                rootSellers[rootIndex] = listing.seller;
            } else if (rootSellers[rootIndex] != listing.seller) {
                // Do not let one root authorize listings from different sellers.
                revert InvalidListingRoot();
            }
            // Check that the seller signed this listing into the selected Merkle root.
            if (!MerkleProof.verifyCalldata(
                    authorization.listingProofs[i], root.listingsRoot, CartHashing.hashListingLeaf(digest)
                )) {
                revert InvalidMerkleProof(root.listingsRoot, CartHashing.hashListingLeaf(digest));
            }

            for (uint256 j = 0; j < i; ++j) {
                // Do not accept the same listing more than once in the supplied array.
                if (resolvedDigests[j] == digest) revert DuplicateListingDigest(digest);
            }
            // Save the verified digest at the listing's array index.
            resolvedDigests[i] = digest;
        }

        // Map each order line to its supplied listing. NO_LISTING means a non-inventory line.
        bool[] memory referenced = new bool[](listings.length);
        lineListing = new uint256[](lines.length);
        for (uint256 i = 0; i < lines.length; ++i) {
            bytes32 target = lines[i].listingDigest;
            if (target == bytes32(0)) {
                // Arbitrary ERC-20 swap lines do not require seller inventory.
                lineListing[i] = NO_LISTING;
                continue;
            }
            // Search the verified listing digests for the digest named by this line.
            uint256 index = NO_LISTING;
            for (uint256 j = 0; j < resolvedDigests.length; ++j) {
                if (resolvedDigests[j] == target) {
                    index = j;
                    break;
                }
            }
            if (index == NO_LISTING) revert ListingNotFound(target);
            // Mark the listing as used by an order line.
            referenced[index] = true;
            lineListing[i] = index;
        }
        for (uint256 i = 0; i < referenced.length; ++i) {
            // Every supplied listing must be used by one order line.
            if (!referenced[i]) revert ExtraListing(i);
        }
    }

    function _validateOrderHashes(
        PurchaseOrder calldata order,
        OrderLine[] calldata lines,
        bytes32 routeHash,
        FulfillmentAction[] calldata actions,
        bytes calldata signature,
        bytes32 orderDigest
    ) private view {
        // Rebuild the signed line hash and compare it with the order envelope.
        if (CartHashing.hashOrderLines(lines) != order.orderLinesHash) {
            revert InvalidOrderLinesHash();
        }
        // Rebuild the signed route hash and compare it with the order envelope.
        if (routeHash != order.payoutRouteHash) revert InvalidPayoutRouteHash();
        // Rebuild the signed fulfillment hash and compare it with the order envelope.
        if (CartHashing.hashFulfillmentActions(actions) != order.fulfillmentActionsHash) {
            revert InvalidFulfillmentActionsHash();
        }
        // Check that the platform authorized this exact order digest.
        _requireSignature(_cartConfig().platformSigner, orderDigest, signature);
    }

    function _validateListing(Listing calldata listing) private view {
        // Require the identity and seller fields that make a listing usable.
        if (listing.listingSalt == bytes32(0) || listing.seller == address(0) || listing.sku == bytes32(0)) {
            revert InvalidListing();
        }
        // Require a payout recipient and a positive minimum unit price.
        if (listing.paymentRecipient == address(0) || listing.minimumUnitPrice == 0) {
            revert InvalidListing();
        }
        if (listing.paymentRecipient == address(this)) revert InvalidPaymentRecipient(listing.paymentRecipient);
        // Currency conversions are platform-authorized Purchase Order lines, never seller Listings.
        if (listing.fulfillmentKind == FulfillmentKind.CURRENCY_SWAP) revert InvalidListing();
        if (!_isOnChainKind(listing.fulfillmentKind)) {
            // Off-chain listings must not carry an NFT contract or token id.
            if (listing.tokenContract != address(0) || listing.tokenId != 0) revert InvalidListing();
        } else if (listing.tokenContract.code.length == 0) {
            // On-chain listings must identify deployed code that performs fulfillment.
            // This rejects EOAs but does not attempt to prove that a contract implements
            // the declared token behavior honestly.
            revert InvalidListing();
        }
        if (_isMintKind(listing.fulfillmentKind) && !_isContractOwner(listing.tokenContract, listing.seller)) {
            revert InvalidMintContractOwner(listing.tokenContract, listing.seller);
        }
        // An ERC-721 transfer can move only one existing token.
        if (
            listing.fulfillmentKind == FulfillmentKind.ERC721_TRANSFER && listing.availableQuantity != 0
                && listing.availableQuantity != 1
        ) {
            revert InvalidListing();
        }
        // An ERC-721 mint returns the new token id, so the listing cannot fix a token id.
        if (listing.fulfillmentKind == FulfillmentKind.ERC721_MINT_TO && listing.tokenId != 0) revert InvalidListing();
    }

    function _isContractOwner(address tokenContract, address expectedOwner) private view returns (bool) {
        (bool success, bytes memory data) = tokenContract.staticcall(abi.encodeWithSignature("owner()"));
        if (!success || data.length < 32) return false;

        uint256 encodedOwner;
        assembly ("memory-safe") {
            encodedOwner := mload(add(data, 0x20))
        }
        return encodedOwner <= type(uint160).max && address(uint160(encodedOwner)) == expectedOwner;
    }

    function _validateLineTerms(
        address paymentCurrency,
        OrderLine[] calldata lines,
        Listing[] calldata listings,
        uint256[] memory lineListing,
        bytes32[] memory listingDigests
    ) private view returns (uint256[] memory requested) {
        // Check each line's required fields first.
        requested = new uint256[](listings.length);
        for (uint256 i = 0; i < lines.length; ++i) {
            OrderLine calldata line = lines[i];
            if (line.sku == bytes32(0) || line.quantity == 0 || line.amount == 0 || line.paymentRecipient == address(0))
            {
                revert InvalidListing();
            }
            if (line.paymentRecipient == address(this)) revert InvalidPaymentRecipient(line.paymentRecipient);
            uint256 listingIndex = lineListing[i];
            // Non-inventory lines explicitly distinguish fees from arbitrary ERC-20 fulfillment.
            if (listingIndex == NO_LISTING) {
                if (
                    line.fulfillmentKind != FulfillmentKind.NONE
                        && line.fulfillmentKind != FulfillmentKind.CURRENCY_SWAP
                ) {
                    revert ListingTermsMismatch(i);
                }
                // A Currency Swap must deliver a currency other than the quoted payment currency.
                if (line.fulfillmentKind == FulfillmentKind.CURRENCY_SWAP && line.settlementCurrency == paymentCurrency)
                revert ListingTermsMismatch(i);
                continue;
            }
            Listing calldata listing = listings[listingIndex];
            // The line must keep the listing's fulfillment, SKU, currency, and payout recipient.
            if (
                line.fulfillmentKind != listing.fulfillmentKind || line.sku != listing.sku
                    || line.settlementCurrency != listing.settlementCurrency
                    || line.paymentRecipient != listing.paymentRecipient
            ) revert ListingTermsMismatch(i);
            // Check the multiplication before calculating the minimum accepted amount.
            if (line.quantity > type(uint256).max / listing.minimumUnitPrice) revert ListingTermsMismatch(i);
            if (line.amount < listing.minimumUnitPrice * line.quantity) revert ListingTermsMismatch(i);
            // Add this line's quantity to the total reserved quantity for the listing.
            if (requested[listingIndex] > type(uint256).max - line.quantity) revert InvalidListing();
            requested[listingIndex] += line.quantity;
        }
        for (uint256 i = 0; i < listings.length; ++i) {
            uint256 available = listings[i].availableQuantity;
            if (available != 0) {
                // A non-zero available quantity is a cap. Zero means the listing is uncapped.
                bytes32 listingDigest = listingDigests[i];
                uint256 alreadyFilled = _cartListings().filledQuantity[listingDigest];
                uint256 remaining = alreadyFilled >= available ? 0 : available - alreadyFilled;
                // Compare this purchase with the quantity that remains under the cap.
                if (requested[i] > remaining) {
                    revert ListingQuantityExceeded(listingDigest, remaining, requested[i]);
                }
            }
        }
    }

    function _validateActions(
        OrderLine[] calldata lines,
        Listing[] calldata listings,
        uint256[] memory lineListing,
        FulfillmentAction[] calldata actions
    ) private pure {
        // Track how much each line's on-chain listing will fulfill.
        uint256[] memory quantities = new uint256[](lines.length);
        uint256 operations;
        for (uint256 i = 0; i < actions.length; ++i) {
            FulfillmentAction calldata action = actions[i];
            // Check the action index, quantity, and recipient before reading the line.
            if (action.lineIndex >= lines.length || action.quantity == 0 || action.recipient == address(0)) {
                revert InvalidFulfillmentAction(i);
            }
            uint256 listingIndex = lineListing[action.lineIndex];
            // A fulfillment action must point to an on-chain listing.
            if (listingIndex == NO_LISTING) revert InvalidFulfillmentAction(i);
            FulfillmentKind kind = listings[listingIndex].fulfillmentKind;
            if (!_isOnChainKind(kind)) revert InvalidFulfillmentAction(i);
            // An ERC-721 transfer is one transfer of one token. It cannot appear twice.
            if (kind == FulfillmentKind.ERC721_TRANSFER && (action.quantity != 1 || quantities[action.lineIndex] != 0))
            {
                revert InvalidFulfillmentAction(i);
            }
            // Add the action quantity and reject arithmetic overflow.
            if (quantities[action.lineIndex] > type(uint256).max - action.quantity) {
                revert InvalidFulfillmentAction(i);
            }
            quantities[action.lineIndex] += action.quantity;

            // Each ERC-721 mint unit is its own call; every other kind settles in one call.
            uint256 cost = kind == FulfillmentKind.ERC721_MINT_TO ? action.quantity : 1;
            // Limit the total number of external fulfillment calls in one purchase.
            if (cost > MAX_FULFILLMENT_OPERATIONS || operations > MAX_FULFILLMENT_OPERATIONS - cost) {
                revert MaxFulfillmentOperationsExceeded();
            }
            operations += cost;
        }
        for (uint256 i = 0; i < lines.length; ++i) {
            // On-chain lines must be fully covered. Off-chain and ERC-20 swap lines have no action.
            uint256 listingIndex = lineListing[i];
            uint256 expected = listingIndex != NO_LISTING && _isOnChainKind(listings[listingIndex].fulfillmentKind)
                ? lines[i].quantity
                : 0;
            if (quantities[i] != expected) revert InvalidFulfillmentAction(i);
        }
    }

    function _reserveListings(
        Listing[] calldata listings,
        bytes32[] memory resolvedDigests,
        uint256[] memory requested
    ) private {
        CartStorage.Listings storage listingState = _cartListings();
        for (uint256 i = 0; i < listings.length; ++i) {
            if (requested[i] != 0) {
                // Reserve the requested quantity before calling external token contracts.
                listingState.filledQuantity[resolvedDigests[i]] += requested[i];
            }
        }
    }

    function _beginPayment(PurchaseOrder calldata order, OrderLine[] calldata lines, PayoutRoute memory route)
        private
        returns (ICartPayments.PaymentState memory state)
    {
        (bool success, bytes memory result) =
            address(PAYMENT_EXECUTOR).delegatecall(abi.encodeCall(ICartPayments.begin, (order, lines, route)));
        if (!success) _bubble(result);
        state = abi.decode(result, (ICartPayments.PaymentState));
    }

    function _finishPayment(
        bytes32 orderId,
        address paymentCurrency,
        OrderLine[] calldata lines,
        ICartPayments.PaymentState memory state
    ) private {
        (bool success, bytes memory result) = address(PAYMENT_EXECUTOR)
            .delegatecall(abi.encodeCall(ICartPayments.finish, (orderId, paymentCurrency, lines, state)));
        if (!success) _bubble(result);
    }

    function _bubble(bytes memory reason) private pure {
        /// @solidity memory-safe-assembly
        assembly {
            revert(add(reason, 0x20), mload(reason))
        }
    }

    function _executeFulfillment(
        bytes32 orderId,
        Listing[] calldata listings,
        uint256[] memory lineListing,
        FulfillmentAction[] calldata actions
    ) private {
        for (uint256 i = 0; i < actions.length; ++i) {
            FulfillmentAction calldata action = actions[i];
            Listing calldata listing = listings[lineListing[action.lineIndex]];
            FulfillmentKind kind = listing.fulfillmentKind;

            bytes memory callData;
            if (kind == FulfillmentKind.ERC721_TRANSFER) {
                // Build a safe ERC-721 transfer from the seller to the requested recipient.
                callData = abi.encodeWithSelector(
                    bytes4(keccak256("safeTransferFrom(address,address,uint256)")),
                    listing.seller,
                    action.recipient,
                    listing.tokenId
                );
            } else if (kind == FulfillmentKind.ERC1155_TRANSFER) {
                // Build a safe ERC-1155 transfer for the requested quantity.
                callData = abi.encodeWithSelector(
                    bytes4(keccak256("safeTransferFrom(address,address,uint256,uint256,bytes)")),
                    listing.seller,
                    action.recipient,
                    listing.tokenId,
                    action.quantity,
                    bytes("")
                );
            } else if (kind == FulfillmentKind.ERC721_MINT_TO) {
                // Build the mint call for one ERC-721 unit.
                callData = abi.encodeWithSignature("mintTo(address)", action.recipient);
            } else if (kind == FulfillmentKind.ERC1155_MINT_TO) {
                // Build the mint call for the requested ERC-1155 quantity.
                callData = abi.encodeWithSignature(
                    "mintTo(address,uint256,uint256)", action.recipient, listing.tokenId, action.quantity
                );
            } else {
                revert InvalidListing();
            }

            // `mintTo(address)` carries no quantity, so an ERC-721 mint repeats once per unit.
            uint256 repeats = kind == FulfillmentKind.ERC721_MINT_TO ? action.quantity : 1;
            for (uint256 unit = 0; unit < repeats; ++unit) {
                // Call the seller's token contract to perform this fulfillment unit.
                (bool success, bytes memory result) = listing.tokenContract.call(callData);
                if (!success) revert FulfillmentActionFailed(action.lineIndex, i, result);

                // Use the listed token data for transfers and ERC-1155 mints.
                uint256 fulfilledTokenId = listing.tokenId;
                uint256 fulfilledQuantity = action.quantity;
                if (kind == FulfillmentKind.ERC721_MINT_TO) {
                    // Decode the new token id returned by the ERC-721 mint call.
                    if (result.length < 32) revert InvalidFulfillmentResult(action.lineIndex, i, result);
                    fulfilledTokenId = abi.decode(result, (uint256));
                    fulfilledQuantity = 1;
                }
                // Report the exact unit that the token contract fulfilled.
                emit FulfillmentActionExecuted(
                    orderId,
                    action.lineIndex,
                    i,
                    kind,
                    listing.tokenContract,
                    action.recipient,
                    fulfilledQuantity,
                    fulfilledTokenId,
                    unit
                );
            }
        }
    }

    function _emitLineEvents(bytes32 orderId, OrderLine[] calldata lines) private {
        for (uint256 i = 0; i < lines.length; ++i) {
            // The signed line classification is authoritative and has already been matched to its listing.
            FulfillmentKind fulfillmentKind = lines[i].fulfillmentKind;
            emit OrderLineSettled(
                orderId,
                i,
                lines[i].sku,
                lines[i].listingDigest,
                lines[i].quantity,
                lines[i].settlementCurrency,
                lines[i].amount,
                lines[i].paymentRecipient,
                fulfillmentKind
            );
        }
    }

    function _requireSignature(address signer, bytes32 digest, bytes calldata signature) private view {
        // Accept both EOA signatures and contract-wallet signatures supported by SignatureChecker.
        if (!SignatureChecker.isValidSignatureNow(signer, digest, signature)) revert InvalidSignature(signer, digest);
    }

    function _currencyToken(address currency, address wrappedNative) private pure returns (address) {
        // Use WETH as the internal token representation for native currency.
        return currency == address(0) ? wrappedNative : currency;
    }

    function _isOnChainKind(FulfillmentKind kind) private pure returns (bool) {
        // These fulfillment kinds call an NFT contract during settlement.
        return kind == FulfillmentKind.ERC721_TRANSFER || kind == FulfillmentKind.ERC1155_TRANSFER
            || kind == FulfillmentKind.ERC721_MINT_TO || kind == FulfillmentKind.ERC1155_MINT_TO;
    }

    function _isMintKind(FulfillmentKind kind) private pure returns (bool) {
        // These fulfillment kinds create a new token instead of transferring an existing token.
        return kind == FulfillmentKind.ERC721_MINT_TO || kind == FulfillmentKind.ERC1155_MINT_TO;
    }

    receive() external payable {}
}
