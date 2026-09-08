// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import {ICart} from "./ICart.sol";

/// @dev The subset of Cart's generated public getters used by the lens. Cart does not need to
///      inherit this interface; the ABI is sufficient for the stateless read boundary.
interface ICartLensTarget {
    /// @notice Returns whether Cart has paused purchase execution.
    function paused() external view returns (bool);
    /// @notice Returns the current platform signer.
    function platformSigner() external view returns (address);
    /// @notice Returns the immutable route policy address.
    function routePolicy() external view returns (address);
    /// @notice Returns whether the seller cancelled one listing.
    function cancelledListings(address seller, bytes32 listingDigest) external view returns (bool);
    /// @notice Returns the EIP-712 domain separator used by Cart.
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

/// @notice Read-only integration surface for Cart state and preflight checks.
/// @dev Cart remains the source of truth. Lens results are advisory and execution must always
///      revalidate the supplied payload.
interface ICartLens {
    enum ValidationCode {
        OK,
        CART_PAUSED,
        ORDER_DEADLINE_EXPIRED,
        ORDER_ALREADY_EXECUTED,
        INVALID_ARRAY_LENGTH,
        INVALID_ORDER_LINE,
        ZERO_PAYMENT_AMOUNT,
        INVALID_ORDER_LINES_HASH,
        INVALID_PAYOUT_ROUTE_HASH,
        INVALID_FULFILLMENT_ACTIONS_HASH,
        INVALID_PLATFORM_SIGNATURE,
        INVALID_LISTING,
        INVALID_LISTING_NONCE,
        LISTING_QUANTITY_EXCEEDED,
        ASSET_UNAVAILABLE,
        ROUTE_REJECTED,
        INVALID_ROOT,
        INVALID_ROOT_SIGNATURE,
        INVALID_MERKLE_PROOF,
        INVALID_ORDER_ID,
        LISTING_CANCELLED
    }

    struct ValidationResult {
        /// @dev True only when all checks passed.
        bool valid;
        /// @dev Stable reason code for the result.
        ValidationCode code;
        /// @dev Line or action index related to the result.
        uint256 index;
        /// @dev Order or listing related to the result.
        bytes32 subject;
        /// @dev ABI-encoded details for the result, when available.
        bytes reason;
    }

    struct ListingStatus {
        /// @dev Seller nonce read from Cart.
        uint256 currentNonce;
        /// @dev Quantity already filled for the listing digest.
        uint256 filledQuantity;
        /// @dev Quantity still available under the listing cap.
        uint256 remainingQuantity;
        /// @dev True when the listing has no quantity cap.
        bool uncapped;
        /// @dev True when the root nonce matches the seller nonce.
        bool nonceValid;
        /// @dev True when the root deadline has not passed.
        bool deadlineValid;
        /// @dev True when the root or listing was cancelled.
        bool cancelled;
        /// @dev True when all status checks allow a purchase.
        bool active;
    }

    struct RoutePreview {
        /// @dev True when the shallow route policy accepts the command program.
        bool valid;
        /// @dev Stable reason code for the route result.
        ValidationCode code;
        /// @dev Policy revert data or encoded local structural error details.
        bytes reason;
    }

    /// @notice Returns root lifecycle and quantity state for a Listing leaf.
    function listingStatus(address cart, ICart.Listing calldata listing, ICart.ListingRoot calldata root)
        external
        view
        returns (ListingStatus memory status);

    /// @notice Validates the Cart-level Purchase Order envelope without executing it.
    /// @dev This covers checks that do not require resolving and executing every Listing action.
    ///      Funding is always taken from the transaction caller during execution.
    function validatePurchaseEnvelope(
        address cart,
        ICart.PurchaseOrder calldata order,
        ICart.OrderLine[] calldata lines,
        ICart.PayoutRoute calldata route,
        ICart.FulfillmentAction[] calldata actions,
        bytes calldata platformSignature
    ) external view returns (ValidationResult memory result);

    /// @notice Validates a Listing leaf, its root authorization, and current local state.
    /// @dev This is a preflight helper. Cart execution remains authoritative.
    function validateListing(
        address cart,
        ICart.Listing calldata listing,
        ICart.ListingRoot calldata root,
        bytes calldata rootSignature,
        bytes32[] calldata proof,
        uint256 requestedQuantity
    ) external view returns (ValidationResult memory result);

    /// @notice Checks only the shallow command-family structure of an order-wide route.
    function previewRoute(address cart, ICart.PayoutRoute calldata route)
        external
        view
        returns (RoutePreview memory preview);
}
