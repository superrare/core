// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import {ERC20} from "openzeppelin-contracts/token/ERC20/ERC20.sol";
import {IERC1155} from "openzeppelin-contracts/token/ERC1155/IERC1155.sol";
import {IERC165} from "openzeppelin-contracts/utils/introspection/IERC165.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {IApprovedTokenRegistry} from "../../registry/interfaces/IApprovedTokenRegistry.sol";
import {IMarketplaceSettings} from "../../marketplace/IMarketplaceSettings.sol";
import {IStakingSettings} from "../../marketplace/IStakingSettings.sol";
import {IRareStakingRegistry} from "../../staking/registry/IRareStakingRegistry.sol";
import {Payments} from "../../payments/Payments.sol";
import {RareERC1155} from "../../token/ERC1155/RareERC1155.sol";
import {RareERC1155ContractFactory} from "../../token/ERC1155/RareERC1155ContractFactory.sol";
import {ERC20ApprovalManager} from "../../v2/approver/ERC20/ERC20ApprovalManager.sol";
import {ERC721ApprovalManager} from "../../v2/approver/ERC721/ERC721ApprovalManager.sol";
import {ERC1155ApprovalManager} from "../../v2/approver/ERC1155/ERC1155ApprovalManager.sol";
import {IRareERC1155MarketplaceTypes} from "../../marketplace/IRareERC1155MarketplaceTypes.sol";
import {RareERC1155Marketplace} from "../../marketplace/RareERC1155Marketplace.sol";
import {RareERC1155Settlement} from "../../marketplace/RareERC1155Settlement.sol";
import {IRoyaltyEngineV1} from "royalty-registry/IRoyaltyEngineV1.sol";

contract CheckoutCurrency is ERC20 {
    constructor() ERC20("Checkout Currency", "CCUR") {
        _mint(msg.sender, 1_000_000_000 ether);
    }
}

contract CheckoutNoOpERC1155 is IERC1155 {
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

contract RareERC1155MarketplaceSettlementTest is Test {
    RareERC1155Marketplace private marketplace;
    RareERC1155Settlement private settlement;
    RareERC1155 private token;
    CheckoutCurrency private currency;
    RareERC1155ContractFactory private tokenFactory;
    ERC20ApprovalManager private erc20ApprovalManager;
    ERC721ApprovalManager private erc721ApprovalManager;
    ERC1155ApprovalManager private erc1155ApprovalManager;

    address private deployer = address(0x1000);
    address private seller = address(0x2000);
    address private sellerTwo = address(0x2500);
    address private buyer = address(0x3000);
    address private royaltyReceiver = address(0x4000);
    address private networkBeneficiary = address(0x5000);
    address private rewardAccumulator = address(0x6000);

    address private marketplaceSettings = address(0x7100);
    address private stakingSettings = address(0x7200);
    address private stakingRegistry = address(0x7300);
    address private royaltyEngine = address(0x7400);
    address private spaceOperatorRegistry = address(0x7500);
    address private approvedTokenRegistry = address(0x7600);

    uint256 private tokenId;

    function setUp() public {
        deal(deployer, 100 ether);
        deal(seller, 100 ether);
        deal(sellerTwo, 100 ether);
        deal(buyer, 100 ether);

        vm.startPrank(deployer);
        currency = new CheckoutCurrency();
        currency.transfer(buyer, 1_000_000 ether);
        erc20ApprovalManager = new ERC20ApprovalManager();
        erc721ApprovalManager = new ERC721ApprovalManager();
        erc1155ApprovalManager = new ERC1155ApprovalManager();
        settlement = new RareERC1155Settlement();
        marketplace = RareERC1155Marketplace(
            address(
                new ERC1967Proxy(
                    address(new RareERC1155Marketplace()), _initData(address(new Payments()), address(settlement))
                )
            )
        );
        erc20ApprovalManager.grantOperatorRole(address(marketplace));
        erc1155ApprovalManager.grantOperatorRole(address(marketplace));

        tokenFactory = new RareERC1155ContractFactory();
        tokenFactory.setDefaultMinter(address(marketplace));
        vm.stopPrank();

        vm.prank(seller);
        token = RareERC1155(tokenFactory.createRareERC1155Contract("Rare Editions", "RED", "ipfs://base/{id}.json"));

        vm.prank(seller);
        tokenId = token.createToken("ipfs://token/1.json", 20, seller);

        vm.etch(marketplaceSettings, address(marketplace).code);
        vm.etch(stakingSettings, address(marketplace).code);
        vm.etch(stakingRegistry, address(marketplace).code);
        vm.etch(royaltyEngine, address(marketplace).code);
        vm.etch(spaceOperatorRegistry, address(marketplace).code);
        vm.etch(approvedTokenRegistry, address(marketplace).code);
    }

    function testBuyListingThroughSettlementModule() public {
        uint256 price = 1 ether;
        uint256 quantity = 2;

        vm.prank(seller);
        token.mintBatchTo(seller, _singleTokenIds(tokenId), _singleAmounts(quantity));

        vm.prank(seller);
        token.setApprovalForAll(address(erc1155ApprovalManager), true);

        vm.prank(seller);
        marketplace.setSalePrices(
            address(token),
            address(0),
            _singleSalePriceRequest(tokenId, price, quantity),
            _singleSplitRecipients(seller),
            _singleSplitRatios()
        );

        _mockSecondaryPayout(price * quantity, seller);

        vm.prank(buyer);
        marketplace.buyBatch{value: _withFee(price * quantity)}(
            address(token), seller, address(0), _singleBuyRequest(tokenId, price, quantity)
        );

        assertEq(token.balanceOf(buyer, tokenId), quantity);
        assertEq(token.balanceOf(seller, tokenId), 0);
        assertEq(marketplace.getSalePrice(address(token), tokenId, seller).quantity, 0);
    }

    function testAcceptOfferThroughSettlementModule() public {
        uint256 price = 1 ether;
        uint256 offerQuantity = 2;

        vm.prank(seller);
        token.mintBatchTo(seller, _singleTokenIds(tokenId), _singleAmounts(offerQuantity));

        vm.prank(seller);
        token.setApprovalForAll(address(erc1155ApprovalManager), true);

        _mockMarketplaceFee(price * offerQuantity, seller);
        vm.prank(buyer);
        marketplace.makeOffer{value: _withFee(price * offerQuantity)}(
            address(token), tokenId, address(0), price, offerQuantity, 0
        );

        _mockSecondaryPayout(price, seller);
        vm.prank(seller);
        marketplace.acceptOffer(
            address(token), tokenId, buyer, address(0), price, 1, _singleSplitRecipients(seller), _singleSplitRatios()
        );

        IRareERC1155MarketplaceTypes.Offer memory offer =
            marketplace.getOffer(address(token), tokenId, buyer, address(0));
        assertEq(offer.quantity, 1);
        assertEq(offer.marketplaceFeeRemaining, _fee(price));
        assertEq(token.balanceOf(buyer, tokenId), 1);
        assertEq(token.balanceOf(seller, tokenId), 1);
    }

    function testMintDirectSaleThroughSettlementModule() public {
        uint256 price = 1 ether;
        uint256 quantity = 2;

        vm.prank(seller);
        marketplace.prepareMintDirectSales(
            address(token),
            address(0),
            _singleDirectSaleRequest(tokenId, price, 0, 0),
            _singleSplitRecipients(seller),
            _singleSplitRatios()
        );

        _mockPrimaryPayout(price * quantity, seller);

        vm.prank(buyer);
        marketplace.mintDirectSaleBatch{value: _withFee(price * quantity)}(
            address(token), address(0), _singleMintRequest(tokenId, price, quantity)
        );

        assertEq(token.balanceOf(buyer, tokenId), quantity);
        assertEq(marketplace.getTokenMintsPerAddress(address(token), tokenId, buyer), 0);
    }

    function testMintDirectSaleBatchRevertsWithSharedValidationReason() public {
        uint256 price = 1 ether;

        vm.prank(seller);
        marketplace.prepareMintDirectSales(
            address(token),
            address(0),
            _singleDirectSaleRequest(tokenId, price, 0, 0),
            _singleSplitRecipients(seller),
            _singleSplitRatios()
        );

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(IRareERC1155MarketplaceTypes.PriceMismatch.selector, price + 1, price));
        marketplace.mintDirectSaleBatch(address(token), address(0), _singleMintRequest(tokenId, price + 1, 1));
    }

    function testBuyBatchRevertsWithSharedValidationReason() public {
        uint256 price = 1 ether;

        vm.prank(seller);
        token.mintBatchTo(seller, _singleTokenIds(tokenId), _singleAmounts(1));

        vm.prank(seller);
        token.setApprovalForAll(address(erc1155ApprovalManager), true);

        vm.prank(seller);
        marketplace.setSalePrices(
            address(token),
            address(0),
            _singleSalePriceRequest(tokenId, price, 1),
            _singleSplitRecipients(seller),
            _singleSplitRatios()
        );

        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(IRareERC1155MarketplaceTypes.QuantityExceedsSalePriceQuantity.selector, 2, 1)
        );
        marketplace.buyBatch(address(token), seller, address(0), _singleBuyRequest(tokenId, price, 2));
    }

    function testMarketplaceUsesSeparateBatchAndCheckoutCaps() public {
        assertEq(marketplace.MAX_BATCH_SIZE(), 75);
        assertEq(marketplace.MAX_CHECKOUT_SIZE(), 50);

        IRareERC1155MarketplaceTypes.MintRequest[] memory mintRequests =
            new IRareERC1155MarketplaceTypes.MintRequest[](76);
        vm.expectRevert(abi.encodeWithSelector(IRareERC1155MarketplaceTypes.BatchSizeExceeded.selector, 76, 75));
        marketplace.mintDirectSaleBatch(address(token), address(0), mintRequests);

        IRareERC1155MarketplaceTypes.CheckoutItem[] memory checkoutItems =
            new IRareERC1155MarketplaceTypes.CheckoutItem[](51);
        vm.expectRevert(abi.encodeWithSelector(IRareERC1155MarketplaceTypes.BatchSizeExceeded.selector, 51, 50));
        marketplace.checkout(checkoutItems);
    }

    function testCheckoutFillsMixedDirectSaleAndListingAcrossCurrencies() public {
        uint256 mintPrice = 1 ether;
        uint256 listingPrice = 2 ether;

        vm.prank(seller);
        marketplace.prepareMintDirectSales(
            address(token),
            address(0),
            _singleDirectSaleRequest(tokenId, mintPrice, 0, 0),
            _singleSplitRecipients(seller),
            _singleSplitRatios()
        );
        _mockPrimaryPayoutFor(address(token), mintPrice, seller);

        vm.prank(sellerTwo);
        RareERC1155 otherToken =
            RareERC1155(tokenFactory.createRareERC1155Contract("Other Editions", "OED", "ipfs://other/{id}.json"));
        vm.prank(sellerTwo);
        uint256 otherTokenId = otherToken.createToken("ipfs://other/1.json", 10, sellerTwo);
        vm.prank(sellerTwo);
        otherToken.mintBatchTo(sellerTwo, _singleTokenIds(otherTokenId), _singleAmounts(1));
        vm.prank(sellerTwo);
        otherToken.setApprovalForAll(address(erc1155ApprovalManager), true);

        _mockApprovedCurrency(address(currency));
        vm.prank(sellerTwo);
        marketplace.setSalePrices(
            address(otherToken),
            address(currency),
            _singleSalePriceRequest(otherTokenId, listingPrice, 1),
            _singleSplitRecipients(sellerTwo),
            _singleSplitRatios()
        );
        _mockSecondaryPayoutFor(address(otherToken), otherTokenId, listingPrice, sellerTwo);

        vm.prank(buyer);
        currency.approve(address(erc20ApprovalManager), _withFee(listingPrice));

        IRareERC1155MarketplaceTypes.CheckoutItem[] memory items = new IRareERC1155MarketplaceTypes.CheckoutItem[](2);
        items[0] = _directSaleCheckoutItem(address(token), seller, address(0), tokenId, mintPrice, 1);
        items[1] =
            _listingCheckoutItem(address(otherToken), sellerTwo, address(currency), otherTokenId, listingPrice, 1);

        uint256 buyerCurrencyBefore = currency.balanceOf(buyer);

        vm.prank(buyer);
        IRareERC1155MarketplaceTypes.CheckoutSummary memory summary =
            marketplace.checkout{value: _withFee(mintPrice)}(items);

        assertEq(summary.filledCount, 2);
        assertEq(summary.skippedCount, 0);
        assertEq(summary.ethSpent, _withFee(mintPrice));
        assertEq(summary.ethRefunded, 0);
        assertEq(token.balanceOf(buyer, tokenId), 1);
        assertEq(otherToken.balanceOf(buyer, otherTokenId), 1);
        assertEq(otherToken.balanceOf(sellerTwo, otherTokenId), 0);
        assertEq(currency.balanceOf(buyer), buyerCurrencyBefore - _withFee(listingPrice));
        assertEq(currency.balanceOf(address(marketplace)), 0);
        assertEq(address(marketplace).balance, 0);
    }

    function testCheckoutDirectSaleMintResolvesSellerFromConfig() public {
        uint256 price = 1 ether;

        vm.prank(seller);
        marketplace.prepareMintDirectSales(
            address(token),
            address(0),
            _singleDirectSaleRequest(tokenId, price, 0, 0),
            _singleSplitRecipients(seller),
            _singleSplitRatios()
        );
        _mockPrimaryPayout(price, seller);

        IRareERC1155MarketplaceTypes.CheckoutItem[] memory items = new IRareERC1155MarketplaceTypes.CheckoutItem[](1);
        items[0] = _directSaleCheckoutItem(address(token), sellerTwo, address(0), tokenId, price, 1);

        vm.prank(buyer);
        IRareERC1155MarketplaceTypes.CheckoutSummary memory summary =
            marketplace.checkout{value: _withFee(price)}(items);

        assertEq(summary.filledCount, 1);
        assertEq(summary.skippedCount, 0);
        assertEq(summary.ethSpent, _withFee(price));
        assertEq(token.balanceOf(buyer, tokenId), 1);
    }

    function testCheckoutSkipsInvalidItemsAndRefundsUnusedETH() public {
        uint256 mintPrice = 1 ether;
        uint256 listingPrice = 2 ether;
        uint256 refundAmount = 0.5 ether;

        vm.prank(seller);
        token.mintBatchTo(seller, _singleTokenIds(tokenId), _singleAmounts(1));
        vm.prank(seller);
        token.setApprovalForAll(address(erc1155ApprovalManager), true);
        vm.prank(seller);
        marketplace.setSalePrices(
            address(token),
            address(0),
            _singleSalePriceRequest(tokenId, listingPrice, 1),
            _singleSplitRecipients(seller),
            _singleSplitRatios()
        );

        vm.prank(seller);
        marketplace.prepareMintDirectSales(
            address(token),
            address(0),
            _singleDirectSaleRequest(tokenId, mintPrice, 0, 0),
            _singleSplitRecipients(seller),
            _singleSplitRatios()
        );
        _mockPrimaryPayoutFor(address(token), mintPrice, seller);

        IRareERC1155MarketplaceTypes.CheckoutItem[] memory items = new IRareERC1155MarketplaceTypes.CheckoutItem[](2);
        items[0] = _listingCheckoutItem(address(token), seller, address(0), tokenId, listingPrice + 1, 1);
        items[1] = _directSaleCheckoutItem(address(token), seller, address(0), tokenId, mintPrice, 1);

        vm.prank(buyer);
        IRareERC1155MarketplaceTypes.CheckoutSummary memory summary =
            marketplace.checkout{value: _withFee(mintPrice) + refundAmount}(items);

        assertEq(summary.filledCount, 1);
        assertEq(summary.skippedCount, 1);
        assertEq(summary.ethSpent, _withFee(mintPrice));
        assertEq(summary.ethRefunded, refundAmount);
        assertEq(token.balanceOf(buyer, tokenId), 1);
        assertEq(token.balanceOf(seller, tokenId), 1);
        assertEq(marketplace.getSalePrice(address(token), tokenId, seller).quantity, 1);
        assertEq(address(marketplace).balance, 0);
    }

    function testCheckoutSkipsSoldOutDirectSaleMintAndRollsBackLimitCounters() public {
        uint256 price = 1 ether;

        vm.startPrank(seller);
        uint256 soldOutTokenId = token.createToken("ipfs://token/sold-out-primary.json", 1, seller);
        token.mintBatchTo(seller, _singleTokenIds(soldOutTokenId), _singleAmounts(1));
        marketplace.prepareMintDirectSales(
            address(token),
            address(0),
            _singleDirectSaleRequest(soldOutTokenId, price, 0, 0),
            _singleSplitRecipients(seller),
            _singleSplitRatios()
        );
        marketplace.setTokenMintLimits(address(token), _singleTokenLimitRequest(soldOutTokenId, 5));
        marketplace.setTokenTxLimits(address(token), _singleTokenLimitRequest(soldOutTokenId, 5));
        marketplace.prepareMintDirectSales(
            address(token),
            address(0),
            _singleDirectSaleRequest(tokenId, price, 0, 0),
            _singleSplitRecipients(seller),
            _singleSplitRatios()
        );
        vm.stopPrank();

        _mockPrimaryPayoutFor(address(token), price, seller);

        IRareERC1155MarketplaceTypes.CheckoutItem[] memory items = new IRareERC1155MarketplaceTypes.CheckoutItem[](2);
        items[0] = _directSaleCheckoutItem(address(token), seller, address(0), soldOutTokenId, price, 1);
        items[1] = _directSaleCheckoutItem(address(token), seller, address(0), tokenId, price, 1);

        vm.prank(buyer);
        IRareERC1155MarketplaceTypes.CheckoutSummary memory summary =
            marketplace.checkout{value: _withFee(price)}(items);

        assertEq(summary.filledCount, 1);
        assertEq(summary.skippedCount, 1);
        assertEq(summary.ethSpent, _withFee(price));
        assertEq(token.balanceOf(buyer, soldOutTokenId), 0);
        assertEq(token.balanceOf(buyer, tokenId), 1);
        assertEq(marketplace.getTokenMintsPerAddress(address(token), soldOutTokenId, buyer), 0);
        assertEq(marketplace.getTokenTxsPerAddress(address(token), soldOutTokenId, buyer), 0);
    }

    function testCheckoutSkipsDirectSaleMintWhenMarketplaceMinterApprovalRevoked() public {
        uint256 price = 1 ether;

        vm.startPrank(seller);
        marketplace.prepareMintDirectSales(
            address(token),
            address(0),
            _singleDirectSaleRequest(tokenId, price, 0, 0),
            _singleSplitRecipients(seller),
            _singleSplitRatios()
        );
        token.setMinterApproval(address(marketplace), false);
        token.mintBatchTo(seller, _singleTokenIds(tokenId), _singleAmounts(1));
        token.setApprovalForAll(address(erc1155ApprovalManager), true);
        marketplace.setSalePrices(
            address(token),
            address(0),
            _singleSalePriceRequest(tokenId, price, 1),
            _singleSplitRecipients(seller),
            _singleSplitRatios()
        );
        vm.stopPrank();

        _mockSecondaryPayout(price, seller);

        IRareERC1155MarketplaceTypes.CheckoutItem[] memory items = new IRareERC1155MarketplaceTypes.CheckoutItem[](2);
        items[0] = _directSaleCheckoutItem(address(token), seller, address(0), tokenId, price, 1);
        items[1] = _listingCheckoutItem(address(token), seller, address(0), tokenId, price, 1);

        vm.prank(buyer);
        IRareERC1155MarketplaceTypes.CheckoutSummary memory summary =
            marketplace.checkout{value: _withFee(price)}(items);

        assertEq(summary.filledCount, 1);
        assertEq(summary.skippedCount, 1);
        assertEq(summary.ethSpent, _withFee(price));
        assertEq(token.balanceOf(buyer, tokenId), 1);
        assertEq(token.totalMintedForToken(tokenId), 1);
        assertEq(marketplace.getSalePrice(address(token), tokenId, seller).quantity, 0);
    }

    function testCheckoutSkipsAdditionalValidationFailuresBeforeSuccessfulFill() public {
        uint256 price = 1 ether;
        uint256 expensivePrice = 20 ether;

        vm.startPrank(seller);
        uint256 soldOutTokenId = token.createToken("ipfs://token/sold-out.json", 5, seller);
        uint256 expiredTokenId = token.createToken("ipfs://token/expired.json", 5, seller);
        uint256 expensiveTokenId = token.createToken("ipfs://token/expensive.json", 5, seller);
        uint256 allowlistTokenId = token.createToken("ipfs://token/allowlist.json", 5, seller);
        token.mintBatchTo(
            seller,
            _tokenIds(soldOutTokenId, expiredTokenId, expensiveTokenId),
            _amounts(uint256(1), uint256(1), uint256(1))
        );
        token.setApprovalForAll(address(erc1155ApprovalManager), true);
        marketplace.setSalePrices(
            address(token),
            address(0),
            _singleSalePriceRequest(soldOutTokenId, price, 1),
            _singleSplitRecipients(seller),
            _singleSplitRatios()
        );
        marketplace.setSalePrices(
            address(token),
            address(0),
            _singleExpiringSalePriceRequest(expiredTokenId, price, 1, block.timestamp + 1),
            _singleSplitRecipients(seller),
            _singleSplitRatios()
        );
        marketplace.setSalePrices(
            address(token),
            address(0),
            _singleSalePriceRequest(expensiveTokenId, expensivePrice, 1),
            _singleSplitRecipients(seller),
            _singleSplitRatios()
        );
        marketplace.prepareMintDirectSales(
            address(token),
            address(0),
            _singleDirectSaleRequest(allowlistTokenId, price, 0, 0),
            _singleSplitRecipients(seller),
            _singleSplitRatios()
        );
        marketplace.setTokenAllowListConfigs(
            address(token),
            _singleAllowListConfigRequest(
                allowlistTokenId, keccak256(abi.encodePacked(address(0xdead))), block.timestamp + 1 days
            )
        );
        marketplace.prepareMintDirectSales(
            address(token),
            address(0),
            _singleDirectSaleRequest(tokenId, price, 0, 0),
            _singleSplitRecipients(seller),
            _singleSplitRatios()
        );
        vm.stopPrank();

        _mockMarketplaceFee(expensivePrice, seller);
        _mockPrimaryPayoutFor(address(token), price, seller);

        vm.warp(block.timestamp + 2);

        IRareERC1155MarketplaceTypes.CheckoutItem[] memory items = new IRareERC1155MarketplaceTypes.CheckoutItem[](5);
        items[0] = _listingCheckoutItem(address(token), seller, address(0), soldOutTokenId, price, 2);
        items[1] = _listingCheckoutItem(address(token), seller, address(0), expiredTokenId, price, 1);
        items[2] = _listingCheckoutItem(address(token), seller, address(0), expensiveTokenId, expensivePrice, 1);
        items[3] = _directSaleCheckoutItem(address(token), seller, address(0), allowlistTokenId, price, 1);
        items[4] = _directSaleCheckoutItem(address(token), seller, address(0), tokenId, price, 1);

        vm.prank(buyer);
        IRareERC1155MarketplaceTypes.CheckoutSummary memory summary =
            marketplace.checkout{value: _withFee(price)}(items);

        assertEq(summary.filledCount, 1);
        assertEq(summary.skippedCount, 4);
        assertEq(summary.ethSpent, _withFee(price));
        assertEq(summary.ethRefunded, 0);
        assertEq(token.balanceOf(buyer, tokenId), 1);
        assertEq(token.balanceOf(buyer, soldOutTokenId), 0);
        assertEq(token.balanceOf(buyer, expiredTokenId), 0);
        assertEq(token.balanceOf(buyer, expensiveTokenId), 0);
        assertEq(token.balanceOf(buyer, allowlistTokenId), 0);
        assertEq(token.balanceOf(seller, soldOutTokenId), 1);
        assertEq(token.balanceOf(seller, expiredTokenId), 1);
        assertEq(token.balanceOf(seller, expensiveTokenId), 1);
    }

    function testCheckoutSkipsInsufficientERC20AllowanceWithoutPullingFunds() public {
        uint256 mintPrice = 1 ether;
        uint256 listingPrice = 2 ether;

        vm.prank(seller);
        uint256 listedTokenId = token.createToken("ipfs://token/2.json", 5, seller);
        vm.prank(seller);
        token.mintBatchTo(seller, _singleTokenIds(listedTokenId), _singleAmounts(1));
        vm.prank(seller);
        token.setApprovalForAll(address(erc1155ApprovalManager), true);

        _mockApprovedCurrency(address(currency));
        _mockMarketplaceFee(listingPrice, seller);
        vm.prank(seller);
        marketplace.setSalePrices(
            address(token),
            address(currency),
            _singleSalePriceRequest(listedTokenId, listingPrice, 1),
            _singleSplitRecipients(seller),
            _singleSplitRatios()
        );

        vm.prank(seller);
        marketplace.prepareMintDirectSales(
            address(token),
            address(0),
            _singleDirectSaleRequest(tokenId, mintPrice, 0, 0),
            _singleSplitRecipients(seller),
            _singleSplitRatios()
        );
        _mockPrimaryPayoutFor(address(token), mintPrice, seller);

        IRareERC1155MarketplaceTypes.CheckoutItem[] memory items = new IRareERC1155MarketplaceTypes.CheckoutItem[](2);
        items[0] = _listingCheckoutItem(address(token), seller, address(currency), listedTokenId, listingPrice, 1);
        items[1] = _directSaleCheckoutItem(address(token), seller, address(0), tokenId, mintPrice, 1);

        uint256 buyerCurrencyBefore = currency.balanceOf(buyer);

        vm.prank(buyer);
        IRareERC1155MarketplaceTypes.CheckoutSummary memory summary =
            marketplace.checkout{value: _withFee(mintPrice)}(items);

        assertEq(summary.filledCount, 1);
        assertEq(summary.skippedCount, 1);
        assertEq(summary.ethSpent, _withFee(mintPrice));
        assertEq(currency.balanceOf(buyer), buyerCurrencyBefore);
        assertEq(token.balanceOf(buyer, listedTokenId), 0);
        assertEq(token.balanceOf(seller, listedTokenId), 1);
        assertEq(marketplace.getSalePrice(address(token), listedTokenId, seller).quantity, 1);
        assertEq(token.balanceOf(buyer, tokenId), 1);
    }

    function testCheckoutRevertsWhenEveryItemIsSkipped() public {
        IRareERC1155MarketplaceTypes.CheckoutItem[] memory items = new IRareERC1155MarketplaceTypes.CheckoutItem[](1);
        items[0] = _unsupportedCheckoutItem();

        vm.prank(buyer);
        vm.expectRevert(IRareERC1155MarketplaceTypes.CheckoutRequiresSuccessfulFill.selector);
        marketplace.checkout(items);
    }

    function testCheckoutRevertsOnNonSkippableTransferFailure() public {
        CheckoutNoOpERC1155 brokenToken = new CheckoutNoOpERC1155();
        uint256 brokenTokenId = 88;
        uint256 price = 1 ether;

        brokenToken.setBalance(seller, brokenTokenId, 1);
        vm.prank(seller);
        brokenToken.setApprovalForAll(address(erc1155ApprovalManager), true);

        vm.prank(seller);
        marketplace.setSalePrices(
            address(brokenToken),
            address(0),
            _singleSalePriceRequest(brokenTokenId, price, 1),
            _singleSplitRecipients(seller),
            _singleSplitRatios()
        );
        _mockMarketplaceFee(price, seller);

        IRareERC1155MarketplaceTypes.CheckoutItem[] memory items = new IRareERC1155MarketplaceTypes.CheckoutItem[](1);
        items[0] = _listingCheckoutItem(address(brokenToken), seller, address(0), brokenTokenId, price, 1);

        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRareERC1155MarketplaceTypes.InvalidERC1155Transfer.selector,
                address(brokenToken),
                brokenTokenId,
                seller,
                buyer,
                1
            )
        );
        marketplace.checkout{value: _withFee(price)}(items);

        assertEq(brokenToken.balanceOf(seller, brokenTokenId), 1);
        assertEq(brokenToken.balanceOf(buyer, brokenTokenId), 0);
        assertEq(marketplace.getSalePrice(address(brokenToken), brokenTokenId, seller).quantity, 1);
    }

    function testDirectCallsToSettlementRevert() public {
        IRareERC1155MarketplaceTypes.BuyRequest[] memory requests = new IRareERC1155MarketplaceTypes.BuyRequest[](1);
        requests[0] = IRareERC1155MarketplaceTypes.BuyRequest(tokenId, 1 ether, 1);

        vm.expectRevert(IRareERC1155MarketplaceTypes.DirectSettlementCallUnsupported.selector);
        settlement.buyBatch(address(token), seller, address(0), requests);

        IRareERC1155MarketplaceTypes.CheckoutItem[] memory items = new IRareERC1155MarketplaceTypes.CheckoutItem[](0);

        vm.expectRevert(IRareERC1155MarketplaceTypes.DirectSettlementCallUnsupported.selector);
        settlement.checkout(items);
    }

    function testOwnerCanUpdateSettlementModule() public {
        vm.prank(deployer);
        RareERC1155Settlement newSettlement = new RareERC1155Settlement();

        vm.prank(deployer);
        marketplace.setSettlement(address(newSettlement));

        assertEq(marketplace.getSettlement(), address(newSettlement));
    }

    function testSetTokenAllowListConfigsRevertsWhenPaused() public {
        vm.prank(deployer);
        marketplace.setContractPaused(true);

        vm.prank(seller);
        vm.expectRevert(IRareERC1155MarketplaceTypes.ContractPaused.selector);
        marketplace.setTokenAllowListConfigs(
            address(token),
            _singleAllowListConfigRequest(tokenId, keccak256(abi.encodePacked(buyer)), block.timestamp + 1 days)
        );
    }

    function testSetTokenMintLimitsRevertsWhenPaused() public {
        vm.prank(deployer);
        marketplace.setContractPaused(true);

        vm.prank(seller);
        vm.expectRevert(IRareERC1155MarketplaceTypes.ContractPaused.selector);
        marketplace.setTokenMintLimits(address(token), _singleTokenLimitRequest(tokenId, 5));
    }

    function testSetTokenTxLimitsRevertsWhenPaused() public {
        vm.prank(deployer);
        marketplace.setContractPaused(true);

        vm.prank(seller);
        vm.expectRevert(IRareERC1155MarketplaceTypes.ContractPaused.selector);
        marketplace.setTokenTxLimits(address(token), _singleTokenLimitRequest(tokenId, 5));
    }

    function _initData(address _payments, address _settlement) private view returns (bytes memory) {
        return abi.encodeWithSelector(
            RareERC1155Marketplace.initialize.selector,
            networkBeneficiary,
            marketplaceSettings,
            spaceOperatorRegistry,
            royaltyEngine,
            _payments,
            approvedTokenRegistry,
            stakingSettings,
            stakingRegistry,
            address(erc20ApprovalManager),
            address(erc721ApprovalManager),
            address(erc1155ApprovalManager),
            _settlement
        );
    }

    function _singleSalePriceRequest(uint256 _tokenId, uint256 _price, uint256 _quantity)
        private
        pure
        returns (IRareERC1155MarketplaceTypes.SalePriceRequest[] memory)
    {
        IRareERC1155MarketplaceTypes.SalePriceRequest[] memory requests =
            new IRareERC1155MarketplaceTypes.SalePriceRequest[](1);
        requests[0] = IRareERC1155MarketplaceTypes.SalePriceRequest(_tokenId, _price, _quantity, 0);
        return requests;
    }

    function _singleExpiringSalePriceRequest(
        uint256 _tokenId,
        uint256 _price,
        uint256 _quantity,
        uint256 _expirationTime
    ) private pure returns (IRareERC1155MarketplaceTypes.SalePriceRequest[] memory) {
        IRareERC1155MarketplaceTypes.SalePriceRequest[] memory requests =
            new IRareERC1155MarketplaceTypes.SalePriceRequest[](1);
        requests[0] = IRareERC1155MarketplaceTypes.SalePriceRequest(_tokenId, _price, _quantity, _expirationTime);
        return requests;
    }

    function _singleDirectSaleRequest(uint256 _tokenId, uint256 _price, uint256 _startTime, uint256 _maxMints)
        private
        pure
        returns (IRareERC1155MarketplaceTypes.DirectSaleRequest[] memory)
    {
        IRareERC1155MarketplaceTypes.DirectSaleRequest[] memory requests =
            new IRareERC1155MarketplaceTypes.DirectSaleRequest[](1);
        requests[0] = IRareERC1155MarketplaceTypes.DirectSaleRequest(_tokenId, _price, _startTime, _maxMints);
        return requests;
    }

    function _singleAllowListConfigRequest(uint256 _tokenId, bytes32 _root, uint256 _endTimestamp)
        private
        pure
        returns (IRareERC1155MarketplaceTypes.AllowListConfigRequest[] memory)
    {
        IRareERC1155MarketplaceTypes.AllowListConfigRequest[] memory requests =
            new IRareERC1155MarketplaceTypes.AllowListConfigRequest[](1);
        requests[0] = IRareERC1155MarketplaceTypes.AllowListConfigRequest(_tokenId, _root, _endTimestamp);
        return requests;
    }

    function _singleTokenLimitRequest(uint256 _tokenId, uint256 _limit)
        private
        pure
        returns (IRareERC1155MarketplaceTypes.TokenLimitRequest[] memory)
    {
        IRareERC1155MarketplaceTypes.TokenLimitRequest[] memory requests =
            new IRareERC1155MarketplaceTypes.TokenLimitRequest[](1);
        requests[0] = IRareERC1155MarketplaceTypes.TokenLimitRequest(_tokenId, _limit);
        return requests;
    }

    function _singleMintRequest(uint256 _tokenId, uint256 _price, uint256 _quantity)
        private
        pure
        returns (IRareERC1155MarketplaceTypes.MintRequest[] memory)
    {
        bytes32[] memory proof = new bytes32[](0);
        IRareERC1155MarketplaceTypes.MintRequest[] memory requests = new IRareERC1155MarketplaceTypes.MintRequest[](1);
        requests[0] = IRareERC1155MarketplaceTypes.MintRequest(_tokenId, _price, _quantity, proof);
        return requests;
    }

    function _singleBuyRequest(uint256 _tokenId, uint256 _price, uint256 _quantity)
        private
        pure
        returns (IRareERC1155MarketplaceTypes.BuyRequest[] memory)
    {
        IRareERC1155MarketplaceTypes.BuyRequest[] memory requests = new IRareERC1155MarketplaceTypes.BuyRequest[](1);
        requests[0] = IRareERC1155MarketplaceTypes.BuyRequest(_tokenId, _price, _quantity);
        return requests;
    }

    function _directSaleCheckoutItem(
        address _contractAddress,
        address _seller,
        address _currencyAddress,
        uint256 _tokenId,
        uint256 _price,
        uint256 _quantity
    ) private pure returns (IRareERC1155MarketplaceTypes.CheckoutItem memory) {
        return IRareERC1155MarketplaceTypes.CheckoutItem({
            itemKind: uint8(IRareERC1155MarketplaceTypes.CheckoutItemKind.DIRECT_SALE_MINT),
            contractAddress: _contractAddress,
            seller: _seller,
            currencyAddress: _currencyAddress,
            tokenId: _tokenId,
            price: _price,
            quantity: _quantity,
            proof: new bytes32[](0)
        });
    }

    function _listingCheckoutItem(
        address _contractAddress,
        address _seller,
        address _currencyAddress,
        uint256 _tokenId,
        uint256 _price,
        uint256 _quantity
    ) private pure returns (IRareERC1155MarketplaceTypes.CheckoutItem memory) {
        return IRareERC1155MarketplaceTypes.CheckoutItem({
            itemKind: uint8(IRareERC1155MarketplaceTypes.CheckoutItemKind.LISTING_BUY),
            contractAddress: _contractAddress,
            seller: _seller,
            currencyAddress: _currencyAddress,
            tokenId: _tokenId,
            price: _price,
            quantity: _quantity,
            proof: new bytes32[](0)
        });
    }

    function _unsupportedCheckoutItem() private pure returns (IRareERC1155MarketplaceTypes.CheckoutItem memory) {
        return IRareERC1155MarketplaceTypes.CheckoutItem({
            itemKind: type(uint8).max,
            contractAddress: address(0),
            seller: address(0),
            currencyAddress: address(0),
            tokenId: 0,
            price: 0,
            quantity: 0,
            proof: new bytes32[](0)
        });
    }

    function _singleSplitRecipients(address _recipient) private pure returns (address payable[] memory recipients) {
        recipients = new address payable[](1);
        recipients[0] = payable(_recipient);
    }

    function _singleSplitRatios() private pure returns (uint8[] memory ratios) {
        ratios = new uint8[](1);
        ratios[0] = 100;
    }

    function _singleTokenIds(uint256 _tokenId) private pure returns (uint256[] memory tokenIds) {
        tokenIds = new uint256[](1);
        tokenIds[0] = _tokenId;
    }

    function _tokenIds(uint256 _firstTokenId, uint256 _secondTokenId, uint256 _thirdTokenId)
        private
        pure
        returns (uint256[] memory tokenIds)
    {
        tokenIds = new uint256[](3);
        tokenIds[0] = _firstTokenId;
        tokenIds[1] = _secondTokenId;
        tokenIds[2] = _thirdTokenId;
    }

    function _singleAmounts(uint256 _amount) private pure returns (uint256[] memory amounts) {
        amounts = new uint256[](1);
        amounts[0] = _amount;
    }

    function _amounts(uint256 _firstAmount, uint256 _secondAmount, uint256 _thirdAmount)
        private
        pure
        returns (uint256[] memory amounts)
    {
        amounts = new uint256[](3);
        amounts[0] = _firstAmount;
        amounts[1] = _secondAmount;
        amounts[2] = _thirdAmount;
    }

    function _mockSecondaryPayout(uint256 _amount, address _seller) private {
        _mockSecondaryPayoutFor(address(token), tokenId, _amount, _seller);
    }

    function _mockSecondaryPayoutFor(address _contractAddress, uint256 _tokenId, uint256 _amount, address _seller)
        private
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

    function _mockApprovedCurrency(address _currencyAddress) private {
        vm.mockCall(
            approvedTokenRegistry,
            abi.encodeWithSelector(IApprovedTokenRegistry.isApprovedToken.selector, _currencyAddress),
            abi.encode(true)
        );
    }

    function _mockMarketplaceFee(uint256 _amount, address _seller) private {
        _mockApprovedCurrency(address(0));
        vm.mockCall(
            marketplaceSettings,
            abi.encodeWithSelector(IMarketplaceSettings.calculateMarketplaceFee.selector, _amount),
            abi.encode(_fee(_amount))
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

    function _mockPrimaryPayout(uint256 _amount, address _seller) private {
        _mockPrimaryPayoutFor(address(token), _amount, _seller);
    }

    function _mockPrimaryPayoutFor(address _contractAddress, uint256 _amount, address _seller) private {
        _mockMarketplaceFee(_amount, _seller);
        vm.mockCall(
            spaceOperatorRegistry,
            abi.encodeWithSignature("isApprovedSpaceOperator(address)", _seller),
            abi.encode(false)
        );
        vm.mockCall(
            marketplaceSettings,
            abi.encodeWithSignature("getERC721ContractPrimarySaleFeePercentage(address)", _contractAddress),
            abi.encode(uint256(10))
        );
    }

    function _withFee(uint256 _amount) private pure returns (uint256) {
        return _amount + _fee(_amount);
    }

    function _fee(uint256 _amount) private pure returns (uint256) {
        return (_amount * 3) / 100;
    }
}
