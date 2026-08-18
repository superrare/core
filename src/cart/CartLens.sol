// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import {IERC721} from "openzeppelin-contracts/token/ERC721/IERC721.sol";
import {IERC1155} from "openzeppelin-contracts/token/ERC1155/IERC1155.sol";
import {ECDSA} from "openzeppelin-contracts/utils/cryptography/ECDSA.sol";
import {MerkleProof} from "openzeppelin-contracts/utils/cryptography/MerkleProof.sol";
import {SignatureChecker} from "openzeppelin-contracts/utils/cryptography/SignatureChecker.sol";

import {CartHashing} from "./CartHashing.sol";
import {ICart} from "./ICart.sol";
import {ICartLens, ICartLensTarget} from "./ICartLens.sol";
import {ICartRoutePolicy} from "./ICartRoutePolicy.sol";

/// @title SuperRare Cart Lens
/// @notice Stateless read and preflight helpers for Cart integrations.
/// @dev This contract deliberately owns no state and is never called by Cart settlement. Its
///      results are advisory; executePurchase remains the authoritative validation boundary.
contract CartLens is ICartLens {
    // Keep preflight bounds aligned with Cart's authoritative execution limits.
    uint256 private constant MAX_FULFILLMENT_OPERATIONS = 20;
    uint256 private constant MAX_MERKLE_PROOF_DEPTH = 64;
    uint256 private constant MAX_ROUTE_COMMANDS = 32;

    function listingStatus(address cart, ICart.Listing calldata listing, ICart.ListingRoot calldata root)
        external
        view
        override
        returns (ListingStatus memory status)
    {
        // Use the Cart interfaces to read current seller and settlement state.
        ICart target = ICart(cart);
        status.currentNonce = target.listingNonces(listing.seller);
        // Build the listing digest with the Cart domain separator.
        bytes32 listingDigest =
            _typedDataHash(ICartLensTarget(cart).DOMAIN_SEPARATOR(), CartHashing.hashListingStruct(listing));
        // Read the quantity already filled for this listing.
        status.filledQuantity = target.filledQuantity(listingDigest);
        // Convert zero available quantity into an uncapped listing state.
        status.uncapped = listing.availableQuantity == 0;
        status.remainingQuantity = status.uncapped
            ? type(uint256).max
            : status.filledQuantity >= listing.availableQuantity ? 0 : listing.availableQuantity - status.filledQuantity;
        // Compare the root nonce and deadline with the current chain state.
        status.nonceValid = root.nonce == status.currentNonce;
        status.deadlineValid = root.deadline >= block.timestamp;
        // Build the root digest and check both root-level and listing-level cancellation.
        bytes32 rootDigest =
            _typedDataHash(ICartLensTarget(cart).DOMAIN_SEPARATOR(), CartHashing.hashListingRootStruct(root));
        status.cancelled = target.cancelledListingRoots(listing.seller, rootDigest)
            || ICartLensTarget(cart).cancelledListings(listing.seller, listingDigest);
        // A listing is active only when its authorization, deadline, cancellation, and quantity checks pass.
        status.active = status.nonceValid && status.deadlineValid && !status.cancelled
            && (status.uncapped || status.remainingQuantity != 0);
    }

    function validateListing(
        address cart,
        ICart.Listing calldata listing,
        ICart.ListingRoot calldata root,
        bytes calldata rootSignature,
        bytes32[] calldata proof,
        uint256 requestedQuantity
    ) external view override returns (ValidationResult memory result) {
        ICart target = ICart(cart);
        ICartLensTarget config = ICartLensTarget(cart);
        // Check the listing's required identity and payout fields.
        if (listing.listingId == bytes32(0) || listing.seller == address(0) || listing.sku == bytes32(0)) {
            return _failure(ValidationCode.INVALID_LISTING, 0, bytes32(0), "");
        }
        if (listing.paymentRecipient == address(0) || listing.minimumUnitPrice == 0) {
            return _failure(ValidationCode.INVALID_LISTING, 0, bytes32(0), "");
        }
        if (root.listingsRoot == bytes32(0)) {
            return _failure(ValidationCode.INVALID_ROOT, 0, bytes32(0), "");
        }
        // Check the seller root nonce against the current Cart nonce.
        uint256 currentNonce = target.listingNonces(listing.seller);
        if (root.nonce != currentNonce) {
            return _failure(ValidationCode.INVALID_LISTING_NONCE, 0, bytes32(0), abi.encode(currentNonce, root.nonce));
        }
        if (root.deadline < block.timestamp) {
            return _failure(ValidationCode.ORDER_DEADLINE_EXPIRED, 0, bytes32(0), "");
        }
        // Check the listing's fulfillment-specific field shape.
        if (!_validListingShape(listing)) {
            return _failure(ValidationCode.INVALID_LISTING, 0, bytes32(0), "");
        }
        if (proof.length > MAX_MERKLE_PROOF_DEPTH) {
            return _failure(ValidationCode.INVALID_MERKLE_PROOF, 0, bytes32(0), abi.encode(proof.length));
        }
        if (listing.fulfillmentKind == ICart.FulfillmentKind.ERC721_TRANSFER && requestedQuantity != 1) {
            return _failure(ValidationCode.INVALID_LISTING, 0, bytes32(0), "");
        }
        // Build and check the seller's root authorization.
        bytes32 rootDigest = _typedDataHash(config.DOMAIN_SEPARATOR(), CartHashing.hashListingRootStruct(root));
        if (target.cancelledListingRoots(listing.seller, rootDigest)) {
            return _failure(ValidationCode.INVALID_ROOT, 0, rootDigest, "");
        }
        if (!SignatureChecker.isValidSignatureNow(listing.seller, rootDigest, rootSignature)) {
            return _failure(ValidationCode.INVALID_ROOT_SIGNATURE, 0, rootDigest, "");
        }
        // Build and check the individual listing authorization and cancellation state.
        bytes32 listingDigest = _typedDataHash(config.DOMAIN_SEPARATOR(), CartHashing.hashListingStruct(listing));
        if (target.cancelledListings(listing.seller, listingDigest)) {
            return _failure(ValidationCode.LISTING_CANCELLED, 0, listingDigest, "");
        }
        if (!MerkleProof.verifyCalldata(proof, root.listingsRoot, CartHashing.hashListingLeaf(listingDigest))) {
            return _failure(ValidationCode.INVALID_MERKLE_PROOF, 0, listingDigest, "");
        }
        if (listing.availableQuantity != 0) {
            // Compare the requested quantity with the listing's remaining cap.
            uint256 filled = target.filledQuantity(listingDigest);
            uint256 remaining = filled >= listing.availableQuantity ? 0 : listing.availableQuantity - filled;
            if (requestedQuantity > remaining) {
                return _failure(
                    ValidationCode.LISTING_QUANTITY_EXCEEDED, 0, listingDigest, abi.encode(remaining, requestedQuantity)
                );
            }
        }
        // Check current NFT ownership or mint authority when the listing needs on-chain fulfillment.
        if (!_assetAvailable(listing, requestedQuantity)) {
            return _failure(ValidationCode.ASSET_UNAVAILABLE, 0, listingDigest, "");
        }
        return _success();
    }

    function validatePurchaseEnvelope(
        address cart,
        ICart.PurchaseOrder calldata order,
        ICart.OrderLine[] calldata lines,
        ICart.PayoutRoute calldata route,
        ICart.FulfillmentAction[] calldata actions,
        bytes calldata platformSignature
    ) external view override returns (ValidationResult memory result) {
        ICart target = ICart(cart);
        ICartLensTarget config = ICartLensTarget(cart);
        if (config.paused()) return _failure(ValidationCode.CART_PAUSED, 0, bytes32(0), "");
        if (order.deadline < block.timestamp) {
            return _failure(ValidationCode.ORDER_DEADLINE_EXPIRED, 0, order.orderId, "");
        }
        if (order.orderId == bytes32(0)) return _failure(ValidationCode.INVALID_ORDER_ID, 0, order.orderId, "");
        if (target.executedOrderIds(order.orderId)) {
            return _failure(ValidationCode.ORDER_ALREADY_EXECUTED, 0, order.orderId, "");
        }
        if (lines.length == 0 || lines.length > 20 || actions.length > MAX_FULFILLMENT_OPERATIONS) {
            return _failure(ValidationCode.INVALID_ARRAY_LENGTH, 0, order.orderId, "");
        }
        if (route.commands.length > MAX_ROUTE_COMMANDS || route.inputs.length > MAX_ROUTE_COMMANDS) {
            return _failure(ValidationCode.INVALID_ARRAY_LENGTH, 0, order.orderId, "");
        }
        if (order.paymentAmount == 0) return _failure(ValidationCode.ZERO_PAYMENT_AMOUNT, 0, order.orderId, "");
        if (CartHashing.hashOrderLines(lines) != order.orderLinesHash) {
            return _failure(ValidationCode.INVALID_ORDER_LINES_HASH, 0, order.orderId, "");
        }
        if (CartHashing.hashPayoutRoute(route) != order.payoutRouteHash) {
            return _failure(ValidationCode.INVALID_PAYOUT_ROUTE_HASH, 0, order.orderId, "");
        }
        if (CartHashing.hashFulfillmentActions(actions) != order.fulfillmentActionsHash) {
            return _failure(ValidationCode.INVALID_FULFILLMENT_ACTIONS_HASH, 0, order.orderId, "");
        }
        for (uint256 i = 0; i < lines.length; ++i) {
            if (
                lines[i].sku == bytes32(0) || lines[i].quantity == 0 || lines[i].amount == 0
                    || lines[i].paymentRecipient == address(0)
            ) {
                return _failure(ValidationCode.INVALID_ORDER_LINE, i, order.orderId, "");
            }
            if (
                lines[i].listingHash == bytes32(0) && lines[i].fulfillmentKind != ICart.FulfillmentKind.NONE
                    && lines[i].fulfillmentKind != ICart.FulfillmentKind.CURRENCY_SWAP
            ) {
                return _failure(ValidationCode.INVALID_ORDER_LINE, i, order.orderId, "");
            }
            if (
                lines[i].fulfillmentKind == ICart.FulfillmentKind.CURRENCY_SWAP
                    && (lines[i].listingHash != bytes32(0) || lines[i].settlementCurrency == order.paymentCurrency)
            ) {
                return _failure(ValidationCode.INVALID_ORDER_LINE, i, order.orderId, "");
            }
        }
        if (!SignatureChecker.isValidSignatureNow(
                config.platformSigner(),
                _typedDataHash(config.DOMAIN_SEPARATOR(), CartHashing.hashOrderStruct(order)),
                platformSignature
            )) {
            return _failure(ValidationCode.INVALID_PLATFORM_SIGNATURE, 0, order.orderId, "");
        }
        return _success();
    }

    function previewRoute(
        address cart,
        address inputCurrency,
        address[] calldata outputCurrencies,
        ICart.PayoutRoute calldata route
    ) external view override returns (RoutePreview memory preview) {
        ICartLensTarget config = ICartLensTarget(cart);
        address[] memory outputs = new address[](outputCurrencies.length);
        address weth = config.weth();
        for (uint256 i = 0; i < outputCurrencies.length; ++i) {
            outputs[i] = outputCurrencies[i] == address(0) ? weth : outputCurrencies[i];
        }
        address inputToken = inputCurrency == address(0) ? weth : inputCurrency;
        if (outputs.length == 0) {
            preview.direct = true;
            preview.exactInput = true;
            preview.valid = route.commands.length == 0 && route.inputs.length == 0;
            preview.code = preview.valid ? ValidationCode.OK : ValidationCode.ROUTE_UNEXPECTED;
            return preview;
        }
        if (route.commands.length == 0) {
            preview.code = ValidationCode.ROUTE_REQUIRED;
            return preview;
        }
        try ICartRoutePolicy(config.routePolicy()).validate(route.commands, route.inputs, inputToken, outputs) returns (
            ICartRoutePolicy.Summary memory summary
        ) {
            preview.valid = true;
            preview.code = ValidationCode.OK;
            preview.exactInput = summary.exactInput;
            preview.inputAmount = summary.inputAmount;
            preview.outputAmount = summary.outputAmount;
        } catch (bytes memory reason) {
            preview.code = ValidationCode.ROUTE_REJECTED;
            preview.reason = reason;
        }
    }

    function _assetAvailable(ICart.Listing calldata listing, uint256 requestedQuantity) private view returns (bool) {
        if (listing.fulfillmentKind == ICart.FulfillmentKind.ERC721_TRANSFER) {
            // An ERC-721 transfer is available only when the seller owns the token.
            try IERC721(listing.tokenContract).ownerOf(listing.tokenId) returns (address owner) {
                return owner == listing.seller;
            } catch {
                return false;
            }
        }
        if (listing.fulfillmentKind == ICart.FulfillmentKind.ERC1155_TRANSFER) {
            // An ERC-1155 transfer is available only when the seller has enough units.
            try IERC1155(listing.tokenContract).balanceOf(listing.seller, listing.tokenId) returns (uint256 balance) {
                return balance >= requestedQuantity;
            } catch {
                return false;
            }
        }
        if (_isMintKind(listing.fulfillmentKind)) {
            // A mint listing is available only when the seller controls the mint contract.
            (bool success, bytes memory data) = listing.tokenContract.staticcall(abi.encodeWithSignature("owner()"));
            return success && data.length >= 32 && abi.decode(data, (address)) == listing.seller;
        }
        return true;
    }

    function _validListingShape(ICart.Listing calldata listing) private pure returns (bool) {
        if (listing.fulfillmentKind == ICart.FulfillmentKind.CURRENCY_SWAP) return false;
        // Classify the fulfillment kind so the token fields can be checked consistently.
        bool onChain = listing.fulfillmentKind == ICart.FulfillmentKind.ERC721_TRANSFER
            || listing.fulfillmentKind == ICart.FulfillmentKind.ERC1155_TRANSFER
            || listing.fulfillmentKind == ICart.FulfillmentKind.ERC721_MINT_TO
            || listing.fulfillmentKind == ICart.FulfillmentKind.ERC1155_MINT_TO;
        // Off-chain listings must not contain NFT fields.
        if (!onChain && (listing.tokenContract != address(0) || listing.tokenId != 0)) return false;
        // On-chain listings must contain a token contract.
        if (onChain && listing.tokenContract == address(0)) return false;
        // An ERC-721 transfer can authorize zero or one available token only.
        if (
            listing.fulfillmentKind == ICart.FulfillmentKind.ERC721_TRANSFER && listing.availableQuantity != 0
                && listing.availableQuantity != 1
        ) return false;
        // An ERC-721 mint returns its token id, so its listed token id must be zero.
        return listing.fulfillmentKind != ICart.FulfillmentKind.ERC721_MINT_TO || listing.tokenId == 0;
    }

    function _isMintKind(ICart.FulfillmentKind kind) private pure returns (bool) {
        // Identify fulfillment kinds that call a mint function.
        return kind == ICart.FulfillmentKind.ERC721_MINT_TO || kind == ICart.FulfillmentKind.ERC1155_MINT_TO;
    }

    function _typedDataHash(bytes32 domainSeparator, bytes32 structHash) private pure returns (bytes32) {
        // Add the EIP-712 prefix and domain to the struct hash.
        return ECDSA.toTypedDataHash(domainSeparator, structHash);
    }

    function _success() private pure returns (ValidationResult memory result) {
        // Mark a validation result as successful and leave optional fields empty.
        result.valid = true;
        result.code = ValidationCode.OK;
    }

    function _failure(ValidationCode code, uint256 index, bytes32 subject, bytes memory reason)
        private
        pure
        returns (ValidationResult memory result)
    {
        // Return the first failing check with its location, subject, and optional details.
        result.code = code;
        result.index = index;
        result.subject = subject;
        result.reason = reason;
    }
}
