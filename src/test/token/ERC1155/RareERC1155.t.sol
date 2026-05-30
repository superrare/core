// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import {IRareERC1155} from "../../../token/ERC1155/IRareERC1155.sol";
import {RareERC1155} from "../../../token/ERC1155/RareERC1155.sol";
import {RareERC1155ContractFactory} from "../../../token/ERC1155/RareERC1155ContractFactory.sol";
import {ITokenCreator} from "../../../token/extensions/ITokenCreator.sol";
import {IERC2981} from "../../../token/extensions/IERC2981.sol";

contract RareERC1155Test is Test {
    RareERC1155 private token;
    RareERC1155ContractFactory private factory;

    address private owner = address(0x1111);
    address private minter = address(0x2222);
    address private collector = address(0x3333);
    address private royaltyReceiver = address(0x4444);

    event MetadataUpdate(uint256 _tokenId);

    function setUp() public {
        factory = new RareERC1155ContractFactory();
        factory.setDefaultMinter(minter);

        vm.prank(owner);
        token = RareERC1155(factory.createRareERC1155Contract("Rare Editions", "RARE1155", "ipfs://base/{id}.json"));
    }

    function testImplementationCannotBeInitialized() public {
        RareERC1155 implementation = new RareERC1155();

        vm.expectRevert("Initializable: contract is already initialized");
        implementation.init("Rare Editions", "RARE1155", "ipfs://base/{id}.json", owner, minter);
    }

    function testFactoryCreatesInitializedClone() public {
        factory = new RareERC1155ContractFactory();
        factory.setDefaultMinter(minter);

        vm.prank(owner);
        address clone = factory.createRareERC1155Contract("Factory Editions", "FED", "ipfs://factory/{id}.json");

        RareERC1155 created = RareERC1155(clone);
        assertEq(created.owner(), owner);
        assertEq(created.name(), "Factory Editions");
        assertEq(created.symbol(), "FED");
        assertTrue(created.isApprovedMinter(minter));
    }

    function testCreateTokenMintAndRoyalty() public {
        vm.prank(owner);
        uint256 tokenId = token.createToken("ipfs://token/1.json", 10, royaltyReceiver);

        assertEq(tokenId, 1);
        assertEq(token.uri(tokenId), "ipfs://token/1.json");
        assertEq(token.maxSupplyForToken(tokenId), 10);
        assertEq(token.tokenCreator(tokenId), owner);
        assertTrue(token.supportsInterface(type(IRareERC1155).interfaceId));
        assertTrue(token.supportsInterface(type(ITokenCreator).interfaceId));
        assertTrue(token.supportsInterface(type(IERC2981).interfaceId));
        assertTrue(token.supportsInterface(0x49064906));

        vm.prank(minter);
        token.mintTo(collector, tokenId, 4);

        assertEq(token.balanceOf(collector, tokenId), 4);
        assertEq(token.totalSupply(tokenId), 4);
        assertEq(token.totalMintedForToken(tokenId), 4);

        (address receiver, uint256 royaltyAmount) = token.royaltyInfo(tokenId, 1 ether);
        assertEq(receiver, royaltyReceiver);
        assertEq(royaltyAmount, 0.1 ether);
    }

    function testUpdateTokenURIEmitsMetadataUpdate() public {
        vm.prank(owner);
        uint256 tokenId = token.createToken("ipfs://token/1.json", 10);

        vm.expectEmit(false, false, false, true, address(token));
        emit MetadataUpdate(tokenId);

        vm.prank(owner);
        token.updateTokenURI(tokenId, "ipfs://token/updated.json");

        assertEq(token.uri(tokenId), "ipfs://token/updated.json");
    }

    function testMaxSupplyEnforced() public {
        vm.prank(owner);
        uint256 tokenId = token.createToken("ipfs://token/1.json", 2);

        vm.prank(minter);
        token.mintTo(collector, tokenId, 2);

        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(IRareERC1155.ExceededMaxSupply.selector, tokenId, 3, 2));
        token.mintTo(collector, tokenId, 1);
    }

    function testBurnDoesNotResetMaxSupply() public {
        vm.prank(owner);
        uint256 tokenId = token.createToken("ipfs://token/1.json", 2);

        vm.prank(minter);
        token.mintTo(collector, tokenId, 2);

        vm.prank(collector);
        token.burn(collector, tokenId, 1);

        assertEq(token.balanceOf(collector, tokenId), 1);
        assertEq(token.totalSupply(tokenId), 1);
        assertEq(token.totalMintedForToken(tokenId), 2);

        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(IRareERC1155.ExceededMaxSupply.selector, tokenId, 3, 2));
        token.mintTo(collector, tokenId, 1);
    }

    function testOnlyOwnerOrApprovedMinterCanMint() public {
        vm.prank(owner);
        uint256 tokenId = token.createToken("ipfs://token/1.json", 5);

        vm.prank(collector);
        vm.expectRevert(abi.encodeWithSelector(IRareERC1155.CallerCannotMint.selector, collector));
        token.mintTo(collector, tokenId, 1);

        vm.prank(owner);
        token.setMinterApproval(collector, true);

        vm.prank(collector);
        token.mintTo(collector, tokenId, 1);

        assertEq(token.balanceOf(collector, tokenId), 1);
    }

    function testBurnAndDisable() public {
        vm.prank(owner);
        uint256 tokenId = token.createToken("ipfs://token/1.json", 5);

        vm.prank(minter);
        token.mintTo(collector, tokenId, 3);

        vm.prank(collector);
        token.burn(collector, tokenId, 1);
        assertEq(token.balanceOf(collector, tokenId), 2);
        assertEq(token.totalSupply(tokenId), 2);
        assertEq(token.totalMintedForToken(tokenId), 3);

        vm.prank(owner);
        token.disableContract();

        vm.prank(minter);
        vm.expectRevert(IRareERC1155.ContractIsDisabled.selector);
        token.mintTo(collector, tokenId, 1);
    }

    function testDisableFreezesOwnerManagedWrites() public {
        vm.prank(owner);
        uint256 tokenId = token.createToken("ipfs://token/1.json", 5, royaltyReceiver);

        vm.prank(owner);
        token.disableContract();

        vm.prank(owner);
        vm.expectRevert(IRareERC1155.ContractIsDisabled.selector);
        token.setMinterApproval(collector, true);

        vm.prank(owner);
        vm.expectRevert(IRareERC1155.ContractIsDisabled.selector);
        token.setDefaultRoyaltyReceiver(collector);

        vm.prank(owner);
        vm.expectRevert(IRareERC1155.ContractIsDisabled.selector);
        token.setRoyaltyReceiverForToken(collector, tokenId);

        vm.prank(owner);
        vm.expectRevert(IRareERC1155.ContractIsDisabled.selector);
        token.updateTokenURI(tokenId, "ipfs://token/updated.json");
    }
}
