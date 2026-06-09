// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import {ERC1967Proxy} from "openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC1155Receiver} from "openzeppelin-contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC165} from "openzeppelin-contracts/utils/introspection/IERC165.sol";

import {Payments} from "../../payments/Payments.sol";
import {RareERC1155} from "../../token/ERC1155/RareERC1155.sol";
import {RareERC1155ContractFactory} from "../../token/ERC1155/RareERC1155ContractFactory.sol";
import {ERC20ApprovalManager} from "../../v2/approver/ERC20/ERC20ApprovalManager.sol";
import {ERC721ApprovalManager} from "../../v2/approver/ERC721/ERC721ApprovalManager.sol";
import {ERC1155ApprovalManager} from "../../v2/approver/ERC1155/ERC1155ApprovalManager.sol";
import {IRareERC1155MarketplaceTypes} from "../../marketplace/IRareERC1155MarketplaceTypes.sol";
import {RareERC1155CheckoutExecutionModule} from "../../marketplace/RareERC1155CheckoutExecutionModule.sol";
import {RareERC1155Marketplace} from "../../marketplace/RareERC1155Marketplace.sol";
import {RareERC1155TradeExecutionModule} from "../../marketplace/RareERC1155TradeExecutionModule.sol";
import {IRoyaltyEngineV1} from "royalty-registry/IRoyaltyEngineV1.sol";

contract ReentrancyMarketplaceSettings {
  function calculateMarketplaceFee(uint256 _amount) external pure returns (uint256) {
    return (_amount * 3) / 100;
  }

  function getERC721ContractPrimarySaleFeePercentage(address) external pure returns (uint8) {
    return 10;
  }
}

contract ReentrancyApprovedTokenRegistry {
  mapping(address => bool) private approvedTokens;

  function setApprovedToken(address _token, bool _approved) external {
    approvedTokens[_token] = _approved;
  }

  function isApprovedToken(address _token) external view returns (bool) {
    return approvedTokens[_token];
  }
}

contract ReenteringERC1155Receiver is IERC1155Receiver {
  RareERC1155Marketplace private immutable target;
  bytes private reentryCall;
  uint256 private reentryValue;

  bool public reentryReverted;

  constructor(RareERC1155Marketplace _target) {
    target = _target;
  }

  receive() external payable {
    _attemptReentry();
  }

  function setReentry(bytes calldata _reentryCall, uint256 _reentryValue) external {
    reentryCall = _reentryCall;
    reentryValue = _reentryValue;
    reentryReverted = false;
  }

  function onERC1155Received(address, address, uint256, uint256, bytes calldata) external returns (bytes4) {
    _attemptReentry();
    return this.onERC1155Received.selector;
  }

  function onERC1155BatchReceived(
    address,
    address,
    uint256[] calldata,
    uint256[] calldata,
    bytes calldata
  ) external returns (bytes4) {
    _attemptReentry();
    return this.onERC1155BatchReceived.selector;
  }

  function supportsInterface(bytes4 _interfaceId) external pure returns (bool) {
    return _interfaceId == type(IERC165).interfaceId || _interfaceId == type(IERC1155Receiver).interfaceId;
  }

  function _attemptReentry() private {
    if (reentryCall.length == 0) return;

    (bool success, ) = address(target).call{value: reentryValue}(reentryCall);
    reentryReverted = !success;
  }
}

contract ReenteringRoyaltyEngine is IRoyaltyEngineV1, IERC1155Receiver {
  RareERC1155Marketplace private target;
  bytes private reentryCall;
  bool private revertAfterReentry;

  function setTarget(RareERC1155Marketplace _target) external {
    target = _target;
  }

  function setReentry(bytes calldata _reentryCall, bool _revertAfterReentry) external {
    reentryCall = _reentryCall;
    revertAfterReentry = _revertAfterReentry;
  }

  function getRoyalty(
    address,
    uint256,
    uint256
  ) external returns (address payable[] memory recipients, uint256[] memory amounts) {
    if (reentryCall.length != 0) {
      (bool success, ) = address(target).call(reentryCall);
      if (revertAfterReentry) {
        if (!success) revert("royalty reentry blocked");
        revert("royalty reentry unexpectedly succeeded");
      }
    }

    recipients = new address payable[](0);
    amounts = new uint256[](0);
  }

  function getRoyaltyView(
    address,
    uint256,
    uint256
  ) external pure returns (address payable[] memory recipients, uint256[] memory amounts) {
    recipients = new address payable[](0);
    amounts = new uint256[](0);
  }

  function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
    return this.onERC1155Received.selector;
  }

  function onERC1155BatchReceived(
    address,
    address,
    uint256[] calldata,
    uint256[] calldata,
    bytes calldata
  ) external pure returns (bytes4) {
    return this.onERC1155BatchReceived.selector;
  }

  function supportsInterface(bytes4 _interfaceId) external pure returns (bool) {
    return
      _interfaceId == type(IERC165).interfaceId ||
      _interfaceId == type(IRoyaltyEngineV1).interfaceId ||
      _interfaceId == type(IERC1155Receiver).interfaceId;
  }
}

contract ReenteringERC20 is IERC1155Receiver {
  enum Hook {
    NONE,
    BALANCE_OF_REVERT,
    ALLOWANCE_REVERT
  }

  string public constant name = "Reentering ERC20";
  string public constant symbol = "RE20";
  uint8 public constant decimals = 18;
  uint256 public totalSupply;

  RareERC1155Marketplace private target;
  bytes private reentryCall;
  Hook private hook;

  mapping(address => uint256) private balances;
  mapping(address => mapping(address => uint256)) private allowances;

  function setReentry(RareERC1155Marketplace _target, bytes calldata _reentryCall, Hook _hook) external {
    target = _target;
    reentryCall = _reentryCall;
    hook = _hook;
  }

  function mint(address _account, uint256 _amount) external {
    balances[_account] += _amount;
    totalSupply += _amount;
  }

  function approve(address _spender, uint256 _amount) external returns (bool) {
    allowances[msg.sender][_spender] = _amount;
    return true;
  }

  function balanceOf(address _account) external returns (uint256) {
    if (hook == Hook.BALANCE_OF_REVERT) {
      _reenterAndRevert("balanceOf reentry blocked");
    }

    return balances[_account];
  }

  function allowance(address _owner, address _spender) external returns (uint256) {
    if (hook == Hook.ALLOWANCE_REVERT) {
      _reenterAndRevert("allowance reentry blocked");
    }

    return allowances[_owner][_spender];
  }

  function transfer(address _to, uint256 _amount) external returns (bool) {
    balances[msg.sender] -= _amount;
    balances[_to] += _amount;
    return true;
  }

  function transferFrom(address _from, address _to, uint256 _amount) external returns (bool) {
    uint256 currentAllowance = allowances[_from][msg.sender];
    require(currentAllowance >= _amount, "ERC20: insufficient allowance");

    allowances[_from][msg.sender] = currentAllowance - _amount;
    balances[_from] -= _amount;
    balances[_to] += _amount;
    return true;
  }

  function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
    return this.onERC1155Received.selector;
  }

  function onERC1155BatchReceived(
    address,
    address,
    uint256[] calldata,
    uint256[] calldata,
    bytes calldata
  ) external pure returns (bytes4) {
    return this.onERC1155BatchReceived.selector;
  }

  function supportsInterface(bytes4 _interfaceId) external pure returns (bool) {
    return _interfaceId == type(IERC165).interfaceId || _interfaceId == type(IERC1155Receiver).interfaceId;
  }

  function _reenterAndRevert(string memory _reason) private {
    (bool success, ) = address(target).call(reentryCall);
    if (success) revert("reentry unexpectedly succeeded");
    revert(_reason);
  }
}

contract RareERC1155MarketplaceReentrancyTest is Test {
  RareERC1155Marketplace private marketplace;
  Payments private payments;
  RareERC1155 private token;
  RareERC1155ContractFactory private tokenFactory;
  ERC20ApprovalManager private erc20ApprovalManager;
  ERC721ApprovalManager private erc721ApprovalManager;
  ERC1155ApprovalManager private erc1155ApprovalManager;
  ReentrancyApprovedTokenRegistry private approvedTokenRegistry;
  ReenteringRoyaltyEngine private royaltyEngine;

  address private deployer = address(0x1000);
  address private seller = address(0x2000);
  address private buyer = address(0x3000);
  address private networkBeneficiary = address(0x5000);

  ReentrancyMarketplaceSettings private marketplaceSettings;
  uint256 private tokenId;
  uint256 private tokenIdTwo;
  uint256 private tokenIdThree;

  function setUp() public {
    deal(deployer, 100 ether);
    deal(seller, 100 ether);
    deal(buyer, 100 ether);

    vm.startPrank(deployer);
    marketplaceSettings = new ReentrancyMarketplaceSettings();
    approvedTokenRegistry = new ReentrancyApprovedTokenRegistry();
    royaltyEngine = new ReenteringRoyaltyEngine();

    erc20ApprovalManager = new ERC20ApprovalManager();
    erc721ApprovalManager = new ERC721ApprovalManager();
    erc1155ApprovalManager = new ERC1155ApprovalManager();
    RareERC1155TradeExecutionModule tradeExecutionModule = new RareERC1155TradeExecutionModule();
    RareERC1155CheckoutExecutionModule checkoutExecutionModule = new RareERC1155CheckoutExecutionModule();
    payments = new Payments();

    marketplace = RareERC1155Marketplace(
      address(
        new ERC1967Proxy(
          address(new RareERC1155Marketplace()),
          _initData(address(tradeExecutionModule), address(checkoutExecutionModule))
        )
      )
    );
    royaltyEngine.setTarget(marketplace);
    erc20ApprovalManager.grantOperatorRole(address(marketplace));
    erc1155ApprovalManager.grantOperatorRole(address(marketplace));

    tokenFactory = new RareERC1155ContractFactory();
    tokenFactory.setDefaultMinter(address(marketplace));
    vm.stopPrank();

    vm.prank(seller);
    token = RareERC1155(tokenFactory.createRareERC1155Contract("Rare Editions", "RED", "ipfs://base/{id}.json"));

    vm.startPrank(seller);
    tokenId = token.createToken("ipfs://token/1.json", 100, seller);
    tokenIdTwo = token.createToken("ipfs://token/2.json", 100, seller);
    tokenIdThree = token.createToken("ipfs://token/3.json", 100, seller);
    token.mintTo(seller, tokenId, 10);
    token.mintTo(seller, tokenIdTwo, 10);
    token.mintTo(seller, tokenIdThree, 10);
    token.setApprovalForAll(address(erc1155ApprovalManager), true);
    vm.stopPrank();
  }

  function test_reentry_mintHookCannotReenterCheckout() public {
    uint256 supplyBefore = token.totalSupply(tokenId);
    ReenteringERC1155Receiver receiver = new ReenteringERC1155Receiver(marketplace);

    _prepareDirectSale(tokenId, 0, 2, payable(seller));

    IRareERC1155MarketplaceTypes.CheckoutItem[] memory reentryItems = _singleCheckoutItem(
      _directSaleCheckoutItem(tokenId, 0, 1)
    );
    receiver.setReentry(abi.encodeWithSelector(marketplace.checkout.selector, reentryItems), 0);

    vm.prank(address(receiver));
    IRareERC1155MarketplaceTypes.CheckoutExecution memory execution = marketplace.checkout(reentryItems);

    assertEq(execution.summary.filledCount, 1);
    assertTrue(receiver.reentryReverted());
    assertEq(token.balanceOf(address(receiver), tokenId), 1);
    assertEq(token.totalSupply(tokenId), supplyBefore + 1);
    assertEq(address(marketplace).balance, 0);
  }

  function test_reentry_ethPayoutRecipientCannotReenter() public {
    uint256 price = 1 ether;
    ReenteringERC1155Receiver payoutRecipient = new ReenteringERC1155Receiver(marketplace);

    _prepareDirectSale(tokenIdTwo, 0, 2, payable(seller));
    IRareERC1155MarketplaceTypes.CheckoutItem[] memory reentryItems = _singleCheckoutItem(
      _directSaleCheckoutItem(tokenIdTwo, 0, 1)
    );
    payoutRecipient.setReentry(abi.encodeWithSelector(marketplace.checkout.selector, reentryItems), 0);

    _setListing(tokenId, address(0), price, 1, payable(address(payoutRecipient)));

    vm.prank(buyer);
    marketplace.buyBatch{value: _withFee(price)}(
      address(token),
      seller,
      address(0),
      _singleBuyRequest(tokenId, price, 1)
    );

    assertTrue(payoutRecipient.reentryReverted());
    assertEq(token.balanceOf(buyer, tokenId), 1);
    assertEq(token.balanceOf(address(payoutRecipient), tokenIdTwo), 0);
    assertEq(token.totalSupply(tokenIdTwo), 10);
    assertEq(address(marketplace).balance, 0);
  }

  function test_reentry_maliciousERC20BalanceOfCannotMutateState() public {
    uint256 price = 1 ether;
    ReenteringERC20 maliciousCurrency = new ReenteringERC20();
    approvedTokenRegistry.setApprovedToken(address(maliciousCurrency), true);
    maliciousCurrency.mint(buyer, 100 ether);

    vm.prank(buyer);
    maliciousCurrency.approve(address(erc20ApprovalManager), type(uint256).max);

    _prepareDirectSale(tokenIdTwo, 0, 2, payable(seller));
    IRareERC1155MarketplaceTypes.CheckoutItem[] memory reentryItems = _singleCheckoutItem(
      _directSaleCheckoutItem(tokenIdTwo, 0, 1)
    );
    maliciousCurrency.setReentry(
      marketplace,
      abi.encodeWithSelector(marketplace.checkout.selector, reentryItems),
      ReenteringERC20.Hook.BALANCE_OF_REVERT
    );

    _setListing(tokenId, address(maliciousCurrency), price, 1, payable(seller));

    vm.expectRevert("balanceOf reentry blocked");
    vm.prank(buyer);
    marketplace.buyBatch(address(token), seller, address(maliciousCurrency), _singleBuyRequest(tokenId, price, 1));

    IRareERC1155MarketplaceTypes.SalePrice memory salePrice = marketplace.getSalePrice(address(token), tokenId, seller);
    assertEq(salePrice.quantity, 1);
    assertEq(token.balanceOf(buyer, tokenId), 0);
    assertEq(token.balanceOf(address(maliciousCurrency), tokenIdTwo), 0);

    maliciousCurrency.setReentry(
      marketplace,
      abi.encodeWithSelector(marketplace.checkout.selector, reentryItems),
      ReenteringERC20.Hook.ALLOWANCE_REVERT
    );

    IRareERC1155MarketplaceTypes.CheckoutItem[] memory items = _singleCheckoutItem(
      _listingCheckoutItem(tokenId, seller, address(maliciousCurrency), price, 1)
    );

    vm.prank(buyer);
    IRareERC1155MarketplaceTypes.CheckoutExecution memory execution = marketplace.checkout(items);

    assertEq(execution.summary.filledCount, 0);
    assertEq(execution.summary.skippedCount, 1);
    assertEq(
      uint8(execution.items[0].failureStage),
      uint8(IRareERC1155MarketplaceTypes.CheckoutFailureStage.PAYMENT_COLLECTION)
    );
    assertEq(execution.items[0].reason, IRareERC1155MarketplaceTypes.InsufficientCheckoutERC20Allowance.selector);
    assertEq(token.balanceOf(buyer, tokenId), 0);
    assertEq(token.balanceOf(address(maliciousCurrency), tokenIdTwo), 0);
    assertEq(maliciousCurrency.balanceOf(address(marketplace)), 0);
  }

  function test_reentry_royaltyEngineCannotReenter() public {
    uint256 price = 1 ether;
    bytes memory royaltyRevertData = abi.encodeWithSignature("Error(string)", "royalty reentry blocked");

    _setListing(tokenId, address(0), price, 1, payable(seller));
    _prepareDirectSale(tokenIdTwo, 0, 1, payable(seller));
    _prepareDirectSale(tokenIdThree, 0, 1, payable(seller));

    IRareERC1155MarketplaceTypes.CheckoutItem[] memory royaltyReentryItems = _singleCheckoutItem(
      _directSaleCheckoutItem(tokenIdThree, 0, 1)
    );
    royaltyEngine.setReentry(abi.encodeWithSelector(marketplace.checkout.selector, royaltyReentryItems), true);

    IRareERC1155MarketplaceTypes.CheckoutItem[] memory items = new IRareERC1155MarketplaceTypes.CheckoutItem[](2);
    items[0] = _listingCheckoutItem(tokenId, seller, address(0), price, 1);
    items[1] = _directSaleCheckoutItem(tokenIdTwo, 0, 1);

    vm.prank(buyer);
    IRareERC1155MarketplaceTypes.CheckoutExecution memory execution = marketplace.checkout{value: _withFee(price)}(
      items
    );

    assertEq(execution.summary.filledCount, 1);
    assertEq(execution.summary.skippedCount, 1);
    assertEq(execution.summary.ethRefunded, _withFee(price));
    assertEq(uint8(execution.items[0].failureStage), uint8(IRareERC1155MarketplaceTypes.CheckoutFailureStage.PAYOUT));
    assertEq(execution.items[0].reason, bytes4(0x08c379a0));
    assertEq(execution.items[0].failureData, royaltyRevertData);

    assertEq(token.balanceOf(buyer, tokenId), 0);
    assertEq(token.balanceOf(seller, tokenId), 10);
    assertEq(token.balanceOf(buyer, tokenIdTwo), 1);
    assertEq(token.balanceOf(address(royaltyEngine), tokenIdThree), 0);
    assertEq(marketplace.getSalePrice(address(token), tokenId, seller).quantity, 1);
    assertEq(address(marketplace).balance, 0);
  }

  function _prepareDirectSale(
    uint256 _tokenId,
    uint256 _price,
    uint256 _maxMints,
    address payable _splitRecipient
  ) private {
    vm.prank(seller);
    marketplace.prepareMintDirectSales(
      address(token),
      address(0),
      _singleDirectSaleRequest(_tokenId, _price, 0, _maxMints),
      _singleSplitRecipients(_splitRecipient),
      _singleSplitRatios()
    );
  }

  function _setListing(
    uint256 _tokenId,
    address _currencyAddress,
    uint256 _price,
    uint256 _quantity,
    address payable _splitRecipient
  ) private {
    vm.prank(seller);
    marketplace.setSalePrices(
      address(token),
      _currencyAddress,
      _singleSalePriceRequest(_tokenId, _price, _quantity),
      _singleSplitRecipients(_splitRecipient),
      _singleSplitRatios()
    );
  }

  function _directSaleCheckoutItem(
    uint256 _tokenId,
    uint256 _price,
    uint256 _quantity
  ) private view returns (IRareERC1155MarketplaceTypes.CheckoutItem memory) {
    return
      IRareERC1155MarketplaceTypes.CheckoutItem({
        itemKind: uint8(IRareERC1155MarketplaceTypes.CheckoutItemKind.DIRECT_SALE_MINT),
        contractAddress: address(token),
        seller: seller,
        currencyAddress: address(0),
        tokenId: _tokenId,
        price: _price,
        quantity: _quantity,
        proof: new bytes32[](0)
      });
  }

  function _listingCheckoutItem(
    uint256 _tokenId,
    address _seller,
    address _currencyAddress,
    uint256 _price,
    uint256 _quantity
  ) private view returns (IRareERC1155MarketplaceTypes.CheckoutItem memory) {
    return
      IRareERC1155MarketplaceTypes.CheckoutItem({
        itemKind: uint8(IRareERC1155MarketplaceTypes.CheckoutItemKind.LISTING_BUY),
        contractAddress: address(token),
        seller: _seller,
        currencyAddress: _currencyAddress,
        tokenId: _tokenId,
        price: _price,
        quantity: _quantity,
        proof: new bytes32[](0)
      });
  }

  function _singleCheckoutItem(
    IRareERC1155MarketplaceTypes.CheckoutItem memory _item
  ) private pure returns (IRareERC1155MarketplaceTypes.CheckoutItem[] memory items) {
    items = new IRareERC1155MarketplaceTypes.CheckoutItem[](1);
    items[0] = _item;
  }

  function _singleDirectSaleRequest(
    uint256 _tokenId,
    uint256 _price,
    uint256 _startTime,
    uint256 _maxMints
  ) private pure returns (IRareERC1155MarketplaceTypes.DirectSaleRequest[] memory requests) {
    requests = new IRareERC1155MarketplaceTypes.DirectSaleRequest[](1);
    requests[0] = IRareERC1155MarketplaceTypes.DirectSaleRequest(_tokenId, _price, _startTime, _maxMints);
  }

  function _singleSalePriceRequest(
    uint256 _tokenId,
    uint256 _price,
    uint256 _quantity
  ) private pure returns (IRareERC1155MarketplaceTypes.SalePriceRequest[] memory requests) {
    requests = new IRareERC1155MarketplaceTypes.SalePriceRequest[](1);
    requests[0] = IRareERC1155MarketplaceTypes.SalePriceRequest(_tokenId, _price, _quantity, 0);
  }

  function _singleBuyRequest(
    uint256 _tokenId,
    uint256 _price,
    uint256 _quantity
  ) private pure returns (IRareERC1155MarketplaceTypes.BuyRequest[] memory requests) {
    requests = new IRareERC1155MarketplaceTypes.BuyRequest[](1);
    requests[0] = IRareERC1155MarketplaceTypes.BuyRequest(_tokenId, _price, _quantity);
  }

  function _singleSplitRecipients(
    address payable _recipient
  ) private pure returns (address payable[] memory recipients) {
    recipients = new address payable[](1);
    recipients[0] = _recipient;
  }

  function _singleSplitRatios() private pure returns (uint8[] memory ratios) {
    ratios = new uint8[](1);
    ratios[0] = 100;
  }

  function _withFee(uint256 _amount) private pure returns (uint256) {
    return _amount + ((_amount * 3) / 100);
  }

  function _initData(
    address _tradeExecutionModule,
    address _checkoutExecutionModule
  ) private view returns (bytes memory) {
    return
      abi.encodeWithSelector(
        RareERC1155Marketplace.initialize.selector,
        networkBeneficiary,
        address(marketplaceSettings),
        address(royaltyEngine),
        address(payments),
        address(approvedTokenRegistry),
        address(erc20ApprovalManager),
        address(erc721ApprovalManager),
        address(erc1155ApprovalManager),
        _tradeExecutionModule,
        _checkoutExecutionModule
      );
  }
}
