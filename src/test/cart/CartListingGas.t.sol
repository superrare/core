// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;
import {CartTest} from "./Cart.t.sol";
import {ICart} from "../../cart/ICart.sol";
import {CartLens} from "../../cart/CartLens.sol";

interface ListingGasVm {
    function cool(address target) external;
}

/// @notice Whole-purchase scaling benchmark, not an isolated listing-lookup cost measurement.
contract CartListingGasTest is CartTest {
    event ListingGas(
        uint256 lines,
        uint256 listings,
        uint256 calldataBytes,
        uint256 grossCallGas,
        uint256 intrinsicGas,
        uint256 calldataFloorGas
    );

    function testListingGasDistinct9() public {
        this.measure(9, false);
    }

    function testListingGasDistinct18() public {
        this.measure(18, false);
    }

    function testListingGasDistinct32() public {
        this.measure(32, false);
    }

    function testListingGasDistinct64() public {
        this.measure(64, false);
    }

    function testListingGasRepeated9() public {
        this.measure(9, true);
    }

    function testListingGasRepeated18() public {
        this.measure(18, true);
    }

    function testListingGasRepeated32() public {
        this.measure(32, true);
    }

    function testListingGasRepeated64() public {
        this.measure(64, true);
    }

    function testPurchaseAboveFormer64LineCap() public {
        this.measure(65, false);
    }

    // External dispatch prevents viaIR from cloning the full builder for every size.
    function measure(uint256 count, bool repeated) external {
        require(msg.sender == address(this));
        uint256 listingCount = repeated ? 1 : count;
        ICart.Listing[] memory listings = new ICart.Listing[](listingCount);
        ICart.OrderLine[] memory lines = new ICart.OrderLine[](count);
        for (uint256 i; i < listingCount; ++i) {
            listings[i] = _listingWithQuantity(
                keccak256(abi.encode("listing-gas", i)),
                ICart.FulfillmentKind.OFF_CHAIN,
                address(0),
                0,
                sellerPayout,
                repeated ? count : 1
            );
        }
        for (uint256 i; i < count; ++i) {
            lines[i] = _lineForListing(listings[repeated ? 0 : i], 1, 1 ether)[0];
        }
        ICart.ListingPurchaseAuthorization memory auth = sharedRoot(listings);
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](0);
        ICart.PayoutRoute[] memory routes = _emptyRoutes(1);
        ICart.PurchaseOrder memory order = _order("listing-gas", lines, routes, actions);
        bytes memory signature = _sign(PLATFORM_PK, _orderDigest(order));
        bytes memory payload = abi.encodeCall(
            ICart.executePurchase, (order, lines, listings, auth, _combineRoutes(routes), actions, signature)
        );
        assertTrue(
            new CartLens()
            .validatePurchaseEnvelope(address(cart), order, lines, _combineRoutes(routes), actions, signature)
            .valid
        );
        uint256 intrinsic = 21000;
        uint256 floor = 21000;
        for (uint256 i; i < payload.length; ++i) {
            intrinsic += payload[i] == 0 ? 4 : 16;
            floor += payload[i] == 0 ? 10 : 40;
        }
        vm.deal(sellerPayout, 1);
        vm.deal(payer, order.paymentAmount);
        ListingGasVm(address(vm)).cool(address(cart));
        ListingGasVm(address(vm)).cool(address(weth));
        ListingGasVm(address(vm)).cool(sellerPayout);
        vm.prank(payer);
        uint256 beforeGas = gasleft();
        (bool ok, bytes memory result) = address(cart).call{value: order.paymentAmount}(payload);
        uint256 used = beforeGas - gasleft();
        if (!ok) assembly ("memory-safe") { revert(add(result, 32), mload(result)) }
        assertEq(sellerPayout.balance, count * 1 ether + 1);
        assertTrue(cart.executedOrderIds(order.orderId));
        for (uint256 i; i < listingCount; ++i) {
            assertEq(cart.filledQuantity(_listingDigest(listings[i])), repeated ? count : 1);
        }
        emit ListingGas(count, listingCount, payload.length, used, intrinsic, floor);
    }

    function sharedRoot(ICart.Listing[] memory listings)
        internal
        returns (ICart.ListingPurchaseAuthorization memory auth)
    {
        uint256 width = 1;
        uint256 depth;
        while (width < listings.length) width *= 2;
        for (uint256 nodes = width; nodes > 1; nodes /= 2) ++depth;
        bytes32[] memory tree = new bytes32[](2 * width);
        for (uint256 i; i < listings.length; ++i) {
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
        auth.listingRootIndexes = new uint256[](listings.length);
        auth.listingProofs = new bytes32[][](listings.length);
        for (uint256 i; i < listings.length; ++i) {
            auth.listingProofs[i] = new bytes32[](depth);
            uint256 node = width + i;
            for (uint256 j; j < depth; ++j) {
                auth.listingProofs[i][j] = tree[node ^ 1];
                node /= 2;
            }
        }
    }
}
