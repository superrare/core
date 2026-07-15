// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Ownable} from "openzeppelin-contracts/access/Ownable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/security/ReentrancyGuard.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "openzeppelin-contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "openzeppelin-contracts/token/ERC721/IERC721Receiver.sol";
import {IMarketplaceSettings} from "rareprotocol/aux/marketplace/IMarketplaceSettings.sol";

import {ISuperRareBazaar} from "./ISuperRareBazaar.sol";
import {IRareMinter} from "../collection/IRareMinter.sol";
import {IRareERC1155Marketplace} from "../marketplace/IRareERC1155Marketplace.sol";
import {IRareERC1155MarketplaceTypes} from "../marketplace/IRareERC1155MarketplaceTypes.sol";

interface ISuperRareBazaarSettings {
  function marketplaceSettings() external view returns (address);
}

contract SuperRareBazaarERC20BuyProxy is Ownable, ReentrancyGuard, IERC721Receiver {
  using SafeERC20 for IERC20;

  error BazaarCannotBeZeroAddress();
  error RareMinterCannotBeZeroAddress();
  error ERC1155MarketplaceCannotBeZeroAddress();
  error CurrencyAddressCannotBeZero();
  error RecipientCannotBeZero();
  error UnexpectedMintedTokenCount(uint256 expectedCount, uint256 actualCount);

  ISuperRareBazaar public immutable bazaar;
  IRareMinter public immutable rareMinter;
  IRareERC1155Marketplace public immutable erc1155Marketplace;
  address private pendingMintOriginContract;
  uint256[] private pendingMintTokenIds;

  constructor(address _bazaar, address _rareMinter, address _erc1155Marketplace) {
    if (_bazaar == address(0)) {
      revert BazaarCannotBeZeroAddress();
    }

    if (_rareMinter == address(0)) {
      revert RareMinterCannotBeZeroAddress();
    }

    if (_erc1155Marketplace == address(0)) {
      revert ERC1155MarketplaceCannotBeZeroAddress();
    }

    bazaar = ISuperRareBazaar(_bazaar);
    rareMinter = IRareMinter(_rareMinter);
    erc1155Marketplace = IRareERC1155Marketplace(_erc1155Marketplace);
  }

  function approveCurrency(address _currencyAddress, uint256 _amount) external onlyOwner {
    if (_currencyAddress == address(0)) {
      revert CurrencyAddressCannotBeZero();
    }

    IERC20(_currencyAddress).forceApprove(address(bazaar), _amount);
    IERC20(_currencyAddress).forceApprove(address(rareMinter), _amount);
    IERC20(_currencyAddress).forceApprove(_erc1155ApprovalTarget(), _amount);
  }

  function buy(
    address _originContract,
    uint256 _tokenId,
    address _currencyAddress,
    uint256 _amount,
    address _recipient
  ) external nonReentrant {
    if (_currencyAddress == address(0)) {
      revert CurrencyAddressCannotBeZero();
    }

    if (_recipient == address(0)) {
      revert RecipientCannotBeZero();
    }

    uint256 marketplaceFee =
      IMarketplaceSettings(ISuperRareBazaarSettings(address(bazaar)).marketplaceSettings()).calculateMarketplaceFee(_amount);
    uint256 requiredAmount = _amount + marketplaceFee;

    IERC20(_currencyAddress).transferFrom(msg.sender, address(this), requiredAmount);
    bazaar.buy(_originContract, _tokenId, _currencyAddress, _amount);
    IERC721(_originContract).transferFrom(address(this), _recipient, _tokenId);
  }

  function mint(
    address _originContract,
    address _currencyAddress,
    uint256 _amount,
    uint8 _numMints,
    bytes32[] calldata _proof,
    address _recipient
  ) external nonReentrant {
    if (_currencyAddress == address(0)) {
      revert CurrencyAddressCannotBeZero();
    }

    if (_recipient == address(0)) {
      revert RecipientCannotBeZero();
    }

    uint256 totalAmount = _amount * _numMints;
    uint256 marketplaceFee =
      IMarketplaceSettings(ISuperRareBazaarSettings(address(bazaar)).marketplaceSettings()).calculateMarketplaceFee(
        totalAmount
      );
    uint256 requiredAmount = totalAmount + marketplaceFee;

    IERC20(_currencyAddress).transferFrom(msg.sender, address(this), requiredAmount);

    delete pendingMintTokenIds;
    pendingMintOriginContract = _originContract;

    rareMinter.mintDirectSale(_originContract, _currencyAddress, _amount, _numMints, _proof);

    pendingMintOriginContract = address(0);

    uint256 mintedTokenCount = pendingMintTokenIds.length;
    if (mintedTokenCount != _numMints) {
      revert UnexpectedMintedTokenCount(_numMints, mintedTokenCount);
    }

    for (uint256 i = 0; i < mintedTokenCount; i++) {
      IERC721(_originContract).transferFrom(address(this), _recipient, pendingMintTokenIds[i]);
    }

    delete pendingMintTokenIds;
  }

  /// @notice Buys ERC1155 tokens from a seller's secondary fixed-price listings using ERC20 currency.
  /// @dev Pulls the gross price plus marketplace fee for every request from the caller and settles the purchase
  /// through the ERC1155 marketplace, which transfers the tokens directly to `_recipient`.
  /// @param _contractAddress ERC1155 collection being purchased from.
  /// @param _seller Seller whose listings are being filled.
  /// @param _currencyAddress ERC20 currency used to pay.
  /// @param _requests Per-token purchase requests (tokenId, price, quantity), token ids strictly ascending.
  /// @param _recipient Address that receives the purchased tokens.
  function buyBatch(
    address _contractAddress,
    address _seller,
    address _currencyAddress,
    IRareERC1155MarketplaceTypes.BuyRequest[] calldata _requests,
    address _recipient
  ) external nonReentrant {
    if (_currencyAddress == address(0)) {
      revert CurrencyAddressCannotBeZero();
    }

    if (_recipient == address(0)) {
      revert RecipientCannotBeZero();
    }

    IMarketplaceSettings marketplaceSettings = _erc1155MarketplaceSettings();

    uint256 requiredAmount = 0;
    for (uint256 i = 0; i < _requests.length; i++) {
      uint256 grossAmount = _requests[i].price * _requests[i].quantity;
      requiredAmount += grossAmount + marketplaceSettings.calculateMarketplaceFee(grossAmount);
    }

    IERC20(_currencyAddress).transferFrom(msg.sender, address(this), requiredAmount);
    erc1155Marketplace.buyBatch(_contractAddress, _seller, _currencyAddress, _recipient, _requests);
  }

  /// @notice Mints ERC1155 tokens from configured primary sales using ERC20 currency.
  /// @dev Pulls the gross price plus marketplace fee for every request from the caller and settles the mint
  /// through the ERC1155 marketplace, which mints the tokens directly to `_recipient`.
  /// @param _contractAddress ERC1155 collection being minted from.
  /// @param _currencyAddress ERC20 currency used to pay.
  /// @param _requests Per-token mint requests (tokenId, price, quantity, proof), token ids strictly ascending.
  /// @param _recipient Address that receives the minted tokens.
  function mintDirectSaleBatch(
    address _contractAddress,
    address _currencyAddress,
    IRareERC1155MarketplaceTypes.MintRequest[] calldata _requests,
    address _recipient
  ) external nonReentrant {
    if (_currencyAddress == address(0)) {
      revert CurrencyAddressCannotBeZero();
    }

    if (_recipient == address(0)) {
      revert RecipientCannotBeZero();
    }

    IMarketplaceSettings marketplaceSettings = _erc1155MarketplaceSettings();

    uint256 requiredAmount = 0;
    for (uint256 i = 0; i < _requests.length; i++) {
      uint256 grossAmount = _requests[i].price * _requests[i].quantity;
      requiredAmount += grossAmount + marketplaceSettings.calculateMarketplaceFee(grossAmount);
    }

    IERC20(_currencyAddress).transferFrom(msg.sender, address(this), requiredAmount);
    erc1155Marketplace.mintDirectSaleBatch(_contractAddress, _currencyAddress, _recipient, _requests);
  }

  function onERC721Received(address, address, uint256 _tokenId, bytes calldata) external returns (bytes4) {
    if (pendingMintOriginContract != address(0) && msg.sender == pendingMintOriginContract) {
      pendingMintTokenIds.push(_tokenId);
    }

    return IERC721Receiver.onERC721Received.selector;
  }

  /// @dev The ERC1155 marketplace pulls ERC20 funds from this contract through its configured
  /// ERC20 approval manager, so currency approvals must target that manager rather than the marketplace.
  function _erc1155ApprovalTarget() private view returns (address) {
    return address(erc1155Marketplace.getMarketConfig().erc20ApprovalManager);
  }

  function _erc1155MarketplaceSettings() private view returns (IMarketplaceSettings) {
    return erc1155Marketplace.getMarketConfig().marketplaceSettings;
  }
}
