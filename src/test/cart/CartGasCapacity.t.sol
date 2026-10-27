// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import {CartTest, CartTestMintableERC721} from "./Cart.t.sol";
import {ICart} from "../../cart/ICart.sol";

interface CapacityVm {
    function cool(address target) external;
}

/// @notice Capacity experiments for the current working tree, not a gas guarantee for external contracts.
contract CartGasCapacityTest is CartTest {
    event Capacity(string scenario, uint256 lines, uint256 calldataBytes, uint256 grossCallGas, uint256 intrinsicGas);

    function testCapacitySimpleNative1() public { _capacity(1, 0, false, false); }
    function testCapacitySimpleNative5() public { _capacity(5, 0, false, false); }
    function testCapacitySimpleNative10() public { _capacity(10, 0, false, false); }
    function testCapacitySimpleNative20() public { _capacity(20, 0, false, false); }
    function testCapacitySimpleNative32() public { _capacity(32, 0, false, false); }
    function testCapacityListings1() public { _capacity(1, 0, true, false); }
    function testCapacityListings5() public { _capacity(5, 0, true, false); }
    function testCapacityListings10() public { _capacity(10, 0, true, false); }
    function testCapacityListings20() public { _capacity(20, 0, true, false); }
    function testCapacityListings32() public { _capacity(32, 0, true, false); }
    function testCapacityProof64Lines20() public { _capacity(20, 64, true, false); }
    function testCapacityProof64Lines32() public { _capacity(32, 64, true, false); }
    function testCapacityMint20() public { _capacity(20, 0, true, true); }
    function testCapacityMint20Proof64() public { _capacity(20, 64, true, true); }

    function _capacity(uint256 count, uint256 depth, bool withListings, bool withMints) internal {
        ICart.OrderLine[] memory lines = new ICart.OrderLine[](count);
        ICart.Listing[] memory listings = new ICart.Listing[](withListings ? count : 0);
        ICart.FulfillmentAction[] memory actions = new ICart.FulfillmentAction[](withMints ? count : 0);
        CartTestMintableERC721 token;
        if (withMints) {
            token = new CartTestMintableERC721();
            token.transferOwnership(seller);
            vm.prank(seller);
            token.setMinter(address(cart), true);
        }
        for (uint256 i; i < count; ++i) {
            address recipient = address(uint160(0x100000 + i));
            bytes32 sku = keccak256(abi.encode("capacity", i));
            ICart.FulfillmentKind kind = withMints ? ICart.FulfillmentKind.ERC721_MINT_TO :
                (withListings ? ICart.FulfillmentKind.OFF_CHAIN : ICart.FulfillmentKind.NONE);
            bytes32 digest;
            if (withListings) {
                listings[i] = _listing(sku, kind, address(token), 0, recipient);
                sku = listings[i].sku;
                digest = _listingDigest(listings[i]);
            }
            lines[i] = ICart.OrderLine(sku, digest, kind, 1, address(0), 1 ether, recipient);
            if (withMints) actions[i] = ICart.FulfillmentAction(i, 1, recipient);
            vm.deal(recipient, 1); // Existing EOAs avoid new-account gas dominating payout comparisons.
        }
        ICart.ListingPurchaseAuthorization memory auth = _rootAuthorization(listings, SELLER_PK);
        if (depth != 0) {
            for (uint256 i; i < count; ++i) {
                bytes32 root = hashes.hashListingLeaf(_listingDigest(listings[i]));
                auth.listingProofs[i] = new bytes32[](depth);
                for (uint256 j; j < depth; ++j) {
                    bytes32 sibling = keccak256(abi.encode("sibling", i, j));
                    auth.listingProofs[i][j] = sibling;
                    root = root < sibling ? keccak256(abi.encodePacked(root, sibling)) :
                        keccak256(abi.encodePacked(sibling, root));
                }
                auth.listingRoots[i].listingsRoot = root;
                auth.listingRootSignatures[i] = _sign(SELLER_PK,
                    hashes.hashListingRoot(cart.DOMAIN_SEPARATOR(), auth.listingRoots[i]));
            }
        }
        ICart.PayoutRoute[] memory routes = _emptyRoutes(1);
        ICart.PurchaseOrder memory order = _order("capacity", lines, routes, actions);
        bytes memory signature = _sign(PLATFORM_PK, _orderDigest(order));
        bytes memory payload = abi.encodeCall(ICart.executePurchase,
            (order, lines, listings, auth, _combineRoutes(routes), actions, signature));
        uint256 intrinsic = 21000;
        for (uint256 i; i < payload.length; ++i) intrinsic += payload[i] == 0 ? 4 : 16;
        CapacityVm(address(vm)).cool(address(cart));
        CapacityVm(address(vm)).cool(address(weth));
        if (withMints) CapacityVm(address(vm)).cool(address(token));
        vm.deal(payer, order.paymentAmount);
        vm.prank(payer);
        uint256 beforeGas = gasleft();
        (bool success, bytes memory result) = address(cart).call{value: order.paymentAmount}(payload);
        uint256 used = beforeGas - gasleft();
        if (!success) assembly ("memory-safe") { revert(add(result, 32), mload(result)) }
        emit Capacity(withMints ? "mint" : (withListings ? "listing" : "simple"), count, payload.length, used, intrinsic);
    }
}
