// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import "./RoyaltySplitterFactory.sol";
import "openzeppelin-contracts/finance/PaymentSplitter.sol";

interface IRoyaltySplitInitializable {
    function initWithRoyaltySplit(
        string calldata name,
        string calldata symbol,
        address creator,
        uint256 maxTokens,
        address splitterFactory,
        RoyaltySplitConfig calldata config
    ) external returns (address splitter);
}

/// @dev Opt-in payout templates; ordinary initialization leaves routing unchanged.
abstract contract RoyaltySplitReceiver {
    RoyaltySplitterFactory public royaltySplitterFactory;
    uint256 public royaltyBeneficiaryIndex;
    address[] private _royaltyRecipients;
    uint256[] private _royaltyShares;

    error InvalidRoyaltySplitConfig();
    error RoyaltySplitNotConfigured();
    error IncompatibleRoyaltySplitter();

    event RoyaltySplitTermsConfigured(
        address indexed splitterFactory,
        uint256 beneficiaryIndex,
        uint256 royaltyPercentage,
        address[] recipients,
        uint256[] shares
    );

    function royaltySplitTerms()
        external
        view
        returns (address[] memory recipients, uint256[] memory shares, uint256 beneficiaryIndex)
    {
        return (_royaltyRecipients, _royaltyShares, royaltyBeneficiaryIndex);
    }

    /// @notice Predict a payout destination without deploying a new splitter.
    /// @dev Existing owner overrides of the default receiver remain authoritative.
    function predictRoyaltySplitter(address beneficiary) public view returns (address) {
        if (address(royaltySplitterFactory) == address(0)) revert RoyaltySplitNotConfigured();
        address defaultReceiver = _royaltyDefaultReceiver();
        if (_usesDefaultReceiver(beneficiary, defaultReceiver)) return defaultReceiver;

        (address[] memory recipients, uint256[] memory shares, bool existingSplit) = _termsFor(beneficiary);
        if (existingSplit) return beneficiary;
        return royaltySplitterFactory.predictSplitter(recipients, shares);
    }

    function _initializeRoyaltySplit(address factory, RoyaltySplitConfig calldata config)
        internal
        returns (address splitter)
    {
        if (
            address(royaltySplitterFactory) != address(0) || factory.code.length == 0
                || config.beneficiaryIndex >= config.recipients.length || config.royaltyPercentage > 100
        ) revert InvalidRoyaltySplitConfig();

        royaltySplitterFactory = RoyaltySplitterFactory(factory);
        royaltyBeneficiaryIndex = config.beneficiaryIndex;
        _royaltyRecipients = config.recipients;
        _royaltyShares = config.shares;
        splitter = royaltySplitterFactory.getOrCreateSplitter(config.recipients, config.shares);
        if (splitter.code.length == 0) revert InvalidRoyaltySplitConfig();

        emit RoyaltySplitTermsConfigured(
            factory, config.beneficiaryIndex, config.royaltyPercentage, config.recipients, config.shares
        );
    }

    function _resolveRoyaltyReceiver(address beneficiary) internal returns (address) {
        if (address(royaltySplitterFactory) == address(0)) return beneficiary;
        address defaultReceiver = _royaltyDefaultReceiver();
        if (_usesDefaultReceiver(beneficiary, defaultReceiver)) return defaultReceiver;

        (address[] memory recipients, uint256[] memory shares, bool existingSplit) = _termsFor(beneficiary);
        if (existingSplit) return beneficiary;
        return royaltySplitterFactory.getOrCreateSplitter(recipients, shares);
    }

    function _usesDefaultReceiver(address beneficiary, address defaultReceiver) private view returns (bool) {
        return beneficiary == address(0) || beneficiary == defaultReceiver
            || beneficiary == _royaltyRecipients[royaltyBeneficiaryIndex];
    }

    function _termsFor(address beneficiary)
        private
        view
        returns (address[] memory recipients, uint256[] memory shares, bool existingSplit)
    {
        recipients = _royaltyRecipients;
        shares = _royaltyShares;
        existingSplit = royaltySplitterFactory.configurationHash(beneficiary) != bytes32(0);
        recipients[royaltyBeneficiaryIndex] =
            existingSplit ? PaymentSplitter(payable(beneficiary)).payee(royaltyBeneficiaryIndex) : beneficiary;
        if (existingSplit && royaltySplitterFactory.predictSplitter(recipients, shares) != beneficiary) {
            revert IncompatibleRoyaltySplitter();
        }
    }

    function _royaltyDefaultReceiver() internal view virtual returns (address);
}
