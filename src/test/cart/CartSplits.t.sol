// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import {Cart} from "../../cart/Cart.sol";
import {CartPayments} from "../../cart/CartPayments.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {Vm} from "forge-std/Vm.sol";
import {CartFixture} from "./CartFixture.sol";
import {ICart} from "../../cart/ICart.sol";
import {CartLens} from "../../cart/CartLens.sol";
import {ICartLens} from "../../cart/ICartLens.sol";
import {CartTestToken, CartTestERC721, CartTestRevertingTransferToken, RevertingPayoutRecipient} from "./CartMocks.sol";

contract CartSplitsTest is CartFixture {
    using stdJson for string;
    uint256 internal lastCheckoutGas;
    uint256 internal lastCalldataBytes;
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
        lastCalldataBytes =
        abi.encodeCall(cart.executePurchase, (order, lines, listings, authorization, route, actions, signature)).length;
        if (failure.length != 0) vm.expectRevert(failure);
        vm.prank(payer);
        uint256 gasBefore = gasleft();
        cart.executePurchase{value: currency == address(0) ? order.paymentAmount : 0}(
            order, lines, listings, authorization, route, actions, signature
        );
        lastCheckoutGas = gasBefore - gasleft();
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
            abi.encodeWithSelector(ICart.OrderLineFailed.selector, 0, ICart.FailureStage.PAYOUT, abi.encodeWithSignature("Error(string)", "payout rejected"))
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

    function testSdkTypedDataVectors() public {
        string memory data = vm.readFile("docs/data/cart-split-sdk-vectors.json");
        ICart.Listing memory listing = _listing(
            bytes32(uint256(type(uint256).max / 15)), ICart.FulfillmentKind.OFF_CHAIN, address(0), 0, address(0x3333)
        );
        listing.seller = address(0x2222);
        listing.sku = bytes32(uint256(type(uint256).max / 15 * 2));
        listing.minimumUnitPrice = 100;
        listing.availableQuantity = 3;
        bytes32 domain = data.readBytes32(".domainSeparator");
        assertEq(hashes.hashListing(domain, listing), data.readBytes32(".empty"));
        listing.splits = new ICart.Split[](2);
        listing.splits[0] = ICart.Split(address(0x3333), 8000);
        listing.splits[1] = ICart.Split(address(0x4444), 2000);
        assertEq(hashes.hashListing(domain, listing), data.readBytes32(".populated"));
    }

    function testActualPreSplitProxyMigrationPreservesHistoryAndRequiresNewAuthorization() public {
        string memory data = vm.readFile("docs/data/cart-pre-split-bytecode.json");
        address oldPayments =
            _deployFixture(abi.encodePacked(data.readBytes(".CartPayments"), abi.encode(address(routePolicy))));
        address oldImplementation =
            _deployFixture(abi.encodePacked(data.readBytes(".Cart"), abi.encode(address(routePolicy), oldPayments)));
        cart = Cart(
            payable(address(
                    new ERC1967Proxy(
                        oldImplementation,
                        abi.encodeCall(
                            Cart.initialize,
                            (address(this), platformSigner, address(router), address(permit2), address(weth))
                        )
                    )
                ))
        );
        ICart.Listing memory listing =
            _listingWithQuantity("migration", ICart.FulfillmentKind.OFF_CHAIN, address(0), 0, sellerPayout, 3);
        listing.minimumUnitPrice = 100;
        LegacySplitCart.Listing[] memory oldListings = new LegacySplitCart.Listing[](1);
        oldListings[0] = LegacySplitCart.Listing(
            listing.listingSalt,
            listing.seller,
            listing.sku,
            listing.fulfillmentKind,
            listing.tokenContract,
            listing.tokenId,
            listing.settlementCurrency,
            listing.minimumUnitPrice,
            listing.availableQuantity,
            listing.paymentRecipient
        );
        bytes32 oldStructHash = keccak256(
            abi.encode(
                keccak256(
                    "Listing(bytes32 listingSalt,address seller,bytes32 sku,uint8 fulfillmentKind,address tokenContract,uint256 tokenId,address settlementCurrency,uint256 minimumUnitPrice,uint256 availableQuantity,address paymentRecipient)"
                ),
                oldListings[0]
            )
        );
        bytes32 oldDigest = keccak256(abi.encodePacked(hex"1901", cart.DOMAIN_SEPARATOR(), oldStructHash));
        ICart.OrderLine[] memory lines = _lineForListing(listing, 1, 100);
        lines[0].listingDigest = oldDigest;
        ICart.ListingPurchaseAuthorization memory authorization =
            _rootAuthorization(_singletonListing(listing), SELLER_PK);
        authorization.listingRoots[0].listingsRoot = hashes.hashListingLeaf(oldDigest);
        authorization.listingRootSignatures[0] =
            _sign(SELLER_PK, hashes.hashListingRoot(cart.DOMAIN_SEPARATOR(), authorization.listingRoots[0]));
        ICart.PayoutRoute memory route = _emptyRoute();
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](0);
        ICart.PurchaseOrder memory order = _order("legacy-order", lines, route, actions);
        bytes memory signature = _sign(PLATFORM_PK, _orderDigest(order));
        vm.deal(payer, 100);
        vm.prank(payer);
        LegacySplitCart(address(cart)).executePurchase{value: 100}(
            order, lines, oldListings, authorization, route, actions, signature
        );
        assertEq(cart.filledQuantity(oldDigest), 1);
        vm.prank(seller);
        cart.cancelListing(oldDigest);
        cart.upgradeTo(address(new Cart(address(routePolicy), address(paymentExecutor))));
        assertEq(cart.filledQuantity(oldDigest), 1);
        assertTrue(cart.cancelledListings(seller, oldDigest));
        assertTrue(cart.executedOrderIds(order.orderId));
        // Unchanged seller terms now hash differently; the old root cannot authorize them.
        lines[0].listingDigest = _listingDigest(listing);
        order = _order("old-root-new-schema", lines, route, actions);
        signature = _sign(PLATFORM_PK, _orderDigest(order));
        vm.expectRevert(
            abi.encodeWithSelector(
                ICart.InvalidMerkleProof.selector,
                authorization.listingRoots[0].listingsRoot,
                hashes.hashListingLeaf(lines[0].listingDigest)
            )
        );
        vm.prank(payer);
        cart.executePurchase{value: 0}(
            order, lines, _singletonListing(listing), authorization, route, actions, signature
        );
        // Seller explicitly authorizes only the remaining two units under new terms.
        listing.availableQuantity = 2;
        listing.splits = new ICart.Split[](2);
        listing.splits[0] = ICart.Split(sellerPayout, 8000);
        listing.splits[1] = ICart.Split(collaborator, 2000);
        lines = _lineForListing(listing, 2, 200);
        _execute(_singletonListing(listing), lines, actions, address(0), "");
        assertEq(cart.filledQuantity(_listingDigest(listing)), 2);
        assertEq(cart.filledQuantity(oldDigest), 1);
        assertTrue(cart.cancelledListings(seller, oldDigest));
        assertEq(sellerPayout.balance, 260);
        assertEq(collaborator.balance, 40);
    }

    function _deployFixture(bytes memory code) internal returns (address deployed) {
        assembly ("memory-safe") { deployed := create(0, add(code, 32), mload(code)) }
        require(deployed != address(0), "fixture deployment failed");
    }

    function testFuzzArbitraryVectors(uint256 seed, uint8 size, uint96 amount) public {
        uint256 count = bound(size, 1, 16);
        amount = uint96(bound(amount, 1, type(uint96).max));
        ICart.Listing memory listing = _splitListing("vector", 2000);
        listing.minimumUnitPrice = 0;
        listing.splits = new ICart.Split[](count);
        uint256 remaining = 10_000;
        for (uint256 i; i < count; ++i) {
            uint256 share = i + 1 == count
                ? remaining
                : 1 + uint256(keccak256(abi.encode(seed, i))) % (remaining - (count - i - 1));
            listing.splits[i] = ICart.Split(i == 0 ? sellerPayout : address(uint160(0x8000 + i)), uint16(share));
            remaining -= share;
        }
        vm.recordLogs();
        _pay(listing, amount, "");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 total;
        uint256 events;
        for (uint256 i; i < count; ++i) {
            uint256 expected;
            if (i == 0) {
                expected = amount;
                for (uint256 j = 1; j < count; ++j) {
                    expected -= uint256(amount) * listing.splits[j].basisPoints / 10_000;
                }
            } else {
                expected = uint256(amount) * listing.splits[i].basisPoints / 10_000;
            }
            assertEq(listing.splits[i].recipient.balance, expected);
            total += expected;
            uint256 matches;
            for (uint256 j; j < logs.length; ++j) {
                if (logs[j].topics[0] != keccak256("ListingSplitPaid(bytes32,uint256,bytes32,address,address,uint256)"))
                {
                    continue;
                }
                (address currency, address recipient, uint256 paid) =
                    abi.decode(logs[j].data, (address, address, uint256));
                if (recipient == listing.splits[i].recipient) {
                    assertEq(currency, address(0));
                    assertEq(paid, expected);
                    assertEq(logs[j].topics[3], _listingDigest(listing));
                    ++matches;
                    ++events;
                }
            }
            assertEq(matches, 1);
        }
        assertEq(events, count);
        assertEq(total, amount);
    }

    function testSecondaryCallbackCannotReenter() public {
        SplitCallback receiver = new SplitCallback(address(cart), _signedInnerPurchase(), false);
        ICart.Listing memory listing = _splitListing("callback", 2000);
        listing.splits[1].recipient = address(receiver);
        _pay(listing, 150, "");
        assertTrue(receiver.attempted());
        assertFalse(receiver.succeeded());
        assertEq(receiver.result(), abi.encodeWithSignature("Error(string)", "ReentrancyGuard: reentrant call"));
        assertEq(address(receiver).balance, 30);
        assertEq(sellerPayout.balance, 120);
    }

    function testLaterSecondaryFailureRevertsEarlierCallbackAndPayouts() public {
        SplitCallback receiver = new SplitCallback(address(cart), _signedInnerPurchase(), false);
        ICart.Listing memory listing = _splitListing("later-failure", 2000);
        listing.splits = new ICart.Split[](3);
        listing.splits[0] = ICart.Split(sellerPayout, 6000);
        listing.splits[1] = ICart.Split(address(receiver), 2000);
        listing.splits[2] = ICart.Split(address(new RevertingPayoutRecipient()), 2000);
        _pay(
            listing,
            150,
            abi.encodeWithSelector(ICart.OrderLineFailed.selector, 0, ICart.FailureStage.PAYOUT, abi.encodeWithSignature("Error(string)", "payout rejected"))
        );
        assertFalse(receiver.attempted());
        assertEq(address(receiver).balance, 0);
        assertEq(payer.balance, 150);
        assertEq(cart.filledQuantity(_listingDigest(listing)), 0);
        assertFalse(cart.executedOrderIds(lastOrderId));
    }

    function testPayoutIndexCollisionsWrapAndMergeWithoutChangingAttribution() public {
        address[] memory recipients = new address[](5);
        uint256 found;
        for (uint256 candidate = 0xA000; found < 5; ++candidate) {
            address recipient = address(uint160(candidate));
            if (uint256(keccak256(abi.encode(address(0), recipient))) & 15 == 15) recipients[found++] = recipient;
        }
        ICart.Listing[] memory listings = new ICart.Listing[](3);
        ICart.OrderLine[] memory lines = new ICart.OrderLine[](3);
        for (uint256 i; i < 3; ++i) {
            listings[i] = _splitListing(bytes32(i + 1), 2000);
            listings[i].paymentRecipient = recipients[i * 2];
            listings[i].splits[0].recipient = recipients[i * 2];
            listings[i].splits[1].recipient = recipients[i == 1 ? 3 : 1];
            lines[i] = _lineForListing(listings[i], 1, 100)[0];
        }
        _execute(listings, lines, new ICart.FulfillmentAction[](0), address(0), "");
        assertEq(recipients[0].balance, 80);
        assertEq(recipients[1].balance, 40);
        assertEq(recipients[2].balance, 80);
        assertEq(recipients[3].balance, 20);
        assertEq(recipients[4].balance, 80);
        // Every key hashes to the last bucket of a 16-slot table, forcing wraparound.
        // The repeated recipient remains attributed to its first line on failure.
        vm.etch(recipients[1], address(new RevertingPayoutRecipient()).code);
        for (uint256 i; i < 3; ++i) {
            listings[i].listingSalt = bytes32(i + 100);
            lines[i] = _lineForListing(listings[i], 1, 100)[0];
        }
        _execute(
            listings,
            lines,
            new ICart.FulfillmentAction[](0),
            address(0),
            abi.encodeWithSelector(ICart.OrderLineFailed.selector, 0, ICart.FailureStage.PAYOUT, abi.encodeWithSignature("Error(string)", "payout rejected"))
        );
        assertEq(recipients[1].balance, 40);
    }

    function testCollidingPayoutCallbacksPreserveFirstSeenOrder() public {
        SplitOrderRecorder recorder = new SplitOrderRecorder();
        SplitOrderReceiver receiver = new SplitOrderReceiver(recorder);
        address[] memory recipients = new address[](4);
        uint256 found;
        for (uint256 candidate = 0xB000; found < 4; ++candidate) {
            address recipient = address(uint160(candidate));
            if (uint256(keccak256(abi.encode(address(0), recipient))) & 15 != 15) continue;
            recipients[found++] = recipient;
            vm.etch(recipient, address(receiver).code);
        }
        ICart.Listing[] memory listings = new ICart.Listing[](3);
        ICart.OrderLine[] memory lines = new ICart.OrderLine[](3);
        for (uint256 i; i < 3; ++i) {
            uint256 pair = i == 1 ? 2 : 0;
            listings[i] = _splitListing(bytes32(i + 1), i == 2 ? 5000 : 2000);
            listings[i].paymentRecipient = recipients[pair];
            listings[i].splits[0].recipient = recipients[pair];
            listings[i].splits[1].recipient = recipients[pair + 1];
            lines[i] = _lineForListing(listings[i], 1, 100)[0];
        }
        _execute(listings, lines, new ICart.FulfillmentAction[](0), address(0), "");
        assertEq(recorder.count(), 4);
        // All keys start at slot 15, wrapping to slot 0. Bucket order must not
        // replace allocation order, and later allocations must merge in place.
        assertEq(recorder.recipient(0), recipients[1]);
        assertEq(recorder.amount(0), 70);
        assertEq(recorder.recipient(1), recipients[0]);
        assertEq(recorder.amount(1), 130);
        assertEq(recorder.recipient(2), recipients[3]);
        assertEq(recorder.amount(2), 20);
        assertEq(recorder.recipient(3), recipients[2]);
        assertEq(recorder.amount(3), 80);
    }

    function testCollidingCurrenciesRemainSeparateForSharedRecipients() public {
        address[] memory recipients = new address[](2);
        uint256 found;
        for (uint256 candidate = 0xC000; found < 2; ++candidate) {
            address recipient = address(uint160(candidate));
            if (uint256(keccak256(abi.encode(address(0), recipient))) & 7 != 7) continue;
            if (uint256(keccak256(abi.encode(address(weth), recipient))) & 7 != 7) continue;
            recipients[found++] = recipient;
        }
        ICart.Listing[] memory listings = new ICart.Listing[](2);
        ICart.OrderLine[] memory lines = new ICart.OrderLine[](2);
        for (uint256 i; i < 2; ++i) {
            listings[i] = _splitListing(bytes32(i + 1), i == 0 ? 2000 : 5000);
            listings[i].paymentRecipient = recipients[0];
            listings[i].splits[0].recipient = recipients[0];
            listings[i].splits[1].recipient = recipients[1];
            listings[i].settlementCurrency = i == 0 ? address(0) : address(weth);
            lines[i] = _lineForListing(listings[i], 1, i == 0 ? 100 : 200)[0];
            lines[i].settlementCurrency = listings[i].settlementCurrency;
        }
        // Four distinct keys all start at the last slot of an eight-slot table.
        _execute(listings, lines, new ICart.FulfillmentAction[](0), address(0), "");
        assertEq(recipients[0].balance, 80);
        assertEq(recipients[1].balance, 20);
        assertEq(weth.balanceOf(recipients[0]), 100);
        assertEq(weth.balanceOf(recipients[1]), 100);
        assertEq(address(cart).balance, 0);
        assertEq(weth.balanceOf(address(cart)), 0);
    }

    function testSplitOrderGasBenchmarks() public {
        uint256 gasAt32;
        for (uint256 scenario; scenario < 4; ++scenario) {
            uint256 count = scenario == 0 ? 1 : scenario == 1 ? 8 : scenario == 2 ? 32 : 64;
            ICart.Listing[] memory listings = new ICart.Listing[](count);
            ICart.OrderLine[] memory lines = new ICart.OrderLine[](count);
            for (uint256 i; i < count; ++i) {
                listings[i] = _splitListing(keccak256(abi.encode("gas", scenario, i)), 2000);
                listings[i].paymentRecipient = address(uint160(0x100000 + scenario * 10000 + i * 16));
                listings[i].splits = new ICart.Split[](16);
                for (uint256 j; j < 16; ++j) {
                    listings[i].splits[j] = ICart.Split(address(uint160(0x100000 + scenario * 10000 + i * 16 + j)), 625);
                }
                lines[i] = _lineForListing(listings[i], 1, 10_000)[0];
            }
            _execute(listings, lines, new ICart.FulfillmentAction[](0), address(0), "");
            if (count == 32) gasAt32 = lastCheckoutGas;
            if (count == 64) assertLe(lastCheckoutGas, gasAt32 * 23 / 10, "payout gas growth must remain near linear");
            emit log_named_uint("listings", count);
            emit log_named_uint("distinct split recipients", count * 16);
            emit log_named_uint("checkout call gas", lastCheckoutGas);
            emit log_named_uint("checkout calldata bytes", lastCalldataBytes);
        }
    }
}

contract SplitCallback {
    address internal immutable cart;
    bytes internal payload;
    bool internal immutable reject;
    bool public attempted;
    bool public succeeded;
    bytes public result;

    constructor(address cart_, bytes memory payload_, bool reject_) {
        cart = cart_;
        payload = payload_;
        reject = reject_;
    }

    receive() external payable {
        attempted = true;
        (succeeded, result) = cart.call(payload);
        require(!reject, "reject");
    }
}

interface LegacySplitCart {
    struct Listing {
        bytes32 listingSalt;
        address seller;
        bytes32 sku;
        ICart.FulfillmentKind fulfillmentKind;
        address tokenContract;
        uint256 tokenId;
        address settlementCurrency;
        uint256 minimumUnitPrice;
        uint256 availableQuantity;
        address paymentRecipient;
    }
    function executePurchase(
        ICart.PurchaseOrder calldata order,
        ICart.OrderLine[] calldata lines,
        Listing[] calldata listings,
        ICart.ListingPurchaseAuthorization calldata authorization,
        ICart.PayoutRoute calldata route,
        ICart.FulfillmentAction[] calldata actions,
        bytes calldata signature
    ) external payable returns (ICart.MintResult[] memory);
}

contract SplitOrderRecorder {
    address[] public recipient;
    uint256[] public amount;

    function record(uint256 value) external {
        recipient.push(msg.sender);
        amount.push(value);
    }

    function count() external view returns (uint256) {
        return recipient.length;
    }
}

contract SplitOrderReceiver {
    SplitOrderRecorder private immutable recorder;

    constructor(SplitOrderRecorder recorder_) {
        recorder = recorder_;
    }

    receive() external payable {
        recorder.record(msg.value);
    }
}
