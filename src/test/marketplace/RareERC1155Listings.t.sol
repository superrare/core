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
import {RareERC1155Listings} from "../../marketplace/RareERC1155Listings.sol";
import {IRareERC1155Listings} from "../../marketplace/IRareERC1155Listings.sol";
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

contract RareERC1155ListingsTest is Test {
    event MarketplaceDependencyUpdated(bytes32 indexed field, address indexed dependency);
    event ContractPausedUpdated(bool isPaused);
    event SalePriceSet(
        address indexed seller,
        address indexed contractAddress,
        uint256 indexed tokenId,
        address currency,
        uint256 price,
        uint256 quantity,
        uint256 expirationTime,
        address payable[] splitRecipients,
        uint8[] splitRatios
    );

    RareERC1155Listings private market;
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

        RareERC1155Listings implementation = new RareERC1155Listings();
        market = RareERC1155Listings(address(new ERC1967Proxy(address(implementation), "")));
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
        tokenId = token.createToken("ipfs://token/1.json", 20);

        vm.etch(marketplaceSettings, address(market).code);
        vm.etch(stakingSettings, address(market).code);
        vm.etch(stakingRegistry, address(market).code);
        vm.etch(royaltyEngine, address(market).code);
        vm.etch(spaceOperatorRegistry, address(market).code);
        vm.etch(approvedTokenRegistry, address(market).code);
    }

    function testImplementationCannotBeInitialized() public {
        RareERC1155Listings directImplementation = new RareERC1155Listings();
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

    function testMaxBatchSize() public {
        assertEq(market.MAX_BATCH_SIZE(), 100);
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
        _mintDirectSale(tokenId, address(currency), price, quantity, emptyProof, 0);

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
        _mintDirectSale(tokenId, address(currency), price, 1, emptyProof, 0);

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
        _mintDirectSale(tokenId, address(0), price, quantity, emptyProof, totalPrice + ((totalPrice * 3) / 100));

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
        _mintDirectSale(tokenId, address(0), 0, 3, emptyProof, 0);

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
        vm.expectRevert(abi.encodeWithSelector(IRareERC1155Listings.SplitRecipientCannotBeZero.selector, 0));
        market.prepareMintDirectSales(
            address(token),
            address(0),
            _singleDirectSaleRequest(tokenId, 1 ether, block.timestamp, 0),
            splitRecipients,
            splitRatios
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
        vm.expectRevert(abi.encodeWithSelector(IRareERC1155Listings.SplitRatioCannotBeZero.selector, 0));
        market.prepareMintDirectSales(
            address(token),
            address(0),
            _singleDirectSaleRequest(tokenId, 1 ether, block.timestamp, 0),
            splitRecipients,
            splitRatios
        );
    }

    function testMintDirectSaleRevertsAfterCollectionOwnershipChanges() public {
        uint256 price = 1 ether;
        _prepareDirectSale(address(0), price, block.timestamp, 0);

        vm.prank(seller);
        token.transferOwnership(nextOwner);

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(IRareERC1155Listings.NotContractOwner.selector, address(token), seller));
        _mintDirectSale(tokenId, address(0), price, 1, emptyProof, price + ((price * 3) / 100));

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
        _mintDirectSale(tokenId, address(0), price, 1, emptyProof, 104);

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
        vm.expectRevert(abi.encodeWithSelector(IRareERC1155Listings.StakingFeeExceedsMarketplaceFee.selector, 3, 4));
        _mintDirectSale(tokenId, address(0), price, 1, emptyProof, 104);

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
        vm.expectRevert(abi.encodeWithSelector(IRareERC1155Listings.PlatformCommissionExceeded.selector, 101, 100));
        _mintDirectSale(tokenId, address(0), price, 1, emptyProof, price + ((price * 3) / 100));

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
        vm.expectRevert(abi.encodeWithSelector(IRareERC1155Listings.PlatformCommissionExceeded.selector, 101, 100));
        _mintDirectSale(tokenId, address(0), price, 1, emptyProof, price + ((price * 3) / 100));

        assertEq(token.balanceOf(buyer, tokenId), 0);
        assertEq(address(market).balance, 0);
    }

    function testMintDirectSaleAllowListAndLimits() public {
        uint256 price = 1 ether;
        bytes32 root = keccak256(abi.encodePacked(buyer));

        _prepareDirectSale(address(0), price, block.timestamp, 2);

        vm.prank(seller);
        _setTokenAllowListConfig(tokenId, root, block.timestamp + 1 days);

        vm.prank(seller);
        _setTokenMintLimit(tokenId, 2);

        _mockPrimaryPayout(price * 2, seller);
        vm.prank(buyer);
        _mintDirectSale(tokenId, address(0), price, 2, emptyProof, (price * 2) + (((price * 2) * 3) / 100));

        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRareERC1155Listings.MintLimitExceeded.selector, address(token), tokenId, buyer, 1, 2, 2
            )
        );
        _mintDirectSale(tokenId, address(0), price, 1, emptyProof, price + ((price * 3) / 100));
    }

    function testMintDirectSaleAllowListRejectsNonMember() public {
        uint256 price = 1 ether;
        bytes32 root = keccak256(abi.encodePacked(address(0x9999)));

        _prepareDirectSale(address(0), price, block.timestamp, 0);

        vm.prank(seller);
        _setTokenAllowListConfig(tokenId, root, block.timestamp + 1 days);

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(IRareERC1155Listings.AddressNotAllowlisted.selector, buyer));
        _mintDirectSale(tokenId, address(0), price, 1, emptyProof, price + ((price * 3) / 100));
    }

    function testTokenScopedPrimaryConfigRevertsForUnknownTokenId() public {
        uint256 missingTokenId = tokenId + 1;
        bytes32 root = keccak256(abi.encodePacked(buyer));

        vm.startPrank(seller);
        vm.expectRevert(
            abi.encodeWithSelector(IRareERC1155Listings.TokenNotFound.selector, address(token), missingTokenId)
        );
        _setTokenAllowListConfig(missingTokenId, root, block.timestamp + 1 days);

        vm.expectRevert(
            abi.encodeWithSelector(IRareERC1155Listings.TokenNotFound.selector, address(token), missingTokenId)
        );
        _setTokenMintLimit(missingTokenId, 1);

        vm.expectRevert(
            abi.encodeWithSelector(IRareERC1155Listings.TokenNotFound.selector, address(token), missingTokenId)
        );
        _setTokenTxLimit(missingTokenId, 1);
        vm.stopPrank();
    }

    function testMintDirectSaleTxLimit() public {
        uint256 price = 1 ether;
        _prepareDirectSale(address(0), price, block.timestamp, 0);

        vm.prank(seller);
        _setTokenTxLimit(tokenId, 1);

        _mockPrimaryPayout(price, seller);
        vm.prank(buyer);
        _mintDirectSale(tokenId, address(0), price, 1, emptyProof, price + ((price * 3) / 100));

        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRareERC1155Listings.TransactionLimitExceeded.selector, address(token), tokenId, buyer, 1, 1
            )
        );
        _mintDirectSale(tokenId, address(0), price, 1, emptyProof, price + ((price * 3) / 100));
    }

    function testMintDirectSaleLimitsOnlyCountWhileEnabled() public {
        _prepareDirectSale(address(0), 0, block.timestamp, 0);

        vm.prank(buyer);
        _mintDirectSale(tokenId, address(0), 0, 2, emptyProof, 0);

        assertEq(market.getTokenMintsPerAddress(address(token), tokenId, buyer), 0);
        assertEq(market.getTokenTxsPerAddress(address(token), tokenId, buyer), 0);

        vm.startPrank(seller);
        _setTokenMintLimit(tokenId, 1);
        _setTokenTxLimit(tokenId, 1);
        vm.stopPrank();

        vm.prank(buyer);
        _mintDirectSale(tokenId, address(0), 0, 1, emptyProof, 0);

        assertEq(market.getTokenMintsPerAddress(address(token), tokenId, buyer), 1);
        assertEq(market.getTokenTxsPerAddress(address(token), tokenId, buyer), 1);

        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRareERC1155Listings.MintLimitExceeded.selector, address(token), tokenId, buyer, 1, 1, 1
            )
        );
        _mintDirectSale(tokenId, address(0), 0, 1, emptyProof, 0);
    }

    function testMintDirectSaleLimitsAreTokenScoped() public {
        uint256 otherTokenId;

        vm.prank(seller);
        otherTokenId = token.createToken("ipfs://token/2.json", 20);

        _prepareDirectSale(address(0), 0, block.timestamp, 0);
        _prepareDirectSaleForToken(otherTokenId, address(0), 0, block.timestamp, 0);

        vm.prank(seller);
        _setTokenMintLimit(tokenId, 1);

        vm.prank(buyer);
        _mintDirectSale(tokenId, address(0), 0, 1, emptyProof, 0);

        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRareERC1155Listings.MintLimitExceeded.selector, address(token), tokenId, buyer, 1, 1, 1
            )
        );
        _mintDirectSale(tokenId, address(0), 0, 1, emptyProof, 0);

        vm.prank(buyer);
        _mintDirectSale(otherTokenId, address(0), 0, 2, emptyProof, 0);

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
        vm.expectRevert(abi.encodeWithSelector(IRareERC1155Listings.SaleNotStarted.selector, block.timestamp + 1 hours));
        _mintDirectSale(tokenId, address(currency), price, 1, emptyProof, 0);

        skip(1 hours);

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(IRareERC1155Listings.PriceMismatch.selector, price + 1, price));
        _mintDirectSale(tokenId, address(currency), price + 1, 1, emptyProof, 0);

        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(IRareERC1155Listings.CurrencyMismatch.selector, address(0), address(currency))
        );
        _mintDirectSale(tokenId, address(0), price, 1, emptyProof, 0);
    }

    function testMintDirectSaleBatchRejectsBadBatchShape() public {
        IRareERC1155Listings.MintRequest[] memory emptyRequests = new IRareERC1155Listings.MintRequest[](0);

        vm.prank(buyer);
        vm.expectRevert(IRareERC1155Listings.EmptyBatch.selector);
        market.mintDirectSaleBatch(address(token), address(0), emptyRequests);

        bytes32[] memory proof = new bytes32[](0);
        IRareERC1155Listings.MintRequest[] memory requests = new IRareERC1155Listings.MintRequest[](2);
        requests[0] = IRareERC1155Listings.MintRequest(1, 0, 1, proof);
        requests[1] = IRareERC1155Listings.MintRequest(1, 0, 1, proof);

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(IRareERC1155Listings.TokenIdsNotStrictlyAscending.selector, 1, 1, 1));
        market.mintDirectSaleBatch(address(token), address(0), requests);

        requests[0] = IRareERC1155Listings.MintRequest(2, 0, 1, proof);
        requests[1] = IRareERC1155Listings.MintRequest(1, 0, 1, proof);

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(IRareERC1155Listings.TokenIdsNotStrictlyAscending.selector, 1, 2, 1));
        market.mintDirectSaleBatch(address(token), address(0), requests);
    }

    function testMintDirectSaleBatchRejectsOversizedBatch() public {
        bytes32[] memory proof = new bytes32[](0);
        IRareERC1155Listings.MintRequest[] memory requests = new IRareERC1155Listings.MintRequest[](101);

        for (uint256 i = 0; i < requests.length; i++) {
            requests[i] = IRareERC1155Listings.MintRequest(i + 1, 0, 1, proof);
        }

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(IRareERC1155Listings.BatchSizeExceeded.selector, 101, 100));
        market.mintDirectSaleBatch(address(token), address(0), requests);
    }

    function testMintDirectSaleBatchRejectsZeroQuantity() public {
        _prepareDirectSale(address(0), 0, block.timestamp, 0);

        vm.prank(buyer);
        vm.expectRevert(IRareERC1155Listings.QuantityCannotBeZero.selector);
        _mintDirectSale(tokenId, address(0), 0, 0, emptyProof, 0);
    }

    function testMintDirectSaleBatchAggregatesFreeAndPaidETHPayment() public {
        uint256 paidTokenId;
        uint256 price = 1 ether;

        vm.prank(seller);
        paidTokenId = token.createToken("ipfs://token/2.json", 20);

        _prepareDirectSale(address(0), 0, block.timestamp, 0);
        _prepareDirectSaleForToken(paidTokenId, address(0), price, block.timestamp, 0);
        _mockPrimaryPayout(price, seller);

        IRareERC1155Listings.MintRequest[] memory requests = new IRareERC1155Listings.MintRequest[](2);
        bytes32[] memory proof = new bytes32[](0);
        requests[0] = IRareERC1155Listings.MintRequest(tokenId, 0, 2, proof);
        requests[1] = IRareERC1155Listings.MintRequest(paidTokenId, price, 1, proof);

        vm.prank(buyer);
        market.mintDirectSaleBatch{value: price + ((price * 3) / 100)}(address(token), address(0), requests);

        assertEq(token.balanceOf(buyer, tokenId), 2);
        assertEq(token.balanceOf(buyer, paidTokenId), 1);
    }

    function testMintDirectSaleBatchRejectsValueForAllFreeBatch() public {
        _prepareDirectSale(address(0), 0, block.timestamp, 0);

        vm.prank(buyer);
        vm.expectRevert(IRareERC1155Listings.MsgValueMustBeZero.selector);
        _mintDirectSale(tokenId, address(0), 0, 1, emptyProof, 1);
    }

    function testMintDirectSaleBatchRejectsMsgValueForERC20Batch() public {
        uint256 price = 1 ether;
        _mockApprovedCurrency(true);
        _prepareDirectSale(address(currency), price, block.timestamp, 0);
        _mockMarketplaceFee(price, seller);

        vm.prank(buyer);
        vm.expectRevert(IRareERC1155Listings.MsgValueUnsupportedForERC20.selector);
        _mintDirectSale(tokenId, address(currency), price, 1, emptyProof, 1);
    }

    function testMintDirectSaleBatchCalculatesFeesPerItem() public {
        uint256 otherTokenId;
        uint256 price = 33;

        vm.prank(seller);
        otherTokenId = token.createToken("ipfs://token/2.json", 20);

        _prepareDirectSale(address(0), price, block.timestamp, 0);
        _prepareDirectSaleForToken(otherTokenId, address(0), price, block.timestamp, 0);
        _mockPrimaryPayout(price, seller);

        IRareERC1155Listings.MintRequest[] memory requests = new IRareERC1155Listings.MintRequest[](2);
        bytes32[] memory proof = new bytes32[](0);
        requests[0] = IRareERC1155Listings.MintRequest(tokenId, price, 1, proof);
        requests[1] = IRareERC1155Listings.MintRequest(otherTokenId, price, 1, proof);

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(IRareERC1155Listings.IncorrectETHAmount.selector, 66, 67));
        market.mintDirectSaleBatch{value: 67}(address(token), address(0), requests);

        vm.prank(buyer);
        market.mintDirectSaleBatch{value: 66}(address(token), address(0), requests);

        assertEq(token.balanceOf(buyer, tokenId), 1);
        assertEq(token.balanceOf(buyer, otherTokenId), 1);
        assertEq(address(market).balance, 0);
    }

    function testMintDirectSaleBatchCountsOneTxPerTokenId() public {
        uint256 otherTokenId;

        vm.prank(seller);
        otherTokenId = token.createToken("ipfs://token/2.json", 20);

        _prepareDirectSale(address(0), 0, block.timestamp, 0);
        _prepareDirectSaleForToken(otherTokenId, address(0), 0, block.timestamp, 0);

        vm.startPrank(seller);
        _setTokenTxLimit(tokenId, 1);
        _setTokenTxLimit(otherTokenId, 1);
        vm.stopPrank();

        IRareERC1155Listings.MintRequest[] memory requests = new IRareERC1155Listings.MintRequest[](2);
        bytes32[] memory proof = new bytes32[](0);
        requests[0] = IRareERC1155Listings.MintRequest(tokenId, 0, 1, proof);
        requests[1] = IRareERC1155Listings.MintRequest(otherTokenId, 0, 2, proof);

        vm.prank(buyer);
        market.mintDirectSaleBatch(address(token), address(0), requests);

        assertEq(market.getTokenTxsPerAddress(address(token), tokenId, buyer), 1);
        assertEq(market.getTokenTxsPerAddress(address(token), otherTokenId, buyer), 1);
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
        _buy(address(token), tokenId, seller, address(currency), price, quantity, 0);

        assertEq(token.balanceOf(buyer, tokenId), quantity);
        assertEq(currency.balanceOf(seller) - sellerBalanceBefore, (totalPrice * 90) / 100);
        assertEq(currency.balanceOf(royaltyReceiver) - royaltyBalanceBefore, (totalPrice * 10) / 100);
        assertEq(currency.balanceOf(networkBeneficiary) - networkBalanceBefore, (totalPrice * 2) / 100);
        assertEq(currency.balanceOf(rewardAccumulator) - rewardBalanceBefore, (totalPrice * 1) / 100);

        IRareERC1155Listings.SalePrice memory salePrice = market.getSalePrice(address(token), tokenId, seller);
        assertEq(salePrice.quantity, 2);
    }

    function testNoExpirySalePriceRemainsBuyableAfterTimePasses() public {
        uint256 price = 1 ether;

        _mintToSellerAndList(address(0), price, 1);
        vm.warp(block.timestamp + 30 days);
        _mockSecondaryPayout(price, seller);

        vm.prank(buyer);
        _buy(address(token), tokenId, seller, address(0), price, 1, price + ((price * 3) / 100));

        assertEq(token.balanceOf(buyer, tokenId), 1);
    }

    function testSetSalePriceStoresAndEmitsExpiration() public {
        uint256 price = 1 ether;
        uint256 quantity = 2;
        uint256 expirationTime = block.timestamp + 1 days;

        vm.prank(seller);
        token.mintBatchTo(seller, _singleTokenIds(tokenId), _singleAmounts(quantity));

        vm.prank(seller);
        token.setApprovalForAll(address(erc1155ApprovalManager), true);

        address payable[] memory splitRecipients = new address payable[](1);
        uint8[] memory splitRatios = new uint8[](1);
        splitRecipients[0] = payable(seller);
        splitRatios[0] = 100;

        vm.prank(seller);
        vm.expectEmit(true, true, true, true, address(market));
        emit SalePriceSet(
            seller, address(token), tokenId, address(0), price, quantity, expirationTime, splitRecipients, splitRatios
        );
        market.setSalePrices(
            address(token),
            address(0),
            _singleSalePriceRequest(tokenId, price, quantity, expirationTime),
            splitRecipients,
            splitRatios
        );

        IRareERC1155Listings.SalePrice memory salePrice = market.getSalePrice(address(token), tokenId, seller);
        assertEq(salePrice.expirationTime, expirationTime);
    }

    function testBuyBeforeExpirationPreservesExpirationOnPartialFill() public {
        uint256 price = 1 ether;
        uint256 expirationTime = block.timestamp + 1 days;

        _mintToSellerAndListWithExpiration(address(0), price, 3, expirationTime);
        _mockSecondaryPayout(price, seller);

        vm.prank(buyer);
        _buy(address(token), tokenId, seller, address(0), price, 1, price + ((price * 3) / 100));

        IRareERC1155Listings.SalePrice memory salePrice = market.getSalePrice(address(token), tokenId, seller);
        assertEq(salePrice.quantity, 2);
        assertEq(salePrice.expirationTime, expirationTime);
    }

    function testBuyAtExpirationRevertsAndLeavesListingReadable() public {
        uint256 price = 1 ether;
        uint256 expirationTime = block.timestamp + 1 days;

        _mintToSellerAndListWithExpiration(address(0), price, 2, expirationTime);
        vm.warp(expirationTime);

        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRareERC1155Listings.SalePriceExpired.selector, address(token), tokenId, seller, expirationTime
            )
        );
        _buy(address(token), tokenId, seller, address(0), price, 1, price + ((price * 3) / 100));

        IRareERC1155Listings.SalePrice memory salePrice = market.getSalePrice(address(token), tokenId, seller);
        assertEq(salePrice.quantity, 2);
        assertEq(salePrice.expirationTime, expirationTime);
    }

    function testSetSalePriceRevertsForCurrentOrPastExpiration() public {
        uint256 price = 1 ether;
        vm.warp(100);

        vm.prank(seller);
        token.setApprovalForAll(address(erc1155ApprovalManager), true);

        address payable[] memory splitRecipients = new address payable[](1);
        uint8[] memory splitRatios = new uint8[](1);
        splitRecipients[0] = payable(seller);
        splitRatios[0] = 100;

        vm.prank(seller);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRareERC1155Listings.SalePriceExpirationInvalid.selector, block.timestamp, block.timestamp
            )
        );
        _setSalePriceWithExpiration(
            address(token), tokenId, address(0), price, 1, block.timestamp, splitRecipients, splitRatios
        );

        vm.prank(seller);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRareERC1155Listings.SalePriceExpirationInvalid.selector, block.timestamp - 1, block.timestamp
            )
        );
        _setSalePriceWithExpiration(
            address(token), tokenId, address(0), price, 1, block.timestamp - 1, splitRecipients, splitRatios
        );
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
        vm.expectRevert(abi.encodeWithSelector(IRareERC1155Listings.PayoutLengthMismatch.selector, 1, 2));
        _buy(address(token), tokenId, seller, address(0), price, 1, price + ((price * 3) / 100));

        assertEq(token.balanceOf(buyer, tokenId), 0);
        assertEq(token.balanceOf(seller, tokenId), 1);
        assertEq(address(market).balance, 0);
    }

    function testBuyRemainingQuantityClearsSalePrice() public {
        uint256 price = 1 ether;
        uint256 quantity = 2;
        uint256 totalPrice = price * quantity;
        uint256 expirationTime = block.timestamp + 1 days;

        _mintToSellerAndListWithExpiration(address(0), price, quantity, expirationTime);
        _mockSecondaryPayout(totalPrice, seller);

        vm.prank(buyer);
        _buy(address(token), tokenId, seller, address(0), price, quantity, totalPrice + ((totalPrice * 3) / 100));

        IRareERC1155Listings.SalePrice memory salePrice = market.getSalePrice(address(token), tokenId, seller);
        assertEq(salePrice.quantity, 0);
        assertEq(salePrice.expirationTime, 0);
    }

    function testBuyBatchPartialAndFinalFillUpdatesListingsAndBalances() public {
        uint256 otherTokenId;
        uint256 price = 1 ether;

        vm.prank(seller);
        otherTokenId = token.createToken("ipfs://token/2.json", 20);

        uint256[] memory tokenIds = new uint256[](2);
        uint256[] memory mintAmounts = new uint256[](2);
        tokenIds[0] = tokenId;
        tokenIds[1] = otherTokenId;
        mintAmounts[0] = 5;
        mintAmounts[1] = 5;

        vm.prank(seller);
        token.mintBatchTo(seller, tokenIds, mintAmounts);

        vm.prank(seller);
        token.setApprovalForAll(address(erc1155ApprovalManager), true);

        address payable[] memory splitRecipients = new address payable[](1);
        uint8[] memory splitRatios = new uint8[](1);
        splitRecipients[0] = payable(seller);
        splitRatios[0] = 100;

        IRareERC1155Listings.SalePriceRequest[] memory saleRequests = new IRareERC1155Listings.SalePriceRequest[](2);
        saleRequests[0] = IRareERC1155Listings.SalePriceRequest(tokenId, price, 5, 0);
        saleRequests[1] = IRareERC1155Listings.SalePriceRequest(otherTokenId, price, 5, 0);

        vm.prank(seller);
        market.setSalePrices(address(token), address(0), saleRequests, splitRecipients, splitRatios);

        IRareERC1155Listings.BuyRequest[] memory buyRequests = new IRareERC1155Listings.BuyRequest[](2);
        buyRequests[0] = IRareERC1155Listings.BuyRequest(tokenId, price, 2);
        buyRequests[1] = IRareERC1155Listings.BuyRequest(otherTokenId, price, 3);

        _mockSecondaryPayoutFor(address(token), tokenId, 2 ether, seller);
        _mockSecondaryPayoutFor(address(token), otherTokenId, 3 ether, seller);

        vm.prank(buyer);
        market.buyBatch{value: 5 ether + ((2 ether * 3) / 100) + ((3 ether * 3) / 100)}(
            address(token), seller, address(0), buyRequests
        );

        assertEq(token.balanceOf(seller, tokenId), 3);
        assertEq(token.balanceOf(seller, otherTokenId), 2);
        assertEq(token.balanceOf(buyer, tokenId), 2);
        assertEq(token.balanceOf(buyer, otherTokenId), 3);
        assertEq(market.getSalePrice(address(token), tokenId, seller).quantity, 3);
        assertEq(market.getSalePrice(address(token), otherTokenId, seller).quantity, 2);

        buyRequests[0] = IRareERC1155Listings.BuyRequest(tokenId, price, 3);
        buyRequests[1] = IRareERC1155Listings.BuyRequest(otherTokenId, price, 2);

        _mockSecondaryPayoutFor(address(token), tokenId, 3 ether, seller);
        _mockSecondaryPayoutFor(address(token), otherTokenId, 2 ether, seller);

        vm.prank(buyer);
        market.buyBatch{value: 5 ether + ((3 ether * 3) / 100) + ((2 ether * 3) / 100)}(
            address(token), seller, address(0), buyRequests
        );

        assertEq(token.balanceOf(seller, tokenId), 0);
        assertEq(token.balanceOf(seller, otherTokenId), 0);
        assertEq(token.balanceOf(buyer, tokenId), 5);
        assertEq(token.balanceOf(buyer, otherTokenId), 5);
        assertEq(market.getSalePrice(address(token), tokenId, seller).quantity, 0);
        assertEq(market.getSalePrice(address(token), otherTokenId, seller).quantity, 0);
    }

    function testBuyBatchRejectsBadBatchShape() public {
        IRareERC1155Listings.BuyRequest[] memory emptyRequests = new IRareERC1155Listings.BuyRequest[](0);

        vm.prank(buyer);
        vm.expectRevert(IRareERC1155Listings.EmptyBatch.selector);
        market.buyBatch(address(token), seller, address(0), emptyRequests);

        IRareERC1155Listings.BuyRequest[] memory requests = new IRareERC1155Listings.BuyRequest[](2);
        requests[0] = IRareERC1155Listings.BuyRequest(1, 1 ether, 1);
        requests[1] = IRareERC1155Listings.BuyRequest(1, 1 ether, 1);

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(IRareERC1155Listings.TokenIdsNotStrictlyAscending.selector, 1, 1, 1));
        market.buyBatch(address(token), seller, address(0), requests);

        requests[0] = IRareERC1155Listings.BuyRequest(2, 1 ether, 1);
        requests[1] = IRareERC1155Listings.BuyRequest(1, 1 ether, 1);

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(IRareERC1155Listings.TokenIdsNotStrictlyAscending.selector, 1, 2, 1));
        market.buyBatch(address(token), seller, address(0), requests);
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
        _setSalePrice(address(openToken), openTokenId, address(0), price, quantity, splitRecipients, splitRatios);

        _mockSecondaryPayoutFor(address(openToken), openTokenId, totalPrice, seller);

        vm.prank(buyer);
        _buy(
            address(openToken), openTokenId, seller, address(0), price, quantity, totalPrice + ((totalPrice * 3) / 100)
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
            abi.encodeWithSelector(IRareERC1155Listings.MarketplaceNotApproved.selector, seller, address(token))
        );
        _buy(address(token), tokenId, seller, address(0), price, 1, price + ((price * 3) / 100));

        vm.prank(seller);
        token.setApprovalForAll(address(erc1155ApprovalManager), true);

        vm.prank(seller);
        token.safeTransferFrom(seller, address(0x9999), tokenId, 2, "");

        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRareERC1155Listings.InsufficientTokenBalance.selector, seller, address(token), tokenId, 1, 0
            )
        );
        _buy(address(token), tokenId, seller, address(0), price, 1, price + ((price * 3) / 100));
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
            abi.encodeWithSelector(IRareERC1155Listings.InvalidERC1155Contract.selector, address(nonERC1155))
        );
        _setSalePrice(address(nonERC1155), unsupportedTokenId, address(0), 1 ether, 1, splitRecipients, splitRatios);
    }

    function testSetSalePriceRevertsForZeroSplitRecipient() public {
        address payable[] memory splitRecipients = new address payable[](2);
        uint8[] memory splitRatios = new uint8[](2);
        splitRecipients[0] = payable(seller);
        splitRecipients[1] = payable(address(0));
        splitRatios[0] = 50;
        splitRatios[1] = 50;

        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(IRareERC1155Listings.SplitRecipientCannotBeZero.selector, 1));
        _setSalePrice(address(token), tokenId, address(0), 1 ether, 1, splitRecipients, splitRatios);
    }

    function testSetSalePriceRevertsForZeroSplitRatio() public {
        address payable[] memory splitRecipients = new address payable[](2);
        uint8[] memory splitRatios = new uint8[](2);
        splitRecipients[0] = payable(seller);
        splitRecipients[1] = splitRecipientA;
        splitRatios[0] = 100;
        splitRatios[1] = 0;

        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(IRareERC1155Listings.SplitRatioCannotBeZero.selector, 1));
        _setSalePrice(address(token), tokenId, address(0), 1 ether, 1, splitRecipients, splitRatios);
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
        _setSalePrice(address(brokenToken), brokenTokenId, address(0), price, 1, splitRecipients, splitRatios);

        _mockMarketplaceFee(price, seller);

        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRareERC1155Listings.InvalidERC1155Transfer.selector,
                address(brokenToken),
                brokenTokenId,
                seller,
                buyer,
                1
            )
        );
        _buy(address(brokenToken), brokenTokenId, seller, address(0), price, 1, price + ((price * 3) / 100));

        assertEq(brokenToken.balanceOf(seller, brokenTokenId), 1);
        assertEq(brokenToken.balanceOf(buyer, brokenTokenId), 0);
    }

    function testBuyRevertsForSelfPurchase() public {
        uint256 price = 1 ether;

        _mintToSellerAndList(address(0), price, 1);

        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(IRareERC1155Listings.SelfPurchaseUnsupported.selector, seller));
        _buy(address(token), tokenId, seller, address(0), price, 1, price + ((price * 3) / 100));
    }

    function testCancelSalePrice() public {
        _mintToSellerAndList(address(0), 1 ether, 2);

        vm.prank(seller);
        market.cancelSalePrices(address(token), _singleTokenIds(tokenId));

        IRareERC1155Listings.SalePrice memory salePrice = market.getSalePrice(address(token), tokenId, seller);
        assertEq(salePrice.quantity, 0);
    }

    function testCancelSalePriceAllowedWhilePaused() public {
        _mintToSellerAndList(address(0), 1 ether, 2);

        vm.prank(deployer);
        market.setContractPaused(true);

        vm.prank(seller);
        market.cancelSalePrices(address(token), _singleTokenIds(tokenId));

        IRareERC1155Listings.SalePrice memory salePrice = market.getSalePrice(address(token), tokenId, seller);
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
        vm.expectRevert(IRareERC1155Listings.ContractPaused.selector);
        _setSalePrice(address(token), tokenId, address(0), 1 ether, 1, splitRecipients, splitRatios);
    }

    function testBuyRevertsWhilePaused() public {
        uint256 price = 1 ether;
        _mintToSellerAndList(address(0), price, 2);

        vm.prank(deployer);
        market.setContractPaused(true);

        vm.prank(buyer);
        vm.expectRevert(IRareERC1155Listings.ContractPaused.selector);
        _buy(address(token), tokenId, seller, address(0), price, 1, price + ((price * 3) / 100));
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
        market.prepareMintDirectSales(
            address(token),
            _currencyAddress,
            _singleDirectSaleRequest(_tokenId, _price, _startTime, _maxMints),
            _splitRecipients,
            _splitRatios
        );
    }

    function _mintToSellerAndList(address _currencyAddress, uint256 _price, uint256 _quantity) internal {
        _mintToSellerAndListWithExpiration(_currencyAddress, _price, _quantity, 0);
    }

    function _mintToSellerAndListWithExpiration(
        address _currencyAddress,
        uint256 _price,
        uint256 _quantity,
        uint256 _expirationTime
    ) internal {
        vm.prank(seller);
        token.mintBatchTo(seller, _singleTokenIds(tokenId), _singleAmounts(_quantity));

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
        market.setSalePrices(
            address(token),
            _currencyAddress,
            _singleSalePriceRequest(tokenId, _price, _quantity, _expirationTime),
            splitRecipients,
            splitRatios
        );
    }

    function _mintDirectSale(
        uint256 _tokenId,
        address _currencyAddress,
        uint256 _price,
        uint256 _quantity,
        bytes32[] memory _proof,
        uint256 _value
    ) internal {
        market.mintDirectSaleBatch{value: _value}(
            address(token), _currencyAddress, _singleMintRequest(_tokenId, _price, _quantity, _proof)
        );
    }

    function _setTokenAllowListConfig(uint256 _tokenId, bytes32 _root, uint256 _endTimestamp) internal {
        market.setTokenAllowListConfigs(address(token), _singleAllowListConfigRequest(_tokenId, _root, _endTimestamp));
    }

    function _setTokenMintLimit(uint256 _tokenId, uint256 _limit) internal {
        market.setTokenMintLimits(address(token), _singleTokenLimitRequest(_tokenId, _limit));
    }

    function _setTokenTxLimit(uint256 _tokenId, uint256 _limit) internal {
        market.setTokenTxLimits(address(token), _singleTokenLimitRequest(_tokenId, _limit));
    }

    function _setSalePrice(
        address _contractAddress,
        uint256 _tokenId,
        address _currencyAddress,
        uint256 _price,
        uint256 _quantity,
        address payable[] memory _splitRecipients,
        uint8[] memory _splitRatios
    ) internal {
        _setSalePriceWithExpiration(
            _contractAddress, _tokenId, _currencyAddress, _price, _quantity, 0, _splitRecipients, _splitRatios
        );
    }

    function _setSalePriceWithExpiration(
        address _contractAddress,
        uint256 _tokenId,
        address _currencyAddress,
        uint256 _price,
        uint256 _quantity,
        uint256 _expirationTime,
        address payable[] memory _splitRecipients,
        uint8[] memory _splitRatios
    ) internal {
        market.setSalePrices(
            _contractAddress,
            _currencyAddress,
            _singleSalePriceRequest(_tokenId, _price, _quantity, _expirationTime),
            _splitRecipients,
            _splitRatios
        );
    }

    function _buy(
        address _contractAddress,
        uint256 _tokenId,
        address _seller,
        address _currencyAddress,
        uint256 _price,
        uint256 _quantity,
        uint256 _value
    ) internal {
        market.buyBatch{value: _value}(
            _contractAddress, _seller, _currencyAddress, _singleBuyRequest(_tokenId, _price, _quantity)
        );
    }

    function _singleDirectSaleRequest(uint256 _tokenId, uint256 _price, uint256 _startTime, uint256 _maxMints)
        internal
        pure
        returns (IRareERC1155Listings.DirectSaleRequest[] memory)
    {
        IRareERC1155Listings.DirectSaleRequest[] memory requests = new IRareERC1155Listings.DirectSaleRequest[](1);
        requests[0] = IRareERC1155Listings.DirectSaleRequest(_tokenId, _price, _startTime, _maxMints);
        return requests;
    }

    function _singleMintRequest(uint256 _tokenId, uint256 _price, uint256 _quantity, bytes32[] memory _proof)
        internal
        pure
        returns (IRareERC1155Listings.MintRequest[] memory)
    {
        IRareERC1155Listings.MintRequest[] memory requests = new IRareERC1155Listings.MintRequest[](1);
        requests[0] = IRareERC1155Listings.MintRequest(_tokenId, _price, _quantity, _proof);
        return requests;
    }

    function _singleAllowListConfigRequest(uint256 _tokenId, bytes32 _root, uint256 _endTimestamp)
        internal
        pure
        returns (IRareERC1155Listings.AllowListConfigRequest[] memory)
    {
        IRareERC1155Listings.AllowListConfigRequest[] memory requests =
            new IRareERC1155Listings.AllowListConfigRequest[](1);
        requests[0] = IRareERC1155Listings.AllowListConfigRequest(_tokenId, _root, _endTimestamp);
        return requests;
    }

    function _singleTokenLimitRequest(uint256 _tokenId, uint256 _limit)
        internal
        pure
        returns (IRareERC1155Listings.TokenLimitRequest[] memory)
    {
        IRareERC1155Listings.TokenLimitRequest[] memory requests = new IRareERC1155Listings.TokenLimitRequest[](1);
        requests[0] = IRareERC1155Listings.TokenLimitRequest(_tokenId, _limit);
        return requests;
    }

    function _singleSalePriceRequest(uint256 _tokenId, uint256 _price, uint256 _quantity)
        internal
        pure
        returns (IRareERC1155Listings.SalePriceRequest[] memory)
    {
        return _singleSalePriceRequest(_tokenId, _price, _quantity, 0);
    }

    function _singleSalePriceRequest(uint256 _tokenId, uint256 _price, uint256 _quantity, uint256 _expirationTime)
        internal
        pure
        returns (IRareERC1155Listings.SalePriceRequest[] memory)
    {
        IRareERC1155Listings.SalePriceRequest[] memory requests = new IRareERC1155Listings.SalePriceRequest[](1);
        requests[0] = IRareERC1155Listings.SalePriceRequest(_tokenId, _price, _quantity, _expirationTime);
        return requests;
    }

    function _singleBuyRequest(uint256 _tokenId, uint256 _price, uint256 _quantity)
        internal
        pure
        returns (IRareERC1155Listings.BuyRequest[] memory)
    {
        IRareERC1155Listings.BuyRequest[] memory requests = new IRareERC1155Listings.BuyRequest[](1);
        requests[0] = IRareERC1155Listings.BuyRequest(_tokenId, _price, _quantity);
        return requests;
    }

    function _singleTokenIds(uint256 _tokenId) internal pure returns (uint256[] memory) {
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = _tokenId;
        return tokenIds;
    }

    function _singleAmounts(uint256 _amount) internal pure returns (uint256[] memory) {
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = _amount;
        return amounts;
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
