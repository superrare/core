// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import {Vm} from "forge-std/Vm.sol";
import {CartFixture} from "./CartFixture.sol";
import {ICart} from "../../cart/ICart.sol";
import {CartLens} from "../../cart/CartLens.sol";
import {ICartLens} from "../../cart/ICartLens.sol";
import {CartTestToken, CartTestERC721, CartTestRevertingTransferToken, RevertingPayoutRecipient} from "./CartMocks.sol";

contract CartSplitsTest is CartFixture {
    uint256 internal orderSequence;
    bytes32 internal lastOrderId;
    address internal collaborator = address(0x6001);

    function _splitListing(bytes32 salt, uint16 secondary) internal view returns (ICart.Listing memory listing) {
        listing = _listing(salt, ICart.FulfillmentKind.OFF_CHAIN, address(0), 0, sellerPayout);
        listing.minimumUnitPrice = 100;
        listing.splits = new ICart.Split[](2);
        listing.splits[0] = ICart.Split(sellerPayout, uint16(10_000 - secondary));
        listing.splits[1] = ICart.Split(collaborator, secondary);
    }

    function _execute(
        ICart.Listing[] memory listings,
        ICart.OrderLine[] memory lines,
        ICart.FulfillmentAction[] memory actions,
        address currency,
        bytes memory failure
    ) internal {
        ICart.PayoutRoute memory route = _emptyRoute();
        ICart.ListingPurchaseAuthorization memory authorization = _rootAuthorization(listings, SELLER_PK);
        ICart.PurchaseOrder memory order = _order("splits", lines, route, actions);
        order.orderId = keccak256(abi.encode("splits", ++orderSequence));
        lastOrderId = order.orderId;
        order.paymentCurrency = currency;
        bytes memory signature = _sign(PLATFORM_PK, _orderDigest(order));
        if (currency == address(0)) {
            vm.deal(payer, order.paymentAmount);
        } else {
            CartTestToken(currency).mint(payer, order.paymentAmount);
            vm.prank(payer);
            CartTestToken(currency).approve(address(cart), order.paymentAmount);
        }
        if (failure.length != 0) vm.expectRevert(failure);
        vm.prank(payer);
        cart.executePurchase{value: currency == address(0) ? order.paymentAmount : 0}(
            order, lines, listings, authorization, route, actions, signature
        );
    }

    function _pay(ICart.Listing memory listing, uint256 amount, bytes memory failure) internal {
        ICart.OrderLine[] memory lines = _lineForListing(listing, 1, amount);
        lines[0].settlementCurrency = listing.settlementCurrency;
        _execute(
            _singletonListing(listing), lines, new ICart.FulfillmentAction[](0), listing.settlementCurrency, failure
        );
    }

    function testSplitsFinalAmountAboveFloor() public {
        _pay(_splitListing("above-floor", 2000), 150, "");
        assertEq(sellerPayout.balance, 120);
        assertEq(collaborator.balance, 30);
        assertEq(address(cart).balance, 0);
    }

    function testFloorProtectsGroupTotalAndRejectsUnderpayment() public {
        _pay(_splitListing("floor", 2000), 100, "");
        assertEq(sellerPayout.balance, 80);
        assertEq(collaborator.balance, 20);
        _pay(_splitListing("under-floor", 2000), 99, abi.encodeWithSelector(ICart.ListingTermsMismatch.selector, 0));
    }

    function testFuzzConservationAndRounding(uint128 amount, uint16 share) public {
        amount = uint128(bound(amount, 100, type(uint128).max));
        share = uint16(bound(share, 1, 9999));
        _pay(_splitListing("fuzz", share), amount, "");
        uint256 secondary = uint256(amount) * share / 10_000;
        assertEq(collaborator.balance, secondary);
        assertEq(sellerPayout.balance, uint256(amount) - secondary);
        assertEq(address(cart).balance, 0);
    }

    function testSharedRecipientsDoNotSpreadSplitToOtherListingsOrFees() public {
        ICart.Listing[] memory listings = new ICart.Listing[](4);
        listings[0] = _splitListing("A", 2000);
        listings[1] = _listing("B", ICart.FulfillmentKind.OFF_CHAIN, address(0), 0, sellerPayout);
        listings[1].minimumUnitPrice = 200;
        listings[2] = _splitListing("C", 2000);
        listings[3] = _splitListing("D", 5000);
        ICart.OrderLine[] memory lines = new ICart.OrderLine[](5);
        // Reverse listing order so settlement must use resolved listing identities.
        lines[0] = _lineForListing(listings[3], 1, 100)[0];
        lines[1] = _lineForListing(listings[2], 1, 150)[0];
        lines[2] = _lineForListing(listings[1], 1, 200)[0];
        lines[3] = _lineForListing(listings[0], 1, 100)[0];
        lines[4] = ICart.OrderLine("fee", bytes32(0), ICart.FulfillmentKind.NONE, 1, address(0), 50, sellerPayout);
        _execute(listings, lines, new ICart.FulfillmentAction[](0), address(0), "");
        assertEq(sellerPayout.balance, 500);
        assertEq(collaborator.balance, 100);
    }

    function testRoundingOccursBeforeAggregationAcrossRepeatedLines() public {
        ICart.Listing memory listing = _splitListing("rounding", 3333);
        listing.minimumUnitPrice = 0;
        listing.availableQuantity = 2;
        ICart.OrderLine[] memory lines = new ICart.OrderLine[](2);
        lines[0] = _lineForListing(listing, 1, 2)[0];
        lines[1] = lines[0];
        _execute(_singletonListing(listing), lines, new ICart.FulfillmentAction[](0), address(0), "");
        assertEq(sellerPayout.balance, 4);
        assertEq(collaborator.balance, 0);
        assertEq(cart.filledQuantity(_listingDigest(listing)), 2);
    }

    function testErc20AndWethSplitInExactSettlementCurrency() public {
        for (uint256 i; i < 2; ++i) {
            CartTestToken token = i == 0 ? new CartTestToken("USD", "USD") : CartTestToken(address(weth));
            ICart.Listing memory listing = _splitListing(bytes32(i + 1), 2000);
            listing.settlementCurrency = address(token);
            _pay(listing, 151, "");
            assertEq(token.balanceOf(sellerPayout), 121);
            assertEq(token.balanceOf(collaborator), 30);
            assertEq(token.balanceOf(address(cart)), 0);
        }
        assertEq(sellerPayout.balance, 0);
        assertEq(collaborator.balance, 0);
    }

    function testInvalidSplitsRejectedByCartAndLens() public {
        for (uint256 variant; variant < 9; ++variant) {
            ICart.Listing memory listing = _splitListing(bytes32(variant + 1), 2000);
            if (variant == 0) listing.splits[1].basisPoints = 1999;
            if (variant == 1) listing.splits[1].basisPoints = 2001;
            if (variant == 2) listing.splits[1].recipient = address(0);
            if (variant == 3) listing.splits[1].recipient = address(cart);
            if (variant == 4) listing.splits[1].recipient = sellerPayout;
            if (variant == 5) listing.splits[0].recipient = collaborator;
            if (variant == 6) listing.splits[1].basisPoints = 0;
            if (variant == 7) listing.splits = new ICart.Split[](17);
            if (variant == 8) listing.splits[1].basisPoints = type(uint16).max;
            ICart.Listing[] memory listings = _singletonListing(listing);
            ICart.ListingPurchaseAuthorization memory auth = _rootAuthorization(listings, SELLER_PK);
            ICartLens.ValidationResult memory result = new CartLens()
                .validateListing(
                    address(cart),
                    listing,
                    auth.listingRoots[0],
                    auth.listingRootSignatures[0],
                    auth.listingProofs[0],
                    1
                );
            assertFalse(result.valid);
            _pay(listing, 100, abi.encodeWithSelector(ICart.InvalidListing.selector));
        }
    }

    function testRecipientAndShareTamperingCannotUseSellerRoot() public {
        for (uint256 variant; variant < 2; ++variant) {
            ICart.Listing memory listing = _splitListing(bytes32(variant + 1), 2000);
            ICart.Listing[] memory listings = _singletonListing(listing);
            ICart.ListingPurchaseAuthorization memory auth = _rootAuthorization(listings, SELLER_PK);
            if (variant == 0) {
                listings[0].splits[1].recipient = collector;
            } else {
                listings[0].splits[0].basisPoints = 7000;
                listings[0].splits[1].basisPoints = 3000;
            }
            // Even a platform signer approving the altered listing cannot replace seller consent.
            ICart.OrderLine[] memory lines = _lineForListing(listings[0], 1, 100);
            ICart.PayoutRoute memory route = _emptyRoute();
            ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](0);
            ICart.PurchaseOrder memory order = _order("tampered", lines, route, actions);
            bytes memory signature = _sign(PLATFORM_PK, _orderDigest(order));
            vm.deal(payer, 100);
            vm.expectRevert(
                abi.encodeWithSelector(
                    ICart.InvalidMerkleProof.selector,
                    auth.listingRoots[0].listingsRoot,
                    hashes.hashListingLeaf(_listingDigest(listings[0]))
                )
            );
            vm.prank(payer);
            cart.executePurchase{value: 100}(order, lines, listings, auth, route, actions, signature);
        }
    }

    function testSplitSaleTransfersAssetOnceAndNeedsOnlySellerSignature() public {
        CartTestERC721 nft = new CartTestERC721();
        nft.mint(seller, 7);
        vm.prank(seller);
        nft.approve(address(cart), 7);
        ICart.Listing memory listing = _splitListing("nft", 2000);
        listing.fulfillmentKind = ICart.FulfillmentKind.ERC721_TRANSFER;
        listing.tokenContract = address(nft);
        listing.tokenId = 7;
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](1);
        actions[0] = ICart.FulfillmentAction(0, 1, collector);
        _execute(_singletonListing(listing), _lineForListing(listing, 1, 150), actions, address(0), "");
        assertEq(nft.ownerOf(7), collector);
        assertEq(cart.filledQuantity(_listingDigest(listing)), 1);
        assertEq(sellerPayout.balance, 120);
        assertEq(collaborator.balance, 30);
    }

    function testPayoutFailureRevertsAssetTransferFundingAndReservations() public {
        CartTestERC721 nft = new CartTestERC721();
        nft.mint(seller, 7);
        vm.prank(seller);
        nft.approve(address(cart), 7);
        ICart.Listing memory listing = _splitListing("rollback", 2000);
        listing.fulfillmentKind = ICart.FulfillmentKind.ERC721_TRANSFER;
        listing.tokenContract = address(nft);
        listing.tokenId = 7;
        listing.splits[1].recipient = address(new RevertingPayoutRecipient());
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](1);
        actions[0] = ICart.FulfillmentAction(0, 1, collector);
        _execute(
            _singletonListing(listing),
            _lineForListing(listing, 1, 150),
            actions,
            address(0),
            abi.encodeWithSelector(ICart.OrderLineFailed.selector, 0, ICart.FailureStage.PAYOUT, bytes(""))
        );
        assertEq(nft.ownerOf(7), seller);
        assertEq(cart.filledQuantity(_listingDigest(listing)), 0);
        assertFalse(cart.executedOrderIds(lastOrderId));
        assertEq(payer.balance, 150);
        assertEq(sellerPayout.balance, 0);
    }

    function testFreeSplitListingSkipsRejectingRecipients() public {
        ICart.Listing memory listing = _splitListing("free", 2000);
        listing.minimumUnitPrice = 0;
        listing.splits[1].recipient = address(new RevertingPayoutRecipient());
        _pay(listing, 0, "");
        assertEq(cart.filledQuantity(_listingDigest(listing)), 1);
    }

    function testMaximumRecipientCountAndAllocationEvents() public {
        ICart.Listing memory listing = _splitListing("maximum", 2000);
        listing.splits = new ICart.Split[](16);
        listing.splits[0] = ICart.Split(sellerPayout, 625);
        for (uint256 i = 1; i < 16; ++i) {
            listing.splits[i] = ICart.Split(address(uint160(0x7000 + i)), 625);
        }
        vm.recordLogs();
        _pay(listing, 10_001, "");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 count;
        uint256 total;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != keccak256("ListingSplitPaid(bytes32,uint256,bytes32,address,address,uint256)")) {
                continue;
            }
            assertEq(logs[i].emitter, address(cart));
            assertEq(logs[i].topics[1], lastOrderId);
            assertEq(logs[i].topics[2], bytes32(0));
            assertEq(logs[i].topics[3], _listingDigest(listing));
            (address currency,, uint256 amount) = abi.decode(logs[i].data, (address, address, uint256));
            assertEq(currency, address(0));
            total += amount;
            ++count;
        }
        assertEq(count, 16);
        assertEq(total, 10_001);
        assertEq(sellerPayout.balance, 626);
    }

    function testErc20PayoutFailureRestoresFunding() public {
        CartTestRevertingTransferToken token = new CartTestRevertingTransferToken();
        token.setRejectingRecipient(sellerPayout);
        ICart.Listing memory listing = _splitListing("erc20-failure", 2000);
        listing.settlementCurrency = address(token);
        _pay(listing, 150, abi.encodeWithSignature("Error(string)", "rejected recipient"));
        // Secondary payout executes first, and must also roll back.
        assertEq(token.balanceOf(collaborator), 0);
        assertEq(token.balanceOf(payer), 150);
        assertEq(token.balanceOf(address(cart)), 0);
        assertEq(cart.filledQuantity(_listingDigest(listing)), 0);
        assertFalse(cart.executedOrderIds(lastOrderId));
    }

    function testSplitCannotSpendRecipientsAssetUsingSellerSignature() public {
        CartTestERC721 nft = new CartTestERC721();
        nft.mint(collaborator, 7);
        vm.prank(collaborator);
        nft.approve(address(cart), 7);
        ICart.Listing memory listing = _splitListing("asset-owner", 2000);
        listing.fulfillmentKind = ICart.FulfillmentKind.ERC721_TRANSFER;
        listing.tokenContract = address(nft);
        listing.tokenId = 7;
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](1);
        actions[0] = ICart.FulfillmentAction(0, 1, collector);
        _execute(
            _singletonListing(listing),
            _lineForListing(listing, 1, 150),
            actions,
            address(0),
            abi.encodeWithSelector(
                ICart.FulfillmentActionFailed.selector,
                0,
                0,
                abi.encodeWithSignature("Error(string)", "ERC721: transfer from incorrect owner")
            )
        );
        assertEq(nft.ownerOf(7), collaborator);
        assertEq(sellerPayout.balance, 0);
        assertEq(cart.filledQuantity(_listingDigest(listing)), 0);
    }

    function testListingHashMatchesIndependentEip712Encoding() public {
        ICart.Listing memory listing = _splitListing("hash", 2000);
        bytes32 splitType = keccak256("Split(address recipient,uint16 basisPoints)");
        bytes32 splitHash = keccak256(
            abi.encodePacked(
                keccak256(abi.encode(splitType, sellerPayout, uint16(8000))),
                keccak256(abi.encode(splitType, collaborator, uint16(2000)))
            )
        );
        bytes32 listingType = keccak256(
            "Listing(bytes32 listingSalt,address seller,bytes32 sku,uint8 fulfillmentKind,address tokenContract,uint256 tokenId,address settlementCurrency,uint256 minimumUnitPrice,uint256 availableQuantity,address paymentRecipient,Split[] splits)Split(address recipient,uint16 basisPoints)"
        );
        bytes32 structHash = keccak256(
            abi.encode(
                listingType,
                listing.listingSalt,
                listing.seller,
                listing.sku,
                listing.fulfillmentKind,
                listing.tokenContract,
                listing.tokenId,
                listing.settlementCurrency,
                listing.minimumUnitPrice,
                listing.availableQuantity,
                listing.paymentRecipient,
                splitHash
            )
        );
        assertEq(_listingDigest(listing), keccak256(abi.encodePacked(hex"1901", cart.DOMAIN_SEPARATOR(), structHash)));
    }

    function testMixedEthAndWethSplitsKeepCurrenciesAndCustodySeparate() public {
        ICart.Listing[] memory listings = new ICart.Listing[](2);
        listings[0] = _splitListing("native", 2000);
        listings[1] = _splitListing("wrapped", 5000);
        listings[1].settlementCurrency = address(weth);
        ICart.OrderLine[] memory lines = new ICart.OrderLine[](2);
        lines[0] = _lineForListing(listings[0], 1, 100)[0];
        lines[1] = _lineForListing(listings[1], 1, 200)[0];
        lines[1].settlementCurrency = address(weth);
        vm.deal(address(cart), 17);
        weth.mint(address(cart), 13);
        _execute(listings, lines, new ICart.FulfillmentAction[](0), address(0), "");
        assertEq(sellerPayout.balance, 80);
        assertEq(collaborator.balance, 20);
        assertEq(weth.balanceOf(sellerPayout), 100);
        assertEq(weth.balanceOf(collaborator), 100);
        assertEq(address(cart).balance, 17);
        assertEq(weth.balanceOf(address(cart)), 13);
    }

    function testSplitMultiplicationHandlesFullUint256Amount() public {
        CartTestToken token = new CartTestToken("Full range", "FULL");
        ICart.Listing memory listing = _splitListing("full-range", 2000);
        listing.settlementCurrency = address(token);
        _pay(listing, type(uint256).max, "");
        uint256 secondary = type(uint256).max / 5;
        assertEq(token.balanceOf(collaborator), secondary);
        assertEq(token.balanceOf(sellerPayout), type(uint256).max - secondary);
    }
}
