// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import {ERC20} from "openzeppelin-contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
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

contract CheckoutGasCurrency is ERC20 {
  constructor(address _buyer) ERC20("Checkout Gas Currency", "CGAS") {
    _mint(_buyer, 1_000_000_000 ether);
  }
}

contract CheckoutGasApprovedTokenRegistry {
  function isApprovedToken(address) external pure returns (bool) {
    return true;
  }
}

contract CheckoutGasMarketplaceSettings {
  function calculateMarketplaceFee(uint256 _amount) external pure returns (uint256) {
    return (_amount * 3) / 100;
  }

  function getERC721ContractPrimarySaleFeePercentage(address) external pure returns (uint8) {
    return 10;
  }
}

contract CheckoutGasRoyaltyEngine is IRoyaltyEngineV1 {
  uint256 private immutable royaltyRecipientCount;

  constructor(uint256 _royaltyRecipientCount) {
    royaltyRecipientCount = _royaltyRecipientCount;
  }

  function getRoyalty(
    address,
    uint256,
    uint256 _value
  ) external view returns (address payable[] memory recipients, uint256[] memory amounts) {
    return _royalties(_value);
  }

  function getRoyaltyView(
    address,
    uint256,
    uint256 _value
  ) external view returns (address payable[] memory recipients, uint256[] memory amounts) {
    return _royalties(_value);
  }

  function supportsInterface(bytes4 _interfaceId) external pure returns (bool) {
    return _interfaceId == type(IRoyaltyEngineV1).interfaceId || _interfaceId == type(IERC165).interfaceId;
  }

  function _royalties(
    uint256 _value
  ) private view returns (address payable[] memory recipients, uint256[] memory amounts) {
    recipients = new address payable[](royaltyRecipientCount);
    amounts = new uint256[](royaltyRecipientCount);
    for (uint256 i = 0; i < royaltyRecipientCount; i++) {
      recipients[i] = payable(address(uint160(0xA000 + i)));
      amounts[i] = (_value * 10) / 100 / royaltyRecipientCount;
    }
  }
}

/// @dev Run with `forge test --match-contract RareERC1155MarketplaceGasTest -vv` to print sweep gas logs.
contract RareERC1155MarketplaceGasTest is Test {
  uint256 private constant PRICE = 1 ether;
  uint256 private constant MAX_BATCH_BENCH_ITEMS = 75;
  uint256 private constant MAX_CHECKOUT_BENCH_ITEMS = 50;
  uint256 private constant MAX_SPLIT_RECIPIENTS = 5;
  uint256 private constant MAX_ROYALTY_RECIPIENTS = 5;
  uint256 private constant BLOCK_GAS_CEILING = 30_000_000;

  RareERC1155Marketplace private marketplace;
  RareERC1155 private token;
  CheckoutGasCurrency private currency;
  RareERC1155ContractFactory private tokenFactory;
  ERC20ApprovalManager private erc20ApprovalManager;
  ERC721ApprovalManager private erc721ApprovalManager;
  ERC1155ApprovalManager private erc1155ApprovalManager;

  address private deployer = address(0x1000);
  address private seller = address(0x2000);
  address private buyer = address(0x3000);
  address private networkBeneficiary = address(0x4000);
  address private rewardAccumulator = address(0x5000);

  function testGas_checkoutPrimaryEthMaxSplits_sweep() public {
    uint256[] memory counts = _checkoutBenchmarkCounts();
    for (uint256 i = 0; i < counts.length; i++) {
      uint256 count = counts[i];
      _deployFixture(0);
      IRareERC1155MarketplaceTypes.CheckoutItem[] memory items = _preparePrimaryCheckoutItems(count);
      _measureCheckout("checkout_primary_eth_max_splits", count, items, _withFee(PRICE) * count, count, 0);
    }
  }

  function testGas_checkoutSecondaryEthMaxSplitsAndRoyalties_sweep() public {
    uint256[] memory counts = _checkoutBenchmarkCounts();
    for (uint256 i = 0; i < counts.length; i++) {
      uint256 count = counts[i];
      _deployFixture(MAX_ROYALTY_RECIPIENTS);
      IRareERC1155MarketplaceTypes.CheckoutItem[] memory items = _prepareSecondaryCheckoutItems(
        count,
        address(0),
        PRICE
      );
      _measureCheckout(
        "checkout_secondary_eth_max_splits_max_royalties",
        count,
        items,
        _withFee(PRICE) * count,
        count,
        0
      );
    }
  }

  function testGas_checkoutSecondaryErc20MaxSplitsAndRoyalties_sweep() public {
    uint256[] memory counts = _checkoutBenchmarkCounts();
    for (uint256 i = 0; i < counts.length; i++) {
      uint256 count = counts[i];
      _deployFixture(MAX_ROYALTY_RECIPIENTS);
      IRareERC1155MarketplaceTypes.CheckoutItem[] memory items = _prepareSecondaryCheckoutItems(
        count,
        address(currency),
        PRICE
      );

      vm.prank(buyer);
      currency.approve(address(erc20ApprovalManager), _withFee(PRICE) * count);

      _measureCheckout("checkout_secondary_erc20_max_splits_max_royalties", count, items, 0, count, 0);
    }
  }

  function testGas_checkoutMixedPrimaryAndSecondaryEth_sweep() public {
    uint256[] memory counts = _checkoutBenchmarkCounts();
    for (uint256 i = 0; i < counts.length; i++) {
      uint256 count = counts[i];
      _deployFixture(MAX_ROYALTY_RECIPIENTS);

      uint256 primaryCount = count / 2;
      uint256 secondaryCount = count - primaryCount;
      IRareERC1155MarketplaceTypes.CheckoutItem[] memory primaryItems = _preparePrimaryCheckoutItems(primaryCount);
      IRareERC1155MarketplaceTypes.CheckoutItem[] memory secondaryItems = _prepareSecondaryCheckoutItems(
        secondaryCount,
        address(0),
        PRICE
      );
      IRareERC1155MarketplaceTypes.CheckoutItem[] memory items = _concatCheckoutItems(primaryItems, secondaryItems);

      _measureCheckout("checkout_mixed_primary_secondary_eth", count, items, _withFee(PRICE) * count, count, 0);
    }
  }

  function testGas_checkoutSkippedSecondaryStaleBalanceThenPrimaryEth_sweep() public {
    uint256[] memory counts = _checkoutBenchmarkCounts();
    for (uint256 i = 0; i < counts.length; i++) {
      uint256 count = counts[i];
      _deployFixture(MAX_ROYALTY_RECIPIENTS);

      uint256 skippedCount = count - 1;
      IRareERC1155MarketplaceTypes.CheckoutItem[] memory skippedItems = _prepareStaleBalanceSecondaryCheckoutItems(
        skippedCount,
        address(0)
      );
      IRareERC1155MarketplaceTypes.CheckoutItem[] memory primaryItems = _preparePrimaryCheckoutItems(1);
      IRareERC1155MarketplaceTypes.CheckoutItem[] memory items = _concatCheckoutItems(skippedItems, primaryItems);

      _measureCheckout(
        "checkout_skipped_secondary_stale_balance_then_primary_eth",
        count,
        items,
        _withFee(PRICE),
        1,
        skippedCount
      );
    }
  }

  function testGas_checkoutAllSkippedFiftyItemCartUnderBlockGas() public {
    _deployFixture(0);
    IRareERC1155MarketplaceTypes.CheckoutItem[] memory items = _prepareStaleBalanceSecondaryCheckoutItems(
      MAX_CHECKOUT_BENCH_ITEMS,
      address(0)
    );

    uint256 gasUsed = _measureCheckout(
      "checkout_all_skipped_secondary_stale_balance_eth",
      MAX_CHECKOUT_BENCH_ITEMS,
      items,
      _withFee(PRICE) * MAX_CHECKOUT_BENCH_ITEMS,
      0,
      MAX_CHECKOUT_BENCH_ITEMS
    );

    _assertBelowBlockGas(gasUsed);
  }

  function testGas_checkoutFiftyItemFiveRoyaltyRecipientCartUnderBlockGas() public {
    _deployFixture(MAX_ROYALTY_RECIPIENTS);
    IRareERC1155MarketplaceTypes.CheckoutItem[] memory items = _prepareSecondaryCheckoutItems(
      MAX_CHECKOUT_BENCH_ITEMS,
      address(0),
      PRICE
    );

    uint256 gasUsed = _measureCheckout(
      "checkout_secondary_eth_50_items_5_royalty_recipients",
      MAX_CHECKOUT_BENCH_ITEMS,
      items,
      _withFee(PRICE) * MAX_CHECKOUT_BENCH_ITEMS,
      MAX_CHECKOUT_BENCH_ITEMS,
      0
    );

    _assertBelowBlockGas(gasUsed);
  }

  function testGas_mintDirectSaleBatchEthMaxSplits_sweep() public {
    uint256[] memory counts = _batchBenchmarkCounts();
    for (uint256 i = 0; i < counts.length; i++) {
      uint256 count = counts[i];
      _deployFixture(0);
      uint256[] memory tokenIds = _preparePrimarySales(count);
      IRareERC1155MarketplaceTypes.MintRequest[] memory requests = _mintRequests(tokenIds, PRICE);

      vm.prank(buyer);
      uint256 gasBefore = gasleft();
      marketplace.mintDirectSaleBatch{value: _withFee(PRICE) * count}(address(token), address(0), requests);
      _recordGas("mint_direct_sale_batch_eth_max_splits", count, gasBefore - gasleft());
    }
  }

  function testGas_buyBatchEthMaxSplitsAndRoyalties_sweep() public {
    uint256[] memory counts = _batchBenchmarkCounts();
    for (uint256 i = 0; i < counts.length; i++) {
      uint256 count = counts[i];
      _deployFixture(MAX_ROYALTY_RECIPIENTS);
      uint256[] memory tokenIds = _prepareSecondaryListings(count, address(0));
      IRareERC1155MarketplaceTypes.BuyRequest[] memory requests = _buyRequests(tokenIds, PRICE);

      vm.prank(buyer);
      uint256 gasBefore = gasleft();
      marketplace.buyBatch{value: _withFee(PRICE) * count}(address(token), seller, address(0), requests);
      _recordGas("buy_batch_eth_max_splits_max_royalties", count, gasBefore - gasleft());
    }
  }

  function _deployFixture(uint256 _royaltyRecipientCount) private {
    deal(deployer, 1_000_000 ether);
    deal(seller, 1_000_000 ether);
    deal(buyer, 1_000_000 ether);

    vm.startPrank(deployer);
    currency = new CheckoutGasCurrency(buyer);
    erc20ApprovalManager = new ERC20ApprovalManager();
    erc721ApprovalManager = new ERC721ApprovalManager();
    erc1155ApprovalManager = new ERC1155ApprovalManager();
    RareERC1155TradeExecutionModule tradeExecutionModule = new RareERC1155TradeExecutionModule();
    RareERC1155CheckoutExecutionModule checkoutExecutionModule = new RareERC1155CheckoutExecutionModule();

    address marketplaceSettings = address(new CheckoutGasMarketplaceSettings());
    address royaltyEngine = address(new CheckoutGasRoyaltyEngine(_royaltyRecipientCount));
    address approvedTokenRegistry = address(new CheckoutGasApprovedTokenRegistry());

    marketplace = RareERC1155Marketplace(
      address(
        new ERC1967Proxy(
          address(new RareERC1155Marketplace()),
          abi.encodeWithSelector(
            RareERC1155Marketplace.initialize.selector,
            networkBeneficiary,
            marketplaceSettings,
            royaltyEngine,
            address(new Payments()),
            approvedTokenRegistry,
            address(erc20ApprovalManager),
            address(erc721ApprovalManager),
            address(erc1155ApprovalManager),
            address(tradeExecutionModule),
            address(checkoutExecutionModule)
          )
        )
      )
    );
    erc20ApprovalManager.grantOperatorRole(address(marketplace));
    erc1155ApprovalManager.grantOperatorRole(address(marketplace));

    tokenFactory = new RareERC1155ContractFactory();
    tokenFactory.setDefaultMinter(address(marketplace));
    vm.stopPrank();

    vm.prank(seller);
    token = RareERC1155(tokenFactory.createRareERC1155Contract("Gas Editions", "GAS", "ipfs://gas/{id}.json"));
  }

  function _preparePrimaryCheckoutItems(
    uint256 _count
  ) private returns (IRareERC1155MarketplaceTypes.CheckoutItem[] memory items) {
    uint256[] memory tokenIds = _preparePrimarySales(_count);
    items = new IRareERC1155MarketplaceTypes.CheckoutItem[](_count);
    for (uint256 i = 0; i < _count; i++) {
      items[i] = _directSaleCheckoutItem(tokenIds[i], PRICE);
    }
  }

  function _prepareSecondaryCheckoutItems(
    uint256 _count,
    address _currencyAddress,
    uint256 _itemPrice
  ) private returns (IRareERC1155MarketplaceTypes.CheckoutItem[] memory items) {
    uint256[] memory tokenIds = _prepareSecondaryListings(_count, _currencyAddress);
    items = new IRareERC1155MarketplaceTypes.CheckoutItem[](_count);
    for (uint256 i = 0; i < _count; i++) {
      items[i] = _listingCheckoutItem(tokenIds[i], _currencyAddress, _itemPrice);
    }
  }

  function _prepareStaleBalanceSecondaryCheckoutItems(
    uint256 _count,
    address _currencyAddress
  ) private returns (IRareERC1155MarketplaceTypes.CheckoutItem[] memory items) {
    uint256[] memory tokenIds = _prepareSecondaryListings(_count, _currencyAddress);
    if (_count != 0) {
      vm.prank(seller);
      token.safeBatchTransferFrom(seller, address(0x6000), tokenIds, _amounts(_count, 1), "");
    }

    items = new IRareERC1155MarketplaceTypes.CheckoutItem[](_count);
    for (uint256 i = 0; i < _count; i++) {
      items[i] = _listingCheckoutItem(tokenIds[i], _currencyAddress, PRICE);
    }
  }

  function _preparePrimarySales(uint256 _count) private returns (uint256[] memory tokenIds) {
    tokenIds = _createTokenIds(_count, 10);
    if (_count == 0) return tokenIds;

    vm.prank(seller);
    marketplace.prepareMintDirectSales(
      address(token),
      address(0),
      _directSaleRequests(tokenIds, PRICE),
      _splitRecipients(MAX_SPLIT_RECIPIENTS),
      _splitRatios(MAX_SPLIT_RECIPIENTS)
    );
  }

  function _prepareSecondaryListings(
    uint256 _count,
    address _currencyAddress
  ) private returns (uint256[] memory tokenIds) {
    tokenIds = _createTokenIds(_count, 10);
    if (_count == 0) return tokenIds;

    uint256[] memory amounts = _amounts(_count, 1);
    vm.startPrank(seller);
    token.mintBatchTo(seller, tokenIds, amounts);
    token.setApprovalForAll(address(erc1155ApprovalManager), true);
    marketplace.setSalePrices(
      address(token),
      _currencyAddress,
      _salePriceRequests(tokenIds, PRICE),
      _splitRecipients(MAX_SPLIT_RECIPIENTS),
      _splitRatios(MAX_SPLIT_RECIPIENTS)
    );
    vm.stopPrank();
  }

  function _createTokenIds(uint256 _count, uint256 _maxSupply) private returns (uint256[] memory tokenIds) {
    tokenIds = new uint256[](_count);
    vm.startPrank(seller);
    for (uint256 i = 0; i < _count; i++) {
      tokenIds[i] = token.createToken("ipfs://gas-token.json", _maxSupply, seller);
    }
    vm.stopPrank();
  }

  function _measureCheckout(
    string memory _scenario,
    uint256 _count,
    IRareERC1155MarketplaceTypes.CheckoutItem[] memory _items,
    uint256 _value,
    uint256 _expectedFilled,
    uint256 _expectedSkipped
  ) private returns (uint256 gasUsed) {
    vm.prank(buyer);
    uint256 gasBefore = gasleft();
    IRareERC1155MarketplaceTypes.CheckoutExecution memory execution = marketplace.checkout{value: _value}(_items);
    IRareERC1155MarketplaceTypes.CheckoutSummary memory summary = execution.summary;
    gasUsed = gasBefore - gasleft();

    assertEq(summary.filledCount, _expectedFilled);
    assertEq(summary.skippedCount, _expectedSkipped);
    _recordGas(_scenario, _count, gasUsed);
  }

  function _assertBelowBlockGas(uint256 _gasUsed) private {
    assertLt(_gasUsed, BLOCK_GAS_CEILING);
  }

  function _recordGas(string memory _scenario, uint256 _count, uint256 _gasUsed) private {
    emit log_string(_scenario);
    emit log_named_uint("items", _count);
    emit log_named_uint("gas", _gasUsed);
    emit log_named_uint("gas_per_item", _gasUsed / _count);
  }

  function _checkoutBenchmarkCounts() private pure returns (uint256[] memory counts) {
    counts = new uint256[](5);
    counts[0] = 1;
    counts[1] = 5;
    counts[2] = 10;
    counts[3] = 20;
    counts[4] = MAX_CHECKOUT_BENCH_ITEMS;
  }

  function _batchBenchmarkCounts() private pure returns (uint256[] memory counts) {
    counts = new uint256[](6);
    counts[0] = 1;
    counts[1] = 5;
    counts[2] = 10;
    counts[3] = 20;
    counts[4] = 50;
    counts[5] = MAX_BATCH_BENCH_ITEMS;
  }

  function _concatCheckoutItems(
    IRareERC1155MarketplaceTypes.CheckoutItem[] memory _first,
    IRareERC1155MarketplaceTypes.CheckoutItem[] memory _second
  ) private pure returns (IRareERC1155MarketplaceTypes.CheckoutItem[] memory items) {
    items = new IRareERC1155MarketplaceTypes.CheckoutItem[](_first.length + _second.length);
    for (uint256 i = 0; i < _first.length; i++) {
      items[i] = _first[i];
    }
    for (uint256 i = 0; i < _second.length; i++) {
      items[_first.length + i] = _second[i];
    }
  }

  function _directSaleCheckoutItem(
    uint256 _tokenId,
    uint256 _price
  ) private view returns (IRareERC1155MarketplaceTypes.CheckoutItem memory) {
    return
      IRareERC1155MarketplaceTypes.CheckoutItem({
        itemKind: uint8(IRareERC1155MarketplaceTypes.CheckoutItemKind.DIRECT_SALE_MINT),
        contractAddress: address(token),
        seller: address(0),
        currencyAddress: address(0),
        tokenId: _tokenId,
        price: _price,
        quantity: 1,
        proof: new bytes32[](0)
      });
  }

  function _listingCheckoutItem(
    uint256 _tokenId,
    address _currencyAddress,
    uint256 _price
  ) private view returns (IRareERC1155MarketplaceTypes.CheckoutItem memory) {
    return
      IRareERC1155MarketplaceTypes.CheckoutItem({
        itemKind: uint8(IRareERC1155MarketplaceTypes.CheckoutItemKind.LISTING_BUY),
        contractAddress: address(token),
        seller: seller,
        currencyAddress: _currencyAddress,
        tokenId: _tokenId,
        price: _price,
        quantity: 1,
        proof: new bytes32[](0)
      });
  }

  function _directSaleRequests(
    uint256[] memory _tokenIds,
    uint256 _price
  ) private pure returns (IRareERC1155MarketplaceTypes.DirectSaleRequest[] memory requests) {
    requests = new IRareERC1155MarketplaceTypes.DirectSaleRequest[](_tokenIds.length);
    for (uint256 i = 0; i < _tokenIds.length; i++) {
      requests[i] = IRareERC1155MarketplaceTypes.DirectSaleRequest(_tokenIds[i], _price, 0, 0);
    }
  }

  function _salePriceRequests(
    uint256[] memory _tokenIds,
    uint256 _price
  ) private pure returns (IRareERC1155MarketplaceTypes.SalePriceRequest[] memory requests) {
    requests = new IRareERC1155MarketplaceTypes.SalePriceRequest[](_tokenIds.length);
    for (uint256 i = 0; i < _tokenIds.length; i++) {
      requests[i] = IRareERC1155MarketplaceTypes.SalePriceRequest(_tokenIds[i], _price, 1, 0);
    }
  }

  function _mintRequests(
    uint256[] memory _tokenIds,
    uint256 _price
  ) private pure returns (IRareERC1155MarketplaceTypes.MintRequest[] memory requests) {
    requests = new IRareERC1155MarketplaceTypes.MintRequest[](_tokenIds.length);
    for (uint256 i = 0; i < _tokenIds.length; i++) {
      requests[i] = IRareERC1155MarketplaceTypes.MintRequest(_tokenIds[i], _price, 1, new bytes32[](0));
    }
  }

  function _buyRequests(
    uint256[] memory _tokenIds,
    uint256 _price
  ) private pure returns (IRareERC1155MarketplaceTypes.BuyRequest[] memory requests) {
    requests = new IRareERC1155MarketplaceTypes.BuyRequest[](_tokenIds.length);
    for (uint256 i = 0; i < _tokenIds.length; i++) {
      requests[i] = IRareERC1155MarketplaceTypes.BuyRequest(_tokenIds[i], _price, 1);
    }
  }

  function _splitRecipients(uint256 _count) private pure returns (address payable[] memory recipients) {
    recipients = new address payable[](_count);
    for (uint256 i = 0; i < _count; i++) {
      recipients[i] = payable(address(uint160(0xB000 + i)));
    }
  }

  function _splitRatios(uint256 _count) private pure returns (uint8[] memory ratios) {
    ratios = new uint8[](_count);
    uint8 ratio = uint8(100 / _count);
    for (uint256 i = 0; i < _count; i++) {
      ratios[i] = ratio;
    }
    ratios[_count - 1] += uint8(100 - (ratio * _count));
  }

  function _amounts(uint256 _count, uint256 _amount) private pure returns (uint256[] memory amounts) {
    amounts = new uint256[](_count);
    for (uint256 i = 0; i < _count; i++) {
      amounts[i] = _amount;
    }
  }

  function _withFee(uint256 _amount) private pure returns (uint256) {
    return _amount + ((_amount * 3) / 100);
  }
}
