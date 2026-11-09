// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import "../../../token/ERC721/sovereign/lazy/LazySovereignNFTFactory.sol";
import "../../../collection/RareMinter.sol";
import "../../../marketplace/IMarketplaceSettings.sol";
import "../../../marketplace/ISuperRareMarketplace.sol";
import "../../../../script/NetworkConfig.s.sol";

interface IV5CollectionPolicy {
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

/// @notice Integration tests against actual deployed V5 and RareMinter, never a mock validator.
contract LazySovereignNFTV5Test is Test {
    address constant V5 = 0x721C008fdff27BF06E7E123956E2Fe03B63342e3;
    uint256 constant FORK_BLOCK = 26350391;
    address constant ARTIST = address(0xA11CE);
    address constant COLLECTOR = address(0xB0B);
    address constant RECIPIENT = address(0xCAFE);
    address constant OPERATOR = address(0xBEEF);

    LazySovereignNFTFactory factory;
    LazySovereignNFTV5 token;
    IV5CollectionPolicy validator;

    function setUp() public {
        vm.createSelectFork(vm.envOr("MAINNET_RPC_URL", string("https://eth.drpc.org")), FORK_BLOCK);
        validator = IV5CollectionPolicy(V5);
        factory = new LazySovereignNFTFactory();
        factory.setSovereignNFT(address(new LazySovereignNFTV5()), factory.LAZY_SOVEREIGN_NFT_V5());
        token = _createCollection(3);
        vm.prank(ARTIST);
        token.prepareMint("ipfs://portraits", 3);
    }

    function testCloneInitializesOnceAndRegistersERC721() public {
        assertEq(token.owner(), ARTIST);
        assertEq(token.getTransferValidator(), V5);
        assertEq(validator.getCollectionSecurityPolicy(address(token)).tokenType, 721);
        vm.expectRevert("Initializable: contract is already initialized");
        token.init("Replacement", "BAD", COLLECTOR, 100);
        assertEq(token.owner(), ARTIST);
    }

    function testImplementationCannotBeInitialized() public {
        LazySovereignNFTV5 implementation = LazySovereignNFTV5(factory.lazySovereignNFTV5());
        vm.expectRevert("Initializable: contract is already initialized");
        implementation.init("Implementation", "BAD", ARTIST, 3);
    }

    function testMissingDefaultValidatorRejectsV5ButNotStandardCollection() public {
        vm.etch(V5, hex"");
        bytes32 v5Type = factory.LAZY_SOVEREIGN_NFT_V5();
        vm.expectRevert(LazySovereignNFTV5.InvalidTransferValidator.selector);
        vm.prank(ARTIST);
        factory.createSovereignNFTContract("Unprotected", "BAD", 3, v5Type);

        bytes32 standardType = factory.LAZY_SOVEREIGN_NFT();
        vm.prank(ARTIST);
        address standard = factory.createSovereignNFTContract("Standard", "STD", 3, standardType);
        assertEq(LazySovereignNFT(standard).owner(), ARTIST);
    }

    function testFactoryRequiresOwnerInstalledV5Implementation() public {
        LazySovereignNFTFactory fresh = new LazySovereignNFTFactory();
        bytes32 contractType = fresh.LAZY_SOVEREIGN_NFT_V5();
        vm.expectRevert("createSovereignNFTContract::V5 implementation not configured.");
        fresh.createSovereignNFTContract("Not installed", "BAD", 3, contractType);
        vm.expectRevert("setSovereignNFT::V5 implementation has no code.");
        fresh.setSovereignNFT(COLLECTOR, contractType);
        LazySovereignNFTV5 implementation = new LazySovereignNFTV5();
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(ARTIST);
        fresh.setSovereignNFT(address(implementation), contractType);
        fresh.setSovereignNFT(address(implementation), contractType);
        vm.prank(ARTIST);
        LazySovereignNFTV5 created =
            LazySovereignNFTV5(fresh.createSovereignNFTContract("Installed", "V5", 3, contractType));
        assertEq(created.owner(), ARTIST);
        assertEq(created.getTransferValidator(), V5);
    }

    function testApprovedMinterSupplyAndMetadata() public {
        vm.prank(ARTIST);
        token.setMinterApproval(OPERATOR, true);
        for (uint256 id = 1; id <= 3; ++id) {
            vm.prank(OPERATOR);
            assertEq(token.mintTo(COLLECTOR), id);
            assertEq(token.ownerOf(id), COLLECTOR);
        }
        assertEq(token.tokenURI(3), "ipfs://portraits/3.json");
        vm.expectRevert("_createToken::exceeded maxTokens");
        vm.prank(OPERATOR);
        token.mintTo(COLLECTOR);
        assertEq(token.totalSupply(), 3);
    }

    function testUnauthorizedMintAndRevokedMinterDoNotConsumeSupply() public {
        vm.expectRevert("lazyMint::only owner or approved minter can mint");
        vm.prank(COLLECTOR);
        token.mintTo(COLLECTOR);
        vm.startPrank(ARTIST);
        token.setMinterApproval(OPERATOR, true);
        token.setMinterApproval(OPERATOR, false);
        vm.stopPrank();
        vm.expectRevert("lazyMint::only owner or approved minter can mint");
        vm.prank(OPERATOR);
        token.mintTo(COLLECTOR);
        assertEq(token.totalSupply(), 0);
    }

    function testMetadataUpdatesAndLockRemainAvailable() public {
        _mint(COLLECTOR);
        vm.startPrank(ARTIST);
        token.updateBaseURI("ipfs://revealed");
        assertEq(token.tokenURI(1), "ipfs://revealed/1.json");
        token.updateTokenURI(1, "ipfs://special/1.json");
        token.lockBaseURI();
        vm.expectRevert("updateBaseURI::metadata is locked");
        token.updateBaseURI("ipfs://replacement");
        vm.expectRevert("updateTokenURI::metadata is locked");
        token.updateTokenURI(1, "ipfs://replacement/1.json");
        vm.stopPrank();
        assertEq(token.tokenURI(1), "ipfs://special/1.json");
    }

    function testRoyaltyReceiverAndPerTokenOverrideRemainAvailable() public {
        vm.prank(ARTIST);
        token.setDefaultRoyaltyReceiver(RECIPIENT);
        _mint(COLLECTOR);
        (address receiver, uint256 amount) = token.royaltyInfo(1, 2 ether);
        assertEq(receiver, RECIPIENT);
        assertEq(amount, 2 ether * token.getDefaultRoyaltyPercentage() / 100);
        vm.prank(ARTIST);
        token.setRoyaltyReceiverForToken(ARTIST, 1);
        (receiver, amount) = token.royaltyInfo(1, 2 ether);
        assertEq(receiver, ARTIST);
    }

    function testRoyaltyPercentageUsesExistingToolSelectorAndPreservesSnapshots() public {
        vm.startPrank(ARTIST);
        token.setDefaultRoyaltyPercentage(7);
        token.mintTo(COLLECTOR);
        token.setDefaultRoyaltyPercentage(3);
        token.mintTo(COLLECTOR);
        token.setDefaultRoyaltyPercentage(0);
        token.mintTo(COLLECTOR);
        vm.expectRevert(LazySovereignNFTV5.InvalidRoyaltyPercentage.selector);
        token.setDefaultRoyaltyPercentage(101);
        vm.stopPrank();
        (, uint256 first) = token.royaltyInfo(1, 1 ether);
        (, uint256 second) = token.royaltyInfo(2, 1 ether);
        (, uint256 third) = token.royaltyInfo(3, 1 ether);
        assertEq(first, 0.07 ether);
        assertEq(second, 0.03 ether);
        assertEq(third, 0);
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(COLLECTOR);
        token.setDefaultRoyaltyPercentage(5);
        assertEq(token.getDefaultRoyaltyPercentage(), 0);
    }

    function testCreatorTokenDiscoveryPreservesNFTAndRoyaltyInterfaces() public {
        assertTrue(token.supportsInterface(type(ICreatorToken).interfaceId));
        assertTrue(token.supportsInterface(0x80ac58cd));
        assertTrue(token.supportsInterface(0x2a55205a));
        assertFalse(token.supportsInterface(0xffffffff));
        (bytes4 selector, bool isView) = token.getTransferValidationFunction();
        assertEq(selector, bytes4(keccak256("validateTransfer(address,address,address,uint256)")));
        assertTrue(isView);
    }

    function testApprovalDoesNotBypassV5TransferPolicy() public {
        _mint(COLLECTOR);
        vm.prank(COLLECTOR);
        token.setApprovalForAll(OPERATOR, true);
        vm.expectRevert();
        vm.prank(OPERATOR);
        token.transferFrom(COLLECTOR, RECIPIENT, 1);
        assertEq(token.ownerOf(1), COLLECTOR);
        assertTrue(token.isApprovedForAll(COLLECTOR, OPERATOR));
    }

    function testAddingAndRemovingOperatorChangesExistingApprovalTransfers() public {
        _mint(COLLECTOR);
        uint48 listId = _customList();
        address[] memory accounts = new address[](1);
        accounts[0] = OPERATOR;
        vm.prank(ARTIST);
        validator.addAccountsToList(listId, 1, accounts);
        vm.prank(COLLECTOR);
        token.setApprovalForAll(OPERATOR, true);
        vm.prank(OPERATOR);
        token.safeTransferFrom(COLLECTOR, RECIPIENT, 1, hex"1234");
        assertEq(token.ownerOf(1), RECIPIENT);

        vm.prank(RECIPIENT);
        token.setApprovalForAll(OPERATOR, true);
        vm.prank(ARTIST);
        validator.removeAccountsFromList(listId, 1, accounts);
        vm.expectRevert();
        vm.prank(OPERATOR);
        token.transferFrom(RECIPIENT, COLLECTOR, 1);
        assertEq(token.ownerOf(1), RECIPIENT);
    }

    function testHolderTransferIsAllowedByDefaultPolicy() public {
        _mint(COLLECTOR);
        vm.prank(COLLECTOR, COLLECTOR);
        token.transferFrom(COLLECTOR, RECIPIENT, 1);
        assertEq(token.ownerOf(1), RECIPIENT);
    }

    function testOwnerCanChangeExternalPolicyWithoutChangingToken() public {
        _mint(COLLECTOR);
        vm.prank(COLLECTOR);
        token.approve(OPERATOR, 1);
        vm.prank(ARTIST);
        validator.setRulesetOfCollection(address(token), 1, address(0), 0, 0);
        vm.prank(OPERATOR);
        token.transferFrom(COLLECTOR, RECIPIENT, 1);
        assertEq(token.ownerOf(1), RECIPIENT);
    }

    function testMintAndBurnDoNotRequireTransferAuthorization() public {
        vm.prank(ARTIST);
        validator.setRulesetOfCollection(address(token), 2, address(0), 0, 0);
        _mint(COLLECTOR);
        vm.expectRevert();
        vm.prank(COLLECTOR);
        token.transferFrom(COLLECTOR, RECIPIENT, 1);
        vm.prank(COLLECTOR);
        token.burn(1);
        vm.expectRevert("ERC721: invalid token ID");
        token.ownerOf(1);
    }

    function testOnlyOwnerCanChangeOrDisableValidator() public {
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(COLLECTOR);
        token.setTransferValidator(address(0));
        assertEq(token.getTransferValidator(), V5);
        vm.prank(ARTIST);
        token.transferOwnership(RECIPIENT);
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(ARTIST);
        token.setTransferValidator(address(0));
        vm.prank(RECIPIENT);
        token.setTransferValidator(address(0));
        assertEq(token.getTransferValidator(), address(0));
    }

    function testOwnerCanDisableAndRestoreValidation() public {
        _mint(COLLECTOR);
        vm.prank(COLLECTOR);
        token.setApprovalForAll(OPERATOR, true);
        vm.prank(ARTIST);
        token.setTransferValidator(address(0));
        vm.prank(OPERATOR);
        token.transferFrom(COLLECTOR, RECIPIENT, 1);
        vm.prank(ARTIST);
        token.setTransferValidator(V5);
        vm.prank(RECIPIENT);
        token.approve(OPERATOR, 1);
        vm.expectRevert();
        vm.prank(OPERATOR);
        token.transferFrom(RECIPIENT, COLLECTOR, 1);
        assertEq(token.ownerOf(1), RECIPIENT);
    }

    function testInvalidAndIncompatibleValidatorsLeavePolicyIntact() public {
        vm.startPrank(ARTIST);
        vm.expectRevert(LazySovereignNFTV5.InvalidTransferValidator.selector);
        token.setTransferValidator(COLLECTOR);
        vm.expectRevert();
        token.setTransferValidator(address(factory));
        vm.stopPrank();
        assertEq(token.getTransferValidator(), V5);
    }

    function testLegacyFactoryChoicesRemainSeparate() public {
        bytes32[3] memory choices =
            [factory.LAZY_SOVEREIGN_NFT(), factory.LAZY_ROYALTY_GUARD(), factory.LAZY_ROYALTY_GUARD_DEADMAN()];
        for (uint256 i; i < choices.length; ++i) {
            vm.prank(ARTIST);
            LazySovereignNFT legacy =
                LazySovereignNFT(factory.createSovereignNFTContract("Legacy", "OLD", 3, choices[i]));
            assertFalse(legacy.supportsInterface(type(ICreatorToken).interfaceId));
            vm.prank(ARTIST);
            legacy.mintTo(COLLECTOR);
            vm.prank(COLLECTOR);
            legacy.approve(OPERATOR, 1);
            vm.prank(OPERATOR);
            legacy.transferFrom(COLLECTOR, RECIPIENT, 1);
            assertEq(legacy.ownerOf(1), RECIPIENT);
        }
    }

    function testExistingDeployedRareMinterMintsAndPaysPrimaryProceeds() public {
        NetworkConfig.Addresses memory config = NetworkConfig.get(1);
        RareMinter minter = RareMinter(config.rareMinter);
        IMarketplaceSettings settings = IMarketplaceSettings(config.marketplaceSettingsV3);
        address payable[] memory recipients = new address payable[](1);
        recipients[0] = payable(ARTIST);
        uint8[] memory ratios = new uint8[](1);
        ratios[0] = 100;
        uint256 price = 0.1 ether;
        uint256 total = 2 * price;
        uint256 fee = settings.calculateMarketplaceFee(total);
        uint256 commission = settings.getERC721ContractPrimarySaleFeePercentage(address(token));
        vm.startPrank(ARTIST);
        token.setMinterApproval(address(minter), true);
        minter.prepareMintDirectSale(address(token), address(0), price, block.timestamp, 2, recipients, ratios);
        minter.setContractMintLimit(address(token), 2);
        vm.stopPrank();
        vm.deal(COLLECTOR, total + fee);
        uint256 artistBalance = ARTIST.balance;
        vm.prank(COLLECTOR);
        minter.mintDirectSale{value: total + fee}(address(token), address(0), price, 2, new bytes32[](0));
        assertEq(token.ownerOf(1), COLLECTOR);
        assertEq(token.ownerOf(2), COLLECTOR);
        assertEq(token.totalSupply(), 2);
        assertEq(token.tokenURI(2), "ipfs://portraits/2.json");
        assertEq(minter.getContractMintsPerAddress(address(token), COLLECTOR), 2);
        assertEq(ARTIST.balance - artistBalance, total - total * commission / 100);
        vm.expectRevert("mintDirectSale::Exceeded mint limit for address");
        vm.prank(COLLECTOR);
        minter.mintDirectSale(address(token), address(0), price, 1, new bytes32[](0));
        assertEq(token.totalSupply(), 2);
    }

    function testExistingDeployedBazaarPaysRoyaltyOnSecondarySale() public {
        NetworkConfig.Addresses memory config = NetworkConfig.get(1);
        RareMinter minter = RareMinter(config.rareMinter);
        IMarketplaceSettings settings = IMarketplaceSettings(config.marketplaceSettingsV3);
        ISuperRareMarketplace bazaar = ISuperRareMarketplace(config.bazaar);
        address payable[] memory recipients = new address payable[](1);
        recipients[0] = payable(ARTIST);
        uint8[] memory ratios = new uint8[](1);
        ratios[0] = 100;
        vm.startPrank(ARTIST);
        token.setDefaultRoyaltyReceiver(RECIPIENT);
        token.setDefaultRoyaltyPercentage(7);
        token.setMinterApproval(address(minter), true);
        minter.prepareMintDirectSale(address(token), address(0), 0, block.timestamp, 1, recipients, ratios);
        vm.stopPrank();
        vm.prank(COLLECTOR);
        minter.mintDirectSale(address(token), address(0), 0, 1, new bytes32[](0));
        assertTrue(settings.hasERC721TokenSold(address(token), 1));

        uint48 listId = _customList();
        address[] memory operators = new address[](1);
        operators[0] = config.bazaar;
        vm.prank(ARTIST);
        validator.addAccountsToList(listId, 1, operators);
        recipients[0] = payable(COLLECTOR);
        uint256 price = 0.2 ether;
        vm.startPrank(COLLECTOR);
        token.setApprovalForAll(config.bazaar, true);
        bazaar.setSalePrice(address(token), 1, address(0), price, address(0), recipients, ratios);
        vm.stopPrank();
        address buyer = address(0xC0FFEE);
        uint256 fee = settings.calculateMarketplaceFee(price);
        vm.deal(buyer, price + fee);
        uint256 royaltyBalance = RECIPIENT.balance;
        uint256 sellerBalance = COLLECTOR.balance;
        vm.prank(buyer);
        bazaar.buy{value: price + fee}(address(token), 1, address(0), price);
        assertEq(token.ownerOf(1), buyer);
        assertEq(RECIPIENT.balance - royaltyBalance, 0.014 ether);
        assertEq(COLLECTOR.balance - sellerBalance, 0.186 ether);
    }

    function _createCollection(uint256 cap) internal returns (LazySovereignNFTV5) {
        bytes32 contractType = factory.LAZY_SOVEREIGN_NFT_V5();
        vm.prank(ARTIST);
        return LazySovereignNFTV5(factory.createSovereignNFTContract("V5 Collection", "V5", cap, contractType));
    }

    function _mint(address to) internal {
        vm.prank(ARTIST);
        token.mintTo(to);
    }

    function _customList() internal returns (uint48 listId) {
        vm.startPrank(ARTIST);
        listId = validator.createList("Artist markets");
        validator.applyListToCollection(address(token), listId);
        vm.stopPrank();
    }
}
