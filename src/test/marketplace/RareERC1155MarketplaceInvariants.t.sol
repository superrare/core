// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "forge-std/StdInvariant.sol";
import "forge-std/Test.sol";

import {ERC20} from "openzeppelin-contracts/token/ERC20/ERC20.sol";
import {IERC1155Receiver} from "openzeppelin-contracts/token/ERC1155/IERC1155Receiver.sol";
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
import {IRareERC1155MarketplaceTypes} from "../../marketplace/IRareERC1155MarketplaceTypes.sol";
import {RareERC1155CheckoutExecutionModule} from "../../marketplace/RareERC1155CheckoutExecutionModule.sol";
import {RareERC1155Marketplace} from "../../marketplace/RareERC1155Marketplace.sol";
import {RareERC1155TradeExecutionModule} from "../../marketplace/RareERC1155TradeExecutionModule.sol";
import {IRoyaltyEngineV1} from "royalty-registry/IRoyaltyEngineV1.sol";

contract MarketplaceInvariantCurrency is ERC20 {
  constructor() ERC20("Invariant Currency", "ICUR") {}

  function mint(address _to, uint256 _amount) external {
    _mint(_to, _amount);
  }
}

contract RejectingERC1155Receiver is IERC1155Receiver {
  receive() external payable {
    revert("reject eth");
  }

  function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
    revert("reject erc1155");
  }

  function onERC1155BatchReceived(
    address,
    address,
    uint256[] calldata,
    uint256[] calldata,
    bytes calldata
  ) external pure returns (bytes4) {
    revert("reject erc1155 batch");
  }

  function supportsInterface(bytes4 _interfaceId) external pure returns (bool) {
    return _interfaceId == type(IERC165).interfaceId || _interfaceId == type(IERC1155Receiver).interfaceId;
  }
}

contract RejectingPayoutRecipient {
  receive() external payable {
    revert("reject eth");
  }
}

contract RareERC1155MarketplaceHandler is Test {
  struct OfferKey {
    uint256 tokenId;
    address buyer;
    address currencyAddress;
  }

  struct ListingKey {
    uint256 tokenId;
    address seller;
  }

  RareERC1155Marketplace public marketplace;
  RareERC1155 public token;
  MarketplaceInvariantCurrency public currency;

  address private collectionOwner;
  address private rejectingPayoutRecipient;
  address private marketplaceSettings;
  address private royaltyEngine;

  address[3] private buyers;
  address[2] private sellers;
  uint256[3] private tokenIds;

  OfferKey[] private offerKeys;
  ListingKey[] private listingKeys;
  mapping(bytes32 => uint256) private offerKeyIndexPlusOne;
  mapping(bytes32 => uint256) private listingKeyIndexPlusOne;

  uint256 public ghostEthEscrowOwed;
  mapping(address => uint256) public ghostErc20EscrowOwed;
  uint256 public ghostTokensReceivedByBuyers;
  uint256 public ghostTokensRemovedFromSellers;
  uint256 public ghostTokensMinted;

  uint256 public initialBuyerTokenBalanceSum;
  uint256 public initialSellerTokenBalanceSum;
  uint256 public initialTokenSupplySum;

  constructor(
    RareERC1155Marketplace _marketplace,
    RareERC1155 _token,
    MarketplaceInvariantCurrency _currencyToken,
    address _collectionOwner,
    address _rejectingPayoutRecipient,
    address _marketplaceSettings,
    address _royaltyEngine,
    address[3] memory _buyers,
    address[2] memory _sellers,
    uint256[3] memory _tokenIds
  ) {
    marketplace = _marketplace;
    token = _token;
    currency = _currencyToken;
    collectionOwner = _collectionOwner;
    rejectingPayoutRecipient = _rejectingPayoutRecipient;
    marketplaceSettings = _marketplaceSettings;
    royaltyEngine = _royaltyEngine;
    buyers = _buyers;
    sellers = _sellers;
    tokenIds = _tokenIds;

    initialBuyerTokenBalanceSum = buyerTokenBalanceSum();
    initialSellerTokenBalanceSum = sellerTokenBalanceSum();
    initialTokenSupplySum = tokenSupplySum();
  }

  function makeOffer(
    uint256 _buyerSeed,
    uint256 _currencySeed,
    uint256 _tokenSeed,
    uint256 _priceSeed,
    uint256 _qtySeed
  ) external {
    address buyer = _buyerForSeed(_buyerSeed);
    address currencyAddress = _currencyForSeed(_currencySeed);
    uint256 tokenId = _tokenIdForSeed(_tokenSeed);
    uint256 price = _priceForSeed(_priceSeed);
    uint256 quantity = _quantityForSeed(_qtySeed);
    uint256 grossAmount = price * quantity;

    _mockOfferFees(grossAmount);

    vm.prank(buyer);
    if (currencyAddress == address(0)) {
      try
        marketplace.makeOffer{value: _withFee(grossAmount)}(
          address(token),
          tokenId,
          currencyAddress,
          price,
          quantity,
          0
        )
      {
        _trackOffer(tokenId, buyer, currencyAddress);
        _syncEscrowGhosts();
      } catch {}
    } else {
      try marketplace.makeOffer(address(token), tokenId, currencyAddress, price, quantity, 0) {
        _trackOffer(tokenId, buyer, currencyAddress);
        _syncEscrowGhosts();
      } catch {}
    }
  }

  function acceptOffer(uint256 _sellerSeed, uint256 _offerSeed, uint256 _qtySeed, uint256 _splitSeed) external {
    (bool found, uint256 keyIndex) = _activeOfferIndex(_offerSeed);
    if (!found) return;

    OfferKey memory key = offerKeys[keyIndex];
    IRareERC1155MarketplaceTypes.Offer memory offer = marketplace.getOffer(
      address(token),
      key.tokenId,
      key.buyer,
      key.currencyAddress
    );
    address seller = _sellerForSeed(_sellerSeed);
    uint256 sellerBalance = token.balanceOf(seller, key.tokenId);
    if (sellerBalance == 0) return;

    uint256 quantity = _bounded(_qtySeed, 1, _min(offer.quantity, sellerBalance));
    uint256 grossAmount = offer.price * quantity;
    _mockSecondaryPayout(key.tokenId, grossAmount, seller);

    uint256 buyerBalanceBefore = token.balanceOf(key.buyer, key.tokenId);
    uint256 sellerBalanceBefore = token.balanceOf(seller, key.tokenId);

    vm.prank(seller);
    try
      marketplace.acceptOffer(
        address(token),
        key.tokenId,
        key.buyer,
        key.currencyAddress,
        offer.price,
        quantity,
        _splitRecipients(seller, _splitSeed),
        _splitRatios()
      )
    {
      _recordSecondaryTransfer(key.buyer, seller, key.tokenId, buyerBalanceBefore, sellerBalanceBefore);
      _syncEscrowGhosts();
    } catch {}
  }

  function cancelOffer(uint256 _offerSeed) external {
    if (offerKeys.length == 0) return;

    OfferKey memory key = offerKeys[_offerSeed % offerKeys.length];
    vm.prank(key.buyer);
    try marketplace.cancelOffer(address(token), key.tokenId, key.currencyAddress) {
      _syncEscrowGhosts();
    } catch {}
  }

  function setListing(
    uint256 _sellerSeed,
    uint256 _currencySeed,
    uint256 _tokenSeed,
    uint256 _priceSeed,
    uint256 _qtySeed,
    uint256 _splitSeed
  ) external {
    address seller = _sellerForSeed(_sellerSeed);
    uint256 tokenId = _tokenIdForSeed(_tokenSeed);
    uint256 balance = token.balanceOf(seller, tokenId);
    if (balance == 0) return;

    uint256 quantity = _bounded(_qtySeed, 1, _min(balance, 5));
    uint256 price = _priceForSeed(_priceSeed);
    address currencyAddress = _currencyForSeed(_currencySeed);

    vm.prank(seller);
    try
      marketplace.setSalePrices(
        address(token),
        currencyAddress,
        _singleSalePriceRequest(tokenId, price, quantity),
        _splitRecipients(seller, _splitSeed),
        _splitRatios()
      )
    {
      _trackListing(tokenId, seller);
    } catch {}
  }

  function cancelListing(uint256 _listingSeed) external {
    if (listingKeys.length == 0) return;

    ListingKey memory key = listingKeys[_listingSeed % listingKeys.length];
    vm.prank(key.seller);
    try marketplace.cancelSalePrices(address(token), _singleTokenIds(key.tokenId)) {} catch {}
  }

  function buyBatch(uint256 _buyerSeed, uint256 _listingSeed, uint256 _qtySeed) external {
    (bool found, uint256 keyIndex) = _activeListingIndex(_listingSeed);
    if (!found) return;

    ListingKey memory key = listingKeys[keyIndex];
    IRareERC1155MarketplaceTypes.SalePrice memory salePrice = marketplace.getSalePrice(
      address(token),
      key.tokenId,
      key.seller
    );
    address buyer = _buyerForSeed(_buyerSeed);
    uint256 sellerBalance = token.balanceOf(key.seller, key.tokenId);
    if (sellerBalance == 0) return;

    uint256 quantity = _bounded(_qtySeed, 1, _min(salePrice.quantity, sellerBalance));
    uint256 grossAmount = salePrice.price * quantity;
    _mockSecondaryPayout(key.tokenId, grossAmount, key.seller);

    uint256 buyerBalanceBefore = token.balanceOf(buyer, key.tokenId);
    uint256 sellerBalanceBefore = token.balanceOf(key.seller, key.tokenId);

    vm.prank(buyer);
    if (salePrice.currencyAddress == address(0)) {
      try
        marketplace.buyBatch{value: _withFee(grossAmount)}(
          address(token),
          key.seller,
          salePrice.currencyAddress,
          _singleBuyRequest(key.tokenId, salePrice.price, quantity)
        )
      {
        _recordSecondaryTransfer(buyer, key.seller, key.tokenId, buyerBalanceBefore, sellerBalanceBefore);
      } catch {}
    } else {
      try
        marketplace.buyBatch(
          address(token),
          key.seller,
          salePrice.currencyAddress,
          _singleBuyRequest(key.tokenId, salePrice.price, quantity)
        )
      {
        _recordSecondaryTransfer(buyer, key.seller, key.tokenId, buyerBalanceBefore, sellerBalanceBefore);
      } catch {}
    }
  }

  function prepareDirectSale(
    uint256 _currencySeed,
    uint256 _tokenSeed,
    uint256 _priceSeed,
    uint256 _maxMintSeed,
    uint256 _splitSeed
  ) external {
    _prepareDirectSaleConfig(
      _tokenIdForSeed(_tokenSeed),
      _currencyForSeed(_currencySeed),
      _priceForSeed(_priceSeed),
      _bounded(_maxMintSeed, 1, 4),
      _splitSeed
    );
  }

  function cancelDirectSale(uint256 _tokenSeed) external {
    vm.prank(collectionOwner);
    try marketplace.cancelMintDirectSales(address(token), _singleTokenIds(_tokenIdForSeed(_tokenSeed))) {} catch {}
  }

  function checkoutMixedCart(
    uint256 _buyerSeed,
    uint256 _sellerSeed,
    uint256 _tokenSeed,
    uint256 _priceSeed,
    uint256 _qtySeed,
    uint256 _splitSeed
  ) external {
    address buyer = _buyerForSeed(_buyerSeed);
    uint256 listingTokenId = _tokenIdForSeed(_tokenSeed);
    (bool listed, address seller, uint256 sellerBalance) = _sellerWithBalance(_sellerSeed, listingTokenId);
    if (!listed) return;

    address listingCurrency = _currencyForSeed(_priceSeed);
    address directCurrency = listingCurrency == address(0) ? address(currency) : address(0);
    uint256 listingQuantity = _bounded(_qtySeed, 1, _min(sellerBalance, 2));
    uint256 listingPrice = _priceForSeed(_priceSeed);

    vm.prank(seller);
    try
      marketplace.setSalePrices(
        address(token),
        listingCurrency,
        _singleSalePriceRequest(listingTokenId, listingPrice, listingQuantity),
        _splitRecipients(seller, _splitSeed),
        _splitRatios()
      )
    {
      _trackListing(listingTokenId, seller);
    } catch {
      return;
    }

    uint256 directTokenId = _tokenIdForSeed(_tokenSeed + 1);
    uint256 directPrice = _priceForSeed(_priceSeed + 1);
    uint256 directQuantity = _bounded(_qtySeed + 1, 1, 2);
    _prepareDirectSaleConfig(directTokenId, directCurrency, directPrice, directQuantity, _splitSeed + 1);

    IRareERC1155MarketplaceTypes.CheckoutItem[] memory items = new IRareERC1155MarketplaceTypes.CheckoutItem[](3);
    items[0] = _listingCheckoutItem(listingTokenId, seller, listingCurrency, listingPrice, listingQuantity);
    items[1] = _directSaleCheckoutItem(directTokenId, directCurrency, directPrice, directQuantity);
    items[2] = _unsupportedCheckoutItem();

    uint256 ethValue = 0;
    if (listingCurrency == address(0)) ethValue += _withFee(listingPrice * listingQuantity);
    if (directCurrency == address(0)) ethValue += _withFee(directPrice * directQuantity);
    ethValue += 1 wei;

    vm.prank(buyer);
    try marketplace.checkout{value: ethValue}(items) returns (
      IRareERC1155MarketplaceTypes.CheckoutExecution memory execution
    ) {
      _recordCheckoutFills(execution, buyer);
      _syncEscrowGhosts();
    } catch {}
  }

  function trackedOfferCount() external view returns (uint256) {
    return offerKeys.length;
  }

  function trackedOfferKey(
    uint256 _index
  ) external view returns (uint256 tokenId, address buyer, address currencyAddress) {
    OfferKey memory key = offerKeys[_index];
    return (key.tokenId, key.buyer, key.currencyAddress);
  }

  function trackedListingCount() external view returns (uint256) {
    return listingKeys.length;
  }

  function trackedListingKey(uint256 _index) external view returns (uint256 tokenId, address seller) {
    ListingKey memory key = listingKeys[_index];
    return (key.tokenId, key.seller);
  }

  function buyerTokenBalanceSum() public view returns (uint256 sum) {
    for (uint256 i = 0; i < buyers.length; i++) {
      for (uint256 j = 0; j < tokenIds.length; j++) {
        sum += token.balanceOf(buyers[i], tokenIds[j]);
      }
    }
  }

  function sellerTokenBalanceSum() public view returns (uint256 sum) {
    for (uint256 i = 0; i < sellers.length; i++) {
      for (uint256 j = 0; j < tokenIds.length; j++) {
        sum += token.balanceOf(sellers[i], tokenIds[j]);
      }
    }
  }

  function tokenSupplySum() public view returns (uint256 sum) {
    for (uint256 i = 0; i < tokenIds.length; i++) {
      sum += token.totalSupply(tokenIds[i]);
    }
  }

  function _recordCheckoutFills(
    IRareERC1155MarketplaceTypes.CheckoutExecution memory _execution,
    address _buyer
  ) private {
    for (uint256 i = 0; i < _execution.items.length; i++) {
      IRareERC1155MarketplaceTypes.CheckoutItemResult memory result = _execution.items[i];
      if (!result.filled) continue;

      if (result.itemKind == uint8(IRareERC1155MarketplaceTypes.CheckoutItemKind.DIRECT_SALE_MINT)) {
        ghostTokensMinted += result.quantity;
        ghostTokensReceivedByBuyers += result.quantity;
        _buyer;
        continue;
      }

      if (result.itemKind == uint8(IRareERC1155MarketplaceTypes.CheckoutItemKind.LISTING_BUY)) {
        ghostTokensRemovedFromSellers += result.quantity;
        ghostTokensReceivedByBuyers += result.quantity;
      }
    }
  }

  function _recordSecondaryTransfer(
    address _buyer,
    address _seller,
    uint256 _tokenId,
    uint256 _buyerBalanceBefore,
    uint256 _sellerBalanceBefore
  ) private {
    uint256 buyerDelta = token.balanceOf(_buyer, _tokenId) - _buyerBalanceBefore;
    uint256 sellerDelta = _sellerBalanceBefore - token.balanceOf(_seller, _tokenId);
    ghostTokensReceivedByBuyers += buyerDelta;
    ghostTokensRemovedFromSellers += sellerDelta;
  }

  function _syncEscrowGhosts() private {
    ghostEthEscrowOwed = 0;
    ghostErc20EscrowOwed[address(currency)] = 0;

    for (uint256 i = 0; i < offerKeys.length; i++) {
      OfferKey memory key = offerKeys[i];
      IRareERC1155MarketplaceTypes.Offer memory offer = marketplace.getOffer(
        address(token),
        key.tokenId,
        key.buyer,
        key.currencyAddress
      );
      uint256 escrowOwed = (offer.price * offer.quantity) + offer.marketplaceFeeRemaining;
      if (key.currencyAddress == address(0)) {
        ghostEthEscrowOwed += escrowOwed;
      } else {
        ghostErc20EscrowOwed[key.currencyAddress] += escrowOwed;
      }
    }
  }

  function _trackOffer(uint256 _tokenId, address _buyer, address _currencyAddress) private {
    bytes32 keyHash = keccak256(abi.encode(_tokenId, _buyer, _currencyAddress));
    if (offerKeyIndexPlusOne[keyHash] != 0) return;

    offerKeys.push(OfferKey({tokenId: _tokenId, buyer: _buyer, currencyAddress: _currencyAddress}));
    offerKeyIndexPlusOne[keyHash] = offerKeys.length;
  }

  function _trackListing(uint256 _tokenId, address _seller) private {
    bytes32 keyHash = keccak256(abi.encode(_tokenId, _seller));
    if (listingKeyIndexPlusOne[keyHash] != 0) return;

    listingKeys.push(ListingKey({tokenId: _tokenId, seller: _seller}));
    listingKeyIndexPlusOne[keyHash] = listingKeys.length;
  }

  function _activeOfferIndex(uint256 _seed) private view returns (bool found, uint256 keyIndex) {
    uint256 activeCount = 0;
    for (uint256 i = 0; i < offerKeys.length; i++) {
      OfferKey memory key = offerKeys[i];
      if (marketplace.getOffer(address(token), key.tokenId, key.buyer, key.currencyAddress).quantity != 0) {
        activeCount++;
      }
    }
    if (activeCount == 0) return (false, 0);

    uint256 target = _seed % activeCount;
    uint256 current = 0;
    for (uint256 i = 0; i < offerKeys.length; i++) {
      OfferKey memory key = offerKeys[i];
      if (marketplace.getOffer(address(token), key.tokenId, key.buyer, key.currencyAddress).quantity == 0) {
        continue;
      }
      if (current == target) return (true, i);
      current++;
    }
  }

  function _activeListingIndex(uint256 _seed) private view returns (bool found, uint256 keyIndex) {
    uint256 activeCount = 0;
    for (uint256 i = 0; i < listingKeys.length; i++) {
      ListingKey memory key = listingKeys[i];
      if (marketplace.getSalePrice(address(token), key.tokenId, key.seller).quantity != 0) activeCount++;
    }
    if (activeCount == 0) return (false, 0);

    uint256 target = _seed % activeCount;
    uint256 current = 0;
    for (uint256 i = 0; i < listingKeys.length; i++) {
      ListingKey memory key = listingKeys[i];
      if (marketplace.getSalePrice(address(token), key.tokenId, key.seller).quantity == 0) continue;
      if (current == target) return (true, i);
      current++;
    }
  }

  function _sellerWithBalance(
    uint256 _sellerSeed,
    uint256 _tokenId
  ) private view returns (bool found, address seller, uint256 balance) {
    for (uint256 i = 0; i < sellers.length; i++) {
      seller = sellers[(_sellerSeed + i) % sellers.length];
      balance = token.balanceOf(seller, _tokenId);
      if (balance != 0) return (true, seller, balance);
    }
  }

  function _prepareDirectSaleConfig(
    uint256 _tokenId,
    address _currencyAddress,
    uint256 _price,
    uint256 _maxMints,
    uint256 _splitSeed
  ) private {
    vm.prank(collectionOwner);
    try
      marketplace.prepareMintDirectSales(
        address(token),
        _currencyAddress,
        _singleDirectSaleRequest(_tokenId, _price, 0, _maxMints),
        _splitRecipients(collectionOwner, _splitSeed),
        _splitRatios()
      )
    {} catch {}
  }

  function _mockOfferFees(uint256 _amount) private {
    vm.mockCall(
      marketplaceSettings,
      abi.encodeWithSelector(IMarketplaceSettings.calculateMarketplaceFee.selector, _amount),
      abi.encode(_fee(_amount))
    );
  }

  function _mockSecondaryPayout(uint256 _tokenId, uint256 _amount, address _seller) private {
    _seller;
    _mockOfferFees(_amount);

    address payable[] memory receivers = new address payable[](0);
    uint256[] memory royalties = new uint256[](0);
    vm.mockCall(
      royaltyEngine,
      abi.encodeWithSelector(IRoyaltyEngineV1.getRoyalty.selector, address(token), _tokenId, _amount),
      abi.encode(receivers, royalties)
    );
  }

  function _mockPrimaryPayout(uint256 _amount, address _seller) private {
    _seller;
    _mockOfferFees(_amount);
    vm.mockCall(
      marketplaceSettings,
      abi.encodeWithSelector(IMarketplaceSettings.getERC721ContractPrimarySaleFeePercentage.selector, address(token)),
      abi.encode(uint256(10))
    );
  }

  function _directSaleCheckoutItem(
    uint256 _tokenId,
    address _currencyAddress,
    uint256 _price,
    uint256 _quantity
  ) private returns (IRareERC1155MarketplaceTypes.CheckoutItem memory) {
    _mockPrimaryPayout(_price * _quantity, collectionOwner);
    return
      IRareERC1155MarketplaceTypes.CheckoutItem({
        itemKind: uint8(IRareERC1155MarketplaceTypes.CheckoutItemKind.DIRECT_SALE_MINT),
        contractAddress: address(token),
        seller: collectionOwner,
        currencyAddress: _currencyAddress,
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
  ) private returns (IRareERC1155MarketplaceTypes.CheckoutItem memory) {
    _mockSecondaryPayout(_tokenId, _price * _quantity, _seller);
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

  function _singleSalePriceRequest(
    uint256 _tokenId,
    uint256 _price,
    uint256 _quantity
  ) private pure returns (IRareERC1155MarketplaceTypes.SalePriceRequest[] memory requests) {
    requests = new IRareERC1155MarketplaceTypes.SalePriceRequest[](1);
    requests[0] = IRareERC1155MarketplaceTypes.SalePriceRequest(_tokenId, _price, _quantity, 0);
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

  function _singleBuyRequest(
    uint256 _tokenId,
    uint256 _price,
    uint256 _quantity
  ) private pure returns (IRareERC1155MarketplaceTypes.BuyRequest[] memory requests) {
    requests = new IRareERC1155MarketplaceTypes.BuyRequest[](1);
    requests[0] = IRareERC1155MarketplaceTypes.BuyRequest(_tokenId, _price, _quantity);
  }

  function _singleTokenIds(uint256 _tokenId) private pure returns (uint256[] memory tokenIdList) {
    tokenIdList = new uint256[](1);
    tokenIdList[0] = _tokenId;
  }

  function _splitRecipients(
    address _seller,
    uint256 _splitSeed
  ) private view returns (address payable[] memory recipients) {
    recipients = new address payable[](1);
    recipients[0] = payable(_splitSeed % 4 == 0 ? rejectingPayoutRecipient : _seller);
  }

  function _splitRatios() private pure returns (uint8[] memory ratios) {
    ratios = new uint8[](1);
    ratios[0] = 100;
  }

  function _buyerForSeed(uint256 _seed) private view returns (address) {
    return buyers[_seed % buyers.length];
  }

  function _sellerForSeed(uint256 _seed) private view returns (address) {
    return sellers[_seed % sellers.length];
  }

  function _tokenIdForSeed(uint256 _seed) private view returns (uint256) {
    return tokenIds[_seed % tokenIds.length];
  }

  function _currencyForSeed(uint256 _seed) private view returns (address) {
    return _seed % 2 == 0 ? address(0) : address(currency);
  }

  function _priceForSeed(uint256 _seed) private pure returns (uint256) {
    return 0.001 ether + ((_seed % 50) * 0.001 ether);
  }

  function _quantityForSeed(uint256 _seed) private pure returns (uint256) {
    return _bounded(_seed, 1, 3);
  }

  function _withFee(uint256 _amount) private pure returns (uint256) {
    return _amount + _fee(_amount);
  }

  function _fee(uint256 _amount) private pure returns (uint256) {
    return (_amount * 3) / 100;
  }

  function _bounded(uint256 _seed, uint256 _minValue, uint256 _maxValue) private pure returns (uint256) {
    return _minValue + (_seed % (_maxValue - _minValue + 1));
  }

  function _min(uint256 _a, uint256 _b) private pure returns (uint256) {
    return _a < _b ? _a : _b;
  }
}

contract RareERC1155MarketplaceInvariantTest is StdInvariant, Test {
  RareERC1155Marketplace private marketplace;
  RareERC1155MarketplaceHandler private handler;
  RareERC1155 private token;
  MarketplaceInvariantCurrency private currency;
  RareERC1155ContractFactory private tokenFactory;
  ERC20ApprovalManager private erc20ApprovalManager;
  ERC721ApprovalManager private erc721ApprovalManager;
  ERC1155ApprovalManager private erc1155ApprovalManager;

  address private deployer = address(0x1000);
  address private seller = address(0x2000);
  address private sellerTwo = address(0x2001);
  address private buyer = address(0x3000);
  address private buyerTwo = address(0x3001);
  address private networkBeneficiary = address(0x5000);

  address private marketplaceSettings = address(0x7100);
  address private royaltyEngine = address(0x7400);
  address private approvedTokenRegistry = address(0x7600);

  uint256[3] private tokenIds;

  function setUp() public {
    RejectingERC1155Receiver rejectingBuyer = new RejectingERC1155Receiver();
    RejectingPayoutRecipient rejectingPayoutRecipient = new RejectingPayoutRecipient();

    deal(deployer, 1_000 ether);
    deal(seller, 1_000 ether);
    deal(sellerTwo, 1_000 ether);
    deal(buyer, 1_000 ether);
    deal(buyerTwo, 1_000 ether);
    deal(address(rejectingBuyer), 1_000 ether);

    vm.startPrank(deployer);
    currency = new MarketplaceInvariantCurrency();
    erc20ApprovalManager = new ERC20ApprovalManager();
    erc721ApprovalManager = new ERC721ApprovalManager();
    erc1155ApprovalManager = new ERC1155ApprovalManager();
    RareERC1155TradeExecutionModule tradeExecutionModule = new RareERC1155TradeExecutionModule();
    RareERC1155CheckoutExecutionModule checkoutExecutionModule = new RareERC1155CheckoutExecutionModule();
    Payments payments = new Payments();
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

    vm.startPrank(seller);
    tokenIds[0] = token.createToken("ipfs://token/1.json", 10_000, seller);
    tokenIds[1] = token.createToken("ipfs://token/2.json", 10_000, seller);
    tokenIds[2] = token.createToken("ipfs://token/3.json", 10_000, seller);
    for (uint256 i = 0; i < tokenIds.length; i++) {
      token.mintTo(seller, tokenIds[i], 120);
      token.mintTo(sellerTwo, tokenIds[i], 120);
    }
    token.setApprovalForAll(address(erc1155ApprovalManager), true);
    vm.stopPrank();

    vm.prank(sellerTwo);
    token.setApprovalForAll(address(erc1155ApprovalManager), true);

    _fundAndApproveCurrency(buyer);
    _fundAndApproveCurrency(buyerTwo);
    _fundAndApproveCurrency(address(rejectingBuyer));

    vm.etch(marketplaceSettings, address(marketplace).code);
    vm.etch(royaltyEngine, address(marketplace).code);
    vm.etch(approvedTokenRegistry, address(marketplace).code);

    vm.mockCall(
      approvedTokenRegistry,
      abi.encodeWithSelector(IApprovedTokenRegistry.isApprovedToken.selector, address(currency)),
      abi.encode(true)
    );

    address[3] memory buyers = [buyer, buyerTwo, address(rejectingBuyer)];
    address[2] memory sellers = [seller, sellerTwo];
    handler = new RareERC1155MarketplaceHandler(
      marketplace,
      token,
      currency,
      seller,
      address(rejectingPayoutRecipient),
      marketplaceSettings,
      royaltyEngine,
      buyers,
      sellers,
      tokenIds
    );

    targetContract(address(handler));
    bytes4[] memory selectors = new bytes4[](9);
    selectors[0] = RareERC1155MarketplaceHandler.makeOffer.selector;
    selectors[1] = RareERC1155MarketplaceHandler.acceptOffer.selector;
    selectors[2] = RareERC1155MarketplaceHandler.cancelOffer.selector;
    selectors[3] = RareERC1155MarketplaceHandler.setListing.selector;
    selectors[4] = RareERC1155MarketplaceHandler.cancelListing.selector;
    selectors[5] = RareERC1155MarketplaceHandler.buyBatch.selector;
    selectors[6] = RareERC1155MarketplaceHandler.prepareDirectSale.selector;
    selectors[7] = RareERC1155MarketplaceHandler.cancelDirectSale.selector;
    selectors[8] = RareERC1155MarketplaceHandler.checkoutMixedCart.selector;
    targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
  }

  function invariant_ethEscrowConserved() public {
    assertGe(address(marketplace).balance, handler.ghostEthEscrowOwed());
  }

  function invariant_erc20EscrowConserved() public {
    assertGe(currency.balanceOf(address(marketplace)), handler.ghostErc20EscrowOwed(address(currency)));
  }

  function invariant_tokensMatchPayments() public {
    assertEq(
      handler.ghostTokensReceivedByBuyers(),
      handler.ghostTokensRemovedFromSellers() + handler.ghostTokensMinted()
    );

    assertEq(
      handler.buyerTokenBalanceSum(),
      handler.initialBuyerTokenBalanceSum() + handler.ghostTokensReceivedByBuyers()
    );

    uint256 sellerBalanceSum = handler.sellerTokenBalanceSum();
    assertGe(handler.initialSellerTokenBalanceSum(), sellerBalanceSum);
    assertEq(handler.initialSellerTokenBalanceSum() - sellerBalanceSum, handler.ghostTokensRemovedFromSellers());

    assertEq(handler.tokenSupplySum(), handler.initialTokenSupplySum() + handler.ghostTokensMinted());
  }

  function invariant_noZeroQuantityListings() public {
    uint256 listingCount = handler.trackedListingCount();
    for (uint256 i = 0; i < listingCount; i++) {
      (uint256 tokenId, address listedSeller) = handler.trackedListingKey(i);
      IRareERC1155MarketplaceTypes.SalePrice memory salePrice = marketplace.getSalePrice(
        address(token),
        tokenId,
        listedSeller
      );

      if (salePrice.quantity == 0) {
        assertEq(salePrice.price, 0);
        assertEq(salePrice.expirationTime, 0);
        assertEq(salePrice.splitRecipients.length, 0);
        assertEq(salePrice.splitRatios.length, 0);
      } else {
        assertGt(salePrice.price, 0);
      }
    }
  }

  function invariant_offerStructConsistency() public {
    uint256 offerCount = handler.trackedOfferCount();
    uint256 ethEscrowOwed = 0;
    uint256 erc20EscrowOwed = 0;

    for (uint256 i = 0; i < offerCount; i++) {
      (uint256 tokenId, address offerBuyer, address currencyAddress) = handler.trackedOfferKey(i);
      IRareERC1155MarketplaceTypes.Offer memory offer = marketplace.getOffer(
        address(token),
        tokenId,
        offerBuyer,
        currencyAddress
      );

      if (offer.quantity == 0) {
        assertEq(offer.currencyAddress, address(0));
        assertEq(offer.price, 0);
        assertEq(offer.initialQuantity, 0);
        assertEq(offer.marketplaceFeeRemaining, 0);
        assertEq(offer.marketplaceFeeTotal, 0);
        assertEq(offer.expirationTime, 0);
        continue;
      }

      assertEq(offer.currencyAddress, currencyAddress);
      assertGt(offer.price, 0);
      assertGe(offer.initialQuantity, offer.quantity);
      assertLe(offer.marketplaceFeeRemaining, offer.marketplaceFeeTotal);

      uint256 escrowOwed = (offer.price * offer.quantity) + offer.marketplaceFeeRemaining;
      if (currencyAddress == address(0)) {
        ethEscrowOwed += escrowOwed;
      } else {
        erc20EscrowOwed += escrowOwed;
      }
    }

    assertEq(ethEscrowOwed, handler.ghostEthEscrowOwed());
    assertEq(erc20EscrowOwed, handler.ghostErc20EscrowOwed(address(currency)));
  }

  function _fundAndApproveCurrency(address _account) private {
    currency.mint(_account, 1_000_000 ether);
    vm.prank(_account);
    currency.approve(address(erc20ApprovalManager), type(uint256).max);
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
}
