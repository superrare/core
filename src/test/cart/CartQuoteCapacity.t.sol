// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;
import {CartTest} from "./Cart.t.sol";
import {ICart} from "../../cart/ICart.sol";

interface QuoteCapacityVm {
    function cool(address target) external;
}

contract CartQuoteCapacityTest is CartTest {
    event QuoteCapacity(
        uint256 merchandise,
        bool groupedFees,
        bool sharedRoot,
        uint256 lines,
        uint256 calldataBytes,
        uint256 grossCallGas,
        uint256 intrinsicGas
    );

    function testQuoteNinePerItemFees() public {
        _quote(9, false, true);
    }

    function testQuoteNineGroupedFees() public {
        _quote(9, true, true);
    }

    function testQuoteFifteenPerItemFees() public {
        _quote(15, false, true);
    }

    function testQuoteFifteenGroupedFees() public {
        _quote(15, true, true);
    }

    function testQuoteThirtyGroupedFees() public {
        _quote(30, true, true);
    }

    function testQuoteNineSeparateRoots() public {
        _quote(9, true, false);
    }

    function _quote(uint256 count, bool grouped, bool shared) internal {
        uint256 lineCount = count + (grouped ? 1 : count) + 1;
        ICart.OrderLine[] memory lines = new ICart.OrderLine[](lineCount);
        ICart.Listing[] memory listings = new ICart.Listing[](count);
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](0);
        for (uint256 i; i < count; ++i) {
            listings[i] = _listing(
                keccak256(abi.encode("quote-listing", i)), ICart.FulfillmentKind.OFF_CHAIN, address(0), 0, sellerPayout
            );
            lines[i] = _lineForListing(listings[i], 1, 1 ether)[0];
        }
        uint256 feeLines = grouped ? 1 : count;
        for (uint256 i; i < feeLines; ++i) {
            lines[count + i] = ICart.OrderLine(
                keccak256("platform-fee"),
                bytes32(0),
                ICart.FulfillmentKind.NONE,
                1,
                address(0),
                grouped ? count * 0.1 ether : 0.1 ether,
                address(this)
            );
        }
        lines[lineCount - 1] = ICart.OrderLine(
            keccak256("shipping"), bytes32(0), ICart.FulfillmentKind.NONE, 1, address(0), 0.2 ether, address(this)
        );
        ICart.ListingPurchaseAuthorization memory auth = _rootAuthorization(listings, SELLER_PK);
        if (shared) auth = _sharedRoot(listings);
        ICart.PayoutRoute[] memory routes = _emptyRoutes(1);
        ICart.PurchaseOrder memory order = _order("quote-capacity", lines, routes, actions);
        bytes memory signature = _sign(PLATFORM_PK, _orderDigest(order));
        bytes memory payload = abi.encodeCall(
            ICart.executePurchase, (order, lines, listings, auth, _combineRoutes(routes), actions, signature)
        );
        uint256 intrinsic = 21000;
        for (uint256 i; i < payload.length; ++i) {
            intrinsic += payload[i] == 0 ? 4 : 16;
        }
        QuoteCapacityVm(address(vm)).cool(address(cart));
        QuoteCapacityVm(address(vm)).cool(address(weth));
        uint256 sellerBefore = sellerPayout.balance;
        uint256 protocolBefore = address(this).balance;
        vm.deal(payer, order.paymentAmount);
        vm.prank(payer);
        uint256 beforeGas = gasleft();
        (bool success, bytes memory result) = address(cart).call{value: order.paymentAmount}(payload);
        uint256 used = beforeGas - gasleft();
        if (!success) assembly ("memory-safe") { revert(add(result, 32), mload(result)) }
        assertEq(sellerPayout.balance - sellerBefore, count * 1 ether);
        assertEq(address(this).balance - protocolBefore, count * 0.1 ether + 0.2 ether);
        emit QuoteCapacity(count, grouped, shared, lineCount, payload.length, used, intrinsic);
    }

    function _sharedRoot(ICart.Listing[] memory listings)
        internal
        returns (ICart.ListingPurchaseAuthorization memory auth)
    {
        uint256 count = listings.length;
        uint256 width = 1;
        uint256 depth;
        while (width < count) width *= 2;
        for (uint256 nodes = width; nodes > 1; nodes /= 2) ++depth;
        bytes32[] memory tree = new bytes32[](2 * width);
        for (uint256 i; i < count; ++i) {
            tree[width + i] = hashes.hashListingLeaf(_listingDigest(listings[i]));
        }
        for (uint256 i = width - 1; i != 0; --i) {
            bytes32 a = tree[2 * i];
            bytes32 b = tree[2 * i + 1];
            tree[i] = a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
        }
        auth.listingRoots = new ICart.ListingRoot[](1);
        auth.listingRoots[0] = ICart.ListingRoot(tree[1], 0, block.timestamp + 1 days);
        auth.listingRootSignatures = new bytes[](1);
        auth.listingRootSignatures[0] =
            _sign(SELLER_PK, hashes.hashListingRoot(cart.DOMAIN_SEPARATOR(), auth.listingRoots[0]));
        auth.listingRootIndexes = new uint256[](count);
        auth.listingProofs = new bytes32[][](count);
        for (uint256 i; i < count; ++i) {
            auth.listingProofs[i] = new bytes32[](depth);
            uint256 node = width + i;
            for (uint256 j; j < depth; ++j) {
                auth.listingProofs[i][j] = tree[node ^ 1];
                node /= 2;
            }
        }
    }
}
