// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import "./SovereignBatchMint.sol";
import "../../../../token/extensions/ICreatorToken.sol";
import "../../../../token/extensions/ICreatorTokenTransferValidator.sol";
import "../../../royalty/RoyaltySplitReceiver.sol";

/// @notice A standard V2 collection with transfer-time creator-token validation.
/// @dev The V2 factory initializes the implementation before creating clones.
///      Immediate minting, batch creation, metadata and royalties retain V2 behavior.
contract SovereignBatchMintV5 is SovereignBatchMint, ICreatorToken, RoyaltySplitReceiver {
    address public constant DEFAULT_TRANSFER_VALIDATOR = 0x721C008fdff27BF06E7E123956E2Fe03B63342e3;

    address private transferValidator;

    error InvalidTransferValidator();

    /// @dev The parent initializer protects the whole transaction against replay.
    function init(string calldata _name, string calldata _symbol, address _creator, uint256 _maxTokens)
        public
        override
    {
        super.init(_name, _symbol, _creator, _maxTokens);
        _setTransferValidator(DEFAULT_TRANSFER_VALIDATOR);
    }

    function initWithRoyaltySplit(
        string calldata name,
        string calldata symbol,
        address creator,
        uint256 maxTokens,
        address splitterFactory,
        RoyaltySplitConfig calldata config
    ) external returns (address splitter) {
        init(name, symbol, creator, maxTokens);
        splitter = _initializeRoyaltySplit(splitterFactory, config);
        _setDefaultRoyaltyReceiver(splitter);
        _setDefaultRoyaltyPercentage(config.royaltyPercentage);
    }

    function addNewToken(string memory uri) public override onlyOwner ifNotDisabled {
        _createToken(uri, msg.sender, getDefaultRoyaltyPercentage(), _resolveRoyaltyReceiver(msg.sender));
    }

    /// @dev On opt-in collections the royalty argument is the beneficiary, not a new split policy.
    function mintTo(string calldata uri, address receiver, address royaltyReceiver)
        external
        override
        onlyOwner
        ifNotDisabled
    {
        _createToken(uri, receiver, getDefaultRoyaltyPercentage(), _resolveRoyaltyReceiver(royaltyReceiver));
    }

    function setRoyaltyBeneficiaryForToken(address beneficiary, uint256 tokenId) external onlyOwner {
        ownerOf(tokenId);
        _setRoyaltyReceiver(tokenId, _resolveRoyaltyReceiver(beneficiary));
    }

    function _royaltyDefaultReceiver() internal view override returns (address) {
        return getDefaultRoyaltyReceiver();
    }

    function getTransferValidator() public view override returns (address) {
        return transferValidator;
    }

    /// @notice Set a V5-compatible validator, or zero to disable transfer validation.
    /// @dev Nonzero validators must accept ERC-721 token-type registration.
    function setTransferValidator(address validator) external override onlyOwner {
        _setTransferValidator(validator);
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
