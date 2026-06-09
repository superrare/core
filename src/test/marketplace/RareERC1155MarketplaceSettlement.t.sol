// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import {ERC20} from "openzeppelin-contracts/token/ERC20/ERC20.sol";
import {IERC1155} from "openzeppelin-contracts/token/ERC1155/IERC1155.sol";
import {IERC165} from "openzeppelin-contracts/utils/introspection/IERC165.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {IApprovedTokenRegistry} from "../../registry/interfaces/IApprovedTokenRegistry.sol";
import {IMarketplaceSettings} from "../../marketplace/IMarketplaceSettings.sol";
import {Payments} from "../../payments/Payments.sol";
import {RareERC1155} from "../../token/ERC1155/RareERC1155.sol";
import {RareERC1155ContractFactory} from "../../token/ERC1155/RareERC1155ContractFactory.sol";
import {ERC20ApprovalManager} from "../../v2/approver/ERC20/ERC20ApprovalManager.sol";
import {ERC721ApprovalManager} from "../../v2/approver/ERC721/ERC721ApprovalManager.sol";
import {ERC1155ApprovalManager} from "../../v2/approver/ERC1155/ERC1155ApprovalManager.sol";
import {IRareERC1155CheckoutExecutionModule} from "../../marketplace/IRareERC1155CheckoutExecutionModule.sol";
import {IRareERC1155MarketplaceTypes} from "../../marketplace/IRareERC1155MarketplaceTypes.sol";
import {RareERC1155CheckoutExecutionModule} from "../../marketplace/RareERC1155CheckoutExecutionModule.sol";
import {RareERC1155Marketplace} from "../../marketplace/RareERC1155Marketplace.sol";
import {RareERC1155TradeExecutionModule} from "../../marketplace/RareERC1155TradeExecutionModule.sol";
import {IRoyaltyEngineV1} from "royalty-registry/IRoyaltyEngineV1.sol";

contract CheckoutCurrency is ERC20 {
  constructor() ERC20("Checkout Currency", "CCUR") {
    _mint(msg.sender, 1_000_000_000 ether);
  }
}

contract CheckoutRejectZeroTransferCurrency is CheckoutCurrency {
  function transfer(address _to, uint256 _amount) public override returns (bool) {
    if (_amount == 0) revert("zero transfer");
    return super.transfer(_to, _amount);
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

  function balanceOfBatch(
    address[] calldata _accounts,
    uint256[] calldata _ids
  ) external view override returns (uint256[] memory) {
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

  function safeBatchTransferFrom(
    address,
    address,
    uint256[] calldata,
    uint256[] calldata,
    bytes calldata
  ) external override {}
}

contract CheckoutToggleERC1155 is IERC1155 {
  mapping(address => mapping(uint256 => uint256)) private balances;
  mapping(address => mapping(address => bool)) private operatorApprovals;

  address private contractOwner;
  bool private revertOwner;
  bool private revertSupportsInterface;
  bool private revertApproval;
  bool private revertBalance;

  constructor(address _owner) {
    contractOwner = _owner;
  }

  function setRevertOwner(bool _revertOwner) external {
    revertOwner = _revertOwner;
  }

  function setRevertSupportsInterface(bool _revertSupportsInterface) external {
    revertSupportsInterface = _revertSupportsInterface;
  }

  function setRevertApproval(bool _revertApproval) external {
    revertApproval = _revertApproval;
  }

  function setRevertBalance(bool _revertBalance) external {
    revertBalance = _revertBalance;
  }

  function owner() external view returns (address) {
    if (revertOwner) revert("owner unavailable");
    return contractOwner;
  }

  function maxSupplyForToken(uint256) external pure returns (uint256) {
    return 100;
  }

  function mintBatchTo(address _receiver, uint256[] calldata _tokenIds, uint256[] calldata _amounts) public virtual {
    for (uint256 i = 0; i < _tokenIds.length; i++) {
      balances[_receiver][_tokenIds[i]] += _amounts[i];
    }
  }

  function setBalance(address _account, uint256 _tokenId, uint256 _amount) external {
    balances[_account][_tokenId] = _amount;
  }

  function supportsInterface(bytes4 _interfaceId) external view override returns (bool) {
    if (revertSupportsInterface) revert("supports unavailable");
    return _interfaceId == type(IERC165).interfaceId || _interfaceId == type(IERC1155).interfaceId;
  }

  function balanceOf(address _account, uint256 _tokenId) external view override returns (uint256) {
    if (revertBalance) revert("balance unavailable");
    return balances[_account][_tokenId];
  }

  function balanceOfBatch(
    address[] calldata _accounts,
    uint256[] calldata _ids
  ) external view override returns (uint256[] memory batchBalances) {
    batchBalances = new uint256[](_accounts.length);
    for (uint256 i = 0; i < _accounts.length; i++) {
      batchBalances[i] = balances[_accounts[i]][_ids[i]];
    }
  }

  function setApprovalForAll(address _operator, bool _approved) external override {
    operatorApprovals[msg.sender][_operator] = _approved;
  }

  function isApprovedForAll(address _account, address _operator) external view override returns (bool) {
    if (revertApproval) revert("approval unavailable");
    return operatorApprovals[_account][_operator];
  }

  function safeTransferFrom(
    address _from,
    address _to,
    uint256 _id,
    uint256 _amount,
    bytes calldata
  ) external override {
    balances[_from][_id] -= _amount;
    balances[_to][_id] += _amount;
  }

  function safeBatchTransferFrom(
    address _from,
    address _to,
    uint256[] calldata _ids,
    uint256[] calldata _amounts,
    bytes calldata
  ) external override {
    for (uint256 i = 0; i < _ids.length; i++) {
      balances[_from][_ids[i]] -= _amounts[i];
      balances[_to][_ids[i]] += _amounts[i];
    }
  }
}

contract CheckoutReentrantERC1155 is CheckoutToggleERC1155 {
  RareERC1155Marketplace private marketplace;
  bool public reentryBlocked;

  constructor(address _owner, RareERC1155Marketplace _marketplace) CheckoutToggleERC1155(_owner) {
    marketplace = _marketplace;
  }

  function mintBatchTo(address _receiver, uint256[] calldata _tokenIds, uint256[] calldata _amounts) public override {
    IRareERC1155MarketplaceTypes.CheckoutItem[]
      memory unsupportedItems = new IRareERC1155MarketplaceTypes.CheckoutItem[](1);
    unsupportedItems[0] = IRareERC1155MarketplaceTypes.CheckoutItem({
      itemKind: type(uint8).max,
      contractAddress: address(0),
      seller: address(0),
      currencyAddress: address(0),
      tokenId: 0,
      price: 0,
      quantity: 0,
      proof: new bytes32[](0)
    });
    (bool success, ) = address(marketplace).call(
      abi.encodeWithSelector(marketplace.checkout.selector, unsupportedItems)
    );
    reentryBlocked = !success;
    super.mintBatchTo(_receiver, _tokenIds, _amounts);
  }
}

contract CheckoutNoOpMintERC1155 is CheckoutToggleERC1155 {
  constructor(address _owner) CheckoutToggleERC1155(_owner) {}

  function mintBatchTo(address, uint256[] calldata, uint256[] calldata) public pure override {}
}

contract CheckoutPaymentObservingERC1155 is CheckoutToggleERC1155 {
  ERC20 private currency;
  address private marketplace;

  uint256 public marketplaceCurrencyBalanceAtMint;

  constructor(address _owner, ERC20 _currency, address _marketplace) CheckoutToggleERC1155(_owner) {
    currency = _currency;
    marketplace = _marketplace;
  }

  function mintBatchTo(address _receiver, uint256[] calldata _tokenIds, uint256[] calldata _amounts) public override {
    marketplaceCurrencyBalanceAtMint = currency.balanceOf(marketplace);
    super.mintBatchTo(_receiver, _tokenIds, _amounts);
  }
}

contract RejectETH {
  receive() external payable {
    revert("reject eth");
  }
}

contract CheckoutFailureDecoderHarness is RareERC1155CheckoutExecutionModule {
  function checkoutExecutionFailure(
    bytes memory _revertData
  ) external pure returns (IRareERC1155MarketplaceTypes.CheckoutFailureStage stage, bytes memory failureData) {
    return _checkoutExecutionFailure(_revertData);
  }
}

contract RareERC1155MarketplaceSettlementTest is Test {
  event MintDirectSaleCancelled(address indexed contractAddress, uint256 indexed tokenId);

  RareERC1155Marketplace private marketplace;
  RareERC1155TradeExecutionModule private tradeExecutionModule;
  RareERC1155CheckoutExecutionModule private checkoutExecutionModule;
  Payments private payments;
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
  address private royaltyEngine = address(0x7400);
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
    tradeExecutionModule = new RareERC1155TradeExecutionModule();
    checkoutExecutionModule = new RareERC1155CheckoutExecutionModule();
    payments = new Payments();
    marketplace = RareERC1155Marketplace(
      address(
        new ERC1967Proxy(
          address(new RareERC1155Marketplace()),
          _initData(address(payments), address(tradeExecutionModule), address(checkoutExecutionModule))
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
    vm.etch(royaltyEngine, address(marketplace).code);
    vm.etch(approvedTokenRegistry, address(marketplace).code);
  }

  function testBuyListingThroughTradeExecutionModule() public {
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
      address(token),
      seller,
      address(0),
      _singleBuyRequest(tokenId, price, quantity)
    );

    assertEq(token.balanceOf(buyer, tokenId), quantity);
    assertEq(token.balanceOf(seller, tokenId), 0);
    assertEq(marketplace.getSalePrice(address(token), tokenId, seller).quantity, 0);
  }

  function testBuyListingAcceptsMaxRoyaltyRecipients() public {
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

    _mockSecondaryPayoutWithRoyalties(
      address(token),
      tokenId,
      price,
      seller,
      _royaltyReceivers(5),
      _royaltyAmounts(price, 5)
    );

    uint256 sellerBalanceBefore = seller.balance;
    uint256 firstRoyaltyBalanceBefore = address(0x4101).balance;

    vm.prank(buyer);
    marketplace.buyBatch{value: _withFee(price)}(
      address(token),
      seller,
      address(0),
      _singleBuyRequest(tokenId, price, 1)
    );

    assertEq(token.balanceOf(buyer, tokenId), 1);
    assertEq(seller.balance, sellerBalanceBefore + ((price * 85) / 100));
    assertEq(address(0x4101).balance, firstRoyaltyBalanceBefore + ((price * 1) / 100));
  }

  function testCheckoutListingTruncatesRoyaltyRecipientsAndFills() public {
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

    _mockSecondaryPayoutWithRoyalties(
      address(token),
      tokenId,
      price,
      seller,
      _royaltyReceivers(6),
      _royaltyAmounts(price, 6)
    );

    IRareERC1155MarketplaceTypes.CheckoutItem[] memory items = new IRareERC1155MarketplaceTypes.CheckoutItem[](1);
    items[0] = _listingCheckoutItem(address(token), seller, address(0), tokenId, price, 1);

    uint256 sellerBalanceBefore = seller.balance;
    uint256 firstRoyaltyBalanceBefore = address(0x4101).balance;
    uint256 fifthRoyaltyBalanceBefore = address(0x4105).balance;
    uint256 sixthRoyaltyBalanceBefore = address(0x4106).balance;

    vm.prank(buyer);
    IRareERC1155MarketplaceTypes.CheckoutExecution memory execution = marketplace.checkout{value: _withFee(price)}(
      items
    );

    assertEq(execution.summary.filledCount, 1);
    assertEq(execution.summary.skippedCount, 0);
    assertTrue(execution.items[0].filled);
    assertEq(token.balanceOf(buyer, tokenId), 1);
    assertEq(seller.balance, sellerBalanceBefore + ((price * 85) / 100));
    assertEq(address(0x4101).balance, firstRoyaltyBalanceBefore + ((price * 1) / 100));
    assertEq(address(0x4105).balance, fifthRoyaltyBalanceBefore + ((price * 5) / 100));
    assertEq(address(0x4106).balance, sixthRoyaltyBalanceBefore);
  }

  function testBuyListingRejectsZeroAddressEthRoyaltyRecipient() public {
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

    _mockSecondaryPayoutWithRoyalties(
      address(token),
      tokenId,
      price,
      seller,
      _zeroAddressRoyaltyReceivers(),
      _singleRoyaltyAmounts(price)
    );

    vm.prank(buyer);
    vm.expectRevert(abi.encodeWithSelector(IRareERC1155MarketplaceTypes.RoyaltyRecipientCannotBeZero.selector, 0));
    marketplace.buyBatch{value: _withFee(price)}(
      address(token),
      seller,
      address(0),
      _singleBuyRequest(tokenId, price, 1)
    );

    assertEq(token.balanceOf(seller, tokenId), 1);
    assertEq(token.balanceOf(buyer, tokenId), 0);
    assertEq(address(payments).balance, 0);
  }

  function testBuyListingRejectsZeroAddressERC20RoyaltyRecipient() public {
    uint256 price = 1 ether;

    vm.prank(seller);
    token.mintBatchTo(seller, _singleTokenIds(tokenId), _singleAmounts(1));

    vm.prank(seller);
    token.setApprovalForAll(address(erc1155ApprovalManager), true);

    _mockApprovedCurrency(address(currency));

    vm.prank(seller);
    marketplace.setSalePrices(
      address(token),
      address(currency),
      _singleSalePriceRequest(tokenId, price, 1),
      _singleSplitRecipients(seller),
      _singleSplitRatios()
    );

    _mockSecondaryPayoutWithRoyalties(
      address(token),
      tokenId,
      price,
      seller,
      _zeroAddressRoyaltyReceivers(),
      _singleRoyaltyAmounts(price)
    );

    vm.prank(buyer);
    currency.approve(address(erc20ApprovalManager), _withFee(price));

    vm.prank(buyer);
    vm.expectRevert(abi.encodeWithSelector(IRareERC1155MarketplaceTypes.RoyaltyRecipientCannotBeZero.selector, 0));
    marketplace.buyBatch(address(token), seller, address(currency), _singleBuyRequest(tokenId, price, 1));

    assertEq(token.balanceOf(seller, tokenId), 1);
    assertEq(token.balanceOf(buyer, tokenId), 0);
    assertEq(currency.balanceOf(address(marketplace)), 0);
  }

  function testBuyListingSkipsZeroValueERC20MarketplaceFeeRecipient() public {
    CheckoutRejectZeroTransferCurrency rejectingCurrency = new CheckoutRejectZeroTransferCurrency();
    uint256 price = 100;

    rejectingCurrency.transfer(buyer, _withFee(price));

    vm.prank(seller);
    token.mintBatchTo(seller, _singleTokenIds(tokenId), _singleAmounts(1));

    vm.prank(seller);
    token.setApprovalForAll(address(erc1155ApprovalManager), true);

    _mockApprovedCurrency(address(rejectingCurrency));

    vm.prank(seller);
    marketplace.setSalePrices(
      address(token),
      address(rejectingCurrency),
      _singleSalePriceRequest(tokenId, price, 1),
      _singleSplitRecipients(seller),
      _singleSplitRatios()
    );

    vm.mockCall(
      marketplaceSettings,
      abi.encodeWithSelector(IMarketplaceSettings.calculateMarketplaceFee.selector, price),
      abi.encode(_fee(price))
    );
    vm.mockCall(
      royaltyEngine,
      abi.encodeWithSelector(IRoyaltyEngineV1.getRoyalty.selector, address(token), tokenId, price),
      abi.encode(new address payable[](0), new uint256[](0))
    );

    vm.prank(buyer);
    rejectingCurrency.approve(address(erc20ApprovalManager), _withFee(price));

    vm.prank(buyer);
    marketplace.buyBatch(address(token), seller, address(rejectingCurrency), _singleBuyRequest(tokenId, price, 1));

    assertEq(token.balanceOf(buyer, tokenId), 1);
    assertEq(rejectingCurrency.balanceOf(rewardAccumulator), 0);
  }

  function testAcceptOfferThroughTradeExecutionModule() public {
    uint256 price = 1 ether;
    uint256 offerQuantity = 2;

    vm.prank(seller);
    token.mintBatchTo(seller, _singleTokenIds(tokenId), _singleAmounts(offerQuantity));

    vm.prank(seller);
    token.setApprovalForAll(address(erc1155ApprovalManager), true);

    _mockMarketplaceFee(price * offerQuantity, seller);
    vm.prank(buyer);
    marketplace.makeOffer{value: _withFee(price * offerQuantity)}(
      address(token),
      tokenId,
      address(0),
      price,
      offerQuantity,
      0
    );

    _mockSecondaryPayout(price, seller);
    vm.prank(seller);
    marketplace.acceptOffer(
      address(token),
      tokenId,
      buyer,
      address(0),
      price,
      1,
      _singleSplitRecipients(seller),
      _singleSplitRatios()
    );

    IRareERC1155MarketplaceTypes.Offer memory offer = marketplace.getOffer(address(token), tokenId, buyer, address(0));
    assertEq(offer.quantity, 1);
    assertEq(offer.initialQuantity, offerQuantity);
    assertEq(offer.marketplaceFeeRemaining, _fee(price));
    assertEq(offer.marketplaceFeeTotal, _fee(price * offerQuantity));
    assertEq(token.balanceOf(buyer, tokenId), 1);
    assertEq(token.balanceOf(seller, tokenId), 1);
  }

  function testAcceptOfferIgnoresStakingFeeAfterSettingsRotation() public {
    uint256 price = 1 ether;
    uint256 offerQuantity = 2;

    vm.prank(seller);
    token.mintBatchTo(seller, _singleTokenIds(tokenId), _singleAmounts(offerQuantity));

    vm.prank(seller);
    token.setApprovalForAll(address(erc1155ApprovalManager), true);

    _mockMarketplaceFee(price * offerQuantity, seller);
    vm.prank(buyer);
    marketplace.makeOffer{value: _withFee(price * offerQuantity)}(
      address(token),
      tokenId,
      address(0),
      price,
      offerQuantity,
      0
    );

    vm.mockCall(
      royaltyEngine,
      abi.encodeWithSelector(IRoyaltyEngineV1.getRoyalty.selector, address(token), tokenId, price),
      abi.encode(new address payable[](0), new uint256[](0))
    );

    vm.prank(seller);
    marketplace.acceptOffer(
      address(token),
      tokenId,
      buyer,
      address(0),
      price,
      1,
      _singleSplitRecipients(seller),
      _singleSplitRatios()
    );

    IRareERC1155MarketplaceTypes.Offer memory offer = marketplace.getOffer(address(token), tokenId, buyer, address(0));
    assertEq(offer.quantity, 1);
    assertEq(offer.marketplaceFeeRemaining, _fee(price));
    assertEq(networkBeneficiary.balance, _fee(price));
    assertEq(rewardAccumulator.balance, 0);
    assertEq(token.balanceOf(buyer, tokenId), 1);
    assertEq(token.balanceOf(seller, tokenId), 1);
  }

  function testPartialOfferFillsAllocateMarketplaceFeeCumulatively() public {
    uint256 price = 1;
    uint256 offerQuantity = 100;
    uint256 fillQuantity = 34;

    vm.prank(seller);
    uint256 highQuantityTokenId = token.createToken("ipfs://token/high-quantity.json", offerQuantity, seller);

    vm.prank(seller);
    token.mintBatchTo(seller, _singleTokenIds(highQuantityTokenId), _singleAmounts(fillQuantity));

    vm.prank(seller);
    token.setApprovalForAll(address(erc1155ApprovalManager), true);

    _mockMarketplaceFee(price * offerQuantity, seller);
    vm.prank(buyer);
    marketplace.makeOffer{value: _withFee(price * offerQuantity)}(
      address(token),
      highQuantityTokenId,
      address(0),
      price,
      offerQuantity,
      0
    );

    _mockSecondaryPayoutFor(address(token), highQuantityTokenId, price, seller);
    for (uint256 i = 0; i < fillQuantity; i++) {
      vm.prank(seller);
      marketplace.acceptOffer(
        address(token),
        highQuantityTokenId,
        buyer,
        address(0),
        price,
        1,
        _singleSplitRecipients(seller),
        _singleSplitRatios()
      );
    }

    IRareERC1155MarketplaceTypes.Offer memory offer = marketplace.getOffer(
      address(token),
      highQuantityTokenId,
      buyer,
      address(0)
    );
    assertEq(offer.quantity, offerQuantity - fillQuantity);
    assertEq(offer.initialQuantity, offerQuantity);
    assertEq(offer.marketplaceFeeRemaining, _fee(price * offerQuantity) - 1);
    assertEq(offer.marketplaceFeeTotal, _fee(price * offerQuantity));
    assertEq(networkBeneficiary.balance, 1);
    assertEq(rewardAccumulator.balance, 0);

    vm.prank(buyer);
    marketplace.cancelOffer(address(token), highQuantityTokenId, address(0));

    assertEq(buyer.balance, 100 ether - fillQuantity - 1);
    assertEq(seller.balance, 100 ether + fillQuantity);
    assertEq(marketplace.getOffer(address(token), highQuantityTokenId, buyer, address(0)).quantity, 0);
  }

  function testOfferEscrowTracksRemainingQuantityAndFeesAcrossPartialFills() public {
    uint256 price = 1 ether;
    uint256 offerQuantity = 3;

    vm.prank(seller);
    token.mintBatchTo(seller, _singleTokenIds(tokenId), _singleAmounts(offerQuantity));

    vm.prank(seller);
    token.setApprovalForAll(address(erc1155ApprovalManager), true);

    _mockMarketplaceFee(price * offerQuantity, seller);
    vm.prank(buyer);
    marketplace.makeOffer{value: _withFee(price * offerQuantity)}(
      address(token),
      tokenId,
      address(0),
      price,
      offerQuantity,
      0
    );

    assertEq(address(marketplace).balance, _withFee(price * offerQuantity));

    _mockSecondaryPayout(price, seller);
    vm.prank(seller);
    marketplace.acceptOffer(
      address(token),
      tokenId,
      buyer,
      address(0),
      price,
      1,
      _singleSplitRecipients(seller),
      _singleSplitRatios()
    );

    IRareERC1155MarketplaceTypes.Offer memory offer = marketplace.getOffer(address(token), tokenId, buyer, address(0));
    assertEq(offer.quantity, 2);
    assertEq(offer.initialQuantity, offerQuantity);
    assertEq(offer.marketplaceFeeRemaining, _fee(price * 2));
    assertEq(address(marketplace).balance, _withFee(price * 2));
    assertEq(token.balanceOf(buyer, tokenId), 1);
    assertEq(token.balanceOf(seller, tokenId), 2);

    _mockSecondaryPayout(price * 2, seller);
    vm.prank(seller);
    marketplace.acceptOffer(
      address(token),
      tokenId,
      buyer,
      address(0),
      price,
      2,
      _singleSplitRecipients(seller),
      _singleSplitRatios()
    );

    offer = marketplace.getOffer(address(token), tokenId, buyer, address(0));
    assertEq(offer.quantity, 0);
    assertEq(offer.initialQuantity, 0);
    assertEq(offer.marketplaceFeeRemaining, 0);
    assertEq(address(marketplace).balance, 0);
    assertEq(token.balanceOf(buyer, tokenId), offerQuantity);
    assertEq(token.balanceOf(seller, tokenId), 0);
  }

  function testListingQuantityConservationAcrossPartialFillsAndCancel() public {
    uint256 price = 1 ether;
    uint256 mintedQuantity = 5;
    uint256 listedQuantity = 4;

    vm.prank(seller);
    token.mintBatchTo(seller, _singleTokenIds(tokenId), _singleAmounts(mintedQuantity));

    vm.prank(seller);
    token.setApprovalForAll(address(erc1155ApprovalManager), true);

    vm.prank(seller);
    marketplace.setSalePrices(
      address(token),
      address(0),
      _singleSalePriceRequest(tokenId, price, listedQuantity),
      _singleSplitRecipients(seller),
      _singleSplitRatios()
    );

    _mockSecondaryPayout(price, seller);
    vm.prank(buyer);
    marketplace.buyBatch{value: _withFee(price)}(
      address(token),
      seller,
      address(0),
      _singleBuyRequest(tokenId, price, 1)
    );

    assertEq(marketplace.getSalePrice(address(token), tokenId, seller).quantity, listedQuantity - 1);
    assertEq(token.balanceOf(seller, tokenId), mintedQuantity - 1);
    assertEq(token.balanceOf(buyer, tokenId), 1);

    _mockSecondaryPayout(price * 2, seller);
    vm.prank(buyer);
    marketplace.buyBatch{value: _withFee(price * 2)}(
      address(token),
      seller,
      address(0),
      _singleBuyRequest(tokenId, price, 2)
    );

    assertEq(marketplace.getSalePrice(address(token), tokenId, seller).quantity, listedQuantity - 3);
    assertEq(token.balanceOf(seller, tokenId), mintedQuantity - 3);
    assertEq(token.balanceOf(buyer, tokenId), 3);

    vm.prank(seller);
    marketplace.cancelSalePrices(address(token), _singleTokenIds(tokenId));

    assertEq(marketplace.getSalePrice(address(token), tokenId, seller).quantity, 0);
    assertEq(token.balanceOf(seller, tokenId), mintedQuantity - 3);
    assertEq(token.balanceOf(buyer, tokenId), 3);
  }

  function testMintDirectSaleThroughTradeExecutionModule() public {
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
      address(token),
      address(0),
      _singleMintRequest(tokenId, price, quantity)
    );

    assertEq(token.balanceOf(buyer, tokenId), quantity);
    assertEq(marketplace.getTokenMintsPerAddress(address(token), tokenId, buyer), 0);
  }

  function testPrepareMintDirectSaleRejectsNonERC1155Contract() public {
    uint256 price = 1 ether;
    RejectETH invalidToken = new RejectETH();

    vm.prank(seller);
    vm.expectRevert(
      abi.encodeWithSelector(IRareERC1155MarketplaceTypes.InvalidERC1155Contract.selector, address(invalidToken))
    );
    marketplace.prepareMintDirectSales(
      address(invalidToken),
      address(0),
      _singleDirectSaleRequest(tokenId, price, 0, 0),
      _singleSplitRecipients(seller),
      _singleSplitRatios()
    );
  }

  function testCancelMintDirectSalesClearsDirectSaleConfig() public {
    uint256 price = 1 ether;

    vm.prank(seller);
    marketplace.prepareMintDirectSales(
      address(token),
      address(0),
      _singleDirectSaleRequest(tokenId, price, 0, 0),
      _singleSplitRecipients(seller),
      _singleSplitRatios()
    );

    vm.expectEmit(true, true, false, false);
    emit MintDirectSaleCancelled(address(token), tokenId);

    vm.prank(seller);
    marketplace.cancelMintDirectSales(address(token), _singleTokenIds(tokenId));

    IRareERC1155MarketplaceTypes.DirectSaleConfig memory config = marketplace.getDirectSaleConfig(
      address(token),
      tokenId
    );
    assertEq(config.seller, address(0));
    assertEq(config.currencyAddress, address(0));
    assertEq(config.price, 0);
    assertEq(config.startTime, 0);
    assertEq(config.maxMints, 0);
    assertEq(config.splitRecipients.length, 0);
    assertEq(config.splitRatios.length, 0);

    vm.prank(buyer);
    vm.expectRevert(
      abi.encodeWithSelector(IRareERC1155MarketplaceTypes.DirectSaleNotConfigured.selector, address(token), tokenId)
    );
    marketplace.mintDirectSaleBatch(address(token), address(0), _singleMintRequest(tokenId, price, 1));
  }

  function testCancelMintDirectSalesRejectsNonContractOwner() public {
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
    vm.expectRevert(
      abi.encodeWithSelector(IRareERC1155MarketplaceTypes.NotContractOwner.selector, address(token), buyer)
    );
    marketplace.cancelMintDirectSales(address(token), _singleTokenIds(tokenId));
  }

  function testCancelMintDirectSalesRevertsWhenOwnerReadReverts() public {
    uint256 price = 1 ether;
    uint256 revertingOwnerTokenId = 89;
    CheckoutToggleERC1155 revertingOwnerToken = new CheckoutToggleERC1155(seller);

    vm.prank(seller);
    marketplace.prepareMintDirectSales(
      address(revertingOwnerToken),
      address(0),
      _singleDirectSaleRequest(revertingOwnerTokenId, price, 0, 0),
      _singleSplitRecipients(seller),
      _singleSplitRatios()
    );
    revertingOwnerToken.setRevertOwner(true);

    vm.prank(seller);
    vm.expectRevert(
      abi.encodeWithSelector(IRareERC1155MarketplaceTypes.ContractHasNoOwner.selector, address(revertingOwnerToken))
    );
    marketplace.cancelMintDirectSales(address(revertingOwnerToken), _singleTokenIds(revertingOwnerTokenId));
  }

  function testMintDirectSaleRevertsWhenMintDoesNotIncreaseBuyerBalance() public {
    uint256 price = 1 ether;
    uint256 noOpTokenId = 91;
    uint256 quantity = 2;
    CheckoutNoOpMintERC1155 noOpToken = new CheckoutNoOpMintERC1155(seller);

    vm.prank(seller);
    marketplace.prepareMintDirectSales(
      address(noOpToken),
      address(0),
      _singleDirectSaleRequest(noOpTokenId, price, 0, 0),
      _singleSplitRecipients(seller),
      _singleSplitRatios()
    );
    _mockMarketplaceFee(price * quantity, seller);

    vm.prank(buyer);
    vm.expectRevert(
      abi.encodeWithSelector(
        IRareERC1155MarketplaceTypes.InvalidERC1155Mint.selector,
        address(noOpToken),
        noOpTokenId,
        buyer,
        quantity
      )
    );
    marketplace.mintDirectSaleBatch{value: _withFee(price * quantity)}(
      address(noOpToken),
      address(0),
      _singleMintRequest(noOpTokenId, price, quantity)
    );

    assertEq(noOpToken.balanceOf(buyer, noOpTokenId), 0);
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

    IRareERC1155MarketplaceTypes.MintRequest[] memory mintRequests = new IRareERC1155MarketplaceTypes.MintRequest[](76);
    vm.expectRevert(abi.encodeWithSelector(IRareERC1155MarketplaceTypes.BatchSizeExceeded.selector, 76, 75));
    marketplace.mintDirectSaleBatch(address(token), address(0), mintRequests);

    IRareERC1155MarketplaceTypes.CheckoutItem[] memory checkoutItems = new IRareERC1155MarketplaceTypes.CheckoutItem[](
      51
    );
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
    RareERC1155 otherToken = RareERC1155(
      tokenFactory.createRareERC1155Contract("Other Editions", "OED", "ipfs://other/{id}.json")
    );
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
    items[1] = _listingCheckoutItem(address(otherToken), sellerTwo, address(currency), otherTokenId, listingPrice, 1);

    uint256 buyerCurrencyBefore = currency.balanceOf(buyer);

    vm.prank(buyer);
    IRareERC1155MarketplaceTypes.CheckoutExecution memory execution = marketplace.checkout{value: _withFee(mintPrice)}(
      items
    );
    IRareERC1155MarketplaceTypes.CheckoutSummary memory summary = execution.summary;

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
    IRareERC1155MarketplaceTypes.CheckoutExecution memory execution = marketplace.checkout{value: _withFee(price)}(
      items
    );
    IRareERC1155MarketplaceTypes.CheckoutSummary memory summary = execution.summary;

    assertEq(summary.filledCount, 1);
    assertEq(summary.skippedCount, 0);
    assertEq(summary.ethSpent, _withFee(price));
    assertEq(token.balanceOf(buyer, tokenId), 1);
  }

  function testCheckoutAggregatesDirectSaleMaxMintsAcrossDuplicateItems() public {
    uint256 price = 1 ether;
    uint256 maxMints = 1;

    vm.prank(seller);
    uint256 limitedTokenId = token.createToken("ipfs://token/max-mints.json", 2, seller);

    vm.prank(seller);
    marketplace.prepareMintDirectSales(
      address(token),
      address(0),
      _singleDirectSaleRequest(limitedTokenId, price, 0, maxMints),
      _singleSplitRecipients(seller),
      _singleSplitRatios()
    );
    _mockPrimaryPayoutFor(address(token), price, seller);

    IRareERC1155MarketplaceTypes.CheckoutItem[] memory items = new IRareERC1155MarketplaceTypes.CheckoutItem[](2);
    items[0] = _directSaleCheckoutItem(address(token), seller, address(0), limitedTokenId, price, 1);
    items[1] = _directSaleCheckoutItem(address(token), seller, address(0), limitedTokenId, price, 1);

    vm.prank(buyer);
    IRareERC1155MarketplaceTypes.CheckoutExecution memory execution = marketplace.checkout{value: _withFee(price) * 2}(
      items
    );
    IRareERC1155MarketplaceTypes.CheckoutSummary memory summary = execution.summary;

    assertEq(summary.filledCount, 1);
    assertEq(summary.skippedCount, 1);
    assertEq(summary.ethSpent, _withFee(price));
    assertEq(summary.ethRefunded, _withFee(price));
    assertEq(token.balanceOf(buyer, limitedTokenId), 1);
    assertTrue(execution.items[0].filled);
    _assertSkipped(
      execution.items[1],
      IRareERC1155MarketplaceTypes.CheckoutFailureStage.VALIDATION,
      IRareERC1155MarketplaceTypes.MaxMintExceeded.selector
    );
    assertEq(
      execution.items[1].failureData,
      abi.encodeWithSelector(IRareERC1155MarketplaceTypes.MaxMintExceeded.selector, 2, maxMints)
    );
  }

  function testCheckoutCountsDuplicateDirectSaleItemsAsOneTransactionLimitUse() public {
    uint256 price = 1 ether;

    vm.startPrank(seller);
    marketplace.prepareMintDirectSales(
      address(token),
      address(0),
      _singleDirectSaleRequest(tokenId, price, 0, 0),
      _singleSplitRecipients(seller),
      _singleSplitRatios()
    );
    marketplace.setTokenMintLimits(address(token), _singleTokenLimitRequest(tokenId, 2));
    marketplace.setTokenTxLimits(address(token), _singleTokenLimitRequest(tokenId, 1));
    vm.stopPrank();
    _mockPrimaryPayoutFor(address(token), price, seller);

    IRareERC1155MarketplaceTypes.CheckoutItem[] memory items = new IRareERC1155MarketplaceTypes.CheckoutItem[](2);
    items[0] = _directSaleCheckoutItem(address(token), seller, address(0), tokenId, price, 1);
    items[1] = _directSaleCheckoutItem(address(token), seller, address(0), tokenId, price, 1);

    vm.prank(buyer);
    IRareERC1155MarketplaceTypes.CheckoutExecution memory execution = marketplace.checkout{value: _withFee(price) * 2}(
      items
    );
    IRareERC1155MarketplaceTypes.CheckoutSummary memory summary = execution.summary;

    assertEq(summary.filledCount, 2);
    assertEq(summary.skippedCount, 0);
    assertEq(summary.ethSpent, _withFee(price) * 2);
    assertEq(summary.ethRefunded, 0);
    assertEq(token.balanceOf(buyer, tokenId), 2);
    assertTrue(execution.items[0].filled);
    assertTrue(execution.items[1].filled);
    assertEq(marketplace.getTokenMintsPerAddress(address(token), tokenId, buyer), 2);
    assertEq(marketplace.getTokenTxsPerAddress(address(token), tokenId, buyer), 1);
  }

  function testCheckoutCannotDoubleFillSingleUnitListingInSameCart() public {
    uint256 price = 1 ether;

    vm.startPrank(seller);
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
    items[0] = _listingCheckoutItem(address(token), seller, address(0), tokenId, price, 1);
    items[1] = _listingCheckoutItem(address(token), seller, address(0), tokenId, price, 1);

    vm.prank(buyer);
    IRareERC1155MarketplaceTypes.CheckoutExecution memory execution = marketplace.checkout{value: _withFee(price) * 2}(
      items
    );
    IRareERC1155MarketplaceTypes.CheckoutSummary memory summary = execution.summary;

    assertEq(summary.filledCount, 1);
    assertEq(summary.skippedCount, 1);
    assertEq(summary.ethSpent, _withFee(price));
    assertEq(summary.ethRefunded, _withFee(price));
    assertTrue(execution.items[0].filled);
    _assertSkipped(
      execution.items[1],
      IRareERC1155MarketplaceTypes.CheckoutFailureStage.VALIDATION,
      IRareERC1155MarketplaceTypes.SalePriceDoesNotExist.selector
    );
    assertEq(token.balanceOf(buyer, tokenId), 1);
    assertEq(token.balanceOf(seller, tokenId), 0);
    assertEq(marketplace.getSalePrice(address(token), tokenId, seller).quantity, 0);
    assertEq(address(marketplace).balance, 0);
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
    IRareERC1155MarketplaceTypes.CheckoutExecution memory execution = marketplace.checkout{
      value: _withFee(mintPrice) + refundAmount
    }(items);
    IRareERC1155MarketplaceTypes.CheckoutSummary memory summary = execution.summary;

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
    IRareERC1155MarketplaceTypes.CheckoutExecution memory execution = marketplace.checkout{value: _withFee(price)}(
      items
    );
    IRareERC1155MarketplaceTypes.CheckoutSummary memory summary = execution.summary;

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
    IRareERC1155MarketplaceTypes.CheckoutExecution memory execution = marketplace.checkout{value: _withFee(price)}(
      items
    );
    IRareERC1155MarketplaceTypes.CheckoutSummary memory summary = execution.summary;

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
        allowlistTokenId,
        keccak256(abi.encodePacked(address(0xdead))),
        block.timestamp + 1 days
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
    IRareERC1155MarketplaceTypes.CheckoutExecution memory execution = marketplace.checkout{value: _withFee(price)}(
      items
    );
    IRareERC1155MarketplaceTypes.CheckoutSummary memory summary = execution.summary;

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
    IRareERC1155MarketplaceTypes.CheckoutExecution memory execution = marketplace.checkout{value: _withFee(mintPrice)}(
      items
    );
    IRareERC1155MarketplaceTypes.CheckoutSummary memory summary = execution.summary;

    assertEq(summary.filledCount, 1);
    assertEq(summary.skippedCount, 1);
    assertEq(summary.ethSpent, _withFee(mintPrice));
    assertEq(currency.balanceOf(buyer), buyerCurrencyBefore);
    assertEq(token.balanceOf(buyer, listedTokenId), 0);
    assertEq(token.balanceOf(seller, listedTokenId), 1);
    assertEq(marketplace.getSalePrice(address(token), listedTokenId, seller).quantity, 1);
    assertEq(token.balanceOf(buyer, tokenId), 1);
  }

  function testCheckoutFreeEthDirectSalePaysZeroAndSkipsPayout() public {
    vm.prank(seller);
    marketplace.prepareMintDirectSales(
      address(token),
      address(0),
      _singleDirectSaleRequest(tokenId, 0, 0, 0),
      _singleSplitRecipients(seller),
      _singleSplitRatios()
    );

    IRareERC1155MarketplaceTypes.CheckoutItem[] memory items = new IRareERC1155MarketplaceTypes.CheckoutItem[](1);
    items[0] = _directSaleCheckoutItem(address(token), seller, address(0), tokenId, 0, 1);

    vm.expectCall(
      marketplaceSettings,
      abi.encodeWithSelector(IMarketplaceSettings.calculateMarketplaceFee.selector, uint256(0)),
      uint64(0)
    );
    vm.prank(buyer);
    IRareERC1155MarketplaceTypes.CheckoutExecution memory execution = marketplace.checkout{value: 0}(items);

    assertEq(execution.summary.filledCount, 1);
    assertEq(execution.summary.skippedCount, 0);
    assertEq(execution.summary.ethSpent, 0);
    assertEq(execution.summary.ethRefunded, 0);
    assertEq(execution.items[0].totalPaid, 0);
    assertEq(token.balanceOf(buyer, tokenId), 1);
    assertEq(address(marketplace).balance, 0);
  }

  function testCheckoutFreeERC20DirectSalePaysZeroAndSkipsPayout() public {
    _mockApprovedCurrency(address(currency));
    vm.prank(seller);
    marketplace.prepareMintDirectSales(
      address(token),
      address(currency),
      _singleDirectSaleRequest(tokenId, 0, 0, 0),
      _singleSplitRecipients(seller),
      _singleSplitRatios()
    );

    vm.prank(buyer);
    currency.approve(address(erc20ApprovalManager), 1 ether);

    IRareERC1155MarketplaceTypes.CheckoutItem[] memory items = new IRareERC1155MarketplaceTypes.CheckoutItem[](1);
    items[0] = _directSaleCheckoutItem(address(token), seller, address(currency), tokenId, 0, 1);

    uint256 buyerCurrencyBefore = currency.balanceOf(buyer);
    uint256 buyerAllowanceBefore = currency.allowance(buyer, address(erc20ApprovalManager));

    vm.expectCall(
      address(erc20ApprovalManager),
      abi.encodeWithSelector(
        ERC20ApprovalManager.transferFrom.selector,
        address(currency),
        buyer,
        address(marketplace),
        0
      ),
      uint64(0)
    );
    vm.prank(buyer);
    IRareERC1155MarketplaceTypes.CheckoutExecution memory execution = marketplace.checkout{value: 0}(items);

    assertEq(execution.summary.filledCount, 1);
    assertEq(execution.summary.skippedCount, 0);
    assertEq(execution.summary.ethSpent, 0);
    assertEq(execution.summary.ethRefunded, 0);
    assertEq(execution.items[0].totalPaid, 0);
    assertEq(currency.balanceOf(buyer), buyerCurrencyBefore);
    assertEq(currency.allowance(buyer, address(erc20ApprovalManager)), buyerAllowanceBefore);
    assertEq(currency.balanceOf(address(marketplace)), 0);
    assertEq(token.balanceOf(buyer, tokenId), 1);
  }

  function testCheckoutMixedFreeAndPaidEthDirectSalesConservesETH() public {
    uint256 paidPrice = 1 ether;

    vm.prank(seller);
    uint256 paidTokenId = token.createToken("ipfs://token/paid-direct-sale.json", 20, seller);

    vm.startPrank(seller);
    marketplace.prepareMintDirectSales(
      address(token),
      address(0),
      _singleDirectSaleRequest(tokenId, 0, 0, 0),
      _singleSplitRecipients(seller),
      _singleSplitRatios()
    );
    marketplace.prepareMintDirectSales(
      address(token),
      address(0),
      _singleDirectSaleRequest(paidTokenId, paidPrice, 0, 0),
      _singleSplitRecipients(seller),
      _singleSplitRatios()
    );
    vm.stopPrank();
    _mockPrimaryPayoutFor(address(token), paidPrice, seller);

    IRareERC1155MarketplaceTypes.CheckoutItem[] memory items = new IRareERC1155MarketplaceTypes.CheckoutItem[](2);
    items[0] = _directSaleCheckoutItem(address(token), seller, address(0), tokenId, 0, 1);
    items[1] = _directSaleCheckoutItem(address(token), seller, address(0), paidTokenId, paidPrice, 1);

    uint256 buyerBalanceBefore = buyer.balance;
    uint256 sellerBalanceBefore = seller.balance;
    uint256 networkBalanceBefore = networkBeneficiary.balance;
    uint256 rewardBalanceBefore = rewardAccumulator.balance;

    vm.prank(buyer);
    IRareERC1155MarketplaceTypes.CheckoutExecution memory execution = marketplace.checkout{value: _withFee(paidPrice)}(
      items
    );

    assertEq(execution.summary.filledCount, 2);
    assertEq(execution.summary.skippedCount, 0);
    assertEq(execution.summary.ethSpent, _withFee(paidPrice));
    assertEq(execution.summary.ethRefunded, 0);
    assertEq(execution.items[0].totalPaid, 0);
    assertEq(execution.items[1].totalPaid, _withFee(paidPrice));
    assertEq(buyer.balance, buyerBalanceBefore - _withFee(paidPrice));
    assertEq(seller.balance, sellerBalanceBefore + ((paidPrice * 90) / 100));
    assertEq(networkBeneficiary.balance, networkBalanceBefore + ((paidPrice * 13) / 100));
    assertEq(rewardAccumulator.balance, rewardBalanceBefore);
    assertEq(token.balanceOf(buyer, tokenId), 1);
    assertEq(token.balanceOf(buyer, paidTokenId), 1);
    assertEq(address(marketplace).balance, 0);
  }

  function testCheckoutSucceedsWhenEveryItemIsSkipped() public {
    IRareERC1155MarketplaceTypes.CheckoutItem[] memory items = new IRareERC1155MarketplaceTypes.CheckoutItem[](1);
    items[0] = _unsupportedCheckoutItem();

    vm.prank(buyer);
    IRareERC1155MarketplaceTypes.CheckoutExecution memory execution = marketplace.checkout(items);

    assertEq(execution.summary.filledCount, 0);
    assertEq(execution.summary.skippedCount, 1);
    assertEq(execution.items.length, 1);
    assertEq(
      uint8(execution.items[0].failureStage),
      uint8(IRareERC1155MarketplaceTypes.CheckoutFailureStage.VALIDATION)
    );
    assertEq(execution.items[0].reason, IRareERC1155MarketplaceTypes.UnsupportedCheckoutItemKind.selector);
    assertEq(
      execution.items[0].failureData,
      abi.encodeWithSelector(IRareERC1155MarketplaceTypes.UnsupportedCheckoutItemKind.selector, items[0].itemKind)
    );
  }

  function testCheckoutSucceedsWhenEveryERC20ItemIsSkippedWithoutPullingFunds() public {
    uint256 price = 1 ether;

    vm.prank(seller);
    token.mintBatchTo(seller, _singleTokenIds(tokenId), _singleAmounts(1));

    vm.prank(seller);
    token.setApprovalForAll(address(erc1155ApprovalManager), true);

    _mockApprovedCurrency(address(currency));
    vm.prank(seller);
    marketplace.setSalePrices(
      address(token),
      address(currency),
      _singleSalePriceRequest(tokenId, price, 1),
      _singleSplitRecipients(seller),
      _singleSplitRatios()
    );

    vm.clearMockedCalls();
    vm.mockCall(
      approvedTokenRegistry,
      abi.encodeWithSelector(IApprovedTokenRegistry.isApprovedToken.selector, address(currency)),
      abi.encode(false)
    );

    vm.prank(buyer);
    currency.approve(address(erc20ApprovalManager), _withFee(price));

    IRareERC1155MarketplaceTypes.CheckoutItem[] memory items = new IRareERC1155MarketplaceTypes.CheckoutItem[](1);
    items[0] = _listingCheckoutItem(address(token), seller, address(currency), tokenId, price, 1);

    uint256 buyerCurrencyBefore = currency.balanceOf(buyer);
    uint256 buyerAllowanceBefore = currency.allowance(buyer, address(erc20ApprovalManager));

    vm.expectCall(
      address(erc20ApprovalManager),
      abi.encodeWithSelector(
        ERC20ApprovalManager.transferFrom.selector,
        address(currency),
        buyer,
        address(marketplace),
        _withFee(price)
      ),
      uint64(0)
    );

    vm.prank(buyer);
    IRareERC1155MarketplaceTypes.CheckoutExecution memory execution = marketplace.checkout(items);

    assertEq(execution.summary.filledCount, 0);
    assertEq(execution.summary.skippedCount, 1);
    assertEq(execution.summary.ethSpent, 0);
    assertEq(execution.summary.ethRefunded, 0);
    assertEq(currency.balanceOf(buyer), buyerCurrencyBefore);
    assertEq(currency.allowance(buyer, address(erc20ApprovalManager)), buyerAllowanceBefore);
    assertEq(currency.balanceOf(address(marketplace)), 0);
    assertEq(token.balanceOf(buyer, tokenId), 0);
    assertEq(token.balanceOf(seller, tokenId), 1);
    assertEq(marketplace.getSalePrice(address(token), tokenId, seller).quantity, 1);
    _assertSkipped(
      execution.items[0],
      IRareERC1155MarketplaceTypes.CheckoutFailureStage.VALIDATION,
      IRareERC1155MarketplaceTypes.CurrencyNotApproved.selector
    );
  }

  function testCheckoutSkipsListingWhenCurrencyIsNoLongerApproved() public {
    uint256 price = 1 ether;

    vm.prank(seller);
    token.mintBatchTo(seller, _singleTokenIds(tokenId), _singleAmounts(1));

    vm.prank(seller);
    token.setApprovalForAll(address(erc1155ApprovalManager), true);

    _mockApprovedCurrency(address(currency));
    vm.prank(seller);
    marketplace.setSalePrices(
      address(token),
      address(currency),
      _singleSalePriceRequest(tokenId, price, 1),
      _singleSplitRecipients(seller),
      _singleSplitRatios()
    );

    vm.clearMockedCalls();
    vm.mockCall(
      approvedTokenRegistry,
      abi.encodeWithSelector(IApprovedTokenRegistry.isApprovedToken.selector, address(currency)),
      abi.encode(false)
    );

    vm.prank(buyer);
    currency.approve(address(erc20ApprovalManager), _withFee(price));

    IRareERC1155MarketplaceTypes.CheckoutItem[] memory items = new IRareERC1155MarketplaceTypes.CheckoutItem[](1);
    items[0] = _listingCheckoutItem(address(token), seller, address(currency), tokenId, price, 1);

    uint256 buyerCurrencyBefore = currency.balanceOf(buyer);

    vm.prank(buyer);
    IRareERC1155MarketplaceTypes.CheckoutExecution memory execution = marketplace.checkout(items);

    assertEq(execution.summary.filledCount, 0);
    assertEq(execution.summary.skippedCount, 1);
    assertEq(currency.balanceOf(buyer), buyerCurrencyBefore);
    assertEq(token.balanceOf(buyer, tokenId), 0);
    assertEq(token.balanceOf(seller, tokenId), 1);
    assertEq(marketplace.getSalePrice(address(token), tokenId, seller).quantity, 1);
    _assertSkipped(
      execution.items[0],
      IRareERC1155MarketplaceTypes.CheckoutFailureStage.VALIDATION,
      IRareERC1155MarketplaceTypes.CurrencyNotApproved.selector
    );
    assertEq(
      execution.items[0].failureData,
      abi.encodeWithSelector(IRareERC1155MarketplaceTypes.CurrencyNotApproved.selector, address(currency))
    );
  }

  function testCheckoutSkipsTransferFailure() public {
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
    IRareERC1155MarketplaceTypes.CheckoutExecution memory execution = marketplace.checkout{value: _withFee(price)}(
      items
    );

    assertEq(execution.summary.filledCount, 0);
    assertEq(execution.summary.skippedCount, 1);
    assertEq(execution.summary.ethSpent, 0);
    assertEq(execution.summary.ethRefunded, _withFee(price));
    assertEq(uint8(execution.items[0].failureStage), uint8(IRareERC1155MarketplaceTypes.CheckoutFailureStage.TRANSFER));
    assertEq(execution.items[0].reason, IRareERC1155MarketplaceTypes.InvalidERC1155Transfer.selector);
    assertEq(
      execution.items[0].failureData,
      abi.encodeWithSelector(
        IRareERC1155MarketplaceTypes.InvalidERC1155Transfer.selector,
        address(brokenToken),
        brokenTokenId,
        seller,
        buyer,
        1
      )
    );

    assertEq(brokenToken.balanceOf(seller, brokenTokenId), 1);
    assertEq(brokenToken.balanceOf(buyer, brokenTokenId), 0);
    assertEq(marketplace.getSalePrice(address(brokenToken), brokenTokenId, seller).quantity, 1);
  }

  function testCheckoutSkipsDirectSaleMintWhenMintDoesNotIncreaseBuyerBalance() public {
    uint256 price = 1 ether;
    uint256 noOpTokenId = 92;
    CheckoutNoOpMintERC1155 noOpToken = new CheckoutNoOpMintERC1155(seller);

    vm.prank(seller);
    marketplace.prepareMintDirectSales(
      address(noOpToken),
      address(0),
      _singleDirectSaleRequest(noOpTokenId, price, 0, 0),
      _singleSplitRecipients(seller),
      _singleSplitRatios()
    );
    _mockMarketplaceFee(price, seller);

    IRareERC1155MarketplaceTypes.CheckoutItem[] memory items = new IRareERC1155MarketplaceTypes.CheckoutItem[](1);
    items[0] = _directSaleCheckoutItem(address(noOpToken), seller, address(0), noOpTokenId, price, 1);

    vm.prank(buyer);
    IRareERC1155MarketplaceTypes.CheckoutExecution memory execution = marketplace.checkout{value: _withFee(price)}(
      items
    );

    assertEq(execution.summary.filledCount, 0);
    assertEq(execution.summary.skippedCount, 1);
    assertEq(execution.summary.ethSpent, 0);
    assertEq(execution.summary.ethRefunded, _withFee(price));
    _assertSkipped(
      execution.items[0],
      IRareERC1155MarketplaceTypes.CheckoutFailureStage.MINT,
      IRareERC1155MarketplaceTypes.InvalidERC1155Mint.selector
    );
    assertEq(
      execution.items[0].failureData,
      abi.encodeWithSelector(
        IRareERC1155MarketplaceTypes.InvalidERC1155Mint.selector,
        address(noOpToken),
        noOpTokenId,
        buyer,
        1
      )
    );
    assertEq(noOpToken.balanceOf(buyer, noOpTokenId), 0);
  }

  function testCheckoutValidationRevertsBecomeValidationSkipsAndContinue() public {
    uint256 price = 1 ether;
    uint256 ownerRevertTokenId = 101;
    uint256 supportsRevertTokenId = 102;
    uint256 approvalRevertTokenId = 103;
    uint256 balanceRevertTokenId = 104;

    CheckoutToggleERC1155 ownerRevertToken = new CheckoutToggleERC1155(seller);
    vm.prank(seller);
    marketplace.prepareMintDirectSales(
      address(ownerRevertToken),
      address(0),
      _singleDirectSaleRequest(ownerRevertTokenId, price, 0, 0),
      _singleSplitRecipients(seller),
      _singleSplitRatios()
    );
    ownerRevertToken.setRevertOwner(true);

    CheckoutToggleERC1155 supportsRevertToken = _listedToggleToken(supportsRevertTokenId, price);
    supportsRevertToken.setRevertSupportsInterface(true);

    CheckoutToggleERC1155 approvalRevertToken = _listedToggleToken(approvalRevertTokenId, price);
    approvalRevertToken.setRevertApproval(true);

    CheckoutToggleERC1155 balanceRevertToken = _listedToggleToken(balanceRevertTokenId, price);
    balanceRevertToken.setRevertBalance(true);

    vm.prank(seller);
    marketplace.prepareMintDirectSales(
      address(token),
      address(0),
      _singleDirectSaleRequest(tokenId, price, 0, 0),
      _singleSplitRecipients(seller),
      _singleSplitRatios()
    );
    _mockPrimaryPayoutFor(address(token), price, seller);

    IRareERC1155MarketplaceTypes.CheckoutItem[] memory items = new IRareERC1155MarketplaceTypes.CheckoutItem[](5);
    items[0] = _directSaleCheckoutItem(address(ownerRevertToken), seller, address(0), ownerRevertTokenId, price, 1);
    items[1] = _listingCheckoutItem(address(supportsRevertToken), seller, address(0), supportsRevertTokenId, price, 1);
    items[2] = _listingCheckoutItem(address(approvalRevertToken), seller, address(0), approvalRevertTokenId, price, 1);
    items[3] = _listingCheckoutItem(address(balanceRevertToken), seller, address(0), balanceRevertTokenId, price, 1);
    items[4] = _directSaleCheckoutItem(address(token), seller, address(0), tokenId, price, 1);

    vm.prank(buyer);
    IRareERC1155MarketplaceTypes.CheckoutExecution memory execution = marketplace.checkout{value: _withFee(price)}(
      items
    );

    assertEq(execution.summary.filledCount, 1);
    assertEq(execution.summary.skippedCount, 4);
    assertEq(token.balanceOf(buyer, tokenId), 1);
    _assertSkipped(
      execution.items[0],
      IRareERC1155MarketplaceTypes.CheckoutFailureStage.VALIDATION,
      IRareERC1155MarketplaceTypes.ContractHasNoOwner.selector
    );
    _assertSkipped(
      execution.items[1],
      IRareERC1155MarketplaceTypes.CheckoutFailureStage.VALIDATION,
      IRareERC1155MarketplaceTypes.InvalidERC1155Contract.selector
    );
    _assertSkipped(
      execution.items[2],
      IRareERC1155MarketplaceTypes.CheckoutFailureStage.VALIDATION,
      IRareERC1155MarketplaceTypes.MarketplaceNotApproved.selector
    );
    _assertSkipped(
      execution.items[3],
      IRareERC1155MarketplaceTypes.CheckoutFailureStage.VALIDATION,
      IRareERC1155MarketplaceTypes.InsufficientTokenBalance.selector
    );
    assertTrue(execution.items[4].filled);
  }

  function testCheckoutSkipsPayoutFailureAndContinues() public {
    uint256 price = 1 ether;
    uint256 primaryTokenId;

    vm.startPrank(seller);
    token.mintBatchTo(seller, _singleTokenIds(tokenId), _singleAmounts(1));
    token.setApprovalForAll(address(erc1155ApprovalManager), true);
    marketplace.setSalePrices(
      address(token),
      address(0),
      _singleSalePriceRequest(tokenId, price, 1),
      _singleSplitRecipients(seller),
      _singleSplitRatios()
    );
    primaryTokenId = token.createToken("ipfs://token/primary-after-payout-fail.json", 20, seller);
    marketplace.prepareMintDirectSales(
      address(token),
      address(0),
      _singleDirectSaleRequest(primaryTokenId, price, 0, 0),
      _singleSplitRecipients(seller),
      _singleSplitRatios()
    );
    vm.stopPrank();

    _mockMarketplaceFee(price, seller);
    _mockPrimaryPayoutFor(address(token), price, seller);
    bytes memory royaltyRevertData = abi.encodeWithSignature("Error(string)", "royalty failed");
    vm.mockCallRevert(
      royaltyEngine,
      abi.encodeWithSelector(IRoyaltyEngineV1.getRoyalty.selector, address(token), tokenId, price),
      royaltyRevertData
    );

    IRareERC1155MarketplaceTypes.CheckoutItem[] memory items = new IRareERC1155MarketplaceTypes.CheckoutItem[](2);
    items[0] = _listingCheckoutItem(address(token), seller, address(0), tokenId, price, 1);
    items[1] = _directSaleCheckoutItem(address(token), seller, address(0), primaryTokenId, price, 1);

    vm.prank(buyer);
    IRareERC1155MarketplaceTypes.CheckoutExecution memory execution = marketplace.checkout{value: _withFee(price)}(
      items
    );

    assertEq(execution.summary.filledCount, 1);
    assertEq(execution.summary.skippedCount, 1);
    assertEq(token.balanceOf(buyer, tokenId), 0);
    assertEq(token.balanceOf(buyer, primaryTokenId), 1);
    assertEq(marketplace.getSalePrice(address(token), tokenId, seller).quantity, 1);
    _assertSkipped(execution.items[0], IRareERC1155MarketplaceTypes.CheckoutFailureStage.PAYOUT, bytes4(0x08c379a0));
    assertEq(execution.items[0].failureData, royaltyRevertData);
    assertTrue(execution.items[1].filled);
  }

  function testCheckoutPayoutFailureCannotSpoofFailureStage() public {
    uint256 price = 1 ether;
    bytes memory spoofedPayoutRevertData = abi.encodeWithSelector(
      IRareERC1155MarketplaceTypes.CheckoutItemExecutionFailed.selector,
      IRareERC1155MarketplaceTypes.CheckoutFailureStage.VALIDATION,
      abi.encodeWithSelector(IRareERC1155MarketplaceTypes.PriceMismatch.selector, price + 1, price)
    );

    vm.startPrank(seller);
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

    _mockMarketplaceFee(price, seller);
    vm.mockCallRevert(
      royaltyEngine,
      abi.encodeWithSelector(IRoyaltyEngineV1.getRoyalty.selector, address(token), tokenId, price),
      spoofedPayoutRevertData
    );

    IRareERC1155MarketplaceTypes.CheckoutItem[] memory items = new IRareERC1155MarketplaceTypes.CheckoutItem[](1);
    items[0] = _listingCheckoutItem(address(token), seller, address(0), tokenId, price, 1);

    vm.prank(buyer);
    IRareERC1155MarketplaceTypes.CheckoutExecution memory execution = marketplace.checkout{value: _withFee(price)}(
      items
    );

    assertEq(execution.summary.filledCount, 0);
    assertEq(execution.summary.skippedCount, 1);
    assertEq(execution.summary.ethSpent, 0);
    assertEq(execution.summary.ethRefunded, _withFee(price));
    assertEq(token.balanceOf(buyer, tokenId), 0);
    assertEq(token.balanceOf(seller, tokenId), 1);
    assertEq(marketplace.getSalePrice(address(token), tokenId, seller).quantity, 1);
    _assertSkipped(
      execution.items[0],
      IRareERC1155MarketplaceTypes.CheckoutFailureStage.PAYOUT,
      IRareERC1155MarketplaceTypes.CheckoutItemExecutionFailed.selector
    );
    assertEq(execution.items[0].failureData, spoofedPayoutRevertData);
  }

  function testCheckoutExecutionFailureDecodesStructuredStage() public {
    CheckoutFailureDecoderHarness harness = new CheckoutFailureDecoderHarness();
    bytes memory mintFailureData = abi.encodeWithSelector(
      IRareERC1155MarketplaceTypes.InvalidERC1155Mint.selector,
      address(token),
      tokenId,
      buyer,
      1
    );
    bytes memory revertData = abi.encodeWithSelector(
      IRareERC1155MarketplaceTypes.CheckoutItemExecutionFailed.selector,
      IRareERC1155MarketplaceTypes.CheckoutFailureStage.MINT,
      mintFailureData
    );

    (IRareERC1155MarketplaceTypes.CheckoutFailureStage stage, bytes memory failureData) = harness
      .checkoutExecutionFailure(revertData);

    assertEq(uint8(stage), uint8(IRareERC1155MarketplaceTypes.CheckoutFailureStage.MINT));
    assertEq(failureData, mintFailureData);
  }

  function testCheckoutExecutionFailureFallsBackToUnknownForRawRevertData() public {
    bytes memory revertData = abi.encodeWithSignature("Error(string)", "unexpected failure");

    _assertUnknownCheckoutFailure(revertData);
  }

  function testCheckoutExecutionFailureFallsBackToUnknownForMalformedStructuredPayloads() public {
    bytes memory shortPayload = abi.encodePacked(
      IRareERC1155MarketplaceTypes.CheckoutItemExecutionFailed.selector,
      bytes32(uint256(uint8(IRareERC1155MarketplaceTypes.CheckoutFailureStage.PAYOUT)))
    );
    _assertUnknownCheckoutFailure(shortPayload);

    bytes memory invalidStagePayload = abi.encodeWithSelector(
      IRareERC1155MarketplaceTypes.CheckoutItemExecutionFailed.selector,
      uint256(255),
      bytes("stage")
    );
    _assertUnknownCheckoutFailure(invalidStagePayload);

    bytes memory invalidOffsetPayload = abi.encodePacked(
      IRareERC1155MarketplaceTypes.CheckoutItemExecutionFailed.selector,
      bytes32(uint256(uint8(IRareERC1155MarketplaceTypes.CheckoutFailureStage.PAYOUT))),
      bytes32(uint256(96)),
      bytes32(uint256(0))
    );
    _assertUnknownCheckoutFailure(invalidOffsetPayload);

    bytes memory invalidLengthPayload = abi.encodePacked(
      IRareERC1155MarketplaceTypes.CheckoutItemExecutionFailed.selector,
      bytes32(uint256(uint8(IRareERC1155MarketplaceTypes.CheckoutFailureStage.PAYOUT))),
      bytes32(uint256(64)),
      bytes32(uint256(1))
    );
    _assertUnknownCheckoutFailure(invalidLengthPayload);
  }

  function testCheckoutEthRecipientRejectionEscrowsInPayments() public {
    uint256 price = 1 ether;
    RejectETH rejectRecipient = new RejectETH();
    address payable[] memory splitRecipients = new address payable[](1);
    splitRecipients[0] = payable(address(rejectRecipient));

    vm.prank(seller);
    marketplace.prepareMintDirectSales(
      address(token),
      address(0),
      _singleDirectSaleRequest(tokenId, price, 0, 0),
      splitRecipients,
      _singleSplitRatios()
    );
    _mockPrimaryPayoutFor(address(token), price, seller);

    IRareERC1155MarketplaceTypes.CheckoutItem[] memory items = new IRareERC1155MarketplaceTypes.CheckoutItem[](1);
    items[0] = _directSaleCheckoutItem(address(token), seller, address(0), tokenId, price, 1);

    vm.prank(buyer);
    IRareERC1155MarketplaceTypes.CheckoutExecution memory execution = marketplace.checkout{value: _withFee(price)}(
      items
    );

    assertEq(execution.summary.filledCount, 1);
    assertEq(execution.summary.skippedCount, 0);
    assertEq(token.balanceOf(buyer, tokenId), 1);
    assertEq(payments.payments(address(rejectRecipient)), price - ((price * 10) / 100));
  }

  function testCheckoutItemExecutionKeepsMarketplaceReentrancyGuard() public {
    uint256 price = 1 ether;
    uint256 reentrantTokenId = 77;
    CheckoutReentrantERC1155 reentrantToken = new CheckoutReentrantERC1155(seller, marketplace);

    vm.prank(seller);
    marketplace.prepareMintDirectSales(
      address(reentrantToken),
      address(0),
      _singleDirectSaleRequest(reentrantTokenId, price, 0, 0),
      _singleSplitRecipients(seller),
      _singleSplitRatios()
    );
    _mockPrimaryPayoutFor(address(reentrantToken), price, seller);

    IRareERC1155MarketplaceTypes.CheckoutItem[] memory items = new IRareERC1155MarketplaceTypes.CheckoutItem[](1);
    items[0] = _directSaleCheckoutItem(address(reentrantToken), seller, address(0), reentrantTokenId, price, 1);

    vm.prank(buyer);
    IRareERC1155MarketplaceTypes.CheckoutExecution memory execution = marketplace.checkout{value: _withFee(price)}(
      items
    );

    assertEq(execution.summary.filledCount, 1);
    assertTrue(reentrantToken.reentryBlocked());
    assertEq(reentrantToken.balanceOf(buyer, reentrantTokenId), 1);
  }

  function testCheckoutDirectSaleMintCollectsERC20BeforeMint() public {
    uint256 price = 1 ether;
    uint256 observedTokenId = 78;
    CheckoutPaymentObservingERC1155 observingToken = new CheckoutPaymentObservingERC1155(
      seller,
      currency,
      address(marketplace)
    );

    _mockApprovedCurrency(address(currency));
    vm.prank(seller);
    marketplace.prepareMintDirectSales(
      address(observingToken),
      address(currency),
      _singleDirectSaleRequest(observedTokenId, price, 0, 0),
      _singleSplitRecipients(seller),
      _singleSplitRatios()
    );
    _mockPrimaryPayoutFor(address(observingToken), price, seller);

    vm.prank(buyer);
    currency.approve(address(erc20ApprovalManager), _withFee(price));

    IRareERC1155MarketplaceTypes.CheckoutItem[] memory items = new IRareERC1155MarketplaceTypes.CheckoutItem[](1);
    items[0] = _directSaleCheckoutItem(address(observingToken), seller, address(currency), observedTokenId, price, 1);

    vm.prank(buyer);
    IRareERC1155MarketplaceTypes.CheckoutExecution memory execution = marketplace.checkout(items);

    assertEq(execution.summary.filledCount, 1);
    assertEq(observingToken.marketplaceCurrencyBalanceAtMint(), _withFee(price));
    assertEq(observingToken.balanceOf(buyer, observedTokenId), 1);
    assertEq(currency.balanceOf(address(marketplace)), 0);
  }

  function testDirectCallsToExecutionModulesRevert() public {
    IRareERC1155MarketplaceTypes.BuyRequest[] memory requests = new IRareERC1155MarketplaceTypes.BuyRequest[](1);
    requests[0] = IRareERC1155MarketplaceTypes.BuyRequest(tokenId, 1 ether, 1);

    vm.expectRevert(IRareERC1155MarketplaceTypes.DirectModuleCallUnsupported.selector);
    tradeExecutionModule.buyBatch(address(token), seller, address(0), requests);

    IRareERC1155MarketplaceTypes.CheckoutItem[] memory items = new IRareERC1155MarketplaceTypes.CheckoutItem[](0);

    vm.expectRevert(IRareERC1155MarketplaceTypes.DirectModuleCallUnsupported.selector);
    checkoutExecutionModule.checkout(items);

    vm.expectRevert(IRareERC1155MarketplaceTypes.DirectModuleCallUnsupported.selector);
    checkoutExecutionModule.executeCheckoutItem(
      _unsupportedCheckoutItem(),
      0,
      address(0),
      0,
      0,
      new address payable[](0),
      new uint8[](0)
    );

    vm.expectRevert(IRareERC1155MarketplaceTypes.DirectModuleCallUnsupported.selector);
    checkoutExecutionModule.executeCheckoutPayout(
      _unsupportedCheckoutItem(),
      seller,
      0,
      0,
      new address payable[](0),
      new uint8[](0)
    );

    (bool success, ) = address(marketplace).call(
      abi.encodeWithSelector(
        IRareERC1155CheckoutExecutionModule.executeCheckoutItem.selector,
        _unsupportedCheckoutItem(),
        0,
        address(0),
        0,
        0,
        new address payable[](0),
        new uint8[](0)
      )
    );
    assertFalse(success);
  }

  function testOwnerCanUpdateTradeExecutionModule() public {
    vm.prank(deployer);
    RareERC1155TradeExecutionModule newTradeExecutionModule = new RareERC1155TradeExecutionModule();

    vm.prank(deployer);
    marketplace.setTradeExecutionModule(address(newTradeExecutionModule));

    assertEq(marketplace.getTradeExecutionModule(), address(newTradeExecutionModule));
  }

  function testOwnerCanUpdateCheckoutExecutionModule() public {
    vm.prank(deployer);
    RareERC1155CheckoutExecutionModule newCheckoutExecutionModule = new RareERC1155CheckoutExecutionModule();

    vm.prank(deployer);
    marketplace.setCheckoutExecutionModule(address(newCheckoutExecutionModule));

    assertEq(marketplace.getCheckoutExecutionModule(), address(newCheckoutExecutionModule));
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

  function testSetTokenAllowListConfigsRevertsWhenActiveEndTimestampNotFuture() public {
    uint256 currentTime = block.timestamp;

    vm.prank(seller);
    vm.expectRevert(
      abi.encodeWithSelector(
        IRareERC1155MarketplaceTypes.AllowListEndTimestampInvalid.selector,
        currentTime,
        currentTime
      )
    );
    marketplace.setTokenAllowListConfigs(
      address(token),
      _singleAllowListConfigRequest(tokenId, keccak256(abi.encodePacked(buyer)), currentTime)
    );
  }

  function testSetTokenAllowListConfigsAllowsDisablingWithZeroRoot() public {
    vm.startPrank(seller);
    marketplace.setTokenAllowListConfigs(
      address(token),
      _singleAllowListConfigRequest(tokenId, keccak256(abi.encodePacked(buyer)), block.timestamp + 1 days)
    );
    marketplace.setTokenAllowListConfigs(address(token), _singleAllowListConfigRequest(tokenId, bytes32(0), 0));
    vm.stopPrank();

    IRareERC1155MarketplaceTypes.AllowListConfig memory config = marketplace.getTokenAllowListConfig(
      address(token),
      tokenId
    );
    assertEq(config.root, bytes32(0));
    assertEq(config.endTimestamp, 0);
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

  function _initData(
    address _payments,
    address _tradeExecutionModule,
    address _checkoutExecutionModule
  ) private view returns (bytes memory) {
    return
      abi.encodeWithSelector(
        RareERC1155Marketplace.initialize.selector,
        networkBeneficiary,
        marketplaceSettings,
        royaltyEngine,
        _payments,
        approvedTokenRegistry,
        address(erc20ApprovalManager),
        address(erc721ApprovalManager),
        address(erc1155ApprovalManager),
        _tradeExecutionModule,
        _checkoutExecutionModule
      );
  }

  function _singleSalePriceRequest(
    uint256 _tokenId,
    uint256 _price,
    uint256 _quantity
  ) private pure returns (IRareERC1155MarketplaceTypes.SalePriceRequest[] memory) {
    IRareERC1155MarketplaceTypes.SalePriceRequest[]
      memory requests = new IRareERC1155MarketplaceTypes.SalePriceRequest[](1);
    requests[0] = IRareERC1155MarketplaceTypes.SalePriceRequest(_tokenId, _price, _quantity, 0);
    return requests;
  }

  function _singleExpiringSalePriceRequest(
    uint256 _tokenId,
    uint256 _price,
    uint256 _quantity,
    uint256 _expirationTime
  ) private pure returns (IRareERC1155MarketplaceTypes.SalePriceRequest[] memory) {
    IRareERC1155MarketplaceTypes.SalePriceRequest[]
      memory requests = new IRareERC1155MarketplaceTypes.SalePriceRequest[](1);
    requests[0] = IRareERC1155MarketplaceTypes.SalePriceRequest(_tokenId, _price, _quantity, _expirationTime);
    return requests;
  }

  function _singleDirectSaleRequest(
    uint256 _tokenId,
    uint256 _price,
    uint256 _startTime,
    uint256 _maxMints
  ) private pure returns (IRareERC1155MarketplaceTypes.DirectSaleRequest[] memory) {
    IRareERC1155MarketplaceTypes.DirectSaleRequest[]
      memory requests = new IRareERC1155MarketplaceTypes.DirectSaleRequest[](1);
    requests[0] = IRareERC1155MarketplaceTypes.DirectSaleRequest(_tokenId, _price, _startTime, _maxMints);
    return requests;
  }

  function _singleAllowListConfigRequest(
    uint256 _tokenId,
    bytes32 _root,
    uint256 _endTimestamp
  ) private pure returns (IRareERC1155MarketplaceTypes.AllowListConfigRequest[] memory) {
    IRareERC1155MarketplaceTypes.AllowListConfigRequest[]
      memory requests = new IRareERC1155MarketplaceTypes.AllowListConfigRequest[](1);
    requests[0] = IRareERC1155MarketplaceTypes.AllowListConfigRequest(_tokenId, _root, _endTimestamp);
    return requests;
  }

  function _singleTokenLimitRequest(
    uint256 _tokenId,
    uint256 _limit
  ) private pure returns (IRareERC1155MarketplaceTypes.TokenLimitRequest[] memory) {
    IRareERC1155MarketplaceTypes.TokenLimitRequest[]
      memory requests = new IRareERC1155MarketplaceTypes.TokenLimitRequest[](1);
    requests[0] = IRareERC1155MarketplaceTypes.TokenLimitRequest(_tokenId, _limit);
    return requests;
  }

  function _singleMintRequest(
    uint256 _tokenId,
    uint256 _price,
    uint256 _quantity
  ) private pure returns (IRareERC1155MarketplaceTypes.MintRequest[] memory) {
    bytes32[] memory proof = new bytes32[](0);
    IRareERC1155MarketplaceTypes.MintRequest[] memory requests = new IRareERC1155MarketplaceTypes.MintRequest[](1);
    requests[0] = IRareERC1155MarketplaceTypes.MintRequest(_tokenId, _price, _quantity, proof);
    return requests;
  }

  function _singleBuyRequest(
    uint256 _tokenId,
    uint256 _price,
    uint256 _quantity
  ) private pure returns (IRareERC1155MarketplaceTypes.BuyRequest[] memory) {
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
    return
      IRareERC1155MarketplaceTypes.CheckoutItem({
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
    return
      IRareERC1155MarketplaceTypes.CheckoutItem({
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
    return
      IRareERC1155MarketplaceTypes.CheckoutItem({
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

  function _listedToggleToken(uint256 _tokenId, uint256 _price) private returns (CheckoutToggleERC1155 toggleToken) {
    toggleToken = new CheckoutToggleERC1155(seller);
    toggleToken.setBalance(seller, _tokenId, 1);
    vm.prank(seller);
    toggleToken.setApprovalForAll(address(erc1155ApprovalManager), true);
    vm.prank(seller);
    marketplace.setSalePrices(
      address(toggleToken),
      address(0),
      _singleSalePriceRequest(_tokenId, _price, 1),
      _singleSplitRecipients(seller),
      _singleSplitRatios()
    );
  }

  function _assertSkipped(
    IRareERC1155MarketplaceTypes.CheckoutItemResult memory _result,
    IRareERC1155MarketplaceTypes.CheckoutFailureStage _stage,
    bytes4 _reason
  ) private {
    assertFalse(_result.filled);
    assertEq(uint8(_result.failureStage), uint8(_stage));
    assertEq(_result.reason, _reason);
  }

  function _assertUnknownCheckoutFailure(bytes memory _revertData) private {
    CheckoutFailureDecoderHarness harness = new CheckoutFailureDecoderHarness();

    (IRareERC1155MarketplaceTypes.CheckoutFailureStage stage, bytes memory failureData) = harness
      .checkoutExecutionFailure(_revertData);

    assertEq(uint8(stage), uint8(IRareERC1155MarketplaceTypes.CheckoutFailureStage.UNKNOWN));
    assertEq(failureData, _revertData);
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

  function _tokenIds(
    uint256 _firstTokenId,
    uint256 _secondTokenId,
    uint256 _thirdTokenId
  ) private pure returns (uint256[] memory tokenIds) {
    tokenIds = new uint256[](3);
    tokenIds[0] = _firstTokenId;
    tokenIds[1] = _secondTokenId;
    tokenIds[2] = _thirdTokenId;
  }

  function _singleAmounts(uint256 _amount) private pure returns (uint256[] memory amounts) {
    amounts = new uint256[](1);
    amounts[0] = _amount;
  }

  function _amounts(
    uint256 _firstAmount,
    uint256 _secondAmount,
    uint256 _thirdAmount
  ) private pure returns (uint256[] memory amounts) {
    amounts = new uint256[](3);
    amounts[0] = _firstAmount;
    amounts[1] = _secondAmount;
    amounts[2] = _thirdAmount;
  }

  function _mockSecondaryPayout(uint256 _amount, address _seller) private {
    _mockSecondaryPayoutFor(address(token), tokenId, _amount, _seller);
  }

  function _mockSecondaryPayoutFor(
    address _contractAddress,
    uint256 _tokenId,
    uint256 _amount,
    address _seller
  ) private {
    address payable[] memory receivers = new address payable[](1);
    uint256[] memory royalties = new uint256[](1);
    receivers[0] = payable(royaltyReceiver);
    royalties[0] = (_amount * 10) / 100;

    _mockSecondaryPayoutWithRoyalties(_contractAddress, _tokenId, _amount, _seller, receivers, royalties);
  }

  function _mockSecondaryPayoutWithRoyalties(
    address _contractAddress,
    uint256 _tokenId,
    uint256 _amount,
    address _seller,
    address payable[] memory _receivers,
    uint256[] memory _royalties
  ) private {
    _mockMarketplaceFee(_amount, _seller);
    vm.mockCall(
      royaltyEngine,
      abi.encodeWithSelector(IRoyaltyEngineV1.getRoyalty.selector, _contractAddress, _tokenId, _amount),
      abi.encode(_receivers, _royalties)
    );
  }

  function _royaltyReceivers(uint256 _count) private pure returns (address payable[] memory receivers) {
    address payable[6] memory allReceivers = [
      payable(address(0x4101)),
      payable(address(0x4102)),
      payable(address(0x4103)),
      payable(address(0x4104)),
      payable(address(0x4105)),
      payable(address(0x4106))
    ];
    receivers = new address payable[](_count);
    for (uint256 i = 0; i < _count; i++) {
      receivers[i] = allReceivers[i];
    }
  }

  function _royaltyAmounts(uint256 _amount, uint256 _count) private pure returns (uint256[] memory royalties) {
    royalties = new uint256[](_count);
    for (uint256 i = 0; i < _count; i++) {
      royalties[i] = (_amount * (i + 1)) / 100;
    }
  }

  function _zeroAddressRoyaltyReceivers() private pure returns (address payable[] memory receivers) {
    receivers = new address payable[](1);
    receivers[0] = payable(address(0));
  }

  function _singleRoyaltyAmounts(uint256 _amount) private pure returns (uint256[] memory royalties) {
    royalties = new uint256[](1);
    royalties[0] = (_amount * 10) / 100;
  }

  function _mockApprovedCurrency(address _currencyAddress) private {
    vm.mockCall(
      approvedTokenRegistry,
      abi.encodeWithSelector(IApprovedTokenRegistry.isApprovedToken.selector, _currencyAddress),
      abi.encode(true)
    );
  }

  function _mockMarketplaceFee(uint256 _amount, address _seller) private {
    _seller;
    _mockApprovedCurrency(address(0));
    vm.mockCall(
      marketplaceSettings,
      abi.encodeWithSelector(IMarketplaceSettings.calculateMarketplaceFee.selector, _amount),
      abi.encode(_fee(_amount))
    );
  }

  function _mockPrimaryPayout(uint256 _amount, address _seller) private {
    _mockPrimaryPayoutFor(address(token), _amount, _seller);
  }

  function _mockPrimaryPayoutFor(address _contractAddress, uint256 _amount, address _seller) private {
    _mockMarketplaceFee(_amount, _seller);
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
