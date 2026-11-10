// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {IERC721Receiver} from "openzeppelin-contracts/token/ERC721/IERC721Receiver.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {LazySovereignBatchMintV5} from "../../../v2/token/ERC721/sovereign/LazySovereignBatchMintV5.sol";
import {LazySovereignBatchMintFactory} from "../../../v2/token/ERC721/sovereign/LazySovereignBatchMintFactory.sol";
import {ICreatorToken} from "../../../token/extensions/ICreatorToken.sol";
import {MarketplaceSettingsV1} from "../../../marketplace/MarketplaceSettingsV1.sol";
import {MarketplaceSettingsV2} from "../../../marketplace/MarketplaceSettingsV2.sol";
import {MarketplaceSettingsV3} from "../../../marketplace/MarketplaceSettingsV3.sol";
import {Payments} from "../../../payments/Payments.sol";
import {RareBatchListingMarketplace} from "../../../v2/marketplace/RareBatchListingMarketplace.sol";
import {RareBatchAuctionHouse} from "../../../v2/auctionhouse/RareBatchAuctionHouse.sol";
import {ERC20ApprovalManager} from "../../../v2/approver/ERC20/ERC20ApprovalManager.sol";
import {ERC721ApprovalManager} from "../../../v2/approver/ERC721/ERC721ApprovalManager.sol";
import {NetworkConfig} from "../../../../script/NetworkConfig.s.sol";

interface IV5BatchCollectionPolicy {
    struct CollectionSecurityPolicy {
        uint8 rulesetId;
        uint48 listId;
        address customRuleset;
        uint8 globalOptions;
        uint16 rulesetOptions;
        uint16 tokenType;
    }

    function createList(string calldata name) external returns (uint48);
    function applyListToCollection(address collection, uint48 listId) external;
    function addAccountsToList(uint48 listId, uint8 listType, address[] calldata accounts) external;
    function removeAccountsFromList(uint48 listId, uint8 listType, address[] calldata accounts) external;
    function setRulesetOfCollection(
        address collection,
        uint8 rulesetId,
        address customRuleset,
        uint8 globalOptions,
        uint16 rulesetOptions
    ) external;
    function getCollectionSecurityPolicy(address collection) external view returns (CollectionSecurityPolicy memory);
}

contract V5BatchReceiver is IERC721Receiver {
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

/// @notice All policy decisions use the deployed canonical V5 at the pinned Ethereum mainnet block.
abstract contract LazySovereignBatchMintV5ForkBase is Test {
    address internal constant V5 = 0x721C008fdff27BF06E7E123956E2Fe03B63342e3;
    uint256 internal constant FORK_BLOCK = 26350391;
    address internal constant ARTIST = address(0xA11CE);
    address internal constant COLLECTOR = address(0xB0B);
    address internal constant RECIPIENT = address(0xCAFE);
    address internal constant OPERATOR = address(0xBEEF);

    LazySovereignBatchMintFactory internal factory;
    LazySovereignBatchMintV5 internal token;
    IV5BatchCollectionPolicy internal validator;

    function setUp() public virtual {
        vm.createSelectFork(vm.envOr("MAINNET_RPC_URL", string("https://eth.drpc.org")), FORK_BLOCK);
        validator = IV5BatchCollectionPolicy(V5);
        factory = new LazySovereignBatchMintFactory(address(new LazySovereignBatchMintV5()));
        token = _createCollection(3);
        vm.prank(ARTIST);
        token.prepareMint("ipfs://portraits", 3);
    }

    function _createCollection(uint256 cap) internal returns (LazySovereignBatchMintV5) {
        vm.prank(ARTIST);
        return LazySovereignBatchMintV5(factory.createLazySovereignBatchMint("V5 Collection", "V5", cap));
    }

    function _materialize(uint256 id, address to) internal {
        vm.prank(ARTIST, ARTIST);
        token.transferFrom(ARTIST, to, id);
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

contract LazySovereignBatchMintV5Test is LazySovereignBatchMintV5ForkBase {
    function testFactoryLocksImplementationAndClonesInitializeOnce() public {
        LazySovereignBatchMintV5 implementation = LazySovereignBatchMintV5(factory.lazySovereignNFT());
        assertEq(implementation.owner(), address(this));
        assertEq(validator.getCollectionSecurityPolicy(address(implementation)).tokenType, 721);
        vm.expectRevert("Initializable: contract is already initialized");
        implementation.init("Replay", "BAD", COLLECTOR, 100);

        assertEq(token.owner(), ARTIST);
        assertEq(token.tokenCreator(1), ARTIST);
        assertEq(token.maxTokens(), 3);
        assertEq(token.getTransferValidator(), V5);
        assertEq(validator.getCollectionSecurityPolicy(address(token)).tokenType, 721);
        vm.expectRevert("Initializable: contract is already initialized");
        token.init("Replay", "BAD", COLLECTOR, 100);
        assertEq(token.owner(), ARTIST);
        assertEq(token.name(), "V5 Collection");

        LazySovereignBatchMintV5 second = _createCollection(7);
        assertEq(second.owner(), ARTIST);
        assertEq(second.maxTokens(), 7);
        assertEq(second.totalSupply(), 0);
        assertEq(second.getBatchCount(), 0);
        assertEq(validator.getCollectionSecurityPolicy(address(second)).tokenType, 721);
    }

    function testDefaultRegistrationRevertRollsBackInitialization() public {
        LazySovereignBatchMintV5 fresh = new LazySovereignBatchMintV5();
        bytes memory validatorCode = V5.code;
        vm.etch(V5, hex"");
        vm.expectRevert(LazySovereignBatchMintV5.InvalidTransferValidator.selector);
        fresh.init("Failed", "BAD", COLLECTOR, 100);
        assertEq(fresh.owner(), address(0));
        assertEq(fresh.getTransferValidator(), address(0));
        vm.expectRevert(LazySovereignBatchMintV5.InvalidTransferValidator.selector);
        factory.createLazySovereignBatchMint("Failed clone", "BAD", 3);

        vm.etch(V5, validatorCode);
        fresh.init("Recovered", "GOOD", ARTIST, 3);
        assertEq(fresh.owner(), ARTIST);
        assertEq(validator.getCollectionSecurityPolicy(address(fresh)).tokenType, 721);
    }

    function testReservationThenTransferMaterializesExactlyOnce() public {
        assertEq(token.getBatchCount(), 1);
        (uint256 start, uint256 end, string memory baseURI) = token.getBatchInfo(0);
        assertEq(start, 1);
        assertEq(end, 3);
        assertEq(baseURI, "ipfs://portraits");
        assertEq(token.ownerOf(1), ARTIST);
        assertEq(token.ownerOf(3), ARTIST);
        assertEq(token.totalSupply(), 0);
        assertEq(token.balanceOf(ARTIST), 0);
        vm.expectRevert("ERC721: approved query for nonexistent token");
        token.getApproved(1);
        vm.expectRevert("ERC721: invalid token ID");
        token.ownerOf(4);

        _materialize(1, COLLECTOR);
        assertEq(token.ownerOf(1), COLLECTOR);
        assertEq(token.ownerOf(2), ARTIST);
        assertEq(token.totalSupply(), 1);
        assertEq(token.balanceOf(ARTIST), 0);
        assertEq(token.balanceOf(COLLECTOR), 1);
        vm.prank(COLLECTOR, COLLECTOR);
        token.transferFrom(COLLECTOR, RECIPIENT, 1);
        assertEq(token.totalSupply(), 1);
        assertEq(token.balanceOf(COLLECTOR), 0);
        assertEq(token.balanceOf(RECIPIENT), 1);
    }

    function testMultipleBatchesKeepReservedRangesAndMaterializeOutOfOrder() public {
        LazySovereignBatchMintV5 batches = _createCollection(5);
        vm.startPrank(ARTIST, ARTIST);
        batches.prepareMint("ipfs://first", 2);
        batches.prepareMint("ipfs://second", 3);
        vm.expectRevert("prepareMint::exceeded maxTokens");
        batches.prepareMint("ipfs://over-cap", 1);
        batches.transferFrom(ARTIST, COLLECTOR, 5);
        batches.transferFrom(ARTIST, RECIPIENT, 1);
        vm.stopPrank();
        (uint256 start, uint256 end, string memory baseURI) = batches.getBatchInfo(1);
        assertEq(start, 3);
        assertEq(end, 5);
        assertEq(baseURI, "ipfs://second");
        assertEq(batches.getBatchCount(), 2);
        assertEq(batches.ownerOf(1), RECIPIENT);
        assertEq(batches.ownerOf(2), ARTIST);
        assertEq(batches.ownerOf(3), ARTIST);
        assertEq(batches.ownerOf(5), COLLECTOR);
        assertEq(batches.tokenURI(1), "ipfs://first/1.json");
        assertEq(batches.tokenURI(5), "ipfs://second/5.json");
        assertEq(batches.totalSupply(), 2);
    }

    function testOnlyOwnerReservesAndCancelledOrBurnedIdsNeverRestoreCap() public {
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(COLLECTOR);
        token.prepareMint("ipfs://unauthorized", 1);
        vm.expectRevert("burn::only owner can cancel unminted lazy token");
        vm.prank(COLLECTOR);
        token.burn(2);
        vm.prank(ARTIST);
        token.burn(2);
        assertEq(token.totalSupply(), 0);
        vm.expectRevert("ERC721::invalid token ID");
        token.ownerOf(2);
        vm.expectRevert("ERC721::invalid token ID");
        vm.prank(ARTIST);
        token.transferFrom(ARTIST, COLLECTOR, 2);

        _materialize(1, COLLECTOR);
        vm.prank(ARTIST);
        validator.setRulesetOfCollection(address(token), 2, address(0), 0, 0);
        vm.expectRevert();
        vm.prank(COLLECTOR, COLLECTOR);
        token.transferFrom(COLLECTOR, RECIPIENT, 1);
        vm.prank(COLLECTOR);
        token.burn(1);
        assertEq(token.totalSupply(), 0);
        assertEq(token.balanceOf(COLLECTOR), 0);
        vm.expectRevert("ERC721::invalid token ID");
        token.ownerOf(1);
        vm.expectRevert("prepareMint::exceeded maxTokens");
        vm.prank(ARTIST);
        token.prepareMint("ipfs://no-reuse", 1);
        assertEq(token.getBatchCount(), 1);
        assertEq(token.ownerOf(3), ARTIST);
    }

    function testMetadataUpdatesApplyBeforeAndAfterMaterializationAndLock() public {
        vm.startPrank(ARTIST);
        token.updateBatchBaseURI(0, "ipfs://revealed");
        token.updateTokenURI(2, "ipfs://special/2.json");
        vm.stopPrank();
        _materialize(1, COLLECTOR);
        assertEq(token.tokenURI(1), "ipfs://revealed/1.json");
        assertEq(token.tokenURI(2), "ipfs://special/2.json");
        vm.expectRevert("Only token creator can update URI");
        vm.prank(COLLECTOR);
        token.updateTokenURI(1, "ipfs://not-creator");
        vm.startPrank(ARTIST);
        token.updateTokenURI(1, "ipfs://special/1.json");
        token.lockTokenURIs();
        vm.expectRevert("Token URIs are locked");
        token.updateBatchBaseURI(0, "ipfs://replacement");
        vm.expectRevert("Token URIs are locked");
        token.updateTokenURI(2, "ipfs://replacement/2.json");
        vm.stopPrank();
        _materialize(2, COLLECTOR);
        assertTrue(token.areTokenURIsLocked());
        assertEq(token.tokenURI(1), "ipfs://special/1.json");
        assertEq(token.tokenURI(2), "ipfs://special/2.json");
        assertEq(token.tokenURI(3), "ipfs://revealed/3.json");
    }

    function testInheritedRoyaltyControlsRemainDynamicNotLegacyMintSnapshots() public {
        (address receiver, uint256 amount) = token.royaltyInfo(1, 1 ether);
        assertEq(receiver, ARTIST);
        assertEq(amount, 0.1 ether);
        _materialize(1, COLLECTOR);
        vm.startPrank(ARTIST);
        token.setDefaultRoyaltyReceiver(RECIPIENT);
        token.setDefaultRoyaltyPercentage(7);
        token.setRoyaltyReceiverForToken(OPERATOR, 2);
        vm.stopPrank();
        (receiver, amount) = token.royaltyInfo(1, 2 ether);
        assertEq(receiver, RECIPIENT);
        assertEq(amount, 0.14 ether);
        (receiver, amount) = token.royaltyInfo(2, 2 ether);
        assertEq(receiver, OPERATOR);
        assertEq(amount, 0.14 ether);
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(COLLECTOR);
        token.setDefaultRoyaltyPercentage(5);
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(COLLECTOR);
        token.setDefaultRoyaltyReceiver(COLLECTOR);
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(COLLECTOR);
        token.setRoyaltyReceiverForToken(COLLECTOR, 2);
        vm.prank(ARTIST);
        token.setDefaultRoyaltyPercentage(0);
        (, amount) = token.royaltyInfo(1, 2 ether);
        assertEq(amount, 0);
        (, amount) = token.royaltyInfo(2, 2 ether);
        assertEq(amount, 0);
    }

    function testDiscoveredValidationFunctionEnforcesTheActivePolicy() public {
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

    function testApprovedButDeniedLazyTransferRollsBackMintSupplyAndApproval() public {
        vm.prank(ARTIST);
        token.setApprovalForAll(OPERATOR, true);
        vm.expectRevert();
        vm.prank(OPERATOR);
        token.transferFrom(ARTIST, COLLECTOR, 1);
        assertEq(token.ownerOf(1), ARTIST);
        assertEq(token.totalSupply(), 0);
        assertEq(token.balanceOf(ARTIST), 0);
        assertEq(token.balanceOf(COLLECTOR), 0);
        assertTrue(token.isApprovedForAll(ARTIST, OPERATOR));
        vm.expectRevert("ERC721: approved query for nonexistent token");
        token.getApproved(1);

        uint48 listId = _customList();
        _setListAccount(listId, OPERATOR, true);
        vm.prank(OPERATOR);
        token.transferFrom(ARTIST, COLLECTOR, 1);
        assertEq(token.totalSupply(), 1);
        assertEq(token.ownerOf(1), COLLECTOR);
        assertEq(token.getApproved(1), address(0));
    }

    function testReservedOwnerCannotBeForgedToBypassTransferPolicy() public {
        vm.prank(ARTIST);
        token.setApprovalForAll(OPERATOR, true);
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
        assertEq(token.totalSupply(), 0);
        assertEq(token.balanceOf(OPERATOR), 0);
        assertEq(token.balanceOf(RECIPIENT), 0);
        assertEq(token.balanceOf(COLLECTOR), 0);
        for (uint256 id = 1; id <= 3; ++id) {
            assertEq(token.ownerOf(id), ARTIST);
        }
        assertTrue(token.isApprovedForAll(ARTIST, OPERATOR));

        vm.expectRevert();
        vm.prank(OPERATOR, OPERATOR);
        token.transferFrom(ARTIST, COLLECTOR, 1);
        _setListAccount(listId, OPERATOR, true);
        vm.prank(OPERATOR, OPERATOR);
        token.transferFrom(ARTIST, COLLECTOR, 1);
        assertEq(token.ownerOf(1), COLLECTOR);
        assertEq(token.totalSupply(), 1);
    }

    function testAllowedOperatorMaterializesThenListRevocationBlocksExistingApproval() public {
        uint48 listId = _customList();
        _setListAccount(listId, OPERATOR, true);
        vm.prank(ARTIST);
        token.setApprovalForAll(OPERATOR, true);
        vm.prank(OPERATOR);
        token.transferFrom(ARTIST, COLLECTOR, 1);
        vm.prank(COLLECTOR);
        token.approve(OPERATOR, 1);
        vm.prank(OPERATOR);
        token.transferFrom(COLLECTOR, RECIPIENT, 1);
        assertEq(token.getApproved(1), address(0));
        vm.prank(RECIPIENT);
        token.approve(OPERATOR, 1);
        _setListAccount(listId, OPERATOR, false);
        vm.expectRevert();
        vm.prank(OPERATOR);
        token.transferFrom(RECIPIENT, COLLECTOR, 1);
        assertEq(token.ownerOf(1), RECIPIENT);
        assertEq(token.getApproved(1), OPERATOR);
        assertEq(token.totalSupply(), 1);
        assertEq(token.balanceOf(RECIPIENT), 1);
    }

    function testBothSafeTransferOverloadsEnforcePolicyAndCallReceiver() public {
        V5BatchReceiver receiver = new V5BatchReceiver();
        vm.prank(ARTIST);
        token.setApprovalForAll(OPERATOR, true);
        vm.expectRevert();
        vm.prank(OPERATOR);
        token.safeTransferFrom(ARTIST, address(receiver), 1);
        vm.expectRevert();
        vm.prank(OPERATOR);
        token.safeTransferFrom(ARTIST, address(receiver), 2, hex"1234");
        assertEq(token.totalSupply(), 0);
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
        assertEq(token.totalSupply(), 2);
    }

    function testSafeTransferToNonReceiverRollsBackMaterialization() public {
        uint48 listId = _customList();
        _setListAccount(listId, OPERATOR, true);
        vm.prank(ARTIST);
        token.setApprovalForAll(OPERATOR, true);
        vm.expectRevert("ERC721: transfer to non ERC721Receiver implementer");
        vm.prank(OPERATOR);
        token.safeTransferFrom(ARTIST, address(factory), 1, hex"1234");
        assertEq(token.ownerOf(1), ARTIST);
        assertEq(token.totalSupply(), 0);
        assertEq(token.balanceOf(ARTIST), 0);
        assertTrue(token.isApprovedForAll(ARTIST, OPERATOR));
    }

    function testOwnershipChangesLazyOwnerAndExternalPolicyAuthorityNotMaterializedOwner() public {
        _materialize(1, COLLECTOR);
        vm.prank(ARTIST);
        token.transferOwnership(RECIPIENT);
        assertEq(token.ownerOf(1), COLLECTOR);
        assertEq(token.ownerOf(2), RECIPIENT);
        assertEq(token.tokenCreator(2), ARTIST);
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(ARTIST);
        token.setTransferValidator(address(0));
        vm.expectRevert();
        vm.prank(ARTIST);
        validator.setRulesetOfCollection(address(token), 1, address(0), 0, 0);
        vm.prank(RECIPIENT);
        validator.setRulesetOfCollection(address(token), 1, address(0), 0, 0);
        vm.prank(COLLECTOR);
        token.approve(OPERATOR, 1);
        vm.prank(OPERATOR);
        token.transferFrom(COLLECTOR, ARTIST, 1);
        assertEq(token.ownerOf(1), ARTIST);
        vm.prank(RECIPIENT);
        token.setTransferValidator(address(0));
        assertEq(token.getTransferValidator(), address(0));
    }

    function testOwnerCanDisableAndRestoreValidatorWithoutLosingPolicy() public {
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(COLLECTOR);
        token.setTransferValidator(address(0));
        vm.prank(ARTIST);
        token.setApprovalForAll(OPERATOR, true);
        vm.prank(ARTIST);
        token.setTransferValidator(address(0));
        vm.prank(OPERATOR);
        token.transferFrom(ARTIST, COLLECTOR, 1);
        vm.prank(ARTIST);
        token.setTransferValidator(V5);
        assertEq(validator.getCollectionSecurityPolicy(address(token)).tokenType, 721);
        vm.prank(COLLECTOR);
        token.approve(OPERATOR, 1);
        vm.expectRevert();
        vm.prank(OPERATOR);
        token.transferFrom(COLLECTOR, RECIPIENT, 1);
        assertEq(token.ownerOf(1), COLLECTOR);
        assertEq(token.getApproved(1), OPERATOR);
    }

    function testValidatorChangeRevertsAtomicallyAndOriginalPolicyStillEnforced() public {
        vm.startPrank(ARTIST);
        vm.expectRevert(LazySovereignBatchMintV5.InvalidTransferValidator.selector);
        token.setTransferValidator(COLLECTOR);
        // The real factory has code but cannot accept V5 token-type registration.
        vm.expectRevert();
        token.setTransferValidator(address(factory));
        vm.stopPrank();
        assertEq(token.getTransferValidator(), V5);
        assertEq(validator.getCollectionSecurityPolicy(address(token)).tokenType, 721);
        vm.prank(ARTIST);
        token.setApprovalForAll(OPERATOR, true);
        vm.expectRevert();
        vm.prank(OPERATOR);
        token.transferFrom(ARTIST, COLLECTOR, 1);
        assertEq(token.totalSupply(), 0);
    }

    function testValidatorIsNotAutomaticallyApprovedButExplicitApprovalAllowsItsOwnTransfer() public {
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

/// @notice Local, unmodified V2 market implementations on the same fork; no mock payment/validator calls.
contract LazySovereignBatchMintV5MarketTest is LazySovereignBatchMintV5ForkBase {
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
        // Keep real sold-token state end-to-end without impersonating a production settings administrator.
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
        // Reuse actual mainnet registry and Manifold royalty-engine contracts, not fake collaborators.
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
        // V2 sends the approval manager as msg.sender to the token, not the listing proxy or buyer.
        _setListAccount(marketList, address(erc721Approver), true);
        vm.prank(ARTIST);
        token.setApprovalForAll(address(erc721Approver), true);
    }

    function testV2MerkleListingPrimaryThenSecondaryPaysRealBalances() public {
        (bytes32 root, bytes32[] memory proof) = _tokenProof(1, 2);
        _registerListing(ARTIST, root, 1 ether);
        vm.deal(COLLECTOR, 1.03 ether);
        uint256 artistBefore = ARTIST.balance;
        uint256 networkBefore = NETWORK.balance;
        vm.prank(COLLECTOR);
        listing.buyWithMerkleProof{value: 1.03 ether}(
            address(token), 1, address(0), 1 ether, ARTIST, root, proof, new bytes32[](0)
        );
        assertEq(token.ownerOf(1), COLLECTOR);
        assertEq(token.totalSupply(), 1);
        assertEq(ARTIST.balance - artistBefore, 0.85 ether);
        assertEq(NETWORK.balance - networkBefore, 0.18 ether);
        assertEq(COLLECTOR.balance, 0);
        assertEq(address(listing).balance, 0);
        assertTrue(settings.hasERC721TokenSold(address(token), 1));
        assertFalse(settings.hasERC721TokenSold(address(token), 2));

        vm.startPrank(ARTIST);
        token.setDefaultRoyaltyReceiver(RECIPIENT);
        token.setDefaultRoyaltyPercentage(7);
        vm.stopPrank();
        vm.prank(COLLECTOR);
        token.setApprovalForAll(address(erc721Approver), true);
        _registerListing(COLLECTOR, root, 2 ether);
        address buyer = address(0xC0FFEE);
        vm.deal(buyer, 2.06 ether);
        uint256 royaltyBefore = RECIPIENT.balance;
        uint256 sellerBefore = COLLECTOR.balance;
        networkBefore = NETWORK.balance;
        vm.prank(buyer);
        listing.buyWithMerkleProof{value: 2.06 ether}(
            address(token), 1, address(0), 2 ether, COLLECTOR, root, proof, new bytes32[](0)
        );
        assertEq(token.ownerOf(1), buyer);
        assertEq(token.totalSupply(), 1);
        assertEq(RECIPIENT.balance - royaltyBefore, 0.14 ether);
        assertEq(COLLECTOR.balance - sellerBefore, 1.86 ether);
        assertEq(NETWORK.balance - networkBefore, 0.06 ether);
        assertEq(buyer.balance, 0);
        assertEq(address(listing).balance, 0);
    }

    function testV2ListingDeniedTransferRollsBackPaymentNonceAndLazyMintThenRetries() public {
        (bytes32 root, bytes32[] memory proof) = _tokenProof(1, 2);
        _registerListing(ARTIST, root, 1 ether);
        _setListAccount(marketList, address(erc721Approver), false);
        vm.deal(COLLECTOR, 1.03 ether);
        uint256 artistBefore = ARTIST.balance;
        uint256 networkBefore = NETWORK.balance;
        bytes32[] memory invalidProof = new bytes32[](1);
        invalidProof[0] = bytes32(uint256(1));
        vm.expectRevert("buyWithMerkleProof::Invalid Merkle proof");
        vm.prank(COLLECTOR);
        listing.buyWithMerkleProof{value: 1.03 ether}(
            address(token), 1, address(0), 1 ether, ARTIST, root, invalidProof, new bytes32[](0)
        );
        vm.expectRevert();
        vm.prank(COLLECTOR);
        listing.buyWithMerkleProof{value: 1.03 ether}(
            address(token), 1, address(0), 1 ether, ARTIST, root, proof, new bytes32[](0)
        );
        assertEq(token.ownerOf(1), ARTIST);
        assertEq(token.totalSupply(), 0);
        assertEq(token.balanceOf(ARTIST), 0);
        assertEq(COLLECTOR.balance, 1.03 ether);
        assertEq(ARTIST.balance, artistBefore);
        assertEq(NETWORK.balance, networkBefore);
        assertEq(address(listing).balance, 0);
        assertFalse(settings.hasERC721TokenSold(address(token), 1));
        assertTrue(token.isApprovedForAll(ARTIST, address(erc721Approver)));
        _setListAccount(marketList, address(erc721Approver), true);
        vm.prank(COLLECTOR);
        listing.buyWithMerkleProof{value: 1.03 ether}(
            address(token), 1, address(0), 1 ether, ARTIST, root, proof, new bytes32[](0)
        );
        assertEq(token.ownerOf(1), COLLECTOR);
        assertEq(token.totalSupply(), 1);
    }

    function testV2MerkleAuctionEscrowsLazyTokenAndSettlesOnlyWithAuctionOperatorAllowed() public {
        (bytes32 root, bytes32[] memory proof) = _tokenProof(1, 2);
        (address payable[] memory recipients, uint8[] memory ratios) = _splits(ARTIST);
        _setListAccount(marketList, address(auction), true);
        vm.prank(ARTIST);
        auction.registerAuctionMerkleRoot(root, address(0), 1 ether, 1 days, recipients, ratios);
        vm.deal(COLLECTOR, 1.03 ether);
        vm.prank(COLLECTOR);
        auction.bidWithAuctionMerkleProof{value: 1.03 ether}(
            address(0), address(token), 1, ARTIST, root, 1 ether, proof
        );
        assertEq(token.ownerOf(1), address(auction));
        assertEq(token.totalSupply(), 1);
        assertEq(address(auction).balance, 1.03 ether);
        _setListAccount(marketList, address(auction), false);
        vm.warp(block.timestamp + 1 days);
        // Settlement calls the NFT directly from the auction, a different sender than transfer-in.
        vm.expectRevert();
        auction.settleAuction(address(token), 1);
        assertEq(token.ownerOf(1), address(auction));
        assertEq(address(auction).balance, 1.03 ether);
        (address bidder,, uint128 amount,) = auction.getCurrentBid(address(token), 1);
        assertEq(bidder, COLLECTOR);
        assertEq(amount, 1 ether);
        assertFalse(settings.hasERC721TokenSold(address(token), 1));

        _setListAccount(marketList, address(auction), true);
        uint256 artistBefore = ARTIST.balance;
        uint256 networkBefore = NETWORK.balance;
        auction.settleAuction(address(token), 1);
        assertEq(token.ownerOf(1), COLLECTOR);
        assertEq(token.totalSupply(), 1);
        assertEq(ARTIST.balance - artistBefore, 0.85 ether);
        assertEq(NETWORK.balance - networkBefore, 0.18 ether);
        assertEq(address(auction).balance, 0);
        assertTrue(settings.hasERC721TokenSold(address(token), 1));
        (bidder,, amount,) = auction.getCurrentBid(address(token), 1);
        assertEq(bidder, address(0));
        assertEq(amount, 0);
    }

    function _registerListing(address seller, bytes32 root, uint256 price) internal {
        (address payable[] memory recipients, uint8[] memory ratios) = _splits(seller);
        vm.prank(seller);
        listing.registerSalePriceMerkleRoot(root, address(0), price, recipients, ratios);
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
