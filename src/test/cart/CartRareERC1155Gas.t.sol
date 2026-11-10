// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import {CartListingGasFixture} from "./CartListingGasFixture.sol";
import {ICart} from "../../cart/ICart.sol";
import {RareERC1155} from "../../token/ERC1155/RareERC1155.sol";
import {RareERC1155ContractFactory} from "../../token/ERC1155/RareERC1155ContractFactory.sol";

interface RareGasVm { function cool(address target) external; }

/// @notice Actual factory-cloned RareERC1155, single collection, distinct token IDs, two fee lines.
contract CartRareERC1155GasTest is CartListingGasFixture {
    event RareERC1155Gas(bool minting, uint256 sales, uint256 lines, uint256 calldataBytes,
        uint256 grossCallGas, uint256 intrinsicGas, uint256 calldataFloorGas);

    function testRareTransfer9() public { runCase(9, false); }
    function testRareTransfer18() public { runCase(18, false); }
    function testRareTransfer32() public { runCase(32, false); }
    function testRareTransfer62() public { runCase(62, false); }
    function testRareTransfer64() public { runCase(64, false); }
    function testRareMint9() public { runCase(9, true); }
    function testRareMint18() public { runCase(18, true); }
    function testRareMint32() public { runCase(32, true); }
    function testRareMint62() public { runCase(62, true); }
    function testRareMint64() public { runCase(64, true); }

    function runCase(uint256 count, bool minting) internal {
        this.measureRare(count, minting);
    }

    function measureRare(uint256 count, bool minting) external {
        require(msg.sender == address(this));
        RareERC1155ContractFactory factory = new RareERC1155ContractFactory();
        factory.setDefaultMinter(address(cart));
        vm.prank(seller);
        RareERC1155 token = RareERC1155(factory.createRareERC1155Contract("Cart benchmark", "CB", "ipfs://benchmark/{id}"));
        ICart.Listing[] memory listings = new ICart.Listing[](count);
        ICart.OrderLine[] memory lines = new ICart.OrderLine[](count + 2);
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](count);
        ICart.FulfillmentKind kind = minting ? ICart.FulfillmentKind.ERC1155_MINT_TO : ICart.FulfillmentKind.ERC1155_TRANSFER;
        for (uint256 i; i < count; ++i) {
            vm.prank(seller);
            uint256 id = token.createToken("", 100, seller);
            if (!minting) {
                // Retain one seller unit after sale, avoiding zero-balance refunds.
                vm.prank(seller);
                token.mintTo(seller, id, 2);
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
        RareGasVm(address(vm)).cool(address(cart));
        RareGasVm(address(vm)).cool(address(weth));
        RareGasVm(address(vm)).cool(address(token));
        RareGasVm(address(vm)).cool(factory.rareERC1155());
        RareGasVm(address(vm)).cool(sellerPayout);
        RareGasVm(address(vm)).cool(collector);
        vm.prank(payer);
        uint256 beforeGas = gasleft();
        (bool ok, bytes memory result) = address(cart).call{value: order.paymentAmount}(payload);
        uint256 used = beforeGas - gasleft();
        if (!ok) assembly ("memory-safe") { revert(add(result, 32), mload(result)) }
        assertTrue(cart.executedOrderIds(order.orderId));
        assertEq(sellerPayout.balance, count * 1 ether + 1);
        assertEq(address(this).balance - protocolBefore, count * 0.1 ether + 0.2 ether);
        for (uint256 i; i < count; ++i) {
            uint256 id = listings[i].tokenId;
            assertEq(token.balanceOf(collector, id), 1);
            assertEq(token.balanceOf(seller, id), minting ? 0 : 1);
            assertEq(token.totalSupply(id), minting ? 1 : 2);
            assertEq(token.totalMintedForToken(id), minting ? 1 : 2);
            assertEq(cart.filledQuantity(_listingDigest(listings[i])), 1);
        }
        emit RareERC1155Gas(minting, count, lines.length, payload.length, used, intrinsic, floor);
    }
}
