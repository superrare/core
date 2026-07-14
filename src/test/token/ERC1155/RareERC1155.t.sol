// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import {IRareERC1155} from "../../../token/ERC1155/IRareERC1155.sol";
import {RareERC1155} from "../../../token/ERC1155/RareERC1155.sol";
import {RareERC1155ContractFactory} from "../../../token/ERC1155/RareERC1155ContractFactory.sol";
import {ITokenCreator} from "../../../token/extensions/ITokenCreator.sol";
import {IERC2981Upgradeable} from "openzeppelin-contracts-upgradeable/interfaces/IERC2981Upgradeable.sol";

contract RareERC1155Test is Test {
    RareERC1155 private token;
    RareERC1155ContractFactory private factory;

    address private owner = address(0x1111);
    address private minter = address(0x2222);
    address private collector = address(0x3333);
    address private royaltyReceiver = address(0x4444);
    address private newOwner = address(0x5555);

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

    function testMaxBatchSize() public {
        assertEq(token.MAX_BATCH_SIZE(), 100);
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
        assertTrue(token.supportsInterface(type(IERC2981Upgradeable).interfaceId));

        vm.prank(minter);
        _mintBatchTo(collector, tokenId, 4);

        assertEq(token.balanceOf(collector, tokenId), 4);
        assertEq(token.totalSupply(tokenId), 4);
        assertEq(token.totalMintedForToken(tokenId), 4);

        (address receiver, uint256 royaltyAmount) = token.royaltyInfo(tokenId, 1 ether);
        assertEq(receiver, royaltyReceiver);
        assertEq(royaltyAmount, 0.1 ether);
    }

    function testTokenCreatorTracksCollectionOwner() public {
        vm.prank(owner);
        uint256 tokenId = token.createToken("ipfs://token/1.json", 10, royaltyReceiver);
        assertEq(token.tokenCreator(tokenId), owner);

        vm.prank(owner);
        token.transferOwnership(newOwner);

        assertEq(token.owner(), newOwner);
        assertEq(token.tokenCreator(tokenId), newOwner);

        vm.prank(newOwner);
        uint256 secondTokenId = token.createToken("ipfs://token/2.json", 10, royaltyReceiver);
        assertEq(token.tokenCreator(secondTokenId), newOwner);
    }

    function testOwnershipCannotBecomeZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert("Ownable: new owner is the zero address");
        token.transferOwnership(address(0));

        vm.prank(owner);
        vm.expectRevert(IRareERC1155.ZeroAddressUnsupported.selector);
        token.renounceOwnership();

        assertEq(token.owner(), owner);
        assertEq(token.tokenCreator(1), owner);
    }

    function testDefaultRoyaltyReceiverUpdatesExistingTokensButPercentageDoesNot() public {
        vm.prank(owner);
        uint256 tokenId = token.createToken("ipfs://token/1.json", 10, owner);

        vm.prank(owner);
        token.setDefaultRoyaltyReceiver(royaltyReceiver);

        (address receiverAfterReceiverUpdate, uint256 amountAfterReceiverUpdate) = token.royaltyInfo(tokenId, 1 ether);
        assertEq(receiverAfterReceiverUpdate, royaltyReceiver);
        assertEq(amountAfterReceiverUpdate, 0.1 ether);

        vm.prank(owner);
        token.setDefaultRoyaltyPercentage(15);

        (address receiverAfterPercentageUpdate, uint256 amountAfterPercentageUpdate) =
            token.royaltyInfo(tokenId, 1 ether);
        assertEq(receiverAfterPercentageUpdate, royaltyReceiver);
        assertEq(amountAfterPercentageUpdate, 0.1 ether);

        (address fallbackReceiver, uint256 fallbackAmount) = token.royaltyInfo(999, 1 ether);
        assertEq(fallbackReceiver, royaltyReceiver);
        assertEq(fallbackAmount, 0.15 ether);

        vm.prank(owner);
        uint256 secondTokenId = token.createToken("ipfs://token/2.json", 10, owner);

        (address secondTokenReceiver, uint256 secondTokenAmount) = token.royaltyInfo(secondTokenId, 1 ether);
        assertEq(secondTokenReceiver, owner);
        assertEq(secondTokenAmount, 0.15 ether);

        vm.prank(owner);
        token.setDefaultRoyaltyReceiver(collector);

        (address firstTokenReceiverAfterSecondReceiverUpdate, uint256 firstTokenAmountAfterSecondReceiverUpdate) =
            token.royaltyInfo(tokenId, 1 ether);
        assertEq(firstTokenReceiverAfterSecondReceiverUpdate, collector);
        assertEq(firstTokenAmountAfterSecondReceiverUpdate, 0.1 ether);

        (address secondTokenReceiverAfterSecondReceiverUpdate, uint256 secondTokenAmountAfterSecondReceiverUpdate) =
            token.royaltyInfo(secondTokenId, 1 ether);
        assertEq(secondTokenReceiverAfterSecondReceiverUpdate, collector);
        assertEq(secondTokenAmountAfterSecondReceiverUpdate, 0.15 ether);
    }

    function testOwnerCanUpdateTokenRoyaltyReceiver() public {
        vm.prank(owner);
        uint256 tokenId = token.createToken("ipfs://token/1.json", 10, owner);

        vm.prank(owner);
        token.setDefaultRoyaltyPercentage(15);

        vm.prank(owner);
        token.setRoyaltyReceiverForToken(tokenId, royaltyReceiver);

        (address receiver, uint256 royaltyAmount) = token.royaltyInfo(tokenId, 1 ether);
        assertEq(receiver, royaltyReceiver);
        assertEq(royaltyAmount, 0.1 ether);
    }

    function testSetDefaultRoyaltyRejectsInvalidConfig() public {
        vm.prank(owner);
        vm.expectRevert(IRareERC1155.ZeroAddressUnsupported.selector);
        token.setDefaultRoyaltyReceiver(address(0));

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IRareERC1155.RoyaltyPercentageTooHigh.selector, 101, 100));
        token.setDefaultRoyaltyPercentage(101);
    }

    function testCreateTokenRejectsZeroRoyaltyReceiver() public {
        vm.prank(owner);
        vm.expectRevert(IRareERC1155.ZeroAddressUnsupported.selector);
        token.createToken("ipfs://token/1.json", 10, address(0));
    }

    function testSetTokenRoyaltyReceiverRejectsInvalidConfig() public {
        vm.prank(owner);
        uint256 tokenId = token.createToken("ipfs://token/1.json", 10, owner);

        vm.prank(owner);
        vm.expectRevert(IRareERC1155.ZeroAddressUnsupported.selector);
        token.setRoyaltyReceiverForToken(tokenId, address(0));

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IRareERC1155.TokenDoesNotExist.selector, tokenId + 1));
        token.setRoyaltyReceiverForToken(tokenId + 1, royaltyReceiver);
    }

    function testMaxSupplyEnforced() public {
        vm.prank(owner);
        uint256 tokenId = token.createToken("ipfs://token/1.json", 2, owner);

        vm.prank(minter);
        _mintBatchTo(collector, tokenId, 2);

        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(IRareERC1155.ExceededMaxSupply.selector, tokenId, 3, 2));
        _mintBatchTo(collector, tokenId, 1);
    }

    function testBurnDoesNotResetMaxSupply() public {
        vm.prank(owner);
        uint256 tokenId = token.createToken("ipfs://token/1.json", 2, owner);

        vm.prank(minter);
        _mintBatchTo(collector, tokenId, 2);

        vm.prank(collector);
        token.burn(collector, tokenId, 1);

        assertEq(token.balanceOf(collector, tokenId), 1);
        assertEq(token.totalSupply(tokenId), 1);
        assertEq(token.totalMintedForToken(tokenId), 2);

        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(IRareERC1155.ExceededMaxSupply.selector, tokenId, 3, 2));
        _mintBatchTo(collector, tokenId, 1);
    }

    function testOnlyOwnerOrApprovedMinterCanMint() public {
        vm.prank(owner);
        uint256 tokenId = token.createToken("ipfs://token/1.json", 5, owner);

        vm.prank(collector);
        vm.expectRevert(abi.encodeWithSelector(IRareERC1155.CallerCannotMint.selector, collector));
        _mintBatchTo(collector, tokenId, 1);

        vm.prank(owner);
        token.setMinterApproval(collector, true);

        vm.prank(collector);
        _mintBatchTo(collector, tokenId, 1);

        assertEq(token.balanceOf(collector, tokenId), 1);
    }

    function testBurnAndDisable() public {
        vm.prank(owner);
        uint256 tokenId = token.createToken("ipfs://token/1.json", 5, owner);

        vm.prank(minter);
        _mintBatchTo(collector, tokenId, 3);

        vm.prank(collector);
        token.burn(collector, tokenId, 1);
        assertEq(token.balanceOf(collector, tokenId), 2);
        assertEq(token.totalSupply(tokenId), 2);
        assertEq(token.totalMintedForToken(tokenId), 3);

        vm.prank(owner);
        token.disableContract();

        vm.prank(minter);
        vm.expectRevert(IRareERC1155.ContractIsDisabled.selector);
        _mintBatchTo(collector, tokenId, 1);
    }

    function testDisableFreezesOwnerManagedWrites() public {
        vm.prank(owner);
        uint256 tokenId = token.createToken("ipfs://token/1.json", 5, owner);

        vm.prank(owner);
        token.disableContract();

        vm.prank(owner);
        vm.expectRevert(IRareERC1155.ContractIsDisabled.selector);
        token.setMinterApproval(collector, true);

        vm.prank(owner);
        vm.expectRevert(IRareERC1155.ContractIsDisabled.selector);
        token.setDefaultRoyaltyReceiver(royaltyReceiver);

        vm.prank(owner);
        vm.expectRevert(IRareERC1155.ContractIsDisabled.selector);
        token.setDefaultRoyaltyPercentage(15);

        vm.prank(owner);
        vm.expectRevert(IRareERC1155.ContractIsDisabled.selector);
        token.setRoyaltyReceiverForToken(tokenId, royaltyReceiver);

        vm.prank(owner);
        vm.expectRevert(IRareERC1155.ContractIsDisabled.selector);
        token.updateTokenURI(tokenId, "ipfs://token/updated.json");
    }

    function testMintBatchToMultipleTokenIds() public {
        vm.startPrank(owner);
        uint256 tokenIdA = token.createToken("ipfs://token/1.json", 10, owner);
        uint256 tokenIdB = token.createToken("ipfs://token/2.json", 10, owner);
        vm.stopPrank();

        uint256[] memory tokenIds = new uint256[](2);
        uint256[] memory amounts = new uint256[](2);
        tokenIds[0] = tokenIdA;
        tokenIds[1] = tokenIdB;
        amounts[0] = 2;
        amounts[1] = 3;

        vm.prank(minter);
        token.mintBatchTo(collector, tokenIds, amounts);

        assertEq(token.balanceOf(collector, tokenIdA), 2);
        assertEq(token.balanceOf(collector, tokenIdB), 3);
        assertEq(token.totalMintedForToken(tokenIdA), 2);
        assertEq(token.totalMintedForToken(tokenIdB), 3);
    }

    function testMintToWrapsBatchMinting() public {
        vm.prank(owner);
        uint256 tokenId = token.createToken("ipfs://token/1.json", 10, owner);

        vm.prank(minter);
        uint256 mintedTokenId = token.mintTo(collector, tokenId, 4);

        assertEq(mintedTokenId, tokenId);
        assertEq(token.balanceOf(collector, tokenId), 4);
        assertEq(token.totalMintedForToken(tokenId), 4);
    }

    function testMintBatchToRejectsBadBatchShape() public {
        uint256[] memory emptyIds = new uint256[](0);
        uint256[] memory emptyAmounts = new uint256[](0);

        vm.prank(minter);
        vm.expectRevert(IRareERC1155.EmptyBatch.selector);
        token.mintBatchTo(collector, emptyIds, emptyAmounts);

        uint256[] memory tokenIds = new uint256[](1);
        uint256[] memory amounts = new uint256[](2);
        tokenIds[0] = 1;
        amounts[0] = 1;
        amounts[1] = 1;

        vm.prank(minter);
        vm.expectRevert(IRareERC1155.BatchLengthMismatch.selector);
        token.mintBatchTo(collector, tokenIds, amounts);
    }

    function testMintBatchToRejectsUnsortedOrDuplicateTokenIds() public {
        uint256[] memory tokenIds = new uint256[](2);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1;
        amounts[1] = 1;

        tokenIds[0] = 1;
        tokenIds[1] = 1;
        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(IRareERC1155.TokenIdsNotStrictlyAscending.selector, 1));
        token.mintBatchTo(collector, tokenIds, amounts);

        tokenIds[0] = 2;
        tokenIds[1] = 1;
        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(IRareERC1155.TokenIdsNotStrictlyAscending.selector, 1));
        token.mintBatchTo(collector, tokenIds, amounts);
    }

    function testMintBatchToRejectsOversizedBatch() public {
        uint256[] memory tokenIds = new uint256[](101);
        uint256[] memory amounts = new uint256[](101);

        for (uint256 i = 0; i < tokenIds.length; i++) {
            tokenIds[i] = i + 1;
            amounts[i] = 1;
        }

        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(IRareERC1155.BatchSizeExceeded.selector, 101, 100));
        token.mintBatchTo(collector, tokenIds, amounts);
    }

    function _mintBatchTo(address _receiver, uint256 _tokenId, uint256 _amount) internal {
        uint256[] memory tokenIds = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        tokenIds[0] = _tokenId;
        amounts[0] = _amount;
        token.mintBatchTo(_receiver, tokenIds, amounts);
    }
}
