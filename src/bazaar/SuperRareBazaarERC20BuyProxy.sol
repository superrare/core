// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Ownable} from "openzeppelin-contracts/access/Ownable.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "openzeppelin-contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "openzeppelin-contracts/token/ERC721/IERC721Receiver.sol";
import {IMarketplaceSettings} from "rareprotocol/aux/marketplace/IMarketplaceSettings.sol";

import {ISuperRareBazaar} from "./ISuperRareBazaar.sol";
import {IRareMinter} from "../collection/IRareMinter.sol";

interface ISuperRareBazaarSettings {
  function marketplaceSettings() external view returns (address);
}

contract SuperRareBazaarERC20BuyProxy is Ownable, IERC721Receiver {
  using SafeERC20 for IERC20;

  error BazaarCannotBeZeroAddress();
  error RareMinterCannotBeZeroAddress();
  error CurrencyAddressCannotBeZero();
  error RecipientCannotBeZero();
  error UnexpectedMintedTokenCount(uint256 expectedCount, uint256 actualCount);

  ISuperRareBazaar public immutable bazaar;
  IRareMinter public immutable rareMinter;
  address private pendingMintOriginContract;
  uint256[] private pendingMintTokenIds;

  constructor(address _bazaar, address _rareMinter) {
    if (_bazaar == address(0)) {
      revert BazaarCannotBeZeroAddress();
    }

    if (_rareMinter == address(0)) {
      revert RareMinterCannotBeZeroAddress();
    }

    bazaar = ISuperRareBazaar(_bazaar);
    rareMinter = IRareMinter(_rareMinter);
  }

  function approveCurrency(address _currencyAddress, uint256 _amount) external onlyOwner {
    if (_currencyAddress == address(0)) {
      revert CurrencyAddressCannotBeZero();
    }

    IERC20(_currencyAddress).forceApprove(address(bazaar), _amount);
    IERC20(_currencyAddress).forceApprove(address(rareMinter), _amount);
  }

  function buy(
    address _originContract,
    uint256 _tokenId,
    address _currencyAddress,
    uint256 _amount,
    address _recipient
  ) external {
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
  ) external {
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

  function onERC721Received(address, address, uint256 _tokenId, bytes calldata) external returns (bytes4) {
    if (pendingMintOriginContract != address(0) && msg.sender == pendingMintOriginContract) {
      pendingMintTokenIds.push(_tokenId);
    }

    return IERC721Receiver.onERC721Received.selector;
  }
}
