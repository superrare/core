// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import "../LazySovereignNFT.sol";
import "../../../../extensions/ICreatorToken.sol";
import "../../../../extensions/ICreatorTokenTransferValidator.sol";

/// @notice A RareMinter-compatible collection with transfer-time creator-token validation.
/// @dev Minting, metadata and ERC-2981 behavior are inherited from LazySovereignNFT.
///      The owner may change or disable validation; the validator does not settle royalties.
contract LazySovereignNFTV5 is LazySovereignNFT, ICreatorToken {
    address public constant DEFAULT_TRANSFER_VALIDATOR = 0x721C008fdff27BF06E7E123956E2Fe03B63342e3;

    address private transferValidator;

    error InvalidTransferValidator();
    error InvalidRoyaltyPercentage();

    constructor() {
        _disableInitializers();
    }

    /// @dev The parent initializer protects the whole transaction against replay.
    function init(string calldata _name, string calldata _symbol, address _creator, uint256 _maxTokens)
        public
        override
    {
        super.init(_name, _symbol, _creator, _maxTokens);
        _setTransferValidator(DEFAULT_TRANSFER_VALIDATOR);
    }

    function getTransferValidator() public view override returns (address) {
        return transferValidator;
    }

    /// @notice Set a V5-compatible validator, or zero to disable transfer validation.
    /// @dev Nonzero validators must accept ERC-721 token-type registration.
    function setTransferValidator(address validator) external override onlyOwner {
        _setTransferValidator(validator);
    }

    /// @notice Set the royalty default in whole percentage points for subsequent mints.
    /// @dev Existing nonzero per-token snapshots retain their rates.
    function setDefaultRoyaltyPercentage(uint256 percentage) external onlyOwner {
        if (percentage > 100) {
            revert InvalidRoyaltyPercentage();
        }
        _setDefaultRoyaltyPercentage(percentage);
    }

    function getTransferValidationFunction()
        external
        pure
        override
        returns (bytes4 functionSignature, bool isViewFunction)
    {
        return (ICreatorTokenTransferValidator.validateTransfer.selector, true);
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(ICreatorToken).interfaceId || super.supportsInterface(interfaceId);
    }

    function _beforeTokenTransfer(address from, address to, uint256 firstTokenId, uint256 batchSize)
        internal
        virtual
        override
    {
        super._beforeTokenTransfer(from, to, firstTokenId, batchSize);

        address validator = transferValidator;
        // Match creator-token-standards: mint/burn are not sales, and the validator
        // pre-validates its own transfers. No automatic validator approval is granted.
        if (from == address(0) || to == address(0) || validator == address(0) || _msgSender() == validator) {
            return;
        }

        for (uint256 i; i < batchSize;) {
            ICreatorTokenTransferValidator(validator).validateTransfer(_msgSender(), from, to, firstTokenId + i);
            unchecked {
                ++i;
            }
        }
    }

    function _setTransferValidator(address validator) private {
        if (validator != address(0) && validator.code.length == 0) {
            revert InvalidTransferValidator();
        }

        emit TransferValidatorUpdated(transferValidator, validator);
        transferValidator = validator;

        if (validator != address(0)) {
            ICreatorTokenTransferValidator(validator).setTokenTypeOfCollection(address(this), 721);
        }
    }
}
