// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {IERC721Receiver} from "openzeppelin-contracts/token/ERC721/IERC721Receiver.sol";
import {SovereignBatchMintV5} from "../../../v2/token/ERC721/sovereign/SovereignBatchMintV5.sol";
import {SovereignBatchMintFactory} from "../../../v2/token/ERC721/sovereign/SovereignBatchMintFactory.sol";
import {ICreatorToken} from "../../../token/extensions/ICreatorToken.sol";
import {IV5BatchCollectionPolicy} from "./LazySovereignBatchMintV5.t.sol";

contract StandardV5BatchReceiver is IERC721Receiver {
    address public operator;
    address public from;
    uint256 public tokenId;
    bytes public data;

    function onERC721Received(address operator_, address from_, uint256 tokenId_, bytes calldata data_)
        external
        returns (bytes4)
    {
        operator = operator_;
        from = from_;
        tokenId = tokenId_;
        data = data_;
        return IERC721Receiver.onERC721Received.selector;
    }
}

/// @notice Standard V2 clones using the canonical V5 on a pinned Ethereum mainnet fork.
abstract contract SovereignBatchMintV5ForkBase is Test {
    address internal constant V5 = 0x721C008fdff27BF06E7E123956E2Fe03B63342e3;
    uint256 internal constant FORK_BLOCK = 26350391;
    address internal constant ARTIST = address(0xA11CE);
    address internal constant COLLECTOR = address(0xB0B);
    address internal constant RECIPIENT = address(0xCAFE);
    address internal constant OPERATOR = address(0xBEEF);

    SovereignBatchMintFactory internal factory;
    SovereignBatchMintV5 internal token;
    IV5BatchCollectionPolicy internal validator;

    function setUp() public virtual {
        vm.createSelectFork(vm.envOr("MAINNET_RPC_URL", string("https://eth.drpc.org")), FORK_BLOCK);
        validator = IV5BatchCollectionPolicy(V5);
        factory = new SovereignBatchMintFactory(address(new SovereignBatchMintV5()));
        token = _createCollection(10);
    }

    function _createCollection(uint256 cap) internal returns (SovereignBatchMintV5) {
        vm.prank(ARTIST);
        return SovereignBatchMintV5(factory.createSovereignBatchMint("Standard V5 Collection", "SV5", cap));
    }

    function _customList() internal returns (uint48 listId) {
        vm.startPrank(ARTIST);
        listId = validator.createList("Artist markets");
        validator.applyListToCollection(address(token), listId);
        vm.stopPrank();
    }

    function _setListAccount(uint48 listId, address account, bool allowed) internal {
        address[] memory accounts = new address[](1);
        accounts[0] = account;
        vm.prank(ARTIST);
        if (allowed) validator.addAccountsToList(listId, 1, accounts);
        else validator.removeAccountsFromList(listId, 1, accounts);
    }
}

contract SovereignBatchMintV5Test is SovereignBatchMintV5ForkBase {
    event ConsecutiveTransfer(
        uint256 indexed fromTokenId, uint256 toTokenId, address indexed fromAddress, address indexed toAddress
    );

    function testFactoryInitializesImplementationAndBothCloneOverloadsOnce() public {
        SovereignBatchMintV5 implementation = SovereignBatchMintV5(factory.sovereignNFT());
        assertEq(implementation.owner(), address(this));
        assertEq(validator.getCollectionSecurityPolicy(address(implementation)).tokenType, 721);
        vm.expectRevert("Initializable: contract is already initialized");
        implementation.init("Replay", "BAD", COLLECTOR, 100);

        assertEq(token.owner(), ARTIST);
        assertEq(token.maxTokens(), 10);
        assertEq(token.totalSupply(), 0);
        assertEq(token.getBatchCount(), 0);
        vm.expectRevert("Initializable: contract is already initialized");
        token.init("Replay", "BAD", COLLECTOR, 100);
        assertEq(token.owner(), ARTIST);
        assertEq(token.name(), "Standard V5 Collection");

        vm.prank(COLLECTOR);
        SovereignBatchMintV5 uncapped = SovereignBatchMintV5(factory.createSovereignBatchMint("Uncapped", "UNC"));
        assertEq(uncapped.owner(), COLLECTOR);
        assertEq(uncapped.maxTokens(), type(uint256).max);
        vm.prank(COLLECTOR);
        uncapped.addNewToken("ipfs://uncapped/1");
        assertEq(uncapped.ownerOf(1), COLLECTOR);
        assertEq(token.totalSupply(), 0);
        assertEq(validator.getCollectionSecurityPolicy(address(uncapped)).tokenType, 721);
    }

    function testDefaultRegistrationFailureRollsBackInitializationAndCloneCreation() public {
        SovereignBatchMintV5 fresh = new SovereignBatchMintV5();
        bytes memory validatorCode = V5.code;
        vm.etch(V5, hex"");
        vm.expectRevert(SovereignBatchMintV5.InvalidTransferValidator.selector);
        fresh.init("Failed", "BAD", COLLECTOR, 10);
        assertEq(fresh.owner(), address(0));
        assertEq(fresh.getTransferValidator(), address(0));
        vm.expectRevert(SovereignBatchMintV5.InvalidTransferValidator.selector);
        factory.createSovereignBatchMint("Failed clone", "BAD", 10);

        vm.etch(V5, validatorCode);
        fresh.init("Recovered", "GOOD", ARTIST, 10);
        vm.prank(ARTIST);
        fresh.addNewToken("ipfs://recovered/1");
        vm.prank(ARTIST);
        fresh.approve(OPERATOR, 1);
        vm.expectRevert();
        vm.prank(OPERATOR);
        fresh.transferFrom(ARTIST, COLLECTOR, 1);
        assertEq(fresh.ownerOf(1), ARTIST);
        assertEq(fresh.totalSupply(), 1);
    }

    function testImmediateMintToAndAddNewTokenPreserveReceiverCreatorAndRoyalties() public {
        StandardV5BatchReceiver receiver = new StandardV5BatchReceiver();
        vm.startPrank(ARTIST);
        token.mintTo("ipfs://immediate/1", address(receiver), RECIPIENT);
        token.addNewToken("ipfs://immediate/2");
        vm.stopPrank();
        assertEq(receiver.operator(), ARTIST);
        assertEq(receiver.from(), address(0));
        assertEq(receiver.tokenId(), 1);
        assertEq(token.ownerOf(1), address(receiver));
        assertEq(token.ownerOf(2), ARTIST);
        assertEq(token.tokenCreator(1), ARTIST);
        assertEq(token.tokenURI(1), "ipfs://immediate/1");
        assertEq(token.tokenURI(2), "ipfs://immediate/2");
        assertEq(token.totalSupply(), 2);
        assertEq(token.balanceOf(address(receiver)), 1);
        assertEq(token.balanceOf(ARTIST), 1);
        (address royaltyReceiver, uint256 amount) = token.royaltyInfo(1, 1 ether);
        assertEq(royaltyReceiver, RECIPIENT);
        assertEq(amount, 0.1 ether);
        (royaltyReceiver, amount) = token.royaltyInfo(2, 1 ether);
        assertEq(royaltyReceiver, ARTIST);
        assertEq(amount, 0.1 ether);
    }

    function testOnlyOwnerCanMintAndSafeMintFailureDoesNotConsumeAnId() public {
        vm.startPrank(COLLECTOR);
        vm.expectRevert("Ownable: caller is not the owner");
        token.mintTo("ipfs://unauthorized", COLLECTOR, COLLECTOR);
        vm.expectRevert("Ownable: caller is not the owner");
        token.addNewToken("ipfs://unauthorized");
        vm.expectRevert("Ownable: caller is not the owner");
        token.batchMint("ipfs://unauthorized", 2);
        vm.stopPrank();
        vm.expectRevert("ERC721: transfer to non ERC721Receiver implementer");
        vm.prank(ARTIST);
        token.mintTo("ipfs://rejected", address(factory), RECIPIENT);
        assertEq(token.totalSupply(), 0);
        assertEq(token.balanceOf(address(factory)), 0);
        vm.expectRevert("ERC721: invalid token ID");
        token.ownerOf(1);
        vm.prank(ARTIST);
        token.mintTo("ipfs://accepted", COLLECTOR, RECIPIENT);
        assertEq(token.ownerOf(1), COLLECTOR);
        assertEq(token.tokenURI(1), "ipfs://accepted");
        assertEq(token.totalSupply(), 1);
    }

    function testBatchMintEmitsConsecutiveRangeAndCountsSupplyBeforeMaterialization() public {
        vm.expectEmit(true, true, true, true, address(token));
        emit ConsecutiveTransfer(1, 3, address(0), ARTIST);
        vm.prank(ARTIST);
        token.batchMint("ipfs://batch", 3);
        (uint256 start, uint256 end, string memory uri) = token.getBatchInfo(0);
        assertEq(start, 1);
        assertEq(end, 3);
        assertEq(uri, "ipfs://batch");
        assertEq(token.totalSupply(), 3);
        assertEq(token.balanceOf(ARTIST), 0);
        assertEq(token.ownerOf(1), ARTIST);
        assertEq(token.ownerOf(3), ARTIST);
        assertEq(token.getApproved(1), address(0));
        assertEq(token.tokenURI(3), "ipfs://batch/3.json");
        vm.prank(ARTIST, ARTIST);
        token.transferFrom(ARTIST, COLLECTOR, 3);
        assertEq(token.totalSupply(), 3);
        assertEq(token.balanceOf(ARTIST), 0);
        assertEq(token.balanceOf(COLLECTOR), 1);
        assertEq(token.ownerOf(1), ARTIST);
        assertEq(token.ownerOf(3), COLLECTOR);
    }

    function testMixedImmediateAndMultipleBatchMintsShareIdsAndCap() public {
        token = _createCollection(5);
        vm.startPrank(ARTIST, ARTIST);
        token.addNewToken("ipfs://single/1");
        token.batchMint("ipfs://first", 2);
        token.mintTo("ipfs://single/4", COLLECTOR, RECIPIENT);
        token.batchMint("ipfs://second", 1);
        vm.expectRevert("batchMint::exceeded maxTokens");
        token.batchMint("ipfs://overflow", 1);
        vm.expectRevert("_createToken::exceeded maxTokens");
        token.addNewToken("ipfs://overflow");
        token.transferFrom(ARTIST, RECIPIENT, 5);
        token.transferFrom(ARTIST, COLLECTOR, 2);
        vm.stopPrank();
        (uint256 start, uint256 end,) = token.getBatchInfo(0);
        assertEq(start, 2);
        assertEq(end, 3);
        (start, end,) = token.getBatchInfo(1);
        assertEq(start, 5);
        assertEq(end, 5);
        assertEq(token.getBatchCount(), 2);
        assertEq(token.totalSupply(), 5);
        assertEq(token.ownerOf(1), ARTIST);
        assertEq(token.ownerOf(3), ARTIST);
        assertEq(token.ownerOf(4), COLLECTOR);
        assertEq(token.ownerOf(5), RECIPIENT);
        assertEq(token.balanceOf(ARTIST), 1);
        assertEq(token.balanceOf(COLLECTOR), 2);
        assertEq(token.balanceOf(RECIPIENT), 1);
        assertEq(token.tokenURI(2), "ipfs://first/2.json");
        assertEq(token.tokenURI(4), "ipfs://single/4");
        assertEq(token.tokenURI(5), "ipfs://second/5.json");
    }

    function testBurnUsesCurrentSupplyForBatchCapButImmediateMintUsesNextId() public {
        token = _createCollection(3);
        vm.prank(ARTIST);
        token.batchMint("ipfs://initial", 3);
        vm.expectRevert("Must be owner of token.");
        vm.prank(COLLECTOR);
        token.burn(1);
        vm.startPrank(ARTIST, ARTIST);
        token.burn(1);
        assertEq(token.totalSupply(), 2);
        vm.expectRevert("ERC721: invalid token ID");
        token.ownerOf(1);
        vm.expectRevert("ERC721: approved query for nonexistent token");
        token.getApproved(1);
        token.batchMint("ipfs://replacement", 1);
        assertEq(token.totalSupply(), 3);
        assertEq(token.ownerOf(4), ARTIST);
        token.transferFrom(ARTIST, COLLECTOR, 2);
        validator.setRulesetOfCollection(address(token), 2, address(0), 0, 0);
        vm.stopPrank();
        vm.expectRevert();
        vm.prank(COLLECTOR, COLLECTOR);
        token.transferFrom(COLLECTOR, RECIPIENT, 2);
        vm.prank(COLLECTOR);
        token.burn(2);
        assertEq(token.totalSupply(), 2);
        assertEq(token.balanceOf(COLLECTOR), 0);
        vm.expectRevert("ERC721: invalid token ID");
        token.ownerOf(2);
        vm.expectRevert("_createToken::exceeded maxTokens");
        vm.prank(ARTIST);
        token.addNewToken("ipfs://id-exceeds-cap");
        assertEq(token.totalSupply(), 2);
    }

    function testMetadataUpdatesAndLockCoverImmediateAndBatchTokens() public {
        vm.startPrank(ARTIST, ARTIST);
        token.addNewToken("ipfs://single/1");
        token.batchMint("ipfs://hidden", 2);
        token.updateTokenURI(1, "ipfs://single/revealed");
        token.updateBatchBaseURI(0, "ipfs://revealed");
        token.updateTokenURI(3, "ipfs://special/3");
        token.transferFrom(ARTIST, COLLECTOR, 2);
        token.updateTokenURI(2, "ipfs://special/2");
        vm.stopPrank();
        vm.expectRevert("Only token creator can update URI");
        vm.prank(COLLECTOR);
        token.updateTokenURI(2, "ipfs://not-creator");
        vm.startPrank(ARTIST);
        token.lockTokenURIs();
        vm.expectRevert("Token URIs are locked");
        token.updateTokenURI(1, "ipfs://locked");
        vm.expectRevert("Token URIs are locked");
        token.updateBatchBaseURI(0, "ipfs://locked");
        vm.stopPrank();
        assertTrue(token.areTokenURIsLocked());
        assertEq(token.tokenURI(1), "ipfs://single/revealed");
        assertEq(token.tokenURI(2), "ipfs://special/2");
        assertEq(token.tokenURI(3), "ipfs://special/3");
    }

    function testDisabledCollectionStopsMintAndMetadataButPreservesTransferAndBurn() public {
        vm.startPrank(ARTIST, ARTIST);
        token.addNewToken("ipfs://single/1");
        token.batchMint("ipfs://batch", 1);
        token.disableContract();
        vm.expectRevert("Contract must not be disabled.");
        token.addNewToken("ipfs://disabled");
        vm.expectRevert("Contract must not be disabled.");
        token.mintTo("ipfs://disabled", COLLECTOR, ARTIST);
        vm.expectRevert("Contract must not be disabled.");
        token.batchMint("ipfs://disabled", 1);
        vm.expectRevert("Contract must not be disabled.");
        token.updateTokenURI(1, "ipfs://disabled");
        vm.expectRevert("Contract must not be disabled.");
        token.updateBatchBaseURI(0, "ipfs://disabled");
        token.transferFrom(ARTIST, COLLECTOR, 1);
        token.burn(2);
        vm.stopPrank();
        assertEq(token.ownerOf(1), COLLECTOR);
        assertEq(token.totalSupply(), 1);
    }

    function testImmediateRoyaltiesSnapshotWhileBatchRoyaltiesFollowDefaultsAfterTransfer() public {
        vm.startPrank(ARTIST, ARTIST);
        token.mintTo("ipfs://single/1", COLLECTOR, RECIPIENT);
        token.addNewToken("ipfs://single/2");
        token.batchMint("ipfs://batch", 2);
        token.setDefaultRoyaltyReceiver(OPERATOR);
        token.setDefaultRoyaltyPercentage(7);
        token.transferFrom(ARTIST, COLLECTOR, 3);
        vm.stopPrank();
        (address receiver, uint256 amount) = token.royaltyInfo(3, 2 ether);
        assertEq(receiver, OPERATOR);
        assertEq(amount, 0.14 ether);
        vm.startPrank(ARTIST);
        token.setDefaultRoyaltyReceiver(COLLECTOR);
        token.setDefaultRoyaltyPercentage(5);
        token.setRoyaltyReceiverForToken(RECIPIENT, 4);
        vm.stopPrank();
        (receiver, amount) = token.royaltyInfo(1, 2 ether);
        assertEq(receiver, RECIPIENT);
        assertEq(amount, 0.2 ether);
        (receiver, amount) = token.royaltyInfo(2, 2 ether);
        assertEq(receiver, ARTIST);
        assertEq(amount, 0.2 ether);
        (receiver, amount) = token.royaltyInfo(3, 2 ether);
        assertEq(receiver, COLLECTOR);
        assertEq(amount, 0.1 ether);
        (receiver, amount) = token.royaltyInfo(4, 2 ether);
        assertEq(receiver, RECIPIENT);
        assertEq(amount, 0.1 ether);
    }

    function testDiscoveredValidationFunctionActuallyEnforcesActivePolicy() public {
        assertTrue(token.supportsInterface(type(ICreatorToken).interfaceId));
        (bytes4 selector, bool isView) = token.getTransferValidationFunction();
        assertTrue(isView);
        bytes memory transfer = abi.encodeWithSelector(selector, OPERATOR, ARTIST, COLLECTOR, uint256(1));
        address validatorAddress = token.getTransferValidator();
        vm.prank(address(token));
        (bool denied,) = validatorAddress.staticcall(transfer);
        assertFalse(denied);
        uint48 listId = _customList();
        _setListAccount(listId, OPERATOR, true);
        vm.prank(address(token));
        (bool allowed,) = validatorAddress.staticcall(transfer);
        assertTrue(allowed);
    }

    function testApprovedButDisallowedBatchTransferRollsBackMaterializationAndApproval() public {
        vm.startPrank(ARTIST);
        token.batchMint("ipfs://batch", 2);
        token.approve(OPERATOR, 1);
        vm.stopPrank();
        vm.expectRevert();
        vm.prank(OPERATOR);
        token.transferFrom(ARTIST, COLLECTOR, 1);
        assertEq(token.ownerOf(1), ARTIST);
        assertEq(token.totalSupply(), 2);
        assertEq(token.balanceOf(ARTIST), 0);
        assertEq(token.balanceOf(COLLECTOR), 0);
        assertEq(token.getApproved(1), OPERATOR);
        uint48 listId = _customList();
        _setListAccount(listId, OPERATOR, true);
        vm.prank(OPERATOR);
        token.transferFrom(ARTIST, COLLECTOR, 1);
        assertEq(token.ownerOf(1), COLLECTOR);
        assertEq(token.totalSupply(), 2);
        assertEq(token.getApproved(1), address(0));
    }

    function testBatchOwnerCannotBeForgedBeforeMaterialization() public {
        vm.startPrank(ARTIST);
        token.batchMint("ipfs://batch", 3);
        token.setApprovalForAll(OPERATOR, true);
        vm.stopPrank();
        vm.expectRevert("ERC721: transfer from incorrect owner");
        vm.prank(OPERATOR, OPERATOR);
        token.transferFrom(OPERATOR, COLLECTOR, 1);
        vm.expectRevert("ERC721: transfer from incorrect owner");
        vm.prank(OPERATOR, OPERATOR);
        token.safeTransferFrom(OPERATOR, COLLECTOR, 2);
        vm.expectRevert("ERC721: transfer from incorrect owner");
        vm.prank(OPERATOR, OPERATOR);
        token.safeTransferFrom(OPERATOR, COLLECTOR, 3, hex"1234");
        uint48 listId = _customList();
        _setListAccount(listId, RECIPIENT, true);
        vm.expectRevert("ERC721: transfer from incorrect owner");
        vm.prank(OPERATOR, OPERATOR);
        token.transferFrom(RECIPIENT, COLLECTOR, 1);
        assertEq(token.totalSupply(), 3);
        assertEq(token.balanceOf(ARTIST), 0);
        assertEq(token.balanceOf(OPERATOR), 0);
        assertEq(token.balanceOf(RECIPIENT), 0);
        assertEq(token.balanceOf(COLLECTOR), 0);
        for (uint256 id = 1; id <= 3; ++id) {
            assertEq(token.ownerOf(id), ARTIST);
            assertEq(token.getApproved(id), address(0));
        }
        assertTrue(token.isApprovedForAll(ARTIST, OPERATOR));
        vm.expectRevert();
        vm.prank(OPERATOR, OPERATOR);
        token.transferFrom(ARTIST, COLLECTOR, 1);
        _setListAccount(listId, OPERATOR, true);
        vm.prank(OPERATOR, OPERATOR);
        token.transferFrom(ARTIST, COLLECTOR, 1);
        assertEq(token.ownerOf(1), COLLECTOR);
        assertEq(token.totalSupply(), 3);
        assertEq(token.balanceOf(COLLECTOR), 1);
    }

    function testAllowedOperatorThenRevocationBlocksExistingTokenApproval() public {
        uint48 listId = _customList();
        _setListAccount(listId, OPERATOR, true);
        vm.startPrank(ARTIST);
        token.mintTo("ipfs://single/1", COLLECTOR, ARTIST);
        token.batchMint("ipfs://batch", 1);
        token.setApprovalForAll(OPERATOR, true);
        vm.stopPrank();
        vm.prank(OPERATOR);
        token.transferFrom(ARTIST, COLLECTOR, 2);
        vm.startPrank(COLLECTOR);
        token.approve(OPERATOR, 1);
        token.approve(OPERATOR, 2);
        vm.stopPrank();
        vm.prank(OPERATOR);
        token.transferFrom(COLLECTOR, RECIPIENT, 1);
        assertEq(token.getApproved(1), address(0));
        _setListAccount(listId, OPERATOR, false);
        vm.expectRevert();
        vm.prank(OPERATOR);
        token.transferFrom(COLLECTOR, RECIPIENT, 2);
        assertEq(token.ownerOf(2), COLLECTOR);
        assertEq(token.getApproved(2), OPERATOR);
        assertEq(token.totalSupply(), 2);
    }

    function testBothSafeTransferOverloadsEnforcePolicyAndDeliverReceiverData() public {
        StandardV5BatchReceiver receiver = new StandardV5BatchReceiver();
        vm.startPrank(ARTIST);
        token.mintTo("ipfs://single/1", ARTIST, ARTIST);
        token.batchMint("ipfs://batch", 1);
        token.setApprovalForAll(OPERATOR, true);
        vm.stopPrank();
        vm.expectRevert();
        vm.prank(OPERATOR);
        token.safeTransferFrom(ARTIST, address(receiver), 1);
        vm.expectRevert();
        vm.prank(OPERATOR);
        token.safeTransferFrom(ARTIST, address(receiver), 2, hex"1234");
        assertEq(token.totalSupply(), 2);
        assertEq(token.balanceOf(ARTIST), 1);
        assertEq(receiver.tokenId(), 0);
        uint48 listId = _customList();
        _setListAccount(listId, OPERATOR, true);
        vm.prank(OPERATOR);
        token.safeTransferFrom(ARTIST, address(receiver), 1);
        assertEq(receiver.operator(), OPERATOR);
        assertEq(receiver.from(), ARTIST);
        assertEq(receiver.tokenId(), 1);
        assertEq(receiver.data(), hex"");
        vm.prank(OPERATOR);
        token.safeTransferFrom(ARTIST, address(receiver), 2, hex"1234");
        assertEq(receiver.tokenId(), 2);
        assertEq(receiver.data(), hex"1234");
        assertEq(token.ownerOf(1), address(receiver));
        assertEq(token.ownerOf(2), address(receiver));
        assertEq(token.balanceOf(address(receiver)), 2);
        assertEq(token.totalSupply(), 2);
    }

    function testSafeTransferToNonReceiverRollsBackBatchMaterialization() public {
        uint48 listId = _customList();
        _setListAccount(listId, OPERATOR, true);
        vm.startPrank(ARTIST);
        token.batchMint("ipfs://batch", 1);
        token.approve(OPERATOR, 1);
        vm.stopPrank();
        vm.expectRevert("ERC721: transfer to non ERC721Receiver implementer");
        vm.prank(OPERATOR);
        token.safeTransferFrom(ARTIST, address(factory), 1, hex"1234");
        assertEq(token.ownerOf(1), ARTIST);
        assertEq(token.totalSupply(), 1);
        assertEq(token.balanceOf(ARTIST), 0);
        assertEq(token.balanceOf(address(factory)), 0);
        assertEq(token.getApproved(1), OPERATOR);
    }

    function testOrdinaryTokenOwnersCanTransferBeforeAndAfterBatchMaterialization() public {
        vm.startPrank(ARTIST, ARTIST);
        token.batchMint("ipfs://batch", 1);
        token.transferFrom(ARTIST, COLLECTOR, 1);
        vm.stopPrank();
        vm.prank(COLLECTOR, COLLECTOR);
        token.transferFrom(COLLECTOR, RECIPIENT, 1);
        assertEq(token.ownerOf(1), RECIPIENT);
        assertEq(token.totalSupply(), 1);
        assertEq(token.balanceOf(COLLECTOR), 0);
        assertEq(token.balanceOf(RECIPIENT), 1);
    }

    function testOwnerCanDisableAndRestoreValidatorWithoutLosingPolicy() public {
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(COLLECTOR);
        token.setTransferValidator(address(0));
        vm.startPrank(ARTIST);
        token.batchMint("ipfs://batch", 1);
        token.setApprovalForAll(OPERATOR, true);
        token.setTransferValidator(address(0));
        vm.stopPrank();
        vm.prank(OPERATOR);
        token.transferFrom(ARTIST, COLLECTOR, 1);
        vm.prank(ARTIST);
        token.setTransferValidator(V5);
        vm.prank(COLLECTOR);
        token.approve(OPERATOR, 1);
        vm.expectRevert();
        vm.prank(OPERATOR);
        token.transferFrom(COLLECTOR, RECIPIENT, 1);
        assertEq(token.ownerOf(1), COLLECTOR);
        assertEq(token.getApproved(1), OPERATOR);
        uint48 listId = _customList();
        _setListAccount(listId, OPERATOR, true);
        vm.prank(OPERATOR);
        token.transferFrom(COLLECTOR, RECIPIENT, 1);
        assertEq(token.ownerOf(1), RECIPIENT);
    }

    function testValidatorChangeFailureIsAtomicAndOriginalPolicyStillEnforced() public {
        vm.startPrank(ARTIST);
        token.batchMint("ipfs://batch", 1);
        vm.expectRevert(SovereignBatchMintV5.InvalidTransferValidator.selector);
        token.setTransferValidator(COLLECTOR);
        // A real factory has code but cannot accept V5 collection registration.
        vm.expectRevert();
        token.setTransferValidator(address(factory));
        token.approve(OPERATOR, 1);
        vm.stopPrank();
        assertEq(token.getTransferValidator(), V5);
        vm.expectRevert();
        vm.prank(OPERATOR);
        token.transferFrom(ARTIST, COLLECTOR, 1);
        assertEq(token.ownerOf(1), ARTIST);
        assertEq(token.totalSupply(), 1);
        assertEq(token.balanceOf(ARTIST), 0);
        assertEq(token.getApproved(1), OPERATOR);
    }

    function testValidatorRequiresExplicitApprovalAndSkipsItsOwnPolicyCheck() public {
        vm.prank(ARTIST);
        token.batchMint("ipfs://batch", 1);
        assertFalse(token.isApprovedForAll(ARTIST, V5));
        vm.expectRevert("ERC721: caller is not token owner or approved");
        vm.prank(V5);
        token.transferFrom(ARTIST, COLLECTOR, 1);
        vm.startPrank(ARTIST);
        validator.setRulesetOfCollection(address(token), 2, address(0), 0, 0);
        token.setApprovalForAll(V5, true);
        vm.stopPrank();
        vm.prank(V5);
        token.transferFrom(ARTIST, COLLECTOR, 1);
        assertEq(token.ownerOf(1), COLLECTOR);
        assertEq(token.totalSupply(), 1);
    }
}
