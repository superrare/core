// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

/// @title SuperRare Cart Storage
/// @notice ERC-7201 namespaces for Cart-owned configuration and execution state.
/// @dev OpenZeppelin upgradeable base contracts retain their own linear storage. Only state
///      declared by Cart lives in these namespaces; append fields to the relevant struct only.
abstract contract CartStorage {
    /// @custom:storage-location erc7201:superrare.storage.CartConfig
    struct Config {
        // Account that signs purchase orders for the platform.
        address platformSigner;
        // Universal Router used for currency conversion routes.
        address universalRouter;
        // Permit2 used to give the Universal Router temporary token access.
        address permit2;
        // WETH used as Cart's internal representation of native currency.
        address weth;
        // Stops new purchases while preserving read access and administrative control.
        bool paused;
        // Receives favorable exact-input output that exceeds signed line obligations.
        address protocolRecipient;
    }

    /// @custom:storage-location erc7201:superrare.storage.CartListings
    struct Listings {
        // Cumulative quantity reserved for each listing digest.
        mapping(bytes32 => uint256) filledQuantity;
        // Current invalidation nonce for each seller's signed listing roots.
        mapping(address => uint256) listingNonces;
        // Seller-controlled cancellation map for complete listing roots.
        mapping(address => mapping(bytes32 => bool)) cancelledListingRoots;
        // Seller-controlled cancellation map for individual listings.
        mapping(address => mapping(bytes32 => bool)) cancelledListings;
    }

    /// @custom:storage-location erc7201:superrare.storage.CartSettlement
    struct Settlement {
        // Prevents a purchase order from being executed more than once.
        mapping(bytes32 => bool) executedOrderIds;
    }

    /// @dev cast index-erc7201 superrare.storage.CartConfig
    bytes32 internal constant CART_CONFIG_LOCATION = 0xc012b0fbebfe5af5b8d952297ba0e80136c8473aa49759c18a1edebf3f3a9b00;

    /// @dev cast index-erc7201 superrare.storage.CartListings
    bytes32 internal constant CART_LISTINGS_LOCATION =
        0xc8a60026949baf9fc493cfe5d84f9acad28caf992be661d90708c137c6ab4d00;

    /// @dev cast index-erc7201 superrare.storage.CartSettlement
    bytes32 internal constant CART_SETTLEMENT_LOCATION =
        0xfc270c27ab1faa9aefd81c2a82301c8d0dada2f8e495ae4b2d6bc4fd8a9cff00;

    function _cartConfig() internal pure returns (Config storage $) {
        assembly {
            // Point the returned storage reference at the fixed ERC-7201 namespace.
            $.slot := CART_CONFIG_LOCATION
        }
    }

    function _cartListings() internal pure returns (Listings storage $) {
        assembly {
            // Point the returned storage reference at the fixed ERC-7201 namespace.
            $.slot := CART_LISTINGS_LOCATION
        }
    }

    function _cartSettlement() internal pure returns (Settlement storage $) {
        assembly {
            // Point the returned storage reference at the fixed ERC-7201 namespace.
            $.slot := CART_SETTLEMENT_LOCATION
        }
    }
}
