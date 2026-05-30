// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import {ERC20} from "openzeppelin-contracts/token/ERC20/ERC20.sol";
import {ERC1155} from "openzeppelin-contracts/token/ERC1155/ERC1155.sol";
import {IERC1155} from "openzeppelin-contracts/token/ERC1155/IERC1155.sol";
import {IERC165} from "openzeppelin-contracts/utils/introspection/IERC165.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {IApprovedTokenRegistry} from "../../registry/interfaces/IApprovedTokenRegistry.sol";
import {IRareStakingRegistry} from "../../staking/registry/IRareStakingRegistry.sol";
import {IStakingSettings} from "../../marketplace/IStakingSettings.sol";
import {IMarketplaceSettings} from "../../marketplace/IMarketplaceSettings.sol";
import {Payments} from "../../payments/Payments.sol";
import {RareERC1155} from "../../token/ERC1155/RareERC1155.sol";
import {RareERC1155ContractFactory} from "../../token/ERC1155/RareERC1155ContractFactory.sol";
import {RareERC1155Marketplace} from "../../marketplace/RareERC1155Marketplace.sol";
import {IRareERC1155Marketplace} from "../../marketplace/IRareERC1155Marketplace.sol";
import {ERC20ApprovalManager} from "../../v2/approver/ERC20/ERC20ApprovalManager.sol";
import {ERC721ApprovalManager} from "../../v2/approver/ERC721/ERC721ApprovalManager.sol";
import {ERC1155ApprovalManager} from "../../v2/approver/ERC1155/ERC1155ApprovalManager.sol";
import {ISpaceOperatorRegistry} from "../../registry/interfaces/ISpaceOperatorRegistry.sol";
import {IRoyaltyEngineV1} from "royalty-registry/IRoyaltyEngineV1.sol";

contract TestERC1155Currency is ERC20 {
    constructor() ERC20("Currency", "CUR") {
        _mint(msg.sender, 1_000_000_000 ether);
    }
}

contract TestOpenERC1155 is ERC1155 {
    constructor() ERC1155("ipfs://open/{id}.json") {}

    function mint(address _to, uint256 _tokenId, uint256 _amount) external {
        _mint(_to, _tokenId, _amount, "");
    }
}

contract TestNonERC165ERC1155Like {
    mapping(address => mapping(uint256 => uint256)) private balances;
    mapping(address => mapping(address => bool)) private operatorApprovals;

    function setBalance(address _account, uint256 _tokenId, uint256 _amount) external {
        balances[_account][_tokenId] = _amount;
    }

    function balanceOf(address _account, uint256 _tokenId) external view returns (uint256) {
        return balances[_account][_tokenId];
    }

    function isApprovedForAll(address _account, address _operator) external view returns (bool) {
        return operatorApprovals[_account][_operator];
    }

    function setApprovalForAll(address _operator, bool _approved) external {
        operatorApprovals[msg.sender][_operator] = _approved;
    }

    function safeTransferFrom(address, address, uint256, uint256, bytes calldata) external {}
}

contract TestNoOpERC1155 is IERC1155 {
    mapping(address => mapping(uint256 => uint256)) private balances;
    mapping(address => mapping(address => bool)) private operatorApprovals;

    function supportsInterface(bytes4 _interfaceId) external pure override returns (bool) {
        return _interfaceId == type(IERC165).interfaceId || _interfaceId == type(IERC1155).interfaceId;
    }

    function setBalance(address _account, uint256 _tokenId, uint256 _amount) external {
        balances[_account][_tokenId] = _amount;
    }

    function balanceOf(address _account, uint256 _tokenId) external view override returns (uint256) {
        return balances[_account][_tokenId];
    }

    function balanceOfBatch(address[] calldata _accounts, uint256[] calldata _ids)
        external
        view
        override
        returns (uint256[] memory)
    {
        uint256[] memory batchBalances = new uint256[](_accounts.length);
        for (uint256 i = 0; i < _accounts.length; i++) {
            batchBalances[i] = balances[_accounts[i]][_ids[i]];
        }
        return batchBalances;
    }

    function setApprovalForAll(address _operator, bool _approved) external override {
        operatorApprovals[msg.sender][_operator] = _approved;
    }

    function isApprovedForAll(address _account, address _operator) external view override returns (bool) {
        return operatorApprovals[_account][_operator];
    }

    function safeTransferFrom(address, address, uint256, uint256, bytes calldata) external override {}

    function safeBatchTransferFrom(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        override
    {}
}

contract RareERC1155MarketplaceTest is Test {
    event MarketplaceDependencyUpdated(bytes32 indexed field, address indexed dependency);
    event ContractPausedUpdated(bool isPaused);

    RareERC1155Marketplace private market;
    RareERC1155 private token;
    TestERC1155Currency private currency;
    ERC20ApprovalManager private erc20ApprovalManager;
    ERC721ApprovalManager private erc721ApprovalManager;
    ERC1155ApprovalManager private erc1155ApprovalManager;

    address private deployer = address(0x1000);
    address private seller = address(0x2000);
    address private buyer = address(0x3000);
    address private nextOwner = address(0x3500);
    address private royaltyReceiver = address(0x4000);
    address private networkBeneficiary = address(0x5000);
    address private rewardAccumulator = address(0x6000);
    address payable private splitRecipientA = payable(address(0x6100));
    address payable private splitRecipientB = payable(address(0x6200));

    address private stakingSettings = address(0x7100);
    address private marketplaceSettings = address(0x7200);
    address private royaltyEngine = address(0x7300);
    address private spaceOperatorRegistry = address(0x7400);
    address private approvedTokenRegistry = address(0x7500);
    address private stakingRegistry = address(0x7600);

    uint256 private tokenId;
    bytes32[] private emptyProof;
    bytes32 private constant MARKETPLACE_DEPENDENCY_UPDATED_TOPIC =
        keccak256("MarketplaceDependencyUpdated(bytes32,address)");

    receive() external payable {}

    function setUp() public {
        deal(deployer, 100 ether);
        deal(seller, 100 ether);
        deal(buyer, 100 ether);

        vm.startPrank(deployer);
        currency = new TestERC1155Currency();
        currency.transfer(buyer, 1_000_000 ether);
        erc20ApprovalManager = new ERC20ApprovalManager();
        erc721ApprovalManager = new ERC721ApprovalManager();
        erc1155ApprovalManager = new ERC1155ApprovalManager();

        RareERC1155Marketplace implementation = new RareERC1155Marketplace();
        market = RareERC1155Marketplace(address(new ERC1967Proxy(address(implementation), "")));
        market.initialize(
            networkBeneficiary,
            marketplaceSettings,
            spaceOperatorRegistry,
            royaltyEngine,
            address(new Payments()),
            approvedTokenRegistry,
            stakingSettings,
            stakingRegistry,
            address(erc20ApprovalManager),
            address(erc721ApprovalManager),
            address(erc1155ApprovalManager)
        );
        erc20ApprovalManager.grantOperatorRole(address(market));
        erc1155ApprovalManager.grantOperatorRole(address(market));

        RareERC1155ContractFactory tokenFactory = new RareERC1155ContractFactory();
        tokenFactory.setDefaultMinter(address(market));
        vm.stopPrank();

        vm.prank(seller);
        token = RareERC1155(tokenFactory.createRareERC1155Contract("Rare Editions", "RED", "ipfs://base/{id}.json"));

        vm.prank(seller);
        tokenId = token.createToken("ipfs://token/1.json", 20, royaltyReceiver);

        vm.etch(marketplaceSettings, address(market).code);
        vm.etch(stakingSettings, address(market).code);
        vm.etch(stakingRegistry, address(market).code);
        vm.etch(royaltyEngine, address(market).code);
        vm.etch(spaceOperatorRegistry, address(market).code);
        vm.etch(approvedTokenRegistry, address(market).code);
    }

    function testImplementationCannotBeInitialized() public {
        RareERC1155Marketplace directImplementation = new RareERC1155Marketplace();
        Payments payments = new Payments();

        vm.expectRevert("Initializable: contract is already initialized");
        directImplementation.initialize(
            networkBeneficiary,
            marketplaceSettings,
            spaceOperatorRegistry,
            royaltyEngine,
            address(payments),
            approvedTokenRegistry,
            stakingSettings,
            stakingRegistry,
            address(erc20ApprovalManager),
            address(erc721ApprovalManager),
            address(erc1155ApprovalManager)
        );
    }

    function testPrepareAndMintDirectSaleERC20() public {
        uint256 price = 1 ether;
        uint256 quantity = 2;
        uint256 totalPrice = price * quantity;

        _mockApprovedCurrency(true);
        _mockPrimaryPayout(totalPrice, seller);

        _prepareDirectSale(address(currency), price, block.timestamp, 0);

        vm.prank(buyer);
        currency.approve(address(erc20ApprovalManager), totalPrice + ((totalPrice * 3) / 100));

        uint256 buyerBalanceBefore = currency.balanceOf(buyer);
        uint256 sellerBalanceBefore = currency.balanceOf(seller);
        uint256 networkBalanceBefore = currency.balanceOf(networkBeneficiary);
        uint256 rewardBalanceBefore = currency.balanceOf(rewardAccumulator);

        vm.prank(buyer);
        market.mintDirectSale(address(token), tokenId, address(currency), price, quantity, emptyProof);

        assertEq(token.balanceOf(buyer, tokenId), quantity);
        assertEq(buyerBalanceBefore - currency.balanceOf(buyer), totalPrice + ((totalPrice * 3) / 100));
        assertEq(currency.balanceOf(seller) - sellerBalanceBefore, (totalPrice * 85) / 100);
        assertEq(
            currency.balanceOf(networkBeneficiary) - networkBalanceBefore,
            ((totalPrice * 2) / 100) + ((totalPrice * 15) / 100)
        );
        assertEq(currency.balanceOf(rewardAccumulator) - rewardBalanceBefore, (totalPrice * 1) / 100);
    }

    function testMintDirectSaleERC20SplitRoundingPaysFullAmount() public {
        uint256 price = 101;
        uint256 marketplaceFee = 3;

        address payable[] memory splitRecipients = new address payable[](3);
        uint8[] memory splitRatios = new uint8[](3);
        splitRecipients[0] = payable(seller);
        splitRecipients[1] = splitRecipientA;
        splitRecipients[2] = splitRecipientB;
        splitRatios[0] = 33;
        splitRatios[1] = 33;
        splitRatios[2] = 34;

        _mockApprovedCurrency(true);
        _mockPrimaryPayout(price, seller);
        _prepareDirectSaleWithSplits(address(currency), price, block.timestamp, 0, splitRecipients, splitRatios);

        vm.prank(buyer);
        currency.approve(address(erc20ApprovalManager), price + marketplaceFee);

        uint256 buyerBalanceBefore = currency.balanceOf(buyer);
        uint256 networkBalanceBefore = currency.balanceOf(networkBeneficiary);
        uint256 rewardBalanceBefore = currency.balanceOf(rewardAccumulator);

        vm.prank(buyer);
        market.mintDirectSale(address(token), tokenId, address(currency), price, 1, emptyProof);

        assertEq(buyerBalanceBefore - currency.balanceOf(buyer), price + marketplaceFee);
        assertEq(currency.balanceOf(seller), 28);
        assertEq(currency.balanceOf(splitRecipientA), 28);
        assertEq(currency.balanceOf(splitRecipientB), 30);
        assertEq(currency.balanceOf(networkBeneficiary) - networkBalanceBefore, 17);
        assertEq(currency.balanceOf(rewardAccumulator) - rewardBalanceBefore, 1);
        assertEq(currency.balanceOf(address(market)), 0);
    }

    function testMintDirectSaleETH() public {
        uint256 price = 1 ether;
        uint256 quantity = 2;
        uint256 totalPrice = price * quantity;

        _mockPrimaryPayout(totalPrice, seller);
        _prepareDirectSale(address(0), price, block.timestamp, 0);

        uint256 sellerBalanceBefore = seller.balance;
        uint256 networkBalanceBefore = networkBeneficiary.balance;
        uint256 rewardBalanceBefore = rewardAccumulator.balance;

        vm.prank(buyer);
        market.mintDirectSale{value: totalPrice + ((totalPrice * 3) / 100)}(
            address(token), tokenId, address(0), price, quantity, emptyProof
        );

        assertEq(token.balanceOf(buyer, tokenId), quantity);
        assertEq(seller.balance - sellerBalanceBefore, (totalPrice * 85) / 100);
        assertEq(
            networkBeneficiary.balance - networkBalanceBefore, ((totalPrice * 2) / 100) + ((totalPrice * 15) / 100)
        );
        assertEq(rewardAccumulator.balance - rewardBalanceBefore, (totalPrice * 1) / 100);
    }

    function testMintDirectSaleFree() public {
        _prepareDirectSale(address(0), 0, block.timestamp, 0);

        vm.prank(buyer);
        market.mintDirectSale(address(token), tokenId, address(0), 0, 3, emptyProof);

        assertEq(token.balanceOf(buyer, tokenId), 3);
    }

    function testPrepareMintDirectSaleRevertsForZeroSplitRecipient() public {
        address payable[] memory splitRecipients = new address payable[](2);
        uint8[] memory splitRatios = new uint8[](2);
        splitRecipients[0] = payable(address(0));
        splitRecipients[1] = payable(seller);
        splitRatios[0] = 50;
        splitRatios[1] = 50;

        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(IRareERC1155Marketplace.SplitRecipientCannotBeZero.selector, 0));
        market.prepareMintDirectSale(
            address(token), tokenId, address(0), 1 ether, block.timestamp, 0, splitRecipients, splitRatios
        );
    }

    function testPrepareMintDirectSaleRevertsForZeroSplitRatio() public {
        address payable[] memory splitRecipients = new address payable[](2);
        uint8[] memory splitRatios = new uint8[](2);
        splitRecipients[0] = payable(seller);
        splitRecipients[1] = splitRecipientA;
        splitRatios[0] = 0;
        splitRatios[1] = 100;

        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(IRareERC1155Marketplace.SplitRatioCannotBeZero.selector, 0));
        market.prepareMintDirectSale(
            address(token), tokenId, address(0), 1 ether, block.timestamp, 0, splitRecipients, splitRatios
        );
    }

    function testMintDirectSaleRevertsAfterCollectionOwnershipChanges() public {
        uint256 price = 1 ether;
        _prepareDirectSale(address(0), price, block.timestamp, 0);

        vm.prank(seller);
        token.transferOwnership(nextOwner);

        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(IRareERC1155Marketplace.NotContractOwner.selector, address(token), seller)
        );
        market.mintDirectSale{value: price + ((price * 3) / 100)}(
            address(token), tokenId, address(0), price, 1, emptyProof
        );

        assertEq(token.balanceOf(buyer, tokenId), 0);
    }

    function testMintDirectSaleDerivesNetworkFeeFromMarketplaceFee() public {
        uint256 price = 101;
        _prepareDirectSale(address(0), price, block.timestamp, 0);
        _mockInconsistentMarketplaceFee(price, seller);
        vm.mockCall(
            spaceOperatorRegistry,
            abi.encodeWithSelector(ISpaceOperatorRegistry.isApprovedSpaceOperator.selector, seller),
            abi.encode(false)
        );
        vm.mockCall(
            marketplaceSettings,
            abi.encodeWithSelector(
                IMarketplaceSettings.getERC721ContractPrimarySaleFeePercentage.selector, address(token)
            ),
            abi.encode(15)
        );

        uint256 sellerBalanceBefore = seller.balance;
        uint256 networkBalanceBefore = networkBeneficiary.balance;
        uint256 rewardBalanceBefore = rewardAccumulator.balance;

        vm.prank(buyer);
        market.mintDirectSale{value: 104}(address(token), tokenId, address(0), price, 1, emptyProof);

        assertEq(token.balanceOf(buyer, tokenId), 1);
        assertEq(seller.balance - sellerBalanceBefore, 86);
        assertEq(networkBeneficiary.balance - networkBalanceBefore, 17);
        assertEq(rewardAccumulator.balance - rewardBalanceBefore, 1);
        assertEq(address(market).balance, 0);
    }

    function testMintDirectSaleRevertsWhenStakingFeeExceedsMarketplaceFee() public {
        uint256 price = 101;
        _prepareDirectSale(address(0), price, block.timestamp, 0);
        vm.mockCall(
            marketplaceSettings,
            abi.encodeWithSelector(IMarketplaceSettings.calculateMarketplaceFee.selector, price),
            abi.encode(3)
        );
        vm.mockCall(
            stakingRegistry,
            abi.encodeWithSelector(IRareStakingRegistry.getRewardAccumulatorAddressForUser.selector, seller),
            abi.encode(rewardAccumulator)
        );
        vm.mockCall(
            stakingSettings, abi.encodeWithSelector(IStakingSettings.calculateStakingFee.selector, price), abi.encode(4)
        );

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(IRareERC1155Marketplace.StakingFeeExceedsMarketplaceFee.selector, 3, 4));
        market.mintDirectSale{value: 104}(address(token), tokenId, address(0), price, 1, emptyProof);

        assertEq(token.balanceOf(buyer, tokenId), 0);
        assertEq(address(market).balance, 0);
    }

    function testMintDirectSaleRevertsWhenSettingsPlatformCommissionExceedsMax() public {
        uint256 price = 1 ether;
        _prepareDirectSale(address(0), price, block.timestamp, 0);
        _mockMarketplaceFee(price, seller);
        vm.mockCall(
            spaceOperatorRegistry,
            abi.encodeWithSelector(ISpaceOperatorRegistry.isApprovedSpaceOperator.selector, seller),
            abi.encode(false)
        );
        vm.mockCall(
            marketplaceSettings,
            abi.encodeWithSelector(
                IMarketplaceSettings.getERC721ContractPrimarySaleFeePercentage.selector, address(token)
            ),
            abi.encode(101)
        );

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(IRareERC1155Marketplace.PlatformCommissionExceeded.selector, 101, 100));
        market.mintDirectSale{value: price + ((price * 3) / 100)}(
            address(token), tokenId, address(0), price, 1, emptyProof
        );

        assertEq(token.balanceOf(buyer, tokenId), 0);
        assertEq(address(market).balance, 0);
    }

    function testMintDirectSaleRevertsWhenSpaceOperatorPlatformCommissionExceedsMax() public {
        uint256 price = 1 ether;
        _prepareDirectSale(address(0), price, block.timestamp, 0);
        _mockMarketplaceFee(price, seller);
        vm.mockCall(
            spaceOperatorRegistry,
            abi.encodeWithSelector(ISpaceOperatorRegistry.isApprovedSpaceOperator.selector, seller),
            abi.encode(true)
        );
        vm.mockCall(
            spaceOperatorRegistry,
            abi.encodeWithSelector(ISpaceOperatorRegistry.getPlatformCommission.selector, seller),
            abi.encode(101)
        );

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(IRareERC1155Marketplace.PlatformCommissionExceeded.selector, 101, 100));
        market.mintDirectSale{value: price + ((price * 3) / 100)}(
            address(token), tokenId, address(0), price, 1, emptyProof
        );

        assertEq(token.balanceOf(buyer, tokenId), 0);
        assertEq(address(market).balance, 0);
    }

    function testMintDirectSaleAllowListAndLimits() public {
        uint256 price = 1 ether;
        bytes32 root = keccak256(abi.encodePacked(buyer));

        _prepareDirectSale(address(0), price, block.timestamp, 2);

        vm.prank(seller);
        market.setTokenAllowListConfig(root, block.timestamp + 1 days, address(token), tokenId);

        vm.prank(seller);
        market.setTokenMintLimit(address(token), tokenId, 2);

        _mockPrimaryPayout(price * 2, seller);
        vm.prank(buyer);
        market.mintDirectSale{value: (price * 2) + (((price * 2) * 3) / 100)}(
            address(token), tokenId, address(0), price, 2, emptyProof
        );

        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRareERC1155Marketplace.MintLimitExceeded.selector, address(token), tokenId, buyer, 1, 2, 2
            )
        );
        market.mintDirectSale{value: price + ((price * 3) / 100)}(
            address(token), tokenId, address(0), price, 1, emptyProof
        );
    }

    function testMintDirectSaleAllowListRejectsNonMember() public {
        uint256 price = 1 ether;
        bytes32 root = keccak256(abi.encodePacked(address(0x9999)));

        _prepareDirectSale(address(0), price, block.timestamp, 0);

        vm.prank(seller);
        market.setTokenAllowListConfig(root, block.timestamp + 1 days, address(token), tokenId);

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(IRareERC1155Marketplace.AddressNotAllowlisted.selector, buyer));
        market.mintDirectSale{value: price + ((price * 3) / 100)}(
            address(token), tokenId, address(0), price, 1, emptyProof
        );
    }

    function testTokenScopedPrimaryConfigRevertsForUnknownTokenId() public {
        uint256 missingTokenId = tokenId + 1;
        bytes32 root = keccak256(abi.encodePacked(buyer));

        vm.startPrank(seller);
        vm.expectRevert(
            abi.encodeWithSelector(IRareERC1155Marketplace.TokenNotFound.selector, address(token), missingTokenId)
        );
        market.setTokenAllowListConfig(root, block.timestamp + 1 days, address(token), missingTokenId);

        vm.expectRevert(
            abi.encodeWithSelector(IRareERC1155Marketplace.TokenNotFound.selector, address(token), missingTokenId)
        );
        market.setTokenMintLimit(address(token), missingTokenId, 1);

        vm.expectRevert(
            abi.encodeWithSelector(IRareERC1155Marketplace.TokenNotFound.selector, address(token), missingTokenId)
        );
        market.setTokenTxLimit(address(token), missingTokenId, 1);
        vm.stopPrank();
    }

    function testMintDirectSaleTxLimit() public {
        uint256 price = 1 ether;
        _prepareDirectSale(address(0), price, block.timestamp, 0);

        vm.prank(seller);
        market.setTokenTxLimit(address(token), tokenId, 1);

        _mockPrimaryPayout(price, seller);
        vm.prank(buyer);
        market.mintDirectSale{value: price + ((price * 3) / 100)}(
            address(token), tokenId, address(0), price, 1, emptyProof
        );

        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRareERC1155Marketplace.TransactionLimitExceeded.selector, address(token), tokenId, buyer, 1, 1
            )
        );
        market.mintDirectSale{value: price + ((price * 3) / 100)}(
            address(token), tokenId, address(0), price, 1, emptyProof
        );
    }

    function testMintDirectSaleLimitsOnlyCountWhileEnabled() public {
        _prepareDirectSale(address(0), 0, block.timestamp, 0);

        vm.prank(buyer);
        market.mintDirectSale(address(token), tokenId, address(0), 0, 2, emptyProof);

        assertEq(market.getTokenMintsPerAddress(address(token), tokenId, buyer), 0);
        assertEq(market.getTokenTxsPerAddress(address(token), tokenId, buyer), 0);

        vm.startPrank(seller);
        market.setTokenMintLimit(address(token), tokenId, 1);
        market.setTokenTxLimit(address(token), tokenId, 1);
        vm.stopPrank();

        vm.prank(buyer);
        market.mintDirectSale(address(token), tokenId, address(0), 0, 1, emptyProof);

        assertEq(market.getTokenMintsPerAddress(address(token), tokenId, buyer), 1);
        assertEq(market.getTokenTxsPerAddress(address(token), tokenId, buyer), 1);

        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRareERC1155Marketplace.MintLimitExceeded.selector, address(token), tokenId, buyer, 1, 1, 1
            )
        );
        market.mintDirectSale(address(token), tokenId, address(0), 0, 1, emptyProof);
    }

    function testMintDirectSaleLimitsAreTokenScoped() public {
        uint256 otherTokenId;

        vm.prank(seller);
        otherTokenId = token.createToken("ipfs://token/2.json", 20, royaltyReceiver);

        _prepareDirectSale(address(0), 0, block.timestamp, 0);
        _prepareDirectSaleForToken(otherTokenId, address(0), 0, block.timestamp, 0);

        vm.prank(seller);
        market.setTokenMintLimit(address(token), tokenId, 1);

        vm.prank(buyer);
        market.mintDirectSale(address(token), tokenId, address(0), 0, 1, emptyProof);

        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRareERC1155Marketplace.MintLimitExceeded.selector, address(token), tokenId, buyer, 1, 1, 1
            )
        );
        market.mintDirectSale(address(token), tokenId, address(0), 0, 1, emptyProof);

        vm.prank(buyer);
        market.mintDirectSale(address(token), otherTokenId, address(0), 0, 2, emptyProof);

        assertEq(token.balanceOf(buyer, tokenId), 1);
        assertEq(token.balanceOf(buyer, otherTokenId), 2);
        assertEq(market.getTokenMintsPerAddress(address(token), tokenId, buyer), 1);
        assertEq(market.getTokenMintsPerAddress(address(token), otherTokenId, buyer), 0);
    }

    function testMintDirectSaleRevertsForWrongPriceCurrencyAndStartTime() public {
        uint256 price = 1 ether;
        _mockApprovedCurrency(true);
        _prepareDirectSale(address(currency), price, block.timestamp + 1 hours, 0);

        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(IRareERC1155Marketplace.SaleNotStarted.selector, block.timestamp + 1 hours)
        );
        market.mintDirectSale(address(token), tokenId, address(currency), price, 1, emptyProof);

        skip(1 hours);

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(IRareERC1155Marketplace.PriceMismatch.selector, price + 1, price));
        market.mintDirectSale(address(token), tokenId, address(currency), price + 1, 1, emptyProof);

        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(IRareERC1155Marketplace.CurrencyMismatch.selector, address(0), address(currency))
        );
        market.mintDirectSale(address(token), tokenId, address(0), price, 1, emptyProof);
    }

    function testSetSalePriceAndBuyPartialERC20() public {
        uint256 price = 1 ether;
        uint256 quantity = 2;
        uint256 totalPrice = price * quantity;

        _mintToSellerAndList(address(currency), price, 4);
        _mockApprovedCurrency(true);
        _mockSecondaryPayout(totalPrice, seller);

        vm.prank(buyer);
        currency.approve(address(erc20ApprovalManager), totalPrice + ((totalPrice * 3) / 100));

        uint256 sellerBalanceBefore = currency.balanceOf(seller);
        uint256 royaltyBalanceBefore = currency.balanceOf(royaltyReceiver);
        uint256 networkBalanceBefore = currency.balanceOf(networkBeneficiary);
        uint256 rewardBalanceBefore = currency.balanceOf(rewardAccumulator);

        vm.prank(buyer);
        market.buy(address(token), tokenId, seller, address(currency), price, quantity);

        assertEq(token.balanceOf(buyer, tokenId), quantity);
        assertEq(currency.balanceOf(seller) - sellerBalanceBefore, (totalPrice * 90) / 100);
        assertEq(currency.balanceOf(royaltyReceiver) - royaltyBalanceBefore, (totalPrice * 10) / 100);
        assertEq(currency.balanceOf(networkBeneficiary) - networkBalanceBefore, (totalPrice * 2) / 100);
        assertEq(currency.balanceOf(rewardAccumulator) - rewardBalanceBefore, (totalPrice * 1) / 100);

        IRareERC1155Marketplace.SalePrice memory salePrice = market.getSalePrice(address(token), tokenId, seller);
        assertEq(salePrice.quantity, 2);
    }

    function testBuyRevertsForRoyaltyPayoutLengthMismatch() public {
        uint256 price = 1 ether;

        _mintToSellerAndList(address(0), price, 1);
        _mockMarketplaceFee(price, seller);

        address payable[] memory receivers = new address payable[](1);
        uint256[] memory royalties = new uint256[](2);
        receivers[0] = payable(royaltyReceiver);
        royalties[0] = 0.01 ether;
        royalties[1] = 0.01 ether;

        vm.mockCall(
            royaltyEngine,
            abi.encodeWithSelector(IRoyaltyEngineV1.getRoyalty.selector, address(token), tokenId, price),
            abi.encode(receivers, royalties)
        );

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(IRareERC1155Marketplace.PayoutLengthMismatch.selector, 1, 2));
        market.buy{value: price + ((price * 3) / 100)}(address(token), tokenId, seller, address(0), price, 1);

        assertEq(token.balanceOf(buyer, tokenId), 0);
        assertEq(token.balanceOf(seller, tokenId), 1);
        assertEq(address(market).balance, 0);
    }

    function testBuyRemainingQuantityClearsSalePrice() public {
        uint256 price = 1 ether;
        uint256 quantity = 2;
        uint256 totalPrice = price * quantity;

        _mintToSellerAndList(address(0), price, quantity);
        _mockSecondaryPayout(totalPrice, seller);

        vm.prank(buyer);
        market.buy{value: totalPrice + ((totalPrice * 3) / 100)}(
            address(token), tokenId, seller, address(0), price, quantity
        );

        IRareERC1155Marketplace.SalePrice memory salePrice = market.getSalePrice(address(token), tokenId, seller);
        assertEq(salePrice.quantity, 0);
    }

    function testSetSalePriceAndBuyArbitraryERC1155() public {
        TestOpenERC1155 openToken = new TestOpenERC1155();
        uint256 openTokenId = 42;
        uint256 price = 1 ether;
        uint256 quantity = 2;
        uint256 totalPrice = price * quantity;

        openToken.mint(seller, openTokenId, quantity);

        vm.prank(seller);
        openToken.setApprovalForAll(address(erc1155ApprovalManager), true);

        address payable[] memory splitRecipients = new address payable[](1);
        uint8[] memory splitRatios = new uint8[](1);
        splitRecipients[0] = payable(seller);
        splitRatios[0] = 100;

        vm.prank(seller);
        market.setSalePrice(address(openToken), openTokenId, address(0), price, quantity, splitRecipients, splitRatios);

        _mockSecondaryPayoutFor(address(openToken), openTokenId, totalPrice, seller);

        vm.prank(buyer);
        market.buy{value: totalPrice + ((totalPrice * 3) / 100)}(
            address(openToken), openTokenId, seller, address(0), price, quantity
        );

        assertEq(openToken.balanceOf(seller, openTokenId), 0);
        assertEq(openToken.balanceOf(buyer, openTokenId), quantity);
    }

    function testBuyRevertsForStaleApprovalAndBalance() public {
        uint256 price = 1 ether;

        _mintToSellerAndList(address(0), price, 2);

        vm.prank(seller);
        token.setApprovalForAll(address(erc1155ApprovalManager), false);

        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(IRareERC1155Marketplace.MarketplaceNotApproved.selector, seller, address(token))
        );
        market.buy{value: price + ((price * 3) / 100)}(address(token), tokenId, seller, address(0), price, 1);

        vm.prank(seller);
        token.setApprovalForAll(address(erc1155ApprovalManager), true);

        vm.prank(seller);
        token.safeTransferFrom(seller, address(0x9999), tokenId, 2, "");

        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRareERC1155Marketplace.InsufficientTokenBalance.selector, seller, address(token), tokenId, 1, 0
            )
        );
        market.buy{value: price + ((price * 3) / 100)}(address(token), tokenId, seller, address(0), price, 1);
    }

    function testSetSalePriceRevertsForNonERC1155Contract() public {
        TestNonERC165ERC1155Like nonERC1155 = new TestNonERC165ERC1155Like();
        uint256 unsupportedTokenId = 77;

        nonERC1155.setBalance(seller, unsupportedTokenId, 1);

        vm.prank(seller);
        nonERC1155.setApprovalForAll(address(erc1155ApprovalManager), true);

        address payable[] memory splitRecipients = new address payable[](1);
        uint8[] memory splitRatios = new uint8[](1);
        splitRecipients[0] = payable(seller);
        splitRatios[0] = 100;

        vm.prank(seller);
        vm.expectRevert(
            abi.encodeWithSelector(IRareERC1155Marketplace.InvalidERC1155Contract.selector, address(nonERC1155))
        );
        market.setSalePrice(
            address(nonERC1155), unsupportedTokenId, address(0), 1 ether, 1, splitRecipients, splitRatios
        );
    }

    function testSetSalePriceRevertsForZeroSplitRecipient() public {
        address payable[] memory splitRecipients = new address payable[](2);
        uint8[] memory splitRatios = new uint8[](2);
        splitRecipients[0] = payable(seller);
        splitRecipients[1] = payable(address(0));
        splitRatios[0] = 50;
        splitRatios[1] = 50;

        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(IRareERC1155Marketplace.SplitRecipientCannotBeZero.selector, 1));
        market.setSalePrice(address(token), tokenId, address(0), 1 ether, 1, splitRecipients, splitRatios);
    }

    function testSetSalePriceRevertsForZeroSplitRatio() public {
        address payable[] memory splitRecipients = new address payable[](2);
        uint8[] memory splitRatios = new uint8[](2);
        splitRecipients[0] = payable(seller);
        splitRecipients[1] = splitRecipientA;
        splitRatios[0] = 100;
        splitRatios[1] = 0;

        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(IRareERC1155Marketplace.SplitRatioCannotBeZero.selector, 1));
        market.setSalePrice(address(token), tokenId, address(0), 1 ether, 1, splitRecipients, splitRatios);
    }

    function testBuyRevertsWhenERC1155TransferDoesNotMoveBalances() public {
        TestNoOpERC1155 brokenToken = new TestNoOpERC1155();
        uint256 brokenTokenId = 88;
        uint256 price = 1 ether;

        brokenToken.setBalance(seller, brokenTokenId, 1);

        vm.prank(seller);
        brokenToken.setApprovalForAll(address(erc1155ApprovalManager), true);

        address payable[] memory splitRecipients = new address payable[](1);
        uint8[] memory splitRatios = new uint8[](1);
        splitRecipients[0] = payable(seller);
        splitRatios[0] = 100;

        vm.prank(seller);
        market.setSalePrice(address(brokenToken), brokenTokenId, address(0), price, 1, splitRecipients, splitRatios);

        _mockMarketplaceFee(price, seller);

        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRareERC1155Marketplace.InvalidERC1155Transfer.selector,
                address(brokenToken),
                brokenTokenId,
                seller,
                buyer,
                1
            )
        );
        market.buy{value: price + ((price * 3) / 100)}(
            address(brokenToken), brokenTokenId, seller, address(0), price, 1
        );

        assertEq(brokenToken.balanceOf(seller, brokenTokenId), 1);
        assertEq(brokenToken.balanceOf(buyer, brokenTokenId), 0);
    }

    function testBuyRevertsForSelfPurchase() public {
        uint256 price = 1 ether;

        _mintToSellerAndList(address(0), price, 1);

        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(IRareERC1155Marketplace.SelfPurchaseUnsupported.selector, seller));
        market.buy{value: price + ((price * 3) / 100)}(address(token), tokenId, seller, address(0), price, 1);
    }

    function testCancelSalePrice() public {
        _mintToSellerAndList(address(0), 1 ether, 2);

        vm.prank(seller);
        market.cancelSalePrice(address(token), tokenId);

        IRareERC1155Marketplace.SalePrice memory salePrice = market.getSalePrice(address(token), tokenId, seller);
        assertEq(salePrice.quantity, 0);
    }

    function testCancelSalePriceAllowedWhilePaused() public {
        _mintToSellerAndList(address(0), 1 ether, 2);

        vm.prank(deployer);
        market.setContractPaused(true);

        vm.prank(seller);
        market.cancelSalePrice(address(token), tokenId);

        IRareERC1155Marketplace.SalePrice memory salePrice = market.getSalePrice(address(token), tokenId, seller);
        assertEq(salePrice.quantity, 0);
    }

    function testSetContractPausedEmitsEvent() public {
        vm.prank(deployer);
        vm.expectEmit(false, false, false, true, address(market));
        emit ContractPausedUpdated(true);
        market.setContractPaused(true);
    }

    function testDependencySettersEmitLocalEvents() public {
        _expectDependencyUpdate("NETWORK_BENEFICIARY", address(0x8001), this._setNetworkBeneficiary);
        _expectDependencyUpdate("MARKETPLACE_SETTINGS", address(0x8002), this._setMarketplaceSettings);
        _expectDependencyUpdate("SPACE_OPERATOR_REGISTRY", address(0x8003), this._setSpaceOperatorRegistry);
        _expectDependencyUpdate("ROYALTY_ENGINE", address(0x8004), this._setRoyaltyEngine);
        _expectDependencyUpdate("PAYMENTS", address(0x8005), this._setPayments);
        _expectDependencyUpdate("APPROVED_TOKEN_REGISTRY", address(0x8006), this._setApprovedTokenRegistry);
        _expectDependencyUpdate("STAKING_SETTINGS", address(0x8007), this._setStakingSettings);
        _expectDependencyUpdate("STAKING_REGISTRY", address(0x8008), this._setStakingRegistry);
        _expectDependencyUpdate("ERC20_APPROVAL_MANAGER", address(0x8009), this._setERC20ApprovalManager);
        _expectDependencyUpdate("ERC721_APPROVAL_MANAGER", address(0x8010), this._setERC721ApprovalManager);
        _expectDependencyUpdate("ERC1155_APPROVAL_MANAGER", address(0x8011), this._setERC1155ApprovalManager);
    }

    function testSetSalePriceRevertsWhilePaused() public {
        address payable[] memory splitRecipients = new address payable[](1);
        uint8[] memory splitRatios = new uint8[](1);
        splitRecipients[0] = payable(seller);
        splitRatios[0] = 100;

        vm.prank(deployer);
        market.setContractPaused(true);

        vm.prank(seller);
        vm.expectRevert(IRareERC1155Marketplace.ContractPaused.selector);
        market.setSalePrice(address(token), tokenId, address(0), 1 ether, 1, splitRecipients, splitRatios);
    }

    function testBuyRevertsWhilePaused() public {
        uint256 price = 1 ether;
        _mintToSellerAndList(address(0), price, 2);

        vm.prank(deployer);
        market.setContractPaused(true);

        vm.prank(buyer);
        vm.expectRevert(IRareERC1155Marketplace.ContractPaused.selector);
        market.buy{value: price + ((price * 3) / 100)}(address(token), tokenId, seller, address(0), price, 1);
    }

    function _expectDependencyUpdate(bytes32 _field, address _dependency, function(address) external _setter) private {
        vm.recordLogs();

        _setter(_dependency);

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 dependencyTopic = bytes32(uint256(uint160(_dependency)));
        bool found;

        for (uint256 i = 0; i < entries.length; i++) {
            if (
                entries[i].emitter == address(market) && entries[i].topics.length == 3
                    && entries[i].topics[0] == MARKETPLACE_DEPENDENCY_UPDATED_TOPIC && entries[i].topics[1] == _field
                    && entries[i].topics[2] == dependencyTopic
            ) {
                found = true;
                break;
            }
        }

        assertTrue(found, "missing dependency update event");
    }

    function _setNetworkBeneficiary(address _dependency) external {
        vm.prank(deployer);
        market.setNetworkBeneficiary(_dependency);
    }

    function _setMarketplaceSettings(address _dependency) external {
        vm.prank(deployer);
        market.setMarketplaceSettings(_dependency);
    }

    function _setSpaceOperatorRegistry(address _dependency) external {
        vm.prank(deployer);
        market.setSpaceOperatorRegistry(_dependency);
    }

    function _setRoyaltyEngine(address _dependency) external {
        vm.prank(deployer);
        market.setRoyaltyEngine(_dependency);
    }

    function _setPayments(address _dependency) external {
        vm.prank(deployer);
        market.setPayments(_dependency);
    }

    function _setApprovedTokenRegistry(address _dependency) external {
        vm.prank(deployer);
        market.setApprovedTokenRegistry(_dependency);
    }

    function _setStakingSettings(address _dependency) external {
        vm.prank(deployer);
        market.setStakingSettings(_dependency);
    }

    function _setStakingRegistry(address _dependency) external {
        vm.prank(deployer);
        market.setStakingRegistry(_dependency);
    }

    function _setERC20ApprovalManager(address _dependency) external {
        vm.prank(deployer);
        market.setERC20ApprovalManager(_dependency);
    }

    function _setERC721ApprovalManager(address _dependency) external {
        vm.prank(deployer);
        market.setERC721ApprovalManager(_dependency);
    }

    function _setERC1155ApprovalManager(address _dependency) external {
        vm.prank(deployer);
        market.setERC1155ApprovalManager(_dependency);
    }

    function _prepareDirectSale(address _currencyAddress, uint256 _price, uint256 _startTime, uint256 _maxMints)
        internal
    {
        _prepareDirectSaleForToken(tokenId, _currencyAddress, _price, _startTime, _maxMints);
    }

    function _prepareDirectSaleForToken(
        uint256 _tokenId,
        address _currencyAddress,
        uint256 _price,
        uint256 _startTime,
        uint256 _maxMints
    ) internal {
        address payable[] memory splitRecipients = new address payable[](1);
        uint8[] memory splitRatios = new uint8[](1);
        splitRecipients[0] = payable(seller);
        splitRatios[0] = 100;

        _prepareDirectSaleWithSplitsForToken(
            _tokenId, _currencyAddress, _price, _startTime, _maxMints, splitRecipients, splitRatios
        );
    }

    function _prepareDirectSaleWithSplits(
        address _currencyAddress,
        uint256 _price,
        uint256 _startTime,
        uint256 _maxMints,
        address payable[] memory _splitRecipients,
        uint8[] memory _splitRatios
    ) internal {
        _prepareDirectSaleWithSplitsForToken(
            tokenId, _currencyAddress, _price, _startTime, _maxMints, _splitRecipients, _splitRatios
        );
    }

    function _prepareDirectSaleWithSplitsForToken(
        uint256 _tokenId,
        address _currencyAddress,
        uint256 _price,
        uint256 _startTime,
        uint256 _maxMints,
        address payable[] memory _splitRecipients,
        uint8[] memory _splitRatios
    ) internal {
        vm.prank(seller);
        market.prepareMintDirectSale(
            address(token), _tokenId, _currencyAddress, _price, _startTime, _maxMints, _splitRecipients, _splitRatios
        );
    }

    function _mintToSellerAndList(address _currencyAddress, uint256 _price, uint256 _quantity) internal {
        vm.prank(seller);
        token.mintTo(seller, tokenId, _quantity);

        vm.prank(seller);
        token.setApprovalForAll(address(erc1155ApprovalManager), true);

        if (_currencyAddress != address(0)) {
            _mockApprovedCurrency(true);
        }

        address payable[] memory splitRecipients = new address payable[](1);
        uint8[] memory splitRatios = new uint8[](1);
        splitRecipients[0] = payable(seller);
        splitRatios[0] = 100;

        vm.prank(seller);
        market.setSalePrice(address(token), tokenId, _currencyAddress, _price, _quantity, splitRecipients, splitRatios);
    }

    function _mockApprovedCurrency(bool _approved) internal {
        vm.mockCall(
            approvedTokenRegistry,
            abi.encodeWithSelector(IApprovedTokenRegistry.isApprovedToken.selector, address(currency)),
            abi.encode(_approved)
        );
    }

    function _mockPrimaryPayout(uint256 _amount, address _seller) internal {
        _mockMarketplaceFee(_amount, _seller);
        vm.mockCall(
            spaceOperatorRegistry,
            abi.encodeWithSelector(ISpaceOperatorRegistry.isApprovedSpaceOperator.selector, _seller),
            abi.encode(false)
        );
        vm.mockCall(
            marketplaceSettings,
            abi.encodeWithSelector(
                IMarketplaceSettings.getERC721ContractPrimarySaleFeePercentage.selector, address(token)
            ),
            abi.encode(15)
        );
    }

    function _mockSecondaryPayout(uint256 _amount, address _seller) internal {
        _mockSecondaryPayoutFor(address(token), tokenId, _amount, _seller);
    }

    function _mockSecondaryPayoutFor(address _contractAddress, uint256 _tokenId, uint256 _amount, address _seller)
        internal
    {
        _mockMarketplaceFee(_amount, _seller);

        address payable[] memory receivers = new address payable[](1);
        uint256[] memory royalties = new uint256[](1);
        receivers[0] = payable(royaltyReceiver);
        royalties[0] = (_amount * 10) / 100;

        vm.mockCall(
            royaltyEngine,
            abi.encodeWithSelector(IRoyaltyEngineV1.getRoyalty.selector, _contractAddress, _tokenId, _amount),
            abi.encode(receivers, royalties)
        );
    }

    function _mockMarketplaceFee(uint256 _amount, address _seller) internal {
        vm.mockCall(
            marketplaceSettings,
            abi.encodeWithSelector(IMarketplaceSettings.calculateMarketplaceFee.selector, _amount),
            abi.encode((_amount * 3) / 100)
        );
        vm.mockCall(
            stakingRegistry,
            abi.encodeWithSelector(IRareStakingRegistry.getRewardAccumulatorAddressForUser.selector, _seller),
            abi.encode(rewardAccumulator)
        );
        vm.mockCall(
            stakingSettings,
            abi.encodeWithSelector(IStakingSettings.calculateStakingFee.selector, _amount),
            abi.encode((_amount * 1) / 100)
        );
    }

    function _mockInconsistentMarketplaceFee(uint256 _amount, address _seller) internal {
        vm.mockCall(
            marketplaceSettings,
            abi.encodeWithSelector(IMarketplaceSettings.calculateMarketplaceFee.selector, _amount),
            abi.encode((_amount * 3) / 100)
        );
        vm.mockCall(
            stakingRegistry,
            abi.encodeWithSelector(IRareStakingRegistry.getRewardAccumulatorAddressForUser.selector, _seller),
            abi.encode(rewardAccumulator)
        );
        vm.mockCall(
            stakingSettings,
            abi.encodeWithSelector(IStakingSettings.calculateMarketplacePayoutFee.selector, _amount),
            abi.encode((_amount * 1) / 100)
        );
        vm.mockCall(
            stakingSettings,
            abi.encodeWithSelector(IStakingSettings.calculateStakingFee.selector, _amount),
            abi.encode((_amount * 1) / 100)
        );
    }
}
