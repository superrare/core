// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import {CartProofBase} from "./CartProofBase.sol";
import {CartProofSigner} from "./mocks/CartProofModels.sol";
import {Cart} from "cart-src/Cart.sol";
import {ICart} from "cart-src/ICart.sol";

contract CartRejectingInventoryRecipient {
    receive() external payable {
        revert("reject payout");
    }
}

/// @notice Fixed-shape inventory specifications through the deployed Cart proxy.
/// @dev Assumes accepting ERC1271 platform/seller signatures, one singleton Merkle root,
/// native payment, unit price 1, OFF_CHAIN fulfillment and an EOA payout recipient.
/// Valid listing inputs require nonzero digest (NO_LISTING sentinel) and nonzero Merkle root.
/// uint96 quantities bound arithmetic well below uint256 overflow. These claims do not
/// cover arbitrary array lengths, NFT callbacks, cancellation or signature cryptography.
contract CartInventoryProof is CartProofBase {
    address internal seller;
    bytes4 private lastFailure;

    function setUp() public override {
        super.setUp();
        seller = address(new CartProofSigner());
    }

    function testProof_duplicateLinesShareCapacity(uint96 first, uint96 second, uint96 extra) public {
        vm.assume(first > 0 && second > 0);
        uint256 total = uint256(first) + second;
        (ICart.Listing[] memory listings, ICart.ListingPurchaseAuthorization memory auth, bytes32 digest) =
            _inventory(total + extra);
        ICart.OrderLine[] memory lines = new ICart.OrderLine[](2);
        lines[0] = _inventoryLine(digest, first);
        lines[1] = _inventoryLine(digest, second);
        vm.deal(address(this), total);
        vm.deal(PAYEE, 0);
        assert(_buy(1, lines, listings, auth, total));
        assert(cart.filledQuantity(digest) == total);
        assert(PAYEE.balance == total);
        assert(cart.executedOrderIds(bytes32(uint256(1))));
    }

    function testProof_twoPurchasesAndReplay(uint96 first, uint96 second, uint96 extra) public {
        vm.assume(first > 0 && second > 0);
        uint256 total = uint256(first) + second;
        (ICart.Listing[] memory listings, ICart.ListingPurchaseAuthorization memory auth, bytes32 digest) =
            _inventory(total + extra);
        ICart.OrderLine[] memory lines = new ICart.OrderLine[](1);
        vm.deal(address(this), total + second);
        vm.deal(PAYEE, 0);
        lines[0] = _inventoryLine(digest, first);
        assert(_buy(1, lines, listings, auth, first));
        assert(cart.filledQuantity(digest) == first);
        lines[0] = _inventoryLine(digest, second);
        assert(_buy(2, lines, listings, auth, second));
        assert(cart.filledQuantity(digest) == total);
        uint256 payerBalance = address(this).balance;
        // Replay the identical second order, including its amount and payload hashes.
        assert(!_buy(2, lines, listings, auth, second));
        assert(lastFailure == ICart.AlreadyExecuted.selector);
        assert(cart.filledQuantity(digest) == total);
        assert(PAYEE.balance == total);
        assert(address(this).balance == payerBalance);
        assert(cart.executedOrderIds(bytes32(uint256(1))));
        assert(cart.executedOrderIds(bytes32(uint256(2))));
    }

    function testProof_overfillAfterPurchaseRollsBack(uint96 first, uint96 remaining, uint96 excess) public {
        vm.assume(first > 0 && excess > 0);
        uint256 cap = uint256(first) + remaining;
        uint256 rejected = uint256(remaining) + excess;
        (ICart.Listing[] memory listings, ICart.ListingPurchaseAuthorization memory auth, bytes32 digest) =
            _inventory(cap);
        ICart.OrderLine[] memory lines = new ICart.OrderLine[](1);
        vm.deal(address(this), uint256(first) + rejected);
        vm.deal(PAYEE, 0);
        lines[0] = _inventoryLine(digest, first);
        assert(_buy(1, lines, listings, auth, first));
        lines[0] = _inventoryLine(digest, rejected);
        uint256 payerBalance = address(this).balance;
        uint256 cartBalance = address(cart).balance;
        assert(!_buy(2, lines, listings, auth, rejected));
        assert(lastFailure == ICart.ListingQuantityExceeded.selector);
        assert(cart.filledQuantity(digest) == first);
        assert(!cart.executedOrderIds(bytes32(uint256(2))));
        assert(cart.executedOrderIds(bytes32(uint256(1))));
        assert(PAYEE.balance == first);
        assert(address(this).balance == payerBalance);
        assert(address(cart).balance == cartBalance);
    }

    function testProof_duplicateLinesCannotIndividuallyReuseCapacity(uint96 first, uint96 second) public {
        vm.assume(first > 0 && second > 0);
        uint256 cap = first > second ? first : second;
        (ICart.Listing[] memory listings, ICart.ListingPurchaseAuthorization memory auth, bytes32 digest) =
            _inventory(cap);
        ICart.OrderLine[] memory lines = new ICart.OrderLine[](2);
        lines[0] = _inventoryLine(digest, first);
        lines[1] = _inventoryLine(digest, second);
        uint256 total = uint256(first) + second;
        vm.deal(address(this), total);
        vm.deal(PAYEE, 0);
        // Each line fits alone; their combined quantity must fail the shared cap.
        assert(!_buy(1, lines, listings, auth, total));
        assert(lastFailure == ICart.ListingQuantityExceeded.selector);
        assert(cart.filledQuantity(digest) == 0);
        assert(!cart.executedOrderIds(bytes32(uint256(1))));
        assert(PAYEE.balance == 0);
        assert(address(this).balance == total);
    }

    /// @dev A late payout failure occurs after inventory reservation; transaction rollback
    /// must restore the reservation and consumed order id as well as the payment balances.
    function testProof_payoutFailureRestoresReservation(uint96 quantity, uint96 baseline) public {
        vm.assume(quantity > 0);
        address recipient = address(new CartRejectingInventoryRecipient());
        (ICart.Listing[] memory listings, ICart.ListingPurchaseAuthorization memory auth, bytes32 digest) =
            _inventory(quantity, recipient);
        ICart.OrderLine[] memory lines = new ICart.OrderLine[](1);
        lines[0] = _inventoryLine(digest, quantity);
        lines[0].paymentRecipient = recipient;
        vm.deal(address(this), quantity);
        vm.deal(address(cart), baseline);
        assert(!_buy(1, lines, listings, auth, quantity));
        assert(lastFailure == ICart.OrderLineFailed.selector);
        assert(cart.filledQuantity(digest) == 0);
        assert(!cart.executedOrderIds(bytes32(uint256(1))));
        assert(address(cart).balance == baseline);
        assert(address(this).balance == quantity);
        assert(recipient.balance == 0);
    }

    function testConcretePayoutRollbackWitness() public {
        testProof_payoutFailureRestoresReservation(3, 7);
    }

    function testConcreteInventoryWitness() public {
        testProof_duplicateLinesShareCapacity(2, 3, 1);
    }

    function testConcreteReportedRootIndexModel() public {
        testProof_twoPurchasesAndReplay(1, 1, 0);
    }

    function testConcreteSequenceWitness() public {
        testProof_twoPurchasesAndReplay(2, 3, 10);
    }

    function testConcreteOverfillWitness() public {
        testProof_overfillAfterPurchaseRollsBack(2, 3, 1);
    }

    function testConcreteDuplicateOverfillWitness() public {
        testProof_duplicateLinesCannotIndividuallyReuseCapacity(2, 3);
    }

    function _inventory(uint256 cap)
        private
        view
        returns (ICart.Listing[] memory listings, ICart.ListingPurchaseAuthorization memory auth, bytes32 digest)
    {
        return _inventory(cap, PAYEE);
    }

    function _inventory(uint256 cap, address recipient)
        private
        view
        returns (ICart.Listing[] memory listings, ICart.ListingPurchaseAuthorization memory auth, bytes32 digest)
    {
        listings = new ICart.Listing[](1);
        listings[0] = ICart.Listing({
            listingSalt: bytes32(uint256(1)),
            seller: seller,
            sku: bytes32(uint256(1)),
            fulfillmentKind: ICart.FulfillmentKind.OFF_CHAIN,
            tokenContract: address(0),
            tokenId: 0,
            settlementCurrency: address(0),
            minimumUnitPrice: 1,
            availableQuantity: cap,
            paymentRecipient: recipient
        });
        digest = hashes.hashListing(cart.DOMAIN_SEPARATOR(), listings[0]);
        auth.listingRoots = new ICart.ListingRoot[](1);
        auth.listingRoots[0] = ICart.ListingRoot({
            listingsRoot: hashes.hashListingLeaf(digest), nonce: 0, deadline: block.timestamp + 1 days
        });
        vm.assume(digest != bytes32(0));
        vm.assume(auth.listingRoots[0].listingsRoot != bytes32(0));
        auth.listingRootSignatures = new bytes[](1);
        auth.listingRootIndexes = new uint256[](1);
        // Explicitly initialize the singleton index so symbolic memory slicing need not infer padding.
        auth.listingRootIndexes[0] = 0;
        auth.listingProofs = new bytes32[][](1);
        auth.listingProofs[0] = new bytes32[](0);
    }

    function _inventoryLine(bytes32 digest, uint256 quantity) private pure returns (ICart.OrderLine memory) {
        return ICart.OrderLine({
            sku: bytes32(uint256(1)),
            listingDigest: digest,
            fulfillmentKind: ICart.FulfillmentKind.OFF_CHAIN,
            quantity: quantity,
            settlementCurrency: address(0),
            amount: quantity,
            paymentRecipient: PAYEE
        });
    }

    function _buy(
        uint256 id,
        ICart.OrderLine[] memory lines,
        ICart.Listing[] memory listings,
        ICart.ListingPurchaseAuthorization memory auth,
        uint256 quote
    ) private returns (bool) {
        ICart.PayoutRoute memory route;
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](0);
        ICart.PurchaseOrder memory order = ICart.PurchaseOrder({
            orderId: bytes32(id),
            paymentCurrency: address(0),
            deadline: block.timestamp + 1 days,
            paymentAmount: quote,
            orderLinesHash: hashes.hashOrderLines(lines),
            payoutRouteHash: hashes.hashPayoutRoute(route),
            fulfillmentActionsHash: hashes.hashFulfillmentActions(actions)
        });
        (bool success, bytes memory result) = address(cart).call{value: quote}(
            abi.encodeCall(Cart.executePurchase, (order, lines, listings, auth, route, actions, bytes("")))
        );
        lastFailure = result.length >= 4 ? bytes4(result) : bytes4(0);
        return success;
    }
}
