// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {IERC721} from "openzeppelin-contracts/token/ERC721/IERC721.sol";
import {IERC2981} from "openzeppelin-contracts/interfaces/IERC2981.sol";
import {PaymentSplitter} from "openzeppelin-contracts/finance/PaymentSplitter.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {SovereignBatchMintV5ForkBase} from "./SovereignBatchMintV5.t.sol";
import {SovereignBatchMint} from "../../../v2/token/ERC721/sovereign/SovereignBatchMint.sol";
import {SovereignBatchMintV5} from "../../../v2/token/ERC721/sovereign/SovereignBatchMintV5.sol";
import {SovereignBatchMintFactory} from "../../../v2/token/ERC721/sovereign/SovereignBatchMintFactory.sol";
import {LazySovereignBatchMint} from "../../../v2/token/ERC721/sovereign/LazySovereignBatchMint.sol";
import {LazySovereignBatchMintV5} from "../../../v2/token/ERC721/sovereign/LazySovereignBatchMintV5.sol";
import {LazySovereignBatchMintFactory} from "../../../v2/token/ERC721/sovereign/LazySovereignBatchMintFactory.sol";
import {RoyaltySplitConfig, RoyaltySplitterFactory} from "../../../v2/royalty/RoyaltySplitterFactory.sol";
import {MarketplaceSettingsV1} from "../../../marketplace/MarketplaceSettingsV1.sol";
import {MarketplaceSettingsV2} from "../../../marketplace/MarketplaceSettingsV2.sol";
import {MarketplaceSettingsV3} from "../../../marketplace/MarketplaceSettingsV3.sol";
import {Payments} from "../../../payments/Payments.sol";
import {RareBatchListingMarketplace} from "../../../v2/marketplace/RareBatchListingMarketplace.sol";
import {ERC20ApprovalManager} from "../../../v2/approver/ERC20/ERC20ApprovalManager.sol";
import {ERC721ApprovalManager} from "../../../v2/approver/ERC721/ERC721ApprovalManager.sol";
import {NetworkConfig} from "../../../../script/NetworkConfig.s.sol";
import {ApprovedTokenRegistry} from "../../../registry/ApprovedTokenRegistry.sol";

interface IRoyaltySplitWETH is IERC20 {
    function deposit() external payable;
}

/// @dev Inherits the existing MAINNET_RPC_URL override and block 26350391 fixture.
abstract contract RoyaltySplitCollectionsForkBase is SovereignBatchMintV5ForkBase {
    RoyaltySplitterFactory internal splitterFactory;
    LazySovereignBatchMintFactory internal lazyFactory;
    LazySovereignBatchMintV5 internal lazy;
    address internal splitter;
    address internal constant ALTERNATE = address(0xD00D);

    function setUp() public virtual override {
        super.setUp();
        splitterFactory = new RoyaltySplitterFactory();
        lazyFactory = new LazySovereignBatchMintFactory(address(new LazySovereignBatchMintV5()));
        factory.setRoyaltySplitterFactory(address(splitterFactory));
        lazyFactory.setRoyaltySplitterFactory(address(splitterFactory));
        RoyaltySplitConfig memory config = _config();
        address collection;
        vm.prank(ARTIST);
        (collection, splitter) = factory.createSovereignBatchMintWithRoyaltySplit("Split standard", "SS", 20, config);
        token = SovereignBatchMintV5(collection);
        address lazySplitter;
        vm.prank(ARTIST);
        (collection, lazySplitter) =
            lazyFactory.createLazySovereignBatchMintWithRoyaltySplit("Split lazy", "SL", 20, config);
        lazy = LazySovereignBatchMintV5(collection);
        assertEq(lazySplitter, splitter);
    }

    function _config() internal pure returns (RoyaltySplitConfig memory config) {
        config.recipients = new address[](2);
        config.recipients[0] = RECIPIENT;
        config.recipients[1] = ARTIST;
        config.shares = new uint256[](2);
        config.shares[0] = 20;
        config.shares[1] = 80;
        config.beneficiaryIndex = 1;
        config.royaltyPercentage = 10;
    }

    function _assertRoyalty(address collection, uint256 id, address receiver, uint256 amount) internal {
        (address actualReceiver, uint256 actualAmount) = IERC2981(collection).royaltyInfo(id, 2 ether);
        assertEq(actualReceiver, receiver);
        assertEq(actualAmount, amount);
    }

    function _assertTemplates() internal {
        RoyaltySplitConfig memory config = _config();
        (address[] memory recipients, uint256[] memory shares, uint256 index) = token.royaltySplitTerms();
        assertEq(recipients, config.recipients);
        assertEq(shares, config.shares);
        assertEq(index, config.beneficiaryIndex);
        (recipients, shares, index) = lazy.royaltySplitTerms();
        assertEq(recipients, config.recipients);
        assertEq(shares, config.shares);
        assertEq(index, config.beneficiaryIndex);
    }

    function _assertCreationReverts(RoyaltySplitConfig memory config, uint256 cap) internal {
        uint64 standardNonce = vm.getNonce(address(factory));
        uint64 lazyNonce = vm.getNonce(address(lazyFactory));
        address standardClone = computeCreateAddress(address(factory), standardNonce);
        address lazyClone = computeCreateAddress(address(lazyFactory), lazyNonce);
        vm.expectRevert();
        vm.prank(ARTIST);
        factory.createSovereignBatchMintWithRoyaltySplit("Invalid standard", "BAD", cap, config);
        vm.expectRevert();
        vm.prank(ARTIST);
        lazyFactory.createLazySovereignBatchMintWithRoyaltySplit("Invalid lazy", "BAD", cap, config);
        assertEq(vm.getNonce(address(factory)), standardNonce);
        assertEq(vm.getNonce(address(lazyFactory)), lazyNonce);
        assertEq(standardClone.code.length, 0);
        assertEq(lazyClone.code.length, 0);
        assertEq(token.owner(), ARTIST);
        assertEq(lazy.owner(), ARTIST);
    }
}

contract RoyaltySplitCollectionsTest is RoyaltySplitCollectionsForkBase {
    event SovereignBatchMintCreated(address indexed contractAddress, address indexed owner);
    event LazySovereignBatchMintCreated(address indexed contractAddress, address indexed owner);
    event RoyaltySplitConfigured(address indexed collection, address indexed splitter, address indexed owner);

    function testAtomicFactoriesPreserveArtistOwnershipCreatorAndWholePercentRoyalty() public {
        assertEq(token.owner(), ARTIST);
        assertEq(lazy.owner(), ARTIST);
        assertEq(token.tokenCreator(1), ARTIST);
        assertEq(lazy.tokenCreator(1), ARTIST);
        assertEq(token.maxTokens(), 20);
        assertEq(lazy.maxTokens(), 20);
        assertEq(address(token.royaltySplitterFactory()), address(splitterFactory));
        assertEq(address(lazy.royaltySplitterFactory()), address(splitterFactory));
        assertEq(token.getDefaultRoyaltyReceiver(), splitter);
        assertEq(lazy.getDefaultRoyaltyReceiver(), splitter);
        assertEq(token.getDefaultRoyaltyPercentage(), 10);
        assertEq(lazy.getDefaultRoyaltyPercentage(), 10);
        assertEq(token.getTransferValidator(), V5);
        assertEq(lazy.getTransferValidator(), V5);
        assertEq(validator.getCollectionSecurityPolicy(address(token)).tokenType, 721);
        assertEq(validator.getCollectionSecurityPolicy(address(lazy)).tokenType, 721);
        _assertRoyalty(address(token), 1, splitter, 0.2 ether);
        _assertRoyalty(address(lazy), 1, splitter, 0.2 ether);
        _assertTemplates();
        PaymentSplitter paymentSplitter = PaymentSplitter(payable(splitter));
        assertEq(paymentSplitter.payee(0), RECIPIENT);
        assertEq(paymentSplitter.payee(1), ARTIST);
        assertEq(paymentSplitter.shares(RECIPIENT), 20);
        assertEq(paymentSplitter.shares(ARTIST), 80);
        assertEq(paymentSplitter.totalShares(), 100);
    }

    function testCreationEmitsExistingAndSplitEventsForBothFactories() public {
        RoyaltySplitConfig memory config = _config();
        address predicted = computeCreateAddress(address(factory), vm.getNonce(address(factory)));
        vm.expectEmit(true, true, false, true, address(factory));
        emit SovereignBatchMintCreated(predicted, ARTIST);
        vm.expectEmit(true, true, true, true, address(factory));
        emit RoyaltySplitConfigured(predicted, splitter, ARTIST);
        vm.prank(ARTIST);
        (address collection, address actualSplitter) =
            factory.createSovereignBatchMintWithRoyaltySplit("Again", "A", 2, config);
        assertEq(collection, predicted);
        assertEq(actualSplitter, splitter);

        predicted = computeCreateAddress(address(lazyFactory), vm.getNonce(address(lazyFactory)));
        vm.expectEmit(true, true, false, true, address(lazyFactory));
        emit LazySovereignBatchMintCreated(predicted, ARTIST);
        vm.expectEmit(true, true, true, true, address(lazyFactory));
        emit RoyaltySplitConfigured(predicted, splitter, ARTIST);
        vm.prank(ARTIST);
        (collection, actualSplitter) =
            lazyFactory.createLazySovereignBatchMintWithRoyaltySplit("Again lazy", "AL", 2, config);
        assertEq(collection, predicted);
        assertEq(actualSplitter, splitter);
    }

    function testCreate2IdentityIsSharedAcrossFactoriesCollectionsAndSaleRates() public {
        RoyaltySplitConfig memory config = _config();
        assertEq(splitterFactory.predictSplitter(config.recipients, config.shares), splitter);
        assertEq(splitterFactory.configurationHash(splitter), keccak256(abi.encode(config.recipients, config.shares)));
        config.royaltyPercentage = 7;
        vm.prank(ARTIST);
        (address second, address reused) = factory.createSovereignBatchMintWithRoyaltySplit("Seven", "SEV", 2, config);
        assertTrue(second != address(token));
        assertEq(reused, splitter);
        _assertRoyalty(second, 1, splitter, 0.14 ether);
        vm.prank(ARTIST);
        (second, reused) = lazyFactory.createLazySovereignBatchMintWithRoyaltySplit("Seven lazy", "SEVL", 2, config);
        assertEq(reused, splitter);
        _assertRoyalty(second, 1, splitter, 0.14 ether);

        config.shares[0] = 21;
        address expected = splitterFactory.predictSplitter(config.recipients, config.shares);
        assertTrue(expected != splitter);
        vm.prank(ARTIST);
        (, address changed) = lazyFactory.createLazySovereignBatchMintWithRoyaltySplit("New shares", "NS", 2, config);
        assertEq(changed, expected);
        config = _config();
        config.recipients[0] = ALTERNATE;
        expected = splitterFactory.predictSplitter(config.recipients, config.shares);
        vm.prank(ARTIST);
        (, changed) = factory.createSovereignBatchMintWithRoyaltySplit("New fixed payee", "NP", 2, config);
        assertEq(changed, expected);
        assertTrue(changed != splitter);
    }

    function testStandardMintResolvesArtistZeroDefaultReceiverAndAlternateWithoutChangingTemplate() public {
        address alternateSplitter = token.predictRoyaltySplitter(ALTERNATE);
        assertEq(alternateSplitter.code.length, 0);
        assertEq(alternateSplitter, lazy.predictRoyaltySplitter(ALTERNATE));
        vm.startPrank(ARTIST);
        token.addNewToken("ipfs://artist");
        token.mintTo("ipfs://zero", COLLECTOR, address(0));
        token.mintTo("ipfs://default-beneficiary", COLLECTOR, ARTIST);
        token.mintTo("ipfs://default-receiver", COLLECTOR, splitter);
        token.mintTo("ipfs://alternate", COLLECTOR, ALTERNATE);
        vm.stopPrank();
        for (uint256 id = 1; id <= 4; ++id) {
            _assertRoyalty(address(token), id, splitter, 0.2 ether);
        }
        _assertRoyalty(address(token), 5, alternateSplitter, 0.2 ether);
        assertEq(token.ownerOf(1), ARTIST);
        assertEq(token.ownerOf(5), COLLECTOR);
        assertEq(token.totalSupply(), 5);
        PaymentSplitter alternate = PaymentSplitter(payable(alternateSplitter));
        assertEq(alternate.payee(0), RECIPIENT);
        assertEq(alternate.payee(1), ALTERNATE);
        assertEq(alternate.shares(ALTERNATE), 80);
        _assertTemplates();
    }

    function testCompatibleKnownSplitterIsReusedWithoutNestingAndIncompatibleKnownSplitterReverts() public {
        RoyaltySplitConfig memory config = _config();
        config.recipients[1] = ALTERNATE;
        address compatible = splitterFactory.getOrCreateSplitter(config.recipients, config.shares);
        vm.prank(ARTIST);
        token.mintTo("ipfs://reuse", COLLECTOR, compatible);
        vm.prank(ARTIST);
        lazy.prepareMint("ipfs://lazy", 1);
        vm.prank(ARTIST);
        lazy.setRoyaltyBeneficiaryForToken(compatible, 1);
        _assertRoyalty(address(token), 1, compatible, 0.2 ether);
        _assertRoyalty(address(lazy), 1, compatible, 0.2 ether);
        assertEq(PaymentSplitter(payable(compatible)).payee(1), ALTERNATE);
        config.shares[1] = 81;
        address incompatible = splitterFactory.getOrCreateSplitter(config.recipients, config.shares);
        vm.expectRevert();
        vm.prank(ARTIST);
        token.mintTo("ipfs://no-nesting", COLLECTOR, incompatible);
        vm.expectRevert();
        vm.prank(ARTIST);
        lazy.setRoyaltyBeneficiaryForToken(incompatible, 1);
        assertEq(token.totalSupply(), 1);
        _assertRoyalty(address(lazy), 1, compatible, 0.2 ether);
        vm.prank(ARTIST);
        token.addNewToken("ipfs://next");
        assertEq(token.ownerOf(2), ARTIST);
    }

    function testDuplicateFixedRecipientSubstitutionRevertsWithoutMintingOrConsumingId() public {
        vm.expectRevert();
        vm.prank(ARTIST);
        token.mintTo("ipfs://duplicate", COLLECTOR, RECIPIENT);
        assertEq(token.totalSupply(), 0);
        assertEq(token.balanceOf(COLLECTOR), 0);
        vm.expectRevert("ERC721: invalid token ID");
        token.ownerOf(1);
        vm.prank(ARTIST);
        token.addNewToken("ipfs://still-first");
        assertEq(token.ownerOf(1), ARTIST);
        assertEq(token.totalSupply(), 1);
        vm.prank(ARTIST);
        lazy.prepareMint("ipfs://reserved", 1);
        vm.expectRevert();
        vm.prank(ARTIST);
        lazy.setRoyaltyBeneficiaryForToken(RECIPIENT, 1);
        assertEq(lazy.ownerOf(1), ARTIST);
        assertEq(lazy.totalSupply(), 0);
        assertEq(lazy.getBatchCount(), 1);
        _assertRoyalty(address(lazy), 1, splitter, 0.2 ether);
    }

    function testOwnerBeneficiaryHelpersAndRawOverridesWorkForImmediateAndLazyTokens() public {
        vm.startPrank(ARTIST);
        token.addNewToken("ipfs://immediate");
        lazy.prepareMint("ipfs://lazy", 2);
        token.setRoyaltyBeneficiaryForToken(ALTERNATE, 1);
        lazy.setRoyaltyBeneficiaryForToken(ALTERNATE, 1);
        vm.stopPrank();
        address alternateSplitter = token.predictRoyaltySplitter(ALTERNATE);
        _assertRoyalty(address(token), 1, alternateSplitter, 0.2 ether);
        _assertRoyalty(address(lazy), 1, alternateSplitter, 0.2 ether);
        vm.startPrank(ARTIST, ARTIST);
        lazy.transferFrom(ARTIST, COLLECTOR, 1);
        token.setRoyaltyReceiverForToken(OPERATOR, 1);
        lazy.setRoyaltyReceiverForToken(OPERATOR, 1);
        vm.stopPrank();
        _assertRoyalty(address(token), 1, OPERATOR, 0.2 ether);
        _assertRoyalty(address(lazy), 1, OPERATOR, 0.2 ether);
        vm.startPrank(ARTIST);
        token.setRoyaltyBeneficiaryForToken(address(0), 1);
        lazy.setRoyaltyBeneficiaryForToken(splitter, 1);
        vm.stopPrank();
        _assertRoyalty(address(token), 1, splitter, 0.2 ether);
        _assertRoyalty(address(lazy), 1, splitter, 0.2 ether);
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(COLLECTOR);
        token.setRoyaltyBeneficiaryForToken(ALTERNATE, 1);
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(COLLECTOR);
        lazy.setRoyaltyBeneficiaryForToken(ALTERNATE, 1);
        _assertRoyalty(address(token), 1, splitter, 0.2 ether);
        _assertRoyalty(address(lazy), 1, splitter, 0.2 ether);
    }

    function testImmediateSnapshotsButStandardBatchAndLazyUseRetargetableOwnerDefaults() public {
        vm.startPrank(ARTIST);
        token.addNewToken("ipfs://snapshot");
        token.batchMint("ipfs://batch", 1);
        lazy.prepareMint("ipfs://lazy", 1);
        token.setDefaultRoyaltyReceiver(OPERATOR);
        lazy.setDefaultRoyaltyReceiver(OPERATOR);
        token.setDefaultRoyaltyPercentage(7);
        lazy.setDefaultRoyaltyPercentage(7);
        token.mintTo("ipfs://current-default", COLLECTOR, address(0));
        vm.stopPrank();
        _assertRoyalty(address(token), 1, splitter, 0.2 ether);
        _assertRoyalty(address(token), 2, OPERATOR, 0.14 ether);
        _assertRoyalty(address(token), 3, OPERATOR, 0.14 ether);
        _assertRoyalty(address(lazy), 1, OPERATOR, 0.14 ether);
        _assertTemplates();
    }

    function testDefaultMintKeepsConfiguredWalletAcrossOwnerChangesAndHonorsExplicitRetarget() public {
        RoyaltySplitConfig memory config = _config();
        config.recipients[config.beneficiaryIndex] = ALTERNATE;
        vm.prank(ARTIST);
        (address collection, address configuredSplit) =
            factory.createSovereignBatchMintWithRoyaltySplit("Separate payout wallet", "WAL", 3, config);
        SovereignBatchMintV5 routed = SovereignBatchMintV5(collection);
        vm.prank(ARTIST);
        routed.addNewToken("ipfs://configured-wallet");
        _assertRoyalty(collection, 1, configuredSplit, 0.2 ether);
        assertEq(routed.ownerOf(1), ARTIST);

        vm.prank(ARTIST);
        routed.transferOwnership(COLLECTOR);
        vm.prank(COLLECTOR);
        routed.addNewToken("ipfs://new-owner-same-wallet");
        _assertRoyalty(collection, 2, configuredSplit, 0.2 ether);
        assertEq(routed.ownerOf(2), COLLECTOR);
        assertEq(routed.tokenCreator(2), ARTIST);

        vm.startPrank(COLLECTOR);
        routed.setDefaultRoyaltyReceiver(OPERATOR);
        routed.addNewToken("ipfs://owner-retarget");
        vm.stopPrank();
        _assertRoyalty(collection, 3, OPERATOR, 0.2 ether);
        _assertRoyalty(collection, 1, configuredSplit, 0.2 ether);
        _assertRoyalty(collection, 2, configuredSplit, 0.2 ether);
    }

    function testOrdinaryFactoryCreationAndCustomMintReceiverRemainUnchanged() public {
        vm.prank(ARTIST);
        SovereignBatchMintV5 plain = SovereignBatchMintV5(factory.createSovereignBatchMint("Plain", "P", 3));
        vm.prank(ARTIST);
        LazySovereignBatchMintV5 plainLazy =
            LazySovereignBatchMintV5(lazyFactory.createLazySovereignBatchMint("Plain lazy", "PL", 3));
        vm.startPrank(ARTIST);
        plain.mintTo("ipfs://raw", COLLECTOR, RECIPIENT);
        plain.mintTo("ipfs://zero", COLLECTOR, address(0));
        plain.addNewToken("ipfs://artist");
        plainLazy.prepareMint("ipfs://plain-lazy", 1);
        vm.stopPrank();
        assertEq(plain.owner(), ARTIST);
        assertEq(plainLazy.owner(), ARTIST);
        assertEq(plain.tokenCreator(1), ARTIST);
        assertEq(plainLazy.tokenCreator(1), ARTIST);
        assertEq(address(plain.royaltySplitterFactory()), address(0));
        assertEq(address(plainLazy.royaltySplitterFactory()), address(0));
        _assertRoyalty(address(plain), 1, RECIPIENT, 0.2 ether);
        _assertRoyalty(address(plain), 2, ARTIST, 0.2 ether);
        _assertRoyalty(address(plain), 3, ARTIST, 0.2 ether);
        _assertRoyalty(address(plainLazy), 1, ARTIST, 0.2 ether);
        vm.expectRevert();
        plain.predictRoyaltySplitter(ALTERNATE);
        vm.expectRevert();
        plainLazy.predictRoyaltySplitter(ALTERNATE);
    }

    function testBothInitializersRejectReplayWithoutChangingOwnerOrTerms() public {
        RoyaltySplitConfig memory config = _config();
        vm.expectRevert("Initializable: contract is already initialized");
        token.initWithRoyaltySplit("Replay", "BAD", COLLECTOR, 1, address(splitterFactory), config);
        vm.expectRevert("Initializable: contract is already initialized");
        lazy.initWithRoyaltySplit("Replay", "BAD", COLLECTOR, 1, address(splitterFactory), config);
        vm.expectRevert("Initializable: contract is already initialized");
        token.init("Replay", "BAD", COLLECTOR, 1);
        vm.expectRevert("Initializable: contract is already initialized");
        lazy.init("Replay", "BAD", COLLECTOR, 1);
        assertEq(token.owner(), ARTIST);
        assertEq(lazy.owner(), ARTIST);
        _assertTemplates();
    }

    function testFactoryConfigurationIsOwnerOnlyAndRejectsZeroAndNoCode() public {
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(ARTIST);
        factory.setRoyaltySplitterFactory(address(splitterFactory));
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(ARTIST);
        lazyFactory.setRoyaltySplitterFactory(address(splitterFactory));
        vm.expectRevert();
        factory.setRoyaltySplitterFactory(address(0));
        vm.expectRevert();
        lazyFactory.setRoyaltySplitterFactory(address(0));
        vm.expectRevert();
        factory.setRoyaltySplitterFactory(ALTERNATE);
        vm.expectRevert();
        lazyFactory.setRoyaltySplitterFactory(ALTERNATE);
        assertEq(factory.royaltySplitterFactory(), address(splitterFactory));
        assertEq(lazyFactory.royaltySplitterFactory(), address(splitterFactory));
    }

    function testSplitCreationRequiresConfiguredFactoryAndCompatibleImplementation() public {
        SovereignBatchMintFactory unconfigured = new SovereignBatchMintFactory(address(new SovereignBatchMintV5()));
        LazySovereignBatchMintFactory unconfiguredLazy =
            new LazySovereignBatchMintFactory(address(new LazySovereignBatchMintV5()));
        RoyaltySplitConfig memory config = _config();
        vm.expectRevert();
        unconfigured.createSovereignBatchMintWithRoyaltySplit("No factory", "BAD", 1, config);
        vm.expectRevert();
        unconfiguredLazy.createLazySovereignBatchMintWithRoyaltySplit("No factory", "BAD", 1, config);
        factory.setSovereignBatchMint(address(new SovereignBatchMint()));
        lazyFactory.setLazySovereignBatchMint(address(new LazySovereignBatchMint()));
        _assertCreationReverts(config, 1);
    }

    function testInvalidTermsAndZeroCapRollBackBothFactoryCreations() public {
        RoyaltySplitConfig memory config = _config();
        _assertCreationReverts(config, 0);
        config.royaltyPercentage = 101;
        _assertCreationReverts(config, 1);
        config = _config();
        config.beneficiaryIndex = 2;
        _assertCreationReverts(config, 1);
        config = _config();
        config.recipients[0] = address(0);
        _assertCreationReverts(config, 1);
        config = _config();
        config.recipients[0] = ARTIST;
        _assertCreationReverts(config, 1);
        config = _config();
        config.shares[0] = 0;
        _assertCreationReverts(config, 1);
        config = _config();
        config.shares = new uint256[](1);
        config.shares[0] = 1;
        _assertCreationReverts(config, 1);
        config.recipients = new address[](0);
        config.shares = new uint256[](0);
        config.beneficiaryIndex = 0;
        _assertCreationReverts(config, 1);
    }

    function testInitializationRevertLeavesNoSplitterCloneOrInitializedState() public {
        RoyaltySplitConfig memory config = _config();
        config.recipients[0] = OPERATOR;
        address predicted = splitterFactory.predictSplitter(config.recipients, config.shares);
        SovereignBatchMintV5 fresh = new SovereignBatchMintV5();
        LazySovereignBatchMintV5 freshLazy = new LazySovereignBatchMintV5();
        bytes memory validatorCode = V5.code;
        vm.etch(V5, hex"");
        _assertCreationReverts(config, 2);
        vm.expectRevert();
        fresh.initWithRoyaltySplit("Failed", "BAD", ARTIST, 2, address(splitterFactory), config);
        vm.expectRevert();
        freshLazy.initWithRoyaltySplit("Failed lazy", "BAD", ARTIST, 2, address(splitterFactory), config);
        assertEq(predicted.code.length, 0);
        assertEq(splitterFactory.configurationHash(predicted), bytes32(0));
        assertEq(fresh.owner(), address(0));
        assertEq(freshLazy.owner(), address(0));
        assertEq(address(fresh.royaltySplitterFactory()), address(0));
        assertEq(address(freshLazy.royaltySplitterFactory()), address(0));
        vm.etch(V5, validatorCode);
        fresh.initWithRoyaltySplit("Recovered", "OK", ARTIST, 2, address(splitterFactory), config);
        freshLazy.initWithRoyaltySplit("Recovered lazy", "OK", ARTIST, 2, address(splitterFactory), config);
        assertEq(fresh.owner(), ARTIST);
        assertEq(freshLazy.owner(), ARTIST);
        assertEq(fresh.getDefaultRoyaltyReceiver(), predicted);
        assertEq(freshLazy.getDefaultRoyaltyReceiver(), predicted);
    }

    function testInvalidTemplateAfterParentInitializationRollsBackAndAllowsValidRetry() public {
        SovereignBatchMintV5 fresh = new SovereignBatchMintV5();
        LazySovereignBatchMintV5 freshLazy = new LazySovereignBatchMintV5();
        RoyaltySplitConfig memory config = _config();
        config.recipients[0] = OPERATOR;
        config.royaltyPercentage = 101;
        address predicted = splitterFactory.predictSplitter(config.recipients, config.shares);
        vm.expectRevert();
        fresh.initWithRoyaltySplit("Bad rate", "BAD", ARTIST, 2, address(splitterFactory), config);
        vm.expectRevert();
        freshLazy.initWithRoyaltySplit("Bad rate lazy", "BAD", ARTIST, 2, address(splitterFactory), config);
        assertEq(fresh.owner(), address(0));
        assertEq(freshLazy.owner(), address(0));
        assertEq(fresh.getTransferValidator(), address(0));
        assertEq(freshLazy.getTransferValidator(), address(0));
        assertEq(predicted.code.length, 0);
        config.royaltyPercentage = 0;
        fresh.initWithRoyaltySplit("Zero", "ZERO", ARTIST, 2, address(splitterFactory), config);
        config.royaltyPercentage = 100;
        freshLazy.initWithRoyaltySplit("Full", "FULL", ARTIST, 2, address(splitterFactory), config);
        _assertRoyalty(address(fresh), 1, predicted, 0);
        _assertRoyalty(address(freshLazy), 1, predicted, 2 ether);
    }
}

/// @notice Checked-in V2 listing sources on local proxies; only the fork's actual V5/registries/royalty engine/WETH are reused.
contract RoyaltySplitCollectionsLocalV2MarketTest is RoyaltySplitCollectionsForkBase {
    address internal constant NETWORK = address(0xFEE);
    address internal constant BUYER = address(0xC0FFEE);
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    RareBatchListingMarketplace internal listing;
    ERC20ApprovalManager internal erc20Approver;
    ERC721ApprovalManager internal erc721Approver;
    MarketplaceSettingsV3 internal settings;

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
        ApprovedTokenRegistry approvedTokens = new ApprovedTokenRegistry();
        approvedTokens.addApprovedToken(WETH);
        listing = RareBatchListingMarketplace(address(new ERC1967Proxy(address(new RareBatchListingMarketplace()), "")));
        listing.initialize(
            address(settings),
            config.royaltyEngineManifold,
            config.spaceOperatorRegistry,
            address(approvedTokens),
            address(payments),
            config.stakingRegistry,
            address(settings),
            NETWORK,
            address(erc20Approver),
            address(erc721Approver)
        );
        settings.grantMarketplaceAccess(address(listing));
        erc20Approver.grantRole(erc20Approver.OPERATOR_ROLE(), address(listing));
        erc721Approver.grantOperatorRole(address(listing));
        _authorizeMarket(address(token));
        _authorizeMarket(address(lazy));
    }

    function testStandardSecondaryV2EthRoyaltyDepositsIntoSplitterThenPullReleases() public {
        vm.prank(ARTIST);
        token.addNewToken("ipfs://market-standard");
        _primaryThenSecondary(address(token), address(0));
        uint256 artistBefore = ARTIST.balance;
        uint256 recipientBefore = RECIPIENT.balance;
        vm.startPrank(OPERATOR);
        PaymentSplitter(payable(splitter)).release(payable(RECIPIENT));
        PaymentSplitter(payable(splitter)).release(payable(ARTIST));
        vm.stopPrank();
        assertEq(RECIPIENT.balance - recipientBefore, 0.04 ether);
        assertEq(ARTIST.balance - artistBefore, 0.16 ether);
        assertEq(splitter.balance, 0);
        assertEq(PaymentSplitter(payable(splitter)).totalReleased(), 0.2 ether);
        assertEq(PaymentSplitter(payable(splitter)).released(ARTIST), 0.16 ether);
    }

    function testLazySecondaryV2ActualWethRoyaltyDepositsIntoSplitterThenPullReleases() public {
        vm.prank(ARTIST);
        lazy.prepareMint("ipfs://market-lazy", 1);
        assertEq(lazy.totalSupply(), 0);
        _primaryThenSecondary(address(lazy), WETH);
        assertEq(lazy.totalSupply(), 1);
        IERC20 weth = IERC20(WETH);
        uint256 artistBefore = weth.balanceOf(ARTIST);
        uint256 recipientBefore = weth.balanceOf(RECIPIENT);
        vm.startPrank(OPERATOR);
        PaymentSplitter(payable(splitter)).release(weth, RECIPIENT);
        PaymentSplitter(payable(splitter)).release(weth, ARTIST);
        vm.stopPrank();
        assertEq(weth.balanceOf(RECIPIENT) - recipientBefore, 0.04 ether);
        assertEq(weth.balanceOf(ARTIST) - artistBefore, 0.16 ether);
        assertEq(weth.balanceOf(splitter), 0);
        assertEq(PaymentSplitter(payable(splitter)).totalReleased(weth), 0.2 ether);
        assertEq(PaymentSplitter(payable(splitter)).released(weth, ARTIST), 0.16 ether);
    }

    function _authorizeMarket(address collection) internal {
        address[] memory accounts = new address[](1);
        accounts[0] = address(erc721Approver);
        vm.startPrank(ARTIST);
        uint48 listId = validator.createList("Royalty split local V2 market");
        validator.applyListToCollection(collection, listId);
        validator.addAccountsToList(listId, 1, accounts);
        vm.stopPrank();
    }

    function _primaryThenSecondary(address collection, address currency) internal {
        bytes32 leaf = keccak256(abi.encodePacked(collection, uint256(1)));
        bytes32 sibling = keccak256(abi.encodePacked(collection, uint256(2)));
        bytes32 root =
            leaf < sibling ? keccak256(abi.encodePacked(leaf, sibling)) : keccak256(abi.encodePacked(sibling, leaf));
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = sibling;
        _assertRoyalty(collection, 1, splitter, 0.2 ether);
        uint256 artistBefore = _balance(currency, ARTIST);
        uint256 networkBefore = _balance(currency, NETWORK);
        _buy(collection, currency, ARTIST, COLLECTOR, 1 ether, root, proof);
        assertEq(IERC721(collection).ownerOf(1), COLLECTOR);
        assertEq(_balance(currency, ARTIST) - artistBefore, 0.85 ether);
        assertEq(_balance(currency, NETWORK) - networkBefore, 0.18 ether);
        assertEq(_balance(currency, splitter), 0);
        assertTrue(settings.hasERC721TokenSold(collection, 1));
        uint256 sellerBefore = _balance(currency, COLLECTOR);
        uint256 recipientBefore = _balance(currency, RECIPIENT);
        artistBefore = _balance(currency, ARTIST);
        networkBefore = _balance(currency, NETWORK);
        _buy(collection, currency, COLLECTOR, BUYER, 2 ether, root, proof);
        assertEq(IERC721(collection).ownerOf(1), BUYER);
        assertEq(_balance(currency, splitter), 0.2 ether);
        assertEq(_balance(currency, COLLECTOR) - sellerBefore, 1.8 ether);
        assertEq(_balance(currency, NETWORK) - networkBefore, 0.06 ether);
        // Royalties are held by OZ, not synchronously forwarded to either payee.
        assertEq(_balance(currency, ARTIST), artistBefore);
        assertEq(_balance(currency, RECIPIENT), recipientBefore);
        assertEq(_balance(currency, address(listing)), 0);
        assertEq(listing.getTokenSalePriceNonce(ARTIST, root, collection, 1), 1);
        assertEq(listing.getTokenSalePriceNonce(COLLECTOR, root, collection, 1), 1);
    }

    function _buy(
        address collection,
        address currency,
        address seller,
        address buyer,
        uint256 price,
        bytes32 root,
        bytes32[] memory proof
    ) internal {
        address payable[] memory recipients = new address payable[](1);
        recipients[0] = payable(seller);
        uint8[] memory ratios = new uint8[](1);
        ratios[0] = 100;
        vm.startPrank(seller);
        IERC721(collection).setApprovalForAll(address(erc721Approver), true);
        listing.registerSalePriceMerkleRoot(root, currency, price, recipients, ratios);
        vm.stopPrank();
        uint256 payment = price * 103 / 100;
        vm.deal(buyer, payment);
        vm.startPrank(buyer);
        if (currency != address(0)) {
            IRoyaltySplitWETH(currency).deposit{value: payment}();
            IERC20(currency).approve(address(erc20Approver), payment);
        }
        listing.buyWithMerkleProof{value: currency == address(0) ? payment : 0}(
            collection, 1, currency, price, seller, root, proof, new bytes32[](0)
        );
        vm.stopPrank();
    }

    function _balance(address currency, address account) internal view returns (uint256) {
        return currency == address(0) ? account.balance : IERC20(currency).balanceOf(account);
    }
}
