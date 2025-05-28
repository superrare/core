// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {IERC721} from "openzeppelin-contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {IPayments} from "rareprotocol/aux/payments/IPayments.sol";
import {MarketConfigV2} from "./MarketConfigV2.sol";

library MarketUtilsV2 {
  using SafeERC20 for IERC20;

  /// @notice Maximum number of royalty recipients allowed to prevent DoS attacks
  uint256 public constant MAX_ROYALTY_RECIPIENTS = 5;

  /// @notice Error thrown when too many royalty recipients are returned
  error TooManyRoyaltyRecipients();

  /// @notice Checks to see if the currency address is eth or an approved erc20 token.
  /// @param _currencyAddress Address of currency (Zero address if eth).
  function checkIfCurrencyIsApproved(MarketConfigV2.Config storage _config, address _currencyAddress) internal view {
    require(
      _currencyAddress == address(0) || _config.approvedTokenRegistry.isApprovedToken(_currencyAddress),
      "Not approved currency"
    );
  }

  /// @notice Checks to see if the msg sender owns the token.
  /// @param _originContract Contract address of the token being checked.
  /// @param _tokenId Token Id of the asset.
  function senderMustBeTokenOwner(address _originContract, uint256 _tokenId) internal view {
    IERC721 erc721 = IERC721(_originContract);
    require(erc721.ownerOf(_tokenId) == msg.sender, "sender must be the token owner");
  }

  /// @notice Checks to see if the approval manager has approval to transfer the NFT
  /// @param _originContract Contract address of the token being checked.
  /// @param _tokenId Token Id of the asset.
  function addressMustHaveMarketplaceApprovedForNFT(
    MarketConfigV2.Config storage _config,
    address _address,
    address _originContract,
    uint256 _tokenId
  ) internal view {
    IERC721 nft = IERC721(_originContract);
    require(nft.isApprovedForAll(_address, address(_config.erc721ApprovalManager)), "owner must have approved token");
  }

  /// @notice Verifies that the splits supplied are valid.
  /// @dev A valid split has the same number of splits and ratios.
  /// @dev There can only be a max of 5 parties split with.
  /// @dev Total of the ratios should be 100 which is relative.
  /// @param _splitAddrs The addresses the amount is being split with.
  /// @param _splitRatios The ratios each address in _splits is getting.
  function checkSplits(address payable[] calldata _splitAddrs, uint8[] calldata _splitRatios) internal pure {
    require(_splitAddrs.length > 0, "checkSplits::Must have at least 1 split");
    require(_splitAddrs.length <= 5, "checkSplits::Split exceeded max size");
    require(_splitAddrs.length == _splitRatios.length, "checkSplits::Splits and ratios must be equal");
    uint256 totalRatio = 0;

    for (uint256 i = 0; i < _splitRatios.length; i++) {
      totalRatio += _splitRatios[i];
    }

    require(totalRatio == 100, "checkSplits::Total must be equal to 100");
  }

  /// @notice Checks to see if the approval manager has approval to transfer tokens
  /// @dev This is for offers/buys/bids and the allowance of erc20 tokens.
  /// @dev Returns on zero address because no allowance is needed for eth.
  /// @param _currency The address of the currency being checked.
  /// @param _amount The total amount being checked.
  function senderMustHaveMarketplaceApproved(
    MarketConfigV2.Config storage _config,
    address _currency,
    uint256 _amount
  ) internal view {
    if (_currency == address(0)) {
      return;
    }

    IERC20 erc20 = IERC20(_currency);
    require(
      erc20.allowance(msg.sender, address(_config.erc20ApprovalManager)) >= _amount,
      "sender needs to approve ERC20ApprovalManager for currency"
    );
  }

  /// @notice Checks the user has the correct amount and transfers to the marketplace.
  /// @dev If the currency used is eth (zero address) the msg value is checked.
  /// @dev If eth isnt used and eth is sent we revert the txn.
  /// @dev We need to check this contracts balance before and after the transfer to ensure no fee.
  /// @param _config The market config
  /// @param _currencyAddress Currency address being checked and transfered.
  /// @param _amount Total amount of currency.
  function checkAmountAndTransfer(
    MarketConfigV2.Config storage _config,
    address _currencyAddress,
    uint256 _amount
  ) internal {
    if (_currencyAddress == address(0)) {
      require(msg.value == _amount, "not enough eth sent");
      return;
    }

    require(msg.value == 0, "msg.value should be 0 when not using eth");

    IERC20 erc20 = IERC20(_currencyAddress);
    uint256 balanceBefore = erc20.balanceOf(address(this));

    _config.erc20ApprovalManager.transferFrom(_currencyAddress, msg.sender, address(this), _amount);

    uint256 balanceAfter = erc20.balanceOf(address(this));

    require(balanceAfter - balanceBefore == _amount, "not enough tokens transfered");
  }

  /// @notice Refunds an address the designated amount.
  /// @dev Return if amount being refunded is zero.
  /// @dev Forwards to payment contract if eth is being refunded.
  /// @param _currencyAddress Address of currency being refunded.
  /// @param _amount Amount being refunded.
  /// @param _marketplaceFee Marketplace Fee (percentage) paid by _recipient.
  /// @param _recipient Address amount is being refunded to.
  function refund(
    MarketConfigV2.Config storage _config,
    address _currencyAddress,
    uint256 _amount,
    uint256 _marketplaceFee,
    address _recipient
  ) internal {
    if (_amount == 0) {
      return;
    }

    uint256 requiredAmount = _amount + ((_amount * _marketplaceFee) / 100);

    if (_currencyAddress == address(0)) {
      (bool success, bytes memory data) = address(_config.payments).call{value: requiredAmount}(
        abi.encodeWithSignature("refund(address,uint256)", _recipient, requiredAmount)
      );

      require(success, string(data));
      return;
    }

    IERC20 erc20 = IERC20(_currencyAddress);
    erc20.safeTransfer(_recipient, requiredAmount);
  }

  /// @notice Sends a payout to all the necessary parties.
  /// @dev Note that _splitAddrs and _splitRatios are not checked for validity. Make sure supplied values are correct by using _checkSplits.
  /// @dev Sends payments to the network, royalty if applicable, and splits for the rest.
  /// @dev Forwards payments to the payment contract if payout is happening in eth.
  /// @dev Total amount of ratios should be 100 and is relative to the total ratio left.
  /// @param _originContract Contract address of asset triggering a payout.
  /// @param _tokenId Token Id of the asset.
  /// @param _currencyAddress Address of currency being paid out.
  /// @param _amount Total amount to be paid out.
  /// @param _seller Address of the person selling the asset.
  /// @param _splitAddrs Addresses that funds need to be split against.
  /// @param _splitRatios Ratios for split pertaining to each address.
  function payout(
    MarketConfigV2.Config storage _config,
    address _originContract,
    uint256 _tokenId,
    address _currencyAddress,
    uint256 _amount,
    address _seller,
    address payable[] memory _splitAddrs,
    uint8[] memory _splitRatios
  ) internal {
    payoutWithMarketplaceFee(
      _config,
      _originContract,
      _tokenId,
      _currencyAddress,
      _amount,
      _seller,
      _splitAddrs,
      _splitRatios,
      _config.marketplaceSettings.getMarketplaceFeePercentage()
    );
  }

  /// @notice Sends a payout to all the necessary parties with a specific marketplace fee percentage.
  /// @dev Note that _splitAddrs and _splitRatios are not checked for validity. Make sure supplied values are correct by using _checkSplits.
  /// @dev Sends payments to the network, royalty if applicable, and splits for the rest.
  /// @dev Forwards payments to the payment contract if payout is happening in eth.
  /// @dev Total amount of ratios should be 100 and is relative to the total ratio left.
  /// @param _originContract Contract address of asset triggering a payout.
  /// @param _tokenId Token Id of the asset.
  /// @param _currencyAddress Address of currency being paid out.
  /// @param _amount Total amount to be paid out.
  /// @param _seller Address of the person selling the asset.
  /// @param _splitAddrs Addresses that funds need to be split against.
  /// @param _splitRatios Ratios for split pertaining to each address.
  /// @param _marketplaceFeePercentage The marketplace fee percentage to use for this payout.
  function payoutWithMarketplaceFee(
    MarketConfigV2.Config storage _config,
    address _originContract,
    uint256 _tokenId,
    address _currencyAddress,
    uint256 _amount,
    address _seller,
    address payable[] memory _splitAddrs,
    uint8[] memory _splitRatios,
    uint8 _marketplaceFeePercentage
  ) internal {
    require(_splitAddrs.length == _splitRatios.length, "Number of split addresses and ratios must be equal.");

    /*
        The overall flow for payouts is:
            1. Payout marketplace fee
            2. Primary/Secondary Payouts
                a. Primary -> If space sale, query space operator registry for platform comission and payout
                              Else query marketplace setting for primary sale comission and payout
                b. Secondary -> Query global royalty registry for recipients and amounts and payout
            3. Calculate the amount for each _splitAddr based on remaining amount and payout
         */

    uint256 remainingAmount = _amount;

    // Marketplace fee - use the provided fee percentage instead of current settings
    uint256 marketplaceFee = (_amount * _marketplaceFeePercentage) / 100;

    address payable[] memory mktFeeRecip = new address payable[](2);
    mktFeeRecip[0] = payable(_config.networkBeneficiary);
    mktFeeRecip[1] = payable(_config.stakingRegistry.getRewardAccumulatorAddressForUser(_seller));
    mktFeeRecip[1] = mktFeeRecip[1] == address(0) ? payable(_config.networkBeneficiary) : mktFeeRecip[1];
    uint256[] memory mktFee = new uint256[](2);
    require(
      marketplaceFee - _config.stakingSettings.calculateStakingFee(_amount) >= 0,
      "Marketplace fee is less than staking fee"
    );
    mktFee[0] = marketplaceFee - _config.stakingSettings.calculateStakingFee(_amount); // All marketplace fee goes to network beneficiary
    mktFee[1] = _config.stakingSettings.calculateStakingFee(_amount); // Staking fee for this implementation

    performPayouts(_config, _currencyAddress, marketplaceFee, mktFeeRecip, mktFee);

    if (!_config.marketplaceSettings.hasERC721TokenSold(_originContract, _tokenId)) {
      uint256[] memory platformFee = new uint256[](1);
      address payable[] memory platformRecip = new address payable[](1);
      platformRecip[0] = mktFeeRecip[0];

      if (_config.spaceOperatorRegistry.isApprovedSpaceOperator(_seller)) {
        uint256 platformCommission = _config.spaceOperatorRegistry.getPlatformCommission(_seller);

        remainingAmount = remainingAmount - ((_amount * platformCommission) / 100);

        platformFee[0] = (_amount * platformCommission) / 100;

        performPayouts(_config, _currencyAddress, platformFee[0], platformRecip, platformFee);
      } else {
        uint256 platformCommission = _config.marketplaceSettings.getERC721ContractPrimarySaleFeePercentage(
          _originContract
        );

        remainingAmount = remainingAmount - ((_amount * platformCommission) / 100);

        platformFee[0] = (_amount * platformCommission) / 100;

        performPayouts(_config, _currencyAddress, platformFee[0], platformRecip, platformFee);
      }
    }

    // Get royalty recipients and amounts
    (address payable[] memory recipients, uint256[] memory amounts) = _config.royaltyEngine.getRoyalty(
      _originContract,
      _tokenId,
      _amount
    );

    // Check for maximum royalty recipients to prevent DoS attacks
    if (recipients.length > MAX_ROYALTY_RECIPIENTS) {
      revert TooManyRoyaltyRecipients();
    }

    // Calculate total royalty amount
    uint256 totalRoyaltyAmount = 0;
    for (uint256 i = 0; i < amounts.length; i++) {
      totalRoyaltyAmount += amounts[i];
    }

    remainingAmount = remainingAmount - totalRoyaltyAmount;

    // Pay out royalties
    performPayouts(_config, _currencyAddress, totalRoyaltyAmount, recipients, amounts);

    // Calculate and pay out splits
    uint256[] memory splitAmounts = new uint256[](_splitRatios.length);
    for (uint256 i = 0; i < _splitRatios.length; i++) {
      splitAmounts[i] = (remainingAmount * _splitRatios[i]) / 100;
    }

    performPayouts(_config, _currencyAddress, remainingAmount, _splitAddrs, splitAmounts);
  }

  /// @notice Performs payouts to recipients.
  /// @dev If eth is being paid out, forwards to payment contract.
  /// @dev If erc20 is being paid out, transfers directly.
  /// @param _currencyAddress Address of currency being paid out.
  /// @param _totalAmount Total amount being paid out.
  /// @param _recipients Recipients of the payouts.
  /// @param _amounts Amounts pertaining to each recipient.
  function performPayouts(
    MarketConfigV2.Config storage _config,
    address _currencyAddress,
    uint256 _totalAmount,
    address payable[] memory _recipients,
    uint256[] memory _amounts
  ) internal {
    if (_currencyAddress == address(0)) {
      (bool success, bytes memory data) = address(_config.payments).call{value: _totalAmount}(
        abi.encodeWithSignature("payout(address[],uint256[])", _recipients, _amounts)
      );

      require(success, string(data));
      return;
    }

    IERC20 erc20 = IERC20(_currencyAddress);
    for (uint256 i = 0; i < _recipients.length; i++) {
      erc20.safeTransfer(_recipients[i], _amounts[i]);
    }
  }

  /// @notice Transfers an ERC721 token using the approval manager
  /// @param _config The market config
  /// @param _originContract The address of the ERC721 contract
  /// @param _from The current owner of the token
  /// @param _to The recipient of the token
  /// @param _tokenId The ID of the token being transferred
  function transferERC721(
    MarketConfigV2.Config storage _config,
    address _originContract,
    address _from,
    address _to,
    uint256 _tokenId
  ) internal {
    _config.erc721ApprovalManager.transferFrom(_originContract, _from, _to, _tokenId);
  }
}
