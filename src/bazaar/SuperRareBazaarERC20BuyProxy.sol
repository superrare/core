// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Ownable} from "openzeppelin-contracts/access/Ownable.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "openzeppelin-contracts/token/ERC721/IERC721.sol";

import {ISuperRareBazaar} from "./ISuperRareBazaar.sol";

contract SuperRareBazaarERC20BuyProxy is Ownable {
  using SafeERC20 for IERC20;

  error BazaarCannotBeZeroAddress();
  error CurrencyAddressCannotBeZero();
  error RecipientCannotBeZero();

  ISuperRareBazaar public immutable bazaar;

  constructor(address _bazaar) {
    if (_bazaar == address(0)) {
      revert BazaarCannotBeZeroAddress();
    }

    bazaar = ISuperRareBazaar(_bazaar);
  }

  function approveCurrency(address _currencyAddress, uint256 _amount) external onlyOwner {
    if (_currencyAddress == address(0)) {
      revert CurrencyAddressCannotBeZero();
    }

    IERC20(_currencyAddress).forceApprove(address(bazaar), _amount);
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

    bazaar.buy(_originContract, _tokenId, _currencyAddress, _amount);
    IERC721(_originContract).transferFrom(address(this), _recipient, _tokenId);
  }
}
