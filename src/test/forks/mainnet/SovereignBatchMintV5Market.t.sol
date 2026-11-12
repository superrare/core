// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import {ERC1967Proxy} from "openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {SovereignBatchMintV5ForkBase} from "./SovereignBatchMintV5.t.sol";
import {MarketplaceSettingsV1} from "../../../marketplace/MarketplaceSettingsV1.sol";
import {MarketplaceSettingsV2} from "../../../marketplace/MarketplaceSettingsV2.sol";
import {MarketplaceSettingsV3} from "../../../marketplace/MarketplaceSettingsV3.sol";
import {Payments} from "../../../payments/Payments.sol";
import {RareBatchListingMarketplace} from "../../../v2/marketplace/RareBatchListingMarketplace.sol";
import {RareBatchAuctionHouse} from "../../../v2/auctionhouse/RareBatchAuctionHouse.sol";
import {ERC20ApprovalManager} from "../../../v2/approver/ERC20/ERC20ApprovalManager.sol";
import {ERC721ApprovalManager} from "../../../v2/approver/ERC721/ERC721ApprovalManager.sol";
import {NetworkConfig} from "../../../../script/NetworkConfig.s.sol";

/// @notice Checked-in V2 sources deployed to test-local proxies, not evidence about existing mainnet market proxies.
/// @dev Uses the deployed mainnet V5, registries and Manifold royalty engine with real local settings/payments/approvers.
contract SovereignBatchMintV5LocalV2MarketTest is SovereignBatchMintV5ForkBase {
    RareBatchListingMarketplace internal listing;
    RareBatchAuctionHouse internal auction;
    ERC20ApprovalManager internal erc20Approver;
    ERC721ApprovalManager internal erc721Approver;
    MarketplaceSettingsV3 internal settings;
    address internal constant NETWORK = address(0xFEE);
    uint48 internal marketList;

    function setUp() public override {
        super.setUp();
        NetworkConfig.Addresses memory config = NetworkConfig.get(1);
        MarketplaceSettingsV1 firstSettings = new MarketplaceSettingsV1();
        MarketplaceSettingsV2 secondSettings = new MarketplaceSettingsV2(address(this), address(firstSettings));
        settings = new MarketplaceSettingsV3(address(this), address(secondSettings));
        firstSettings.grantMarketplaceAccess(address(secondSettings));
        secondSettings.grantMarketplaceAccess(address(settings));
        Payments payments = new Payments();
        erc20Approver = new ERC20ApprovalManager();
        erc721Approver = new ERC721ApprovalManager();
        listing = RareBatchListingMarketplace(address(new ERC1967Proxy(address(new RareBatchListingMarketplace()), "")));
        auction = RareBatchAuctionHouse(payable(address(new ERC1967Proxy(address(new RareBatchAuctionHouse()), ""))));
        listing.initialize(
            address(settings),
            config.royaltyEngineManifold,
            config.spaceOperatorRegistry,
            config.approvedTokenRegistry,
            address(payments),
            config.stakingRegistry,
            address(settings),
            NETWORK,
            address(erc20Approver),
            address(erc721Approver)
        );
        auction.initialize(
            address(settings),
            config.royaltyEngineManifold,
            config.spaceOperatorRegistry,
            config.approvedTokenRegistry,
            address(payments),
            config.stakingRegistry,
            address(settings),
            NETWORK,
            address(erc20Approver),
            address(erc721Approver)
        );
        settings.grantMarketplaceAccess(address(listing));
        settings.grantMarketplaceAccess(address(auction));
        erc20Approver.grantRole(erc20Approver.OPERATOR_ROLE(), address(listing));
        erc20Approver.grantRole(erc20Approver.OPERATOR_ROLE(), address(auction));
        erc721Approver.grantOperatorRole(address(listing));
        erc721Approver.grantOperatorRole(address(auction));
        marketList = _customList();
        // NFT ingress is called by the approval manager, not either market proxy or the buyer.
        _setListAccount(marketList, address(erc721Approver), true);
        vm.prank(ARTIST);
        token.setApprovalForAll(address(erc721Approver), true);
    }

    function testImmediateMintListingPrimaryThenSecondaryPreservesRoyaltySnapshot() public {
        vm.prank(ARTIST);
        token.mintTo("ipfs://immediate/1.json", ARTIST, RECIPIENT);
        assertEq(token.ownerOf(1), ARTIST);
        assertEq(token.balanceOf(ARTIST), 1);
        assertEq(token.totalSupply(), 1);
        assertEq(token.getBatchCount(), 0);
        (bytes32 root, bytes32[] memory proof) = _tokenProof(1, 2);
        _registerListing(ARTIST, root, 1 ether);
        vm.deal(COLLECTOR, 1.03 ether);
        uint256 artistBefore = ARTIST.balance;
        uint256 networkBefore = NETWORK.balance;
        uint256 royaltyBefore = RECIPIENT.balance;
        vm.prank(COLLECTOR);
        listing.buyWithMerkleProof{value: 1.03 ether}(
            address(token), 1, address(0), 1 ether, ARTIST, root, proof, new bytes32[](0)
        );
        assertEq(token.ownerOf(1), COLLECTOR);
        assertEq(token.balanceOf(ARTIST), 0);
        assertEq(token.balanceOf(COLLECTOR), 1);
        assertEq(token.totalSupply(), 1);
        assertEq(ARTIST.balance - artistBefore, 0.85 ether);
        assertEq(NETWORK.balance - networkBefore, 0.18 ether);
        assertEq(RECIPIENT.balance, royaltyBefore);
        assertEq(COLLECTOR.balance, 0);
        assertEq(address(listing).balance, 0);
        assertTrue(settings.hasERC721TokenSold(address(token), 1));
        assertFalse(settings.hasERC721TokenSold(address(token), 2));

        vm.startPrank(ARTIST);
        token.setDefaultRoyaltyReceiver(ARTIST);
        token.setDefaultRoyaltyPercentage(7);
        vm.stopPrank();
        // Standard mintTo snapshots the nonzero receiver and rate; defaults do not rewrite this token.
        (address receiver, uint256 royalty) = token.royaltyInfo(1, 2 ether);
        assertEq(receiver, RECIPIENT);
        assertEq(royalty, 0.2 ether);
        vm.prank(COLLECTOR);
        token.setApprovalForAll(address(erc721Approver), true);
        _registerListing(COLLECTOR, root, 2 ether);
        address buyer = address(0xC0FFEE);
        vm.deal(buyer, 2.06 ether);
        royaltyBefore = RECIPIENT.balance;
        uint256 sellerBefore = COLLECTOR.balance;
        artistBefore = ARTIST.balance;
        networkBefore = NETWORK.balance;
        vm.prank(buyer);
        listing.buyWithMerkleProof{value: 2.06 ether}(
            address(token), 1, address(0), 2 ether, COLLECTOR, root, proof, new bytes32[](0)
        );
        assertEq(token.ownerOf(1), buyer);
        assertEq(token.balanceOf(COLLECTOR), 0);
        assertEq(token.balanceOf(buyer), 1);
        assertEq(token.totalSupply(), 1);
        assertEq(RECIPIENT.balance - royaltyBefore, 0.2 ether);
        assertEq(COLLECTOR.balance - sellerBefore, 1.8 ether);
        assertEq(ARTIST.balance, artistBefore);
        assertEq(NETWORK.balance - networkBefore, 0.06 ether);
        assertEq(buyer.balance, 0);
        assertEq(address(listing).balance, 0);
    }

    function testBatchListingDeniedFirstTransferRollsBackStoragePaymentApprovalAndNonce() public {
        vm.startPrank(ARTIST);
        token.batchMint("ipfs://batch", 2);
        token.setApprovalForAll(address(erc721Approver), true);
        token.approve(address(erc721Approver), 1);
        vm.stopPrank();
        // Standard batches count supply at issuance, before ERC721 ownership storage is materialized.
        assertEq(token.totalSupply(), 2);
        assertEq(token.balanceOf(ARTIST), 0);
        (bytes32 root, bytes32[] memory proof) = _tokenProof(1, 2);
        _registerListing(ARTIST, root, 1 ether);
        _setListAccount(marketList, address(erc721Approver), false);
        _setListAccount(marketList, address(listing), true);
        vm.deal(COLLECTOR, 1.03 ether);
        uint256 artistBefore = ARTIST.balance;
        uint256 networkBefore = NETWORK.balance;
        // Allowing the listing itself cannot authorize the approval manager's NFT call.
        vm.expectRevert();
        vm.prank(COLLECTOR);
        listing.buyWithMerkleProof{value: 1.03 ether}(
            address(token), 1, address(0), 1 ether, ARTIST, root, proof, new bytes32[](0)
        );
        assertEq(token.ownerOf(1), ARTIST);
        assertEq(token.ownerOf(2), ARTIST);
        assertEq(token.totalSupply(), 2);
        assertEq(token.balanceOf(ARTIST), 0);
        assertEq(token.balanceOf(COLLECTOR), 0);
        assertEq(token.getApproved(1), address(erc721Approver));
        assertEq(COLLECTOR.balance, 1.03 ether);
        assertEq(ARTIST.balance, artistBefore);
        assertEq(NETWORK.balance, networkBefore);
        assertEq(address(listing).balance, 0);
        assertFalse(settings.hasERC721TokenSold(address(token), 1));

        _setListAccount(marketList, address(listing), false);
        _setListAccount(marketList, address(erc721Approver), true);
        // Identical root/proof retry also proves the denied transaction did not consume the listing nonce.
        vm.prank(COLLECTOR);
        listing.buyWithMerkleProof{value: 1.03 ether}(
            address(token), 1, address(0), 1 ether, ARTIST, root, proof, new bytes32[](0)
        );
        assertEq(token.ownerOf(1), COLLECTOR);
        assertEq(token.ownerOf(2), ARTIST);
        assertEq(token.totalSupply(), 2);
        assertEq(token.balanceOf(ARTIST), 0);
        assertEq(token.balanceOf(COLLECTOR), 1);
        assertEq(token.getApproved(1), address(0));
        assertEq(ARTIST.balance - artistBefore, 0.85 ether);
        assertEq(NETWORK.balance - networkBefore, 0.18 ether);
        assertEq(COLLECTOR.balance, 0);
        assertEq(address(listing).balance, 0);
        assertTrue(settings.hasERC721TokenSold(address(token), 1));
        assertFalse(settings.hasERC721TokenSold(address(token), 2));
    }

    function testBatchAuctionUsesManagerForFirstEscrowAndAuctionForSettlementThenPaysSecondaryRoyalty() public {
        vm.prank(ARTIST);
        token.batchMint("ipfs://auction-batch", 2);
        (bytes32 root, bytes32[] memory proof) = _tokenProof(1, 2);
        _registerAuction(ARTIST, root, 1 ether);
        _setListAccount(marketList, address(erc721Approver), false);
        _setListAccount(marketList, address(auction), true);
        vm.deal(COLLECTOR, 1.03 ether);
        uint256 artistBefore = ARTIST.balance;
        uint256 networkBefore = NETWORK.balance;
        vm.expectRevert();
        vm.prank(COLLECTOR);
        auction.bidWithAuctionMerkleProof{value: 1.03 ether}(
            address(0), address(token), 1, ARTIST, root, 1 ether, proof
        );
        assertEq(token.ownerOf(1), ARTIST);
        assertEq(token.totalSupply(), 2);
        assertEq(token.balanceOf(ARTIST), 0);
        assertEq(token.balanceOf(address(auction)), 0);
        assertEq(COLLECTOR.balance, 1.03 ether);
        assertEq(ARTIST.balance, artistBefore);
        assertEq(NETWORK.balance, networkBefore);
        assertEq(address(auction).balance, 0);
        assertEq(auction.getTokenAuctionNonce(ARTIST, root, address(token), 1), 0);
        (address bidder,, uint128 amount,) = auction.getCurrentBid(address(token), 1);
        assertEq(bidder, address(0));
        assertEq(amount, 0);
        assertFalse(settings.hasERC721TokenSold(address(token), 1));

        _setListAccount(marketList, address(auction), false);
        _setListAccount(marketList, address(erc721Approver), true);
        vm.prank(COLLECTOR);
        auction.bidWithAuctionMerkleProof{value: 1.03 ether}(
            address(0), address(token), 1, ARTIST, root, 1 ether, proof
        );
        assertEq(token.ownerOf(1), address(auction));
        assertEq(token.ownerOf(2), ARTIST);
        assertEq(token.totalSupply(), 2);
        assertEq(token.balanceOf(address(auction)), 1);
        assertEq(token.balanceOf(ARTIST), 0);
        assertEq(COLLECTOR.balance, 0);
        assertEq(address(auction).balance, 1.03 ether);
        assertEq(auction.getTokenAuctionNonce(ARTIST, root, address(token), 1), 1);
        vm.warp(block.timestamp + 1 days);
        // Unlike ingress, settlement calls transferFrom directly from the auction proxy.
        vm.expectRevert();
        auction.settleAuction(address(token), 1);
        assertEq(token.ownerOf(1), address(auction));
        assertEq(token.balanceOf(address(auction)), 1);
        assertEq(address(auction).balance, 1.03 ether);
        assertEq(ARTIST.balance, artistBefore);
        assertEq(NETWORK.balance, networkBefore);
        (bidder,, amount,) = auction.getCurrentBid(address(token), 1);
        assertEq(bidder, COLLECTOR);
        assertEq(amount, 1 ether);
        assertFalse(settings.hasERC721TokenSold(address(token), 1));
        _setListAccount(marketList, address(auction), true);
        auction.settleAuction(address(token), 1);
        assertEq(token.ownerOf(1), COLLECTOR);
        assertEq(token.totalSupply(), 2);
        assertEq(token.balanceOf(address(auction)), 0);
        assertEq(token.balanceOf(COLLECTOR), 1);
        assertEq(ARTIST.balance - artistBefore, 0.85 ether);
        assertEq(NETWORK.balance - networkBefore, 0.18 ether);
        assertEq(address(auction).balance, 0);
        assertTrue(settings.hasERC721TokenSold(address(token), 1));
        assertFalse(settings.hasERC721TokenSold(address(token), 2));
        (bidder,, amount,) = auction.getCurrentBid(address(token), 1);
        assertEq(bidder, address(0));
        assertEq(amount, 0);

        // A materialized batch token has no mintTo snapshot: its secondary royalty still uses current defaults.
        vm.startPrank(ARTIST);
        token.setDefaultRoyaltyReceiver(RECIPIENT);
        token.setDefaultRoyaltyPercentage(7);
        vm.stopPrank();
        (address receiver, uint256 royalty) = token.royaltyInfo(1, 2 ether);
        assertEq(receiver, RECIPIENT);
        assertEq(royalty, 0.14 ether);
        vm.prank(COLLECTOR);
        token.setApprovalForAll(address(erc721Approver), true);
        _registerAuction(COLLECTOR, root, 2 ether);
        vm.deal(OPERATOR, 2.06 ether);
        vm.prank(OPERATOR);
        auction.bidWithAuctionMerkleProof{value: 2.06 ether}(
            address(0), address(token), 1, COLLECTOR, root, 2 ether, proof
        );
        assertEq(token.ownerOf(1), address(auction));
        assertEq(token.balanceOf(COLLECTOR), 0);
        assertEq(token.balanceOf(address(auction)), 1);
        assertEq(address(auction).balance, 2.06 ether);
        assertEq(OPERATOR.balance, 0);
        vm.warp(block.timestamp + 1 days);
        uint256 royaltyBefore = RECIPIENT.balance;
        uint256 sellerBefore = COLLECTOR.balance;
        artistBefore = ARTIST.balance;
        networkBefore = NETWORK.balance;
        auction.settleAuction(address(token), 1);
        assertEq(token.ownerOf(1), OPERATOR);
        assertEq(token.ownerOf(2), ARTIST);
        assertEq(token.totalSupply(), 2);
        assertEq(token.balanceOf(address(auction)), 0);
        assertEq(token.balanceOf(OPERATOR), 1);
        assertEq(RECIPIENT.balance - royaltyBefore, 0.14 ether);
        assertEq(COLLECTOR.balance - sellerBefore, 1.86 ether);
        assertEq(ARTIST.balance, artistBefore);
        assertEq(NETWORK.balance - networkBefore, 0.06 ether);
        assertEq(address(auction).balance, 0);
        (bidder,, amount,) = auction.getCurrentBid(address(token), 1);
        assertEq(bidder, address(0));
        assertEq(amount, 0);
    }

    function _registerListing(address seller, bytes32 root, uint256 price) internal {
        (address payable[] memory recipients, uint8[] memory ratios) = _splits(seller);
        vm.prank(seller);
        listing.registerSalePriceMerkleRoot(root, address(0), price, recipients, ratios);
    }

    function _registerAuction(address seller, bytes32 root, uint128 minimumBid) internal {
        (address payable[] memory recipients, uint8[] memory ratios) = _splits(seller);
        vm.prank(seller);
        auction.registerAuctionMerkleRoot(root, address(0), minimumBid, 1 days, recipients, ratios);
    }

    function _splits(address seller)
        internal
        pure
        returns (address payable[] memory recipients, uint8[] memory ratios)
    {
        recipients = new address payable[](1);
        recipients[0] = payable(seller);
        ratios = new uint8[](1);
        ratios[0] = 100;
    }

    function _tokenProof(uint256 id, uint256 siblingId) internal view returns (bytes32 root, bytes32[] memory proof) {
        bytes32 leaf = keccak256(abi.encodePacked(address(token), id));
        bytes32 sibling = keccak256(abi.encodePacked(address(token), siblingId));
        root = leaf < sibling ? keccak256(abi.encodePacked(leaf, sibling)) : keccak256(abi.encodePacked(sibling, leaf));
        proof = new bytes32[](1);
        proof[0] = sibling;
    }
}
