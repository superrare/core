// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;
import {CartListingGasFixture} from "./CartListingGasFixture.sol";
import {ICart} from "../../cart/ICart.sol";
import {CartLens} from "../../cart/CartLens.sol";

interface ListingGasVm {
    function cool(address target) external;
}

/// @notice Whole-purchase scaling benchmark, not an isolated listing-lookup cost measurement.
contract CartListingGasTest is CartListingGasFixture {
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
        ICart.PayoutRoute memory route = _emptyRoute();
        ICart.PurchaseOrder memory order = _order("listing-gas", lines, route, actions);
        bytes memory signature = _sign(PLATFORM_PK, _orderDigest(order));
        bytes memory payload = abi.encodeCall(
            ICart.executePurchase, (order, lines, listings, auth, route, actions, signature)
        );
        assertTrue(
            new CartLens()
            .validatePurchaseEnvelope(address(cart), order, lines, route, actions, signature)
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

}
