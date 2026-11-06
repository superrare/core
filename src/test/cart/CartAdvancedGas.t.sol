// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;
import {CartFixture} from "./CartFixture.sol";
import {CartTestToken, CartTestERC721} from "./CartMocks.sol";
import {ICart} from "../../cart/ICart.sol";

/// @notice Six NFT purchases, two fee lines, USD/WETH settlement and two collaborator splits.
/// @dev Router and exchange rate are deterministic local fixtures, not a live swap benchmark.
contract CartAdvancedGasTest is CartFixture {
    function testAdvancedCheckoutGas() public {
        CartTestToken usd = new CartTestToken("USD fixture", "USD");
        CartTestERC721 nft = new CartTestERC721();
        address collaborator = address(0x9090);
        address shipping = address(0x9091);
        ICart.Listing[] memory listings = new ICart.Listing[](6);
        ICart.OrderLine[] memory lines = new ICart.OrderLine[](8);
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](6);
        for (uint256 i; i < 6; ++i) {
            nft.mint(seller, i);
            listings[i] = _listing(
                bytes32(i + 1), ICart.FulfillmentKind.ERC721_TRANSFER, address(nft), i, address(uint160(0x9000 + i))
            );
            listings[i].settlementCurrency = i < 3 ? address(usd) : address(weth);
            if (i == 0 || i == 3) {
                listings[i].splits = new ICart.Split[](2);
                listings[i].splits[0] = ICart.Split(listings[i].paymentRecipient, i == 0 ? 8000 : 9000);
                listings[i].splits[1] = ICart.Split(collaborator, i == 0 ? 2000 : 1000);
            }
            lines[i] = _lineForListing(listings[i], 1, 1 ether)[0];
            lines[i].settlementCurrency = listings[i].settlementCurrency;
            actions[i] = ICart.FulfillmentAction(i, 1, collector);
        }
        vm.prank(seller);
        nft.setApprovalForAll(address(cart), true);
        lines[6] = ICart.OrderLine("platform", 0, ICart.FulfillmentKind.NONE, 1, address(usd), 0.2 ether, address(this));
        lines[7] = ICart.OrderLine("shipping", 0, ICart.FulfillmentKind.NONE, 1, address(weth), 0.1 ether, shipping);
        ICart.PayoutRoute memory route = _multiOutputRoute(address(usd), address(weth), address(0), 3.1 ether, 0, true);
        router.configureSettlement(address(permit2), address(0x9092), address(usd), address(weth), 3.1 ether, 3.1 ether);
        weth.mint(address(router), 3.1 ether);
        ICart.PurchaseOrder memory order = _order("advanced", lines, route, actions);
        order.paymentCurrency = address(usd);
        ICart.ListingPurchaseAuthorization memory auth = _rootAuthorization(listings, SELLER_PK);
        bytes memory signature = _sign(PLATFORM_PK, _orderDigest(order));
        usd.mint(payer, order.paymentAmount);
        vm.prank(payer);
        usd.approve(address(cart), order.paymentAmount);
        bytes memory payload =
            abi.encodeCall(ICart.executePurchase, (order, lines, listings, auth, route, actions, signature));
        uint256 intrinsic = 21000;
        for (uint256 i; i < payload.length; ++i) {
            intrinsic += payload[i] == 0 ? 4 : 16;
        }
        vm.prank(payer);
        uint256 start = gasleft();
        (bool ok, bytes memory result) = address(cart).call(payload);
        uint256 used = start - gasleft();
        if (!ok) assembly ("memory-safe") { revert(add(result, 32), mload(result)) }
        emit log_named_uint("advanced checkout call gas", used);
        emit log_named_uint("advanced intrinsic gas", intrinsic);
        emit log_named_uint("advanced calldata bytes", payload.length);
        assertEq(nft.balanceOf(collector), 6);
        assertEq(usd.balanceOf(collaborator), 0.2 ether);
        assertEq(weth.balanceOf(collaborator), 0.1 ether);
        assertEq(usd.balanceOf(address(this)), 0.2 ether);
        assertEq(weth.balanceOf(shipping), 0.1 ether);
        for (uint256 i; i < 6; ++i) {
            uint256 expected = i == 0 ? 0.8 ether : i == 3 ? 0.9 ether : 1 ether;
            assertEq(
                i < 3 ? usd.balanceOf(listings[i].paymentRecipient) : weth.balanceOf(listings[i].paymentRecipient),
                expected
            );
            assertEq(nft.ownerOf(i), collector);
            assertEq(cart.filledQuantity(lines[i].listingDigest), 1);
        }
        assertEq(usd.balanceOf(address(cart)), 0);
        assertEq(weth.balanceOf(address(cart)), 0);
        assertEq(usd.allowance(address(cart), address(permit2)), 0);
    }
}
