// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";

import {MarketConfigV2} from "../v2/utils/MarketConfigV2.sol";
import {IRareERC1155MarketplaceTypes} from "./IRareERC1155MarketplaceTypes.sol";

/// @author SuperRare Labs Inc.
/// @title RareERC1155MarketplacePayments
/// @notice Shared payment, refund, royalty, staking fee, and split payout helpers for ERC1155 marketplaces.
library RareERC1155MarketplacePayments {
    using SafeERC20 for IERC20;

    uint256 private constant MAX_ROYALTY_RECIPIENTS = 5;

    function checkIfCurrencyIsApproved(MarketConfigV2.Config storage _config, address _currencyAddress) public view {
        if (_currencyAddress != address(0) && !_config.approvedTokenRegistry.isApprovedToken(_currencyAddress)) {
            revert IRareERC1155MarketplaceTypes.CurrencyNotApproved(_currencyAddress);
        }
    }

    function checkBatchPayment(MarketConfigV2.Config storage _config, address _currencyAddress, uint256 _amount)
        public
    {
        if (_amount == 0) {
            if (msg.value != 0) revert IRareERC1155MarketplaceTypes.MsgValueMustBeZero();
            return;
        }

        checkAmountAndTransfer(_config, _currencyAddress, _amount);
    }

    function checkAmountAndTransfer(MarketConfigV2.Config storage _config, address _currencyAddress, uint256 _amount)
        public
    {
        if (_currencyAddress == address(0)) {
            if (msg.value != _amount) revert IRareERC1155MarketplaceTypes.IncorrectETHAmount(_amount, msg.value);
            return;
        }

        if (msg.value != 0) revert IRareERC1155MarketplaceTypes.MsgValueUnsupportedForERC20();

        IERC20 erc20 = IERC20(_currencyAddress);
        uint256 balanceBefore = erc20.balanceOf(address(this));

        _config.erc20ApprovalManager.transferFrom(_currencyAddress, msg.sender, address(this), _amount);

        uint256 receivedAmount = erc20.balanceOf(address(this)) - balanceBefore;
        if (receivedAmount != _amount) {
            revert IRareERC1155MarketplaceTypes.ERC20FeeOnTransferUnsupported(_currencyAddress, _amount, receivedAmount);
        }
    }

    function checkSplits(address payable[] calldata _splitRecipients, uint8[] calldata _splitRatios) public pure {
        if (_splitRecipients.length == 0) revert IRareERC1155MarketplaceTypes.SplitRecipientsRequired();
        if (_splitRecipients.length > 5) {
            revert IRareERC1155MarketplaceTypes.SplitRecipientsExceededMax(_splitRecipients.length, 5);
        }
        if (_splitRecipients.length != _splitRatios.length) {
            revert IRareERC1155MarketplaceTypes.SplitLengthMismatch(_splitRecipients.length, _splitRatios.length);
        }

        uint256 totalRatio = 0;
        for (uint256 i = 0; i < _splitRatios.length; i++) {
            if (_splitRecipients[i] == address(0)) {
                revert IRareERC1155MarketplaceTypes.SplitRecipientCannotBeZero(i);
            }
            if (_splitRatios[i] == 0) revert IRareERC1155MarketplaceTypes.SplitRatioCannotBeZero(i);
            totalRatio += _splitRatios[i];
        }

        if (totalRatio != 100) revert IRareERC1155MarketplaceTypes.SplitTotalInvalid(totalRatio, 100);
    }

    function payoutPrimary(
        MarketConfigV2.Config storage _config,
        address _contractAddress,
        address _currencyAddress,
        uint256 _amount,
        uint256 _marketplaceFee,
        address _seller,
        address payable[] memory _splitRecipients,
        uint8[] memory _splitRatios
    ) public {
        uint256 remainingAmount = _amount;

        payoutMarketplaceFee(_config, _currencyAddress, _amount, _marketplaceFee, _seller);

        uint256 platformCommission = _config.spaceOperatorRegistry.isApprovedSpaceOperator(_seller)
            ? _config.spaceOperatorRegistry.getPlatformCommission(_seller)
            : _config.marketplaceSettings.getERC721ContractPrimarySaleFeePercentage(_contractAddress);
        if (platformCommission > 100) {
            revert IRareERC1155MarketplaceTypes.PlatformCommissionExceeded(platformCommission, 100);
        }

        uint256 platformFee = (_amount * platformCommission) / 100;
        if (platformFee > 0) {
            remainingAmount -= platformFee;

            address payable[] memory platformRecipients = new address payable[](1);
            platformRecipients[0] = payable(_config.networkBeneficiary);
            uint256[] memory platformAmounts = new uint256[](1);
            platformAmounts[0] = platformFee;

            performPayouts(_config, _currencyAddress, platformFee, platformRecipients, platformAmounts);
        }

        payoutSplits(_config, _currencyAddress, remainingAmount, _splitRecipients, _splitRatios);
    }

    function payoutSecondary(
        MarketConfigV2.Config storage _config,
        address _contractAddress,
        uint256 _tokenId,
        address _currencyAddress,
        uint256 _amount,
        uint256 _marketplaceFee,
        address _seller,
        address payable[] memory _splitRecipients,
        uint8[] memory _splitRatios
    ) public {
        uint256 stakingFee = _marketplaceFee == 0 ? 0 : _config.stakingSettings.calculateStakingFee(_amount);
        payoutSecondaryWithStakingFee(
            _config,
            _contractAddress,
            _tokenId,
            _currencyAddress,
            _amount,
            _marketplaceFee,
            stakingFee,
            _seller,
            _splitRecipients,
            _splitRatios
        );
    }

    function payoutSecondaryWithStakingFee(
        MarketConfigV2.Config storage _config,
        address _contractAddress,
        uint256 _tokenId,
        address _currencyAddress,
        uint256 _amount,
        uint256 _marketplaceFee,
        uint256 _stakingFee,
        address _seller,
        address payable[] memory _splitRecipients,
        uint8[] memory _splitRatios
    ) public {
        uint256 remainingAmount = _amount;

        payoutMarketplaceFeeWithStakingFee(_config, _currencyAddress, _marketplaceFee, _stakingFee, _seller);

        (address payable[] memory receivers, uint256[] memory royalties) =
            _config.royaltyEngine.getRoyalty(_contractAddress, _tokenId, _amount);
        (receivers, royalties) = _truncateRoyaltyRecipients(receivers, royalties);

        uint256 totalRoyalties = 0;
        for (uint256 i = 0; i < royalties.length; i++) {
            totalRoyalties += royalties[i];
        }

        if (totalRoyalties > remainingAmount) {
            revert IRareERC1155MarketplaceTypes.RoyaltiesExceedSaleAmount(totalRoyalties, remainingAmount);
        }

        if (totalRoyalties > 0) {
            remainingAmount -= totalRoyalties;
            performPayouts(_config, _currencyAddress, totalRoyalties, receivers, royalties);
        }

        payoutSplits(_config, _currencyAddress, remainingAmount, _splitRecipients, _splitRatios);
    }

    function payoutMarketplaceFee(
        MarketConfigV2.Config storage _config,
        address _currencyAddress,
        uint256 _amount,
        uint256 _marketplaceFee,
        address _seller
    ) public {
        if (_marketplaceFee == 0) {
            return;
        }

        uint256 stakingFee = _config.stakingSettings.calculateStakingFee(_amount);
        payoutMarketplaceFeeWithStakingFee(_config, _currencyAddress, _marketplaceFee, stakingFee, _seller);
    }

    function payoutMarketplaceFeeWithStakingFee(
        MarketConfigV2.Config storage _config,
        address _currencyAddress,
        uint256 _marketplaceFee,
        uint256 _stakingFee,
        address _seller
    ) public {
        if (_marketplaceFee == 0) {
            return;
        }

        if (_stakingFee > _marketplaceFee) {
            revert IRareERC1155MarketplaceTypes.StakingFeeExceedsMarketplaceFee(_marketplaceFee, _stakingFee);
        }

        address payable[] memory recipients = new address payable[](2);
        recipients[0] = payable(_config.networkBeneficiary);
        recipients[1] = payable(_config.stakingRegistry.getRewardAccumulatorAddressForUser(_seller));
        recipients[1] = recipients[1] == address(0) ? payable(_config.networkBeneficiary) : recipients[1];

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = _marketplaceFee - _stakingFee;
        amounts[1] = _stakingFee;

        if (amounts[0] == 0) {
            address payable[] memory stakingRecipients = new address payable[](1);
            stakingRecipients[0] = recipients[1];
            uint256[] memory stakingAmounts = new uint256[](1);
            stakingAmounts[0] = amounts[1];
            performPayouts(_config, _currencyAddress, _marketplaceFee, stakingRecipients, stakingAmounts);
            return;
        }

        if (amounts[1] == 0) {
            address payable[] memory marketplaceRecipients = new address payable[](1);
            marketplaceRecipients[0] = recipients[0];
            uint256[] memory marketplaceAmounts = new uint256[](1);
            marketplaceAmounts[0] = amounts[0];
            performPayouts(_config, _currencyAddress, _marketplaceFee, marketplaceRecipients, marketplaceAmounts);
            return;
        }

        performPayouts(_config, _currencyAddress, _marketplaceFee, recipients, amounts);
    }

    function refundRemainingOffer(
        MarketConfigV2.Config storage _config,
        address _currencyAddress,
        address _buyer,
        uint256 _price,
        uint256 _quantity,
        uint256 _marketplaceFeeRemaining
    ) public {
        if (_quantity == 0) {
            return;
        }

        refund(_config, _currencyAddress, payable(_buyer), (_price * _quantity) + _marketplaceFeeRemaining);
    }

    function refund(
        MarketConfigV2.Config storage _config,
        address _currencyAddress,
        address payable _recipient,
        uint256 _amount
    ) public {
        if (_amount == 0) {
            return;
        }

        if (_currencyAddress == address(0)) {
            (bool success, bytes memory data) = address(_config.payments).call{value: _amount}(
                abi.encodeWithSelector(_config.payments.refund.selector, _recipient, _amount)
            );
            if (!success) revert IRareERC1155MarketplaceTypes.RefundFailed(data);
            return;
        }

        IERC20(_currencyAddress).safeTransfer(_recipient, _amount);
    }

    function _truncateRoyaltyRecipients(address payable[] memory _receivers, uint256[] memory _royalties)
        private
        pure
        returns (address payable[] memory receivers, uint256[] memory royalties)
    {
        if (_receivers.length != _royalties.length) {
            revert IRareERC1155MarketplaceTypes.PayoutLengthMismatch(_receivers.length, _royalties.length);
        }

        uint256 royaltyRecipientCount =
            _receivers.length > MAX_ROYALTY_RECIPIENTS ? MAX_ROYALTY_RECIPIENTS : _receivers.length;
        for (uint256 i = 0; i < royaltyRecipientCount; i++) {
            if (_receivers[i] == address(0) && _royalties[i] != 0) {
                revert IRareERC1155MarketplaceTypes.RoyaltyRecipientCannotBeZero(i);
            }
        }

        if (_receivers.length <= MAX_ROYALTY_RECIPIENTS) {
            return (_receivers, _royalties);
        }

        receivers = new address payable[](MAX_ROYALTY_RECIPIENTS);
        royalties = new uint256[](MAX_ROYALTY_RECIPIENTS);
        for (uint256 i = 0; i < MAX_ROYALTY_RECIPIENTS; i++) {
            receivers[i] = _receivers[i];
            royalties[i] = _royalties[i];
        }
    }

    function payoutSplits(
        MarketConfigV2.Config storage _config,
        address _currencyAddress,
        uint256 _amount,
        address payable[] memory _splitRecipients,
        uint8[] memory _splitRatios
    ) public {
        if (_splitRecipients.length != _splitRatios.length) {
            revert IRareERC1155MarketplaceTypes.SplitLengthMismatch(_splitRecipients.length, _splitRatios.length);
        }

        uint256[] memory amounts = new uint256[](_splitRecipients.length);
        uint256 remainingPayout = _amount;

        for (uint256 i = 0; i < _splitRecipients.length; i++) {
            if (i == _splitRecipients.length - 1) {
                amounts[i] = remainingPayout;
            } else {
                amounts[i] = (_amount * _splitRatios[i]) / 100;
                remainingPayout -= amounts[i];
            }
        }

        performPayouts(_config, _currencyAddress, _amount, _splitRecipients, amounts);
    }

    function performPayouts(
        MarketConfigV2.Config storage _config,
        address _currencyAddress,
        uint256 _amount,
        address payable[] memory _recipients,
        uint256[] memory _amounts
    ) public {
        if (_recipients.length != _amounts.length) {
            revert IRareERC1155MarketplaceTypes.PayoutLengthMismatch(_recipients.length, _amounts.length);
        }

        uint256 totalAmount = 0;
        for (uint256 i = 0; i < _amounts.length; i++) {
            totalAmount += _amounts[i];
        }
        if (totalAmount != _amount) revert IRareERC1155MarketplaceTypes.PayoutTotalMismatch(_amount, totalAmount);

        if (_amount == 0) {
            return;
        }

        if (_currencyAddress == address(0)) {
            (bool success, bytes memory data) = address(_config.payments).call{value: _amount}(
                abi.encodeWithSelector(_config.payments.payout.selector, _recipients, _amounts)
            );
            if (!success) revert IRareERC1155MarketplaceTypes.PayoutFailed(data);
            return;
        }

        IERC20 erc20 = IERC20(_currencyAddress);
        for (uint256 i = 0; i < _recipients.length; i++) {
            if (_amounts[i] == 0) {
                continue;
            }
            erc20.safeTransfer(_recipients[i], _amounts[i]);
        }
    }
}
