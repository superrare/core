// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import {CartListingGasFixture} from "./CartListingGasFixture.sol";
import {ICart} from "../../cart/ICart.sol";
import {LazySovereignNFT} from "../../token/ERC721/sovereign/lazy/LazySovereignNFT.sol";
import {Clones} from "openzeppelin-contracts/proxy/Clones.sol";

interface ERC721GasVm { function cool(address target) external; }

/// @notice Real LazySovereignNFT in a minimal proxy, one collection, two fee lines.
contract CartERC721GasTest is CartListingGasFixture {
    event ERC721Gas(bool minting, uint256 sales, uint256 lines, uint256 calldataBytes,
        uint256 grossCallGas, uint256 intrinsicGas, uint256 calldataFloorGas);

    function testERC721Transfer9() public { runCase(9, false); }
    function testERC721Transfer18() public { runCase(18, false); }
    function testERC721Transfer32() public { runCase(32, false); }
    function testERC721Transfer62() public { runCase(62, false); }
    function testERC721Transfer64() public { runCase(64, false); }
    function testERC721Mint9() public { runCase(9, true); }
    function testERC721Mint18() public { runCase(18, true); }
    function testERC721Mint32() public { runCase(32, true); }
    function testERC721Mint62() public { runCase(62, true); }
    function testERC721Mint64() public { runCase(64, true); }

    function runCase(uint256 count, bool minting) internal {
        this.measureERC721(count, minting);
    }

    function measureERC721(uint256 count, bool minting) external {
        require(msg.sender == address(this));
        LazySovereignNFT implementation = new LazySovereignNFT();
        // Same base-token clone and initialization sequence as LazySovereignNFTFactory.
        // Guarded collection variants are outside this benchmark.
        LazySovereignNFT token = LazySovereignNFT(Clones.clone(address(implementation)));
        token.init("Cart benchmark", "CB721", seller, 1000);
        vm.prank(seller);
        token.prepareMintWithMinter("ipfs://benchmark", 1000, address(cart));
        ICart.Listing[] memory listings = new ICart.Listing[](count);
        ICart.OrderLine[] memory lines = new ICart.OrderLine[](count + 2);
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](count);
        ICart.FulfillmentKind kind = minting ? ICart.FulfillmentKind.ERC721_MINT_TO : ICart.FulfillmentKind.ERC721_TRANSFER;
        for (uint256 i; i < count; ++i) {
            uint256 id;
            if (!minting) {
                vm.prank(seller);
                id = token.mintTo(seller);
            }
            listings[i] = _listing(keccak256(abi.encode("rare-gas", i)), kind, address(token), id, sellerPayout);
            lines[i] = _lineForListing(listings[i], 1, 1 ether)[0];
            actions[i] = ICart.FulfillmentAction(i, 1, collector);
        }
        vm.prank(seller);
        token.setApprovalForAll(address(cart), true);
        lines[count] = ICart.OrderLine(keccak256("platform-fee"), bytes32(0), ICart.FulfillmentKind.NONE,
            1, address(0), count * 0.1 ether, address(this));
        lines[count + 1] = ICart.OrderLine(keccak256("order-charge"), bytes32(0), ICart.FulfillmentKind.NONE,
            1, address(0), 0.2 ether, address(this));
        ICart.ListingPurchaseAuthorization memory auth = sharedRoot(listings);
        ICart.PayoutRoute memory route = _emptyRoute();
        ICart.PurchaseOrder memory order = _order("rare-gas", lines, route, actions);
        bytes memory signature = _sign(PLATFORM_PK, _orderDigest(order));
        bytes memory payload = abi.encodeCall(ICart.executePurchase,
            (order, lines, listings, auth, route, actions, signature));
        uint256 intrinsic = 21000;
        uint256 floor = 21000;
        for (uint256 i; i < payload.length; ++i) {
            intrinsic += payload[i] == 0 ? 4 : 16;
            floor += payload[i] == 0 ? 10 : 40;
        }
        uint256 protocolBefore = address(this).balance;
        vm.deal(sellerPayout, 1);
        vm.deal(payer, order.paymentAmount);
        ERC721GasVm(address(vm)).cool(address(cart));
        ERC721GasVm(address(vm)).cool(address(weth));
        ERC721GasVm(address(vm)).cool(address(token));
        ERC721GasVm(address(vm)).cool(address(implementation));
        ERC721GasVm(address(vm)).cool(sellerPayout);
        ERC721GasVm(address(vm)).cool(collector);
        vm.prank(payer);
        uint256 beforeGas = gasleft();
        (bool ok, bytes memory result) = address(cart).call{value: order.paymentAmount}(payload);
        uint256 used = beforeGas - gasleft();
        if (!ok) assembly ("memory-safe") { revert(add(result, 32), mload(result)) }
        assertTrue(cart.executedOrderIds(order.orderId));
        assertEq(sellerPayout.balance, count * 1 ether + 1);
        assertEq(address(this).balance - protocolBefore, count * 0.1 ether + 0.2 ether);
        ICart.MintResult[] memory minted = abi.decode(result, (ICart.MintResult[]));
        assertEq(minted.length, minting ? count : 0);
        assertEq(token.balanceOf(collector), count);
        assertEq(token.balanceOf(seller), 0);
        assertEq(token.totalSupply(), count);
        for (uint256 i; i < count; ++i) {
            uint256 id = minting ? minted[i].tokenIds[0] : listings[i].tokenId;
            if (minting) {
                assertEq(minted[i].fulfillmentActionIndex, i);
                assertEq(minted[i].tokenIds.length, 1);
                assertEq(id, i + 1);
            }
            assertEq(token.ownerOf(id), collector);
            (address royaltyReceiver, uint256 royaltyAmount) = token.royaltyInfo(id, 1 ether);
            assertEq(royaltyReceiver, seller);
            assertEq(royaltyAmount, 0.1 ether);
            assertEq(cart.filledQuantity(_listingDigest(listings[i])), 1);
        }
        emit ERC721Gas(minting, count, lines.length, payload.length, used, intrinsic, floor);
    }
}
